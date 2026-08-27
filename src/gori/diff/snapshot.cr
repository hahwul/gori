require "../store"
require "../scope"
require "../media_type"
require "./keys"

module Gori::Diff
  # What one side of a retest diff contributes: its captured endpoints, plus the COVERAGE
  # facts a reader needs to know how much the absence of an endpoint is worth.
  #
  # Reading a snapshot never holds the other side's store open and never reads a body: the
  # whole comparison runs off one grouped query per side (`Store#endpoint_observations`),
  # bounded and streamed straight into the per-endpoint tallies (P8).
  class Snapshot
    # What to call this side in a report — a project name, or a db path's basename.
    getter label : String
    getter db_path : String
    # The raw grouped rows this side contributed, in query order.
    getter observations : Array(Store::EndpointObservation)
    # Flows BEHIND those rows — the filtered, possibly capped set the diff actually read,
    # not the project's total. That is the number a coverage claim may be made from.
    getter flows : Int64
    getter first_seen : Int64?
    getter last_seen : Int64?
    getter? scope_enabled : Bool
    getter scope_rules : Array(String)
    # The endpoint query hit its cap, so this side's endpoint set is a PREFIX of what the
    # project holds. Every "not seen here" verdict downstream is suspect while this is true,
    # and the report says so rather than presenting a truncated read as a complete one.
    getter? truncated : Bool

    def initialize(@label, @db_path, @observations, @flows, @first_seen, @last_seen,
                   @scope_enabled, @scope_rules, @truncated)
    end

    # Read one side out of an open store. `filter` narrows the endpoint query, so the
    # coverage reported below describes exactly what the diff compared.
    #
    # `in_scope` drops hosts outside THIS side's own scope rules — host-level, the same
    # question `gori run sitemap --in-scope` asks. Each side is judged by its own rules
    # (they are what that capture was recorded under), and the report states both.
    def self.read(store : Store, label : String, db_path : String, *,
                  filter : QL::Filter = QL::EMPTY,
                  limit : Int32 = Store::ENDPOINT_OBSERVATION_MAX,
                  in_scope : Bool = false,
                  raise_on_error : Bool = false) : Snapshot
      rows = store.endpoint_observations(filter, limit, raise_on_error: raise_on_error)
      # `truncated` is measured BEFORE the scope narrowing: the cap applied to the query, so
      # a full page that then narrows to three rows is still a partial read of the project.
      truncated = rows.size >= limit
      scope = Scope.load(store)
      rows = rows.select { |o| scope.host_in_scope?(o.host) } if in_scope
      new(label, db_path, rows, rows.sum(&.count),
        rows.min_of?(&.first_seen), rows.max_of?(&.last_seen),
        scope.enabled?, scope.rules.map { |r| "#{r.kind} #{r.match_type}:#{r.pattern}" },
        truncated)
    end

    # The distinct (host, method, target) endpoints this side captured — what the shared
    # fold tree is built from.
    def entries : Array({String, String, String})
      seen = Set({String, String, String}).new
      out = [] of {String, String, String}
      @observations.each do |o|
        e = {o.host, o.method, o.target}
        out << e if seen.add?(e)
      end
      out
    end

    # Fold this side's observations into one `Facts` per endpoint key.
    def facts(templates : Templates) : Hash(Key, Facts)
      out = {} of Key => Facts
      @observations.each do |o|
        key = templates.key(o.host, o.method, o.target)
        (out[key] ||= Facts.new(key)).observe(o)
      end
      out
    end

    def hosts : Int32
      @observations.map(&.host).uniq!.size
    end
  end

  # Everything one side observed about ONE endpoint key, accumulated across every
  # (status, content-type) group that folded onto it.
  class Facts
    # The `flows.status` value gori writes when there was no response at all. NULL means the
    # response has not landed yet; 0 means it never will.
    NO_RESPONSE = 0

    getter key : Key
    # Exact statuses seen, so a report can print them. The VERDICT compares CLASSES
    # (see `Compare`) — a 200 that became a 201 is not a retest finding, a 200 that
    # became a 403 is.
    getter statuses : Set(Int32)
    # ≥1 captured flow never got a response — still pending, aborted, or the send errored
    # (see `NO_RESPONSE`). Kept apart from `statuses` because "no status" is not a status:
    # a side whose only observation is pending knows nothing about how the endpoint answers.
    getter? pending : Bool
    # `Content-Type` ESSENCES (`MediaType.essence`) — parameters dropped, so a rotating
    # multipart boundary or a charset spelling is not a change.
    getter content_types : Set(String)
    getter min_size : Int64?
    getter max_size : Int64?
    getter flows : Int64
    getter first_seen : Int64
    getter last_seen : Int64
    # The newest captured flow that folded onto this key, and the target it used — what a
    # surface drills into (the flow-level Comparer / `gori run compare`) and what a report
    # prints so the folded template still points at something concrete.
    getter sample_flow_id : Int64
    getter sample_target : String

    def initialize(@key : Key)
      @statuses = Set(Int32).new
      @pending = false
      @content_types = Set(String).new
      @min_size = nil
      @max_size = nil
      @flows = 0_i64
      @first_seen = Int64::MAX
      @last_seen = Int64::MIN
      @sample_flow_id = 0_i64
      @sample_target = ""
    end

    def observe(o : Store::EndpointObservation) : Nil
      observe_answer(o)
      observe_size(o)
      @flows += o.count
      @first_seen = o.first_seen if o.first_seen < @first_seen
      @last_seen = o.last_seen if o.last_seen > @last_seen
      # Newest wins, so the sample is the most recent evidence rather than whichever group
      # the query emitted first.
      if o.flow_id > @sample_flow_id
        @sample_flow_id = o.flow_id
        @sample_target = o.target
      end
    end

    # How the endpoint ANSWERED: its status and its content type.
    #
    # `status = 0` is gori's own sentinel for a flow that got NO response — an aborted
    # intercept, an upstream failure, a pending flow abandoned at shutdown
    # (`FlowMapper.aborted_response` / `error_response`, `Store#abandon_all_pending`). It is
    # not a status the origin sent, and `0` is truthy in Crystal, so the obvious
    # `if st = o.status` put it in `@statuses` — where `reachable?` (`< 400`) then read a
    # connection failure as "A reached this endpoint" and let `Gone` fire against a side that
    # never reached anything. `sitemap_entries_detailed` draws the same line (`status = 0 OR
    # status >= 400` is its error bucket).
    private def observe_answer(o : Store::EndpointObservation) : Nil
      st = o.status
      if st.nil? || st == NO_RESPONSE
        @pending = true
      else
        @statuses << st
      end
      if ct = MediaType.essence(o.content_type)
        @content_types << ct
      end
    end

    # Widen the observed size range. SQLite's MIN/MAX skip NULLs, so a group that mixes
    # pending and complete flows still contributes the sizes it does have.
    private def observe_size(o : Store::EndpointObservation) : Nil
      if lo = o.min_size
        cur = @min_size
        @min_size = (cur.nil? || lo < cur) ? lo : cur
      end
      if hi = o.max_size
        cur = @max_size
        @max_size = (cur.nil? || hi > cur) ? hi : cur
      end
    end

    # The status CLASSES seen — `2xx`, `4xx`, … — the tolerant view the verdict uses.
    def status_classes : Set(String)
      out = Set(String).new
      @statuses.each { |s| out << Facts.status_class(s) }
      out
    end

    def self.status_class(status : Int32) : String
      return "?" if status < 100 || status >= 600
      "#{status // 100}xx"
    end

    # This endpoint answered with an authentication/authorization refusal. The single
    # highest-value retest signal: "the endpoint is still there, but it asks now".
    def auth_required? : Bool
      @statuses.includes?(401) || @statuses.includes?(403)
    end

    # Every captured answer was "there is nothing here" — the only evidence a capture can
    # carry that an endpoint is really GONE rather than simply not visited.
    def absent? : Bool
      !@statuses.empty? && @statuses.all? { |s| s == 404 || s == 410 }
    end

    # This endpoint answered at all — anything that is not a 4xx/5xx refusal or error.
    def reachable? : Bool
      @statuses.any? { |s| s < 400 }
    end

    # The observed response-size range, or nil when this side measured none (every capture
    # still pending, or errored). ONE accessor rather than two nilable getters read apart:
    # `Compare.size_changed?` judges the band from it and `Render`/`DiffView` print from it,
    # and a second spelling of "what size did this endpoint answer with" is how the printed
    # number and the verdict come to describe different quantities.
    def size_range : {Int64, Int64}?
      lo = @min_size
      hi = @max_size
      (lo && hi) ? {lo, hi} : nil
    end

    # Midpoint of the observed response sizes: the value the tolerance band is centred on.
    def size_mid : Int64?
      size_range.try { |(lo, hi)| (lo + hi) // 2 }
    end

    def sorted_statuses : Array(Int32)
      @statuses.to_a.sort!
    end

    def sorted_content_types : Array(String)
      @content_types.to_a.sort!
    end
  end
end
