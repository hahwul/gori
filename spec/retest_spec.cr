require "./spec_helper"

# Issue-linked retest (#1036). These examples pin the two halves the surfaces share and
# cannot re-derive: the assertion grammar (parse → judge → the sentence a result row shows)
# and the engine's ordering rules — what anchors a comparison, what halts a run, and what
# gori is allowed to send after it has refused to send something.

private alias RT = Gori::Retest

private def step(id : Int64, role : Gori::Store::RetestRole, assertion : String = "",
                 ref_id : Int64 = 1_i64, position : Int32 = id.to_i) : Gori::Store::RetestStep
  Gori::Store::RetestStep.new(id, 1_i64, position, role, Gori::Store::LinkRefKind::Repeater,
    ref_id, assertion, 0_i64, 0_i64)
end

private def planned(id : Int64, role : Gori::Store::RetestRole, assertion : String = "",
                    method : String = "GET", missing : String? = nil) : RT::Planned
  RT::Planned.new(step(id, role, assertion), method, "https://a.test/#{id}", "repeater ##{id}", missing)
end

private def obs(status : Int32? = 200, body : String? = nil, error : String? = nil,
                blocked : String? = nil) : RT::Observation
  RT::Observation.new(status: status, body: body.try(&.to_slice), error: error,
    blocked_reason: blocked, duration_us: 1_000_i64, bytes: (body.try(&.bytesize) || 0).to_i64)
end

# A backend that answers from a table keyed by step id, and records the order it was asked.
private class TableBackend < Gori::Retest::Backend
  getter sent = [] of Int64

  def initialize(@table : Hash(Int64, Gori::Retest::Observation))
    @finished = false
  end

  def send(p : Gori::Retest::Planned) : Gori::Retest::Observation
    @sent << p.step.id
    @table[p.step.id]? || Gori::Retest::Observation.new(status: 200)
  end

  def finish : Nil
    @finished = true
  end

  def finished? : Bool
    @finished
  end
end

describe Gori::Retest::Assertion do
  it "round-trips every accepted spelling, so the store and the surfaces hold one string" do
    # The contract `Assertion`'s own comment states: `parse(text).to_s == text`. Without it
    # a value typed in the CLI reads back differently in the TUI card, and the "expected"
    # column stops matching what the operator wrote.
    %w[status:200 status:2xx status:200-299 json:data.user.id json:data.role=admin
      json-absent:data.token body:same body:diff].each do |text|
      a = RT::Assertion.parse(text)
      a.should be_a(RT::Assertion)
      a.as(RT::Assertion).to_s.should eq(text)
    end
  end

  it "reads an empty assertion as None rather than as an error" do
    # A step with no assertion is legitimate (a login, a cleanup): it records the outcome.
    RT::Assertion.parse("").as(RT::Assertion).none?.should be_true
    RT::Assertion.parse("   ").as(RT::Assertion).none?.should be_true
  end

  it "splits json: on the FIRST = so a literal may contain one" do
    a = RT::Assertion.parse("json:data.next=?page=2").as(RT::Assertion)
    a.kind.json_equals?.should be_true
    a.path.should eq("data.next")
    a.value.should eq("?page=2")
  end

  it "refuses a status that is not a code, a class or a range — by name" do
    RT::Assertion.parse("status:").should be_a(String)
    RT::Assertion.parse("status:99").as(String).should contain("100-599")
    RT::Assertion.parse("status:7xx").as(String).should contain("1xx-5xx")
    RT::Assertion.parse("status:299-200").as(String).should contain("inverted")
    RT::Assertion.parse("status:abc").should be_a(String)
  end

  it "refuses an unknown assertion with the full list of accepted forms" do
    msg = RT::Assertion.parse("statuss:200").as(String)
    msg.should contain("unknown assertion")
    msg.should contain("json-absent:")
  end
end

