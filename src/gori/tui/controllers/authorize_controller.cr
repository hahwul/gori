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
      @batch_declined = 0
      @batch_declined_reason = nil.as(Symbol?)
      @identities_loaded = nil.as(Array(Authorize::Identity)?)
      # The PERSISTED names the cached list was seeded against — see `merge_peer_slots`.
      @identities_base = Set(String).new
      @passive = false
      @passive_started = false
      @passive_seen = Set(String).new
      @passive_capped = false
      @passive_unscoped = Set(String).new
      @seeds = Channel(Store::FlowDetail).new(64)
      @passive_seen_count = 0
      @passive_closed = false
      @passive_skips = Hash(Symbol, Int32).new(0)
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

    # The identities every run replays under. An identity IS a `Gori::SessionSlot`, so this
    # reads the session's LIVE slot registry rather than the settings row underneath it
    # (`Session#slots`, loaded at project open and shared with `Bindings`/`Env.overlay_slot`).
    #
    # That matters both ways round. Reading it means an identity added from the slot picker,
    # `gori run session add` or MCP shows up here; WRITING through it (see
    # `replace_identities`) means the send seams see the edit — a card that wrote the settings
    # row directly left the live registry holding the pre-edit list, so the Authorize tab and
    # a Repeater send disagreed about what "admin" was until the project was reopened.
    #
    # Still cached in `@identities_loaded`: the card mutates the array it is handed and
    # compares against this one, and a fresh `dup` per read would make every in-place edit
    # invisible to `AuthorizeView#identities=`.
    def identities : Array(Authorize::Identity)
      loaded = @identities_loaded
      return loaded if loaded
      stored = @host.session.slots.slots
      list = stored.empty? ? AuthorizeView.default_identities : stored
      @view.identities = list
      @identities_loaded = list
      # The PERSISTED names, not `list`: with an empty row `list` is the built-in pair, which
      # was never in the row — reading it as the base would make every default look like a slot
      # a peer had just deleted, and `merge_peer_slots` would drop it.
      @identities_base = stored.map(&.name).to_set
      list
    end

    # Add or replace one identity. `index` nil = append. Returns false (keeping the form open)
    # when the form could not build one.
    def apply_identity(index : Int32?, identity : Authorize::Identity?) : Bool
      return false unless identity
      list = identities.dup
      if i = index
        return false unless 0 <= i < list.size
        # Editing must not move the baseline, and must not drop the slot's RULE membership:
        # both belong to the list rather than to the form, and the form carries neither (see
        # AuthorizeIdentityOverlay). Rules are the half that fails silently — the extract
        # rules a slot claims decide which binding table `$NAME` resolves out of at EVERY send
        # seam, so an edit that cleared them re-pointed the operator's `$SESSION` at the global
        # table while the card went on showing the identity they meant. `gori run session edit`
        # and MCP `update_session_slot` both keep them; this was the one surface that did not.
        list[i] = identity.with_baseline(list[i].baseline?).with_rules(list[i].rules)
      else
        list << identity.with_baseline(false)
      end
      # The write's outcome is the caller's answer: `false` keeps the form open, which is what
      # stops an identity from looking saved and being gone at the next restart.
      unless replace_identities(list)
        @host.status("authorize: the project could not be written — identity not saved")
        return false
      end
      true
    end

    # Write a whole list back — the list card's delete / baseline moves come through here too.
    # Returns whether the project write committed; a false is REPORTED by the caller rather
    # than swallowed, since the operator would otherwise lose the identity on restart with no
    # word.
    def replace_identities(list : Array(Authorize::Identity)) : Bool
      # Re-read the persisted list BEFORE this read-modify-write. `list` was built from
      # `identities`, which caches, over a registry filled once at project open — so a slot
      # `gori run session add`, MCP `create_session_slot` or a second TUI wrote since would be
      # deleted by this whole-list save, with no error and no row that ever showed it existed.
      # Same refresh and the same reason as MCP's `fresh_slots`.
      @host.session.slots.reload
      merged = merge_peer_slots(list, @host.session.slots.slots)
      # Through the live registry, not `set_setting`: `SessionSlots#save` persists the same row
      # AND updates the object every send seam consults, dropping the active pointer when the
      # slot it named is gone. Writing the row by hand left the two out of step — the tab
      # showed the edit, `Env.overlay_slot` kept applying the old overlay.
      return false unless @host.session.slots.save(merged)
      # ONLY over a committed write. These three are what the NEXT write is built and merged
      # against, so advancing them over a refused one took the just-deleted name out of the
      # base while the row still held it: the operator's next edit reloaded that name, found it
      # in neither the base nor the list, and appended it as a peer ADD — the delete the store
      # had refused silently undone, overlay and all.
      @view.identities = merged
      @identities_loaded = merged
      @identities_base = merged.map(&.name).to_set
      true
    end

    # Reconcile three lists: the names this card was SEEDED with (`@identities_base`), the list
    # the write carries, and the row as it stands NOW. Every difference between the base and
    # `fresh` is a peer's edit, and both directions have to be honoured — a merge that only
    # ADDS re-persists a slot a peer deleted, which is the same clobber from the other side.
    #
    #   in `fresh`, in neither base nor `list` -> a peer ADDED it: carry it over
    #   in base and in `list`, not in `fresh`  -> a peer DELETED it: drop it
    #   in base, not in `list`                 -> the OPERATOR deleted it: stays deleted
    private def merge_peer_slots(list : Array(Authorize::Identity),
                                 fresh : Array(Authorize::Identity)) : Array(Authorize::Identity)
      base = @identities_base
      live = fresh.map(&.name).to_set
      kept = list.reject { |s| base.includes?(s.name) && !live.includes?(s.name) }
      added = fresh.reject { |s| base.includes?(s.name) || kept.any?(&.name.==(s.name)) }
      return list if added.empty? && kept.size == list.size # no peer edit either way
      # The card is the surface the operator is reading, so ITS baseline stands: a peer slot
      # arriving with the flag must not make a second one. `SessionSlots#save` takes the list
      # as given — only the per-slot edits go through `with_one_baseline`.
      added = added.map(&.with_baseline(false)) if kept.any?(&.baseline?)
      merged = kept + added
      # A peer's delete can take the baseline with it, and a set judged against no baseline is
      # a run with no verdict. Promote the first survivor — the rule
      # `AuthorizeIdentitiesOverlay#delete_selected` already applies to the card's own delete.
      merged[0] = merged[0].with_baseline(true) if !merged.empty? && merged.none?(&.baseline?)
      merged
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
        # Say it HERE, at the keypress, not later when a flow happens to be skipped. With no
        # scope include rule the allowlist refuses every host, so passive can never do
        # anything — and the operator is browsing in another window by the time the per-host
        # notice fires, if they are looking at gori at all. "Nothing happened" is the one
        # outcome this mode must never leave unexplained.
        if no_scope?
          @host.status("authorize: passive replay ON, but this project has no scope include rule — " \
                       "nothing is replayed until you add one (Project → Scope)")
        else
          @host.status("authorize: passive replay ON — in-scope requests any identity changes will be replayed")
        end
        @view.passive_note = passive_readout
      else
        @view.passive_note = nil
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
    # directly and bypasses the capture proxy, and nothing here writes THOSE back with
    # `insert_flow` — so a shadow request can never come back round as a new flow event.
    #
    # That is no longer the whole story, and `proxy_origin?` below is the explicit marker this
    # comment used to ask for. The Repeater now records its sends by default, so `^R` publishes
    # a flow event on the same feed: without the guard, every hand-driven send would fan out
    # into one shadow request per identity, and a `send_request` from an agent beside the TUI
    # would too. Passive replay is a lens on WHAT THE BROWSER TOUCHED — a request gori made is
    # not that, and replaying it says nothing the operator did not already ask for by hand.
    private def start_passive_watcher : Nil
      return if @passive_started
      @passive_started = true
      feed = @host.session.authorize_events
      store = @host.session.store
      spawn(name: "authorize-passive") do
        while ev = feed.receive?
          offer_passive_seed(store, ev)
        end
      rescue Channel::ClosedError
        # project closing
      ensure
        # The feed only ends when the session closes it, which is also the signal the catch-up
        # loop needs — nothing else would ever tell that timer to stop.
        @passive_closed = true
      end
      start_passive_catchup(store)
    end

    # One live-feed event, off the main fiber.
    #
    # EXTRACTED so it can carry the same `DB::Error | SQLite3::Exception` rescue the catch-up
    # sweep has always had, and for the same reason: `get_flow` reads the store, and a store
    # that is closing or momentarily busy raises. Inline in the `while` above, that raise
    # unwound the whole watcher — and because the watcher's `ensure` sets `@passive_closed`,
    # which is the ONLY thing that stops the catch-up timer, one transient busy killed BOTH
    # halves of passive replay for the rest of the session while printing its backtrace onto
    # the alternate screen (#411). Dropping the flow instead costs a delay, not the endpoint:
    # the sweep re-offers it within PASSIVE_CATCHUP_INTERVAL.
    private def offer_passive_seed(store : Store, ev : Store::FlowEvent) : Nil
      return unless @passive
      return unless ev.kind == :updated # the response side exists only on the second event
      detail = store.get_flow(ev.id)
      return unless detail
      return unless proxy_origin?(detail.row)
      # NO filtering here. The decision needs the identity set and its outcome needs to be
      # COUNTED, and both live on the main fiber — a flow silently dropped on this side is
      # exactly how this mode came to look broken.
      select
      when @seeds.send(detail)
      else
        # main fiber behind — drop rather than stall the feed; the next matching flow
        # queues the endpoint anyway, and the queue is a sample, not a ledger.
      end
    rescue DB::Error | SQLite3::Exception
      # store closing / busy — the catch-up sweep re-reads (see start_passive_catchup)
    rescue ex
      # And everything else, at the SAME depth. Narrowing to the two DB classes only moved the
      # original failure one exception over: any other raise from here still unwound the watcher
      # and, through its `ensure`, stopped the catch-up sweep with it. One bad flow must cost one
      # flow. `@seeds` is never closed, so nothing legitimate is being swallowed — the watcher's
      # own `rescue Channel::ClosedError` is for `feed`, which this does not touch.
      ::Log.error(exception: ex) { "authorize passive seed dropped" }
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
          break if @passive_closed # the session went away; nothing else stops this timer
          next unless @passive
          store.recent_flows(PASSIVE_CATCHUP_SCAN).each do |row|
            break unless @passive
            next unless row.state.complete?
            next unless proxy_origin?(row) # same guard as the live feed — see start_passive_watcher
            detail = store.get_flow(row.id)
            next unless detail
            # Skip what is already queued HERE rather than letting `accept_seed` count it as a
            # duplicate: this loop re-offers the same 200 rows every 30s, so counting them made
            # the readout climb to thousands "seen" on an idle session and left `already queued`
            # permanently winning the skip tally — hiding the reason worth reading.
            next if @passive_seen.includes?(Authorize::Passive.key(detail))
            select
            when @seeds.send(detail)
            else
              break # still behind — the next tick tries again
            end
          end
        rescue DB::Error | SQLite3::Exception
          # store closing / busy — the next tick re-reads
        rescue ex
          # Same depth, deliberately: one level out (on the spawn block) this reads as a rescue
          # but still ENDS the sweep, and nothing restarts it. The sweep is the only cover for
          # the live feed's dropped events (`Store#publish` drops on a full channel), so losing
          # it degrades passive replay silently while the tab still reads ON — the exact shape
          # this mode came to look broken in. A bad tick costs a tick.
          ::Log.error(exception: ex) { "authorize passive catch-up tick failed" }
        end
      end
    end

    # Is this a flow passive replay is a lens on at all? `Authorize::Passive` owns the answer —
    # this is a cheap pre-filter over the same predicate, not a second rule.
    #
    # `skip_reason` refuses these anyway, so nothing would be SENT without it. What it buys is
    # that hammering `^R` does not fill the queue with one skipped row per send: the readout is
    # meant to be read, and a log of the operator's own keystrokes is not a readout.
    private def proxy_origin?(row : Store::FlowRow) : Bool
      !Authorize::Passive.gori_originated?(row)
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

    # Decide one flow the watcher handed over, COUNTING the outcome either way. Every refusal
    # is tallied by reason so the tab can say what passive is doing instead of appearing idle.
    private def accept_seed(detail : Store::FlowDetail) : Bool
      @passive_seen_count += 1
      if reason = Authorize::Passive.passive_skip_reason(detail, identities)
        @passive_skips[reason] += 1
        return false
      end
      # UNATTENDED sending is gated on the project's scope INCLUDE rules — the strict Layer 1
      # allowlist Probe's active rules enqueue behind, and deliberately stricter than the manual
      # queue (whose sender applies Sandbox/EXCLUDE alone, because a human picked that request).
      # Passive follows the browser, and a browser session reaches a great deal that is not the
      # engagement.
      if Outbound.allowlist(@host.session.scope)
           .check_request(detail.row.scheme, detail.row.host, detail.row.target, detail.row.port).blocked?
        @passive_skips[:out_of_scope] += 1
        host = detail.row.host
        if @passive_unscoped.size < UNSCOPED_REPORT_CAP && @passive_unscoped.add?(host)
          @host.status("authorize: #{host} is outside project scope — passive replay only sends to scoped hosts")
        end
        return false
      end
      key = Authorize::Passive.key(detail)
      if @passive_seen.includes?(key)
        @passive_skips[:duplicate] += 1
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

    # What passive has actually done, as one line for the tab. Without it "nothing happened"
    # and "nothing matched" are the same picture, which is how this mode read as broken.
    private def passive_readout : String
      return "passive replay on — add a scope include rule to replay anything" if no_scope?
      if why = identity_problem(identities)
        return "passive replay on — #{why}"
      end
      return "passive replay on — waiting for traffic" if @passive_seen_count.zero?
      queued = @passive_seen.size
      top = @passive_skips.max_by? { |(_, n)| n }
      tail = top ? " · #{top[1]} skipped (#{Authorize::Passive.reason_label(top[0])})" : ""
      "passive replay on — #{@passive_seen_count} seen · #{queued} queued#{tail}"
    end

    private def no_scope? : Bool
      @host.session.scope.include_count.zero?
    end

    # Passive's run trigger: whatever the watcher queued goes out as soon as nothing else is in
    # flight. Deliberately routed through the SAME `run(:pending)` the operator's ^R uses, so
    # passive inherits the batch's generation stamp, its stop, and its settling rather than
    # growing a second, subtly different send loop.
    private def maybe_autorun : Nil
      return unless @passive
      return if running?
      # A stop the operator asked for OUTLIVES the batch it stopped. `finish_batch` settles the
      # un-run rows back to :pending, so without this the very next drain tick saw pending work,
      # called `run`, and `run`'s `reset_stop` erased the stop — ^X could not stop anything
      # while passive was on, which is the operator losing control of what leaves the machine.
      # Cleared by the next explicit run, or by switching passive off and on.
      return if @view.stop_requested?
      return if @view.auto_pending_entries.empty?
      # The set itself, asked here rather than discovered inside `run`: a refusal there marks
      # nothing, so the rows stay unanswered and this fires again on the very next tick. The
      # readout carries the reason; the loop does not.
      return if identity_problem(identities)
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
                # `identities`, not `@view.identities`: the loader is what reads the project's persisted
                # set, and the view is seeded with the built-in defaults at construction. Reading the
                # view here replayed a reopened project under as-captured + anonymous while the header
                # advertised the same two — the persisted identities were silently ignored on every
                # manual run of a fresh session.
      idents = identities
      batch = comparable_batch(batch, idents)
      return if batch.nil? # comparable_batch already said why
      outbound = Outbound.allowlist(@host.session.scope)
      verify = Settings.verify_upstream?
      # The session's LIVE HostOverrides — the one mutex-guarded instance the Project tab's
      # HOST OVERRIDES pane edits in place and the proxy dials from — not a
      # `HostOverrides.load(store)` of our own. The distinction is the whole reason this is
      # read here: a snapshot taken when the tab was built would be frozen at project open,
      # so an operator who notices a bad route, fixes it in the Project tab and presses run
      # again would keep getting the old address with nothing on screen to say why. Read on
      # the MAIN fiber and handed to the spawned fiber below, like `outbound` above; the
      # object itself is safe to share (that is what its mutex is for).
      overrides = @host.session.host_overrides
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
      @host.status("authorize: replaying #{noun} under #{idents.size} identities…")
      # Snapshot the details now — the background fiber must not touch the view.
      jobs = batch.map { |e| {e.id, e.detail} }
      stop = -> { @view.stop_requested? }
      spawn(name: "authorize-run") do
        engine = Authorize::Engine.live(outbound, verify, overrides: overrides)
        jobs.each do |(eid, detail)|
          break if @view.stop_requested?
          begin
            # nil = the stop landed part-way through this request's identities, so it has no
            # complete result and must not claim a verdict (see `Authorize::Engine#run`).
            if target = engine.run(detail, idents, stop)
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

    # What this identity set can actually say something about, or nil when the answer is
    # nothing — in which case this has already said why.
    #
    # Two refusals, in the order a `Plan` makes them. FEWER THAN TWO IDENTITIES is not a run at
    # all: every trial would be the baseline judged against itself, and the summary would read
    # "no identity matched the baseline" — a clean bill of health for a test that compared
    # nothing, the failure `nothing_sent` exists to keep apart from `enforced`. `gori run
    # authorize` and MCP `authorize_start` both refuse it (`PlanError::NoIdentities`); the tab
    # used to send anyway. Then the per-request question, below.
    private def comparable_batch(batch : Array(AuthorizeView::Entry),
                                 idents : Array(Authorize::Identity)) : Array(AuthorizeView::Entry)?
      if why = identity_problem(idents)
        @host.status("authorize: #{why}")
        return nil
      end
      decline_unchanged(batch, idents)
    end

    # Why this identity SET cannot produce a comparison, as the sentence to show, or nil when
    # it can. A property of the set and not of any request, which is what makes it the wrong
    # thing to mark rows with — and the reason `maybe_autorun` has to ask it BEFORE it calls
    # `run`. Without that, passive found the same unanswered rows on every drain tick, called
    # `run`, was refused, and rewrote the status line with the refusal for as long as the mode
    # stayed on. `passive_readout` reads it too, because "why is nothing happening" is the one
    # question an unattended mode must always be able to answer.
    private def identity_problem(idents : Array(Authorize::Identity)) : String?
      if idents.size < 2
        return "#{idents.size} identity compares nothing — press i and add at least one " \
               "besides the baseline"
      end
      # The form refuses a duplicate as you type one, which covers the name an operator adds
      # HERE and nothing else: a set that arrived already holding two — a hand-edited settings
      # row, `gori run session add admin` and then `Admin` (`SessionSlots#find` is
      # case-sensitive, so both take), an older build — reached the results table as two rows
      # under one label, with no way to say which session produced which verdict. `Plan`
      # refuses it for the headless surfaces; this is the same rule for the queue.
      if dup = duplicate_name(idents)
        return "two identities are called #{dup.inspect} — press i and rename one; the name " \
               "is what tells the result rows apart"
      end
      nil
    end

    # The first name a second identity repeats, or nil. Case-insensitive, matching the form's
    # own check: `admin` and `Admin` are two rows a person reads as one.
    private def duplicate_name(idents : Array(Authorize::Identity)) : String?
      seen = Set(String).new
      idents.each { |id| return id.name unless seen.add?(id.name.downcase) }
      nil
    end

    # Drop the entries this identity set cannot say anything about, MARKING each one, and
    # return what is left (nil when nothing is). `Passive.manual_skip_reason` is the shared
    # rule — the same one `gori run authorize` and MCP apply to a flow a human named — so the
    # three surfaces decline the same request for the same reason.
    #
    # The one this exists for is `:no_effect`. Send a public page (no Cookie, no
    # Authorization) to the tab and the built-in "anonymous" identity removes headers that are
    # not there: every trial ships byte-identical bytes, every response matches by
    # construction, and the row lights up `⚠ 1 same` — a broken-access-control finding
    # manufactured out of nothing, on a page with no access control to break. The queue is the
    # only surface that used to run it, because it was the only one that never asked.
    #
    # Marked rather than silently dropped, and stamped with the identity revision: the refusal
    # holds for THIS set, so adding an identity that sets a session makes the row pending again
    # and ^R picks it straight back up.
    private def decline_unchanged(batch : Array(AuthorizeView::Entry),
                                  idents : Array(Authorize::Identity)) : Array(AuthorizeView::Entry)?
      declined = [] of Symbol
      kept = batch.reject do |e|
        reason = Authorize::Passive.manual_skip_reason(e.detail, idents)
        next false unless reason
        @view.apply_skip(e.id, reason)
        declined << reason
        true
      end
      @batch_declined = declined.size
      @batch_declined_reason = declined.first?
      return kept unless kept.empty?
      @host.status("authorize: nothing to send — #{skip_phrase(declined.size, declined.first?)}")
      nil
    end

    # "2 requests skipped (no identity changes them)" — the count and the FIRST reason, in the
    # words every other surface prints for it.
    private def skip_phrase(count : Int32, reason : Symbol?) : String
      label = reason ? " (#{Authorize::Passive.reason_label(reason)})" : ""
      "#{count} request#{count == 1 ? "" : "s"} skipped#{label}"
    end

    # Ask the run to stop. Cooperative: the flag is polled between requests AND between
    # identities, so the request in flight stops at its next identity rather than mid-send.
    def stop : Nil
      return @host.status("nothing is running") unless running?
      return @host.status("already stopping…") if @view.stop_requested?
      @view.request_stop
      @host.status("authorize: stopping…")
    end

    # Project-level halt (`Runner#stop_all_jobs`): the engine fiber owns its own sockets and
    # kept sending after the operator was back at the picker, with the job pinned at
    # `running` and nothing that could stop it — the exact gap the other six job-owning
    # controllers had already closed. Same `request_stop` + `jobs.finish(:stopped, …)` pair
    # `finish_batch` applies; the fiber's next poll sees the flag and its outcomes are then
    # dropped by the generation check.
    def stop_all : Nil
      return unless running?
      @view.request_stop
      if id = @job_id
        @host.jobs.finish(id, :stopped, "project closed")
        @job_id = nil
      end
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

    # The one clear-all verb that used to go straight through. It was menu-only when it was
    # written, and the space menu is itself a deliberate act — but ⇧X made it one keystroke,
    # and the other three (`history_clear`, `probe_clear`, `activity_clear`) have always asked
    # first. A shared chord has to mean a shared contract, or the tab an operator learns the
    # gesture on is not the tab it costs them something on.
    #
    # HAND-WRAPPED: `ConfirmDialog` splits on '\n' and nothing else and caps the card at 60
    # columns, so a line written as prose is truncated (the note on `activity_clear`). The
    # count is named because "the queue" understates what goes with it — every identity's
    # result for every request, which is the work the tab exists to produce.
    def clear : Nil
      return @host.status("a run is in flight — ^X to stop it first") if running?
      n = @view.size
      return @host.status("authorize: nothing to clear") if n <= 0
      @host.confirm("CLEAR AUTHORIZE",
        "Empty the queue of #{n} request#{n == 1 ? "" : "s"}?\n\n" \
        "Every identity's result goes with them.\n" \
        "This can't be undone.",
        confirm_label: "clear", danger: true) { clear_now }
    end

    # The wipe itself, past the confirm.
    private def clear_now : Nil
      @view.clear
      # The dedup set and the cap notice go with the queue. The cap's own advice is "clear it to
      # keep going", and leaving the keys behind made that false: every endpoint already seen
      # would be skipped as a duplicate forever, with its results gone.
      @passive_seen.clear
      @passive_capped = false
      @passive_seen_count = 0
      @passive_skips.clear
      # The per-host "outside scope" notice goes with them. It is capped so a browse cannot
      # take the status line, and a cap that outlives the queue it was counting made the
      # notice a once-per-session event — silence for every host reached after an operator
      # cleared the tab and fixed the scope.
      @passive_unscoped.clear
      @view.passive_note = passive_readout if @passive
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
      # The readout is what the tab shows while the queue is still empty, which is exactly the
      # stretch an operator is asking "is this doing anything?".
      @view.passive_note = passive_readout if @passive
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
      unanswered = @view.unanswered_in(@batch_ids)
      # What the batch DECLINED to send rides on every summary. A run that skipped half its
      # batch and reported only what it replayed is a run whose selection quietly shrank.
      skips = @batch_declined > 0 ? " · #{skip_phrase(@batch_declined, @batch_declined_reason)}" : ""
      if empty_handed = empty_handed_summary(done, unanswered)
        return "#{empty_handed}#{skips}"
      end
      # A PARTIAL failure still has to travel: the counts below are drawn from the requests
      # that answered, so without this "no identity matched the baseline" would speak for the
      # ones that never did.
      unreached = unanswered > 0 ? " · #{unanswered} could not be reached" : ""
      # …and so does a baseline that was itself refused: those rows are `review` by
      # construction and the count below cannot speak for them either. Same sentence the CLI
      # summary and the MCP headline carry.
      anchored = (n = @view.baseline_denied_in(@batch_ids)) > 0 ? " · #{n} had a denied baseline" : ""
      if stopped
        tail = bypasses > 0 ? " · #{bypasses} bypass#{bypasses == 1 ? "" : "es"}" : ""
        return "authorize: stopped — #{done} of #{@batch_size} replayed#{tail}#{unreached}#{anchored}#{skips}"
      end
      if bypasses > 0
        "authorize: ran #{done} · #{bypasses} identity result#{bypasses == 1 ? "" : "s"} matched the baseline — review for access-control bypass#{unreached}#{anchored}#{skips}"
      else
        "authorize: ran #{done} · no identity matched the baseline#{unreached}#{anchored}#{skips}"
      end
    end

    # The batch produced NO evidence at all, as the sentence to show — or nil when at least
    # one request was actually compared.
    #
    # This exists because with nothing compared, `bypasses` is zero and so is the review
    # count, which is indistinguishable from a target that held: the summary below would read
    # "no identity matched the baseline" about traffic that never left the machine, or about a
    # host that never answered.
    #
    # The test is the SUM of the two counts, not each on its own. They are disjoint —
    # `Target#unanswered?` yields to `fully_blocked?` — and a batch that is part gate-refused
    # and part unreachable compared exactly as little as one that is all of either, so testing
    # them separately let that mixture fall straight through to the clean-sounding line. The
    # other two surfaces already sum them (`report_authorize_empty_handed`, `authorize_verdict`).
    #
    # The reasons are still reported apart, because the operator fixes them differently: a
    # scope rule, or a route.
    private def empty_handed_summary(done : Int32, unanswered : Int32) : String?
      blocked = @view.blocked_in(@batch_ids)
      return nil unless done > 0 && blocked + unanswered == done
      parts = [] of String
      if blocked > 0
        why = @view.blocked_reason_in(@batch_ids)
        parts << "#{blocked} refused before the socket#{why ? " (#{why})" : ""}"
      end
      if unanswered > 0
        why = @view.unanswered_reason_in(@batch_ids)
        parts << "#{unanswered} whose every send failed#{why ? " (#{why})" : ""}"
      end
      "authorize: nothing was compared — #{done} request#{done == 1 ? "" : "s"} · " \
      "#{parts.join(" · ")} · this is not a result"
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
        # ↑ on the first request — or on the empty placeholder, which has no cursor —
        # pops focus back to the tab bar, the same exit esc takes. Clamping there instead
        # left the one key an operator reaches for to walk out of the list looking dead
        # (History/Issues/Intercept all pop from their top row).
        @view.at_top? ? @host.request_focus(:menu) : @view.move_row(-1)
        true
      when key.down?, key.lower_j?
        @view.move_row(1)
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

    # --- the request-list `/` filter (a text sub-mode the shell claims ahead of the focus ring) ---
    def querying? : Bool
      @view.filter_editing?
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      @view.handle_filter_key(ev)
    end

    def set_preedit(text : String) : Bool
      @view.set_filter_preedit(text)
    end

    def body_badge : Symbol
      querying? ? :editor : :body
    end

    # `/` — narrow the queue by method / host / path / verdict. Refused with nothing queued.
    def authorize_filter : Nil
      return @host.status("nothing to filter — Send to Authorize from History to begin") unless @view.any_requests?
      @view.filter_start
    end

    # `y`: the selected request as `METHOD host/path`.
    def authorize_copy : Nil
      e = @view.selected_entry
      copy_text(e ? "#{e.method} #{e.host_path}" : "")
    end

    # ⇥ / ⇧⇥ step the identity sub-cursor — the focus-ring hook, not a `key.tab?` arm: the
    # Runner claims ⇥ for the ring BEFORE the body sees a key, so the arms that used to sit
    # in `handle_body_key` never ran and the `⇥ identity` the hint promised went to the tab
    # bar instead. The pair, not just ⇥: the sub-cursor wraps, so with eight identities
    # stepping BACK one row meant seven forward presses. Always true — the identities are a
    # ring of their own, and esc is the way out to the tab bar.
    def pane_advance(dir : Int32) : Bool
      return false unless @view.any_requests?
      @view.move_trial(dir)
      true
    end

    # Home/End jump the response detail to its ends (PgUp/PgDn page it from the body arms).
    def body_scroll(delta : Int32) : Bool
      return false unless delta.abs >= Runner::JUMP_ROWS
      @view.scroll_detail(delta)
      true
    end

    def body_hint(focus : Symbol) : String
      passive = @passive ? " · PASSIVE on" : ""
      unless @view.any_requests?
        return keys("{authorize.identities} identities · {authorize.passive} passive · Send to Authorize from History to begin#{passive}")
      end
      return @view.filter_hint if querying?
      return keys("↑/↓ request · ⇥ identity · {authorize.stop} stop#{passive} · space cmds") if running?
      # `⇧X clear` is named here and NOT in the running branch above: that one is deliberately
      # the two keys a run leaves meaningful, and "empty the queue" is not the thing to put in
      # front of an operator watching one go out. Resolved through the keymap so a rebind
      # reaches the hint; the rest of this line is still literal, as its siblings are.
      keys("↑/↓ request · ⇥ identity · {authorize.run} run · {authorize.run-all} all · {authorize.identities} identities · {authorize.passive} passive#{passive} · {authorize.filter} filter · {authorize.copy} copy · {authorize.clear} clear · space cmds")
    end
  end
end
