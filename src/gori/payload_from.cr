require "./store"
require "./ql"
require "./scope"
require "./params"
require "./param_inventory"
require "./sitemap"
require "./rules"
require "./intercept_filter"
require "./token_extract"
require "./miner/types"
require "./plural"

module Gori
  # Payload values read from data the project ALREADY captured (#1352): a QL query picks a set
  # of flows, a projection turns that set into a deterministic, de-duplicated list of strings,
  # and a Fuzzer set or a Miner name list consumes it like any other. `--payload-from 'host:api
  # param-names'` is the engagement's own vocabulary as a wordlist, with no temp file to write.
  #
  # ## Where this runs, and what it never does
  #
  # It is a READ over the store, resolved by the plan builders (`Fuzz::Plan.build`,
  # `Miner::Plan.build`) — never on the proxy path and never on the Store writer, so a large
  # project costs the operator's own `run` a few hundred milliseconds and costs capture
  # nothing (P6). The walk is the one the parameter inventory and the OpenAPI export share
  # (`ParamInventory.each_flow`): newest first, id-cursor paged, one flow's bytes in hand at a
  # time, the scheduler handed back after every flow. Nothing here sends a request.
  #
  # ## Bounded, deterministic, de-duplicated
  #
  # Every read is capped — flows read, distinct values kept, total value bytes, one value's
  # length — and the cap that ended a resolution is REPORTED, never silent. The order is the
  # walk's: newest flow first, and within a flow the order `Params.each` reads, first sighting
  # wins. The same project state and options give the same list, so a saved command line
  # reproduces its run.
  #
  # ## Values are kept as captured (P7)
  #
  # A projected value is the captured value, byte for byte: it is not trimmed, not decoded past
  # what `Params` already does (a query value is percent-decoded there, so the Fuzzer's position
  # rule can encode it once, not twice), and not filtered for line breaks. A value holding CR,
  # LF or NUL is COUNTED in the report and kept, because dropping it would decide for the
  # operator which of their captured bytes are payloads. What a position does with it is the
  # position's rule: a query or form position percent-encodes it (`Fuzz::AutoEncode`), a path
  # position takes it raw.
  #
  # ## Secrets
  #
  # A captured request carries cookies, authorization headers and credential-named fields, and
  # a value read out of the project is one `send` away from another host. So the DEFAULT
  # excludes every location that is credential material by construction (cookies, headers) and
  # every value the project's redaction policy would mask (`ParamInventory::Sensitivity`: a
  # credential-named field, a JWT or key shape). `include_sensitive` is the explicit opt-in, it
  # is REPORTED on the resolution, and `extracted` — whose whole point is a value an extract
  # rule pulled out of a response, session tokens and CSRF nonces included — refuses to run
  # without it. NAMES are not values: a cookie or credential-named field's NAME is a fine
  # candidate parameter name, so `param-names` does not withhold them.
  #
  # The memory-only binding table (#501) is never read: `extracted` re-applies the stored extract
  # RULES to stored responses, the same way a History display column does, so nothing live is
  # written anywhere and nothing durable is made of a live secret.
  module PayloadFrom
    extend self

    # A refusal in the builder's own words: a surface's existing `Gori::Error` path carries it
    # unchanged, the way `Fuzz::ChainError` and `Fuzz::WsError` do (not a `PlanError::Reason`,
    # which every surface `case`s exhaustively).
    class Error < Gori::Error
    end

    # Newest flows one resolution reads by default, and the ceiling a surface may raise it to.
    # The inventory's own defaults, so "how much of the project a source sees" is one number.
    DEFAULT_MAX_FLOWS = ParamInventory::Options.new.max_flows
    MAX_FLOWS         = 20_000

    # Distinct values kept, by default and at most. A Fuzzer sweep multiplies this by its
    # positions, so the default is a wordlist's size, not a project's.
    DEFAULT_MAX_VALUES =  10_000
    MAX_VALUES         = 100_000

    # Total bytes of kept values (each plus its separator): the memory bound that holds however
    # long the values are, beside the count bound above.
    MAX_BYTES = 8 * 1024 * 1024

    # A value longer than this is skipped and counted. A payload source is a wordlist, and a
    # 2 MiB JSON string is one row of a capture, not a candidate.
    VALUE_MAX_BYTES = 4096

    # The store reads at most `Store::JS_REF_READ_MAX` stored JavaScript references in one
    # query, so `js-endpoints` can only PROVE "there were more" below that: it asks for one row
    # past its cap, and a cap at the store's limit would never see the extra row. The cap it
    # applies is therefore one less, and the report names that number.
    JS_VALUES_CEILING = Store::JS_REF_READ_MAX - 1

    # What `param-names` and `param-values` read by default: the request's own inputs. Cookies
    # and headers are credential material by construction and are named explicitly.
    DEFAULT_LOCATIONS = [Miner::Location::Query, Miner::Location::Form, Miner::Location::Multipart,
                         Miner::Location::Json]

    enum Projection
      # The parameter NAMES of the selected requests (a JSON member contributes its leaf name).
      ParamNames
      # The parameter VALUES, decoded as `Params` reads them.
      ParamValues
      # The request-path segments, as captured (percent-encoded: a path position takes them raw).
      PathSegments
      # Endpoints found in captured JavaScript (`gori run sitemap js --scan` stores them).
      JsEndpoints
      # Values the project's extract rules pull out of the selected responses.
      Extracted

      def label : String
        case self
        in ParamNames   then "param-names"
        in ParamValues  then "param-values"
        in PathSegments then "path-segments"
        in JsEndpoints  then "js-endpoints"
        in Extracted    then "extracted"
        end
      end

      def self.parse?(token : String) : Projection?
        case token.strip.downcase
        when "param-names"   then ParamNames
        when "param-values"  then ParamValues
        when "path-segments" then PathSegments
        when "js-endpoints"  then JsEndpoints
        when "extracted"     then Extracted
        end
      end

      def self.labels : Array(String)
        values.map(&.label)
      end
    end

    # What ended a resolution short, when something did.
    enum Cap
      Flows
      Values
      Bytes
    end

    # The run-wide knobs a surface fills once (`--payload-from-*`, the MCP siblings, the TUI
    # form) and applies to every source it built. `locations` nil = the projection's default.
    record Policy,
      locations : Array(Miner::Location)? = nil,
      include_sensitive : Bool = false,
      max_flows : Int32 = DEFAULT_MAX_FLOWS,
      max_values : Int32 = DEFAULT_MAX_VALUES

    # One normalized source: the QL that picks flows, what to project out of them, and the
    # policy. `query` may be empty (every flow, newest first). `rule` names one extract rule
    # for `extracted` (nil = every enabled rule).
    record Spec,
      query : String,
      projection : Projection,
      rule : String? = nil,
      locations : Array(Miner::Location)? = nil,
      include_sensitive : Bool = false,
      max_flows : Int32 = DEFAULT_MAX_FLOWS,
      max_values : Int32 = DEFAULT_MAX_VALUES do
      # The descriptor this spec was written as: `<QL> <projection>`.
      def label : String
        proj = rule ? "#{projection.label}:#{rule}" : projection.label
        query.empty? ? proj : "#{query} #{proj}"
      end

      # `apply` a run-wide policy over this source's own. A policy's `locations` wins only when it
      # names some; the caps and the opt-in are the policy's.
      def apply(policy : Policy) : Spec
        copy_with(locations: policy.locations || locations, include_sensitive: policy.include_sensitive,
          max_flows: policy.max_flows.clamp(1, MAX_FLOWS), max_values: policy.max_values.clamp(1, MAX_VALUES))
      end

      # The locations this source reads: the caller's, or the projection's default.
      def effective_locations : Array(Miner::Location)
        locations || DEFAULT_LOCATIONS
      end
    end

    # What a resolution did, for the surface to SAY: the source, how much it read, what it kept,
    # what it withheld and why, and what ended it short. Never carries a value.
    record Report,
      source : String,
      projection : Projection,
      query : String,
      values : Int32,
      flows_scanned : Int32,
      capped_by : Cap?,
      max_flows : Int32,
      max_values : Int32,
      skipped_sensitive : Int32,
      skipped_oversize : Int32,
      framing_values : Int32,
      include_sensitive : Bool,
      locations : Array(String),
      fts_backlog : Int32 = 0,
      note : String? = nil do
      # The policy, as a word both an operator and an agent read the same way.
      def policy : String
        include_sensitive ? "sensitive-included" : "sensitive-excluded"
      end

      def truncated? : Bool
        !capped_by.nil?
      end

      # One line for a terminal or a status bar. The surface adds the flag names.
      def summary : String
        parts = ["#{source} → #{Gori.plural(values, "value")} from #{Gori.plural(flows_scanned, "flow")}"]
        parts << "SENSITIVE INCLUDED" if include_sensitive
        parts << "#{skipped_sensitive} sensitive skipped" if skipped_sensitive > 0
        parts << "#{skipped_oversize} over #{VALUE_MAX_BYTES} bytes skipped" if skipped_oversize > 0
        parts << "#{framing_values} with CR/LF/NUL kept verbatim" if framing_values > 0
        if cap = capped_by
          parts << case cap
          in .flows?  then "read only the newest #{max_flows} flows"
          in .values? then "stopped at #{max_values} values"
          in .bytes?  then "stopped at the #{MAX_BYTES // (1024 * 1024)} MiB value budget"
          end
        end
        parts << "the search index is #{Gori.plural(fts_backlog, "flow")} behind, so a body:/free-text term may miss some" if fts_backlog > 0
        if n = note
          parts << n
        end
        parts.join(" · ")
      end
    end

    record Resolved, values : Array(String), report : Report

    # ── the descriptor ────────────────────────────────────────────────────────

    # The distinct-values cap a resolution applies to `spec`: what the spec asked for, except
    # that `js-endpoints` cannot honor more than `JS_VALUES_CEILING` (a cap the report would
    # otherwise claim while the read stopped short of it). Public because the specs read it too.
    def value_cap(spec : Spec) : Int32
      spec.projection.js_endpoints? ? {spec.max_values, JS_VALUES_CEILING}.min : spec.max_values
    end

    # `<QL> <projection>`, the shape `--payload-from` and the MCP `payload_from` string take.
    # The LAST whitespace-delimited token is the projection (`extracted:NAME` names one extract
    # rule); everything before it is the QL, kept as written — quote a QL value containing
    # spaces the way QL always asks (`path:"/a b"`). A lone projection reads every flow.
    #
    # A refusal names what is wrong AND what would fix it, because the commonest mistake is a
    # QL with no projection (`host:api`), which would otherwise read as a valid query and a
    # missing word.
    def parse(descriptor : String) : Spec
      text = descriptor.strip
      raise Error.new("empty payload source — expected `<QL> <projection>`, " \
                      "projection one of #{Projection.labels.join(", ")}") if text.empty?
      # Not `rpartition(/\s+/)`: PCRE raises on invalid UTF-8, and the stdlib retries the match
      # at every position, quadratic in a text with no whitespace (200k chars took >20 s).
      token = text.split.last # no whitespace at all: the whole text is the projection
      query = text.rchop(token)
      name, colon, rule = token.partition(':')
      projection = Projection.parse?(name)
      unless projection
        raise Error.new("payload source #{descriptor.inspect} does not end in a projection — expected " \
                        "`<QL> <projection>` with projection one of #{Projection.labels.join(", ")}")
      end
      if colon.empty?
        Spec.new(query.strip, projection)
      elsif projection.extracted?
        raise Error.new("payload source #{descriptor.inspect}: `extracted:` needs the name of an extract rule") if rule.empty?
        Spec.new(query.strip, projection, rule)
      else
        raise Error.new("payload source #{descriptor.inspect}: only `extracted` takes a `:name` (a rule); " \
                        "#{projection.label} does not")
      end
    end

    # Would resolving `spec` read the free-text search index (`body:` and bare words)? A surface
    # asks BEFORE it opens the project, to decide whether its handle may be read-only.
    def uses_fts?(spec : Spec) : Bool
      return false if spec.query.empty?
      QL.parse(spec.query, scope: QL::SCOPE_SHAPE_ONLY).uses_fts?
    end

    # ── resolution ────────────────────────────────────────────────────────────

    # Read `spec` out of `store`.
    #
    # `drain_fts` — a one-shot surface (CLI, MCP) drains the off-commit search index first and
    # REFUSES when it cannot, because a `body:` selection over a partial index silently omits
    # flows; the live TUI passes false and gets the backlog on the report instead, since it must
    # not stall its frame waiting for a writer.
    #
    # `stop` is polled between flows; a stopped read returns what it had, capped `Flows`.
    def resolve(store : Store, spec : Spec, *, drain_fts : Bool = true,
                stop : -> Bool = -> { false }) : Resolved
      if spec.projection.extracted? && !spec.include_sensitive
        raise Error.new("`extracted` reads values your extract rules pulled out of responses — session tokens and " \
                        "CSRF nonces among them — so it is refused unless you say you want them (the sensitive-value " \
                        "opt-in). The reads are of stored responses only; no live binding is touched")
      end
      filter = compile_query(store, spec.query)
      backlog = 0
      if filter.uses_fts?
        if drain_fts
          pending = store.drain_fts!
          unless pending.zero?
            raise Error.new("#{Gori.plural(pending, "flow")} are not yet indexed for the free-text term in " \
                            "#{spec.query.inspect}, so the selection would silently omit them — retry in a moment " \
                            "(a gori capturing this project holds the writer that indexes them), or select without body:/free text")
          end
        else
          backlog = store.fts_backlog
        end
      end
      c = Collector.new(value_cap(spec), MAX_BYTES)
      scanned, cut, note = walk(store, spec, filter, c, stop)
      capped = c.capped_by || (cut ? Cap::Flows : nil)
      report = Report.new(spec.label, spec.projection, spec.query, c.values.size, scanned, capped,
        spec.max_flows, c.max_values, c.skipped_sensitive, c.skipped_oversize, c.framing,
        spec.include_sensitive, spec.effective_locations.map(&.label), backlog, note)
      Resolved.new(c.values, report)
    rescue ex : DB::Error | SQLite3::Exception
      raise Error.new("cannot read the project for payload source #{spec.label.inspect}: #{ex.message}")
    end

    # The QL, STRICT: a source is an exact selection, and a term QL drops or misreads BROADENS it
    # (an unknown field free-texts, a bad numeric is dropped, an invalid regex matches nothing).
    # History's bar can afford to be lenient because its result is on screen; a payload list is
    # not, so each of those is a refusal naming the term, not a wider run.
    def compile_query(store : Store, query : String) : QL::Filter
      q = query.strip
      return QL::EMPTY if q.empty?
      if use = QL.fields_used(q).find { |f| !QL.known_field?(f.name) }
        op = use.regex ? '~' : ':'
        near = QL.suggest_field(use.name)
        raise Error.new("payload source query: unknown field `#{use.name}#{op}`" +
                        (near ? " — did you mean `#{near}#{op}`?" : " — QL has no such field (fields: #{QL::FIELDS.join(' ')})"))
      end
      lens = Scope.ql_lens(store)
      filter = QL.parse(q, scope: lens)
      raise Error.new("payload source query #{q.inspect} matched no QL term — check the syntax (host:example.com method:POST path:/api)") if QL.reject_empty?(q, filter)
      bad = QL.invalid_regex_terms(q)
      raise Error.new("payload source query #{q.inspect}: regex term(s) failed to compile and would match nothing: #{bad.join(", ")}") unless bad.empty?
      analysis = QL.analyze(q, scope: lens)
      unless analysis.ignored.empty?
        raise Error.new("payload source query #{q.inspect}: term(s) QL would silently drop and so select MORE flows than " \
                        "written: #{analysis.ignored.join(", ")}")
      end
      filter
    end

    # ── projections ───────────────────────────────────────────────────────────

    # What the caps hold while a projection fills the list. `add` is the ONE place a value is
    # judged: it is de-duplicated (the first sighting keeps its place), skipped and counted when
    # over-long, and refused — with the cap noted — once a cap is reached, which is what tells the
    # walk to stop.
    private class Collector
      getter values = [] of String
      getter capped_by : Cap? = nil
      getter max_values : Int32
      property skipped_sensitive = 0
      getter skipped_oversize = 0
      getter framing = 0

      def initialize(@max_values : Int32, @max_bytes : Int32)
        @seen = Set(String).new
        @bytes = 0
      end

      def full? : Bool
        !@capped_by.nil?
      end

      # The read itself stopped at the value cap, whatever `add` saw (a bounded query whose
      # one extra row was skipped rather than refused).
      def cap_values! : Nil
        @capped_by ||= Cap::Values
      end

      # Already kept? Asked BEFORE the costlier judgements (a sensitivity regex pass), so a value
      # met a hundred times is judged once.
      def seen?(value : String) : Bool
        @seen.includes?(value)
      end

      # false once a cap is reached: the caller stops walking.
      def add(value : String) : Bool
        return false if full?
        return true if @seen.includes?(value)
        if value.bytesize > VALUE_MAX_BYTES
          @skipped_oversize += 1
          return true
        end
        if @values.size >= @max_values
          @capped_by = Cap::Values
          return false
        end
        if @bytes + value.bytesize + 1 > @max_bytes
          @capped_by = Cap::Bytes
          return false
        end
        @seen << value
        @values << value
        @bytes += value.bytesize + 1
        @framing += 1 if value.each_byte.any? { |b| b == 0x0a_u8 || b == 0x0d_u8 || b == 0_u8 }
        true
      end
    end

    # {flows scanned, the flow cap or a stop ended it, a note}
    private def walk(store : Store, spec : Spec, filter : QL::Filter, c : Collector,
                     stop : -> Bool) : {Int32, Bool, String?}
      case spec.projection
      in .param_names?, .param_values? then walk_params(store, spec, filter, c, stop)
      in .path_segments?               then walk_paths(store, spec, filter, c, stop)
      in .js_endpoints?                then walk_js(store, spec, filter, c, stop)
      in .extracted?                   then walk_extracted(store, spec, filter, c, stop)
      end
    end

    # The shared newest-first walk, stopping as soon as the collector is full.
    private def each_selected_flow(store : Store, spec : Spec, filter : QL::Filter, c : Collector,
                                   stop : -> Bool, & : Store::FlowRow ->) : {Int32, Bool}
      ParamInventory.each_flow(store, filter, spec.max_flows, ->(_row : Store::FlowRow) { true },
        -> { stop.call || c.full? }) { |row| yield row }
    end

    private def walk_params(store : Store, spec : Spec, filter : QL::Filter, c : Collector,
                            stop : -> Bool) : {Int32, Bool, String?}
      wanted = spec.effective_locations.to_set
      # Built only when VALUES are read AND the default policy applies: it loads the project's
      # redaction profile, which a names-only or opted-in read has no use for.
      sens = (spec.projection.param_values? && !spec.include_sensitive) ? ParamInventory::Sensitivity.new(store) : nil
      judged = Set(String).new # values already judged sensitive by SHAPE: one regex pass each
      scanned, cut = each_selected_flow(store, spec, filter, c, stop) do |row|
        next unless parts = store.request_parts(row.id)
        Params.each(parts[0], parts[1]) do |p|
          next unless wanted.includes?(p.loc)
          break unless add_param(spec, c, p, sens, judged)
        end
      end
      {scanned, cut, nil}
    end

    # One input of a request into the list, per the projection. false once a cap is reached: the
    # caller stops walking.
    private def add_param(spec : Spec, c : Collector, p : Params::Param,
                          sens : ParamInventory::Sensitivity?, judged : Set(String)) : Bool
      if spec.projection.param_names?
        word = ParamInventory.word(p.loc, p.name)
        return true if word.nil? || word.empty?
        return c.add(word)
      end
      return true if p.note || p.value.empty? || c.seen?(p.value)
      if (s = sens) && withheld?(s, p, judged)
        c.skipped_sensitive += 1
        return true
      end
      c.add(p.value)
    end

    # Is this value credential material by the project's own policy — its NAME says so
    # (a cookie, a credential header or field) or its SHAPE does (a JWT, a key)? A shape verdict
    # is remembered, so a value met a hundred times costs one regex pass.
    private def withheld?(s : ParamInventory::Sensitivity, p : Params::Param, judged : Set(String)) : Bool
      return true if s.name?(p) || judged.includes?(p.value)
      return false unless s.value?(p.value)
      judged << p.value
      true
    end

    private def walk_paths(store : Store, spec : Spec, filter : QL::Filter, c : Collector,
                           stop : -> Bool) : {Int32, Bool, String?}
      sens = spec.include_sensitive ? nil : ParamInventory::Sensitivity.new(store)
      scanned, cut = each_selected_flow(store, spec, filter, c, stop) do |row|
        ParamInventory.endpoint_path(row.target).split('/').each do |seg|
          next if seg.empty? || c.seen?(seg)
          if (s = sens) && s.value?(seg)
            c.skipped_sensitive += 1
            next
          end
          break unless c.add(seg)
        end
      end
      {scanned, cut, nil}
    end

    # Endpoints the JavaScript of the selected flows referenced (`gori run sitemap js --scan`
    # stores them; this only READS them). One indexed query, bounded by the value cap, newest
    # source flow first — so `max_flows` does not apply, and the flows reported are those with
    # stored references rather than a walk that stopped after N. The credential policy is
    # `path-segments`': an endpoint with a credential-shaped segment (a token a bundle
    # hard-codes into a path) is withheld and counted unless the operator opted in.
    private def walk_js(store : Store, spec : Spec, filter : QL::Filter, c : Collector,
                        stop : -> Bool) : {Int32, Bool, String?}
      return {0, true, nil} if stop.call # a single query: this is the only place to honor a stop
      sens = spec.include_sensitive ? nil : ParamInventory::Sensitivity.new(store)
      paths = store.js_ref_paths(filter, c.max_values + 1)
      paths.each do |path|
        next if c.seen?(path)
        if (s = sens) && path.split('/').any? { |seg| !seg.empty? && s.value?(seg) }
          c.skipped_sensitive += 1
          next
        end
        break unless c.add(path)
      end
      # The `+ 1` row proves there was more only when `add` refuses it; one skipped as sensitive
      # or oversize inside the window would leave a cut list reported complete.
      c.cap_values! if paths.size > c.max_values
      flows = store.js_ref_flow_count(filter)
      note = if flows.zero?
               "no JavaScript references are stored for these flows — `gori run sitemap js --scan` reads them"
             elsif spec.max_values > c.max_values
               "JavaScript references are read #{c.max_values} at a time, so the cap is #{c.max_values}, not #{spec.max_values}"
             end
      {flows, false, note}
    end

    # The stored extract rules, re-applied to the STORED responses of the selected flows — the
    # same claim a live rule makes (its host glob and its condition) and the same descriptor
    # (`TokenExtract`), on data that is already durable. Newest flow first, each rule in name order.
    private def walk_extracted(store : Store, spec : Spec, filter : QL::Filter, c : Collector,
                               stop : -> Bool) : {Int32, Bool, String?}
      compiled = extract_rules_for(store, spec)
      scanned, cut = each_selected_flow(store, spec, filter, c, stop) do |row|
        next unless detail = store.get_flow(row.id)
        add_extracted(row, detail, compiled, c)
      end
      {scanned, cut, nil}
    end

    # The enabled rules a source reads (all of them, or the one it names), each with its condition
    # and its regex compiled ONCE. A refusal names what is missing.
    private def extract_rules_for(store : Store, spec : Spec) : Array({Store::ExtractRule, InterceptFilter, Regex?})
      rules = store.extract_rules.select(&.enabled?)
      if wanted = spec.rule
        rules = rules.select { |r| r.name == wanted }
        raise Error.new("no enabled extract rule named #{wanted.inspect} (see `gori run rewriter extract`)") if rules.empty?
      elsif rules.empty?
        raise Error.new("this project has no enabled extract rule — add one (`gori run rewriter extract add`) " \
                        "for `extracted` to have something to read")
      end
      rules.map do |r|
        re = r.kind.regex? && !r.selector.empty? ? (Regex.new(r.selector) rescue nil) : nil
        {r, InterceptFilter.new(r.match_filter), re}
      end
    end

    # One stored exchange through every rule that claims it.
    private def add_extracted(row : Store::FlowRow, detail : Store::FlowDetail,
                              compiled : Array({Store::ExtractRule, InterceptFilter, Regex?}), c : Collector) : Nil
      head = detail.response_head
      body = detail.response_body
      return if (head.nil? || head.empty?) && body.nil? # still pending, or never answered
      subject = InterceptFilter::Subject.new(method: row.method, host: row.host, target: row.target,
        scheme: row.scheme, status: row.status, head: head, payload: body, port: row.port)
      extract = ExtractSubject.response(head, body, Params::DECODE_MAX)
      compiled.each do |(rule, cond, re)|
        next unless Rules.host_matches?(rule.host, row.host) && cond.matches?(subject)
        next unless v = TokenExtract.extract(extract, rule.token_loc, re)
        next if v.empty?
        break unless c.add(v)
      end
    end
  end
end
