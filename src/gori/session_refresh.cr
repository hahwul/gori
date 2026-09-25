require "log"
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
        "refresh #{slot} failed#{where}#{why} · binding unchanged"
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

      def initialize(@store : Store, @bindings : Bindings, @outbound : Proc(Outbound), *,
                     @overrides : HostOverrides? = nil, @verify : Bool = true,
                     @record_history : Bool = true)
        @states = {} of String => State
        @outcomes = Deque(Outcome).new
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
        return if st.auto_off?
        if (cd = st.cooldown_until) && Time.utc < cd
          return
        end
        return unless due?(s, st)
        run(s, st, @outbound.call, manual: false)
      rescue ex
        # A refresh must never fail the send that asked for it.
        ::Log.warn { "session refresh skipped for #{slot}: #{ex.message}" }
      end

      # When `slot` is due: now or earlier, a time in the future, or nil for "never" (the policy
      # has nothing to watch). Cached against the binding rev — the JWT decode must not run on
      # every request of a sweep.
      def due_at(slot : SessionSlot) : Time?
        compute_due(slot)
      end

      private def due?(slot : SessionSlot, st : State) : Bool
        rev = @bindings.rev
        due = st.due
        at = if due && due[0] == rev
               due[1]
             else
               fresh = compute_due(slot)
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
      private def compute_due(slot : SessionSlot) : Time?
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
          newest = bound.compact_map(&.bound_at).max?
          newest.try { |t| t + policy.ttl }
        end
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
        outcome = begin
          execute(slot, outbound, manual)
        rescue ex
          Outcome.new(slot.name, false, manual, slot.refresh.size,
            reason: "refresh raised: #{ex.message || ex.class.name}")
        ensure
          st.inflight = nil
          ch.close
        end
        settle(st, outcome)
        report(outcome)
        @rev &+= 1
        outcome
      end

      private def settle(st : State, outcome : Outcome) : Nil
        st.last = outcome
        st.due = nil
        if outcome.ok
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
        @store.insert_event("session", kind, level, message, flow_id: outcome.flow_ids.last?)
      rescue ex
        ::Log.warn { "session refresh event not recorded: #{ex.message}" }
      end

      private def execute(slot : SessionSlot, outbound : Outbound, manual : Bool) : Outcome
        total = slot.refresh.size
        fail = ->(n : Int32?, label : String?, reason : String, status : Int32?, flows : Array(Int64)) {
          Outcome.new(slot.name, false, manual, total, n, label, status, reason, [] of String, flows)
        }
        flows = [] of Int64
        if total == 0
          return fail.call(nil, nil, "the slot has no refresh steps — add a Repeater session to it", nil, flows)
        end
        watched = watched_times(slot)
        slot.refresh.each_with_index do |id, i|
          n = i + 1
          if id < 0
            return fail.call(n, "repeater ##{-id} (deleted)",
              "its Repeater session was deleted; remove the step from the slot's refresh list", nil, flows)
          end
          rec = @store.get_repeater(id)
          return fail.call(n, "repeater ##{id}", "that Repeater session no longer exists", nil, flows) unless rec
          label = SessionRefresh.step_label(rec)
          if Repeater::DraftMarkers.live?(@store, rec)
            return fail.call(n, label, "the session holds §…§ fuzz markers, which a refresh cannot render", nil, flows)
          end
          plan = begin
            Repeater::Plan.build(plan_options(rec, slot.name), outbound)
          rescue ex : Repeater::PlanError
            return fail.call(n, label, "could not build the request: #{ex.message}", nil, flows)
          end
          target = (bytes = plan.requests.first?) ? Outbound.request_target(bytes) : "/"
          verdict = outbound.check_request(plan.scheme, plan.host, target, plan.port)
          if verdict.blocked?
            return fail.call(n, label, "#{plan.host} is out of the project scope — #{Outbound.remedy(verdict, nil)}", nil, flows)
          end
          if reason = plan.refusal
            return fail.call(n, label, reason, nil, flows)
          end
          sent_at = Time.utc.to_unix_ms * 1000_i64
          wire = plan.wire_bytes
          result = plan.send_wire(wire)
          if fid = record(plan, result, sent_at, wire, slot.name, n)
            flows << fid
          end
          if err = result.error
            return fail.call(n, label, err, nil, flows)
          end
          status = result.response.try(&.status)
          if status.nil? || status == 0
            return fail.call(n, label, "no response", nil, flows)
          end
          return fail.call(n, label, "the step answered #{status}", status, flows) if status >= 400
        end
        rebound = rebound_since(slot, watched)
        # The steps all answered, but if the slot claims a live rule and none of them moved,
        # the refresh did not refresh anything — the next send carries the same expired value.
        # Reported as a failure so the cooldown and the failure limit apply to it.
        if !watched.empty? && rebound.empty?
          return fail.call(nil, nil, "every step answered, but none of the slot's bindings " \
                                     "(#{Env.token_list(watched.keys, ns: Env::Namespace::Bind)}) was rebound — " \
                                     "check the extract rules' host, condition and selector", nil, flows)
        end
        Outcome.new(slot.name, true, manual, total, rebound: rebound, flow_ids: flows)
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
          refresh_slot: slot)
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
        Repeater::HistoryRecord.record(@store, plan, result, sent_at, wire,
          surface: surface, kind: FlowSource::Kind::Refresh, source_ref: "slot #{slot} step #{n}")
      rescue ex
        ::Log.warn { "session refresh step not recorded in History: #{ex.message}" }
        nil
      end
    end
  end
end
