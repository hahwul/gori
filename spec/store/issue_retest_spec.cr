require "../spec_helper"

# Issue retest steps and runs (V27, #1036). These examples pin the store-level contract the
# three surfaces depend on: positions stay 1..N so "move step 3 up" means what the list
# shows, a run summary and its rows commit together, the history is bounded, and the whole
# thing cascades with the Issue it belongs to (unlike frozen evidence, which does not).

private def repeater(store, name : String, target : String = "https://a.test") : Int64
  id = store.insert_repeater(target: target, request: "GET / HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice,
    http2: false, auto_cl: true, flow_id: nil, position: store.next_repeater_position)
  store.set_repeater_name(id, name)
  id
end

private def issue(store, title : String = "broken access control") : Int64
  store.insert_issue(title, Gori::Store::Severity::High, "a.test", nil)
end

private def positions(store, issue_id : Int64) : Array(Int32)
  store.retest_steps(issue_id).map(&.position)
end

private def result(step : Gori::Store::RetestStep, outcome : Gori::Store::RetestOutcome,
                   detail : String = "ok", status : Int32? = 200,
                   flow_id : Int64? = nil) : Gori::Retest::StepResult
  planned = Gori::Retest::Planned.new(step, "GET", "https://a.test/x", "repeater tab")
  Gori::Retest::StepResult.new(planned, outcome, detail,
    Gori::Retest::Observation.new(status: status, duration_us: 1_234_i64, bytes: 42_i64, flow_id: flow_id))
end

