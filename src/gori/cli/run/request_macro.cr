# `--macro` (#1350): Repeater sessions replayed before a candidate so a per-request CSRF token or
# nonce is fresh when the candidate resolves its `$BIND.NAME`, shared by `gori run fuzz` and
# `gori run mine`. The flag parsing lives here; what a macro MEANS — the cadence, the epochs,
# the failure policy, every gate the steps pass — is `Gori::RequestMacro`, and it is wired by the
# plan builders, so this command, MCP and the TUI cannot come to disagree about it.
module Gori
  module CLI
    module Run
      # The flags of one command's macro, collected while the parser walks argv and turned into a
      # `RequestMacro::Spec` once it is done — so `--macro-every` means the same wherever it sits
      # relative to `--macro`.
      class RequestMacroFlags
        property steps = [] of String
        property every : String? = nil
        property on_failure : String? = nil
        property expect = [] of String
      end

      # Register `--macro` and its companions on `p`. `noun` is what the command sends per
      # macro run: a fuzz `candidate`, a mine `request`.
      private def self.request_macro_flags(p : OptionParser, flags : RequestMacroFlags, noun : String) : Nil
        p.on("--macro=STEPS", "Request-time macro: replay these saved Repeater sessions (ids from `gori run repeater list`, or a " \
                              "tab's name; comma list, repeatable) BEFORE each #{noun}, so the CSRF token or nonce their extract rules " \
                              "leave in the session bindings is fresh when it resolves $BIND.NAME (bare syntax: $NAME). Sent as the " \
                              "active --slot, charged to --max-requests and held to --rate") do |v|
          flags.steps.concat(RequestMacro::Spec.parse_steps(v))
        end
        p.on("--macro-every=WHEN", "How often the macro runs: request (before every #{noun}; " \
                                   "default — the run goes one at a time, so a one-time value is never shared), N (a value shared by N, " \
                                   "up to N running at once), or off") do |v|
          flags.every = v
        end
        p.on("--macro-expect=NAME", "Fail the macro unless it rebinds this binding (repeatable). Default: any binding — " \
                                    "name the one that matters and a missed extract rule cannot pass as a fresh value") do |v|
          flags.expect << v
        end
        p.on("--macro-on-failure=POLICY", "skip (default: the #{noun} is not sent, and the run ends after " \
                                          "#{RequestMacro::Lane::FAILURE_LIMIT} failures in a row) | stop (end the run on the first failure)") do |v|
          flags.on_failure = v
        end
      end

      # The parsed spec, or nil when the command asked for no macro. A companion flag with no
      # `--macro` is a knob that silently did nothing, and is refused instead. Public so a spec
      # can pin what the flags build; the refusals `abort`, which an example cannot observe.
      def self.request_macro_spec(cmd : String, flags : RequestMacroFlags) : RequestMacro::Spec?
        if flags.steps.empty?
          stray = [] of String
          stray << "--macro-every" if flags.every
          stray << "--macro-expect" unless flags.expect.empty?
          stray << "--macro-on-failure" if flags.on_failure
          unless stray.empty?
            abort "#{cmd}: #{stray.join(", ")} modif#{stray.size == 1 ? "ies" : "y"} --macro, and none was given"
          end
          return nil
        end
        cadence = if raw = flags.every
                    RequestMacro::Cadence.parse?(raw) ||
                      abort("#{cmd}: invalid --macro-every '#{raw}' (use request, off, or a number of requests)")
                  else
                    RequestMacro::Cadence.request
                  end
        policy = if raw = flags.on_failure
                   RequestMacro::OnFailure.parse?(raw) ||
                     abort("#{cmd}: invalid --macro-on-failure '#{raw}' (use skip or stop)")
                 else
                   RequestMacro::OnFailure::Skip
                 end
        # Comma-split here, as MCP and the TUI do: `--macro-expect=CSRF,NONCE` is two names.
        # `Spec.new` then strips each spelling (`$CSRF`, `$BIND.CSRF`).
        names = flags.expect.flat_map { |item| RequestMacro::Spec.parse_steps(item) }
        RequestMacro::Spec.new(flags.steps, cadence, policy, names)
      end

      # The project the steps are read from, opened for the lifetime of one plan build. The steps
      # are Repeater sessions, so — like `--payload-from` — they need a project the operator NAMED:
      # a `--flow` / `--repeater` seed and `--project` / `--db` all name one, and a bare
      # `--request` / stdin run (deliberately outside any project) does not. Reading the ambient
      # default there would replay another engagement's sessions at this target, silently.
      #
      # Read-only: the plan freezes the steps, and the History rows and events the run writes go
      # through the writable handle the run opens (`RequestMacro::Runner#record_to`).
      private def self.open_request_macro_store(cmd : String, spec : RequestMacro::Spec?, named_project : Bool,
                                                project_name : String?, db_path : String?) : Store?
        return nil unless spec && spec.active?
        unless named_project
          abort "#{cmd}: --macro replays a project's Repeater sessions and none was named — replaying the default " \
                "project's sessions silently is not something it will do (a --request/stdin run is deliberately " \
                "outside any project). Pass --project NAME or --db PATH."
        end
        open_store(resolve_read_project(project_name, db_path), read_only: true)
      end

      # What the macro will do to the run, said before it starts. On STDERR — STDOUT is data.
      private def self.note_request_macro(cmd : String, info : RequestMacro::Info?) : Nil
        return unless info
        STDERR.puts "#{cmd}: #{info.line}"
      end

      # What it did, said after. Always for a run that had one: "0 failed" is the line that says the
      # macro was working, and a failure without it is the number that explains the error rows.
      private def self.note_request_macro_result(cmd : String, tally : RequestMacro::Tally?) : Nil
        return unless t = tally
        STDERR.puts "#{cmd}: macro: #{t.summary}"
      end

      # Hand the run's macro the writable handle this command holds for the run, so its steps are
      # recorded (History, source `macro`) and its failures logged. No-op without a macro.
      private def self.attach_request_macro_store(lane : RequestMacro::Lane?, store : Store?) : Nil
        return unless lane && store
        lane.source.as?(RequestMacro::Runner).try(&.record_to(store))
      end
    end
  end
end
