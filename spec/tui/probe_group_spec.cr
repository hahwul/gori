require "../spec_helper"
require "../support/fake_host"
require "../support/memory_backend"
require "file_utils"

# src/gori/tui/probe_group.cr — Probe's "Group by check" rows: a code on 2+ hosts folds into
# one row, a code on one host stays the row it always was.

private def row(id : Int64, code : String, host : String, sev = Gori::Store::Severity::Medium, n = 1)
  Gori::Store::ProbeIssueRow.new(id, code, "headers", host, code.upcase, sev,
    Gori::Store::Status::Open, 1_i64, n, nil, nil, 0_i64, 0_i64)
end

private def seed(store, code, host, sev = Gori::Store::Severity::Medium)
  store.upsert_probe_issue(
    Gori::Probe::Detection.new(code, "headers", host, "https://#{host}/", "t", sev))
end

private PROBE_GROUP_CA = File.tempname("gori-probe-group-ca")
Spec.after_suite { FileUtils.rm_rf(PROBE_GROUP_CA) }

private def with_probe_group_controller(&)
  root = File.tempname("gori-probe-group")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("probegroup")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(PROBE_GROUP_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session, :probe)
    yield Gori::Tui::ProbeController.new(host), host, session.store
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe Gori::Tui::ProbeRow do
  it "folds a code on several hosts at its first member's place, and keeps a lone code plain" do
    findings = [row(1, "hsts", "a", Gori::Store::Severity::High, 3), row(2, "csp", "a"),
                row(3, "hsts", "b", Gori::Store::Severity::Low, 4)]
    rows = Gori::Tui::ProbeRow.build(findings, true, Set(String).new)
    rows.size.should eq(2)
    rows[0].group?.should be_true
    rows[0].members.not_nil!.map(&.host).should eq(%w[a b])
    rows[0].severity.should eq(Gori::Store::Severity::High)
    rows[0].affected_count.should eq(7)
    rows[1].group?.should be_false
    rows[1].issue.id.should eq(2)

    expanded = Gori::Tui::ProbeRow.build(findings, true, Set{"hsts"})
    expanded.map { |r| {r.issue.id, r.group?, r.child?} }.should eq(
      [{1_i64, true, false}, {1_i64, false, true}, {3_i64, false, true}, {2_i64, false, false}])
  end

  it "is the flat list, one row per finding, with grouping off" do
    findings = [row(1, "hsts", "a"), row(2, "hsts", "b")]
    rows = Gori::Tui::ProbeRow.build(findings, false, Set{"hsts"})
    rows.map(&.issue.id).should eq([1, 2])
    rows.none?(&.group?).should be_true
    rows.none?(&.child?).should be_true
  end
end

