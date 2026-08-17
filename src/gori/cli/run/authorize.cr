# `gori run authorize` — replay captured requests under several identities and read the
# responses against a baseline (broken access control), the headless equivalent of the TUI
# Authorize tab.
module Gori
  module CLI
    module Run
      private def self.cmd_authorize(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_ids = [] of Int64
        query : String? = nil
        limit = Authorize::Plan::DEFAULT_LIMIT
        identities_file : String? = nil
        unsafe_methods = false
        allow_unscoped = false
        insecure = false
        timeout = Authorize::ACTIVE_TIMEOUT
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run authorize [<flow-id>…] [options]\n\n" \
                     "Replay each selected flow under every IDENTITY — a header overlay standing in\n" \
                     "for an admin session, a low-privilege user, an anonymous client — and judge\n" \
                     "each response against the baseline's. An identity that is served what the\n" \
                     "baseline was served is a likely access-control BYPASS.\n\n" \
                     "Identities come from the project (the TUI Authorize tab's list) unless\n" \
                     "--identities names a JSON file:\n" \
                     "  [{\"name\":\"anonymous\",\"remove\":[\"Cookie\",\"Authorization\"]},\n" \
                     "   {\"name\":\"low-priv\",\"set\":[{\"name\":\"Cookie\",\"value\":\"session=…\"}]}]\n" \
                     "The request as captured is the baseline unless an entry claims \"baseline\".\n\n" \
                     "Only safe methods (GET/HEAD/OPTIONS) are replayed without --unsafe-methods:\n" \
                     "every other method re-runs its side effect once per identity."
          p.on("--flow=ID", "Replay this captured flow (repeatable; same as a positional id)") { |v| flow_ids << parse_flow_id(v, "gori run authorize") }
          p.on("-qQL", "--query=QL", "Also replay every flow matching this QL query (host: path: status: …)") { |v| query = v }
          p.on("-nN", "--limit=N", "Max flows --query may contribute (default #{Authorize::Plan::DEFAULT_LIMIT})") { |v| limit = parse_count(v, "--limit") }
          p.on("--identities=FILE", "Identity set as JSON ('-' = stdin); default: the project's saved set") { |v| identities_file = v }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--unsafe-methods", "Also replay POST/PUT/PATCH/DELETE — each identity re-runs the side effect") { unsafe_methods = true }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--format=FMT", "Output: text (default) | json (one array at the end) | jsonl (streamed)") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          # BOTH halves: the second is everything after a `--`, which a handler binding only the
          # first silently discards (see spec/cli_spec.cr's source guard). Here that would drop
          # flow ids — `gori run authorize -- 42` would refuse with "no request selected".
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run authorize: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run authorize: missing value for #{f}" }
        end
        # `-q '-path:/x'` reads as another flag unless it is rewritten to `--query=…` first —
        # the same normalization history/probe do. (Negation terms are NOT lifted out of argv
        # here the way they are there: a positional on this command is a flow id, not a query,
        # so a bare `-path:/x` is a usage error rather than a term to fold in.)
        parser.parse(normalize_query_flag(args))
        positional.each { |s| flow_ids << parse_flow_id(s, "gori run authorize") }
        # An unrecognized/uncompilable term makes the selection BROADER than asked, and every
        # extra row here is `identities.size` more requests on a target.
        query.try { |q| Run.warn_query_terms("authorize", q) }

        # Read the identity file BEFORE opening anything: an unreadable path is the operator's
        # typo, and it should not cost a project open (or a scope load) to hear about it.
        identities_json = identities_file.try { |f| read_input_file(f, "gori run authorize", stdin: true) }

        store = open_store(resolve_read_project(project_name, db_path))
        # Authorize ALWAYS has a project in play (the flows and the identities both come out of
        # one), so this is `project_outbound`, never the optional variant: an omitted --project
        # resolves the most-recently-active project, which is exactly the case where
        # short-circuiting on "no --project given" would drop Sandbox containment.
        outbound = project_outbound(project_name, db_path, allow_unscoped)
        plan = begin
          Authorize::Plan.build(Authorize::PlanOptions.new(store,
            flow_ids: flow_ids, query: query, limit: limit, identities_json: identities_json,
            unsafe_methods: unsafe_methods, verify: !insecure, timeout: timeout), outbound)
        rescue ex : Authorize::PlanError
          store.close
          outbound.close
          authorize_plan_abort(ex)
        end
        # The plan holds every target's FlowDetail already, and nothing downstream reads the DB
        # again — so the read connection goes now rather than being held for the whole run.
        # (`outbound` keeps its OWN connection open on purpose: that is what lets a mid-run
        # scope/Sandbox change stop an in-flight sweep.)
        store.close
        if query && (plan.targets.size + plan.skipped.size) >= limit
          STDERR.puts "gori run authorize: --query was capped at --limit #{limit} — " \
                      "matching flows past that were not replayed (raise --limit to include them)"
        end
        begin
          run_authorize(plan, format)
        ensure
          outbound.close
        end
      end

      # Replay the plan, reporting as each request lands.
      #
      # Skips are stated UP FRONT, per flow: "gori sent nothing for this one" and "there was
      # nothing there" are different answers and the operator has to be able to tell them apart
      # (DESIGN.md §7). A partial refusal is otherwise invisible — the run just looks smaller
      # than the selection.
      private def self.run_authorize(plan : Authorize::Plan, format : Symbol) : Nil
        total = plan.targets.size
        ids = plan.identities.size
        STDERR.puts "authorizing #{total} request#{total == 1 ? "" : "s"} × #{ids} identities " \
                    "(#{plan.identities.map(&.name).join(", ")}) = #{plan.total_sends} requests"
        report_authorize_skips(plan.skipped)

        buffered = [] of Authorize::Target
        done = 0
        bypasses = 0
        blocked_runs = 0
        blocked_reason : String? = nil
        stopping = false
        # `--format json` buffers every target and prints ONCE after the loop, so a bare SIGINT
        # threw away the whole run. The stop is polled between requests AND handed to the engine
        # (see `Authorize::Plan#run`), so the emit below covers the interrupted path too.
        interrupted = Run.install_interrupt_trap("authorize-interrupt",
          "interrupted — stopping and reporting the requests already compared…") { stopping = true }
        sent = plan.run(-> { stopping }) do |_detail, target|
          bypasses += 1 if CLI::Output.authorize_verdict(target) == :bypass
          if target.fully_blocked?
            blocked_runs += 1
            blocked_reason ||= target.blocked_reason
          end
          emit_authorize_target(target, format, done, buffered)
          done += 1
          authorize_progress(done, total, bypasses, format)
        end
        puts CLI::Output.authorize_array_json(buffered) if format == :json
        authorize_done(sent, total, ids, bypasses)
        # Before the all-refused check below — see `Run.report_interrupted` for why the order
        # matters: a run stopped early has not demonstrated that every send was refused.
        Run.report_interrupted(sent, "request", "replayed") if interrupted.call
        # Every request's every send was refused before the socket. Without this the run reports
        # `0 possible bypasses` — a clean bill of health for traffic that never left the machine,
        # which `Authorize::Target#blocked` names as the worst way this can fail.
        if sent > 0 && blocked_runs == sent
          STDERR.puts "authorize: every send was refused before the socket — " \
                      "#{blocked_reason || "blocked by the project's Sandbox or an exclude rule"}"
          exit 1
        end
      end

      private def self.report_authorize_skips(skipped : Array(Authorize::Skipped)) : Nil
        return if skipped.empty?
        STDERR.puts "skipped #{skipped.size} flow#{skipped.size == 1 ? "" : "s"} · #{Authorize::Plan.skip_tally(skipped)}"
        skipped.each { |s| STDERR.puts "  #{authorize_skip_text(s)}" }
      end

      # "  #12  POST    acme.test/orders   not a safe method to repeat"
      private def self.authorize_skip_text(s : Authorize::Skipped) : String
        String.build do |io|
          io << '#' << s.flow_id.to_s.ljust(6)
          io << CLI::Output.term_safe(s.method).ljust(7)
          io << CLI::Output.term_safe(s.url)
          io << "  — " << s.label
        end
      end

      # `json` buffers and emits ONE array after the drain; `jsonl` streams an object per
      # request. The two are NOT aliases here — that split belongs to `capture`/`history`, and
      # every run-producing tool (fuzz, mine, discover, sequence) draws it this way.
      private def self.emit_authorize_target(t : Authorize::Target, format : Symbol, index : Int32,
                                             buffered : Array(Authorize::Target)) : Nil
        case format
        when :jsonl then puts CLI::Output.authorize_target_json(t)
        when :json  then buffered << t
        else
          puts "" if index > 0
          puts CLI::Output.authorize_target_text(t)
        end
      end

      # The in-place meter, for the formats that show nothing until the end. NOT drawn in text
      # mode: there each request prints its own block as it lands (so the meter says nothing new),
      # and a `\r`-redrawn STDERR line between two STDOUT blocks lands ON one of them when both go
      # to the same terminal.
      private def self.authorize_progress(done : Int32, total : Int32, bypasses : Int32,
                                          format : Symbol) : Nil
        return if format == :text
        return unless STDERR.tty? # the \r-redrawn meter only makes sense on a terminal
        STDERR.print "\r[authorize] #{done}/#{total} requests · #{bypasses} possible bypass#{bypasses == 1 ? "" : "es"}"
        STDERR.flush
      end

      private def self.authorize_done(sent : Int32, total : Int32, ids : Int32, bypasses : Int32) : Nil
        STDERR.print "\r\e[K" if STDERR.tty? # clear the in-place meter before the summary
        # "1 of 3 requests" — the noun agrees with the SELECTION, not with how much of it ran, so
        # an interrupted run does not read as "1 of 3 request".
        of = sent == total ? "" : " of #{total}"
        STDERR.puts "done · #{sent}#{of} request#{total == 1 ? "" : "s"} replayed · #{sent * ids} sends · " \
                    "#{bypasses} possible bypass#{bypasses == 1 ? "" : "es"}"
      end

      # Refuse a selection that cannot become a run, listing what it reached first: `skipped` is
      # populated for `NothingToSend`, and a per-reason tally alone cannot say WHICH flow was
      # dropped for which reason.
      private def self.authorize_plan_abort(ex : Authorize::PlanError) : NoReturn
        report_authorize_skips(ex.skipped)
        abort "gori run authorize: #{authorize_plan_error(ex)}"
      end

      # `gori run authorize`'s wording for a selection the options cannot run. The builder
      # reports the machine-readable `reason`; the sentence — and the flags it names — is ours,
      # and every arm ends in the next thing to type. Exhaustive `in` on purpose: a new
      # `PlanError::Reason` must not compile until this surface has an answer for it.
      private def self.authorize_plan_error(ex : Authorize::PlanError) : String
        case ex.reason
        in Authorize::PlanError::Reason::NoTarget
          "no request selected — name one or more captured flow ids (`gori run authorize 42 43`, " \
          "or --flow 42), or select them with --query (e.g. --query 'host:acme.test method:GET'). " \
          "List what is there with `gori run history`"
        in Authorize::PlanError::Reason::NoFlows
          if q = ex.detail
            "nothing to replay: no captured flow matches #{q.inspect} (nor any --flow id given — " \
            "a pruned or unknown id contributes nothing). Check the selection with " \
            "`gori run history --query #{q.inspect}`"
          else
            "nothing to replay: this project has no captured flow with that id — it was never " \
            "captured, or retention has pruned it. List the ids with `gori run history`"
          end
        in Authorize::PlanError::Reason::BadQuery
          "#{ex.message} — fix it and try it on `gori run history --query …` first. It is refused " \
          "rather than run because a query that compiles to no clause matches EVERY captured " \
          "flow, and each one would be replayed under every identity"
        in Authorize::PlanError::Reason::NoIdentities
          if ex.detail == "json"
            "--identities resolved to fewer than two identities — every trial is judged against a " \
            "baseline, so name at least one identity besides it, e.g. " \
            "[{\"name\":\"anonymous\",\"remove\":[\"Cookie\"]}]. An entry with no \"name\" is " \
            "skipped and a malformed file reads as empty, so check the JSON parsed"
          else
            "this project has no identities saved besides the baseline — add them in the TUI " \
            "Authorize tab, or pass --identities FILE with at least one, e.g. " \
            "[{\"name\":\"anonymous\",\"remove\":[\"Cookie\"]}]"
          end
        in Authorize::PlanError::Reason::NothingToSend
          "every selected flow was skipped (#{ex.detail}), so nothing was sent — replay " \
          "POST/PUT/PATCH/DELETE with --unsafe-methods, reach a host outside the project scope " \
          "with --allow-unscoped, and note that a flow NO identity would change is skipped on " \
          "purpose (add an identity that sets or drops the header that carries the session)"
        end
      end
    end
  end
end
