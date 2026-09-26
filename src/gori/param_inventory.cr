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

    # Row cap: an adversarial project (ID-keyed JSON maps, a path per record) must not build
    # millions of accumulators. Rows already open keep counting; new ones are refused.
    ROW_CAP = 10_000

    record Options,
      filter : QL::Filter = QL::EMPTY,
      host : String? = nil,
      path_prefix : String? = nil,
      locations : Array(Miner::Location) = ALL_LOCATIONS,
      all_headers : Bool = false,
      max_flows : Int32 = 2000,
      max_rows : Int32 = ROW_CAP,
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
        ParamInventory.word(location, name)
      end
    end

    # `truncated` — a cap (flows or rows) or `stop` ended the read with matches left.
    # `rows_capped` — the row cap (`max_rows`) stopped it: raising the flow cap won't help.
    record Report, rows : Array(Row), flows_scanned : Int32, truncated : Bool, rows_capped : Bool = false

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
      # Each `json_pointers` entry as its RFC 6901 tokens (`Redact::Matcher.pointer_tokens`).
      @pointers : Array(Array(String))
      # A JSON path's verdict by name alone, once per distinct path: the segment walk
      # allocates, and `name?` runs on every sighting of a row not yet known sensitive.
      @json = {} of String => Bool

      def initialize(store : Store)
        @names = SENSITIVE_NAMES.dup
        @patterns = Redact::BUILTIN_PATTERNS.map(&.[0])
        @pointers = [] of Array(String)
        name = Redact::Policy.project_scope(store).active.presence || Settings.redaction_active.presence
        if profile = name.try { |n| Redact::Policy.profile(store, n) }
          (profile.json_fields + profile.form_keys).each do |f|
            f = f.strip.downcase
            @names << f unless f.empty?
          end
          profile.json_pointers.each do |ptr|
            @pointers << Redact::Matcher.pointer_tokens(ptr.strip) unless ptr.strip.empty?
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
        return @json.fetch(p.name) { @json[p.name] = json_path?(p.name) } if p.loc.json?
        @names.includes?(Params.bracket_leaf(p.name).downcase)
      end

      # The Redact matcher masks a whole value — object or array included — under a member it
      # names, at any depth, and whatever a pointer lands on. So a leaf is sensitive when ANY
      # member on its path is a sensitive name (`password[]`, `secret.new`), or when a pointer
      # names the path or one of its ancestors. The walk collapses array indices to `[]`, so an
      # array step answers to `-` and to any numeric index: one element masked is enough.
      private def json_path?(path : String) : Bool
        segs = Params.json_segments(path)
        return Params.json_leaf(path).try { |l| @names.includes?(l.downcase) } || false if segs.empty?
        return true if segs.any? { |s| s && @names.includes?(s.downcase) }
        @pointers.any? do |want|
          next false if want.size > segs.size
          want.each_with_index.all? do |tok, i|
            seg = segs[i]
            seg.nil? ? (tok == "-" || (!tok.empty? && tok.each_char.all?(&.ascii_number?))) : tok == seg
          end
        end
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
      scanned, flow_truncated = each_flow(store, host_filter(opts), opts.max_flows, keep,
        -> { stop.call || accs.size >= opts.max_rows }) do |row|
        next unless detail = store.get_flow(row.id, body_max: opts.body_max)
        add_flow(accs, detail, row.host.downcase, row.method.upcase, endpoint_path(row.target), wanted, opts, sens)
      end
      capped = accs.size >= opts.max_rows
      Report.new(rows(accs), scanned, flow_truncated || capped, capped)
    end

    # The Sitemap's durable node key with the query cut — what a row's `path` names.
    def endpoint_path(target : String) : String
      Sitemap.path_part(Sitemap.node_path(target))
    end

    # Does the stored flow `flow` still stand where `row` said its flow did — same host,
    # method and endpoint, keyed exactly as `build` keyed the row? A report holds flow ids,
    # and a History clear restarts them (`Store#clear_flows`), so an id read back after the
    # scan can name an unrelated request; a caller that acts on the id checks this first.
    def carries?(row : Row, flow : Store::FlowRow) : Bool
      flow.host.downcase == row.host && flow.method.upcase == row.method &&
        endpoint_path(flow.target) == row.path
    end

    # The caller's filter, AND an exact host when one was named. Exact on purpose: QL's
    # `host:` is a substring, and "api.test" must not also read "sub.api.test".
    # Case-insensitive, but hosts are stored as captured: a bare `host = ? COLLATE NOCASE`
    # cannot use idx_flows_sitemap and scans the table, so the stored spellings are
    # resolved off the index first and the outer match is an indexed equality.
    private def host_filter(opts : Options) : QL::Filter
      return opts.filter unless h = opts.host.try(&.strip).presence
      QL.and(opts.filter, QL::Filter.new(
        "host IN (SELECT DISTINCT host FROM flows WHERE host = ? COLLATE NOCASE)", [h] of DB::Any))
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
        key = {host, method, path, p.loc, p.name}
        acc = accs[key]?
        if acc.nil?
          next if accs.size >= opts.max_rows
          acc = accs[key] = Acc.new(id)
        end
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
      h = host.downcase
      own = Set(String).new
      rows.each { |r| (w = r.word) && own << w if r.host.downcase == h && r.path == path }
      neighbors = rows.select { |r| r.host.downcase == h && r.path != path }
      wordlist(neighbors).reject { |w| own.includes?(w) }
    end

    # A parameter's name as a wordlist entry: a JSON parameter contributes its LEAF member
    # (what Miner's Json location injects), everything else its name. nil for an array leaf.
    def word(location : Miner::Location, name : String) : String?
      location.json? ? Params.json_leaf(name) : name
    end

    # Newest flows `seed_names` reads for one host. A Miner seed is a guess list, not a report,
    # so it reads fewer than the Params sub-tab does.
    SEED_MAX_FLOWS = 2000

    # `neighbor_names` for the endpoint each of `flows` stands on, by flow id, read straight
    # from the store: what a History mine seeds with, where no Params scan is on screen to
    # read. One walk per HOST, however many of the flows share it, over the same newest-first
    # flow set `build` walks — but names only: request head and body alone (no response BLOB
    # is read), and no rows, samples, sensitivity or reflection. Names come newest sighting
    # first, so a request-capped mine spends its budget on what the host uses now. A host
    # `stop` cut short gets no entries.
    def seed_names(store : Store, flows : Enumerable(Store::FlowRow), max_flows : Int32 = SEED_MAX_FLOWS,
                   stop : -> Bool = -> { false }) : Hash(Int64, Array(String))
      out = {} of Int64 => Array(String)
      flows.group_by(&.host.downcase).each do |host, group|
        break if stop.call
        sightings = host_words(store, host, max_flows, stop)
        break if stop.call # a walk `stop` cut short read a partial host
        group.each do |f|
          path = endpoint_path(f.target)
          own = sightings.compact_map { |(p, w)| w if p == path }.to_set
          names = Set(String).new
          sightings.each { |(p, w)| names << w if p != path && !own.includes?(w) }
          out[f.id] = names.to_a
        end
      end
      out
    end

    # {endpoint path, word} per distinct sighting on `host`, newest flow first. Header names
    # are left out (see `wordlist`), as are words the wordlist format cannot carry.
    private def host_words(store : Store, host : String, max_flows : Int32, stop : -> Bool) : Array({String, String})
      seen = Set({String, String}).new
      out = [] of {String, String}
      each_flow(store, host_filter(Options.new(host: host)), max_flows, ->(_row : Store::FlowRow) { true },
        -> { stop.call || out.size >= ROW_CAP }) do |row|
        next unless parts = store.request_parts(row.id)
        path = endpoint_path(row.target)
        Params.each(parts[0], parts[1]) do |p|
          next if p.loc.headers?
          next unless (w = word(p.loc, p.name)) && wordlist_safe?(w)
          out << {path, w} if seen.add?({path, w})
        end
      end
      out
    end
  end
end
