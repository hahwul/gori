require "../support/tui_contract"

include Gori::Tui

# #1431: the Project tab's SCOPE and HOST OVERRIDES selections are anchored to a row ID, not an
# index. The view renders straight out of the live `Scope` / `HostOverrides`, which
# `Runner#apply_external_change` reloads before the tab hears about it, so a bare index that
# was only clamped on refresh slid onto the NEXT row when a peer deleted one above it — and
# `d` / `e` / `y` then acted on a row the operator never selected.
#
# A peer is a second `Scope` / `HostOverrides` over the same store, which is what another
# `gori run project …` process is; the live object's `reload` is the Runner's half of the tick.

# A host whose confirm HOLDS the action instead of running it, so a peer's write can land
# between the question and the answer — the data_version tick keeps running under the modal.
private class DeferringHost < TuiContract::Host
  @pending : Proc(Nil)? = nil

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    @confirms << {title, message}
    @pending = action
  end

  def accept : Nil
    (@pending || raise "no confirm is open").call
    @pending = nil
  end
end

private def with_project(&)
  TuiContract.with_session("sel-anchor") do |session|
    %w[aaa.test bbb.test ccc.test].each { |h| session.scope.add("include", "host", h).should be_true }
    session.host_overrides.add("aaa.test", "10.0.0.1").should be_true
    session.host_overrides.add("bbb.test", "10.0.0.2").should be_true
    session.host_overrides.add("ccc.test", "10.0.0.3").should be_true
    host = DeferringHost.new(session)
    host.tab = :project
    ctl = ProjectController.new(host)
    ctl.on_enter
    yield ctl, host, session
  end
end

# What another process does: write through its OWN object, then this session's tick reloads
# the live one.
private def peer_scope_remove(session : Gori::Session, pattern : String) : Nil
  peer = Gori::Scope.load(session.store)
  id = peer.rules.find { |r| r.pattern == pattern }.not_nil!.id
  peer.remove(id).should be_true
  session.scope.reload
end

private def peer_override_remove(session : Gori::Session, host : String) : Nil
  peer = Gori::HostOverrides.load(session.store)
  id = peer.entries.find { |e| e.host == host }.not_nil!.id
  peer.remove(id).should be_true
  session.host_overrides.reload
end

# A peer write the live object has NOT caught up with yet — the window before the next
# data_version tick (750 ms).
private def peer_scope_remove_unseen(session : Gori::Session, pattern : String) : Nil
  peer = Gori::Scope.load(session.store)
  peer.remove(peer.rules.find { |r| r.pattern == pattern }.not_nil!.id).should be_true
end

private def peer_override_remove_unseen(session : Gori::Session, host : String) : Nil
  peer = Gori::HostOverrides.load(session.store)
  peer.remove(peer.entries.find { |e| e.host == host }.not_nil!.id).should be_true
end

describe "Project SCOPE selection across a peer's write (#1431)" do
  it "stays on the selected rule when a peer deletes one above it" do
    with_project do |ctl, _host, session|
      ctl.view.scope_select(1)
      ctl.view.selected_rule.not_nil!.pattern.should eq("bbb.test")

      peer_scope_remove(session, "aaa.test")
      ctl.on_external_change

      ctl.view.selected_rule.not_nil!.pattern.should eq("bbb.test")
    end
  end

  it "follows the rule on tab entry too, when the tick ran while another tab was active" do
    with_project do |ctl, _host, session|
      ctl.view.scope_select(1)
      peer_scope_remove(session, "aaa.test") # no on_external_change: Project was not the active tab
      ctl.on_enter

      ctl.view.selected_rule.not_nil!.pattern.should eq("bbb.test")
    end
  end

  it "keeps a mouse pick anchored as well as a keyboard one" do
    with_project do |ctl, _host, session|
      ctl.view.select_scope(1)
      peer_scope_remove(session, "aaa.test")
      ctl.on_external_change

      ctl.view.selected_rule.not_nil!.pattern.should eq("bbb.test")
    end
  end

  it "lands on the next rule when the peer deleted the selected one" do
    with_project do |ctl, _host, session|
      ctl.view.scope_select(1)
      peer_scope_remove(session, "bbb.test")
      ctl.on_external_change

      ctl.view.selected_rule.not_nil!.pattern.should eq("ccc.test")
    end
  end

  it "lands on the next rule, not past it, when the peer deleted rows above it too" do
    with_project do |ctl, _host, session|
      session.scope.add("include", "host", "ddd.test").should be_true
      ctl.view.scope_select(1)
      peer_scope_remove(session, "aaa.test")
      peer_scope_remove(session, "bbb.test")
      ctl.on_external_change

      ctl.view.selected_rule.not_nil!.pattern.should eq("ccc.test")
    end
  end

  it "deletes the rule the confirm named, not the one that slid under the cursor" do
    with_project do |ctl, host, session|
      ctl.view.scope_select(1)
      ctl.scope_delete_rule
      host.confirms.last[1].should contain("bbb.test")

      peer_scope_remove(session, "aaa.test")
      ctl.on_external_change
      host.accept

      session.scope.rules.map(&.pattern).should eq(["ccc.test"])
      host.statuses.last.should contain("scope rule deleted: bbb.test")
    end
  end

  it "says a rule the peer removed under the confirm is already gone, and deletes nothing else" do
    with_project do |ctl, host, session|
      ctl.view.scope_select(1)
      ctl.scope_delete_rule

      peer_scope_remove(session, "bbb.test")
      ctl.on_external_change
      host.accept

      session.scope.rules.map(&.pattern).should eq(["aaa.test", "ccc.test"])
      host.statuses.last.should contain("already removed elsewhere: bbb.test")
    end
  end

  it "says already gone before the tick has caught up, too" do
    with_project do |ctl, host, session|
      ctl.view.scope_select(1)
      ctl.scope_delete_rule
      peer_scope_remove_unseen(session, "bbb.test") # no reload, no tick
      host.accept

      host.statuses.last.should contain("already removed elsewhere: bbb.test")
      session.scope.rules.map(&.pattern).should eq(["aaa.test", "ccc.test"])
      ctl.view.selected_rule.not_nil!.pattern.should eq("ccc.test")
    end
  end

  it "warns of a black-holed sandbox when the peer removed the last include" do
    with_project do |ctl, host, session|
      %w[aaa.test ccc.test].each { |p| peer_scope_remove(session, p) }
      session.scope.toggle_sandbox.should be_true
      session.scope.sandbox?.should be_true
      ctl.on_external_change
      ctl.scope_delete_rule
      peer_scope_remove(session, "bbb.test")
      host.accept

      host.statuses.last.should contain("already removed elsewhere: bbb.test")
      host.statuses.last.should contain("ALL traffic is now blocked")
    end
  end
