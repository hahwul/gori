require "json"
require "../../store"
require "../../retest"
require "../../retest/live_backend"

module Gori
  module MCP
    class Tools
      # Issue-linked retest (#1036) — the reproducible check a finding carries.
      #
      # An agent that confirms a finding can leave behind more than prose: the ordered list of
      # Repeater sends that demonstrates it, each with a role and the one result it expects.
      # `run_retest` then answers the question a fix needs answered — "is it still there" —
      # with a verdict rather than a transcript, and the run is kept on the Issue so the next
      # agent (or the next week) can see what it said last time.
      #
      # `list_retest_steps` resolves each step against the project as it is NOW, so the reply
      # already says what will be sent and which steps change state. That is deliberate: a
      # caller must be able to decide whether to pass `confirm` WITHOUT sending anything
      # first.

      RETEST_ROLES = Store::RetestRole.values.map(&.label)

      # `assertion` is one string in the grammar `Retest::Assertion` parses. The schema quotes
      # `FORMS` verbatim so the tool description and the parser cannot drift.
      private def retest_assertion_help : String
        Retest::Assertion::FORMS.join("; ")
      end

      @[Tool("list_retest_steps")]
      private def list_retest_steps(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) unless issue_id
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        planned = Retest.plan(store, issue_id)
        last = store.last_retest_run(issue_id)
        Result.new(JSON.build do |j|
          j.object do
            j.field "issue_id", issue_id
            j.field("steps") { j.array { planned.each { |pl| j.object { Serialize.retest_planned(j, pl) } } } }
            j.field "total", planned.size
            j.field "state_changing", Retest.state_changing(planned).size
            # The sentence a confirm has to show, computed here so a caller never has to
            # derive "how many requests, how many of them with side effects" itself.
            Retest.confirm_note(planned).try { |n| j.field "confirm_note", n }
            if r = last
              j.field("last_run") { j.object { Serialize.retest_run(j, r) } }
            end
          end
        end)
      end

      @[Tool("add_retest_step", gated: true, agent_action: true)]
      private def add_retest_step(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) unless issue_id
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) unless repeater_id
        return not_found("no repeater with id #{repeater_id}") unless store.get_repeater(repeater_id)
        role = retest_role(h, default: "variant")
        return role if role.is_a?(Result)
        assertion = retest_assertion(h)
        return assertion if assertion.is_a?(Result)

        id, status = store.add_retest_step(issue_id, role, Store::LinkRefKind::Repeater,
          repeater_id, assertion)
        case status
        in .issue_gone? then return not_found("issue #{issue_id} was deleted before the step was written")
        in .step_gone?  then return busy("the step disappeared before it could be written")
        in .busy?       then return busy("nothing added (store busy or unwritable)")
        in .ok?         then nil
        end
        retest_step_reply(id, "added")
      end

      @[Tool("update_retest_step", gated: true, agent_action: true)]
      private def update_retest_step(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        return not_found("no retest step with id #{id}") unless store.get_retest_step(id)
        role = nil.as(Store::RetestRole?)
        if present?(h, "role")
          parsed = retest_role(h, default: nil)
          return parsed if parsed.is_a?(Result)
          role = parsed
        end
        assertion = nil.as(String?)
        if present?(h, "assertion")
          parsed = retest_assertion(h)
          return parsed if parsed.is_a?(Result)
          assertion = parsed
        end
        if role.nil? && assertion.nil?
          return err("nothing to change — pass 'role' and/or 'assertion' (assertion:\"\" clears it)",
            "INVALID_ARGUMENT", field: "role")
        end
        case store.update_retest_step(id, role: role, assertion: assertion)
        in .issue_gone? then return not_found("the issue was deleted before the edit landed")
        in .step_gone?  then return not_found("retest step #{id} was deleted before the edit landed")
        in .busy?       then return busy("step NOT updated (store busy or unwritable)")
        in .ok?         then nil
        end
        retest_step_reply(id, "updated")
      end

      # `position` is 1-based and CLAMPED to the list, so `position:1` always means "first".
      @[Tool("move_retest_step", gated: true, agent_action: true)]
      private def move_retest_step(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        return not_found("no retest step with id #{id}") unless store.get_retest_step(id)
        position = int(h, "position")
        return Result.new(id_error(h, "position"), is_error: true) unless position
        # CLAMPED before `to_i`: the store clamps to the list anyway, and an unclamped
        # `Int64#to_i` past `Int32::MAX` raises `OverflowError` — a crash, not a refusal, for
        # an argument whose only meaning is "as far as it goes".
        case store.move_retest_step(id, position.clamp(1_i64, Int32::MAX.to_i64).to_i)
        in .issue_gone?, .step_gone? then return not_found("retest step #{id} was deleted before the move landed")
        in .busy?                    then return busy("step NOT moved (store busy or unwritable)")
        in .ok?                      then nil
        end
        retest_step_reply(id, "moved")
      end

      @[Tool("remove_retest_step", gated: true, agent_action: true)]
      private def remove_retest_step(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        step = store.get_retest_step(id)
        return not_found("no retest step with id #{id}") unless step
        case store.remove_retest_step(id)
        in .issue_gone?, .step_gone? then return not_found("retest step #{id} was already gone")
        in .busy?                    then return busy("step NOT removed (store busy or unwritable)")
        in .ok?                      then nil
        end
        Result.new({"removed" => true, "id" => id, "issue_id" => step.issue_id,
                    "position" => step.position, "role" => step.role.label}.to_json)
      end

      # The CLI's `retest clear`. Steps only — the runs are the record of what already
      # happened, and re-planning a check does not un-run it.
      @[Tool("clear_retest_steps", gated: true, agent_action: true)]
      private def clear_retest_steps(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) unless issue_id
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        n = store.count_retest_steps(issue_id)
        return not_found("issue #{issue_id} has no retest steps") if n == 0
        return busy("steps NOT cleared (store busy or unwritable)") unless store.clear_retest_steps(issue_id)
        Result.new({"cleared" => true, "issue_id" => issue_id, "steps" => n}.to_json)
      end

      # The CLI's `retest forget`. Not housekeeping — the history prunes itself — but for the
      # run that should not be ON the record: a batch an agent sent at the wrong target, or
      # under a scope since fixed. Without it an agent could record a run it cannot undo,
      # while `get_issue`'s `retest` object keeps advertising that verdict as the issue's
      # last answer.
      @[Tool("delete_retest_run", gated: true, agent_action: true)]
      private def delete_retest_run(h) : Result
        id = int(h, "run_id")
        return Result.new(id_error(h, "run_id"), is_error: true) unless id
        run = store.get_retest_run(id)
        return not_found("no retest run with id #{id}") unless run
        return busy("run NOT deleted (store busy or unwritable)") unless store.delete_retest_run(id)
        Result.new({"deleted" => true, "run_id" => id, "issue_id" => run.issue_id,
                    "verdict" => run.verdict.label, "steps" => run.total}.to_json)
      end

      # The one tool here that SENDS. Every step goes out through the project's scope and
      # Sandbox gates and is recorded in History as `src:retest`.
      @[Tool("run_retest", gated: true, agent_action: true, env_refresh: true)]
      private def run_retest(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) unless issue_id
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        planned = Retest.plan(store, issue_id)
        if planned.empty?
          return not_found("issue #{issue_id} has no retest steps — add_retest_step first " \
                           "(a repeater_id from list_history/create_repeater, a role, and one assertion)")
        end
        # BEFORE anything is dialled, and it names the exact count: a batch that re-runs a
        # POST/PUT/PATCH/DELETE side effect is the one an operator has to have agreed to. The
        # numbers come from the same `Retest.confirm_note` `list_retest_steps` already
        # returned, so a caller can read them without sending.
        if (note = Retest.confirm_note(planned)) && !bool_arg(h, "confirm", false)
          return err("#{note} Pass confirm:true to run it, or remove the state-changing steps.",
            "CONFIRM_REQUIRED", field: "confirm",
            details: JSON.parse({"requests"       => planned.count(&.runnable?),
                                 "state_changing" => Retest.state_changing(planned).size,
                                 "methods"        => Retest.unsafe_methods(planned)}.to_json))
        end
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        backend = Retest::LiveBackend.new(store, ob,
          issue_id: issue_id, surface: Gori::FlowSource::Surface::Mcp,
          overrides: HostOverrides.load(store),
          # Same rule as every sibling sweep: the tool argument can only make verification
          # STRICTER, never lift a `gori mcp --insecure` the operator set for the process.
          verify: bool_arg(h, "verify", true) && @verify_upstream,
          timeout: retest_timeout(h),
          record_history: bool_arg(h, "record_history", true),
          waiver: "allow_unscoped:true")
        report = Retest.execute(store, planned, backend,
          issue_id: issue_id, surface: Gori::FlowSource::Surface::Mcp,
          allow_cleanup: bool_arg(h, "allow_cleanup", false))
        Result.new(JSON.build do |j|
          j.object do
            j.field "issue_id", issue_id
            j.field "run_id", report.run_id if report.run_id > 0
            j.field "verdict", report.verdict.label
            Serialize.retest_tally(j, report.tally)
            j.field "started_at", report.started_at
            j.field "started_at_iso", Serialize.unix_micros_iso(report.started_at)
            j.field "duration_us", {report.finished_at - report.started_at, 0_i64}.max
            j.field("steps") { j.array { report.results.each { |r| j.object { Serialize.retest_step_result(j, r) } } } }
            # SAID, never swallowed: a run whose summary did not land still ran, and the
            # difference is only whether a later regression check can find it.
            j.field "summary_persisted", report.stored.ok?
            unless report.stored.ok?
              j.field "summary_error", report.stored.issue_gone? ? "the issue was deleted mid-run" : "store busy or unwritable"
            end
          end
        end,
          # `isError` on anything but a clean pass, so an agent's default error policy stops
          # at a regression rather than reading a failed retest as a successful call. The
          # payload is the SAME either way — the rows are the answer, not the flag.
          is_error: !report.verdict.pass?)
      end

      @[Tool("list_retest_runs")]
      private def list_retest_runs(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) unless issue_id
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        limit = bounded_int_arg(h, "limit", Retest::RUN_HISTORY.to_i64,
          min: 1_i64, max: Retest::RUN_HISTORY.to_i64).to_i
        runs = store.retest_runs(issue_id, limit)
        Result.new(JSON.build do |j|
          j.object do
            j.field "issue_id", issue_id
            j.field("runs") { j.array { runs.each { |r| j.object { Serialize.retest_run(j, r) } } } }
            j.field "total", runs.size
            j.field "kept", Retest::RUN_HISTORY
          end
        end)
      end

      @[Tool("get_retest_run")]
      private def get_retest_run(h) : Result
        id = int(h, "run_id")
        return Result.new(id_error(h, "run_id"), is_error: true) unless id
        run = store.get_retest_run(id)
        return not_found("no retest run with id #{id}") unless run
        steps = store.retest_run_steps(id)
        Result.new(JSON.build do |j|
          j.object do
            Serialize.retest_run(j, run)
            j.field("steps") { j.array { steps.each { |s| j.object { Serialize.retest_run_step(j, s) } } } }
          end
        end)
      end

      # --- shared argument reading ---------------------------------------------

      # The role, or the refusal naming every accepted value. `default` nil means the caller
      # is editing and the absence of the argument has already been handled.
      private def retest_role(h, default : String?) : Store::RetestRole | Result
        raw = str(h, "role").try(&.strip.downcase).presence || default
        unless raw
          return err("missing required 'role' (#{RETEST_ROLES.join(" | ")})", "INVALID_ARGUMENT", field: "role")
        end
        Store::RetestRole.parse?(raw) ||
          err("invalid role #{raw.inspect} — one of #{RETEST_ROLES.join(", ")}",
            "INVALID_ARGUMENT", field: "role")
      end

      # The stored assertion spelling, or the refusal. An absent argument is the empty
      # assertion ("record the outcome, assert nothing"), which is a legitimate step.
      private def retest_assertion(h) : String | Result
        raw = str(h, "assertion") || ""
        parsed = Retest::Assertion.parse(raw)
        return err("invalid assertion: #{parsed}", "INVALID_ARGUMENT", field: "assertion") if parsed.is_a?(String)
        parsed.to_s
      end

      private def retest_timeout(h) : Time::Span
        ms = bounded_int_arg(h, "timeout_ms",
          Retest::LiveBackend::DEFAULT_TIMEOUT.total_milliseconds.to_i64,
          min: 100_i64, max: 120_000_i64)
        ms.milliseconds
      end

      private def retest_step_reply(id : Int64, verb : String) : Result
        step = store.get_retest_step(id)
        return busy("the step vanished before it could be read back") unless step
        planned = Retest.plan(store, [step]).first
        Result.new(JSON.build do |j|
          j.object do
            j.field verb, true
            Serialize.retest_planned(j, planned)
          end
        end)
      end

      private def list_retest_tools(j : JSON::Builder) : Nil
        tool j, "list_retest_steps",
          "An Issue's RETEST: the ordered Repeater sends that reproduce the finding, each " \
          "with a role (setup/baseline/variant/control/cleanup) and at most one assertion. " \
          "Every step is resolved against the project as it is now, so the reply already " \
          "says what each one will SEND (method + url), which steps change state, and which " \
          "cannot run at all — read this before run_retest rather than sending to find out." do |s|
          s.field "issue_id", intprop("the issue whose retest to list"), required: true
        end

        tool j, "list_retest_runs",
          "The Issue's bounded retest history, newest first (the last #{Retest::RUN_HISTORY} " \
          "runs are kept): verdict, when, from which surface, and the per-outcome counts. " \
          "Use it to answer \"did this regress\" without re-sending anything." do |s|
          s.field "issue_id", intprop("the issue"), required: true
          s.field "limit", intprop("how many runs (default and maximum #{Retest::RUN_HISTORY})")
        end

        tool j, "get_retest_run",
          "One run's result table: role, Repeater session, the expected result, what actually " \
          "happened and pass/fail per step. Each row keeps the History flow id of its own " \
          "send, so an old row still opens the exact response it reported (get_flow)." do |s|
          s.field "run_id", intprop("the run id (from list_retest_runs)"), required: true
        end

        return unless @allow_actions

        tool j, "add_retest_step",
          "Append a Repeater session to an Issue's retest. The session is NOT copied — the " \
          "step sends whatever the tab holds when the retest runs, which is what makes a " \
          "retest track a fixed request rather than freeze one (freeze_evidence keeps bytes). " \
          "Roles: setup establishes the precondition (a failed one halts the measurement " \
          "steps), baseline is the anchor body:same/body:diff compare against, variant is the " \
          "case under test, control the negative case, cleanup the undo. " \
          "Assertions — at most one, omit to record the outcome and assert nothing: " \
          "#{retest_assertion_help}" do |s|
          s.field "issue_id", intprop("the issue that owns the retest"), required: true
          s.field "repeater_id", intprop("the Repeater session this step sends"), required: true
          s.field "role", enumprop("what this step is for (default variant)", RETEST_ROLES)
          s.field "assertion", strprop("the one expected result, e.g. \"status:403\" or \"json:data.role=admin\" (omit for none)")
        end

        tool j, "update_retest_step",
          "Change one step's role and/or its expected result. Pass assertion:\"\" to drop the " \
          "assertion and only record the outcome. Assertions: #{retest_assertion_help}" do |s|
          s.field "id", intprop("the retest step id (from list_retest_steps)"), required: true
          s.field "role", enumprop("the new role", RETEST_ROLES)
          s.field "assertion", strprop("the new expected result (\"\" clears it)")
        end

        tool j, "move_retest_step",
          "Move one step to a 1-based position, shifting the rest. Order is what a run " \
          "executes in — a `baseline` must run before any step that compares against it." do |s|
          s.field "id", intprop("the retest step id"), required: true
          s.field "position", intprop("the new 1-based position (clamped to the list)"), required: true
        end

        tool j, "remove_retest_step",
          "Remove one step and close the gap its position left. The Repeater session and any " \
          "entity link to it are untouched: a retest step is a test plan, not a link." do |s|
          s.field "id", intprop("the retest step id"), required: true
        end

        tool j, "clear_retest_steps",
          "Drop every step of an Issue's retest. The run history is KEPT: re-planning the " \
          "check does not un-run it, and an old summary is the regression baseline." do |s|
          s.field "issue_id", intprop("the issue whose steps to clear"), required: true
        end

        tool j, "delete_retest_run",
          "Delete one run summary and its result rows. The steps stay, and so do the History " \
          "flows each send recorded — this drops the report, not the evidence. The history " \
          "prunes itself to the newest #{Retest::RUN_HISTORY}, so use this for a run that " \
          "should not be on the record at all (sent at the wrong target, or under a scope " \
          "since fixed)." do |s|
          s.field "run_id", intprop("the run id (from list_retest_runs)"), required: true
        end

        tool j, "run_retest",
          "Run an Issue's retest: every step in order, through the project's scope and " \
          "Sandbox gates, judged against its assertion. This is the answer to \"is the " \
          "finding still there\" after a fix. Each send is recorded in History as " \
          "`src:retest` with the issue and step on the row, and the summary is kept on the " \
          "Issue. Returns verdict pass|fail|inconclusive|blocked plus a row per step; " \
          "isError is set on anything but `pass`. A batch containing a state-changing method " \
          "is REFUSED (CONFIRM_REQUIRED) with the exact request count until confirm:true — " \
          "each of those re-runs its side effect on the target. Once gori refuses a send " \
          "(scope/Sandbox/exclude) the rest is skipped, cleanup included, unless " \
          "allow_cleanup:true." do |s|
          s.field "issue_id", intprop("the issue to retest"), required: true
          s.field "confirm", boolprop("required when the batch contains a state-changing method (default false)")
          s.field "allow_cleanup", boolprop("run cleanup steps even after gori refused a send (default false)")
          s.field "allow_unscoped", boolprop("send even if a target is outside the project scope; Sandbox and explicit excludes still apply (default false)")
          s.field "record_history", boolprop("write each send to History (default true — a retest is evidence)")
          s.field "verify", boolprop("verify upstream TLS certificates (default true; can only tighten the server's own setting)")
          s.field "timeout_ms", intprop("per-step connect + idle timeout in ms (default #{Retest::LiveBackend::DEFAULT_TIMEOUT.total_milliseconds.to_i}, 100-120000)")
        end
      end
    end
  end
end
