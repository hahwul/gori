require "./params"
require "./sitemap"
require "./entity"
require "./redact"
require "./redact/headers"
require "./ql"
require "./store"

module Gori
  # The per-endpoint PARAMETER INVENTORY (#1231): every input name captured traffic shows,
  # grouped by (host, method, path, location, name), with how often it appeared, a capped
  # sample of its values, the first/last flow that carried it, and whether a value came back
  # in the response. Burp's "Analyze target", as a read over the store.
  #
  # The one engine behind all three surfaces — the TUI's Target → Params sub-tab, `gori run
  # sitemap params`, and MCP `list_params` — so the three cannot disagree on what an endpoint
  # or a parameter is. It is recomputed ON DEMAND and never runs on the capture path (P6):
  # the question is asked a few times an engagement, and a table maintained on every write
  # would charge every captured flow for it.
  #
  # "Reflected" is a cheap observation, NOT a finding: a value of at least `min_reflect` bytes
  # occurring verbatim in the decoded response body. It is where an operator looks first for
  # an XSS or injection sink, and nothing more is claimed.
  module ParamInventory
    extend self

    # Flows read per store page. The read is id-cursor paged (`search(before_id:)`), so memory
    # holds one page of rows plus one flow's bodies at a time, never the whole project.
    PAGE = 200

    # The name side of the built-in redaction profile: a member / form key called `password`,
    # `token`, `sid`, … carries a value no inventory prints by default. Folded once; the
    # project's configured profile is added on top per build (`Sensitivity`).
    SENSITIVE_NAMES = (Redact::DEFAULT_PROFILE.json_fields + Redact::DEFAULT_PROFILE.form_keys)
      .map(&.downcase).to_set

    # Longest sample value kept, in characters — an inventory shows what a value LOOKS like,
    # and a 2 MiB JSON string would drown every other row.
    SAMPLE_CHARS = 80

    ALL_LOCATIONS = Miner::Location.values

    # The reflection search's budget, per flow. A substring search is linear in the response,
    # and a JSON POST carries dozens of values: measured on 200 flows of 40 string fields
    # against a 1 MiB (decoded) HTML response, an unbounded search cost ~50 ms a flow in a
    # release build, all of it one synchronous stretch on the scheduler the proxy shares. So:
    # the first REFLECT_WINDOW bytes of the decoded response (where a reflected value almost
    # always lands — a page echoes the query near the top), at most REFLECT_CHECKS searches,
    # and a yield every REFLECT_YIELD of them. A value past the window reads not-reflected,
    # which is the conservative direction for a triage hint.
    REFLECT_WINDOW = 256 * 1024
    REFLECT_CHECKS = 64
    REFLECT_YIELD  =  8

    record Options,
      filter : QL::Filter = QL::EMPTY,
      host : String? = nil,
      path_prefix : String? = nil,
      locations : Array(Miner::Location) = ALL_LOCATIONS,
      all_headers : Bool = false,
      max_flows : Int32 = 2000,
      samples : Int32 = 5,
      min_reflect : Int32 = 4,
      # nil = the whole stored body (capture already caps it at `Body::CAPTURE_MAX`). A cap
      # here cuts the WIRE bytes, before any decode — a gzip body cut short cannot inflate and
      # a JSON body cut short does not parse — so it is for callers that accept that loss.
      body_max : Int32? = nil

    # One inventory row. `path` is the Sitemap's durable node key with the query cut off
    # (`Sitemap.node_path`), so a row names exactly the endpoint the Sitemap tab draws.
    # `sensitive` says the samples carry credential/session material; a surface masks them
    # unless the caller opted in (`masked`).
    record Row,
      host : String,
      method : String,
      path : String,
      location : Miner::Location,
      name : String,
      count : Int32,
      samples : Array(String),
      samples_truncated : Bool,
      first_flow_id : Int64,
      last_flow_id : Int64,
      reflected : Bool,
      reflected_flow_id : Int64?,
      sensitive : Bool do
      # The name as a wordlist entry: a JSON row contributes its LEAF member (what Miner's
      # Json location injects), everything else its name. nil for an array-element leaf.
      def word : String?
        location.json? ? Params.json_leaf(name) : name
      end
    end

    # `truncated` — the flow cap stopped the read before the filter ran out of matches.
    record Report, rows : Array(Row), flows_scanned : Int32, truncated : Bool

    # A row while it is being accumulated.
    private class Acc
      property count = 0
      property samples = [] of String
      property? samples_truncated = false
      property first_flow_id : Int64
      property last_flow_id : Int64
      property reflected_flow_id : Int64? = nil
      property? sensitive = false
      property seen_in : Int64 = -1_i64

      def initialize(id : Int64)
        @first_flow_id = id
        @last_flow_id = id
      end
    end

    # What counts as credential material for one build: the fixed header list, the built-in
    # profile's names and value shapes, AND the project's configured redaction profile — the
    # same one `get_flow` masks with — so a field the operator told gori to redact is not
    # printed here as an ordinary sample. Read without `Policy.resolve`, which would mint and
    # persist the placeholder salt as a side effect of a read.
    private class Sensitivity
      @names : Set(String)
      @patterns : Array(Regex)

      def initialize(store : Store)
        @names = SENSITIVE_NAMES.dup
        @patterns = Redact::BUILTIN_PATTERNS.map(&.[0])
        name = Redact::Policy.project_scope(store).active.presence || Settings.redaction_active.presence
        if profile = name.try { |n| Redact::Policy.profile(store, n) }
          (profile.json_fields + profile.form_keys).each do |f|
            f = f.strip.downcase
            @names << f unless f.empty?
          end
          profile.patterns.each do |src|
            next if src.strip.empty?
            @patterns << Regex.new(src, Regex::Options::IGNORE_CASE) rescue nil
          end
        end
      end

      # By location and name alone — cheap, so it runs on every sighting.
      def name?(p : Params::Param) : Bool
        return true if p.loc.cookies?
        return true if p.loc.headers? && Redact.sensitive_header?(p.name)
        leaf = p.loc.json? ? Params.json_leaf(p.name) : p.name
        !leaf.nil? && @names.includes?(leaf.downcase)
      end

      # By value shape — a regex per pattern, so it runs once per distinct sample, not per
      # sighting. PCRE2 raises on invalid UTF-8, hence the gate.
      def value?(v : String) : Bool
        v.valid_encoding? && @patterns.any?(&.matches?(v))
      end
    end

    # Build the inventory. `stop` is polled between flows (the TUI flips it when the result
    # would be stale); a stopped build returns what it had, flagged truncated.
    def build(store : Store, opts : Options = Options.new, stop : -> Bool = -> { false }) : Report
      wanted = opts.locations.to_set
      sens = Sensitivity.new(store)
      accs = {} of {String, String, String, Miner::Location, String} => Acc
      prefix = opts.path_prefix.presence
      # The path prefix is judged on the ROW, before its bodies are read and before it counts
      # against `max_flows` — so a narrow prefix is not starved by newer flows elsewhere.
      keep = ->(row : Store::FlowRow) { prefix.nil? || endpoint_path(row.target).starts_with?(prefix) }
      scanned, truncated = each_flow(store, host_filter(opts), opts.max_flows, keep, stop) do |row|
        next unless detail = store.get_flow(row.id, body_max: opts.body_max)
        add_flow(accs, detail, row.host, row.method.upcase, endpoint_path(row.target), wanted, opts, sens)
      end
      Report.new(rows(accs), scanned, truncated)
    end

    # The Sitemap's durable node key with the query cut — what a row's `path` names.
    def endpoint_path(target : String) : String
      Sitemap.path_part(Sitemap.node_path(target))
    end

    # The caller's filter, AND an exact host when one was named. Exact on purpose: QL's
    # `host:` is a substring, and "api.test" must not also read "sub.api.test".
    private def host_filter(opts : Options) : QL::Filter
      return opts.filter unless h = opts.host.try(&.strip).presence
      QL.and(opts.filter, QL::Filter.new("host = ? COLLATE NOCASE", [h] of DB::Any))
    end

    # Newest-first, id-cursor-paged walk over the filter's flows, yielding at most `max` rows
    # that `keep` accepts (a rejected row costs a row read, not a flow read, and is not
    # counted). {flows yielded, truncated} — truncated when the cap or `stop` ended the walk
    # with older matches left.
    #
    # The scheduler is handed back after EVERY flow: gori runs one cooperative scheduler, the
    # TUI runs this in a spawned fiber beside the proxy's own (P6), and a yield costs
    # microseconds where one flow's read + decode + reflection search can cost milliseconds.
    #
    # Public because the OpenAPI export (`Export::OpenApi`, #1241) walks the same flow set the
    # same way; a second copy of this pager is how the two would come to disagree about what
    # "the newest N flows" means.
    def each_flow(store : Store, filter : QL::Filter, max : Int32, keep : Store::FlowRow -> Bool,
                  stop : -> Bool, & : Store::FlowRow ->) : {Int32, Bool}
      scanned = 0
      cursor : Int64? = nil
      loop do
        page = store.search(filter, PAGE, cursor, raise_on_error: true)
        page.each do |row|
          return {scanned, true} if stop.call
          next unless keep.call(row)
          return {scanned, true} if scanned >= max # an older match exists: this one
          scanned += 1
          Fiber.yield
          yield row
        end
        return {scanned, false} if page.size < PAGE # the filter ran out of matches
        cursor = page.last.id
        # Once per PAGE too, not only per kept row: a `keep` that rejects (an operation already
        # full, a path outside the selection) would otherwise walk a 200k-flow history in one
        # synchronous stretch, since only a kept row reaches the yield above.
        Fiber.yield
      end
    end

    private def add_flow(accs, detail : Store::FlowDetail, host : String, method : String, path : String,
                         wanted : Set(Miner::Location), opts : Options, sens : Sensitivity) : Nil
      id = detail.row.id
      response : String? = nil
      searched = {} of String => Bool # one search per distinct value per flow
      Params.each(detail.request_head, detail.request_body, opts.all_headers) do |p|
        next unless wanted.includes?(p.loc)
        acc = accs[{host, method, path, p.loc, p.name}] ||= Acc.new(id)
        observe(acc, p, id, opts, sens)
        next unless p.reflectable? && acc.reflected_flow_id.nil? && p.value.bytesize >= opts.min_reflect
        hit = searched[p.value]?
        if hit.nil? && searched.size < REFLECT_CHECKS
          text = response ||= response_text(detail)
          hit = searched[p.value] = text.includes?(p.value)
          Fiber.yield if searched.size % REFLECT_YIELD == 0
        end
        acc.reflected_flow_id = id if hit
      end
    end

    # Fold one sighting into its row: the flow count, the id range, the capped samples, and
    # whether any sighting was credential material.
    private def observe(acc : Acc, p : Params::Param, id : Int64, opts : Options, sens : Sensitivity) : Nil
      if acc.seen_in != id # a count of FLOWS: `items[].id` twice in one body is one sighting
        acc.seen_in = id
        acc.count += 1
        acc.first_flow_id = Math.min(acc.first_flow_id, id)
        acc.last_flow_id = Math.max(acc.last_flow_id, id)
      end
      acc.sensitive = true if !acc.sensitive? && sens.name?(p)
      sample = clip(p.note || p.value)
      return if acc.samples.includes?(sample)
      if acc.samples.size < opts.samples
        acc.samples << sample
        # The value-shape test only on a NEW sample: a regex per sighting would be ~200k
        # scans on a 5000-flow read, for an answer the first sighting already gave.
        acc.sensitive = true if !acc.sensitive? && p.note.nil? && sens.value?(p.value)
      else
        acc.samples_truncated = true
      end
    end

    # The head of the decoded response ENTITY (REFLECT_WINDOW bytes) as a string for a
    # byte-substring search — `String#includes?` compares bytes, so invalid UTF-8 on either
    # side is compared, never raised on. No regex.
    private def response_text(detail : Store::FlowDetail) : String
      body = Entity.bytes(detail.response_head, detail.response_body, Params::DECODE_MAX)
      return "" unless body
      String.new(body[0, Math.min(body.size, REFLECT_WINDOW)])
    end

    private def clip(s : String) : String
      s.size > SAMPLE_CHARS ? "#{s[0, SAMPLE_CHARS]}…" : s
    end

    private def rows(accs) : Array(Row)
      out = accs.map do |(host, method, path, loc, name), a|
        Row.new(host, method, path, loc, name, a.count, a.samples, a.samples_truncated?,
          a.first_flow_id, a.last_flow_id, !a.reflected_flow_id.nil?, a.reflected_flow_id, a.sensitive?)
      end
      out.sort_by! { |r| {r.host, r.path, r.method, r.location.value, r.name} }
    end

    # The samples a surface may print: the real ones, or one placeholder when the row is
    # sensitive and the caller did not ask for secrets.
    def masked(row : Row, include_sensitive : Bool) : Array(String)
      return row.samples if include_sensitive || !row.sensitive || row.samples.empty?
      ["[REDACTED]"]
    end

    # Distinct wordlist entries, first-seen order. Header rows are left out unless
    # `headers` — a header name is not a parameter name, and a wordlist built from `x-api-key`
    # and friends would spend a mine's budget on the wrong namespace.
    #
    # A name the line-oriented wordlist format cannot carry is left out rather than mangled:
    # an embedded CR/LF (a decoded `a%0Ab`) splits into two bogus entries, a leading `#` reads
    # as a comment, and an empty name (`{"":1}`) as a blank line — the file would not say
    # what the screen said.
    def wordlist(rows : Enumerable(Row), headers : Bool = false) : Array(String)
      seen = Set(String).new
      out = [] of String
      rows.each do |r|
        next if r.location.headers? && !headers
        next unless (w = r.word) && wordlist_safe?(w)
        out << w if seen.add?(w)
      end
      out
    end

    private def wordlist_safe?(w : String) : Bool
      !w.strip.empty? && !w.includes?('\n') && !w.includes?('\r') && !w.lstrip.starts_with?('#')
    end

    # Names seen on the host's OTHER endpoints and not on this one — the Miner seed. Miner
    # already skips a name the base request carries (`already-in-request`), so seeding an
    # endpoint's own names would test nothing; its neighbours' names are the guesses worth a
    # request ("the API takes `tenant` on /orders, does /invoices too?").
    def neighbor_names(rows : Enumerable(Row), host : String, path : String) : Array(String)
      own = Set(String).new
      rows.each { |r| (w = r.word) && own << w if r.host == host && r.path == path }
      neighbors = rows.select { |r| r.host == host && r.path != path }
      wordlist(neighbors).reject { |w| own.includes?(w) }
    end
  end
end