describe "Gori::Tui::ProbeView grouping" do
  it "groups by default, and builds from the filtered rows" do
    with_probe_group_controller do |ctl, _, store|
      seed(store, "missing_csp", "a.test", Gori::Store::Severity::Low) # ranks below the group
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_hsts", "b.test")
      view = ctl.view
      view.reload(store)
      view.grouped?.should be_true
      view.list_size.should eq(2)
      view.row_count.should eq(3) # the drill-in still counts findings
      view.selected_row.not_nil!.group?.should be_true

      b = MemoryBackend.new(100, 20)
      view.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, 100, 20))
      b.contains?("2 hosts").should be_true

      # host:a.test leaves one host per code: no group survives the filter.
      view.start_query
      "host:a.test".each_char { |c| view.query_insert(c) }
      view.list_size.should eq(2)
      view.row_count.should eq(2)
      view.selected_row.not_nil!.group?.should be_false
    end
  end

  it "expands on ↵, collapses on ← from the group or a host, and opens a host's detail" do
    with_probe_group_controller do |ctl, _, store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_hsts", "b.test")
      view = ctl.view
      view.reload(store)
      ctl.probe_open # ↵ on the group: expand, no detail
      view.detail_open?.should be_false
      view.list_size.should eq(3)
      ctl.probe_open # already open: nothing moves (a second click stays on its row)
      view.selected_row.not_nil!.group?.should be_true
      ctl.probe_move(1)
      view.selected_row.not_nil!.child?.should be_true
      ctl.probe_move(1)
      host = view.selected_issue.not_nil!.host
      ctl.probe_collapse
      view.list_size.should eq(1)
      view.selected_row.not_nil!.group?.should be_true

      ctl.probe_open
      ctl.probe_move(2)
      ctl.probe_open
      view.detail_open?.should be_true
      view.detail_issue.not_nil!.host.should eq(host)
      # The rail and step walk findings: 2/2, and a step back opens the other host.
      view.detail_crumb.not_nil!.pos.should eq("2/2")
      ctl.probe_step_item(-1)
      view.detail_crumb.not_nil!.pos.should eq("1/2")
    end
  end

  it "keeps a group expanded across a live reload, by code" do
    with_probe_group_controller do |ctl, _, store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_hsts", "b.test")
      view = ctl.view
      view.reload(store)
      view.expand_selected
      seed(store, "missing_hsts", "c.test")
      view.reload(store)
      view.expanded?("missing_hsts").should be_true
      view.list_size.should eq(4)
      view.selected_row.not_nil!.group?.should be_true
    end
  end

  it "restores today's flat list exactly when toggled off" do
    with_probe_group_controller do |ctl, host, store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_hsts", "b.test")
      seed(store, "missing_csp", "a.test")
      view = ctl.view
      view.reload(store)
      ctl.probe_toggle_group
      view.grouped?.should be_false
      host.statuses.last.should eq("one row per finding")
      ids = (0...view.list_size).map { |i| view.select_index(i); view.selected_issue.not_nil!.id }
      ids.should eq(store.probe_issue_rows.map(&.id))
    end
  end

  it "dismisses a group row through Dismiss all with this code" do
    with_probe_group_controller do |ctl, host, store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_hsts", "b.test")
      seed(store, "missing_csp", "c.test", Gori::Store::Severity::Low)
      ctl.view.reload(store)
      ctl.probe_dismiss
      host.confirms.last[0].should eq("DISMISS GROUP")
      store.probe_issue_rows.select(&.code.==("missing_hsts")).all?(&.status.false_positive?).should be_true
      store.probe_issue_rows.find!(&.code.==("missing_csp")).status.open?.should be_true
    end
  end

  # `dismiss_open_by_code` ignores the query and the closed lens: it muted hosts the row did
  # not show, and could not re-open a dismissed group.
  it "dismisses only the hosts the group row shows, and re-opens a fully dismissed group" do
    with_probe_group_controller do |ctl, host, store|
      %w[a.test b.test c.test].each { |h| seed(store, "missing_hsts", h) }
      view = ctl.view
      view.reload(store)
      view.start_query
      "-host:c.test".each_char { |c| view.query_insert(c) }
      view.stop_query
      view.selected_row.not_nil!.members.not_nil!.size.should eq(2)
      ctl.probe_dismiss
      host.confirms.last.should eq({"DISMISS GROUP", "Dismiss 2 findings of “missing_hsts”?"})
      by_host = store.probe_issue_rows.to_h { |r| {r.host, r.status} }
      by_host["c.test"].open?.should be_true
      by_host["a.test"].false_positive?.should be_true

      view.toggle_show_closed
      ctl.probe_dismiss
      host.confirms.last.should eq({"DISMISS GROUP", "Re-open 2 findings of “missing_hsts”?"})
      store.probe_issue_rows.all?(&.status.open?).should be_true
    end
  end

  it "stays on the next host after dismissing one from an expanded group" do
    with_probe_group_controller do |ctl, _, store|
      %w[a.test b.test c.test].each { |h| seed(store, "missing_hsts", h) }
      view = ctl.view
      view.reload(store)
      ctl.probe_open
      ctl.probe_move(1)
      first = view.selected_issue.not_nil!.host
      ctl.probe_dismiss
      view.reload(store)
      row = view.selected_row.not_nil!
      row.child?.should be_true
      row.issue.host.should_not eq(first)
    end
  end

  it "refuses the single-finding actions on a group row" do
    with_probe_group_controller do |ctl, host, store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_hsts", "b.test")
      ctl.view.reload(store)
      ctl.probe_delete
      ctl.probe_dismiss_host
      host.confirms.should be_empty
      host.statuses.should eq(["expand the group and pick a host"] * 2)
      ctl.refuse_group?.should be_true
      store.probe_issue_rows.size.should eq(2)
      ctl.probe_issue_selected?.should be_true # copy still answers: every host's line
    end
  end
end
