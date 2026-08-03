require "../spec_helper"

private def group_store(&)
  path = File.tempname("gori-probe-group", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Severity is what fixes the list order (`ORDER BY severity DESC, last_seen DESC`), so the
# cursor drift below is deterministic rather than a race on same-microsecond timestamps.
private def seed(store, code, host, severity)
  store.upsert_probe_issue(
    Gori::Probe::Detection.new(code, "headers", host, "https://#{host}/", "t", severity))
end

private def status_of(store, host)
  store.probe_issues.find! { |i| i.host == host }.status
end

# `probe_dismiss_code` / `probe_dismiss_host` read the group off the issue under the cursor
# when the confirm OPENS, but the action runs from the modal's on_close on a later tick — and
# the Runner's per-tick probe_generation poll is not gated on the overlay. A peer writer (MCP
# probe_dismiss/probe_delete, a second gori on the same project, `gori run probe`) can make
# the cursor issue leave the open-only list in between; ProbeView#apply_filter then loses its
# prev_id anchor and clamps onto a DIFFERENT issue. Re-deriving the group at answer time
# therefore mass-dismissed the wrong group.
#
# These examples pin the seam the controller now answers through: it takes the code/host
# captured at OPEN time and never re-reads a cursor. Driving the controller instance itself
# would need a live Runner (Host has ~30 abstract members over a bound Session), so the
# cursor-drift half is reproduced against the real ProbeView and asserted as the precondition.
describe "Probe bulk dismiss (group captured at confirm-open time)" do
  it "dismisses the captured code even after a peer writer moves the cursor to another code" do
    group_store do |store|
      seed(store, "missing_csp", "x.test", Gori::Store::Severity::Critical)
      seed(store, "missing_hsts", "y.test", Gori::Store::Severity::High)
      seed(store, "missing_csp", "z.test", Gori::Store::Severity::Medium)

      view = Gori::Tui::ProbeView.new
      view.reload(store)
      # What the operator saw in the prompt: `Dismiss all open "missing_csp" issues?`
      captured = view.target_issue.not_nil!.code
      captured.should eq("missing_csp")

      # …then, before they answered, a peer writer triaged the very issue under the cursor.
      peer_target = store.probe_issues.find! { |i| i.host == "x.test" }
      store.update_probe_issue_status(peer_target.id, Gori::Store::Status::FalsePositive)
      view.reload(store) # the Runner's probe_generation poll, which the overlay does not gate

      # Precondition — the hazard itself: the anchor is gone from the open-only list, so the
      # cursor has clamped onto an issue with a DIFFERENT code. Anything resolving the group
      # at answer time now resolves "missing_hsts", not what the prompt said.
      view.target_issue.not_nil!.code.should eq("missing_hsts")

      n = Gori::Tui::ProbeController.dismiss_open_by_code(store, nil, captured)
      n.should eq(1) # z.test only — x.test was already triaged by the peer

      status_of(store, "z.test").false_positive?.should be_true
      status_of(store, "y.test").open?.should be_true # the drifted-onto group is untouched
    end
  end

  it "dismisses the captured host even after a peer writer moves the cursor to another host" do
    group_store do |store|
      seed(store, "missing_csp", "x.test", Gori::Store::Severity::Critical)
      seed(store, "missing_hsts", "x.test", Gori::Store::Severity::Medium)
      seed(store, "missing_hsts", "y.test", Gori::Store::Severity::High)

      view = Gori::Tui::ProbeView.new
      view.reload(store)
      captured = view.target_issue.not_nil!.host
      captured.should eq("x.test")

      peer_target = store.probe_issues.find! { |i| i.host == "x.test" && i.code == "missing_csp" }
      store.update_probe_issue_status(peer_target.id, Gori::Store::Status::FalsePositive)
      view.reload(store)

      view.target_issue.not_nil!.host.should eq("y.test") # cursor drifted to another host

      Gori::Tui::ProbeController.dismiss_open_by_host(store, captured).should eq(1)

      store.probe_issues.select { |i| i.host == "x.test" }.all?(&.status.false_positive?).should be_true
      status_of(store, "y.test").open?.should be_true
    end
  end

  it "reports a count for the SAME group the prompt named" do
    group_store do |store|
      seed(store, "missing_csp", "a.test", Gori::Store::Severity::Critical)
      seed(store, "missing_csp", "b.test", Gori::Store::Severity::High)
      seed(store, "missing_hsts", "c.test", Gori::Store::Severity::Medium)

      view = Gori::Tui::ProbeView.new
      view.reload(store)
      captured = view.target_issue.not_nil!.code

      # The toast used to take `n` from the re-resolved issue and the code from the captured
      # one, so one sentence could report two different groups. Both now come from `captured`.
      Gori::Tui::ProbeController.dismiss_open_by_code(store, nil, captured).should eq(2)
      status_of(store, "c.test").open?.should be_true
    end
  end

  it "honours the scope lens: a scoped view never mutes hosts it cannot show" do
    group_store do |store|
      seed(store, "missing_hsts", "a.test", Gori::Store::Severity::Medium) # in scope
      seed(store, "missing_hsts", "b.test", Gori::Store::Severity::Medium) # out of scope
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "a.test")
      scope.enable

      Gori::Tui::ProbeController.dismiss_open_by_code(store, scope, "missing_hsts").should eq(1)
      status_of(store, "a.test").false_positive?.should be_true
      status_of(store, "b.test").open?.should be_true
    end
  end

  it "mutes every host for the code when the scope lens is off" do
    group_store do |store|
      seed(store, "missing_hsts", "a.test", Gori::Store::Severity::Medium)
      seed(store, "missing_hsts", "b.test", Gori::Store::Severity::Medium)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "a.test") # configured but NOT enabled → lens inactive

      Gori::Tui::ProbeController.dismiss_open_by_code(store, scope, "missing_hsts").should eq(2)
      store.probe_issues.all?(&.status.false_positive?).should be_true
    end
  end

  it "leaves already-triaged rows alone and counts only what it muted" do
    group_store do |store|
      seed(store, "missing_csp", "a.test", Gori::Store::Severity::High)
      seed(store, "missing_csp", "b.test", Gori::Store::Severity::Medium)
      confirmed = store.probe_issues.find! { |i| i.host == "a.test" }
      store.update_probe_issue_status(confirmed.id, Gori::Store::Status::Confirmed)

      Gori::Tui::ProbeController.dismiss_open_by_code(store, nil, "missing_csp").should eq(1)
      status_of(store, "a.test").confirmed?.should be_true # a promoted finding is not re-triaged
      status_of(store, "b.test").false_positive?.should be_true
    end
  end
end
