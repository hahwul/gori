require "db"
require "./filter_ast"
require "./proto" # Proto::Kind, used by the `proto:` term below

module Gori
  # The query language (DESIGN.md §4): a Lucene/KQL-style boolean filter over the
  # captured flows, compiled to a SQL WHERE fragment + bound params (values are
  # always parameterised — never interpolated — so the projection columns stay
  # injection-safe). The analysis surface; QL is how you find things (P8: pull).
  #
  #   host:acme status:>=500            # AND of terms (whitespace)
  #   (host:a OR host:b) -method:GET    # OR, grouping, negation
  #   -host:cdn  status:5xx  login      # negation, status class, free text
  #   body:token                        # scan request/response body bytes
  #   size:>10000 dur:>=500 dur:<2s     # total bytes (req+resp) / latency (ms; ms|s)
  #   reqsize:>1000 respsize:<500       # request-only / response-only byte size
  #   header:set-cookie                 # substring over request/response head bytes
  #   body~secret\d+  host~^api\.       # `~` = regex (host path url header body)
  module QL
    # `:` fields:  host path method scheme proto status size reqsize respsize dur header body
    # `~` regex on: host path url header body   (+ bare words = free text).
    # Comparison ops (<= >= < > =) apply to status/size/reqsize/respsize/dur.
    struct Filter
      getter sql : String # safe to splice into "WHERE ..."; values are in `args`
      getter args : Array(DB::Any)

      def initialize(@sql : String, @args : Array(DB::Any))
      end

      # Does answering this filter read the trigram index? `body:` and free text are the
      # only terms that compile to a `flows_fts` subquery (see body_cond / free text below),
      # and nothing else mentions that table, so matching the name is exact rather than
      # heuristic. Callers use it to decide whether a stale index would corrupt their answer:
      # indexing is off-commit (Store V4), so a one-shot surface drains the backlog first
      # (Store#index_pending!) while a live one reports Store#fts_backlog instead of stalling.
      def uses_fts? : Bool
        @sql.includes?("flows_fts")
      end
    end

    EMPTY = Filter.new("1", [] of DB::Any)

    # The scope/QL-matching URL for a STORED flow: `scheme://host` + `target`, UNLESS
    # `target` is already ABSOLUTE-FORM (case-insensitive `http://`/`https://` — the wire
    # shape a plain-HTTP forward-proxy request arrives in), in which case it already
    # carries scheme+authority and stands in for the whole URL as-is (mirrors
    # Store::FlowRow.absolute_form?'s Crystal-side check — kept case-insensitive in sync
    # by hand, one's SQL, one's Crystal). Shared by the `url~` field below and Scope's
    # string/regex rule matching (scope.cr) so both agree on every row.
    URL_EXPR = "(CASE WHEN lower(substr(target, 1, 7)) = 'http://' OR lower(substr(target, 1, 8)) = 'https://' " \
               "THEN target ELSE (scheme || '://' || host || target) END)"

    # What one term compiles to: a SQL fragment plus the values bound into its `?`s.
    alias SqlTerm = {String, Array(DB::Any)}

    # One-page reference for MCP clients / models. Kept in sync with the parser above.
    REFERENCE = <<-DOC
      gori QL filters captured HTTP flows:

        host:example.com status:>=500 method:POST   # AND is implicit (whitespace)
        host:api AND status:5xx                     # ...and can also be spelled out
        host:api OR status:5xx                      # OR
        (host:a OR host:b) -method:GET              # parentheses group
        NOT (host:cdn OR host:static)               # NOT negates a term or a group
        host:"my host"  "two words"                 # quotes keep spaces in one term
        -host:cdn login                             # negation + free-text search

      AND/OR/NOT are recognised UPPERCASE and unquoted, so searching for the words
      and/or/not still works; quote them ("AND") to force a literal. Precedence is
      NOT > AND > OR. `-term` and `NOT term` are equivalent.

      Fields (use : for value match, ~ for regex):
        host path method scheme proto status size reqsize respsize dur header body url stub

      Comparisons (status size reqsize respsize dur):
        status:>=500  size:>10000  dur:>=500  dur:<2s  (dur defaults to ms; suffix ms|s)

      Status class shorthand: status:5xx  status:4xx

      Protocol: proto:ws  proto:grpc  proto:sse  proto:http  (ws = 101 upgrade; grpc/sse by Content-Type)

      Short-circuited: stub:true  stub:false  — flows gori answered ITSELF from a Match&Replace
      short-circuit rule, with NO origin involved. Their response bytes came from the rule, not
      from the server, so `stub:false` is what you want before treating History as evidence.

      Regex (~): host~^api\\.  body~secret\\d+  path~/admin

      body: SEARCHES AN INDEX, AND THE INDEX IS BOUNDED. `body:` reads a trigram index that
      covers only the FIRST 8 KiB of each side (request and response), and a body is not
      indexed at all when its Content-Type is binary or its Content-Encoding is compressed.
      So `body:` can return NOTHING for content that is genuinely there — deep in a large
      body, or in a gzipped/binary one. `body~regex` scans the stored bytes instead, with no
      cap and no content-type rule, so it is the one to reach for when `body:` comes back
      empty and you expected a hit. (`body:` is the fast path; `body~` is the complete one.)

      Free text (no field:): matches method, host, or target (case-insensitive substring).

      Invalid syntax (e.g. status:>=foo with no numeric value) is rejected — it does NOT match all flows.
      A mixed query (host:beta status:>=foo) silently drops only the bad comparison/field terms and
      applies the rest (a dropped term BROADENS the result). A dropped term is treated as if it were
      never typed, so inside NOT(...) or OR it can SHIFT what the query matches — e.g.
      `NOT (host:x AND size:>bogus)` becomes `NOT host:x` (excludes host x), not match-all. Note the
      further asymmetry with regex: an invalid `~` pattern is a HARD ERROR, not dropped — because a bad
      regex would otherwise silently match NOTHING (indistinguishable from a genuinely empty result),
      so it must be fixed or removed. Use strict:true (or ql_explain) to see exactly which terms were
      dropped before relying on results.
      DOC

    # A non-blank user query must compile to at least one clause. EMPTY means every
    # token was dropped (bad field, bad numeric, invalid regex) — matching all flows,
    # which is the opposite of what the caller asked for.
    def self.reject_empty?(query : String, filter : Filter) : Bool
      !query.strip.empty? && filter == EMPTY
    end

    # Combines two filters with AND (used to layer the Scope lens over a query).
    def self.and(a : Filter, b : Filter) : Filter
      return b if a.sql == "1"
      return a if b.sql == "1"
      Filter.new("(#{a.sql}) AND (#{b.sql})", a.args + b.args)
    end

    # Boolean structure (AND/OR/NOT, parentheses, quoting) comes from the shared
    # FilterAst grammar; QL only says what a single term compiles to. A term the
    # backend rejects (bad numeric, unknown proto) folds away, and a combinator left
    # with nothing folds away in turn — so a query whose every term was dropped
    # yields EMPTY, exactly as the old flat parser did.
    def self.parse(query : String) : Filter
      tree = FilterAst.build(FilterAst.parse(query)) { |t| term_to_sql(t) }
      return EMPTY unless tree
      args = [] of DB::Any
      Filter.new(wrap_sql(tree, args), args)
    end

    # A bare leaf/negation is parenthesised at the top so the fragment is always safe
    # to splice after "WHERE " and to AND with the Scope lens (QL.and).
    private def self.wrap_sql(tree : FilterAst::Tree(SqlTerm), args : Array(DB::Any)) : String
      sql = tree_sql(tree, args)
      tree.op.and? || tree.op.or? ? sql : "(#{sql})"
    end

    # Depth-first, left to right — `args` MUST be appended in the same order the `?`
    # placeholders are emitted, or every bound value shifts by one.
    private def self.tree_sql(tree : FilterAst::Tree(SqlTerm), args : Array(DB::Any)) : String
      case tree.op
      in .leaf?
        cond, cargs = tree.leaf
        args.concat(cargs)
        cond
      in .not? then "NOT (#{tree_sql(tree.children.first, args)})"
      in .and? then "(#{tree.children.map { |c| tree_sql(c, args) }.join(" AND ")})"
      in .or?  then "(#{tree.children.map { |c| tree_sql(c, args) }.join(" OR ")})"
      end
    end

    # A `~` (regex) term whose pattern fails to compile silently degrades to a
    # never-match "0" SQL clause inside term_to_sql/regex_cond (see there) — unlike
    # a bad numeric term (status:>=foo), which is simply DROPPED and lets the rest
    # of the query stand. That asymmetry means a query like `body~[bad` can zero
    # out an entire result set with exit 0 and no diagnostic. This surfaces those
    # terms so a caller can warn without changing match behaviour. Mirrors the
    # exact tokenization term_to_sql/regex_cond use, so it flags precisely the
    # terms that would compile to the never-match clause — no more, no less.
    def self.invalid_regex_terms(query : String) : Array(String)
      bad = [] of String
      FilterAst.terms(FilterAst.parse(query)).each do |term|
        field, value, op = split_field(term.text) || next
        next unless op == :regex && field.in?(REGEX_FIELDS)
        next if value.empty?
        bad << term.source unless valid_regex?(value)
      end
      bad
    end

    # Per-term diagnosis of a query for the MCP `ql_explain` tool and strict mode.
    # `applied` compiled to a real clause; `ignored` compiled to nothing and was
    # silently DROPPED (bad numeric/proto/empty → broadens the result); `invalid_regex`
    # compiled to a never-match clause (narrows to empty). Mirrors parse's tokenization.
    record TermAnalysis, applied : Array(String), ignored : Array(String), invalid_regex : Array(String) do
      def clean? : Bool
        ignored.empty? && invalid_regex.empty?
      end
    end

    def self.analyze(query : String) : TermAnalysis
      applied = [] of String
      ignored = [] of String
      FilterAst.terms(FilterAst.parse(query)).each do |term|
        (term_to_sql(term) ? applied : ignored) << term.source
      end
      TermAnalysis.new(applied, ignored, invalid_regex_terms(query))
    end

    REGEX_FIELDS = %w[host path url header body]

    # The field/operator split, shared by compilation and diagnosis so the two can't
    # disagree about what counts as a term. The first ':' (field op) or '~' (regex op)
    # wins — whichever appears first — so a regex value may itself contain ':' (e.g.
    # body~https?://x). nil means free text: no separator, or a leading one (`:foo`).
    private def self.split_field(text : String) : {String, String, Symbol}?
      ci = text.index(':')
      ti = text.index('~')
      sep = [ci, ti].compact.min?
      return nil unless sep && sep > 0
      {text[0...sep].downcase, text[(sep + 1)..], ti == sep ? :regex : :field}
    end

    # `term.text` arrives already stripped of its quotes and `-` prefix by the grammar;
    # the negation rides on `term.negate?` and wraps whatever the field compiled to.
    private def self.term_to_sql(term : FilterAst::Term) : SqlTerm?
      text = term.text
      return nil if text.empty?

      result =
        if split = split_field(text)
          field, value, op = split
          op == :regex ? regex_cond(field, value, text) : field_cond(field, value, text)
        else
          free_text(text)
        end
      return nil unless result

      cond, args = result
      {term.negate? ? "NOT (#{cond})" : cond, args}
    end

    private def self.field_cond(field : String, value : String, term : String) : {String, Array(DB::Any)}?
      return nil if value.empty?
      case field
      when "host"                        then {"lower(host) LIKE ? ESCAPE '\\'", [like(value)] of DB::Any}
      when "url"                         then {"#{URL_EXPR} LIKE ? ESCAPE '\\'", [like(value)] of DB::Any}
      when "path"                        then {"lower(target) LIKE ? ESCAPE '\\'", [like(value)] of DB::Any}
      when "method"                      then {"upper(method) = ?", [value.upcase] of DB::Any}
      when "scheme"                      then {"scheme = ?", [value.downcase] of DB::Any}
      when "proto"                       then proto_cond(value)
      when "status"                      then status_cond(value)
      when "size", "reqsize", "respsize" then size_cond(field, value)
      when "dur"                         then duration_cond(value)
      when "header"                      then header_cond(value)
      when "body"                        then body_cond(value)
      when "stub"                        then stub_cond(value)
      else
        # Unknown field — a typo (`hosst:x`) or a literal colon in a value (`time:12:00`):
        # free-text the WHOLE token (prefix included), not just the part after the ':'. This
        # mirrors regex_cond's fallback, searches what the user actually typed, and makes a
        # typo'd field self-evident (it matches nothing real) instead of silently searching
        # only the value. NOTE: `flag:` lands here too — gori has no flow-flag store yet
        # (Store#flags_for is a stub), so there is nothing to match; it free-texts like any
        # other unknown field rather than advertising an unimplemented filter.
        free_text(term)
      end
    end

    # stub: selects flows gori ANSWERED ITSELF from a short-circuit rule (#511) — the ones no
    # origin ever saw. `stub:true` isolates them for review; `stub:false` is the one an
    # operator actually reaches for, to read History as traffic that really happened before
    # writing anything up. The column is NOT NULL DEFAULT 0, so both directions are NULL-free
    # and `-stub:true` behaves exactly like `stub:false`. An unrecognised value drops the term
    # rather than guessing, same as a bad proto:/status:.
    private def self.stub_cond(value : String) : {String, Array(DB::Any)}?
      no_args = [] of DB::Any
      case value.downcase
      when "true", "yes", "on", "1"  then {"short_circuited = 1", no_args}
      when "false", "no", "off", "0" then {"short_circuited = 0", no_args}
      end
    end

    # proto: classifies a flow by application protocol with no column of its OWN —
    # WS is the 101 upgrade handshake, gRPC is read off EITHER side's Content-Type, SSE off
    # the response's, and http is everything else. Mirrors Gori::Proto.classify (the
    # render-side source of truth). The LIKE patterns are constant literals (no user
    # data), so they are inlined; the gRPC/SSE clauses carry an explicit NOT-NULL
    # guard so `http` can negate them NULL-safely — a pending/typeless flow (NULL
    # content_type) counts as http, and `-proto:grpc` correctly keeps it. An
    # unknown value (proto:foo) drops the term, like a bad status: (never matches
    # all). `websocket` is an alias for `ws`, and `wss`/`grpcs`/`sses`/`https` add the
    # transport the operator named — the spellings the PROTO column prints.
    # BOTH sides: gRPC is a content type the request sends too, and a call answered with a
    # proxy's `text/html` 502 — or not answered at all — is still a gRPC call. Matches
    # `Proto.classify`'s own two-sided test; `request_content_type` is NULL on a row captured
    # before the V14 column, which the NOT-NULL guard makes a clean no-match (so `-proto:grpc`
    # keeps it, as it always did).
    GRPC_SQL = "((content_type IS NOT NULL AND lower(content_type) LIKE 'application/grpc%') OR " \
               "(request_content_type IS NOT NULL AND lower(request_content_type) LIKE 'application/grpc%'))"
    SSE_SQL = "(content_type IS NOT NULL AND lower(content_type) LIKE 'text/event-stream%')"

    private def self.proto_cond(value : String) : {String, Array(DB::Any)}?
      # The TLS spellings the History PROTO column prints (`WSS`/`GRPCS`/`SSES`/`HTTPS`) are
      # accepted and mean what the column means: the application protocol AND the transport.
      # Without the second half `proto:wss` would quietly return the cleartext rows too —
      # the exact signal the column was changed to stop dropping.
      base, secure = Proto.split_transport(value)
      no_args = [] of DB::Any
      sql = case Proto::Kind.parse?(base)
            in Proto::Kind::Ws   then "status = 101"
            in Proto::Kind::Grpc then GRPC_SQL
            in Proto::Kind::Sse  then SSE_SQL
            in Proto::Kind::Http then "(status IS NULL OR status <> 101) AND NOT #{GRPC_SQL} AND NOT #{SSE_SQL}"
            in nil               then return nil
            end
      secure.nil? ? {sql, no_args} : {"(#{sql}) AND scheme = 'https'", no_args}
    end

    # size: → the TOTAL bytes (request + response), so it matches the displayed/JSON
    # `size`; reqsize:/respsize: target a single side. A NULL response_size (pending
    # flow) never matches respsize:, while size:/reqsize: fall back on the request bytes.
    private def self.size_cond(field : String, value : String) : {String, Array(DB::Any)}?
      column = case field
               when "reqsize"  then "request_size"
               when "respsize" then "response_size"
               else                 "(request_size + COALESCE(response_size, 0))"
               end
      numeric_cond(column, value)
    end

    # Body search uses the trigram FTS index over request/response body text —
    # case-insensitive SUBSTRING matching (so `body:token` still finds "mytokenvalue"),
    # indexed instead of scanning every BLOB. NOT the same result set as the old LIKE
    # scan, and `REFERENCE` now says so: the index covers only the first
    # `Store::FTS_INDEX_MAX` bytes per side and skips binary/compressed bodies, so
    # `body:` can miss content `body~` finds. The value is passed as a quoted FTS phrase (embedded
    # quotes doubled) so arbitrary characters can't form FTS operator syntax. A
    # bodyless flow has an empty FTS row, so it never matches and `-body:x`
    # correctly KEEPS it. The trigram index needs >=3 characters, so shorter
    # values fall back to the NULL-safe BLOB LIKE scan.
    private def self.body_cond(value : String) : {String, Array(DB::Any)}?
      value = value.chars.reject(&.control?).join # strip NUL/control chars (FTS/LIKE safety)
      # `field_cond`'s `return nil if value.empty?` runs BEFORE this strip, so a value made
      # only of control bytes survived that guard and arrived here as "". `like("")` is
      # `'%%'`, which matches EVERY flow with a body — and `-body:` then excluded every flow
      # with one. That is the silent-BROADEN direction, the one `filter_ast.cr` calls the
      # dangerous one, and `QL.analyze` reported the query clean so `strict:` never saw it.
      # Dropping the term is what `body:` (genuinely empty) already does; this makes the two
      # spellings agree.
      return nil if value.empty?
      if value.size < 3
        # BYTE-wise, not `CAST(... AS TEXT)`: SQLite truncates a BLOB→TEXT cast at the first
        # NUL, so the LIKE fallback stopped scanning there and a body of
        # `head\0NULNEEDLE tail` was invisible to `body:nu` while `body:NULNEEDLE` (the FTS
        # path, >=3 chars) found it. A SHORTER needle matching FEWER rows is a monotonicity
        # violation that cannot be explained to an operator, and this is a tool whose targets
        # deliberately put NULs in bodies. `instr` over the raw BLOB is NUL-transparent.
        #
        # `instr` is case-SENSITIVE while `body:` promises case-insensitive substring matching,
        # so match every case permutation of the needle instead — at most four, since this
        # branch only runs for one or two characters.
        # `COALESCE`-wrapped, and that is load-bearing: a NULL body (a bodyless GET, or any
        # response-less/in-flight flow — the common case) makes `instr(NULL, …)` NULL, and
        # `NOT (NULL > 0)` is NULL, which SQLite's three-valued logic then EXCLUDES — so a bare
        # `instr` made `-body:x` silently drop every bodyless flow (a silent NARROW, the mirror
        # of the broaden this path guards against). `COALESCE(…, 0) > 0` is FALSE for a NULL
        # body, so the positive term still skips it and `NOT FALSE` keeps it under negation.
        conds = [] of String
        params = [] of DB::Any
        case_permutations(value).each do |v|
          conds << "COALESCE(instr(request_body, CAST(? AS BLOB)), 0) > 0"
          conds << "COALESCE(instr(response_body, CAST(? AS BLOB)), 0) > 0"
          params << v << v
        end
        return {"(#{conds.join(" OR ")})", params}
      end
      phrase = %("#{value.gsub('"', "\"\"")}") # quoted phrase → contiguous substring match
      {"id IN (SELECT rowid FROM flows_fts WHERE flows_fts MATCH ?)", [phrase] of DB::Any}
    end

    # Every upper/lower spelling of a one- or two-character needle, so a byte-wise `instr`
    # can stand in for a case-insensitive LIKE. Bounded at 4 by `body_cond`'s `size < 3`
    # guard; a character with no case (a digit, a symbol, most CJK) contributes one variant.
    private def self.case_permutations(value : String) : Array(String)
      value.each_char.reduce([""]) do |acc, ch|
        forms = [ch.downcase, ch.upcase].uniq!
        acc.flat_map { |prefix| forms.map { |f| prefix + f } }
      end.uniq!
    end

    # Split a leading comparison operator (<= >= < > =, default =) off a value. Shared
    # by status:, size:, dur: so the operator parsing lives in exactly one place.
    private def self.split_op(value : String) : {String, String}
      {"<=", ">=", "<", ">", "="}.each do |o|
        return {o, value[o.size..]} if value.starts_with?(o)
      end
      {"=", value}
    end

    private def self.status_cond(value : String) : {String, Array(DB::Any)}?
      op, rest = split_op(value)

      # status class: 2xx / 4xx / 5xx — honour any comparison operator against the
      # class bounds (e.g. status:>=5xx → status >= 500; bare status:4xx → 400-499).
      if rest.size == 3 && rest[1] == 'x' && rest[2] == 'x' && rest[0].ascii_number?
        base = rest[0].to_i * 100
        case op
        when ">=" then return {"status >= ?", [base] of DB::Any}
        when ">"  then return {"status >= ?", [base + 100] of DB::Any}
        when "<=" then return {"status < ?", [base + 100] of DB::Any}
        when "<"  then return {"status < ?", [base] of DB::Any}
        else           return {"(status >= ? AND status < ?)", [base, base + 100] of DB::Any}
        end
      end

      n = rest.to_i?
      return nil unless n
      {"status #{op} ?", [n] of DB::Any}
    end

    # Numeric comparison on an INTEGER column/expression. `size:` uses the total
    # (request_size + COALESCE(response_size, 0)) so it matches the displayed/JSON
    # `size`; `reqsize:`/`respsize:` target one side. A NULL column (e.g. respsize:
    # on a pending flow) never satisfies `col <op> ?`, so such rows fall out of both
    # the positive and negated form. Non-numeric values yield nil (the term is
    # dropped, like a bad status:).
    private def self.numeric_cond(column : String, value : String) : {String, Array(DB::Any)}?
      op, rest = split_op(value)
      scale = 1.0
      lower_rest = rest.downcase
      if lower_rest.ends_with?("kb")
        rest = rest[0...-2]
        scale = 1024.0
      elsif lower_rest.ends_with?('k')
        rest = rest[0...-1]
        scale = 1024.0
      elsif lower_rest.ends_with?("mb")
        rest = rest[0...-2]
        scale = 1024.0 * 1024.0
      elsif lower_rest.ends_with?('m')
        rest = rest[0...-1]
        scale = 1024.0 * 1024.0
      elsif lower_rest.ends_with?("gb")
        rest = rest[0...-2]
        scale = 1024.0 * 1024.0 * 1024.0
      elsif lower_rest.ends_with?('g')
        rest = rest[0...-1]
        scale = 1024.0 * 1024.0 * 1024.0
      elsif lower_rest.ends_with?('b')
        rest = rest[0...-1]
      end
      n = rest.to_f?
      return nil unless n && n.finite?
      bytes = (n * scale).round
      return nil unless bytes.abs < 9.0e18
      {"#{column} #{op} ?", [bytes.to_i64] of DB::Any}
    end

    # dur: is milliseconds (how latency reads), compared against the microsecond
    # `duration_us`. A trailing `ms` (×1000) or `s` (×1_000_000) overrides the default
    # ms scale; the magnitude is parsed as a float so `dur:>1.5s` works. NULL duration
    # (no response yet) never matches, same as size:.
    private def self.duration_cond(value : String) : {String, Array(DB::Any)}?
      op, rest = split_op(value)
      scale_us = 1000.0 # ms → µs (default)
      # Match the unit suffix case-insensitively, mirroring numeric_cond's kb/mb/… handling,
      # so `dur:>2S` / `dur:>=500MS` parse like their lowercase forms instead of silently
      # dropping the term (the numeric part carries no letters, so stripping from `rest`
      # keeps `to_f?` happy).
      lower_rest = rest.downcase
      if lower_rest.ends_with?("ms")
        rest = rest[0...-2]
      elsif lower_rest.ends_with?('s')
        rest = rest[0...-1]
        scale_us = 1_000_000.0
      end
      n = rest.to_f?
      return nil unless n && n.finite?
      us = (n * scale_us).round
      # Drop an absurd magnitude rather than let Float#to_i64 raise OverflowError out of
      # QL.parse (a crash on a single TUI keystroke); size: drops the same way via
      # to_i64?. 9e18 is safely inside Int64 and astronomically beyond any real latency.
      return nil unless us.abs < 9.0e18
      {"duration_us #{op} ?", [us.to_i64] of DB::Any}
    end

    # header: substring-matches the raw request/response head bytes (request line /
    # status line + header lines), case-insensitively — same shape as body:. It scans
    # the whole head, so it also sees the request/status line (rare false hit; fine).
    # request_head is NOT NULL; response_head is guarded so a response-less flow
    # contributes no match (and `-header:x` correctly keeps it).
    #
    # BYTE-wise, not `CAST(... AS TEXT) LIKE`: SQLite truncates a BLOB→TEXT cast at the
    # first NUL, so a head that stored an embedded NUL (header-injection / smuggling
    # cases — the codec keeps the octets, P7) made every header after the NUL invisible
    # to `header:` while `header~` (SafeRegexp over the full blob) still found it. Same
    # trap `body_cond` already routed around. `instr` is case-SENSITIVE, so OR every case
    # permutation of a short needle; longer needles go through a case-insensitive literal
    # REGEXP, which SafeRegexp already makes NUL-transparent.
    private def self.header_cond(value : String) : {String, Array(DB::Any)}?
      value = value.chars.reject(&.control?).join
      return nil if value.empty?
      if value.size < 3
        conds = [] of String
        params = [] of DB::Any
        case_permutations(value).each do |v|
          conds << "COALESCE(instr(request_head, CAST(? AS BLOB)), 0) > 0"
          conds << "COALESCE(instr(response_head, CAST(? AS BLOB)), 0) > 0"
          params << v << v
        end
        return {"(#{conds.join(" OR ")})", params}
      end
      pat = "(?i)#{Regex.escape(value)}"
      return {"0", [] of DB::Any} unless valid_regex?(pat)
      header_regex_cond(pat)
    end

    # The `~` operator: case-sensitive regex (SQLite REGEXP, the same shard-provided
    # function Scope's regex rules use, backed by Crystal Regex) over a text field —
    # host/path/url/header/body. Any other field falls back to a literal free-text
    # search of the whole token. An invalid pattern would raise inside the SQLite
    # REGEXP callback, so we validate up front and emit a never-matches clause instead.
    # For case-insensitive matching use an inline (?i) flag.
    private def self.regex_cond(field : String, value : String, term : String) : {String, Array(DB::Any)}?
      # A non-regex field name means `~` wasn't a regex operator here (e.g. `foo~bar`):
      # fall back to a literal free-text search of the WHOLE token. This must happen BEFORE
      # the validity guard — otherwise `foo~[` (an unterminated char class) would compile to
      # the never-match clause instead of free-texting "foo~[".
      case field
      when "host", "path", "url", "header", "body" # = REGEX_FIELDS
        return nil if value.empty?
        # An invalid pattern would raise inside the SQLite REGEXP callback, so validate up
        # front and emit a never-matches clause instead.
        return {"0", [] of DB::Any} unless valid_regex?(value)
        case field
        when "host"   then {"host REGEXP ?", [value] of DB::Any}
        when "path"   then {"target REGEXP ?", [value] of DB::Any}
        when "url"    then {"#{URL_EXPR} REGEXP ?", [value] of DB::Any}
        when "header" then header_regex_cond(value)
        else               body_regex_cond(value)
        end
      else
        free_text(term)
      end
    end

    # NULL-guarded REGEXP over both body columns (a bodyless flow contributes no match,
    # so `-body~x` keeps it — same null-safety as the body: LIKE fallback above).
    private def self.body_regex_cond(value : String) : {String, Array(DB::Any)}
      {"((request_body IS NOT NULL AND CAST(request_body AS TEXT) REGEXP ?) OR " \
       "(response_body IS NOT NULL AND CAST(response_body AS TEXT) REGEXP ?))",
       [value, value] of DB::Any}
    end

    private def self.header_regex_cond(value : String) : {String, Array(DB::Any)}
      {"(CAST(request_head AS TEXT) REGEXP ? OR " \
       "(response_head IS NOT NULL AND CAST(response_head AS TEXT) REGEXP ?))",
       [value, value] of DB::Any}
    end

    # A pattern must compile or the SQLite REGEXP callback raises (mirrors Scope.valid?).
    private def self.valid_regex?(pattern : String) : Bool
      Regex.new(pattern)
      true
    rescue
      false
    end

    private def self.free_text(word : String) : {String, Array(DB::Any)}
      pattern = like(word)
      {"(lower(method) LIKE ? ESCAPE '\\' OR lower(host) LIKE ? ESCAPE '\\' OR lower(target) LIKE ? ESCAPE '\\')",
       [pattern, pattern, pattern] of DB::Any}
    end

    # Build a LIKE pattern, neutralising the LIKE metacharacters % and _ (and the
    # escape char itself) so a user's literal % / _ matches literally. Pair every
    # use with `ESCAPE '\'` in the SQL. Backslash MUST be escaped first. Public so
    # Scope's string-match rules reuse the one escaper (no second hand-rolled copy).
    def self.like(value : String) : DB::Any
      "%#{like_escape(value.downcase)}%"
    end

    # Neutralise LIKE metacharacters (% _ \) in `value` WITHOUT the surrounding `%`,
    # for callers that splice it into a larger LIKE pattern (e.g. Scope's `%.<host>`
    # subdomain match). Pair with `ESCAPE '\'`. Caller lowercases if it wants ci.
    def self.like_escape(value : String) : String
      value.gsub('\\', "\\\\").gsub('%', "\\%").gsub('_', "\\_")
    end
  end
end