describe "Gori::Retest.evaluate" do
  it "passes an exact status and names the actual one on a miss" do
    a = RT::Assertion.parse("status:403").as(RT::Assertion)
    RT.evaluate(a, obs(status: 403), nil)[0].pass?.should be_true
    outcome, detail = RT.evaluate(a, obs(status: 200), nil)
    outcome.fail?.should be_true
    detail.should eq("status 200, expected 403")
  end

  it "treats a class and a range as inclusive bounds" do
    cls = RT::Assertion.parse("status:2xx").as(RT::Assertion)
    RT.evaluate(cls, obs(status: 200), nil)[0].pass?.should be_true
    RT.evaluate(cls, obs(status: 299), nil)[0].pass?.should be_true
    RT.evaluate(cls, obs(status: 300), nil)[0].fail?.should be_true
    rng = RT::Assertion.parse("status:301-304").as(RT::Assertion)
    RT.evaluate(rng, obs(status: 302), nil)[0].pass?.should be_true
    RT.evaluate(rng, obs(status: 305), nil)[0].fail?.should be_true
  end

  it "answers INCONCLUSIVE for a status assertion with no status at all" do
    # Not a fail: "the origin answered 500" and "the origin answered nothing" are opposite
    # findings, and reporting the second as the first sends the operator to the wrong end.
    outcome, detail = RT.evaluate(RT::Assertion.parse("status:200").as(RT::Assertion),
      obs(status: nil, error: "connection refused"), nil)
    outcome.inconclusive?.should be_true
    detail.should contain("connection refused")
  end

  it "reads a JSON field through a dotted path, arrays included" do
    body = %({"data":{"items":[{"id":7},{"id":8}],"role":"admin"}})
    present = RT::Assertion.parse("json:data.items.1.id").as(RT::Assertion)
    outcome, detail = RT.evaluate(present, obs(body: body), nil)
    outcome.pass?.should be_true
    detail.should eq("data.items.1.id = 8")
    RT.evaluate(RT::Assertion.parse("json:data.items.9.id").as(RT::Assertion), obs(body: body), nil)[0].fail?.should be_true
  end

  it "counts a present-but-null field as PRESENT" do
    # `{"error": null}` HAS the field. A reader that answered "absent" would let a step
    # asserting `json-absent:error` pass on a response that carries it.
    RT.evaluate(RT::Assertion.parse("json:error").as(RT::Assertion), obs(body: %({"error":null})), nil)[0].pass?.should be_true
    RT.evaluate(RT::Assertion.parse("json-absent:error").as(RT::Assertion), obs(body: %({"error":null})), nil)[0].fail?.should be_true
  end

  it "compares an UNTYPED literal against the value's own rendering" do
    # The literal came off a command line or a one-line form, so it carries no type: `n=3`
    # matches the number 3 AND the string "3", and `1e3` matches 1000. Insisting on the JSON
    # type would make the common `json:data.count=3` fail against an API that quotes its
    # numbers, for a reason the operator has no way to see from the assertion.
    eq_num = RT::Assertion.parse("json:n=3").as(RT::Assertion)
    RT.evaluate(eq_num, obs(body: %({"n":3})), nil)[0].pass?.should be_true
    RT.evaluate(eq_num, obs(body: %({"n":"3"})), nil)[0].pass?.should be_true
    RT.evaluate(eq_num, obs(body: %({"n":4})), nil)[0].fail?.should be_true
    RT.evaluate(RT::Assertion.parse("json:n=1e3").as(RT::Assertion), obs(body: %({"n":1000})), nil)[0].pass?.should be_true
    RT.evaluate(RT::Assertion.parse("json:n=3.0").as(RT::Assertion), obs(body: %({"n":3})), nil)[0].pass?.should be_true
    RT.evaluate(RT::Assertion.parse("json:ok=true").as(RT::Assertion), obs(body: %({"ok":true})), nil)[0].pass?.should be_true
    # BOTH booleans, in both cases. `if b = node.as_bool?` is falsey when the value IS
    # `false`, so a boolean false used to fall past the arm to an exact `to_json` compare —
    # `=False` then reported a FAILURE against a response that genuinely carries `false`.
    RT.evaluate(RT::Assertion.parse("json:ok=False").as(RT::Assertion), obs(body: %({"ok":false})), nil)[0].pass?.should be_true
    RT.evaluate(RT::Assertion.parse("json:ok=FALSE").as(RT::Assertion), obs(body: %({"ok":false})), nil)[0].pass?.should be_true
    RT.evaluate(RT::Assertion.parse("json:ok=false").as(RT::Assertion), obs(body: %({"ok":false})), nil)[0].pass?.should be_true
    RT.evaluate(RT::Assertion.parse("json:ok=true").as(RT::Assertion), obs(body: %({"ok":false})), nil)[0].fail?.should be_true
    RT.evaluate(RT::Assertion.parse("json:v=null").as(RT::Assertion), obs(body: %({"v":null})), nil)[0].pass?.should be_true
  end

  it "answers INCONCLUSIVE — never a pass — when the body is not JSON at all" do
    # An HTML error page must not satisfy `json-absent:`. "The field is absent" and "this is
    # not JSON" are different findings, and folding them is a false clean bill of health.
    outcome, detail = RT.evaluate(RT::Assertion.parse("json-absent:data.token").as(RT::Assertion),
      obs(body: "<html>500</html>"), nil)
    outcome.inconclusive?.should be_true
    detail.should contain("not JSON")
  end

  it "answers INCONCLUSIVE for a body comparison with no baseline behind it" do
    outcome, detail = RT.evaluate(RT::Assertion.parse("body:same").as(RT::Assertion), obs(body: "x"), nil)
    outcome.inconclusive?.should be_true
    detail.should contain("baseline")
  end

  it "decides body:same / body:diff against the baseline's decoded body" do
    base = obs(body: "hello")
    RT.evaluate(RT::Assertion.parse("body:same").as(RT::Assertion), obs(body: "hello"), base)[0].pass?.should be_true
    RT.evaluate(RT::Assertion.parse("body:same").as(RT::Assertion), obs(body: "other"), base)[0].fail?.should be_true
    RT.evaluate(RT::Assertion.parse("body:diff").as(RT::Assertion), obs(body: "other"), base)[0].pass?.should be_true
    RT.evaluate(RT::Assertion.parse("body:diff").as(RT::Assertion), obs(body: "hello"), base)[0].fail?.should be_true
  end
