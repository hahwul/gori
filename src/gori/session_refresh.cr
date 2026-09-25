require "log"
require "json"
require "./session_refresh/hook"
require "./bindings"
require "./session_slots"
require "./jwt"
require "./flow_source"
require "./outbound"
require "./host_overrides"
require "./repeater/plan"
require "./repeater/history_record"
require "./repeater/draft_markers"

module Gori
  # A session slot re-authenticating itself (#1233): replay the Repeater sessions in the
  # slot's `refresh` list, in order, and let the slot's own extract rules rebind it.
  #
  # Almost everything this needs already existed. Extract rules watch Repeater responses and
  # rebind `$BIND.NAME` per slot (`Bindings#observe`), bindings resolve PER SEND rather than at
  # plan-build (`Fuzz::Sender#send`), and a multi-step login already chains — step 1's response
  # rebinds `$BIND.CSRF` and step 2 carries it. What was missing is the actor that sends the
  # login request. That is all this is.
  #
  # ## Two triggers, and not a third
  #
  #   * **Manual** — `refresh`: the TUI picker's ^R, `gori run session refresh`, MCP
  #     `refresh_session_slot`.
  #   * **Before send** — `before_send`: every gori-originated send seam asks, for the slot it
  #     goes out as, and a slot whose `refresh_before` policy says its token is about to expire
  #     is refreshed first.
  #
  # Retry-after-failure (refresh on a 401, then re-send) is deliberately NOT here, because it
  # produces wrong answers rather than just complexity: in Authorize a 401 IS the result, in a
  # Fuzz run one row would stand for two requests, and a refresh that itself 401s needs loop
  # protection against locking the account. Acting BEFORE a send never reinterprets a response.
  #
  # ## What a step is
  #
  # A saved Repeater session, sent the way `Retest::LiveBackend` sends one: the same
  # `Repeater::Plan`, the same draft-marker refusal, the surface's own Layer-1 scope check and
  # Layer-2 gate, and one History row per send (source `refresh`). Sent AS the slot without
  # activating it (`PlanOptions#refresh_slot`): its `$BIND.*` read this slot's table, its
  # response rebinds this slot, and no header overlay is written — the login request must not
  # carry the stale credential it is replacing.
  #
  # ## Failure policy
  #
  # A failed refresh never blocks the send that asked for it: the send continues with the
  # value it has, and the failure is surfaced (an `events` row, the outcome queue a TUI drains
  # for its toast). An AUTOMATIC refresh that failed is not retried for `COOLDOWN`, and after
  # `FAILURE_LIMIT` consecutive failures automatic refresh turns OFF for that slot until a
  # manual refresh succeeds — a login endpoint hammered once per fuzz request is an account
  # lockout with a progress bar.
  #
  # ## Per process
  #
  # Binding values are memory-only by design, so each process (TUI, `gori mcp`, `gori run`)
  # refreshes its OWN table. A refresh in the TUI does not update a running `gori mcp`. The
  # state below — last outcome, failure count, cooldown — is per process for the same reason.
  module SessionRefresh
    # How long an AUTOMATIC refresh that failed waits before it may run again. A manual one
    # ignores it: an operator pressing the key is the retry.
    COOLDOWN = 30.seconds

    # Consecutive failures after which automatic refresh stops for the slot.
    FAILURE_LIMIT = 3

    # Per-step connect + idle ceiling — `Retest::LiveBackend::DEFAULT_TIMEOUT`'s reasoning: a
    # login step that hangs stalls the send waiting on it.
    STEP_TIMEOUT = 20.seconds

    # How many finished outcomes a surface can drain (`Runner#take_outcomes`). A surface that
    # never drains (a headless run) must not grow this forever.
    OUTCOME_QUEUE = 16

    # How many unwritten records a runner on a read-only store holds for a later hand-over.
    # Each captures a step's request and response, and a command that never opens its project
    # for writing drops them at exit anyway, so the oldest go first past this.
    DEFERRED_CAP = 32

    # One refresh, finished. Carries binding NAMES and never a value — the TUI renders a
    # masked preview itself from `Bindings#rows`, and nothing here reaches an event row or an
    # MCP reply with a credential in it.
    record Outcome,
      slot : String,
      ok : Bool,
      # Manual (an operator or agent asked) or automatic (a send's policy check asked).
      manual : Bool,
      # How many steps the slot has.
      steps : Int32,
      # 1-based step that failed, nil on success or when the failure is not a step's.
      failed_step : Int32? = nil,
      # What that step is called — the tab's name, or `METHOD path`.
      step_label : String? = nil,
      # The failed step's response status, when it got one.
      status : Int32? = nil,
      # Why it failed, operator-readable. nil on success.
      reason : String? = nil,
      # The slot's bindings a step rebound, by name.
      rebound : Array(String) = [] of String,
      # History rows the steps were recorded as.
      flow_ids : Array(Int64) = [] of Int64,
      at : Time = Time.utc do
      # `refresh admin failed at step 2 (login → 403) · binding unchanged` — the shape every
      # surface prints. No value is in it by construction.
      def message : String
        if ok
          names = rebound.empty? ? "no binding rebound" : "#{Env.token_list(rebound, ns: Env::Namespace::Bind)} rebound"
          return "refreshed #{slot} · #{names}"
        end
        where =
          if (n = failed_step) && (label = step_label)
            detail = status ? "#{label} → #{status}" : label
            " at step #{n} (#{detail})"
          else
            ""
          end
        why = reason ? " — #{reason}" : ""
        tail = rebound.empty? ? "binding unchanged" : "#{Env.token_list(rebound, ns: Env::Namespace::Bind)} rebound"
        "refresh #{slot} failed#{where}#{why} · #{tail}"
      end

      # The fields every surface reports an outcome with — the CLI's `--format json` and MCP —
      # written into an object the caller opens. One copy, so the two cannot drift. Names,
      # never values.
      def json_fields(j : JSON::Builder) : Nil
        j.field "slot", slot
        j.field "ok", ok
        j.field "manual", manual
        j.field "steps", steps
        j.field "failed_step", failed_step
        j.field "step", step_label
        j.field "status", status
        j.field "reason", reason
        j.field("rebound") { j.array { rebound.each { |n| j.string n } } }
        j.field("flow_ids") { j.array { flow_ids.each { |id| j.number id } } }
        j.field "message", message
        j.field "at_iso", at.to_rfc3339
      end
    end

    # What a surface shows next to a slot: is it refreshing, did the last one fail, is the
    # automatic policy switched off.
    record Status,
      refreshing : Bool,
      last : Outcome?,
      failures : Int32,
      auto_off : Bool,
      cooldown_until : Time? do
      def failed? : Bool
        !!last.try { |o| !o.ok }
      end
    end

    # A slot's refresh steps as labels, in order: the tab's own name, or `METHOD path`, and
    # `(deleted)` for a detached step. What the TUI form and every list print.
    def self.step_labels(store : Store, slot : SessionSlot) : Array(String)
      slot.refresh.map do |id|
        if id < 0
          "repeater ##{-id} (deleted)"
        elsif rec = store.get_repeater(id)
          step_label(rec)
        else
          "repeater ##{id} (missing)"
        end
      end
    end

    def self.step_label(rec : Store::RepeaterRecord) : String
      if name = rec.name.presence
        return name
      end
      nl = rec.request.index(0x0a_u8) || rec.request.size
      parts = String.new(rec.request[0, Math.min(nl, 256)]).scrub.split
      line = parts.size >= 2 ? "#{parts[0]} #{parts[1]}" : "repeater ##{rec.id}"
      line.size > 40 ? "#{line[0, 39]}…" : line
    end

    # The earliest `exp` of any JWT inside `value` — a bare token, `Bearer <token>`, a cookie
    # pair. nil when it holds none or none carries an `exp`.
    def self.jwt_exp(value : String) : Int64?
      exps = [] of Int64
      value.scan(Jwt::SCAN_RE) do |m|
        next unless tok = Jwt.narrow(m[0])
        next unless Jwt.jwt?(tok)
        next unless seg = tok.split('.')[1]?
        if exp = Jwt.claim_exp(seg)
          exps << exp
        end
      end
      exps.min?
    end

    # The per-process runner: one per open project, installed as `SessionRefresh.hook` beside
    # `Env.layer`.
    class Runner < Hook
      # Per-slot bookkeeping. A class, so the single-flight latch is shared by every fiber that
      # reads it.
      private class State
        property failures : Int32 = 0
        property cooldown_until : Time? = nil
        property? auto_off : Bool = false
        property last : Outcome? = nil
        # When the last refresh SUCCEEDED — what a `ttl=` policy counts from.
        property last_ok_at : Time? = nil
        # Closed when the in-flight refresh finishes; every waiter wakes on `receive?`.
        property inflight : Channel(Nil)? = nil
        # `{binding rev, due time}` — the due time is absolute, so it stays right as the clock
        # moves and only a rebind (which moves the rev) can change it. nil due = never.
        property due : {UInt64, Time?}? = nil
      end

      getter store : Store
      getter bindings : Bindings

      # Bumped whenever a refresh starts or finishes, so a TUI can repaint its chip on a change
      # rather than on every tick.
      getter rev : UInt64 = 0_u64

      # `outbound` builds the SURFACE's own gate for an automatic refresh — `Outbound.agent`
      # on MCP, `.cli` on `gori run`, `.interactive` in the TUI. An automatic refresh never
      # inherits a send's own waiver: the login is a different request to a possibly different
      # host, and it has to be in scope on its own. A manual refresh may pass its own.
      # Upstream TLS verification for the steps. A property because the TUI flips it live
      # (`Session#set_verify_upstream`).
      property? verify : Bool

      #
      # `records` is where the History rows and the event go when that is not `@store` — a
      # `gori run` command that opened its project writable and then again read-only hands the
      # runner on the second open the first handle (`hydrate_cli_store`). `origin` names the
      # project database, so records are never handed to ANOTHER project's store.
      getter origin : String?

      def initialize(@store : Store, @bindings : Bindings, @outbound : Proc(Outbound), *,
                     @overrides : HostOverrides? = nil, @verify : Bool = true,
                     @record_history : Bool = true, @records : Store? = nil,
                     @origin : String? = nil)
        @states = {} of String => State
        @outcomes = Deque(Outcome).new
        # Records that could not be written because `@store` is read-only — see `deferred`.
        @deferred = [] of Proc(Store, Nil)
        @bindings.on_slots_pruned = ->forget_slots(Array(String)?)
      end

      # Drop the bookkeeping of every slot that is gone, on the same signal that drops its
      # binding table (`Bindings#prune_slots`): `admin` deleted and created again is a new
      # identity, and must not inherit the old one's failure count, cooldown or `auto_off`.
      # nil — a peer's edit this process cannot attribute — forgets every slot. A slot with a
      # refresh in flight keeps its entry, because its waiters hold that latch.
      def forget_slots(surviving : Array(String)?) : Nil
        @states.reject! do |name, st|
          st.inflight.nil? && (surviving.nil? || !surviving.includes?(name))
        end
      end

      def layer : Env::Layer
        @bindings
      end

      # Install this runner as the process's hook. Replaces any previous one.
      def install : self
        SessionRefresh.hook = self
        self
      end

      # Clear the hook if it is still this runner — the `Env.layer = nil if … same?` shape.
      def uninstall : Nil
        SessionRefresh.hook = nil if SessionRefresh.hook.same?(self)
      end

      def status(slot : String) : Status
        st = @states[slot]?
        return Status.new(false, nil, 0, false, nil) unless st
        Status.new(!st.inflight.nil?, st.last, st.failures, st.auto_off?, st.cooldown_until)
      end

      def refreshing?(slot : String) : Bool
        !@states[slot]?.try(&.inflight).nil?
      end

      # Every outcome finished since the last call, oldest first. The TUI drains this on its
      # tick to raise a toast; a headless surface reads `status` instead.
      def take_outcomes : Array(Outcome)
        out = @outcomes.to_a
        @outcomes.clear
        out
      end

      # ── manual ────────────────────────────────────────────────────────────────

      # Refresh `name` now. Waits for an in-flight refresh of the same slot and returns ITS
      # outcome rather than logging in twice. A manual refresh ignores the cooldown and the
      # failure limit, and a successful one switches automatic refresh back on.
      #
      # `outbound` is the caller's gate (a `--allow-unscoped` / `allow_unscoped:true` refresh);
      # nil uses the surface's default.
      def refresh(name : String, outbound : Outbound? = nil) : Outcome
        # Re-read the list first: a peer may have edited the steps, and `Store#delete_repeater`
        # detaches a closed tab's id in the persisted row — acting on a stale positive id would
        # replay whatever tab took that id next.
        @bindings.slots.try(&.reload)
        slot = @bindings.slots.try(&.find(name))
        return Outcome.new(name, false, true, 0, reason: "no session slot named #{name.inspect}") unless slot
        st = state(name)
        if ch = st.inflight
          ch.receive?
          return st.last || Outcome.new(name, false, true, slot.refresh.size, reason: "the refresh in flight did not finish")
        end
        run(slot, st, outbound || @outbound.call, manual: true)
      end

      # ── before send ───────────────────────────────────────────────────────────

      def before_send(slot : String) : Nil
        slots = @bindings.slots
        # One atomic read: no slot anywhere has an automatic policy.
        return unless slots && slots.auto_refresh?
        s = slots.find(slot)
        return unless s && s.auto_refresh?
        st = state(slot)
        # Single-flight: a send arriving while this slot is refreshing waits for THAT refresh
        # and never starts a second — N fuzz workers crossing the expiry together log in once.
        if ch = st.inflight
          ch.receive?
          return
        end
        return unless auto_due?(s, st)
        # Never block the TUI's event loop on a login: from the UI fiber the refresh runs on
        # its own fiber (and marks the slot in flight, so the chip shows `⟳`) while this send
        # goes out with the value it has. Every other caller waits for the fresh one.
        if Fiber.current.same?(SessionRefresh.ui_fiber)
          outbound = @outbound.call
          spawn(name: "gori-session-refresh") { run_fresh(slot, outbound) }
          return
        end
        run_fresh(slot, @outbound.call)
      rescue ex
        # A refresh must never fail the send that asked for it.
        ::Log.warn { "session refresh skipped for #{slot}: #{ex.message}" }
      end

      # Whether an AUTOMATIC refresh of `slot` should run now: not switched off, not cooling
      # down, and due.
      #
      # A slot whose last refresh FAILED is due again once its cooldown is over, whatever its
      # policy reads. The policy alone would go quiet: a login whose step 1 rebound `$CSRF` and
      # whose step 2 was refused leaves a freshly bound value in the table, so a TTL counted from
      # it says "fresh" while the session token it exists for is still stale.
      private def auto_due?(slot : SessionSlot, st : State) : Bool
        return false if st.auto_off?
        return false if (cd = st.cooldown_until) && Time.utc < cd
        !!st.last.try { |o| !o.ok } || due?(slot, st)
      end

      # The automatic run itself, over a FRESHLY read list: `Store#delete_repeater` detaches a
      # closed tab's id in the persisted row, and a step id this process still holds positive
      # could by now name whatever tab took that id next (`repeaters.id` has no AUTOINCREMENT).
      # One settings read, and only when a refresh is actually about to run.
      private def run_fresh(name : String, outbound : Outbound) : Nil
        slots = @bindings.slots
        return unless slots
        slots.reload
        s = slots.find(name)
        return unless s && s.auto_refresh?
        st = state(name)
        # The reload above can yield, so another sender may have started this slot's refresh
        # meanwhile: wait for THAT one rather than going out ahead of it.
        if ch = st.inflight
          ch.receive?
          return
        end
        run(s, st, outbound, manual: false)
      rescue ex
        ::Log.warn { "session refresh skipped for #{name}: #{ex.message}" }
      end

      # When `slot` is due: now or earlier, a time in the future, or nil for "never" (the policy
      # has nothing to watch). Cached against the binding rev — the JWT decode must not run on
      # every request of a sweep.
      def due_at(slot : SessionSlot) : Time?
        compute_due(slot, state(slot.name))
      end

      private def due?(slot : SessionSlot, st : State) : Bool
        rev = @bindings.rev
        due = st.due
        at = if due && due[0] == rev
               due[1]
             else
               fresh = compute_due(slot, st)
               st.due = {rev, fresh}
               fresh
             end
        !!at.try { |t| Time.utc >= t }
      end

      # The rows this slot OWNS — claimed and enabled. A slot that claims no live rule has
      # nothing the policy can read, and is never due on its own (a manual refresh still runs).
      #
      # Nothing bound yet is due NOW: a slot with a refresh policy and an empty table is a slot
      # whose next send would carry literal `$BIND.*`, which is the 401 the policy exists to
      # prevent. The cooldown and failure limit bound how often that can fire.
      private def compute_due(slot : SessionSlot, st : State) : Time?
        rows = @bindings.rows.select { |r| r.slot == slot.name && r.enabled }
        return nil if rows.empty?
        bound = rows.select(&.bound?)
        return Time.utc if bound.empty?
        policy = slot.refresh_before
        case policy.kind
        in SessionSlot::RefreshBefore::Kind::Off
          nil
        in SessionSlot::RefreshBefore::Kind::JwtExp
          exps = bound.compact_map { |r| r.value.try { |v| SessionRefresh.jwt_exp(v) } }
          return nil if exps.empty?
          unix_or_nil(exps.min).try { |t| t - SessionSlot::RefreshBefore::SKEW }
        in SessionSlot::RefreshBefore::Kind::Ttl
          # From the last successful refresh, else from the OLDEST claimed binding — never the
          # newest: a `$BIND.CSRF` rebound by every page would keep a stale session token
          # looking fresh forever.
          base = st.last_ok_at || bound.compact_map(&.bound_at).min?
          base.try { |t| t + policy.ttl }
        end
      end

      # A refresh that answered and rebound, but left a `jwt-exp` slot STILL inside its skew —
      # the login handed back a token that expires within `SKEW`, or the step that rebinds the
      # token did not. Counted as a failure, or the very next send would log in again, and the
      # one after it: a login per request with no cooldown and no failure limit.
      private def still_due_reason(slot : SessionSlot) : String?
        return nil unless slot.refresh_before.kind.jwt_exp?
        exps = @bindings.rows.select { |r| r.slot == slot.name && r.enabled && r.bound? }
          .compact_map { |r| r.value.try { |v| SessionRefresh.jwt_exp(v) } }
        return nil unless exp = exps.min?
        at = unix_or_nil(exp)
        return nil unless at && at - SessionSlot::RefreshBefore::SKEW <= Time.utc
        "the refresh finished, but the slot's JWT still expires within " \
        "#{SessionSlot::RefreshBefore::SKEW.total_seconds.to_i}s — the login step may not be rebinding it"
      end

      # A crafted token can carry an `exp` outside Crystal's Time range.
      private def unix_or_nil(exp : Int64) : Time?
        Time.unix(exp)
      rescue ArgumentError
        nil
      end

      # ── the run ───────────────────────────────────────────────────────────────

      private def state(name : String) : State
        @states[name] ||= State.new
      end

      private def run(slot : SessionSlot, st : State, outbound : Outbound, *, manual : Bool) : Outcome
        ch = Channel(Nil).new
        st.inflight = ch
        @rev &+= 1
        # The latch opens only once the outcome is SETTLED: a manual `refresh` waiting on it
        # returns `st.last`, which must be this run's answer and not the one before it.
        outcome = begin
          finished = begin
            execute(slot, outbound, manual)
          rescue ex
            Outcome.new(slot.name, false, manual, slot.refresh.size,
              reason: "refresh raised: #{ex.message || ex.class.name}")
          end
          if finished.ok && (why = still_due_reason(slot))
            finished = Outcome.new(slot.name, false, manual, slot.refresh.size, reason: why,
              rebound: finished.rebound, flow_ids: finished.flow_ids)
          end
          settle(st, finished)
          finished
        ensure
          st.inflight = nil
          ch.close
        end
        report(outcome)
        @rev &+= 1
        outcome
      end

      private def settle(st : State, outcome : Outcome) : Nil
        st.last = outcome
        st.due = nil
        if outcome.ok
          st.last_ok_at = outcome.at
          st.failures = 0
          st.cooldown_until = nil
          st.auto_off = false
        else
          st.failures += 1
          st.cooldown_until = Time.utc + COOLDOWN
          st.auto_off = true if st.failures >= FAILURE_LIMIT
        end
        @outcomes.shift if @outcomes.size >= OUTCOME_QUEUE
        @outcomes << outcome
      end

      # One `events` row per refresh — `list_events` shows it. Info on success and warn on a
      # failure, which is the only kind a human is interrupted for. Never a value.
      private def report(outcome : Outcome) : Nil
        kind = outcome.ok ? "refresh_ok" : "refresh_failed"
        level = outcome.ok ? :info : :warn
        how = outcome.manual ? "" : " (automatic, before send)"
        message = "#{outcome.message}#{how}"
        if (st = @states[outcome.slot]?) && st.auto_off? && !outcome.ok && !outcome.manual
          message += " — automatic refresh is OFF after #{FAILURE_LIMIT} failures until a manual refresh succeeds"
        end
        flow_id = outcome.flow_ids.last?
        write { |store| store.insert_event("session", kind, level, message, flow_id: flow_id) }
      rescue ex
        ::Log.warn { "session refresh event not recorded: #{ex.message}" }
      end

      # Run one record against the project now, or hold it until a writable store is handed
      # over (`hand_over`). A `gori run` command reads its project through a READ-ONLY store,
      # and a refresh the policy triggers mid-send happens there; the History rows and the
      # event it owes are written through the next writable store the command opens (the one
      # that saves the response), rather than dropped.
      private def write(&block : Store -> Nil) : Nil
        if target = record_target
          block.call(target)
        else
          @deferred.shift if @deferred.size >= DEFERRED_CAP
          @deferred << block
        end
      end

      # The writable store records go through right now, or nil to hold them.
      def record_target : Store?
        if (r = @records) && !r.closed? && !r.read_only?
          return r
        end
        @store.read_only? || @store.closed? ? nil : @store
      end

      # Whether records are waiting for a writable store.
      def deferred? : Bool
        !@deferred.empty?
      end

      # Hand the waiting records to `store` (writable, and the database `origin` names) or, when
      # it cannot take them, to `successor` — the runner a later open of the SAME project
      # installs. A store of another project gets nothing: a refresh of project A's slot does
      # not belong in project B's History. Each record is written once.
      def hand_over(store : Store, origin : String?, successor : Runner? = nil) : Nil
        return if @deferred.empty?
        return unless origin == @origin
        pending = @deferred.dup
        @deferred.clear
        if store.read_only?
          successor && successor.origin == @origin ? successor.adopt(pending) : @deferred.concat(pending)
          return
        end
        pending.each do |rec|
          rec.call(store)
        rescue ex
          ::Log.warn { "session refresh record not written: #{ex.message}" }
        end
      end

      protected def adopt(pending : Array(Proc(Store, Nil))) : Nil
        @deferred.concat(pending)
      end

      private def execute(slot : SessionSlot, outbound : Outbound, manual : Bool) : Outcome
        total = slot.refresh.size
        flows = [] of Int64
        if total == 0
          return failed(slot, manual, nil, nil, "the slot has no refresh steps — add a Repeater session to it", nil, flows)
        end
        watched = watched_times(slot)
        slot.refresh.each_with_index do |id, i|
          # A refresh outlives nothing it belongs to: once its project closed (a TUI project
          # switch while a manual refresh was on its own fiber) the remaining steps stay unsent.
          if @store.closed?
            return failed(slot, manual, nil, nil, "the project was closed before step #{i + 1}", nil, flows)
              .copy_with(rebound: rebound_since(slot, watched))
          end
          if outcome = run_step(slot, id, i + 1, outbound, manual, flows)
            # An earlier step may already have rebound part of the slot (step 1's `$BIND.CSRF`
            # before step 2 was refused): the outcome says so rather than "binding unchanged".
            return outcome.copy_with(rebound: rebound_since(slot, watched))
          end
        end
        rebound = rebound_since(slot, watched)
        # The steps all answered, but if the slot claims a live rule and none of them moved,
        # the refresh did not refresh anything — the next send carries the same expired value.
        # Reported as a failure so the cooldown and the failure limit apply to it.
        if !watched.empty? && rebound.empty?
          return failed(slot, manual, nil, nil, "every step answered, but none of the slot's bindings " \
                                                "(#{Env.token_list(watched.keys, ns: Env::Namespace::Bind)}) was rebound — " \
                                                "check the extract rules' host, condition and selector", nil, flows)
        end
        Outcome.new(slot.name, true, manual, total, rebound: rebound, flow_ids: flows)
      end

      private def failed(slot : SessionSlot, manual : Bool, n : Int32?, label : String?, reason : String,
                         status : Int32?, flows : Array(Int64)) : Outcome
        Outcome.new(slot.name, false, manual, slot.refresh.size, n, label, status, reason, [] of String, flows)
      end

      # Step `n` (Repeater session `id`): the failure it ended the refresh with, or nil to go on.
      # Each send it makes lands in `flows`.
      private def run_step(slot : SessionSlot, id : Int64, n : Int32, outbound : Outbound,
                           manual : Bool, flows : Array(Int64)) : Outcome?
        if id < 0
          return failed(slot, manual, n, "repeater ##{-id} (deleted)",
            "its Repeater session was deleted; remove the step from the slot's refresh list", nil, flows)
        end
        rec = @store.get_repeater(id)
        return failed(slot, manual, n, "repeater ##{id}", "that Repeater session no longer exists", nil, flows) unless rec
        label = SessionRefresh.step_label(rec)
        if Repeater::DraftMarkers.live?(@store, rec)
          return failed(slot, manual, n, label, "the session holds §…§ fuzz markers, which a refresh cannot render", nil, flows)
        end
        plan = begin
          Repeater::Plan.build(plan_options(rec, slot.name), outbound)
        rescue ex : Repeater::PlanError
          return failed(slot, manual, n, label, "could not build the request: #{ex.message}", nil, flows)
        end
        if reason = step_refusal(plan, outbound)
          return failed(slot, manual, n, label, reason, nil, flows)
        end
        sent_at = Time.utc.to_unix_ms * 1000_i64
        wire = plan.wire_bytes
        result = plan.send_wire(wire)
        record(plan, result, sent_at, wire, slot.name, n).try { |fid| flows << fid }
        return failed(slot, manual, n, label, result.error.to_s, nil, flows) if result.error
        status = result.response.try(&.status)
        return failed(slot, manual, n, label, "no response", nil, flows) if status.nil? || status == 0
        return failed(slot, manual, n, label, "the step answered #{status}", status, flows) if status >= 400
        nil
      end

      # Layer 1 (the surface's scope policy) before Layer 2 (Sandbox / explicit excludes) — the
      # order every direct-dial surface asks them in (`Retest::LiveBackend#send`).
      private def step_refusal(plan : Repeater::Plan, outbound : Outbound) : String?
        target = (bytes = plan.requests.first?) ? Outbound.request_target(bytes) : "/"
        verdict = outbound.check_request(plan.scheme, plan.host, target, plan.port)
        return "#{plan.host} is out of the project scope — #{Outbound.remedy(verdict, nil)}" if verdict.blocked?
        plan.refusal
      end

      # `{binding name => bound_at}` for every live rule the slot claims, unbound as nil.
      private def watched_times(slot : SessionSlot) : Hash(String, Time?)
        h = {} of String => Time?
        @bindings.rows.each do |r|
          next unless r.slot == slot.name && r.enabled
          h[r.name] = r.bound_at
        end
        h
      end

      private def rebound_since(slot : SessionSlot, before : Hash(String, Time?)) : Array(String)
        now = watched_times(slot)
        now.compact_map { |(name, at)| at && at != before[name]? ? name : nil }
      end

      # A saved session replayed AS SAVED — `Retest.plan_options`, plus the slot it refreshes.
      private def plan_options(rec : Store::RepeaterRecord, slot : String) : Repeater::PlanOptions
        Repeater::PlanOptions.new([rec.request],
          default_target: rec.target,
          http2: rec.http2?,
          sni: rec.sni,
          timeout: STEP_TIMEOUT,
          auto_content_length: rec.auto_content_length?,
          verify: @verify,
          overrides: overrides,
          tls_preset: rec.tls_preset,
          refresh_slot: slot,
          refresh_layer: @bindings)
      end

      # The live overrides the TUI handed over, else the project's as they stand now — a
      # headless process loads them only when a refresh actually runs.
      private def overrides : HostOverrides?
        @overrides || begin
          HostOverrides.load(@store)
        rescue
          nil
        end
      end

      # The History row. A record failure is not a step failure: the send already happened.
      private def record(plan : Repeater::Plan, result : Repeater::Result, sent_at : Int64,
                         wire : Bytes, slot : String, n : Int32) : Int64?
        return nil unless @record_history
        surface = FlowSource.surface || FlowSource::Surface::Cli
        ref = "slot #{slot} step #{n}"
        unless target = record_target
          # No flow id to report: the row is written when the records are handed over.
          write do |store|
            Repeater::HistoryRecord.record(store, plan, result, sent_at, wire,
              surface: surface, kind: FlowSource::Kind::Refresh, source_ref: ref)
            nil
          end
          return nil
        end
        Repeater::HistoryRecord.record(target, plan, result, sent_at, wire,
          surface: surface, kind: FlowSource::Kind::Refresh, source_ref: ref)
      rescue ex
        ::Log.warn { "session refresh step not recorded in History: #{ex.message}" }
        nil
      end
    end
  end
end