describe "Store retest steps (V27)" do
  it "appends steps at 1..N and reads them back in position order" do
    with_store do |store|
      iid = issue(store)
      a = repeater(store, "login")
      b = repeater(store, "target")
      id1, s1 = store.add_retest_step(iid, :setup, Gori::Store::LinkRefKind::Repeater, a)
      id2, s2 = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, b, "status:403")
      s1.ok?.should be_true
      s2.ok?.should be_true
      steps = store.retest_steps(iid)
      steps.map(&.id).should eq([id1, id2])
      steps.map(&.position).should eq([1, 2])
      steps[0].role.setup?.should be_true
      steps[1].assertion.should eq("status:403")
      steps[1].ref_label.should eq("repeater ##{b}")
      store.count_retest_steps(iid).should eq(2)
    end
  end

  it "refuses a step on an issue that no longer exists, and writes nothing" do
    # Decided INSIDE the writer's transaction against the row as it is when the write lands,
    # not pre-checked by the caller — the argument `freeze_evidence` states one table over.
    with_store do |store|
      r = repeater(store, "x")
      id, status = store.add_retest_step(9999_i64, :variant, Gori::Store::LinkRefKind::Repeater, r)
      status.issue_gone?.should be_true
      id.should eq(0)
      store.retest_steps(9999_i64).should be_empty
    end
  end

  it "closes the gap a removed step left, so positions stay 1..N" do
    # `position` is what a move names. A hole makes "the third row" and "move to 3" disagree
    # the moment anything is deleted.
    with_store do |store|
      iid = issue(store)
      ids = Array.new(3) { |i| store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r#{i}"))[0] }
      store.remove_retest_step(ids[1]).ok?.should be_true
      positions(store, iid).should eq([1, 2])
      store.retest_steps(iid).map(&.id).should eq([ids[0], ids[2]])
    end
  end

  it "moves a step to a 1-based position, clamped to the list" do
    with_store do |store|
      iid = issue(store)
      ids = Array.new(3) { |i| store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r#{i}"))[0] }
      store.move_retest_step(ids[2], 1).ok?.should be_true
      store.retest_steps(iid).map(&.id).should eq([ids[2], ids[0], ids[1]])
      positions(store, iid).should eq([1, 2, 3])
      # Clamped rather than refused: "move it to the top" must not fail on a list that is
      # already there, and "to the end" must not need the caller to know the size.
      store.move_retest_step(ids[2], 99).ok?.should be_true
      store.retest_steps(iid).map(&.id).should eq([ids[0], ids[1], ids[2]])
      store.move_retest_step(ids[2], 0).ok?.should be_true
      store.retest_steps(iid).map(&.id).should eq([ids[2], ids[0], ids[1]])
    end
  end

  it "edits role and assertion independently, and reports a step that is gone" do
    with_store do |store|
      iid = issue(store)
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r"), "status:200")
      store.update_retest_step(id, role: Gori::Store::RetestRole::Control).ok?.should be_true
      step = store.get_retest_step(id).not_nil!
      step.role.control?.should be_true
      step.assertion.should eq("status:200")
      store.update_retest_step(id, assertion: "").ok?.should be_true
      store.get_retest_step(id).not_nil!.assertion.should eq("")
      # No fields supplied is a no-op that reports Ok — nothing to persist, nothing failed.
      store.update_retest_step(id).ok?.should be_true
      store.remove_retest_step(id).ok?.should be_true
      store.update_retest_step(id, role: Gori::Store::RetestRole::Setup).step_gone?.should be_true
    end
  end

  it "clears an issue's steps but keeps its runs — re-planning a check does not un-run it" do
    with_store do |store|
      iid = issue(store)
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r"))
      step = store.get_retest_step(id).not_nil!
      store.record_retest_run(iid, 1_i64, 2_i64, Gori::Store::RetestVerdict::Pass,
        Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0), [result(step, Gori::Store::RetestOutcome::Pass)])
      store.clear_retest_steps(iid).should be_true
      store.count_retest_steps(iid).should eq(0)
      store.retest_runs(iid).size.should eq(1)
    end
  end
end

describe "Store retest runs (V27)" do
  it "writes the summary and its result rows together, copying what each step SENT" do
    with_store do |store|
      iid = issue(store)
      id, _ = store.add_retest_step(iid, :baseline, Gori::Store::LinkRefKind::Repeater, repeater(store, "login"), "status:200")
      step = store.get_retest_step(id).not_nil!
      tally = Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0)
      run_id, status = store.record_retest_run(iid, 10_i64, 20_i64, Gori::Store::RetestVerdict::Pass,
        tally, [result(step, Gori::Store::RetestOutcome::Pass, "200 · 1.2ms", flow_id: 77_i64)],
        surface: "cli")
      status.ok?.should be_true

      run = store.get_retest_run(run_id).not_nil!
      run.verdict.pass?.should be_true
      run.surface.should eq("cli")
      run.total.should eq(1)
      run.passed.should eq(1)
      run.duration_us.should eq(10)

      rows = store.retest_run_steps(run_id)
      rows.size.should eq(1)
      rows[0].position.should eq(1)
      rows[0].role.baseline?.should be_true
      rows[0].method.should eq("GET")
      rows[0].url.should eq("https://a.test/x")
      rows[0].assertion.should eq("status:200")
      rows[0].outcome.pass?.should be_true
      rows[0].status.should eq(200)
      rows[0].bytes.should eq(42)
      # The History row THIS send wrote: how an old result opens the exact response it
      # reported, after the Repeater tab has moved on.
      rows[0].flow_id.should eq(77_i64)
    end
  end

  it "keeps the result row's copies when the step it came from is edited away" do
    # A run summary is read weeks later. A row that re-resolved would describe a request
    # that never ran.
    with_store do |store|
      iid = issue(store)
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "old name"), "status:403")
      step = store.get_retest_step(id).not_nil!
      run_id, _ = store.record_retest_run(iid, 1_i64, 2_i64, Gori::Store::RetestVerdict::Fail,
        Gori::Retest::Tally.new(1, 0, 1, 0, 0, 0, 0),
        [result(step, Gori::Store::RetestOutcome::Fail, "status 200, expected 403", status: 200)])
      store.update_retest_step(id, assertion: "status:200")
      store.remove_retest_step(id)
      rows = store.retest_run_steps(run_id)
      rows[0].assertion.should eq("status:403")
      rows[0].detail.should eq("status 200, expected 403")
    end
  end

  it "keeps only the newest `keep` runs, rows and all" do
    with_store do |store|
      iid = issue(store)
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r"))
      step = store.get_retest_step(id).not_nil!
      run_ids = Array.new(5) do |i|
        store.record_retest_run(iid, (i + 1).to_i64, (i + 2).to_i64, Gori::Store::RetestVerdict::Pass,
          Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0),
          [result(step, Gori::Store::RetestOutcome::Pass)], keep: 3)[0]
      end
      kept = store.retest_runs(iid)
      kept.size.should eq(3)
      # Newest first — a regression check reads the last one.
      kept.map(&.id).should eq(run_ids[2..].reverse)
      store.retest_run_steps(run_ids[0]).should be_empty
      store.retest_run_steps(run_ids.last).size.should eq(1)
    end
  end

  it "does not prune at all when `keep` is zero or negative" do
    # A caller that means "no history" deletes. Wiping on a zero-valued argument is the shape
    # a misread config turns into data loss.
    with_store do |store|
      iid = issue(store)
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r"))
      step = store.get_retest_step(id).not_nil!
      3.times do |i|
        store.record_retest_run(iid, (i + 1).to_i64, (i + 2).to_i64, Gori::Store::RetestVerdict::Pass,
          Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0),
          [result(step, Gori::Store::RetestOutcome::Pass)], keep: 0)
      end
      store.retest_runs(iid).size.should eq(3)
    end
  end

  it "answers the last run, and nil before anything has run" do
    with_store do |store|
      iid = issue(store)
      store.last_retest_run(iid).should be_nil
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r"))
      step = store.get_retest_step(id).not_nil!
      store.record_retest_run(iid, 1_i64, 2_i64, Gori::Store::RetestVerdict::Fail,
        Gori::Retest::Tally.new(1, 0, 1, 0, 0, 0, 0), [result(step, Gori::Store::RetestOutcome::Fail)])
      store.record_retest_run(iid, 5_i64, 6_i64, Gori::Store::RetestVerdict::Pass,
        Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0), [result(step, Gori::Store::RetestOutcome::Pass)])
      store.last_retest_run(iid).not_nil!.verdict.pass?.should be_true
    end
  end

  it "deletes one run with its rows, leaving the steps that produced it" do
    with_store do |store|
      iid = issue(store)
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r"))
      step = store.get_retest_step(id).not_nil!
      run_id, _ = store.record_retest_run(iid, 1_i64, 2_i64, Gori::Store::RetestVerdict::Pass,
        Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0), [result(step, Gori::Store::RetestOutcome::Pass)])
      store.delete_retest_run(run_id).should be_true
      store.get_retest_run(run_id).should be_nil
      store.retest_run_steps(run_id).should be_empty
      store.count_retest_steps(iid).should eq(1)
    end
  end