end

describe Gori::Retest::Engine do
  it "runs steps in the order given and closes its backend" do
    backend = TableBackend.new({} of Int64 => RT::Observation)
    plan = [planned(1_i64, :baseline, "status:200"), planned(2_i64, :variant, "status:200")]
    results = RT::Engine.new(backend).run(plan)
    backend.sent.should eq([1_i64, 2_i64])
    backend.finished?.should be_true
    results.map(&.outcome.pass?).should eq([true, true])
  end

  it "drops the anchor when a LATER baseline fails to establish one" do
    # A baseline whose send errored has no body, and it does not silently fall back to the
    # earlier reading either: the operator put a second baseline there because the state was
    # expected to have moved, so the first one's body is a reading from before it moved.
    # "We could not take the new reading" and "the body is unchanged" are opposite findings.
    backend = TableBackend.new({
      1_i64 => obs(body: "anchor"),
      2_i64 => obs(status: nil, error: "timeout"),
      3_i64 => obs(body: "anchor"),
    })
    plan = [planned(1_i64, :baseline), planned(2_i64, :baseline), planned(3_i64, :variant, "body:same")]
    results = RT::Engine.new(backend).run(plan)
    results[1].outcome.error?.should be_true
    results[2].outcome.inconclusive?.should be_true
    results[2].detail.should contain("got no response")
  end

  it "refuses to anchor a comparison on a baseline that MISSED its own expected result" do
    # The demotion `Authorize` makes for a denied baseline (#906/#913), arriving one tool
    # over. Without it a `body:same` variant compared against the 403 error page a
    # `status:200` baseline was handed reports PASS — "the body is unchanged" about two error
    # pages, neither of which is the resource under test.
    backend = TableBackend.new({
      1_i64 => obs(status: 403, body: "forbidden"),
      2_i64 => obs(status: 403, body: "forbidden"),
    })
    plan = [planned(1_i64, :baseline, "status:200"), planned(2_i64, :variant, "body:same")]
    results = RT::Engine.new(backend).run(plan)
    results[0].outcome.fail?.should be_true
    results[1].outcome.inconclusive?.should be_true
    results[1].detail.should contain("did not meet its own expected result")
    RT.verdict(results).fail?.should be_true
  end

  it "anchors on a baseline with NO assertion — that is the ordinary 'take a reading' case" do
    backend = TableBackend.new({1_i64 => obs(body: "anchor"), 2_i64 => obs(body: "anchor")})
    plan = [planned(1_i64, :baseline), planned(2_i64, :variant, "body:same")]
    RT::Engine.new(backend).run(plan)[1].outcome.pass?.should be_true
  end

  it "lets a LATER passing baseline re-anchor after a failed one" do
    # "baseline, variant, baseline, variant" is the shape a before/after check has, and one
    # bad reading in the middle must not poison the rest of the run.
    backend = TableBackend.new({
      1_i64 => obs(status: 500, body: "boom"),
      2_i64 => obs(body: "good"),
      3_i64 => obs(body: "good"),
    })
    plan = [planned(1_i64, :baseline, "status:200"), planned(2_i64, :baseline, "status:200"),
            planned(3_i64, :variant, "body:same")]
    results = RT::Engine.new(backend).run(plan)
    results[0].outcome.fail?.should be_true
    results[1].outcome.pass?.should be_true
    results[2].outcome.pass?.should be_true
  end

  it "halts after a REFUSED send and skips the rest — cleanup included" do
    backend = TableBackend.new({1_i64 => obs(blocked: "out of the project scope")})
    plan = [planned(1_i64, :baseline, "status:200"), planned(2_i64, :variant, "status:403"),
            planned(3_i64, :cleanup, method: "DELETE")]
    results = RT::Engine.new(backend).run(plan)
    backend.sent.should eq([1_i64]) # nothing after the refusal reached the wire
    results[0].outcome.blocked?.should be_true
    results[1].outcome.skipped?.should be_true
    results[2].outcome.skipped?.should be_true
    results[2].detail.should contain("cleanup not run")
    RT.verdict(results).blocked?.should be_true
  end

  it "runs cleanup after a refusal only when the operator says so" do
    backend = TableBackend.new({1_i64 => obs(blocked: "out of the project scope")})
    plan = [planned(1_i64, :baseline), planned(2_i64, :cleanup, method: "DELETE")]
    results = RT::Engine.new(backend).run(plan, allow_cleanup: true)
    backend.sent.should eq([1_i64, 2_i64])
    results[1].outcome.pass?.should be_true
  end

  it "halts the measurement steps on a failed SETUP but still runs cleanup" do
    # gori refused nothing here, so the "do not keep sending after a refusal" rule does not
    # apply — and a half-created fixture is exactly what cleanup exists to undo.
    backend = TableBackend.new({1_i64 => obs(status: 500)})
    plan = [planned(1_i64, :setup, "status:200"), planned(2_i64, :variant, "status:200"),
            planned(3_i64, :cleanup)]
    results = RT::Engine.new(backend).run(plan)
    backend.sent.should eq([1_i64, 3_i64])
    results[0].outcome.fail?.should be_true
    results[1].outcome.skipped?.should be_true
    results[1].detail.should contain("setup step")
    results[2].outcome.pass?.should be_true
  end

  it "marks a step whose Repeater session is gone SKIPPED, never absent" do
    # A retest that quietly became shorter is not a retest that passed.
    backend = TableBackend.new({} of Int64 => RT::Observation)
    plan = [planned(1_i64, :variant, "status:200", missing: "repeater #1 no longer exists"),
            planned(2_i64, :variant, "status:200")]
    results = RT::Engine.new(backend).run(plan)
    results.size.should eq(2)
    results[0].outcome.skipped?.should be_true
    backend.sent.should eq([2_i64])
    RT.verdict(results).inconclusive?.should be_true
  end

  it "keeps a row for every step after a stop, so a partial run cannot read as a pass" do
    backend = TableBackend.new({} of Int64 => RT::Observation)
    plan = [planned(1_i64, :baseline), planned(2_i64, :variant), planned(3_i64, :variant)]
    sent = 0
    results = RT::Engine.new(backend).run(plan, stop: -> { (sent += 1) > 1 })
    results.size.should eq(3)
    results[1].outcome.skipped?.should be_true
    results[2].outcome.skipped?.should be_true
    RT.verdict(results).should eq(RT::Verdict::Inconclusive)
  end

  it "reports each row to on_step as it is decided" do
    backend = TableBackend.new({} of Int64 => RT::Observation)
    seen = [] of Int64
    plan = [planned(1_i64, :baseline, missing: "gone"), planned(2_i64, :variant)]
    RT::Engine.new(backend).run(plan, on_step: ->(r : RT::StepResult) { seen << r.step.id; nil })
    seen.should eq([1_i64, 2_i64])
  end

  it "carries the backend's note alongside the judgement rather than instead of it" do
    backend = TableBackend.new({
      1_i64 => RT::Observation.new(status: 101, note: "handshake sent as HTTP"),
    })
    results = RT::Engine.new(backend).run([planned(1_i64, :variant, "status:101")])
    results[0].outcome.pass?.should be_true
    results[0].detail.should contain("101")
    results[0].detail.should contain("handshake sent as HTTP")
  end
