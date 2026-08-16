require "../tab_controller"
require "../authorize_view"
require "../../authorize/engine"
require "../../outbound"
require "../../settings"

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

    def initialize(host : Host)
      super(host)
      @view = AuthorizeView.new
      @events = Channel(Outcome).new(64)
      @job_id = nil.as(Int32?)
      @gen = 0
      @active_gen = nil.as(Int32?) # non-nil while a run fiber is alive
      @batch_ids = Set(Int32).new
      @batch_size = 0
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
      drained = false
      DRAIN_CAP.times do
        break unless o = next_outcome
        apply_outcome(o)
        drained = true
      end
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
      return "mark flows in History and Send to Authorize (batch-capable) to begin" unless @view.any_requests?
      return "↑/↓ request · ⇥ identity · ^X stop · space cmds" if running?
      "↑/↓ request · ⇥ identity · ^R run pending · ⇧R all · t this · d remove · space cmds"
    end
  end
end
