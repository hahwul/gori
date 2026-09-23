require "../spec_helper"

private def ref_flow(store : Gori::Store, target : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: Time.utc.to_unix_ms * 1000_i64, scheme: "http", host: "ref.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: ref.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
end

private def retest_run_for_flow(store : Gori::Store, flow_id : Int64) : Int64
  issue_id = store.insert_issue("flow reference", Gori::Store::Severity::High, "ref.test", nil)
  repeater_id = store.insert_repeater(target: "http://ref.test/", request: "GET / HTTP/1.1\r\n\r\n".to_slice,
    http2: false, auto_cl: true, flow_id: nil, position: store.next_repeater_position)
  step_id, status = store.add_retest_step(issue_id, :baseline, Gori::Store::LinkRefKind::Repeater, repeater_id)
  status.ok?.should be_true
  step = store.get_retest_step(step_id).not_nil!
  planned = Gori::Retest::Planned.new(step, "GET", "http://ref.test/", "repeater tab")
  observed = Gori::Retest::Observation.new(status: 200, duration_us: 1_i64, bytes: 2_i64, flow_id: flow_id)
  result = Gori::Retest::StepResult.new(planned, Gori::Store::RetestOutcome::Pass, "ok", observed)
  run_id, status = store.record_retest_run(issue_id, 1_i64, 2_i64,
    Gori::Store::RetestVerdict::Pass, Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0), [result])
  status.ok?.should be_true
  run_id
end

describe "Store flow references after deletion" do
  it "detaches retest results before a deleted flow id can be reused" do
    with_store do |store|
      flow_id = ref_flow(store, "/recorded")
      run_id = retest_run_for_flow(store, flow_id)

      store.delete_flow(flow_id).should be_true
      store.flush
      ref_flow(store, "/unrelated").should eq(flow_id)
      store.flush

      store.retest_run_steps(run_id).first.flow_id.should be_nil
    end
  end

  it "detaches frozen evidence when one History flow is deleted" do
    with_store do |store|
      flow_id = ref_flow(store, "/recorded")
      issue_id = store.insert_issue("frozen flow", Gori::Store::Severity::Low, "ref.test", nil)
      snapshot = Gori::Evidence.from_flow(store.get_flow(flow_id).not_nil!)
      evidence_id, status = store.freeze_evidence(issue_id, snapshot)
      status.ok?.should be_true

      store.delete_flow(flow_id).should be_true
      store.flush
      ref_flow(store, "/unrelated").should eq(flow_id)
      store.flush

      meta = store.get_evidence_meta(evidence_id).not_nil!
      meta.source_id.should eq(-flow_id)
      store.evidence_source_alive?(meta).should be_false
      store.evidence_count_for(Gori::Store::LinkRefKind::Flow, flow_id).should eq(0)
    end
  end

  it "detaches retest results and frozen evidence during History clear" do
    with_store do |store|
      flow_id = ref_flow(store, "/recorded")
      run_id = retest_run_for_flow(store, flow_id)
      issue_id = store.insert_issue("frozen flow", Gori::Store::Severity::Low, "ref.test", nil)
      snapshot = Gori::Evidence.from_flow(store.get_flow(flow_id).not_nil!)
      evidence_id, status = store.freeze_evidence(issue_id, snapshot)
      status.ok?.should be_true

      store.clear_flows.should be_true
      store.flush
      ref_flow(store, "/unrelated").should eq(flow_id)
      store.flush

      store.retest_run_steps(run_id).first.flow_id.should be_nil
      meta = store.get_evidence_meta(evidence_id).not_nil!
      meta.source_id.should be < 0
      meta.source_label.should eq("hist ##{flow_id} (deleted)")
      store.evidence_source_alive?(meta).should be_false
      store.evidence_count_for(Gori::Store::LinkRefKind::Flow, flow_id).should eq(0)
      String.new(store.get_evidence(evidence_id).not_nil!.request_head).should contain("GET /recorded")
    end
  end
end
