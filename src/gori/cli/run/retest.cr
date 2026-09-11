# `gori run retest` — an Issue's REPRODUCIBLE check (#1036): an ordered list of Repeater
# sends, each with a role (setup / baseline / variant / control / cleanup) and at most one
# assertion, plus the bounded record of what happened the last few times it ran.
#
# `links` says what material is related to a finding and `evidence` keeps the bytes that
# proved it; neither can be RUN. This is the surface that turns "send #4, then #5 should
# answer 403" out of an issue's prose into something CI can execute and exit on — `run`
# returns 0 only on `pass`.
require "../../retest"
require "../../retest/live_backend"
require "../../mcp/serialize"

module Gori
  module CLI
    module Run
      @[Subcommand("retest", help: [
        {"retest (steps)", "List an Issue's retest steps"},
        {"retest add", "Add a Repeater session as a retest step (role + assertion)"},
        {"retest run", "Run an Issue's retest and report pass/fail (exit 1 unless it passes)"},
        {"retest runs", "List the bounded run history for an Issue"},
      ])]
      private def self.cmd_retest(args : Array(String)) : Nil
        case sub = args.first?
        when "steps", "list" then cmd_retest_steps(args[1..])
        when "add"           then cmd_retest_add(args[1..])
        when "update", "set" then cmd_retest_update(args[1..])
        when "remove", "rm"  then cmd_retest_remove(args[1..])
        when "move"          then cmd_retest_move(args[1..])
        when "clear"         then cmd_retest_clear(args[1..])
        when "run"           then cmd_retest_run(args[1..])
        when "runs"          then cmd_retest_runs(args[1..])
        when "show"          then cmd_retest_show(args[1..])
        when "forget"        then cmd_retest_forget(args[1..])
        else
          # See `verb_token?` — a bare word here is a mistyped verb, not a query.
          if verb_token?(sub)
            abort "gori run retest: unknown subcommand '#{sub}' " \
                  "(steps, add, update, remove/rm, move, clear, run, runs, show, forget)"
          end
          cmd_retest_steps(args)
        end
      end

      RETEST_VERBS = "steps, add, update, remove/rm, move, clear, run, runs, show, forget"

      # The assertion grammar, indented for an OptionParser banner. ONE list
      # (`Retest::Assertion::FORMS`), so the CLI help and the MCP schema cannot drift from
      # what `parse` accepts.
      private def self.retest_assert_help : String
        Retest::Assertion::FORMS.map { |f| "  #{f}" }.join("\n")
      end

      private def self.cmd_retest_steps(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        issue_id : Int64? = nil
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest [steps] --issue=N\n\n" \
                     "List an Issue's retest: each step's position, role, the Repeater session it\n" \
                     "sends, and the one result it expects. A step whose session no longer exists\n" \
                     "is listed with the reason — a retest that quietly became shorter is not a\n" \
                     "retest that passed.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run retest add --issue=N --repeater=M [--role=ROLE] [--assert=EXPR]\n" \
                     "  gori run retest update STEP [--role=ROLE] [--assert=EXPR]\n" \
                     "  gori run retest remove STEP   (`rm` is accepted)\n" \
                     "  gori run retest move STEP --to=POS\n" \
                     "  gori run retest clear --issue=N --yes\n" \
                     "  gori run retest run --issue=N [--yes]\n" \
                     "  gori run retest runs --issue=N\n" \
                     "  gori run retest show RUN\n" \
                     "  gori run retest forget RUN"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--issue=N", "Issue id (required)") { |v| issue_id = parse_retest_id(v, "--issue") }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run retest: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "retest", RETEST_VERBS, "steps")
        iid = require_issue_id(issue_id, "gori run retest")

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        planned, last = begin
          abort "gori run retest: no issue with id #{iid}" unless store.get_issue(iid)
          {Retest.plan(store, iid), store.last_retest_run(iid)}
        ensure
          store.close
        end

        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "issue_id", iid
              j.field("steps") { j.array { planned.each { |pl| j.object { MCP::Serialize.retest_planned(j, pl) } } } }
              j.field "total", planned.size
              if r = last
                j.field("last_run") { j.object { MCP::Serialize.retest_run(j, r) } }
              end
            end
          end)
          return
        end
        if planned.empty?
          puts "issue ##{iid} has no retest steps — add one with " \
               "`gori run retest add --issue=#{iid} --repeater=<id> --role=baseline`"
          return
        end
        planned.each { |pl| puts retest_step_line(pl) }
        if note = Retest.confirm_note(planned)
          puts "note: #{note}"
        end
        if r = last
          puts "last run: #{retest_run_line(r)}"
        end
      end

      private def self.cmd_retest_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        issue_id : Int64? = nil
        repeater_id : Int64? = nil
        role_s = "variant"
        assertion = ""
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest add --issue=N --repeater=M [--role=ROLE] [--assert=EXPR]\n\n" \
                     "Append a Repeater session to an Issue's retest. The session is NOT copied:\n" \
                     "the step sends whatever the tab holds when the retest runs, which is what\n" \
                     "makes a retest track an edited request rather than freeze one (freeze the\n" \
                     "bytes with `gori run evidence` instead).\n\n" \
                     "Roles: setup (establish the precondition), baseline (the anchor body:same /\n" \
                     "body:diff compare against), variant (the case under test), control (the\n" \
                     "negative case), cleanup (undo). Order is the order steps were added; change\n" \
                     "it with `retest move`.\n\n" \
                     "Assertions (at most one per step, omit for \"record the outcome, assert nothing\"):\n" \
                     "#{retest_assert_help}"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--issue=N", "Issue id (required)") { |v| issue_id = parse_retest_id(v, "--issue") }
          p.on("--repeater=M", "Repeater session id to send (required; ids from `gori run repeater list`)") { |v| repeater_id = parse_retest_id(v, "--repeater") }
          p.on("--role=ROLE", "setup | baseline | variant (default) | control | cleanup") { |v| role_s = v }
          p.on("--assert=EXPR", "The one expected result (see the list above)") { |v| assertion = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run retest add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest add: missing value for #{f}" }
        end
        parser.parse(args)
        # Deferred past `parse` for the reason `cmd_evidence_freeze` gives: the unknown-args
        # callback runs before the flag sweep, so aborting inside it misdiagnoses a typo'd flag.
        unless leftover.empty?
          abort "gori run retest add: unexpected argument#{leftover.size == 1 ? "" : "s"} " \
                "#{leftover.join(" ").inspect} — every end is named by a flag (--issue, --repeater)"
        end
        iid = require_issue_id(issue_id, "gori run retest add")
        rid_opt = repeater_id
        abort "gori run retest add: --repeater is required" if rid_opt.nil?
        rid = rid_opt
        role = Store::RetestRole.parse?(role_s) ||
               abort("gori run retest add: invalid --role #{role_s.inspect} (#{retest_roles})")
        parsed = Retest::Assertion.parse(assertion)
        abort "gori run retest add: --assert: #{parsed}" if parsed.is_a?(String)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          abort "gori run retest add: no issue with id #{iid}" unless store.get_issue(iid)
          abort "gori run retest add: no repeater session ##{rid} (ids from `gori run repeater list`)" unless store.get_repeater(rid)
          id, status = store.add_retest_step(iid, role, Store::LinkRefKind::Repeater, rid, parsed.to_s)
          case status
          in .issue_gone? then abort "gori run retest add: issue ##{iid} was deleted before the step was written"
          in .step_gone?  then abort "gori run retest add: the step disappeared before it could be written"
          in .busy?       then abort "gori run retest add: nothing added (project busy or unwritable)"
          in .ok?         then nil
          end
          step = store.get_retest_step(id) || abort("gori run retest add: step ##{id} vanished before it could be read back")
          planned = Retest.plan(store, [step]).first
          if format == :json
            puts(JSON.build { |j| j.object { MCP::Serialize.retest_planned(j, planned) } })
          else
            puts "Added step #{step.position} to issue ##{iid}: #{retest_step_line(planned)}"
          end
        ensure
          store.close
        end
      end

      private def self.cmd_retest_update(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        role_s : String? = nil
        assertion : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest update STEP [--role=ROLE] [--assert=EXPR]\n\n" \
                     "Change one step's role and/or its expected result. STEP is the step id from\n" \
                     "`gori run retest steps --format=json`, not its position — a position moves.\n" \
                     "Pass --assert= (empty) to drop the assertion and only record the outcome.\n\n" \
                     "Assertions:\n#{retest_assert_help}"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--role=ROLE", "setup | baseline | variant | control | cleanup") { |v| role_s = v }
          p.on("--assert=EXPR", "The one expected result (empty clears it)") { |v| assertion = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run retest update: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest update: missing value for #{f}" }
        end
        parser.parse(args)
        id = require_positional_id(positional, "gori run retest update", "step")
        abort "gori run retest update: nothing to change — pass --role and/or --assert" if role_s.nil? && assertion.nil?
        role = role_s.try do |s|
          Store::RetestRole.parse?(s) || abort("gori run retest update: invalid --role #{s.inspect} (#{retest_roles})")
        end
        stored_assertion = assertion.try do |a|
          parsed = Retest::Assertion.parse(a)
          abort "gori run retest update: --assert: #{parsed}" if parsed.is_a?(String)
          parsed.to_s
        end

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          abort "gori run retest update: no retest step with id #{id}" unless store.get_retest_step(id)
          case store.update_retest_step(id, role: role, assertion: stored_assertion)
          in .issue_gone? then abort "gori run retest update: the issue was deleted before the edit landed"
          in .step_gone?  then abort "gori run retest update: step ##{id} was deleted before the edit landed"
          in .busy?       then abort "gori run retest update: NOT updated (project busy or unwritable)"
          in .ok?         then nil
          end
          step = store.get_retest_step(id) || abort("gori run retest update: step ##{id} vanished before it could be read back")
          puts "Updated step #{step.position} of issue ##{step.issue_id}: #{retest_step_line(Retest.plan(store, [step]).first)}"
        ensure
          store.close
        end
      end

      private def self.cmd_retest_remove(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest remove STEP\n\n" \
                     "Remove one step and close the gap its position left. The Repeater session and\n" \
                     "any entity link to it are untouched: a retest step is a test plan, not a link."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run retest remove: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest remove: missing value for #{f}" }
        end
        parser.parse(args)
        id = require_positional_id(positional, "gori run retest remove", "step")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          step = store.get_retest_step(id) || abort("gori run retest remove: no retest step with id #{id}")
          case store.remove_retest_step(id)
          in .issue_gone?, .step_gone? then abort "gori run retest remove: step ##{id} was already gone"
          in .busy?                    then abort "gori run retest remove: NOT removed (project busy or unwritable)"
          in .ok?                      then nil
          end
          puts "Removed step #{step.position} (#{step.role.label}, #{step.ref_label}) from issue ##{step.issue_id}."
        ensure
          store.close
        end
      end

      private def self.cmd_retest_move(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        to : Int32? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest move STEP --to=POS\n\n" \
                     "Move one step to position POS (1-based), shifting the rest. Clamped to the\n" \
                     "list, so --to=1 always means \"first\"."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          # Clamped BEFORE `to_i`, for the reason MCP's `move_retest_step` states: the store
          # clamps to the list anyway, and an unclamped `Int64#to_i` past `Int32::MAX` raises
          # `OverflowError` — an unhandled crash out of an OptionParser block, for an argument
          # whose only meaning is "as far as it goes".
          p.on("--to=POS", "New 1-based position (required; clamped to the list)") do |v|
            to = parse_retest_id(v, "--to").clamp(1_i64, Int32::MAX.to_i64).to_i
          end
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run retest move: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest move: missing value for #{f}" }
        end
        parser.parse(args)
        id = require_positional_id(positional, "gori run retest move", "step")
        pos_opt = to
        abort "gori run retest move: --to is required" if pos_opt.nil?
        pos = pos_opt

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          abort "gori run retest move: no retest step with id #{id}" unless store.get_retest_step(id)
          case store.move_retest_step(id, pos)
          in .issue_gone?, .step_gone? then abort "gori run retest move: step ##{id} was deleted before the move landed"
          in .busy?                    then abort "gori run retest move: NOT moved (project busy or unwritable)"
          in .ok?                      then nil
          end
          step = store.get_retest_step(id) || abort("gori run retest move: step ##{id} vanished before it could be read back")
          # ONE `plan` over the whole list — it takes the array, and is what every other
          # surface calls. Per-step it allocated a throwaway `[s]` and re-read the store N
          # times to print one listing.
          Retest.plan(store, store.retest_steps(step.issue_id)).each { |pl| puts retest_step_line(pl) }
        ensure
          store.close
        end
      end

      private def self.cmd_retest_clear(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        issue_id : Int64? = nil
        yes = false
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest clear --issue=N --yes\n\n" \
                     "Delete every step of one Issue's retest. The run history is KEPT: re-planning\n" \
                     "the check does not un-run it, and an old summary is the regression baseline."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--issue=N", "Issue id (required)") { |v| issue_id = parse_retest_id(v, "--issue") }
          # `-y` too, because the option table documents the pair for BOTH verbs and `run`
          # registers both — following the docs on this one aborted with "unknown option: -y".
          p.on("-y", "--yes", "Actually delete the steps (required — there is no interactive prompt here)") { yes = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run retest clear: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest clear: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run retest clear: unexpected argument#{leftover.size == 1 ? "" : "s"} #{leftover.join(" ").inspect}" unless leftover.empty?
        iid = require_issue_id(issue_id, "gori run retest clear")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          abort "gori run retest clear: no issue with id #{iid}" unless store.get_issue(iid)
          n = store.count_retest_steps(iid)
          abort "gori run retest clear: issue ##{iid} has no retest steps" if n == 0
          unless yes
            abort "gori run retest clear: this would delete #{n} step#{n == 1 ? "" : "s"} from issue ##{iid} — pass --yes to do it"
          end
          abort "gori run retest clear: NOT cleared (project busy or unwritable)" unless store.clear_retest_steps(iid)
          puts "Cleared #{n} retest step#{n == 1 ? "" : "s"} from issue ##{iid}."
        ensure
          store.close
        end
      end

      # The one command that SENDS. Exit code is the verdict — 0 only on `pass` — so a fix's
      # CI job can gate on it without parsing the output.
      private def self.cmd_retest_run(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        issue_id : Int64? = nil
        yes = false
        allow_cleanup = false
        allow_unscoped = false
        record_history = true
        insecure = false
        slot : String? = nil
        timeout : Time::Span? = nil
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest run --issue=N [--yes]\n\n" \
                     "Run an Issue's retest: every step in order, through the project's scope and\n" \
                     "Sandbox gates, judged against its assertion. Each send is recorded in History\n" \
                     "as `src:retest` with the issue and step on the row, and the run summary is\n" \
                     "kept on the Issue (the newest #{Retest::RUN_HISTORY} runs).\n\n" \
                     "A batch that contains a state-changing method (anything but GET/HEAD/OPTIONS)\n" \
                     "refuses without --yes and prints the exact request count first: every one of\n" \
                     "them re-runs its side effect on the target.\n\n" \
                     "Once gori REFUSES a send (scope, Sandbox, an exclude rule) the rest of the run\n" \
                     "is skipped — cleanup steps included, unless --allow-cleanup says otherwise.\n\n" \
                     "Exit code: 0 when the verdict is `pass`, 1 otherwise."
          p.on("--project=NAME", "Project to run in (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          p.on("--issue=N", "Issue id (required)") { |v| issue_id = parse_retest_id(v, "--issue") }
          p.on("-y", "--yes", "Confirm a batch containing state-changing methods") { yes = true }
          p.on("--allow-cleanup", "Run cleanup steps even after gori refused a send") { allow_cleanup = true }
          p.on("--allow-unscoped", "Send even if a target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--no-record-history", "Do not write each send to History (default: record — a retest is evidence)") { record_history = false }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--slot=NAME", "Send every step as this SESSION SLOT — its header overlay, and its binding table for $NAME") { |v| slot = v.strip }
          p.on("--timeout=SEC", "Per-step connect + idle timeout (seconds, default #{Retest::LiveBackend::DEFAULT_TIMEOUT.total_seconds.to_i})") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run retest run: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest run: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run retest run: unexpected argument#{leftover.size == 1 ? "" : "s"} #{leftover.join(" ").inspect}" unless leftover.empty?
        iid = require_issue_id(issue_id, "gori run retest run")

        # Resolved ONCE and reused after the sends, for the reason `cmd_repeater_send` gives:
        # `resolve_read_project` with no --project/--db picks the most-recently-active project
        # by mtime, and a retest is several seconds long — re-resolving at persist time could
        # write the run summary into a DIFFERENT project.
        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          abort "gori run retest run: no issue with id #{iid}" unless store.get_issue(iid)
          planned = Retest.plan(store, iid)
          if planned.empty?
            abort "gori run retest run: issue ##{iid} has no retest steps — add one with " \
                  "`gori run retest add --issue=#{iid} --repeater=<id> --role=baseline`"
          end
          if (note = Retest.confirm_note(planned)) && !yes
            STDERR.puts "gori run retest run: #{note}"
            abort "gori run retest run: refusing without --yes"
          end
          # After `open_store` (which installs `Env.layer`) and before anything builds bytes:
          # `Repeater::Sender` reads the active slot at the send seam.
          activate_slot(slot, "gori run retest run")
          overrides = Gori::HostOverrides.load(store)
          # Read out of the OptionParser block's nilable in place — same narrowing the
          # `require_issue_id` helper exists for.
          t = timeout
          step_timeout = t.nil? ? Retest::LiveBackend::DEFAULT_TIMEOUT : t
          outbound = project_outbound(project_name, db_path, allow_unscoped)
          backend = Retest::LiveBackend.new(store, outbound,
            issue_id: iid, surface: Gori::FlowSource::Surface::Cli,
            overrides: overrides, verify: !insecure,
            timeout: step_timeout,
            record_history: record_history, waiver: "--allow-unscoped")
          report = Retest.execute(store, planned, backend,
            issue_id: iid, surface: Gori::FlowSource::Surface::Cli,
            allow_cleanup: allow_cleanup)
          # The session slot's `$NAME` that went out LITERALLY, after the run and before the
          # exit code — the placement `gori run repeater send` uses.
          report_unbound_slot_overlay("gori run retest run")
          emit_retest_report(iid, report, format)
          passed = report.verdict.pass?
        ensure
          store.close
        end
        # AFTER the ensure, never inside it: Crystal's `exit` calls `Crystal.exit` directly
        # and does NOT unwind, so an `exit` in the block above would skip `store.close`
        # entirely — leaving the writer fiber undrained, the WAL un-checkpointed and the
        # OpenLock held, on the one retest command that writes. `gori run oast`'s
        # `cmd_oast_listen` states the same rule at its own raise.
        exit(passed ? 0 : 1)
      end

      private def self.cmd_retest_runs(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        issue_id : Int64? = nil
        limit = Retest::RUN_HISTORY
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest runs --issue=N\n\n" \
                     "The Issue's bounded run history, newest first: when it ran, from which\n" \
                     "surface, the verdict and the per-outcome counts. `gori run retest show RUN`\n" \
                     "prints one run's result table."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--issue=N", "Issue id (required)") { |v| issue_id = parse_retest_id(v, "--issue") }
          p.on("--limit=N", "How many runs to print (default #{Retest::RUN_HISTORY}, which is all that is kept)") { |v| limit = parse_count(v, "--limit").to_i }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run retest runs: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest runs: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "retest", RETEST_VERBS, "runs")
        iid = require_issue_id(issue_id, "gori run retest runs")

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        runs = begin
          abort "gori run retest runs: no issue with id #{iid}" unless store.get_issue(iid)
          store.retest_runs(iid, limit)
        ensure
          store.close
        end

        if format == :json
          puts(JSON.build { |j| j.array { runs.each { |r| j.object { MCP::Serialize.retest_run(j, r) } } } })
        elsif runs.empty?
          puts "issue ##{iid} has no retest runs yet"
        else
          runs.each { |r| puts retest_run_line(r) }
        end
      end

      private def self.cmd_retest_show(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest show RUN [--format=text|json]\n\n" \
                     "One run's result table: role, Repeater session, expected result, what actually\n" \
                     "happened, and pass/fail per step. Every row keeps the History flow id of its\n" \
                     "own send, so an old row still opens the exact response it reported."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run retest show: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest show: missing value for #{f}" }
        end
        parser.parse(args)
        id = require_positional_id(positional, "gori run retest show", "run")

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        run, steps = begin
          r = store.get_retest_run(id) || abort("gori run retest show: no retest run with id #{id}")
          {r, store.retest_run_steps(id)}
        ensure
          store.close
        end

        if format == :json
          puts(JSON.build do |j|
            j.object do
              MCP::Serialize.retest_run(j, run)
              j.field("steps") { j.array { steps.each { |s| j.object { MCP::Serialize.retest_run_step(j, s) } } } }
            end
          end)
        else
          puts retest_run_line(run)
          steps.each { |s| puts retest_result_line(s.position, s.role, s.label, s.assertion, s.outcome, s.detail, s.flow_id) }
        end
      end

      # The run history prunes itself to the newest `Retest::RUN_HISTORY`, so this is not
      # housekeeping — it is for the run that should not be ON the record: a batch sent at the
      # wrong target, or under a scope the operator has since fixed. The steps that produced
      # it are untouched.
      private def self.cmd_retest_forget(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run retest forget RUN\n\n" \
                     "Delete one run summary and its result rows. The retest steps stay, and the\n" \
                     "History flows each send recorded stay — this drops the report, not the evidence."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run retest forget: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run retest forget: missing value for #{f}" }
        end
        parser.parse(args)
        id = require_positional_id(positional, "gori run retest forget", "run")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          run = store.get_retest_run(id) || abort("gori run retest forget: no retest run with id #{id}")
          abort "gori run retest forget: NOT deleted (project busy or unwritable)" unless store.delete_retest_run(id)
          puts "Forgot retest run ##{id} of issue ##{run.issue_id} (#{run.verdict.label}, #{run.total} step#{run.total == 1 ? "" : "s"})."
        ensure
          store.close
        end
      end

      # --- shared rendering ----------------------------------------------------

      # The required `--issue`, split out for the reason `resolve_freeze_ends` gives: the value
      # is assigned inside an OptionParser block, so Crystal keeps it nilable in place and a
      # bare `issue_id || abort` does not narrow it.
      private def self.require_issue_id(issue_id : Int64?, cmd : String) : Int64
        v = issue_id
        abort "#{cmd}: --issue is required" if v.nil?
        v
      end

      # The one positional id every step/run verb takes — same narrowing problem, same shape.
      private def self.require_positional_id(positional : Array(String), cmd : String,
                                             noun : String) : Int64
        abort "#{cmd}: too many arguments (expected one <#{noun}>, got: #{positional.join(" ")})" if positional.size > 1
        v = positional.first?
        abort "#{cmd}: <#{noun}> is required" if v.nil?
        parse_retest_id(v, "<#{noun}>")
      end

      private def self.retest_roles : String
        Store::RetestRole.values.map(&.label).join(" | ")
      end

      private def self.parse_retest_id(v : String, flag : String) : Int64
        v.to_i64? || abort("gori run retest: invalid #{flag} #{v.inspect} (expected an integer)")
      end

      # `1  baseline  repeater #4  GET https://a.test/me  expect status:200`
      private def self.retest_step_line(pl : Retest::Planned) : String
        step = pl.step
        expect = step.assertion.empty? ? "(no assertion)" : "expect #{step.assertion}"
        line = "#{step.position}  [#{step.id}]  #{step.role.label.ljust(8)}  #{step.ref_label}  " \
               "#{pl.method} #{Issues::Export.one_line(pl.url)}  #{expect}"
        pl.missing.try { |reason| line += "  — #{reason}" }
        line
      end

      # `#7  2026-09-11T05:02:33Z  cli  FAIL  4 steps · 2 passed · 1 failed · 1 skipped`
      private def self.retest_run_line(r : Store::RetestRun) : String
        t = Retest::Tally.new(r.total, r.passed, r.failed, r.inconclusive, r.errored, r.blocked, r.skipped)
        "##{r.id}  #{MCP::Serialize.unix_micros_iso(r.started_at)}  #{r.surface || "—"}  " \
        "#{r.verdict.label.upcase}  #{r.total} step#{r.total == 1 ? "" : "s"} · #{Retest.summary_line(t)}"
      end

      private def self.retest_result_line(position : Int32, role : Store::RetestRole, label : String,
                                          assertion : String, outcome : Store::RetestOutcome,
                                          detail : String, flow_id : Int64?) : String
        expect = assertion.empty? ? "—" : assertion
        flow = flow_id ? "  flow ##{flow_id}" : ""
        "  #{position}  #{role.label.ljust(8)}  #{outcome.label.upcase.ljust(12)}  " \
        "#{Issues::Export.one_line(label)}  expect #{expect}  → #{Issues::Export.one_line(detail)}#{flow}"
      end

      private def self.emit_retest_report(issue_id : Int64, report : Retest::RunReport,
                                          format : Symbol) : Nil
        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "issue_id", issue_id
              j.field "run_id", report.run_id if report.run_id > 0
              j.field "verdict", report.verdict.label
              MCP::Serialize.retest_tally(j, report.tally)
              j.field "started_at", report.started_at
              j.field "started_at_iso", MCP::Serialize.unix_micros_iso(report.started_at)
              j.field "duration_us", {report.finished_at - report.started_at, 0_i64}.max
              j.field("steps") { j.array { report.results.each { |r| j.object { MCP::Serialize.retest_step_result(j, r) } } } }
              j.field "summary_persisted", report.stored.ok?
            end
          end)
          return
        end
        report.results.each_with_index do |r, i|
          puts retest_result_line(i + 1, r.step.role, r.planned.label, r.step.assertion,
            r.outcome, r.detail, r.observation.flow_id)
        end
        puts "issue ##{issue_id}: #{report.verdict.label.upcase} — #{Retest.summary_line(report.tally)}" \
             "#{report.run_id > 0 ? " (run ##{report.run_id})" : ""}"
        # SAID, not swallowed: a run whose summary did not land still ran, and a later
        # regression check will simply not find it.
        unless report.stored.ok?
          STDERR.puts "gori run retest run: the run summary was NOT saved " \
                      "(#{report.stored.issue_gone? ? "the issue was deleted mid-run" : "project busy or unwritable"})"
        end
      end
    end
  end
end