end

describe "Store issue delete → retest cascade" do
  it "takes the steps and the runs with the issue, unlike frozen evidence" do
    # A run summary is a statement about ONE issue's check and means nothing detached from
    # it, where a frozen exchange is bytes that deliberately outlive any filing (#1039).
    with_store do |store|
      iid = issue(store)
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r"))
      step = store.get_retest_step(id).not_nil!
      run_id, _ = store.record_retest_run(iid, 1_i64, 2_i64, Gori::Store::RetestVerdict::Pass,
        Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0), [result(step, Gori::Store::RetestOutcome::Pass)])
      store.delete_issue(iid).should be_true
      store.retest_steps(iid).should be_empty
      store.retest_runs(iid).should be_empty
      store.get_retest_run(run_id).should be_nil
      store.retest_run_steps(run_id).should be_empty
    end
  end

  it "clears every issue's retest on the whole-tab wipe" do
    with_store do |store|
      a = issue(store, "one")
      b = issue(store, "two")
      [a, b].each { |iid| store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, repeater(store, "r#{iid}")) }
      store.clear_issues.should be_true
      [a, b].each { |iid| store.count_retest_steps(iid).should eq(0) }
    end
  end
end

# A backend that fails the example if it is ever asked to send — for the refusals that must
# never reach the wire.
private class NoSendBackend < Gori::Retest::Backend
  def send(p : Gori::Retest::Planned) : Gori::Retest::Observation
    raise "the engine sent a step it should have skipped: #{p.step.id}"
  end
end

describe "Gori::Retest.plan" do
  it "resolves each step against the project, naming the method and url it will send" do
    with_store do |store|
      iid = issue(store)
      rid = store.insert_repeater(target: "https://a.test",
        request: "POST /orders HTTP/1.1\r\nHost: a.test\r\nContent-Length: 2\r\n\r\n{}".to_slice,
        http2: false, auto_cl: true, flow_id: nil, position: 1)
      store.set_repeater_name(rid, "create order")
      store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, rid, "status:201")
      pl = Gori::Retest.plan(store, iid)
      pl.size.should eq(1)
      pl[0].method.should eq("POST")
      pl[0].url.should eq("https://a.test/orders")
      pl[0].label.should eq("create order")
      pl[0].runnable?.should be_true
      pl[0].state_changing?.should be_true
      pl[0].assertion.describe.should eq("status 201")
    end
  end

  it "refuses a step whose stored assertion THIS build cannot read" do
    # The only way one gets on disk is a newer gori having written it, and the two readings
    # are opposite: "assert nothing" passes, "I cannot read what to assert" must not. Written
    # past the surfaces (they all validate) exactly as a newer gori would.
    with_store do |store|
      iid = issue(store)
      rid = repeater(store, "r")
      id, _ = store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, rid)
      store.update_retest_step(id, assertion: "quantum:entangled").ok?.should be_true
      pl = Gori::Retest.plan(store, iid)
      pl[0].runnable?.should be_false
      pl[0].missing.not_nil!.should contain("cannot read")
      # …and the engine therefore SKIPS it rather than passing it.
      results = Gori::Retest::Engine.new(NoSendBackend.new).run(pl)
      results[0].outcome.skipped?.should be_true
      Gori::Retest.verdict(results).pass?.should be_false
    end
  end

  it "keeps a step whose session is gone, with the reason on the row" do
    with_store do |store|
      iid = issue(store)
      rid = repeater(store, "gone soon")
      store.add_retest_step(iid, :variant, Gori::Store::LinkRefKind::Repeater, rid, "status:200")
      store.delete_repeater(rid)
      pl = Gori::Retest.plan(store, iid)
      pl.size.should eq(1)
      pl[0].runnable?.should be_false
      pl[0].missing.not_nil!.should contain("no longer exists")
      # …and it is not counted in what the operator is asked to approve.
      Gori::Retest.state_changing(pl).should be_empty
    end
  end
end