end

describe "Project HOST OVERRIDES selection across a peer's write (#1431)" do
  it "stays on the selected override, so `y` copies that row" do
    with_project do |ctl, _host, session|
      ctl.view.ov_select(1)
      ctl.view.selected_override_line.should eq("10.0.0.2 bbb.test")

      peer_override_remove(session, "aaa.test")
      ctl.on_external_change

      ctl.view.selected_override_line.should eq("10.0.0.2 bbb.test")
    end
  end

  it "follows the override on tab entry too" do
    with_project do |ctl, _host, session|
      ctl.view.select_override(1)
      peer_override_remove(session, "aaa.test")
      ctl.on_enter

      ctl.view.selected_override_host.should eq("bbb.test")
    end
  end

  it "lands on the next override when the peer deleted the selected one" do
    with_project do |ctl, _host, session|
      ctl.view.ov_select(1)
      peer_override_remove(session, "bbb.test")
      ctl.on_external_change

      ctl.view.selected_override_host.should eq("ccc.test")
    end
  end

  it "lands on the next override, not past it, when the peer deleted rows above it too" do
    with_project do |ctl, _host, session|
      session.host_overrides.add("ddd.test", "10.0.0.4").should be_true
      ctl.view.ov_select(1)
      peer_override_remove(session, "aaa.test")
      peer_override_remove(session, "bbb.test")
      ctl.on_external_change

      ctl.view.selected_override_host.should eq("ccc.test")
    end
  end

  it "deletes the override the confirm named, not the one that slid under the cursor" do
    with_project do |ctl, host, session|
      ctl.view.ov_select(1)
      ctl.hostov_delete_entry
      host.confirms.last[1].should contain("bbb.test")

      peer_override_remove(session, "aaa.test")
      ctl.on_external_change
      host.accept

      session.host_overrides.entries.map(&.host).should eq(["ccc.test"])
      host.statuses.last.should contain("host override deleted: bbb.test")
    end
  end

  it "says an override the peer removed under the confirm is already gone, and deletes nothing else" do
    with_project do |ctl, host, session|
      ctl.view.ov_select(1)
      ctl.hostov_delete_entry

      peer_override_remove(session, "bbb.test")
      ctl.on_external_change
      host.accept

      session.host_overrides.entries.map(&.host).should eq(["aaa.test", "ccc.test"])
      host.statuses.last.should contain("already removed elsewhere: bbb.test")
    end
  end

  it "says already gone before the tick has caught up, too" do
    with_project do |ctl, host, session|
      ctl.view.ov_select(1)
      ctl.hostov_delete_entry
      peer_override_remove_unseen(session, "bbb.test")
      host.accept

      host.statuses.last.should contain("already removed elsewhere: bbb.test")
      session.host_overrides.entries.map(&.host).should eq(["aaa.test", "ccc.test"])
      ctl.view.selected_override_host.should eq("ccc.test")
    end
  end
end
