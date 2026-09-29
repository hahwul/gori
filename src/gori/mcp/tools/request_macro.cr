require "json"
require "../../request_macro"

module Gori
  module MCP
    class Tools
      # --- request-time macros (#1350), shared by fuzz_start and mine_start ------------------
      #
      # This surface only parses ITS input format into a `RequestMacro::Spec`; the cadence, the
      # epochs, the failure policy and every gate the steps pass are `Gori::RequestMacro`, wired
      # by the plan builders, so `gori run` and the TUI cannot come to disagree about them.

      # `macro_steps` / `macro_every` / `macro_expect` / `macro_on_failure` → the spec, or nil when
      # the call asked for no macro.
      #
      # Blank is ABSENT here, on purpose: a schema-filling client sends `""` for every declared
      # property (see `Fuzz::Sender#sni`), so a blank `macro_every` beside no steps must not read
      # as a companion with nothing to modify. A NON-blank companion without steps is the knob
      # that silently did nothing, and is refused.
      private def request_macro_spec(h) : RequestMacro::Spec?
        steps = str_list(h, "macro_steps").flat_map { |s| RequestMacro::Spec.parse_steps(s) }
        every = str(h, "macro_every").try(&.strip.presence)
        policy = str(h, "macro_on_failure").try(&.strip.presence)
        expect = str_list(h, "macro_expect").flat_map(&.split(',')).map(&.strip).reject(&.empty?)
        if steps.empty?
          stray = [] of String
          stray << "macro_every" if every
          stray << "macro_on_failure" if policy
          stray << "macro_expect" unless expect.empty?
          unless stray.empty?
            raise RequestMacro::Error.new("#{stray.join(", ")} modif#{stray.size == 1 ? "ies" : "y"} macro_steps, and none was given")
          end
          return nil
        end
        cadence = if raw = every
                    RequestMacro::Cadence.parse?(raw) ||
                      raise RequestMacro::Error.new("invalid macro_every #{raw.inspect} (use \"request\", \"off\", or a number of requests)")
                  else
                    RequestMacro::Cadence.request
                  end
        on_failure = if raw = policy
                       RequestMacro::OnFailure.parse?(raw) ||
                         raise RequestMacro::Error.new("invalid macro_on_failure #{raw.inspect} (use \"skip\" or \"stop\")")
                     else
                       RequestMacro::OnFailure::Skip
                     end
        RequestMacro::Spec.new(steps, cadence, on_failure, expect)
      end

      # The four schema properties, for both tools. `noun` is what one macro run precedes: a
      # fuzz `candidate`, a mine `request`.
      private def request_macro_props(s, noun : String, *, race : Bool = false) : Nil
        s.field "macro_steps", JSON.parse(%({"type":"array","description":#{request_macro_steps_doc(noun).to_json},) +
                                          %("items":{"oneOf":[{"type":"string"},{"type":"integer"}]}}))
        s.field "macro_every", JSON.parse(%({"description":#{request_macro_every_doc(noun, race).to_json},) +
                                          %("oneOf":[{"type":"string"},{"type":"integer"}]}))
        s.field "macro_expect", strarrprop("Binding names the macro MUST rebind on every run (e.g. [\"CSRF\"]). Default: any binding the send context can see — name the one that matters and an extract rule that missed cannot pass as a fresh value. Refused when no enabled extract rule of that name applies to the active session slot.")
        s.field "macro_on_failure", enumprop("What a #{noun} does when the macro fails: skip (default — the #{noun} is NOT sent, its row is an error row prefixed \"macro:\", and the run ends after #{RequestMacro::Lane::FAILURE_LIMIT} failures in a row) | stop (the run ends on the first failure). There is no \"send it anyway with the last value\": that #{noun}'s verdict would be about a stale token.", %w[skip stop])
      end

      private def request_macro_steps_doc(noun : String) : String
        "Request-time macro (#1350) for a rotating CSRF token or nonce: saved Repeater sessions (ids from get_repeater_context, or a " \
        "tab's name; integers accepted) replayed IN ORDER before each #{noun}, so the value their extract rules leave in the " \
        "session bindings is fresh when the #{noun} resolves its $BIND.NAME (bare syntax: $NAME). The request must name the " \
        "binding — in a `template` (a captured `flow_id` template is sent exactly as captured and substitutes nothing) or in a " \
        "header of the active session slot — or the run is refused. The steps are sent as the active session slot, are recorded " \
        "in History with source `macro`, go through the same scope and Sandbox gates as everything else, and are charged to " \
        "max_requests and held to rate. The reply's request_macro says what it does to the run: a per-request macro runs the " \
        "sweep one #{noun} at a time, because a one-time value cannot be shared."
      end

      private def request_macro_every_doc(noun : String, race : Bool) : String
        doc = "How often the macro runs, counted in #{noun}s: \"request\" (default — before every #{noun}, never shared), a number N " \
              "(one value shared by N #{noun}s, up to N running at once; the next value is fetched after all N finish), or \"off\" " \
              "(keep the steps configured but run nothing)."
        return doc unless race
        doc + " With a race_count run, the number must be at least the group size: the " \
              "steps then run once before the group and every member carries that one value."
      end

      # The plan-time description of the stage, for the start reply — present only for a run
      # that has a macro, so every other start reply is byte-identical to what it was.
      private def emit_request_macro_plan(j : JSON::Builder, info : RequestMacro::Info?) : Nil
        return unless info
        j.field "request_macro" do
          j.object do
            j.field "steps" do
              j.array { info.steps.each { |step| j.string(Serialize.text(step)) } }
            end
            j.field "cadence", info.cadence.token
            j.field "on_failure", info.on_failure.token
            j.field "sharing", info.sharing
            j.field "effective_concurrency", info.concurrency
            j.field "summary", Serialize.text(info.line)
          end
        end
      end

      # What the macro has done so far. Counts and the first failure's sentence — never a value.
      private def emit_request_macro_status(j : JSON::Builder, lane : RequestMacro::Lane?) : Nil
        return unless lane
        t = lane.tally
        j.field "request_macro" do
          j.object do
            j.field "runs", t.runs
            j.field "failed", t.failed
            j.field "candidates_not_sent", t.skipped
            j.field "requests", t.requests
            j.field "first_error", Serialize.text(t.first_error)
            j.field "ended_run", lane.aborted?
            j.field "summary", Serialize.text(t.summary)
          end
        end
      end
    end
  end
end