end

describe "Gori::Retest.verdict" do
  it "ranks a refusal above a failure — a blocked run is about the scope, not the target" do
    blocked = [RT::StepResult.new(planned(1_i64, :variant), RT::Outcome::Blocked, "", RT::Observation.new),
               RT::StepResult.new(planned(2_i64, :variant), RT::Outcome::Fail, "", RT::Observation.new)]
    RT.verdict(blocked).blocked?.should be_true
  end

  it "requires every step to have run and been decided before it says pass" do
    passed = [RT::StepResult.new(planned(1_i64, :variant), RT::Outcome::Pass, "", RT::Observation.new)]
    RT.verdict(passed).pass?.should be_true
    [RT::Outcome::Inconclusive, RT::Outcome::Error, RT::Outcome::Skipped].each do |o|
      mixed = passed + [RT::StepResult.new(planned(2_i64, :variant), o, "", RT::Observation.new)]
      RT.verdict(mixed).inconclusive?.should be_true
    end
  end

  it "calls an empty run inconclusive rather than a pass" do
    RT.verdict([] of RT::StepResult).inconclusive?.should be_true
  end
end

describe "Gori::Retest.confirm_note" do
  it "stays silent on an all-safe batch and names the exact count otherwise" do
    safe = [planned(1_i64, :variant, method: "GET"), planned(2_i64, :variant, method: "HEAD")]
    RT.confirm_note(safe).should be_nil
    mixed = safe + [planned(3_i64, :cleanup, method: "DELETE"), planned(4_i64, :setup, method: "POST")]
    note = RT.confirm_note(mixed).not_nil!
    note.should contain("4 requests will be sent")
    note.should contain("2 of them state-changing")
    note.should contain("DELETE, POST")
  end

  it "counts only steps that will actually be sent" do
    # A step whose session is gone inflates the number the operator is asked to approve.
    plan = [planned(1_i64, :variant, method: "POST"),
            planned(2_i64, :variant, method: "DELETE", missing: "repeater #2 no longer exists")]
    RT.confirm_note(plan).not_nil!.should contain("1 request will be sent, 1 of them state-changing (POST)")
  end
end
