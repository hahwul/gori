require "../spec_helper"
require "file_utils"
require "../support/fake_host"
require "../../src/gori/tui/controllers/issues_controller"

# `IssuesController#issues_clear` — the Issues tab's ⇧X, the fifth member of the clear-all
# family (#899: History's flows, Probe's findings, the Authorize queue, the ACTIVITY feed).
#
# The tab had no clear verb at all while the chord was documented app-wide as "one chord clears
# a tab", so ⇧X on the one list holding hand-written writeups did nothing. What is pinned here
# is the CONTRACT the shared chord carries, not just that rows go: it asks first, the prompt
# names the total, an empty project gets a toast instead of a dialog, and — the one that is
# specific to this tab — a filter narrowing the list to nothing does not turn the wipe into a
# "nothing to clear", because the count is read from the STORE and never from the visible rows.

# The CA is the slow part of standing a Session up and nothing here asserts about it.
private ISSUES_CLEAR_CA = File.tempname("gori-issues-clear-ca")
Spec.after_suite { FileUtils.rm_rf(ISSUES_CLEAR_CA) }

private def with_issues_tab(&)
  root = File.tempname("gori-issues-clear")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("issuesclear")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(ISSUES_CLEAR_CA), Gori::Verbs.registry, project)
    host = FakeHost.new(session)
    ctl = Gori::Tui::IssuesController.new(host)
    ctl.view.reload(session.store)
    yield ctl, host, session.store
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def seed_issue(store : Gori::Store, title : String,
                       severity : Gori::Store::Severity = Gori::Store::Severity::Medium,
                       flow_id : Int64? = nil) : Int64
  id = store.insert_issue(title, severity, "acme.test", flow_id)
  id.should_not eq(0_i64)
  id
end

describe "IssuesController#issues_clear" do
  it "empties the project past a danger confirm that names the total" do
    with_issues_tab do |ctl, host, store|
      3.times { |i| seed_issue(store, "finding #{i}") }
      ctl.view.reload(store)

      ctl.issues_clear
      host.confirms.size.should eq(1)
      title, message = host.confirms.first
      title.should eq("CLEAR ISSUES")
      message.should contain("ALL 3 issues")
      # The prompt names what rides along, because an issue is not a re-capturable row: the
      # writeup in its notes is the part that cannot be scanned back.
      message.should contain("notes")
      # …and the fake host runs the action, so the wipe itself happened.
      store.count_issues.should eq(0)
      ctl.view.empty?.should be_true
      host.statuses.last.should eq("issues cleared")
    end
  end

  # The trap this tab has and the other four do not: `IssuesView#empty?` answers for the
  # FILTERED list (it gates mark-all, correctly), so gating the wipe on it would have told an
  # operator holding 40 issues that there was nothing to clear the moment their filter matched
  # none of them — the one reading of an advertised destructive key that is a lie.
  it "clears the whole project even when the filter is showing nothing" do
    with_issues_tab do |ctl, _host, store|
      2.times { |i| seed_issue(store, "finding #{i}") }
      ctl.view.reload(store)
      ctl.view.start_query
      "zzz-no-such-issue".each_char { |c| ctl.view.query_insert(c) }
      ctl.view.stop_query
      ctl.view.empty?.should be_true  # nothing VISIBLE…
      store.count_issues.should eq(2) # …and two rows still there

      ctl.issues_clear
      store.count_issues.should eq(0)
    end
  end

  # No prompt over nothing, and not silence either: ⇧X is named in the body hint, so a key that
  # answers with nothing at all reads as a key that failed. Same answer `probe_clear` and
  # `activity_clear` give.
  it "says so instead of prompting when the project has no issues" do
    with_issues_tab do |ctl, host, store|
      store.count_issues.should eq(0)

      ctl.issues_clear
      host.confirms.should be_empty
      host.statuses.last.should contain("nothing to clear")
    end
  end

  # The evidence links are the issue's own rows (`owner_kind = 'issue'`), so they go with it —
  # exactly what the per-issue delete cascade does, run unqualified. A link left behind would
  # be adopted by the next issue created: `issues.id` is INTEGER PRIMARY KEY without
  # AUTOINCREMENT, so the rowid comes straight back.
  it "takes the evidence links with the issues" do
    with_issues_tab do |ctl, _host, store|
      id = seed_issue(store, "reflected param", flow_id: 42_i64)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, id).size.should eq(1)
      ctl.view.reload(store)

      ctl.issues_clear
      store.list_links(Gori::Store::LinkOwnerKind::Issue, id).should be_empty
      # A fresh issue is handed that same rowid — and inherits nothing.
      again = seed_issue(store, "next one")
      store.list_links(Gori::Store::LinkOwnerKind::Issue, again).should be_empty
    end
  end

  # Marks are the list's other handle on a set, and every row they point at is gone. Left
  # behind they would inflate the next `N marked` chip and re-point `d` at nothing.
  it "drops the marks the wiped rows were carrying" do
    with_issues_tab do |ctl, _host, store|
      2.times { |i| seed_issue(store, "finding #{i}") }
      ctl.view.reload(store)
      ctl.view.mark_all
      ctl.view.mark_count.should eq(2)

      ctl.issues_clear
      ctl.view.mark_count.should eq(0)
    end
  end

  # Named where it can be read before it is pressed — the second obligation a destructive chord
  # carries (guide/hotkeys). Every LIST state, because `command_scope` answers Scope::Issues in
  # all of them; the marks state spells it `clear ALL`, which is the state where `space`/`d`
  # act on the marked set and this key does not.
  it "names the chord in the body hint, including while marks are set" do
    with_issues_tab do |ctl, _host, store|
      seed_issue(store, "finding")
      ctl.view.reload(store)
      hint = ctl.body_hint(:body)
      hint.should contain("⇧X")
      hint.should contain("clear")

      ctl.view.mark_all
      marked = ctl.body_hint(:body)
      marked.should contain("⇧X clear ALL")
      marked.should contain("esc drops marks")
    end
  end
end
