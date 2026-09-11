require "json"
require "./store"
require "./entity"
require "./env"
require "./evidence"
require "./proxy/codec/http1"
require "./repeater/flow_request"

module Gori
  # Issue-linked retest (#1036): the smallest thing that turns a confirmed finding into a
  # REPRODUCIBLE check — an ordered list of Repeater sends, each with a role and at most one
  # assertion, plus a bounded record of what happened the last few times it ran.
  #
  # Entity links (`links.cr`) say what material is RELATED to an issue; frozen evidence
  # (`evidence.cr`) keeps the bytes that proved it. Neither can be RUN. The prose in an
  # issue's notes — "send #4 first to log in, then #5 should answer 403, and #6 is the
  # control" — is the thing a retest replaces, and prose is exactly what is lost when the
  # person who wrote it is not the person verifying the fix.
  #
  # Everything here is surface-independent and pure except `Engine`, which is handed a
  # `Backend`: the live one dials through `Repeater::Plan` under the project's scope gate,
  # a spec's returns canned observations. The three surfaces (TUI card, `gori run retest`,
  # MCP `run_retest`) share this module and differ only in how they ask and how they print.
  module Retest
    # How many runs one issue keeps. "Persist a BOUNDED run summary" — a retest is meant to
    # be run again after every candidate fix, so without a ceiling the table grows with the
    # engagement. The newest ones are the ones a regression check reads.
    RUN_HISTORY = 20

    # Ceiling on the `detail` sentence stored per result row. The sentence quotes response
    # material (a JSON value, an error string), and a row that is a report must not become a
    # second body store.
    DETAIL_MAX = 512

    # Response bytes an assertion may compare. `body:same` / `body:diff` hash rather than
    # keep the bodies, but the comparison still has to read them; beyond this the engine
    # compares the first `BODY_COMPARE_MAX` bytes and says so.
    BODY_COMPARE_MAX = 8 * 1024 * 1024

    # The three persisted vocabularies, defined in `Store` beside `LinkRefKind` (the store is
    # what reads them off disk) and aliased here so the source has ONE spelling too.
    #
    # `Baseline` is singular per run in the sense that matters: the LAST baseline step to
    # have produced a response is what `body:same`/`body:diff` compare against. A second one
    # re-anchors from there on, which is the only reading that makes "baseline, variant,
    # baseline, variant" (the shape a before/after check has) mean anything.
    alias Role = Store::RetestRole
    alias Outcome = Store::RetestOutcome
    alias Verdict = Store::RetestVerdict

    # --- assertions ----------------------------------------------------------

    # The one expected result a step carries, or `None`.
    #
    # ONE per step, deliberately. The issue's result table has a single "expected result"
    # column and the TUI card a single field; a list would need a grammar with precedence
    # and an AND/OR question this MVP has no answer for. Two expectations about one send are
    # spelled as they read — two steps is wrong (it sends twice), so the honest answer today
    # is "pick the one that decides it", and a richer grammar is the deferred "scriptable
    # assertions" idea.
    #
    # The stored spelling is the TYPED spelling: `Assertion.parse(text).to_s == text` for
    # everything this accepts, so the store, the CLI flag, the MCP field and the TUI card all
    # hold one string and no surface has to translate.
    struct Assertion
      enum Kind
        None
        Status      # an exact code, a class (`2xx`), or an inclusive range
        JsonPresent # the path resolves to a value (`null` counts — the field is there)
        JsonAbsent
        JsonEquals
        BodySame # byte-identical to the baseline's decoded body
        BodyDiff
      end

      getter kind : Kind
      getter path : String  # JSON dotted path, for the three Json* kinds
      getter value : String # the literal, for JsonEquals
      getter lo : Int32     # inclusive status bounds, for Status
      getter hi : Int32
      # The Status spelling as typed (`200`, `2xx`, `200-299`), so `to_s` round-trips rather
      # than re-deriving `2xx` as `200-299` and quietly rewriting the operator's text.
      getter status_text : String

      def initialize(@kind : Kind, @path = "", @value = "", @lo = 0, @hi = 0, @status_text = "")
      end

      def self.none : Assertion
        new(Kind::None)
      end

      def none? : Bool
        @kind.none?
      end

      # The accepted forms, for a help string / a schema enum. Kept beside `parse` so the two
      # cannot drift.
      FORMS = [
        "status:<code>            e.g. status:200",
        "status:<class>           e.g. status:2xx",
        "status:<lo>-<hi>         e.g. status:200-299",
        "json:<path>              the JSON field is present, e.g. json:data.user.id",
        "json:<path>=<literal>    the JSON field equals a literal, e.g. json:data.role=admin",
        "json-absent:<path>       the JSON field is absent, e.g. json-absent:data.token",
        "body:same                the decoded body is identical to the baseline's",
        "body:diff                the decoded body differs from the baseline's",
      ]

      # Parse the stored/typed spelling. Returns the sentence saying why on a bad one — a
      # String, not a raise, for the reason `Evidence.snapshot_for` gives: every caller is a
      # surface that has to print it, and none of them is an error in the program.
      def self.parse(text : String) : Assertion | String
        s = text.strip
        return none if s.empty?
        if rest = chop(s, "status:")
          return parse_status(rest)
        end
        if rest = chop(s, "json-absent:")
          return rest.empty? ? "json-absent: needs a field path (json-absent:data.token)" : new(Kind::JsonAbsent, path: rest)
        end
        if rest = chop(s, "json:")
          # `=` splits the PATH from the literal, and the FIRST one wins: a path segment
          # cannot contain `=` while a literal very much can (`json:data.next=?page=2`).
          if at = rest.index('=')
            path = rest[0...at]
            return "json: needs a field path before the = (json:data.role=admin)" if path.empty?
            return new(Kind::JsonEquals, path: path, value: rest[(at + 1)..])
          end
          return rest.empty? ? "json: needs a field path (json:data.user.id)" : new(Kind::JsonPresent, path: rest)
        end
        if rest = chop(s, "body:")
          case rest.downcase
          when "same"                         then return new(Kind::BodySame)
          when "diff", "different", "differs" then return new(Kind::BodyDiff)
          else                                     return "unknown body assertion #{rest.inspect} (body:same | body:diff)"
          end
        end
        "unknown assertion #{s.inspect} — expected one of:\n  #{FORMS.join("\n  ")}"
      end

      private def self.chop(s : String, prefix : String) : String?
        return nil unless s.size >= prefix.size && s[0, prefix.size].compare(prefix, case_insensitive: true) == 0
        s[prefix.size..]
      end

      # The three spellings, tried in the order that cannot mistake one for another: a class
      # (`2xx`) first because it is the only one that is not all digits, then a range, then a
      # bare code. Each arm is its own method so the refusal a spelling earns is written next
      # to the parse that earned it.
      private def self.parse_status(rest : String) : Assertion | String
        v = rest.strip
        return "status: needs a code, a class or a range (status:200, status:2xx, status:200-299)" if v.empty?
        return parse_status_class(v) if status_class?(v)
        # A range, but only when the dash SEPARATES two numbers — `-1` is a bad code, not a
        # range with an empty low end.
        dash = v.index('-', 1)
        return parse_status_range(v, dash) if dash && dash < v.size - 1
        parse_status_code(v)
      end

      private def self.status_class?(v : String) : Bool
        v.size == 3 && (v.ends_with?("xx") || v.ends_with?("XX")) && !v[0].to_i?.nil?
      end

      private def self.parse_status_class(v : String) : Assertion | String
        h = v[0].to_i?
        return "status class must be 1xx-5xx, got #{v.inspect}" unless h && 1 <= h <= 5
        new(Kind::Status, lo: h * 100, hi: h * 100 + 99, status_text: v.downcase)
      end

      private def self.parse_status_range(v : String, dash : Int32) : Assertion | String
        lo = v[0...dash].to_i?
        hi = v[(dash + 1)..].to_i?
        return "status range must be two numbers (status:200-299), got #{v.inspect}" unless lo && hi
        return "status range #{lo}-#{hi} is inverted — write the low code first" if lo > hi
        return "status codes must be 100-599, got #{v.inspect}" unless valid_code?(lo) && valid_code?(hi)
        new(Kind::Status, lo: lo, hi: hi, status_text: "#{lo}-#{hi}")
      end

      private def self.parse_status_code(v : String) : Assertion | String
        code = v.to_i?
        return "status must be a number, a class or a range (status:200, status:2xx, status:200-299), got #{v.inspect}" unless code
        return "status codes must be 100-599, got #{code}" unless valid_code?(code)
        new(Kind::Status, lo: code, hi: code, status_text: code.to_s)
      end

      private def self.valid_code?(c : Int32) : Bool
        100 <= c <= 599
      end

      # Round-trips `parse`. This is what the store holds and what every surface prints in
      # the "expected" column.
      def to_s(io : IO) : Nil
        case @kind
        in .none?         then io << ""
        in .status?       then io << "status:" << @status_text
        in .json_present? then io << "json:" << @path
        in .json_absent?  then io << "json-absent:" << @path
        in .json_equals?  then io << "json:" << @path << "=" << @value
        in .body_same?    then io << "body:same"
        in .body_diff?    then io << "body:diff"
        end
      end

      # The human phrasing for a result table's "expected" column.
      def describe : String
        case @kind
        in .none?         then "—"
        in .status?       then @lo == @hi ? "status #{@lo}" : "status #{@status_text}"
        in .json_present? then "#{@path} present"
        in .json_absent?  then "#{@path} absent"
        in .json_equals?  then "#{@path} = #{@value}"
        in .body_same?    then "body same as baseline"
        in .body_diff?    then "body differs from baseline"
        end
      end
    end

    # --- steps and observations ----------------------------------------------

    # What the engine was handed for one step, resolved against the project AT PLAN TIME.
    #
    # `missing` is the reason this step cannot run — its Repeater session was deleted, its
    # request has no method. A plan reports it rather than dropping the step, because a
    # retest whose third step vanished must not silently become a two-step retest that
    # passes.
    record Planned,
      step : Store::RetestStep,
      method : String,
      url : String,
      label : String,
      missing : String? = nil do
      def runnable? : Bool
        @missing.nil?
      end

      # A method whose replay can change state on the target. The same three-verb safe set
      # `Authorize::Passive` replays without `--unsafe-methods`; everything else — including
      # a method gori has never seen — counts, because the confirm exists to be conservative.
      def state_changing? : Bool
        !SAFE_METHODS.includes?(@method.upcase)
      end

      def role : Role
        @step.role
      end

      # The step's parsed assertion. An unreadable one answers `None` HERE, but the step is
      # never RUN with it: `plan_step` refuses such a step outright (`missing`), so this
      # fallback is only ever reached by a surface asking a plan row to describe itself.
      # Without that refusal the fallback would be the whole defect — a step whose assertion
      # a newer gori wrote would quietly assert nothing and PASS, which is the absence of a
      # finding reading as a clean one.
      def assertion : Assertion
        parsed = Assertion.parse(@step.assertion)
        parsed.is_a?(String) ? Assertion.none : parsed
      end
    end

    SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}

    # One send's outcome as the engine sees it — the facts an assertion reads plus the ones a
    # result row reports. Built by a `Backend`, never by an assertion.
    record Observation,
      status : Int32? = nil,
      body : Bytes? = nil, # the DECODED entity (see `Entity.bytes`), not the wire body
      error : String? = nil,
      blocked_reason : String? = nil,
      duration_us : Int64? = nil,
      bytes : Int64 = 0_i64,
      flow_id : Int64? = nil,
      # A fact about HOW the send was made that the assertion cannot see and the row must
      # still say — a WebSocket handshake sent as plain HTTP, a History row that could not
      # be written. Appended to whatever detail the judgement produced, never replacing it.
      note : String? = nil do
      def blocked? : Bool
        !@blocked_reason.nil?
      end

      # Did the origin answer at all? An errored send with a status (a partial read) still
      # answered, and an assertion about the status can be decided on it.
      def answered? : Bool
        !@status.nil?
      end
    end

    # One row of the result table. `label`/`method`/`url` are copied from the plan rather
    # than resolved later: a run summary is read WEEKS after the fact, by which time the
    # Repeater tab may have been renamed, edited or closed, and a row that re-resolves would
    # describe a request that never ran. Same argument `Evidence` makes for its provenance.
    record StepResult,
      planned : Planned,
      outcome : Outcome,
      detail : String,
      observation : Observation do
      def step : Store::RetestStep
        @planned.step
      end

      def pass? : Bool
        @outcome.pass?
      end
    end

    # Where a run's sends come from. The live one dials; a spec's answers from a table.
    abstract class Backend
      abstract def send(p : Planned) : Observation

      # Called once after the last send. The live backend closes its `Outbound` here.
      def finish : Nil
      end
    end

    # --- planning ------------------------------------------------------------

    # Resolve an issue's steps against the project as it is NOW: what each one will send, and
    # which of them cannot run. Pure apart from the store reads, so every surface's preflight
    # (the request count, the state-changing tally, the "session gone" refusal) is this one
    # function and cannot disagree with what the engine then does.
    def self.plan(store : Store, steps : Array(Store::RetestStep)) : Array(Planned)
      steps.map { |s| plan_step(store, s) }
    end

    def self.plan(store : Store, issue_id : Int64) : Array(Planned)
      plan(store, store.retest_steps(issue_id))
    end

    private def self.plan_step(store : Store, step : Store::RetestStep) : Planned
      unless step.ref_kind.repeater?
        return Planned.new(step, "?", "?", step.ref_label,
          missing: "only a Repeater session can be a retest step (#{step.ref_kind.label} has no single request to replay)")
      end
      rec = store.get_repeater(step.ref_id)
      unless rec
        return Planned.new(step, "?", "?", step.ref_label,
          missing: "repeater ##{step.ref_id} no longer exists — re-link the session or remove the step")
      end
      boundary = Env.head_body_boundary(rec.request)
      method, target, _ = Proxy::Codec::Http1.authored_start_line(rec.request[0, boundary])
      url = Evidence.repeater_url(rec.target, target)
      label = (rec.name.presence || first_line(String.new(rec.request).scrub) || "repeater ##{rec.id}").scrub
      if method.empty?
        return Planned.new(step, "?", url, label,
          missing: "repeater ##{step.ref_id} has no request line to send")
      end
      # An assertion THIS BUILD cannot read is a refusal, not a step with no assertion. The
      # only way one gets on disk is a newer gori having written it, and the two readings are
      # opposite: "assert nothing" passes, "I cannot read what to assert" must not. Same rule
      # `try_read_retest_step` follows for a role it cannot name — skip the row rather than
      # guess at it.
      parsed = Assertion.parse(step.assertion)
      if parsed.is_a?(String)
        return Planned.new(step, method, url, label,
          missing: "this gori cannot read the step's expected result (#{parsed.lines.first.strip})")
      end
      Planned.new(step, method, url, label)
    end

    private def self.first_line(s : String) : String?
      s.each_line do |raw|
        line = raw.rstrip('\r').strip
        return line unless line.empty?
      end
      nil
    end

    # The state-changing sends in a plan — what the confirm counts. Only RUNNABLE steps: a
    # step whose session is gone will not be sent, so counting it would inflate the number
    # the operator is asked to approve.
    def self.state_changing(planned : Array(Planned)) : Array(Planned)
      planned.select { |p| p.runnable? && p.state_changing? }
    end

    # `POST, DELETE` — the distinct state-changing methods, in plan order, for the confirm's
    # sentence.
    def self.unsafe_methods(planned : Array(Planned)) : Array(String)
      state_changing(planned).map(&.method.upcase).uniq!
    end

    # The sentence every surface's confirm shows: the EXACT request count, and which of them
    # change state. nil when nothing in the plan changes state — there is nothing to warn
    # about, and a confirm that always fires trains the operator to answer without reading.
    def self.confirm_note(planned : Array(Planned)) : String?
      unsafe = state_changing(planned)
      return nil if unsafe.empty?
      runnable = planned.count(&.runnable?)
      methods = unsafe.map(&.method.upcase).uniq!.join(", ")
      "#{runnable} request#{runnable == 1 ? "" : "s"} will be sent, #{unsafe.size} of them " \
      "state-changing (#{methods}). Each one re-runs its side effect on the target."
    end

    # --- the engine ----------------------------------------------------------

    # Runs a plan in `position` order and judges each step. Nothing here dials, stores or
    # prints: the `Backend` sends and the caller persists, so this is the one piece all three
    # surfaces share and the one a spec can drive end-to-end without a socket.
    class Engine
      def initialize(@backend : Backend)
      end

      # Execute `planned` in order.
      #
      # `allow_cleanup` is the issue's safety rule made explicit: once gori has REFUSED to
      # send — the scope gate, Sandbox mode, an exclude rule — it does not keep sending on
      # its own initiative, and that includes the cleanup steps, whose whole job is to send
      # more. The operator can say otherwise, per run, and the skipped rows say what was not
      # run and why.
      #
      # A `Setup` step that fails or errors halts the MEASUREMENT steps for a different
      # reason — its precondition is what everything after it measures against — but cleanup
      # still runs there: gori refused nothing, and a half-created fixture is exactly what
      # cleanup exists to undo.
      #
      # `stop` is polled before each send, so an operator's stop lands between steps rather
      # than only at the end (the argument `Authorize::Engine#run` makes for polling between
      # identities). A stopped run's remaining steps are `Skipped`, never absent: a summary
      # built from the rows that happen to be there would read as a complete pass.
      # `on_step` is fired for each row AS IT IS DECIDED, on this fiber. It exists for the
      # TUI, whose card fills in while the run proceeds — a retest is several seconds of
      # sends and a card that shows nothing until the last one has finished cannot say which
      # step is slow, or that anything is happening at all. Headless callers pass nil and
      # read the returned array.
      def run(planned : Array(Planned), *, allow_cleanup : Bool = false,
              stop : Proc(Bool)? = nil, on_step : Proc(StepResult, Nil)? = nil) : Array(StepResult)
        results = [] of StepResult
        baseline = nil.as(Observation?)
        # Why the last baseline step cannot anchor, when it cannot. Carried so a comparison
        # demoted because of it can say WHICH fact demoted it — "no baseline has run" and
        # "the baseline answered 403 when it expected 200" send the operator to opposite ends.
        baseline_note = nil.as(String?)
        refused = false # gori refused a send — cleanup is gated on `allow_cleanup`
        halted = nil.as(String?)
        begin
          planned.each do |p|
            if reason = p.missing
              # CLIPPED like every other detail. This is the one that is not the engine's own
              # sentence: `plan_step`'s unreadable-assertion refusal quotes the raw `assertion`
              # column through `inspect`, so a long or non-UTF-8 value written by a newer gori
              # would land unbounded and unscrubbed in `issue_retest_run_steps.detail` — the
              # row `DETAIL_MAX` exists to stop becoming a second body store.
              results << emit(on_step, StepResult.new(p, Outcome::Skipped, Retest.clip(reason), Observation.new))
              next
            end
            if stop.try(&.call)
              results << emit(on_step, StepResult.new(p, Outcome::Skipped, "stopped before this step ran", Observation.new))
              next
            end
            if why = skip_reason(p, halted, refused, allow_cleanup)
              results << emit(on_step, StepResult.new(p, Outcome::Skipped, why, Observation.new))
              next
            end
            obs = @backend.send(p)
            outcome, detail = judge(p, obs, baseline, baseline_note)
            # The backend's note rides ALONGSIDE the judgement rather than in place of it:
            # "status 200" and "the handshake was sent as HTTP" are both true, and dropping
            # either one is how a row stops describing the send it reports.
            obs.note.try { |n| detail = Retest.clip("#{detail} · #{n}") }
            # The anchor is the last baseline step that PASSED — not merely the last one
            # attempted, and not merely one that answered.
            #
            # Both halves are load-bearing, and the second is the one that is easy to miss. A
            # baseline whose send errored has no body, so comparing against it reports every
            # variant as "differs from baseline" on the strength of a request that got nothing
            # back. And a baseline that ANSWERED but missed its own expected result
            # established nothing: a `body:same` variant compared against the 403 error page a
            # `status:200` baseline was handed would PASS — "the body is unchanged" about two
            # error pages, neither of which is the resource under test. That is the demotion
            # `Authorize` makes for a denied baseline (#906/#913), arriving one tool over: a
            # baseline that anchors nothing must not let a comparison claim a verdict.
            #
            # A baseline with NO assertion passes vacuously and anchors, which is the ordinary
            # "just take a reading here" case and exactly right.
            if p.role.baseline?
              if outcome.pass?
                baseline = obs
                baseline_note = nil
              else
                baseline = nil
                baseline_note = if obs.answered?
                                  "the baseline step did not meet its own expected result (#{detail})"
                                else
                                  "the baseline step got no response (#{detail})"
                                end
              end
            end
            results << emit(on_step, StepResult.new(p, outcome, detail, obs))
            if outcome.blocked?
              refused = true
              halted ||= "not sent — gori refused an earlier send (#{obs.blocked_reason || "out of scope"})"
            elsif p.role.precondition? && (outcome.fail? || outcome.error?)
              halted ||= "not sent — the setup step did not succeed"
            end
          end
        ensure
          @backend.finish
        end
        results
      end

      # Hand one finished row to the progress hook and return it, so every `results <<` site
      # reports exactly the row it appends — a second, hand-written call beside each one is
      # how a skipped row silently stops appearing in the TUI.
      private def emit(on_step : Proc(StepResult, Nil)?, r : StepResult) : StepResult
        on_step.try(&.call(r))
        r
      end

      # Why this step is not being sent, or nil to send it.
      private def skip_reason(p : Planned, halted : String?, refused : Bool,
                              allow_cleanup : Bool) : String?
        return nil unless halted
        unless p.role.cleanup?
          return halted
        end
        # A cleanup step after a refusal: the one case the operator has to opt into.
        return nil unless refused
        return nil if allow_cleanup
        "cleanup not run after a refused send — re-run with cleanup allowed to send it"
      end

      # Decide one step. Split from `run` so the whole assertion surface is testable against
      # hand-built observations.
      private def judge(p : Planned, obs : Observation, baseline : Observation?,
                        baseline_note : String? = nil) : {Outcome, String}
        if reason = obs.blocked_reason
          return {Outcome::Blocked, Retest.clip("refused before the send: #{reason}")}
        end
        assertion = p.assertion
        # An ERRORED send with no status answered nothing, so no assertion about it can be
        # decided — including `body:diff`, which would otherwise read a failed connection as
        # proof that the response changed.
        if !obs.answered?
          err = obs.error || "no response"
          return {Outcome::Error, Retest.clip(err)}
        end
        return {Outcome::Pass, Retest.actual(obs)} if assertion.none?
        Retest.evaluate(assertion, obs, baseline, baseline_note)
      end
    end

    # --- assertion evaluation ------------------------------------------------

    # Decide one assertion against one observation. Pure and public: the TUI's preview, the
    # engine and the specs all read the same judgement.
    # `baseline_note` sharpens the one refusal a comparison can earn from the PLAN rather
    # than from the response: why the baseline it would have compared against cannot anchor.
    def self.evaluate(a : Assertion, obs : Observation, baseline : Observation?,
                      baseline_note : String? = nil) : {Outcome, String}
      case a.kind
      in .none?                                       then {Outcome::Pass, actual(obs)}
      in .status?                                     then evaluate_status(a, obs)
      in .json_present?, .json_absent?, .json_equals? then evaluate_json(a, obs)
      in .body_same?, .body_diff?                     then evaluate_body(a, obs, baseline, baseline_note)
      end
    end

    private def self.evaluate_status(a : Assertion, obs : Observation) : {Outcome, String}
      status = obs.status
      return {Outcome::Inconclusive, "no status — #{obs.error || "the origin answered nothing"}"} unless status
      if a.lo <= status <= a.hi
        {Outcome::Pass, actual(obs)}
      else
        {Outcome::Fail, "status #{status}, expected #{a.lo == a.hi ? a.lo.to_s : a.status_text}"}
      end
    end

    private def self.evaluate_json(a : Assertion, obs : Observation) : {Outcome, String}
      body = obs.body
      return {Outcome::Inconclusive, "no response body to read #{a.path} from"} if body.nil? || body.empty?
      doc = begin
        JSON.parse(String.new(body).scrub)
      rescue ex : JSON::ParseException
        # INCONCLUSIVE, not fail. "The field is absent" and "this is not JSON" are different
        # findings, and an HTML error page answering a `json-absent:` assertion as PASS is
        # the exact false clean bill of health this outcome exists to keep apart.
        return {Outcome::Inconclusive, clip("response body is not JSON (#{ex.message || "parse error"})")}
      end
      found = json_at(doc, a.path)
      case a.kind
      when .json_present?
        found ? {Outcome::Pass, "#{a.path} = #{render(found)}"} : {Outcome::Fail, "#{a.path} is absent"}
      when .json_absent?
        found ? {Outcome::Fail, clip("#{a.path} is present (#{render(found)})")} : {Outcome::Pass, "#{a.path} is absent"}
      else
        return {Outcome::Fail, "#{a.path} is absent, expected #{a.value}"} unless found
        if json_equals?(found, a.value)
          {Outcome::Pass, clip("#{a.path} = #{render(found)}")}
        else
          {Outcome::Fail, clip("#{a.path} = #{render(found)}, expected #{a.value}")}
        end
      end
    end

    private def self.evaluate_body(a : Assertion, obs : Observation, baseline : Observation?,
                                   baseline_note : String? = nil) : {Outcome, String}
      # A comparison with nothing to compare against is INCONCLUSIVE and says so. Calling it
      # a pass would report "the body is unchanged" about a check that never looked, and
      # calling it a failure would blame the target for the plan's own shape. This is the
      # same demotion `Authorize` makes for a denied baseline: a baseline that anchors
      # nothing must not let a comparison claim a verdict.
      unless baseline
        return {Outcome::Inconclusive, clip(baseline_note ||
                                            "no baseline response to compare against — put a step with role `baseline` before this one")}
      end
      mine = obs.body || Bytes.empty
      theirs = baseline.body || Bytes.empty
      capped = mine.size > BODY_COMPARE_MAX || theirs.size > BODY_COMPARE_MAX
      same = compare_bodies(mine, theirs)
      note = capped ? " (first #{BODY_COMPARE_MAX} bytes)" : ""
      if a.kind.body_same?
        same ? {Outcome::Pass, "body identical to baseline, #{mine.size} bytes#{note}"} : {Outcome::Fail, "body differs from baseline (#{mine.size} vs #{theirs.size} bytes)#{note}"}
      else
        same ? {Outcome::Fail, "body identical to baseline, #{mine.size} bytes#{note}"} : {Outcome::Pass, "body differs from baseline (#{mine.size} vs #{theirs.size} bytes)#{note}"}
      end
    end

    private def self.compare_bodies(a : Bytes, b : Bytes) : Bool
      return a == b if a.size <= BODY_COMPARE_MAX && b.size <= BODY_COMPARE_MAX
      a[0, {a.size, BODY_COMPARE_MAX}.min] == b[0, {b.size, BODY_COMPARE_MAX}.min]
    end

    # Walk a dotted path. A numeric segment indexes an ARRAY; on an object it is tried as a
    # key first, because a JSON object may legitimately be keyed `"0"` and the key is the
    # more specific reading.
    #
    # Returns nil for "no such field". A field whose value is JSON `null` returns the
    # `JSON::Any` holding nil, which `json_at` cannot express — so presence is answered by
    # the caller through the nilable RETURN, and a present-but-null field reads as PRESENT.
    # That is the right reading: `{"error": null}` has the field.
    def self.json_at(doc : JSON::Any, path : String) : JSON::Any?
      node = doc
      path.split('.').each do |seg|
        next if seg.empty?
        if h = node.as_h?
          child = h[seg]?
          return nil unless child
          node = child
        elsif arr = node.as_a?
          idx = seg.to_i?
          return nil unless idx
          idx += arr.size if idx < 0
          return nil unless 0 <= idx < arr.size
          node = arr[idx]
        else
          return nil
        end
      end
      node
    end

    # Compare a resolved JSON value against the typed literal.
    #
    # The literal is UNTYPED TEXT — it came off a command line, a JSON string field or a
    # one-line TUI form — so it is compared against the VALUE's own rendering rather than
    # re-parsed into a JSON type: `json:ok=true` matches the boolean, `json:v=null` the null,
    # a string matches its exact characters, and a number is matched numerically first (so
    # `1.0` equals `1` and `1e3` equals `1000`) and then textually.
    #
    # That means `json:n=3` matches the number 3 AND the string "3", deliberately. Insisting
    # on the JSON type would make the common `json:data.count=3` fail against an API that
    # quotes its numbers — for a reason the operator cannot see from the assertion, on a
    # grammar whose whole point is that one short line says what to look at and what it
    # should be. A type-exact comparison is the deferred "scriptable assertions" idea.
    def self.json_equals?(node : JSON::Any, literal : String) : Bool
      if s = node.as_s?
        return s == literal
      end
      # `!(…).nil?`, NOT `if b = node.as_bool?`: an assignment-condition is falsey when the
      # value IS `false`, so a boolean `false` fell straight past this arm to the exact
      # `to_json` compare at the bottom. `json:admin=true` then matched case-insensitively
      # while `json:admin=False` reported a FAILURE against a response that genuinely carries
      # `"admin": false` — a retest claiming a regression that is not there.
      unless (b = node.as_bool?).nil?
        return literal.downcase == b.to_s
      end
      return literal.downcase == "null" if node.raw.nil?
      if i = node.as_i64?
        return true if literal.to_i64? == i
        return true if (f = literal.to_f64?) && f == i.to_f64
        return literal == i.to_s
      end
      if f = node.as_f?
        return true if (lit = literal.to_f64?) && lit == f
        return literal == f.to_s
      end
      # An object or an array: compare the compact JSON text, which is the only literal an
      # operator could have typed for one.
      node.to_json == literal
    end

    # A JSON value as the result row quotes it — the compact JSON text, so a string keeps its
    # quotes and cannot be confused with a number that happens to print the same.
    def self.render(node : JSON::Any) : String
      node.to_json.scrub
    end

    # The "actual result" sentence for a step whose assertion passed, or which had none.
    def self.actual(obs : Observation) : String
      parts = [] of String
      parts << (obs.status.try(&.to_s) || "no status")
      obs.duration_us.try { |d| parts << "#{(d / 1000.0).round(1)}ms" }
      parts << "#{obs.bytes} bytes" if obs.bytes > 0
      obs.error.try { |e| parts << "error: #{e}" }
      clip(parts.join(" · "))
    end

    def self.clip(s : String) : String
      t = s.scrub.gsub(/[\r\n\t]+/, " ").strip
      t.size > DETAIL_MAX ? "#{t[0, DETAIL_MAX - 1]}…" : t
    end

    # --- one complete run ----------------------------------------------------

    # Everything one run produced: the rows, the fold, and where it was persisted.
    #
    # `stored` is the store's own answer, not a bool, because the three ways a summary fails
    # to be written are acted on differently — an issue deleted mid-run, a busy store, and
    # "we were asked not to persist" are not one fact. A run whose summary did not land STILL
    # ran and still has its rows, and every surface prints them either way; the difference is
    # only whether a later regression check can find it.
    record RunReport,
      run_id : Int64,
      verdict : Verdict,
      tally : Tally,
      results : Array(StepResult),
      started_at : Int64,
      finished_at : Int64,
      stored : Store::RetestStatus

    # Plan → send → judge → persist, in one place, so `gori run retest run`, MCP `run_retest`
    # and the TUI card cannot disagree about what a run IS. Each surface still owns its own
    # confirm, its own output and (for the TUI) its own fiber.
    # `surface` is the ENUM, not its token: the run row stores the token and the History rows
    # the backend writes store the enum, and two arguments for one fact is how a run comes to
    # claim it was `cli` while its flows say `mcp`.
    def self.execute(store : Store, planned : Array(Planned), backend : Backend, *,
                     issue_id : Int64, surface : FlowSource::Surface? = nil,
                     allow_cleanup : Bool = false, stop : Proc(Bool)? = nil,
                     persist : Bool = true, note : String? = nil,
                     on_step : Proc(StepResult, Nil)? = nil) : RunReport
      started_at = Time.utc.to_unix_ms * 1000_i64
      results = Engine.new(backend).run(planned, allow_cleanup: allow_cleanup, stop: stop,
        on_step: on_step)
      finished_at = Time.utc.to_unix_ms * 1000_i64
      counts = tally(results)
      fold = verdict(results)
      run_id = 0_i64
      stored = Store::RetestStatus::Ok
      if persist
        run_id, stored = store.record_retest_run(issue_id, started_at, finished_at, fold,
          counts, results, surface: surface.try(&.token), note: note)
      end
      RunReport.new(run_id, fold, counts, results, started_at, finished_at, stored)
    end

    # --- summarising ---------------------------------------------------------

    record Tally,
      total : Int32,
      passed : Int32,
      failed : Int32,
      inconclusive : Int32,
      errored : Int32,
      blocked : Int32,
      skipped : Int32

    def self.tally(results : Array(StepResult)) : Tally
      Tally.new(
        total: results.size,
        passed: results.count(&.outcome.pass?),
        failed: results.count(&.outcome.fail?),
        inconclusive: results.count(&.outcome.inconclusive?),
        errored: results.count(&.outcome.error?),
        blocked: results.count(&.outcome.blocked?),
        skipped: results.count(&.outcome.skipped?))
    end

    # Fold a run into one word.
    #
    # `Blocked` outranks `Fail`: a run gori refused to complete is a fact about the scope
    # configuration, and reporting it as a failed retest would send the operator to look at
    # the target for a problem that is on this side. Then `Fail`, then anything undecided —
    # `Pass` requires that every step actually ran and nothing was left undecided, because
    # this is the word a regression check exits on.
    def self.verdict(results : Array(StepResult)) : Verdict
      return Verdict::Inconclusive if results.empty?
      return Verdict::Blocked if results.any?(&.outcome.blocked?)
      return Verdict::Fail if results.any?(&.outcome.fail?)
      return Verdict::Inconclusive if results.any? { |r| r.outcome.inconclusive? || r.outcome.error? || r.outcome.skipped? }
      Verdict::Pass
    end

    # `2 passed · 1 failed · 1 skipped` — the one-line summary every surface prints.
    def self.summary_line(t : Tally) : String
      parts = [] of String
      parts << "#{t.passed} passed" if t.passed > 0
      parts << "#{t.failed} failed" if t.failed > 0
      parts << "#{t.inconclusive} inconclusive" if t.inconclusive > 0
      parts << "#{t.errored} errored" if t.errored > 0
      parts << "#{t.blocked} blocked" if t.blocked > 0
      parts << "#{t.skipped} skipped" if t.skipped > 0
      parts.empty? ? "no steps" : parts.join(" · ")
    end
  end
end
