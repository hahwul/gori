require "log"
require "./lane"
require "../store"
require "../bindings"
require "../flow_source"
require "../host_overrides"
require "../outbound"
require "../session_refresh"
require "../repeater/plan"
require "../repeater/history_record"
require "../repeater/draft_markers"

module Gori::RequestMacro
  # The `Source` that sends the macro's Repeater sessions.
  #
  # A step is a saved session replayed the way a Repeater tab sends it — the same
  # `Repeater::Plan`, so `$NAME` expansion, the auto Content-Length, SNI, TLS preset and the
  # tab's protocol are all the tab's — and, being a deliberate single send, it runs the
  # binding table's extract rules over its response (`Repeater::Sender#extract`). That is the
  # whole extraction story: a CSRF rule written for the Repeater already works, with nothing
  # macro-specific to configure.
  #
  # ## Who the steps are sent as
  #
  # As the slot that is ACTIVE for the run, overlay included — the opposite of #1233's refresh
  # steps. A refresh replaces a credential, so its login request must not carry the stale one;
  # a macro fetches a page that needs the session the candidates are sent as, and a CSRF form
  # served to an anonymous client carries the anonymous client's token. It also means the
  # rebind lands in the table the candidates resolve from: both read the active slot.
  #
  # ## Gates
  #
  # Every step passes the surface's Layer 1 (`Outbound#check_request`, at build and again per
  # run, so a scope edited mid-run stops the next step) and Layer 2 (`Outbound#sweep_block`,
  # Sandbox AND explicit excludes). It is `sweep_block` and not the Repeater's `send_block`
  # because this is an automated sweep's traffic: an operator's carve-out holds for it, exactly
  # as it does for the candidates. Steps are also charged to the run's request budget and held
  # to its rate, so `max_requests` and `--rate` mean what they say with a macro switched on.
  #
  # ## What a step may not be
  #
  # A session that still holds live `§…§` markers (the tab would render them, this would not),
  # a WebSocket handshake (a step is one request and one response), or one the plan cannot
  # build. All refused at build time, before anything is sent, with the step named.
  class Runner < Source
    # Per-step connect + idle ceiling — a step that hangs stalls the candidate waiting on it.
    STEP_TIMEOUT = 20.seconds

    private record Step, rec : Store::RepeaterRecord, label : String

    getter spec : Spec
    @labels : Array(String)
    @sink : Store

    # Build and VALIDATE the runner for `spec`, reading the sessions out of `store`. Raises
    # `Error` naming the step — never returns a runner that would fail on its first use for a
    # reason that was knowable up front.
    #
    # The sessions are read once, here, and frozen (see `Spec`): the store is not held for
    # reading afterwards, only for recording the steps' History rows and events.
    def self.build(spec : Spec, store : Store, outbound : Outbound, *,
                   overrides : HostOverrides? = nil, verify : Bool = true) : Runner
      if spec.steps.empty?
        raise Error.new("the macro has no steps — name the Repeater sessions to run, or turn it off")
      end
      steps = spec.steps.map_with_index { |token, i| resolve(store, token, i + 1) }
      steps.each_with_index do |step, i|
        n = i + 1
        rec = step.rec
        if Repeater::DraftMarkers.live?(store, rec)
          raise Error.new("macro step #{n} (#{step.label}) holds §…§ fuzz markers, which a macro cannot render — " \
                          "remove them, or use a copy of the session without markers")
        end
        plan = begin
          Repeater::Plan.build(plan_options(rec, overrides, verify), outbound)
        rescue ex : Repeater::PlanError
          raise Error.new("macro step #{n} (#{step.label}) could not be built: #{ex.message}")
        end
        if plan.websocket?
          raise Error.new("macro step #{n} (#{step.label}) is a WebSocket handshake — a step is one request and one response")
        end
        verdict = outbound.check_request(plan.scheme, plan.host, Outbound.request_target(plan.bytes), plan.port)
        if verdict.blocked?
          raise Error.new("macro step #{n} (#{step.label}) targets #{plan.host}, which is out of the project scope — " \
                          "#{outbound.remedy(verdict)}")
        end
      end
      runner = new(spec, steps, outbound, store, overrides, verify)
      runner.validate_bindings!
      runner
    end

    # One Repeater session for one `steps` entry: `3`, `#3` (an id) or the tab's name.
    private def self.resolve(store : Store, token : String, n : Int32) : Step
      # A char scan, not a Regex: PCRE raises on the invalid UTF-8 an argv can carry.
      rec =
        if !(digits = token.lchop('#')).empty? && digits.each_char.all?(&.ascii_number?)
          id = digits.to_i64?
          (id && store.get_repeater(id)) ||
            raise Error.new("macro step #{n}: there is no Repeater session ##{token.lchop('#')} in this project")
        else
          named = store.repeaters_mcp.select { |r| r.name == token }
          case named.size
          when 0
            raise Error.new("macro step #{n}: no Repeater session is named #{token.inspect} — use its name as the tab shows it, or its id")
          when 1
            store.get_repeater(named[0].id) ||
              raise Error.new("macro step #{n}: Repeater session #{token.inspect} disappeared while the plan was built")
          else
            ids = named.map { |r| "##{r.id}" }.join(", ")
            raise Error.new("macro step #{n}: #{named.size} Repeater sessions are named #{token.inspect} (#{ids}) — name one by id")
          end
        end
      Step.new(rec, SessionRefresh.step_label(rec))
    end

    # A saved session replayed AS SAVED. `Retest::LiveBackend.plan_options` is the sibling and
    # the reasoning is its: no per-send override, `auto_content_length`, `sni` and `tls_preset`
    # come off the row so the step dials the handshake the tab was saved with.
    def self.plan_options(rec : Store::RepeaterRecord, overrides : HostOverrides?,
                          verify : Bool) : Repeater::PlanOptions
      Repeater::PlanOptions.new([rec.request],
        default_target: rec.target,
        http2: rec.http2?,
        sni: rec.sni,
        timeout: STEP_TIMEOUT,
        auto_content_length: rec.auto_content_length?,
        verify: verify,
        overrides: overrides,
        tls_preset: rec.tls_preset)
    end

    # The bindings a send in the CURRENT context resolves — enabled, and unclaimed or claimed by
    # the active slot. These are the only ones a step's response can usefully rebind, and the
    # only ones "did the macro work" is asked about. `{name => bound_at}`.
    def self.visible(bindings : Bindings) : Hash(String, Time?)
      active = bindings.active_slot_name
      h = {} of String => Time?
      bindings.rows.each do |r|
        next unless r.enabled
        next unless r.slot.nil? || r.slot == active
        h[r.name] = r.bound_at
      end
      h
    end

    def initialize(@spec : Spec, @steps : Array(Step), @outbound : Outbound, store : Store,
                   @overrides : HostOverrides?, @verify : Bool)
      @labels = @steps.map(&.label)
      @sink = store
    end

    # Where the steps' History rows and the failure events go from here on. The store the plan
    # was built from is the default, which is right for a surface that holds one project for
    # its whole life (the TUI, `gori mcp`). A `gori run` command reads its project through a
    # short-lived read-only handle, closes it when the plan is built, and opens a writable one
    # for the run — this is how that one is handed over.
    def record_to(store : Store) : Nil
      @sink = store
    end

    def labels : Array(String)
      @labels
    end

    # The bindings must exist before anything is sent: a macro whose response nothing extracts
    # from would run its steps for every candidate and change nothing, and every candidate would
    # then carry the same stale value the macro was written to replace.
    protected def validate_bindings! : Nil
      bindings = Env.layer.as?(Bindings)
      unless bindings
        raise Error.new("a macro needs the project's session bindings, and none are loaded — open a project (--project / --db)")
      end
      seen = Runner.visible(bindings)
      if seen.empty?
        raise Error.new("the project has no enabled extract rule the macro could rebind — add one that reads the CSRF " \
                        "token or nonce from a step's response (Rewriter ▸ Extract, or `gori run rewriter extract add`)")
      end
      missing = @spec.expect.reject { |n| seen.has_key?(n) }
      unless missing.empty?
        raise Error.new("the macro expects #{Env.token_list(missing, ns: Env::Namespace::Bind)}, but no enabled extract rule of " \
                        "that name applies to the active session slot (visible: #{Env.token_list(seen.keys.sort!, ns: Env::Namespace::Bind)})")
      end
    end

    # Refuse a run whose candidates cannot carry anything this macro produces.
    #
    # Extraction and injection are both existing machinery, and they meet at a `$BIND.NAME` in
    # the request the candidate is sent as. If no candidate can name a binding the macro
    # rebinds, the macro would run its steps for every candidate, change the table, and change
    # nothing about what is sent — the "knob that silently does nothing" this codebase refuses
    # everywhere else, and here it would ALSO leave the stale token in place and the sweep
    # reporting 403s as if they were verdicts.
    #
    # A candidate can name one in its own text, or through the active session slot's header
    # overlay (`Authorization: Bearer $BIND.SESSION`), which is also resolved per send. Captured
    # EVIDENCE is not substituted (`Fuzz::Sender#evidence?`): its `$BIND.X` is a byte the origin
    # sent, so an evidence template contributes nothing, and the message says how to get one
    # that does.
    #
    # `candidates` are the request texts the run sends (a WebSocket run has several).
    def check_reachable!(candidates : Array(String), evidence : Bool) : Nil
      bindings = Env.layer.as?(Bindings) || return
      visible = Runner.visible(bindings).keys
      targets = @spec.expect.empty? ? visible : @spec.expect
      referenced = Set(String).new
      unless evidence
        candidates.each { |text| Env.token_names(text, ns: Env::Namespace::Bind).each { |n| referenced << n } }
      end
      if slot = bindings.slots.try(&.active)
        slot.set_headers.each do |(header, value)|
          next if slot.literal_header?(header)
          Env.token_names(value, ns: Env::Namespace::Bind).each { |n| referenced << n }
        end
      end
      return if targets.any? { |t| referenced.includes?(t) }
      names = Env.token_list(targets.sort, ns: Env::Namespace::Bind)
      where = evidence ? "this template is captured evidence, which is sent exactly as it was captured, " \
                         "so a token typed into it is never substituted — seed the run from a Repeater session or a " \
                         "draft instead, or put the token in a header of the active session slot" \
                          : "put #{Env.spell(targets.sort.first, Env::Namespace::Bind)} where the value goes in the request, " \
                            "or in a header of the active session slot"
      raise Error.new("the macro rebinds #{names}, but the request never references #{targets.size == 1 ? "it" : "any of them"} — #{where}")
    end

    def run(budget : Budget?, pacer : Proc(Nil)?, cancelled : Proc(Bool)? = nil) : Outcome
      total = @steps.size
      flows = [] of Int64
      sent = 0
      bindings = Env.layer.as?(Bindings)
      unless bindings
        return failed(total, sent, nil, nil, "the project's session bindings are no longer loaded", nil, flows)
      end
      before = Runner.visible(bindings)
      @steps.each_with_index do |step, i|
        n = i + 1
        # A stop lands between steps, not after the last one: the steps are a login-shaped chain
        # of round trips, and the promise is that only requests already in flight finish.
        if cancelled.try(&.call)
          return Outcome.new(false, total, sent, n, step.label, nil, "the run was stopped", [] of String, flows, stopped: true)
        end
        pacer.try(&.call)
        plan = begin
          Repeater::Plan.build(Runner.plan_options(step.rec, @overrides, @verify), @outbound)
        rescue ex : Repeater::PlanError
          return failed(total, sent, n, step.label, "could not build the request: #{ex.message}", nil, flows)
        end
        target = Outbound.request_target(plan.bytes)
        verdict = @outbound.check_request(plan.scheme, plan.host, target, plan.port)
        if verdict.blocked?
          return failed(total, sent, n, step.label,
            "#{plan.host} is out of the project scope — #{@outbound.remedy(verdict)}", nil, flows)
        end
        wire = plan.wire_bytes
        # Layer 2 on the bytes that will go out (a `$BIND` in the request line resolves before
        # the socket), keyed on the host actually dialled.
        if reason = @outbound.sweep_block(plan.scheme, plan.host, Outbound.request_target(wire), plan.port)
          return failed(total, sent, n, step.label, reason, nil, flows)
        end
        if budget && !budget.reserve(1_i64)
          return Outcome.new(false, total, sent, n, step.label, nil, BUDGET_ERROR, [] of String, flows,
            budget_exhausted: true)
        end
        sent_at = Time.utc.to_unix_ms * 1000_i64
        result = plan.send_wire(wire)
        sent += 1
        record(plan, result, sent_at, wire, n).try { |fid| flows << fid }
        if err = result.error
          return failed(total, sent, n, step.label, err, nil, flows)
        end
        status = result.response.try(&.status)
        return failed(total, sent, n, step.label, "no response", nil, flows) if status.nil? || status == 0
        if status >= 400
          return failed(total, sent, n, step.label, "the step answered #{status}", status, flows)
        end
      end
      settle(bindings, before, total, sent, flows)
    end

    # The steps all answered. Did they refresh anything?
    private def settle(bindings : Bindings, before : Hash(String, Time?), total : Int32,
                       sent : Int32, flows : Array(Int64)) : Outcome
      after = Runner.visible(bindings)
      rebound = after.compact_map { |(name, at)| at && at != before[name]? ? name : nil }
      if after.empty?
        return failed(total, sent, nil, nil, "no enabled extract rule is visible any more", nil, flows)
      end
      if rebound.empty?
        return failed(total, sent, nil, nil,
          "every step answered, but none of the bindings (#{Env.token_list(after.keys, ns: Env::Namespace::Bind)}) " \
          "was rebound — check the extract rules' host, condition and selector", nil, flows)
      end
      missed = @spec.expect.reject { |n| rebound.includes?(n) }
      unless missed.empty?
        return failed(total, sent, nil, nil,
          "the steps answered, but #{Env.token_list(missed, ns: Env::Namespace::Bind)} was not rebound " \
          "(rebound: #{Env.token_list(rebound, ns: Env::Namespace::Bind)}) — the value the candidates carry would be stale",
          nil, flows, rebound)
      end
      Outcome.new(true, total, sent, rebound: rebound, flow_ids: flows)
    end

    private def failed(total : Int32, sent : Int32, n : Int32?, label : String?, reason : String,
                       status : Int32?, flows : Array(Int64),
                       rebound : Array(String) = [] of String) : Outcome
      Outcome.new(false, total, sent, n, label, status, reason, rebound, flows)
    end

    # One event row in the project's feed, filed under the run's tool. Best-effort like every
    # write here: a busy store must not fail a run, and a read-only one has nowhere to write.
    def note(source : String, kind : String, level : Symbol, message : String, flow_id : Int64? = nil) : Nil
      return unless store = record_target
      store.insert_event(source, kind, level, message, flow_id: flow_id)
    rescue ex
      ::Log.warn { "macro event not recorded: #{ex.message}" }
    end

    # The store records go to right now, or nil when there is nowhere to write them: the
    # project was closed, or was opened read-only (a `gori run` command that only reads).
    private def record_target : Store?
      store = @sink
      store.closed? || store.read_only? ? nil : store
    end

    # A step's History row, source `macro`. A failure to record is not a failure of the step: the
    # send already happened.
    private def record(plan : Repeater::Plan, result : Repeater::Result, sent_at : Int64,
                       wire : Bytes, n : Int32) : Int64?
      return nil unless store = record_target
      surface = FlowSource.surface || FlowSource::Surface::Cli
      Repeater::HistoryRecord.record(store, plan, result, sent_at, wire,
        surface: surface, kind: FlowSource::Kind::Macro, source_ref: "macro step #{n}")
    rescue ex
      ::Log.warn { "macro step not recorded in History: #{ex.message}" }
      nil
    end
  end
end
