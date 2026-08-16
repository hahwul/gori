require "../tab_controller"
require "../authorize_view"
require "../../authorize/engine"
require "../../outbound"
require "../../settings"
require "../../authorize/passive"

module Gori::Tui
  # The Authorize tab: replay one or more captured requests under several identities and read
  # the responses against a baseline to spot broken access control. Single-session and
  # ephemeral — no project DB (like Comparer/JWT). A run is a background fiber whose per-request
  # results arrive through `@events`, drained on the main fiber by `drain_events` (the Jobs
  # registry and view state are touched ONLY there — the invariant `Tui::Jobs` documents).
  class AuthorizeController < TabController
    # How many outcomes one render tick may apply, matching the sibling controllers: a long
    # batch must not spend an unbounded slice of a frame in the drain.
    DRAIN_CAP = 512

    # One message from the run fiber. `gen` stamps the BATCH it belongs to, so an outcome from a
    # batch the operator already stopped can be dropped instead of being counted against the
    # next one. `done` is the terminal marker the fiber always sends last (from an `ensure`), and
    # it — not a counter reaching zero — is what tells the controller the fiber has exited.
    private record Outcome, gen : Int32, entry_id : Int32 = 0,
      target : Authorize::Target? = nil, error : String? = nil, done : Bool = false

    # Ceiling on the queue when PASSIVE replay is filling it. A browse can touch hundreds of
    # authenticated endpoints, and every row here is a request set that will go out again; a
    # queue that grows with the session eventually replays more traffic than the browsing did.
    # Reported when it bites — a cap nobody is told about reads as "passive stopped working".
    PASSIVE_CAP = 200

    # Hosts named in the "outside scope" notice before it goes quiet. A browse touches many
    # third-party origins (analytics, fonts, CDNs) and every one of them would otherwise take
    # the status line.
    UNSCOPED_REPORT_CAP = 3

    # How often the catch-up sweep re-reads recent flows, and how many it looks at — the same
    # shape (and the same reason) as `Probe::Analyzer`'s.
    PASSIVE_CATCHUP_INTERVAL = 30.seconds
    PASSIVE_CATCHUP_SCAN     = 200

    # Endpoints passive replay has already queued this session, so a browser refetching a page
    # does not add a row per load. See `Authorize::Passive.key` for why the key is the endpoint
    # rather than the flow id.
    @passive_seen : Set(String)

    def initialize(host : Host)
      super(host)
      @view = AuthorizeView.new
      @events = Channel(Outcome).new(64)
      @job_id = nil.as(Int32?)
      @gen = 0
      @active_gen = nil.as(Int32?) # non-nil while a run fiber is alive
      @batch_ids = Set(Int32).new
      @batch_size = 0
      @identities_loaded = nil.as(Array(Authorize::Identity)?)
      @passive = false
      @passive_started = false
      @passive_seen = Set(String).new
      @passive_capped = false
      @passive_unscoped = Set(String).new
      @seeds = Channel(Store::FlowDetail).new(64)
    end

    def view : AuthorizeView
      @view
    end

    def tab : Symbol
      :authorize
    end

    def command_scope : Verb::Scope
      Verb::Scope::Authorize
    end

    # --- identities ----------------------------------------------------------

    # The identities every run replays under, loaded from the project on first use.
    #
    # LAZY rather than loaded at `Session.open` the way env vars are: these are TUI-only, and a
    # fresh Runner (and so a fresh controller) is built per project, so switching projects
    # re-reads them for free. Nothing outside the TUI reads them, which is why there is no
    # `#reload` hook — a second gori process editing the same project would go unnoticed here.
    def identities : Array(Authorize::Identity)
      loaded = @identities_loaded
      return loaded if loaded
      stored = Authorize.parse_json(@host.session.store.setting(Store::AUTHORIZE_IDENTITIES_KEY))
      list = stored.empty? ? AuthorizeView.default_identities : stored
      @view.identities = list
      @identities_loaded = list
      list
    end

    # Add or replace one identity. `index` nil = append. Returns false (keeping the form open)
    # when the form could not build one.
    def apply_identity(index : Int32?, identity : Authorize::Identity?) : Bool
      return false unless identity
      list = identities.dup
      if i = index
        return false unless 0 <= i < list.size
        # Editing must not move the baseline: the flag belongs to the list, and the form does
        # not carry it (see AuthorizeIdentityOverlay).
        list[i] = identity.with_baseline(list[i].baseline?)
      else
        list << identity.with_baseline(false)
      end
      replace_identities(list)
      true
    end

    # Write a whole list back — the list card's delete / baseline moves come through here too.
    # Returns whether the project write committed; a false is REPORTED by the caller rather
    # than swallowed, since the operator would otherwise lose the identity on restart with no
    # word.
    def replace_identities(list : Array(Authorize::Identity)) : Bool
      @view.identities = list
      @identities_loaded = list
      @host.session.store.set_setting(Store::AUTHORIZE_IDENTITIES_KEY, Authorize.serialize(list))
    end

    # Editing while a batch is in flight would change the set the running requests are being
    # sent under, halfway through.
    def identities_editable? : Bool
      !running?
    end

    # --- passive replay ------------------------------------------------------

    def passive? : Bool
      @passive
    end

    # Flip unattended replay. OFF by default and never implied by anything else: this is the
    # one control in the tab that puts requests on a target with nobody pressing a key, and
    # gori's whole shape is "the operator decides what leaves the machine" (P4).
    def toggle_passive : Nil
      @passive = !@passive
      if @passive
        start_passive_watcher
        @host.status("authorize: passive replay ON — authenticated GETs will be replayed as they are captured")
      else
        # The watcher fiber stays parked on the channel; it re-checks the flag per event, so
        # turning passive off stops the work without needing to kill (and later re-spawn) it.
        @host.status("authorize: passive replay off")
      end
    end

    # Drains the session's live flow feed on its OWN fiber, exactly as `Probe::Analyzer` drains
    # its parallel feed. It never touches the view: a flow that passes the filter is handed to
    # the main fiber through `@seeds`, and `drain_events` is what adds the row.
    #
    # SELF-LOOP: gori's own replays go out through `Fuzz::Sender`, which dials the origin
    # directly and bypasses the capture proxy, and nothing here writes them back with
    # `insert_flow` — so a shadow request can never come back round as a new flow event. That
    # is a property of the send path, not a guard here; recording a shadow send into History
    # would reintroduce the loop and would need an explicit marker to break it.
    private def start_passive_watcher : Nil
      return if @passive_started
      @passive_started = true
      feed = @host.session.authorize_events
      store = @host.session.store
      spawn(name: "authorize-passive") do
        while ev = feed.receive?
          next unless @passive
          next unless ev.kind == :updated # the response side exists only on the second event
          detail = store.get_flow(ev.id)
          next unless detail
          next unless Authorize::Passive.replayable?(detail)
          select
          when @seeds.send(detail)
          else
            # main fiber behind — drop rather than stall the feed; the next matching flow
            # queues the endpoint anyway, and the queue is a sample, not a ledger.
          end
        end
      rescue Channel::ClosedError
        # project closing
      end
      start_passive_catchup(store)
    end

    # The live feed DROPS on a full channel (see `Store#publish`), and both this consumer and
    # the main fiber can fall behind a burst of browsing. Without a sweep a dropped event is a
    # silently untested endpoint — the same reason `Probe::Analyzer` runs one. Re-reading is
    # free of duplicates because `accept_seed` keys on the endpoint, so a flow that WAS handled
    # is rejected on arrival.
    private def start_passive_catchup(store : Store) : Nil
      spawn(name: "authorize-passive-catchup") do
        loop do
          sleep PASSIVE_CATCHUP_INTERVAL
          next unless @passive
          store.recent_flows(PASSIVE_CATCHUP_SCAN).each do |row|
            break unless @passive
            next unless row.state.complete?
            detail = store.get_flow(row.id)
            next unless detail
            next unless Authorize::Passive.replayable?(detail)
            select
            when @seeds.send(detail)
            else
              break # still behind — the next tick tries again
            end
          end
        rescue DB::Error | SQLite3::Exception
          # store closing / busy — the next tick re-reads
        end
      end
    end

    # Add what the watcher found (main fiber). Returns true when anything landed, so the render
    # loop redraws and `drain_events` knows to consider an auto-run.
    private def drain_seeds : Bool
      added = false
      DRAIN_CAP.times do
        break unless detail = next_seed
        added = true if accept_seed(detail)
      end
      added
    end

    # One queued flow if the watcher found any, else nil — a non-blocking channel poll, the
    # twin of `next_outcome`.
    private def next_seed : Store::FlowDetail?
      select
      when d = @seeds.receive
        d
      else
        nil
      end
    end

    private def accept_seed(detail : Store::FlowDetail) : Bool
      key = Authorize::Passive.key(detail)
      return false if @passive_seen.includes?(key)
      # UNATTENDED sending is gated on the project's scope INCLUDE rules — the strict Layer 1
      # allowlist, the same one Probe's active rules enqueue behind, and deliberately stricter
      # than the manual queue (whose sender applies Sandbox/EXCLUDE alone, because a human
      # picked that request). Passive replays whatever the browser touches, and a browser
      # session reaches a great deal that is not the engagement.
      #
      # Silently is the one way it must not refuse: with no scope configured NOTHING would be
      # replayed and the tab would look broken. Reported once per host, capped, the way Probe
      # rate-limits its own per-host failures.
      if Outbound.allowlist(@host.session.scope)
           .check_request(detail.row.scheme, detail.row.host, detail.row.target).blocked?
        host = detail.row.host
        if @passive_unscoped.size < UNSCOPED_REPORT_CAP && @passive_unscoped.add?(host)
          @host.status("authorize: #{host} is outside project scope — passive replay only sends to scoped hosts")
        end
        return false
      end
      if @view.size >= PASSIVE_CAP
        unless @passive_capped
          @passive_capped = true
          @host.status("authorize: passive queue is full at #{PASSIVE_CAP} — clear it to keep going")
        end
        return false
      end
      @passive_seen << key
      @view.add(detail)
      true
    end

    # Passive's run trigger: whatever the watcher queued goes out as soon as nothing else is in
    # flight. Deliberately routed through the SAME `run(:pending)` the operator's ^R uses, so
    # passive inherits the batch's generation stamp, its stop, and its settling rather than
    # growing a second, subtly different send loop.
    private def maybe_autorun : Nil
      return unless @passive
      return if running?
      return if @view.pending_entries.empty?
      run(:pending)
    end

    # --- cross-tab seeding (Send to Authorize) -------------------------------

    # Append captured flows as requests to test. Returns {added, skipped} — `skipped` counts
    # flows already in the queue, which the caller REPORTS rather than swallowing.
    #
    # Dedup is by flow id and `ids.uniq` runs first, so a double-marked row inside one seed
    # counts as already-queued too. A pruned/stale id is skipped silently: it is not a duplicate,
    # it is a flow that no longer exists, and the caller's "loaded N" already says so by omission.
    def seed_flows(ids : Array(Int64)) : {Int32, Int32}
      queued = @view.queued_flow_ids
      added = 0
      skipped = 0
      ids.uniq.each do |id|
        if queued.includes?(id)
          skipped += 1
          next
        end
        next unless detail = @host.session.store.get_flow(id)
        @view.add(detail)
        queued << id
        added += 1
      end
      {added, skipped}
    end

    # --- run lifecycle -------------------------------------------------------

    def has_target? : Bool
      @view.any_requests?
    end

    # True while the run FIBER is alive — cleared only by its terminal marker, never by a
    # counter. "The count reached zero" and "the fiber has exited" are different events, and
    # only the second one makes it safe to start another batch.
    def running? : Bool
      !@active_gen.nil?
    end

    # Replay a batch under every identity on a background fiber. `mode` picks the batch:
    #
    #   :pending — every request with no result yet (never run, or the send failed)
    #   :all     — every request, re-sending ones that already have a result
    #   :one     — the cursor request alone
    #
    # Requests go out one at a time and each finished one streams back its own Target, so the
    # table fills as the run proceeds. The scope gate (Outbound) is the one Probe active uses.
    def run(mode : Symbol = :pending) : Nil
      return @host.status("send requests here first (Send to Authorize from History)") unless @view.any_requests?
      return @host.status("a run is already in flight") if running?
      batch = select_batch(mode)
      return if batch.nil? # select_batch already said why
      identities = @view.identities
      outbound = Outbound.allowlist(@host.session.scope)
      verify = Settings.verify_upstream?
      # Arm the batch on the MAIN fiber, before anything is spawned: the stop flag has to be
      # cleared here, not in the fiber's teardown, or a stop raised while the previous run was
      # winding down would be swallowed and this run would inherit it.
      @view.reset_stop
      @batch_ids = batch.map(&.id).to_set
      @batch_size = batch.size
      @view.mark_running(@batch_ids)
      gen = (@gen += 1)
      @active_gen = gen
      noun = "#{batch.size} request#{batch.size == 1 ? "" : "s"}"
      @job_id = @host.jobs.start(:authorize, noun, Jobs::Goto.new(:authorize))
      @host.status("authorize: replaying #{noun} under #{identities.size} identities…")
      # Snapshot the details now — the background fiber must not touch the view.
      jobs = batch.map { |e| {e.id, e.detail} }
      stop = -> { @view.stop_requested? }
      spawn(name: "authorize-run") do
        engine = Authorize::Engine.live(outbound, verify)
        jobs.each do |(eid, detail)|
          break if @view.stop_requested?
          begin
            # nil = the stop landed part-way through this request's identities, so it has no
            # complete result and must not claim a verdict (see `Authorize::Engine#run`).
            if target = engine.run(detail, identities, stop)
              @events.send(Outcome.new(gen, eid, target: target))
            end
          rescue ex
            @events.send(Outcome.new(gen, eid, error: ex.message || "authorize run failed"))
          end
        end
      rescue ex
        # Anything the per-request rescue cannot see — building the engine, for one. Without
        # this the fiber would die before its marker and leave the tab wedged as "running".
        @events.send(Outcome.new(gen, error: ex.message || "authorize run failed"))
      ensure
        # ALWAYS last, and there is exactly one sender, so the channel's FIFO order puts it
        # after every outcome it follows. This marker — not a counter — ends the batch.
        @events.send(Outcome.new(gen, done: true))
      end
    end

    # The entries `mode` selects, or nil when there is nothing to do — in which case this has
    # already said why. An empty batch is never silent: "nothing happened" and "everything is
    # already done" look identical from the outside otherwise.
    private def select_batch(mode : Symbol) : Array(AuthorizeView::Entry)?
      case mode
      when :all
        batch = @view.runnable
        return batch unless batch.empty?
        @host.status("nothing to run")
      when :one
        if e = @view.selected_entry
          return [e] unless e.state == :running
          @host.status("that request is already running")
        else
          @host.status("select a request first")
        end
      else
        batch = @view.pending_entries
        return batch unless batch.empty?
        @host.status("every request already has a result — ⇧R re-runs them all")
      end
      nil
    end

    # Ask the run to stop. Cooperative: the flag is polled between requests AND between
    # identities, so the request in flight stops at its next identity rather than mid-send.
    def stop : Nil
      return @host.status("nothing is running") unless running?
      return @host.status("already stopping…") if @view.stop_requested?
      @view.request_stop
      @host.status("authorize: stopping…")
    end

    # Drop the cursor request from the queue. Refused while it is mid-run — its outcome is
    # still on the way.
    def remove_selected : Nil
      return @host.status("nothing to remove") unless @view.any_requests?
      unless @view.remove_selected
        return @host.status("that request is still running — ^X to stop it first")
      end
      @host.status("authorize: removed — #{@view.size} left")
    end

    def clear : Nil
      return @host.status("a run is in flight — ^X to stop it first") if running?
      @view.clear
      @host.status("authorize: cleared")
    end

    # Drain finished requests (main fiber, per render tick). Returns true when something landed.
    def drain_events : Bool
      drained = drain_seeds
      DRAIN_CAP.times do
        break unless o = next_outcome
        apply_outcome(o)
        drained = true
      end
      # After the outcomes, not before: a batch that just finished frees the runner for
      # whatever the watcher queued while it was busy.
      maybe_autorun
      drained
    end

    # One finished request if any is queued, else nil — a non-blocking channel poll.
    private def next_outcome : Outcome?
      select
      when o = @events.receive
        o
      else
        nil
      end
    end

    private def apply_outcome(o : Outcome) : Nil
      # A batch the operator already stopped can still have outcomes in flight. They describe
      # rows this run no longer owns, so drop them rather than letting them touch the view or
      # end the current batch early.
      return unless o.gen == @active_gen
      return finish_batch if o.done
      # A batch-level error (no entry): report it and let the marker close the batch.
      return @host.status("authorize: #{o.error}") if o.entry_id == 0
      if t = o.target
        @view.apply_result(o.entry_id, t)
      else
        @view.apply_error(o.entry_id, o.error || "authorize run failed")
      end
    end

    # The run fiber has exited. Settle any row it left marked running, close the job, and say
    # what actually happened.
    private def finish_batch : Nil
      stopped = @view.stop_requested?
      @view.settle_running(@batch_ids)
      # Summarise BEFORE dropping the batch — the counts are scoped to it.
      summary = run_summary(stopped)
      @batch_ids = Set(Int32).new
      @active_gen = nil
      if id = @job_id
        @host.jobs.finish(id, stopped ? :stopped : :done, summary)
        @job_id = nil
      end
      @host.status(summary)
    end

    # What THIS run did — counted over the batch, never over the queue. A queue-wide count
    # credits the current run with work earlier runs did ("ran 6" for a three-request batch
    # because six rows happen to hold results), and after a stop it would also claim requests
    # gori never sent.
    private def run_summary(stopped : Bool) : String
      done = @view.completed_in(@batch_ids)
      bypasses = @view.bypasses_in(@batch_ids)
      if stopped
        tail = bypasses > 0 ? " · #{bypasses} bypass#{bypasses == 1 ? "" : "es"}" : ""
        return "authorize: stopped — #{done} of #{@batch_size} replayed#{tail}"
      end
      if bypasses > 0
        "authorize: ran #{done} · #{bypasses} identity result#{bypasses == 1 ? "" : "s"} matched the baseline — review for access-control bypass"
      else
        "authorize: ran #{done} · no identity matched the baseline"
      end
    end

    # --- render / input ------------------------------------------------------

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) do |inner|
        @view.render(screen, inner, focused)
      end
    end

    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if ev.ctrl? || ev.alt?
      key = ev.key
      case
      when key.up?, key.lower_k?
        @view.move_row(-1)
        true
      when key.down?, key.lower_j?
        @view.move_row(1)
        true
      when key.tab?
        @view.move_trial(1)
        true
      when key.page_up?
        @view.scroll_detail(-10)
        true
      when key.page_down?
        @view.scroll_detail(10)
        true
      when key.escape?
        @host.request_focus(:menu)
        true
      else
        false
      end
    end

    def handle_wheel(step : Int32) : Bool
      @view.scroll_detail(step)
      true
    end

    def body_hint(focus : Symbol) : String
      passive = @passive ? " · PASSIVE on" : ""
      unless @view.any_requests?
        return "i identities · p passive · Send to Authorize from History to begin#{passive}"
      end
      return "↑/↓ request · ⇥ identity · ^X stop#{passive} · space cmds" if running?
      "↑/↓ request · ⇥ identity · ^R run · ⇧R all · i identities · p passive#{passive} · space cmds"
    end
  end
end
