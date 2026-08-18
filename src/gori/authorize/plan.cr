require "../outbound"
require "../ql"
require "../store"
require "./engine"
require "./identity"
require "./passive"

module Gori::Authorize
  # Why one option set cannot become a runnable authorize run.
  #
  # The builder never writes the user-facing sentence: every surface phrases these in its
  # own idiom (`gori run authorize: name a flow id or --query` vs the TUI's `Send to
  # Authorize from History to begin`), and those strings are part of each surface's
  # contract. So `reason` is the machine-readable fact and the `message` here is only a
  # fallback for a caller that has nothing better to say.
  #
  # EVERY MEMBER ADDED HERE OBLIGATES AN ARM IN `gori run authorize` AND ONE IN THE MCP
  # `authorize_*` TOOLS — both switch on this exhaustively (`case … in`), so a new member is
  # a compile error until each has an answer and a next thing to type. (The TUI tab does not
  # appear here: its queue is live view state rather than an options set, so it makes the same
  # refusals against the view — see `AuthorizeController#comparable_batch`.) Keep the set as
  # small as the real failure modes require.
  class PlanError < Exception
    enum Reason
      # No selection at all: neither a flow id nor a query. (A usage mistake, not an empty
      # result — see `NoFlows`.)
      NoTarget
      # A selection was given and resolved to zero flows: unknown/pruned ids, or a query
      # that matched nothing. `detail` = the query, when one was the selector.
      NoFlows
      # The QL query compiled to no clause at all (a bad field / numeric / regex), or the
      # search itself failed. The empty filter matches EVERY flow, so running it would
      # replay the whole history — the opposite of what was asked. `detail` = the query,
      # or the underlying error for a failed search.
      BadQuery
      # The resolved identity set cannot produce a comparison: fewer than two identities
      # once the as-captured baseline is in place, so every trial would be the baseline
      # judged against itself and the run would report `no identity matched the baseline`
      # about a test that compared nothing. `detail` = where the set came from ("json" /
      # "project"), for a surface that wants to name the file or the tab to fix.
      NoIdentities
      # Two identities in the resolved set share a name (case-insensitively). Refused rather
      # than run, because the name is the ONLY thing that tells the rows of the results table
      # apart: two "admin" rows leave no way to say which session produced which verdict, and
      # `bypasses[].identities` names a string a caller then cannot resolve back to a slot.
      # The TUI's identity form has always refused it; this is the same rule for a `--identities`
      # file, an MCP `identities` array, and a hand-edited settings row. `detail` = the name.
      DuplicateIdentity
      # Flows were selected, and every one of them was skipped — unsafe method, incomplete,
      # answered by gori, no identity changes it, out of scope, duplicate. `detail` = the
      # per-reason tally; `PlanError#skipped` carries the full per-flow list, because "a run
      # that sends nothing says so" (DESIGN.md §7, 2026-07-26) and a bare count cannot.
      NothingToSend
    end

    getter reason : Reason
    getter detail : String?
    # Every flow the selection reached and why it will not be replayed. Populated for
    # `NothingToSend`, empty for the rest. Carried on the error — rather than left to a
    # summary string — so the surface that refuses can still list what it looked at.
    getter skipped : Array(Skipped)

    def initialize(@reason : Reason, message : String, @detail : String? = nil,
                   @skipped : Array(Skipped) = [] of Skipped)
      super(message)
    end
  end

  # One flow the selection reached but the run will not replay. `reason` is a
  # `Passive.skip_reason` symbol (plus `:out_of_scope` / `:duplicate`, which the selection
  # decides rather than the flow itself), so `Passive.reason_label` is the one place a
  # sentence for it is written.
  struct Skipped
    getter flow_id : Int64
    getter method : String
    getter url : String
    getter reason : Symbol

    def initialize(@flow_id : Int64, @method : String, @url : String, @reason : Symbol)
    end

    def label : String
      Passive.reason_label(@reason)
    end
  end

  # A normalized, surface-independent description of ONE authorize run.
  #
  # Each surface's remaining job is to parse ITS OWN input format into this — an
  # `OptionParser` for `gori run authorize`, the JSON args hash for the MCP `authorize_*`
  # tools, view state for the TUI tab — and nothing else. Everything downstream of it
  # (resolving a selection to flows, loading the project's identities, the skip decisions,
  # the Layer-1 scope verdict, the engine and the send loop) belongs to `Plan.build`.
  struct PlanOptions
    # The project the selection and the saved identities are read from. Required: both
    # halves of "which requests, under which identities" live in the project, and the whole
    # point of this seam is that neither surface answers them for itself.
    property store : Store
    # Captured flows to replay, by id, in the order given. Deduped against each other and
    # against the query's rows (`:duplicate`).
    property flow_ids : Array(Int64)
    # A QL query over history, appended after `flow_ids`. Same grammar as `gori run history`
    # and the TUI's `/` bar — one grammar for all of them (`QL.parse`).
    property query : String?
    # How many rows the query may contribute. A cap and not a paging window: every row here
    # becomes `identities.size` real requests, so an uncapped query turns a browse into a
    # replay of the whole session.
    property limit : Int32
    # Explicit identities as JSON — the shape `Authorize.parse_json` already reads, so a
    # `--identities FILE`, an MCP `identities` array serialized back, and the project's own
    # stored blob are one format. Nil falls back to the project's saved set.
    property identities_json : String?
    # Replay flows whose method is not in `Passive::SAFE_METHODS`. OFF by default and never
    # implied: a replayed POST/PUT/PATCH/DELETE runs the side effect again, once per
    # identity, and a query can select hundreds of them. A surface turns it on where a human
    # named the request (`gori run authorize <flow-id> --unsafe-methods`), which is the same
    # split the TUI draws between its manual queue and passive replay.
    property? unsafe_methods : Bool
    # Verify upstream TLS certificates.
    property? verify : Bool
    # Per-send connect/read/write timeout.
    property timeout : Time::Span

    def initialize(@store : Store,
                   *,
                   @flow_ids : Array(Int64) = [] of Int64,
                   @query : String? = nil,
                   @limit : Int32 = Plan::DEFAULT_LIMIT,
                   @identities_json : String? = nil,
                   @unsafe_methods : Bool = false,
                   @verify : Bool = true,
                   @timeout : Time::Span = ACTIVE_TIMEOUT)
    end
  end

  # A ready-to-run authorize job: THE only place an `Authorize::Engine` is built from
  # options, and the only place a selection becomes a list of `Store::FlowDetail`.
  #
  # The Authorize tool shipped with an engine and a TUI tab and no seam, which is exactly
  # the shape AGENTS.md §2 names: the CLI and MCP adapters would each have grown their own
  # copy of *resolve flows → load identities → decide what to skip → check scope → build
  # engine → loop*, and the copies drift (the sibling builders' headers list the drifts that
  # were already live when they were written). One builder makes those answers the same by
  # construction.
  #
  # `outbound` is an ARGUMENT, never built here: Layer-1 strictness differs per surface on
  # purpose (`Outbound.agent` / `.cli` / `.interactive`, DESIGN.md §7), and constructing one
  # in here would silently collapse that distinction into whichever policy was hard-coded.
  struct Plan
    # A query's default row cap. Deliberately small: the run's request count is
    # `rows × identities`, so the number that reads as "a page of history" is already a few
    # hundred requests on a target.
    DEFAULT_LIMIT = 50

    getter engine : Engine
    # Baseline first is the ENGINE's job (`order_baseline_first`), not this list's — this is
    # the resolved set in the order the operator wrote it, with `Identity.as_captured`
    # prepended when nothing claimed the baseline.
    getter identities : Array(Identity)
    # The flows that will actually be replayed, in selection order. Never empty: a selection
    # that resolves to nothing to send raises `NothingToSend` instead of returning a plan
    # that quietly does nothing (DESIGN.md §7 — "a run that sends nothing says so").
    getter targets : Array(Store::FlowDetail)
    # The flows the selection reached and will NOT replay, each with its reason. Reported by
    # the surface, never swallowed: "gori sent nothing" and "there was nothing there" are
    # different answers and an operator has to be able to tell them apart (P4).
    getter skipped : Array(Skipped)

    def initialize(@engine : Engine, @identities : Array(Identity),
                   @targets : Array(Store::FlowDetail), @skipped : Array(Skipped))
    end

    # How many requests this run will put on the wire if nothing stops it.
    def total_sends : Int32
      @targets.size * @identities.size
    end

    # The skip tally as one line ("2 not a safe method to repeat · 1 outside project
    # scope"), or nil when nothing was skipped. A FALLBACK for a surface with nothing better
    # to say — `skipped` is the structured form every surface should prefer.
    def skip_summary : String?
      @skipped.empty? ? nil : Plan.skip_tally(@skipped)
    end

    # Replay every target under every identity, yielding each finished `Target` as it lands.
    # Returns the number of FLOWS replayed (each one is `identities.size` requests).
    #
    # THE send loop, here rather than once per surface: `stop` is polled between requests
    # AND handed to the engine so it is also polled between identities, and a request the
    # stop cut short yields NOTHING — a partial set of trials must not become a Target (see
    # `Engine#run`). A surface that re-implemented this loop is one `if target` away from
    # reporting "enforced" for identities it never sent.
    #
    # `on_error` is how ONE unreplayable flow stops being fatal to the whole selection. A
    # send failure is already a `Trial` with an error, but a few things RAISE before any send:
    # a stored h2 pseudo-header head (`FlowRequest::PseudoHeaderHead`) is the reachable one.
    # Escaping here killed the run at that flow — `gori run authorize` lost every remaining
    # flow AND its buffered `--format json` array, and an MCP job went `:error` with the
    # results it already had. The TUI survived it because its own loop rescues per request;
    # a headless run has no reason to be less robust than the tab. Absent an `on_error` the
    # raise still escapes, so a surface has to decide rather than inherit silence.
    def run(stop : Proc(Bool)? = nil,
            on_error : Proc(Store::FlowDetail, Exception, Nil)? = nil,
            & : Store::FlowDetail, Target ->) : Int32
      sent = 0
      @targets.each do |detail|
        break if stop.try(&.call)
        begin
          target = @engine.run(detail, @identities, stop)
        rescue ex
          raise ex unless handler = on_error
          handler.call(detail, ex)
          next
        end
        next unless target
        sent += 1
        yield detail, target
      end
      sent
    end

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : Plan
      # Selection FIRST, identities second. `partition` needs both, but only this order
      # reports the right mistake: a bare `gori run authorize` in a project with no saved
      # identities is a `NoTarget` ("name a flow id or --query"), and resolving identities
      # first answered it with `NoIdentities` — sending the operator off to configure a
      # tab when they had simply named nothing to replay.
      details = resolve_flows(options)
      identities = resolve_identities(options)
      targets, skipped = partition(details, identities, options, outbound)
      if targets.empty?
        raise PlanError.new(PlanError::Reason::NothingToSend,
          "every selected flow was skipped", skip_tally(skipped), skipped)
      end
      new(engine: Engine.live(outbound, options.verify?, options.timeout),
        identities: identities, targets: targets, skipped: skipped)
    end

    # The identity set the run replays under: the explicit JSON when the surface has one,
    # else the project's saved set — the SAME blob the TUI's identities pane writes
    # (`Store::AUTHORIZE_IDENTITIES_KEY`), so `gori run authorize` and `authorize_start`
    # default to the identities the operator already configured in the tab.
    #
    # `Identity.as_captured` is prepended whenever nothing claims the baseline. Without it
    # `Engine#order_baseline_first` would promote the operator's FIRST identity to baseline
    # and judge it against itself, so a single supplied identity — the ordinary CLI shape,
    # `--identity '{"name":"anon","remove":["Cookie"]}'` — would compare nothing.
    private def self.resolve_identities(options : PlanOptions) : Array(Identity)
      source = options.identities_json ? "json" : "project"
      raw = options.identities_json ||
            options.store.setting(Store::AUTHORIZE_IDENTITIES_KEY)
      # A malformed blob degrades to an empty list rather than raising — see
      # `Authorize.parse_json`. That is right on the project-open path and wrong here, so
      # the emptiness is what gets named, with `detail` saying which source produced it.
      list = Authorize.parse_json(raw)
      reject_duplicate_names(list)
      list = [Identity.as_captured(baseline_name(list))] + list unless list.any?(&.baseline?)
      if list.size < 2
        raise PlanError.new(PlanError::Reason::NoIdentities,
          "need at least one identity besides the baseline to compare against", source)
      end
      list
    end

    # Refuse a set whose rows cannot be told apart. Case-insensitive, matching the TUI form's
    # own check — `$Session` and `$SESSION` are two binding names everywhere in gori, but two
    # IDENTITIES called `admin` and `Admin` are two rows a person reads as one.
    private def self.reject_duplicate_names(list : Array(Identity)) : Nil
      seen = Set(String).new
      list.each do |id|
        next if seen.add?(id.name.downcase)
        raise PlanError.new(PlanError::Reason::DuplicateIdentity,
          "two identities are called #{id.name.inspect}", id.name)
      end
    end

    # A name for the prepended baseline that the operator's own set has not already used.
    # Without it, a set containing a non-baseline identity called "as-captured" would collide
    # with the row gori adds — a duplicate gori created, which the check above would then
    # report as the operator's mistake.
    private def self.baseline_name(list : Array(Identity)) : String
      taken = list.map(&.name.downcase).to_set
      return "as-captured" unless taken.includes?("as-captured")
      n = 2
      while taken.includes?("as-captured #{n}")
        n += 1
      end
      "as-captured #{n}"
    end

    # The selection, resolved to flows in the order the operator expressed it: explicit ids
    # first, then the query's rows (newest first, as every other QL listing reads).
    # Duplicates survive as rows here and are counted as `:duplicate` skips by `partition` —
    # dropping them silently would make `--flow 7 --flow 7` and `--flow 7` look identical
    # while one of them asked for something impossible.
    private def self.resolve_flows(options : PlanOptions) : Array(Store::FlowDetail)
      query = options.query.try(&.strip).presence
      if options.flow_ids.empty? && query.nil?
        raise PlanError.new(PlanError::Reason::NoTarget, "no flows selected")
      end
      details = [] of Store::FlowDetail
      # A pruned/unknown id contributes nothing rather than raising: it is not a flow that
      # was declined, it is a flow that no longer exists, and `NoFlows` below is what fires
      # when that leaves the selection empty.
      options.flow_ids.each { |id| options.store.get_flow(id).try { |d| details << d } }
      query.try { |q| search(options, q).each { |row| options.store.get_flow(row.id).try { |d| details << d } } }
      if details.empty?
        raise PlanError.new(PlanError::Reason::NoFlows, "no captured flows matched the selection", query)
      end
      details
    end

    # The query's rows. Mirrors `gori run history`'s reading of a QL query exactly, because
    # they are the same grammar and an operator who narrowed a listing expects the same rows
    # to be the ones replayed:
    #
    #   * a query that compiles to NO clause is refused, not run. `QL::EMPTY` matches every
    #     flow, so a typo (`status:>=foo`) would replay the entire history under every
    #     identity — the widest possible reading of the narrowest possible intent.
    #   * `index_pending!` first for an FTS query. Trigram indexing is off-commit (Store V4),
    #     so a `body:` query run right after a capture would silently see fewer rows.
    #   * `raise_on_error: true`. `search` otherwise degrades a failed query to no matches,
    #     which here is indistinguishable from "nothing matched" — and the two need opposite
    #     responses.
    private def self.search(options : PlanOptions, query : String) : Array(Store::FlowRow)
      filter = QL.parse(query)
      if QL.reject_empty?(query, filter)
        raise PlanError.new(PlanError::Reason::BadQuery,
          "query #{query.inspect} did not match any field", query)
      end
      options.store.index_pending! if filter.uses_fts?
      begin
        options.store.search(filter, options.limit, raise_on_error: true)
      rescue ex
        raise PlanError.new(PlanError::Reason::BadQuery,
          "query #{query.inspect} failed: #{ex.message}", ex.message)
      end
    end

    # Split the selection into what will be replayed and what will not, NAMING every
    # refusal. The order of the tests is the TUI's (`AuthorizeController#accept_seed`): the
    # flow's own disqualifications first, then scope, then the duplicate check — so a flow
    # that is both incomplete and out of scope reports the same reason on every surface.
    private def self.partition(details : Array(Store::FlowDetail),
                               identities : Array(Identity),
                               options : PlanOptions,
                               outbound : Gori::Outbound) : {Array(Store::FlowDetail), Array(Skipped)}
      targets = [] of Store::FlowDetail
      skipped = [] of Skipped
      seen = Set(Int64).new
      details.each do |detail|
        row = detail.row
        if reason = skip_reason(detail, identities, options)
          skipped << Skipped.new(row.id, row.method, row.url, reason)
          next
        end
        # LAYER 1, judged on the DIAL target. `check_request` runs the scheme/host the engine
        # will actually connect to through `Outbound.scope_url`, which reduces an
        # absolute-form request line (what the capture proxy stores) to its path and rebuilds
        # it against the dial host — so a Host-header/SSRF capture cannot authorise itself
        # against the spoofed host's rules. Layer 2 (Sandbox + EXCLUDE) still applies per
        # send inside `Fuzz::Sender`, and `Target#blocked` is how a run reports it.
        #
        # WHICH gate this is remains the surface's decision, which is why `outbound` is an
        # argument: `Outbound.cli` leaves an unconfigured project permissive, `Outbound.agent`
        # refuses it, and the TUI's passive path picks the strictest `Outbound.allowlist` of
        # its own accord.
        if outbound.check_request(row.scheme, row.host, row.target).blocked?
          skipped << Skipped.new(row.id, row.method, row.url, :out_of_scope)
          next
        end
        # By FLOW ID, not by endpoint: this is the manual selection, where naming the same
        # capture twice is an accident. Passive replay keys on the endpoint instead, and for
        # its own reason — see `Passive.key`.
        unless seen.add?(row.id)
          skipped << Skipped.new(row.id, row.method, row.url, :duplicate)
          next
        end
        targets << detail
      end
      {targets, skipped}
    end

    # `Passive.skip_reason`, with the unsafe-method refusal lifted when the surface asked for
    # it. One implementation of "can this flow be replayed at all" rather than a second copy
    # of the rules here: `:incomplete`, `:short_circuited` and `:no_effect` are properties of
    # the flow and the identity set, and they hold whoever is asking. The lifted form lives in
    # `Passive.manual_skip_reason` — the TUI's manual queue asks the same question and has to
    # get the same answer, or one surface refuses a flow another one replays.
    private def self.skip_reason(detail : Store::FlowDetail, identities : Array(Identity),
                                 options : PlanOptions) : Symbol?
      return Passive.manual_skip_reason(detail, identities) if options.unsafe_methods?
      Passive.skip_reason(detail, identities)
    end

    # The per-reason tally: the `NothingToSend` detail AND what `Plan#skip_summary` renders,
    # one implementation so the refusal and the report of a partial run agree.
    def self.skip_tally(skipped : Array(Skipped)) : String
      counts = Hash(Symbol, Int32).new(0)
      skipped.each { |s| counts[s.reason] += 1 }
      counts.map { |(reason, n)| "#{n} #{Passive.reason_label(reason)}" }.join(" · ")
    end
  end
end
