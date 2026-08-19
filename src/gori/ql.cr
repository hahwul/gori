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
    # `:` fields:  see FIELDS below (the list every surface reads).
    # `~` regex on: host path url header body   (+ bare words = free text).
    # Comparison ops (<= >= < > =) apply to status/size/reqsize/respsize/dur.
    #
    # QL is not only History's: a Colormarker rule's condition is a QL string too, matched
    # against the flow it would paint (see `Colormarker`). `InterceptFilter` — the hold gate and
    # extract-rule condition — speaks the same grammar over the SUBSET of fields a live,
    # uncaptured message can answer. One language, three surfaces, no dialects.
    struct Filter
      getter sql : String # safe to splice into "WHERE ..."; values are in `args`
      getter args : Array(DB::Any)

      def initialize(@sql : String, @args : Array(DB::Any))
      end

      # Does answering this filter read the trigram index? `body:` is the only term that
      # compiles to a `flows_fts` subquery — and only when compiled with `fts: true`, the
      # default (see `body_cond`) — and nothing else mentions that table, so matching the name
      # is exact rather than heuristic. (Free text does NOT: it compiles to a substring test
      # over method/host/target. This comment claimed otherwise for a while; the test was
      # always right and only its explanation was wrong.)
      # Callers use it to decide whether a stale index would corrupt their answer:
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

      Sides: header: and body: search the REQUEST AND THE RESPONSE. Prefix either with `req.` or
      `resp.` to search one side — req.body:token resp.header:set-cookie resp.body~secret\\d+ —
      and negate as usual (-resp.body:abcd). `res.` is accepted as a synonym of `resp.`, and
      req.size/resp.size are synonyms of reqsize/respsize. Fields that only ever have one side
      (host, method, status, …) take no prefix.

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
      empty and you expected a hit. (`body:` is the fast path; `body~` is the more complete one.)

      NEITHER READS A COMPRESSED BODY. gori stores the WIRE form (DESIGN.md P7) and decompresses
      only at display time, so `body:` skips a gzip/br/zstd body at index time and `body~` regexes
      the compressed bytes. Most real response bodies are compressed, which matters most under
      NEGATION: `-body:secret` and `-body~secret` both KEEP every compressed response, so a query
      that comes back "clean" has not actually looked. Decode-aware matching lives on the Probe
      custom rules (side/region + Content-Encoding decode), not here.
      A COLOUR RULE's `body:` is the complete one: a rule has to paint the row that just
      arrived, and the index lags capture, so create_color_rule scans the bytes instead. Same
      language, one deliberate difference — a colour rule can paint what this query misses.

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
    # `fts: false` compiles `body:` to the BLOB scan instead of the trigram-index subquery —
    # everything else is bit-for-bit the same query. It exists for a caller that cannot tolerate
    # the index's LAG rather than one that dislikes its bounds: indexing is off-commit (Store V4),
    # so the row captured a moment ago has no `flows_fts` row yet. A one-shot surface drains the
    # backlog first (`Store#index_pending!`) and a live one reports it (`Store#fts_backlog`), but
    # Colormarker can do neither — it answers "paint this row?" on the render path, for a row that
    # is often SECONDS old, and a colour that arrives whenever the indexer catches up is worse than
    # one computed the slow way. The scan reads the same bytes `body~` does, so `body:` here is
    # `body~` with a literal needle: no 8 KiB bound and no text-only rule. See `body_cond`.
    # `body_max` bounds how many BYTES of each side's body a `body:`/`body~` term reads, by
    # compiling the column as `substr(col, 1, N)`. nil (the default) reads all of it. It exists
    # for a caller on an INTERACTIVE path: a body is capped at capture time by
    # `Settings.capture_max` (2 MiB by default, and raisable), so an uncapped scan of one
    # screenful of cap-sized bodies measures ~460 ms — a visible stall, per screen, on the list
    # a proxy scrolls all day. `Rules::RULE_PREVIEW_BODY_MAX` made the identical trade for the
    # Rewriter's preview, and states the identical consequence: a match past the cap is missed.
    # Heads are NOT capped — a head is bounded by the codec long before it reaches here.
    def self.parse(query : String, *, fts : Bool = true, body_max : Int32? = nil) : Filter
      tree = FilterAst.build(FilterAst.parse(query)) { |t| term_to_sql(t, fts, body_max) }
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
        next unless op == :regex && canonical(field).in?(REGEX_FIELDS)
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

    # Every field `field_cond` implements, in the order the reference lists them. THE list:
    # History's and Colormarker's completion pools, Colormarker's unknown-field refusal and the
    # docs all read it, so a field added to `field_cond` becomes offerable everywhere at once
    # instead of in the four hand-kept copies that used to drift.
    FIELDS = %w[host path url method scheme proto status size reqsize respsize dur header body stub
      req.header resp.header req.body resp.body]

    REGEX_FIELDS = %w[host path url header body req.header resp.header req.body resp.body]

    # A `req.`/`resp.` prefix picks ONE SIDE of a field that has two. `header:`/`body:` search the
    # request AND the response, which is right for "find this string anywhere" and useless for the
    # question an operator actually asks more often — did the SERVER send it? There was no way to
    # say that at all: `size` was the only field with a side split, and it got one by growing two
    # hand-written twins (`reqsize`/`respsize`) rather than a rule.
    #
    # The prefix is that rule, and it is deliberately spelled INSIDE the existing `field:value`
    # token instead of as new grammar: `split_field` cuts at the first `:`/`~`, so `resp.body`
    # arrives as an ordinary field name and the lexer, the parser, the syntax highlighting and
    # Tab-completion all keep working untouched — `-resp.body:x` negates and `NOT (req.body:a OR
    # resp.body:b)` groups exactly as they did before. The alternative (a Caido-style
    # `resp.body.cont:"x"` grammar) would have bought the same expressiveness for a new operator
    # vocabulary, the loss of boolean NOT, and a migration of every rule string already stored in
    # `colormarker_rules.match_filter`.
    #
    # `res.` is accepted alongside `resp.` because the coin-flip between them fails SILENTLY:
    # an unknown field free-texts the WHOLE token (see `field_cond`'s else), so `res.body:secret`
    # returns nothing and reads as "no flow has that" rather than "you spelled the prefix the
    # other way". Completion offers `resp.` only, so there is still one spelling to learn.
    SIDES = {"req." => :req, "resp." => :resp, "res." => :resp}

    # Spellings QL ACCEPTS but does not OFFER. Two groups, one reason each:
    #
    #   `res.*`      the `resp.` coin-flip above.
    #   `req.size`   the namespace has to be uniform or it is a trap: someone who learns
    #   `resp.size`  `resp.body` will try `resp.size`, and the honest answer is that it already
    #                exists under an older name. Aliasing costs one line; letting it free-text
    #                costs a query that silently matches nothing.
    #
    # Kept OUT of `FIELDS` so the completion pool stays one name per concept, and read through
    # `known_field?` so a surface that VALIDATES fields (Colormarker's unknown-field refusal)
    # cannot start rejecting a spelling that `field_cond` happily compiles.
    FIELD_ALIASES = {
      "res.header" => "resp.header", "res.body" => "resp.body",
      "req.size" => "reqsize", "resp.size" => "respsize", "res.size" => "respsize",
    }

    # Does QL implement this field name? THE membership test — `FIELDS` alone is the pool a
    # surface OFFERS, which is a strict subset of what it accepts.
    def self.known_field?(name : String) : Bool
      FIELDS.includes?(name) || FIELD_ALIASES.has_key?(name)
    end

    # One line per field, for the surfaces that TEACH this language rather than parse it — the
    # completion row's description column and Help's Query page. Both used to be prose written
    # by hand next to the widget, which is why `FILTER_HINT` and `QUERY_HINT` disagreed with each
    # other and with `FIELDS` about what exists; a field is only really added when the thing that
    # EXPLAINS it is added too, so the explanation lives beside the parser.
    #
    # Kept short on purpose: it renders in one terminal column beside a field name, so anything
    # past ~46 characters is truncated rather than wrapped. Where a field has a bound that will
    # bite (the `body:` index, `path:` including the query string), the line spends its budget
    # naming the bound rather than restating the field name.
    FIELD_HELP = {
      "host"        => "server host — substring; host~ for regex",
      "path"        => "path AND query string — substring",
      "url"         => "scheme://host + path — substring",
      "method"      => "exact method — GET POST PUT …",
      "scheme"      => "exact — http or https",
      "proto"       => "ws grpc sse http (+s = over TLS)",
      "status"      => "code; classes (5xx) and >= <= compare",
      "size"        => "request + response bytes — >10k <1M",
      "reqsize"     => "request bytes only",
      "respsize"    => "response bytes only",
      "dur"         => "latency; ms unless suffixed — dur:>1.5s",
      "header"      => "head bytes, BOTH sides — see req./resp.",
      "body"        => "body via index: 8 KiB/side, no compressed",
      "stub"        => "true = gori answered it, origin never saw it",
      "req.header"  => "request head bytes only",
      "resp.header" => "response head bytes only",
      "req.body"    => "request body only",
      "resp.body"   => "response body only",
    }

    # The fields the one-line hints SAMPLE, in the order that reads best on a bar. A hint gets one
    # terminal row and `FIELDS` has eighteen entries, so something has to choose; choosing once
    # here — with a spec pinning every entry against `FIELDS` — beats each widget choosing for
    # itself in prose, which is exactly how three hint strings came to disagree about what exists.
    # `resp.body` earns its slot because a prefix nobody has seen cannot be guessed, where `host:`
    # would be typed by someone who never read a hint at all.
    # Six, not eight, and that ceiling is load-bearing: a hint is ONE row, and it has to fit the
    # field sample AND the operator tail inside 80 columns or the tail — the half a completion
    # pool can never teach — is what the terminal truncates away. Six chips leaves room for
    # `-term excludes` to survive the cut; the full list lives in Help's Query page.
    #
    # Ordered so a narrow surface sheds the GUESSABLE names first (`QuerySuggest.cold_hint` shrinks
    # the sample from the tail): `resp.body` sits third because a prefix nobody has seen cannot be
    # guessed, where `host:` gets typed by someone who never read a hint at all.
    HINT_FIELDS = %w[host path resp.body status method header]

    # `FIELD_HELP` for a name as the user spelled it (aliases inherit their canonical entry).
    def self.field_help(name : String) : String?
      FIELD_HELP[canonical(name)]?
    end

    # The places this language does something an operator would not predict. Every one of these
    # is a way a query can look CLEAN while not having looked — the direction that matters on a
    # security proxy, and the direction a field list can never warn about. They live here, beside
    # the code that causes them, and Help's Query page renders them verbatim.
    CAVEATS = [
      {"compressed bodies", "body: skips them, body~ reads the gzip — neither matches"},
      {"-body: on a big body", "the index stops at 8 KiB/side, so it KEEPS a deep hit"},
      {"path: vs the query string", "path: matches both, so -path:x drops ?q=x too"},
      {"-status: -dur: -respsize:", "a pending flow has NULL there and falls out of both"},
      {"a dropped term broadens", "status:>=foo is ignored, not refused — use ql_explain"},
      {"a bad regex matches nothing", "body~[ is a HARD error, never silently dropped"},
    ]

    # The grammar itself — everything that is NOT a field name, as {what you type, what it does}.
    # The one place an operator can learn that `-` negates, since a field-name completion pool can
    # never show it. Read by Help's Query page, so it cannot drift from the parser the way the
    # hand-written hint strings did.
    SYNTAX_HELP = [
      {"host:acme status:5xx", "space = AND (both must hold)"},
      {"host:a OR host:b", "OR; NOT > AND > OR, ( ) to group"},
      {"-path:/static", "leading - excludes — so does NOT path:/static"},
      {"NOT (host:cdn OR host:img)", "NOT negates a whole group"},
      {"body~secret\\d+", "~ is regex; : is plain substring"},
      {"status:>=500 dur:>1.5s", ">= <= > < = on status size dur"},
      {"resp.body:token", "req. / resp. picks one side of body: header:"},
      {"host:\"my host\"", "quotes keep spaces inside one term"},
      {"login", "a bare word searches method, host and path"},
    ]

    # The fields that read a message's CONTENT rather than its addressing — the ones a surface can
    # only answer with the bytes in hand (or a query that reads them). Named because "can this
    # backend answer the term?" is asked at three surfaces and each was spelling the list out for
    # itself.
    #
    # The `req.`/`resp.` spellings are deliberately NOT here. The one consumer
    # (`Colormarker::ROW_FIELDS`) derives itself by SUBTRACTING this from `InterceptFilter::FIELDS`,
    # which has no namespaced names to subtract — so a `resp.body:` rule already falls out of the
    # row tier and lands on the store tier, which is where it belongs. Adding them would be a
    # no-op that reads like a fix.
    CONTENT_FIELDS = %w[header body]

    # One field named by a query, its value as written, and whether it was written with the
    # regex operator. The value is carried because a caller routing a term to a backend may
    # need it: `Colormarker.row_answerable?` refuses a transport-suffixed `proto:` value.
    record FieldUse, name : String, regex : Bool, value : String

    # The fields `query` names, in order of appearance, one entry per TERM (so `host:a host~b`
    # reports both). A bare free-text word contributes nothing. Tokenized through exactly the
    # path `parse` compiles through — `FilterAst.terms` + `split_field`, the same pair `analyze`
    # and `invalid_regex_terms` use — so a caller asking "which fields does this need?" is asking
    # about the terms that will really be compiled, not about a second reading of the string.
    def self.fields_used(query : String) : Array(FieldUse)
      FilterAst.terms(FilterAst.parse(query)).compact_map do |term|
        next nil unless split = split_field(term.text)
        field, value, op = split
        FieldUse.new(field, op == :regex, value)
      end
    end

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
    private def self.term_to_sql(term : FilterAst::Term, fts : Bool = true,
                                 body_max : Int32? = nil) : SqlTerm?
      text = term.text
      return nil if text.empty?

      result =
        if split = split_field(text)
          field, value, op = split
          op == :regex ? regex_cond(field, value, text, body_max) : field_cond(field, value, text, fts, body_max)
        else
          free_text(text)
        end
      return nil unless result

      cond, args = result
      {term.negate? ? "NOT (#{cond})" : cond, args}
    end

    private def self.field_cond(field : String, value : String, term : String,
                                fts : Bool = true, body_max : Int32? = nil) : {String, Array(DB::Any)}?
      return nil if value.empty?
      # Resolve an accepted-but-not-offered spelling to its canonical name FIRST, so every arm
      # below (and `size_cond`'s own three-way switch) sees one name per concept.
      field = FIELD_ALIASES.fetch(field, field)
      case field
      when "host"                                then contains_cond("host", value)
      when "url"                                 then contains_cond(URL_EXPR, value)
      when "path"                                then contains_cond("target", value)
      when "method"                              then {"upper(method) = ?", [value.upcase] of DB::Any}
      when "scheme"                              then {"scheme = ?", [value.downcase] of DB::Any}
      when "proto"                               then proto_cond(value)
      when "status"                              then status_cond(value)
      when "size", "reqsize", "respsize"         then size_cond(field, value)
      when "dur"                                 then duration_cond(value)
      when "header", "req.header", "resp.header" then header_cond(value, side_of(field))
      when "body", "req.body", "resp.body"       then body_cond(value, fts, body_max, side_of(field))
      when "stub"                                then stub_cond(value)
      else
        # A side prefix we OWN, on a field that has no side. `resp.status:200` is not a typo the
        # way `hosst:x` is — it is a correct guess at a namespace this module advertises, made by
        # someone the completion row and Help's Query page just taught `resp.body:`. Free-texting
        # it (the fallback below, right for any other unknown field) searches method/host/target
        # for the literal `resp.status:200`, matches nothing, and reports the query CLEAN — which
        # is the exact "is it unsupported, or is the UI just not telling me?" question this
        # namespace was added to answer, asked again one field over.
        #
        # Dropping is louder in every direction that matters: `analyze` lists the term under
        # `ignored`, `ql_explain` and `strict:` name it, `reject_empty?` refuses a query that was
        # ONLY this, and `Colormarker.unusable_reason` refuses a rule carrying one. It does
        # broaden a surviving AND-chain, which this file elsewhere calls the dangerous direction —
        # the difference is that this broaden is REPORTED and the old narrow-to-zero was silent.
        return nil if side_prefixed?(field)
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
    # The body columns a `side` selects — both, or one. Named because `body_cond`,
    # `body_literal_cond` and `body_regex_cond` each build their own clause and must not be able
    # to disagree about what `resp.` means.
    private def self.body_columns(side : Symbol?) : Array(String)
      case side
      when :req  then ["request_body"]
      when :resp then ["response_body"]
      else            ["request_body", "response_body"]
      end
    end

    private def self.head_columns(side : Symbol?) : Array(String)
      case side
      when :req  then ["request_head"]
      when :resp then ["response_head"]
      else            ["request_head", "response_head"]
      end
    end

    # The `flows_fts` column for one side. The index is `fts5(req, resp, …)` — the two sides were
    # stored apart from the start (see `store/schema.cr`), so a side-scoped `body:` is a column
    # filter on an index that already exists, not a new one.
    private def self.fts_column(side : Symbol) : String
      side == :req ? "req" : "resp"
    end

    private def self.body_cond(value : String, fts : Bool = true,
                               body_max : Int32? = nil, side : Symbol? = nil) : {String, Array(DB::Any)}?
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
        cols = body_columns(side)
        case_permutations(value).each do |v|
          cols.each do |col|
            conds << "COALESCE(instr(#{body_col(col, body_max)}, CAST(? AS BLOB)), 0) > 0"
            params << v
          end
        end
        return {"(#{conds.join(" OR ")})", params}
      end
      return body_literal_cond(value, body_max, side) unless fts
      phrase = %("#{value.gsub('"', "\"\"")}") # quoted phrase → contiguous substring match
      # An FTS5 COLUMN FILTER (`resp : "phrase"`) narrows the match to one indexed column. The
      # column name is this module's own constant, never user input — the value stays inside the
      # quoted phrase whose embedded quotes were doubled just above — so the term is still not an
      # injection surface, and it stays a single bound `?`.
      phrase = "#{fts_column(side)} : #{phrase}" if side
      {"id IN (SELECT rowid FROM flows_fts WHERE flows_fts MATCH ?)", [phrase] of DB::Any}
    end

    # The index-free spelling of `body:` (see `parse`'s `fts:`): `body~` with the needle escaped
    # down to a literal, which makes "`body:` here means `body~` with a literal needle" exactly
    # true rather than approximately so — one clause, one set of NULL guards, one scan.
    #
    # NOT `CAST(… AS TEXT) LIKE '%needle%'`, which is the obvious spelling and the wrong one:
    # SQLite's own text conversion stops at the first embedded NUL, while `body~` runs through
    # `Gori::SafeRegexp`, which reads the haystack by its true `value_bytes` length precisely so
    # a body mixing binary and text is scanned whole. LIKE would have made `body:token` silently
    # miss what `body~token` finds — in a tool whose targets deliberately put NULs in bodies, and
    # in exactly the direction `body_cond`'s short-needle branch above already refused to fail.
    private def self.body_literal_cond(value : String, body_max : Int32? = nil,
                                       side : Symbol? = nil) : {String, Array(DB::Any)}
      # Control characters are stripped by `body_cond` before this runs, so the escaped literal
      # can never carry a NUL of its own. `(?i)` because `body:` promises case-insensitive
      # matching where `body~` is case-SENSITIVE by default.
      body_regex_cond("(?i)#{Regex.escape(value)}", body_max, side)
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
    private def self.header_cond(value : String, side : Symbol? = nil) : {String, Array(DB::Any)}?
      value = value.chars.reject(&.control?).join
      return nil if value.empty?
      if value.size < 3
        conds = [] of String
        params = [] of DB::Any
        cols = head_columns(side)
        case_permutations(value).each do |v|
          cols.each do |col|
            conds << "COALESCE(instr(#{col}, CAST(? AS BLOB)), 0) > 0"
            params << v
          end
        end
        return {"(#{conds.join(" OR ")})", params}
      end
      pat = "(?i)#{Regex.escape(value)}"
      return {"0", [] of DB::Any} unless valid_regex?(pat)
      header_regex_cond(pat, side)
    end

    # The `~` operator: case-sensitive regex (SQLite REGEXP, the same shard-provided
    # function Scope's regex rules use, backed by Crystal Regex) over a text field —
    # host/path/url/header/body. Any other field falls back to a literal free-text
    # search of the whole token. An invalid pattern would raise inside the SQLite
    # REGEXP callback, so we validate up front and emit a never-matches clause instead.
    # For case-insensitive matching use an inline (?i) flag.
    private def self.regex_cond(field : String, value : String, term : String,
                                body_max : Int32? = nil) : {String, Array(DB::Any)}?
      # A non-regex field name means `~` wasn't a regex operator here (e.g. `foo~bar`):
      # fall back to a literal free-text search of the WHOLE token. This must happen BEFORE
      # the validity guard — otherwise `foo~[` (an unterminated char class) would compile to
      # the never-match clause instead of free-texting "foo~[".
      # Same alias resolution `field_cond` does, and for the same reason: `res.body~x` must
      # compile like `resp.body~x`, and `invalid_regex_terms` below canonicalises identically so
      # the diagnosis cannot disagree with the compilation about which terms are regex terms.
      field = canonical(field)
      return regex_field_cond(field, value, body_max) if field.in?(REGEX_FIELDS)
      # A side prefix we own on a field that has none — dropped, not free-texted; see `field_cond`.
      return nil if side_prefixed?(field)
      free_text(term)
    end

    # The clause for a `~` term on a field that HAS one. Split out of `regex_cond` so that method
    # stays the three-way ROUTING decision (regex field / owned prefix / free text) and this one
    # stays a flat dispatch: merged, the namespaced arms pushed the pair past the cyclomatic gate
    # CI runs, and the two halves were never one thought anyway.
    private def self.regex_field_cond(field : String, value : String,
                                      body_max : Int32?) : {String, Array(DB::Any)}?
      return nil if value.empty?
      # An invalid pattern would raise inside the SQLite REGEXP callback, so validate up
      # front and emit a never-matches clause instead.
      return {"0", [] of DB::Any} unless valid_regex?(value)
      case field
      when "host"        then {"host REGEXP ?", [value] of DB::Any}
      when "path"        then {"target REGEXP ?", [value] of DB::Any}
      when "url"         then {"#{URL_EXPR} REGEXP ?", [value] of DB::Any}
      when "header"      then header_regex_cond(value)
      when "req.header"  then header_regex_cond(value, :req)
      when "resp.header" then header_regex_cond(value, :resp)
      when "req.body"    then body_regex_cond(value, body_max, :req)
      when "resp.body"   then body_regex_cond(value, body_max, :resp)
      else                    body_regex_cond(value, body_max)
      end
    end

    # Does this unknown field wear a side prefix THIS MODULE advertises? The one place the
    # prefix set is tested, so `field_cond` and `regex_cond` cannot start disagreeing about
    # whether `resp.status:` is a reported mistake or a free-text word.
    private def self.side_prefixed?(field : String) : Bool
      SIDES.each_key.any? { |p| field.starts_with?(p) }
    end

    # Which side a canonical field name selects, or nil for the two-sided spelling. Lets the
    # three `header` arms (and the three `body` ones) collapse into one apiece — six near-identical
    # `when`s is how `field_cond` earns a complexity warning for saying nothing new.
    private def self.side_of(field : String) : Symbol?
      SIDES.each { |prefix, side| return side if field.starts_with?(prefix) }
      nil
    end

    # An accepted spelling resolved to the one name the compilers switch on. Shared by
    # `field_cond`, `regex_cond` and `invalid_regex_terms` so an alias cannot be understood by
    # one of them and not the others.
    private def self.canonical(field : String) : String
      FIELD_ALIASES.fetch(field, field)
    end

    # `canonical`, public, for a surface that keeps its OWN help table over these names
    # (`Colormarker::FIELD_HELP`) and must resolve `res.body` the way the compilers do.
    def self.canonical_field(field : String) : String
      canonical(field)
    end

    # NULL-guarded REGEXP over both body columns (a bodyless flow contributes no match,
    # so `-body~x` keeps it — same null-safety as the body: LIKE fallback above).
    private def self.body_regex_cond(value : String, body_max : Int32? = nil,
                                     side : Symbol? = nil) : {String, Array(DB::Any)}
      params = [] of DB::Any
      conds = body_columns(side).map do |col|
        params << value
        "(#{col} IS NOT NULL AND CAST(#{body_col(col, body_max)} AS TEXT) REGEXP ?)"
      end
      {"(#{conds.join(" OR ")})", params}
    end

    # A body column as the caller wants it READ: whole, or its first `body_max` bytes. The
    # NULL guards around it stay on the RAW column — `substr(NULL, …)` is NULL either way, and
    # guarding the raw name keeps the two spellings' null-safety identical (see `parse`).
    #
    # `body_max` is an Int32 this module chose, never a user value, so inlining it cannot be an
    # injection; it is inlined rather than bound because the same constant appears in two
    # clauses and a `?` here would have to interleave with the pattern's own placeholders.
    private def self.body_col(column : String, body_max : Int32?) : String
      body_max ? "substr(#{column}, 1, #{body_max.to_i})" : column
    end

    private def self.header_regex_cond(value : String, side : Symbol? = nil) : {String, Array(DB::Any)}
      params = [] of DB::Any
      conds = head_columns(side).map do |col|
        params << value
        # `request_head` is BLOB NOT NULL, so it needs no guard; `response_head` is nullable and
        # an unguarded REGEXP over NULL yields NULL, which SQLite's three-valued logic EXCLUDES
        # under negation — that is how `-header:x` would silently drop every response-less flow.
        if col == "response_head"
          "(#{col} IS NOT NULL AND CAST(#{col} AS TEXT) REGEXP ?)"
        else
          "CAST(#{col} AS TEXT) REGEXP ?"
        end
      end
      {"(#{conds.join(" OR ")})", params}
    end

    # A pattern must compile or the SQLite REGEXP callback raises (mirrors Scope.valid?).
    private def self.valid_regex?(pattern : String) : Bool
      Regex.new(pattern)
      true
    rescue
      false
    end

    # Same folding rule as `field_cond`'s substring arms — see `contains_cond`.
    private def self.free_text(word : String) : {String, Array(DB::Any)}
      method_sql, method_args = contains_cond("method", word)
      host_sql, host_args = contains_cond("host", word)
      target_sql, target_args = contains_cond("target", word)
      {"(#{method_sql} OR #{host_sql} OR #{target_sql})", method_args + host_args + target_args}
    end

    # Build a LIKE pattern, neutralising the LIKE metacharacters % and _ (and the
    # escape char itself) so a user's literal % / _ matches literally. Pair every
    # use with `ESCAPE '\'` in the SQL. Backslash MUST be escaped first. Public so
    # Scope's string-match rules reuse the one escaper (no second hand-rolled copy).
    # A case-insensitive substring test on `expr`, picking the folding implementation by what
    # the NEEDLE contains.
    #
    # `lower(col) LIKE ?` folds the haystack with SQLite's built-in `lower()`, which is
    # ASCII-only, while `like` folds the needle with Crystal's full-Unicode `downcase`. For a
    # needle carrying a non-ASCII letter the two never meet: a captured `/Überweisung` was
    # unreachable by `path:` in EVERY spelling, and `InterceptFilter` — the in-memory
    # implementation of this same predicate — matched the row while History did not. Those
    # needles go through `gori_ci_contains` (Crystal's `downcase.includes?` as a UDF), which is
    # the same fix `scope.cr` already applies to a `string` rule.
    #
    # An ASCII needle keeps the native LIKE, because the UDF costs a Crystal callback and two
    # String allocations PER ROW and both forms full-scan either way: measured over 100k flows,
    # `host:` answers in 7ms through LIKE and 71ms through the UDF, and History recompiles this
    # filter on every keystroke (P6 — never stall the data path). Every ASCII character folds
    # identically in the two implementations, so the fast path is exact for the needles that
    # take it. The residue it accepts: a haystack character that folds INTO ASCII under Unicode
    # but not under `lower()` (`İ`→`i`, `K`→`k`, `ſ`→`s`) stays unreachable by an ASCII needle.
    # All three columns are NOT NULL, so the arms cannot disagree under `NOT` the way a NULL
    # haystack would (`NOT (NULL)` drops the row, `NOT (0)` keeps it).
    private def self.contains_cond(expr : String, value : String) : {String, Array(DB::Any)}
      return {"gori_ci_contains(#{expr}, ?)", [value] of DB::Any} unless value.ascii_only?
      {"lower(#{expr}) LIKE ? ESCAPE '\\'", [like(value)] of DB::Any}
    end

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
