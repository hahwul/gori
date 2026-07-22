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
        host path method scheme proto status size reqsize respsize dur header body url

      Comparisons (status size reqsize respsize dur):
        status:>=500  size:>10000  dur:>=500  dur:<2s  (dur defaults to ms; suffix ms|s)

      Status class shorthand: status:5xx  status:4xx

      Protocol: proto:ws  proto:grpc  proto:sse  proto:http  (ws = 101 upgrade; grpc/sse by Content-Type)

      Regex (~): host~^api\\.  body~secret\\d+  path~/admin

      Free text (no field:): matches method, host, or target (case-insensitive substring).

      Invalid syntax (e.g. status:>=foo with no numeric value) is rejected — it does NOT match all flows.
      A mixed query (host:beta status:>=foo) silently drops only the bad terms and applies the rest.
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

    REGEX_FIELDS = %w(host path url header body)

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

    # proto: classifies a flow by application protocol WITHOUT a stored column —
    # WS is the 101 upgrade handshake, gRPC/SSE are read off the response
    # Content-Type, and http is everything else. Mirrors Gori::Proto.classify (the
    # render-side source of truth). The LIKE patterns are constant literals (no user
    # data), so they are inlined; the gRPC/SSE clauses carry an explicit NOT-NULL
    # guard so `http` can negate them NULL-safely — a pending/typeless flow (NULL
    # content_type) counts as http, and `-proto:grpc` correctly keeps it. An
    # unknown value (proto:foo) drops the term, like a bad status: (never matches
    # all). `websocket` is an alias for `ws`.
    GRPC_SQL = "(content_type IS NOT NULL AND lower(content_type) LIKE 'application/grpc%')"
    SSE_SQL  = "(content_type IS NOT NULL AND lower(content_type) LIKE 'text/event-stream%')"

    private def self.proto_cond(value : String) : {String, Array(DB::Any)}?
      no_args = [] of DB::Any
      case Proto::Kind.parse?(value)
      in Proto::Kind::Ws   then {"status = 101", no_args}
      in Proto::Kind::Grpc then {GRPC_SQL, no_args}
      in Proto::Kind::Sse  then {SSE_SQL, no_args}
      in Proto::Kind::Http then {"(status IS NULL OR status <> 101) AND NOT #{GRPC_SQL} AND NOT #{SSE_SQL}", no_args}
      in nil               then nil
      end
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
    # case-insensitive SUBSTRING matching (same semantics as the old `body:` LIKE,
    # so `body:token` still finds "mytokenvalue"), just indexed instead of
    # scanning every BLOB. The value is passed as a quoted FTS phrase (embedded
    # quotes doubled) so arbitrary characters can't form FTS operator syntax. A
    # bodyless flow has an empty FTS row, so it never matches and `-body:x`
    # correctly KEEPS it. The trigram index needs >=3 characters, so shorter
    # values fall back to the NULL-safe BLOB LIKE scan.
    private def self.body_cond(value : String) : {String, Array(DB::Any)}
      value = value.chars.reject(&.control?).join # strip NUL/control chars (FTS/LIKE safety)
      if value.size < 3
        p = like(value)
        return {"((request_body IS NOT NULL AND lower(CAST(request_body AS TEXT)) LIKE ? ESCAPE '\\') OR " \
                "(response_body IS NOT NULL AND lower(CAST(response_body AS TEXT)) LIKE ? ESCAPE '\\'))",
                [p, p] of DB::Any}
      end
      phrase = %("#{value.gsub('"', "\"\"")}") # quoted phrase → contiguous substring match
      {"id IN (SELECT rowid FROM flows_fts WHERE flows_fts MATCH ?)", [phrase] of DB::Any}
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
      if rest.ends_with?("ms")
        rest = rest[0...-2]
      elsif rest.ends_with?('s')
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
    private def self.header_cond(value : String) : {String, Array(DB::Any)}
      p = like(value)
      {"(lower(CAST(request_head AS TEXT)) LIKE ? ESCAPE '\\' OR " \
       "(response_head IS NOT NULL AND lower(CAST(response_head AS TEXT)) LIKE ? ESCAPE '\\'))",
       [p, p] of DB::Any}
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
