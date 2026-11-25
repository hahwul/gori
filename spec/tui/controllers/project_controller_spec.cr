require "../../support/tui_contract"

include Gori::Tui

# Records whether the Project settings pane APPLIED anything (an apply rebinds the live proxy).
private class ApplySpyHost < TuiContract::Host
  getter applied = [] of Gori::Settings::ProjectNetworkConfig
  getter protos = [] of String

  def apply_project_network(config : Gori::Settings::ProjectNetworkConfig) : {String, Bool}
    @applied << config
    {"project network saved", true}
  end

  def apply_project_protos(spec : String) : {String, Bool}
    @protos << spec
    {"proto saved", true}
  end
end

private def settings_key(ctl : ProjectController, key : Termisu::Input::Key) : Nil
  ctl.handle_body_key(Termisu::Event::Key.new(key))
end

private def settings_type(ctl : ProjectController, text : String) : Nil
  text.each_char { |c| ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key.from_char(c), char: c)) }
end

describe ProjectController do
  # esc on the Project settings card used to APPLY the half-typed field (`99 · project`,
  # "project network saved"). It cancels now: the stored value and its pin state come back, nothing
  # is applied — so the bind port never rebinds the proxy — and focus still returns to the strip.
  {ProjectView::SETTINGS_FIELD_BASE + ProjectView::SETTINGS_BIND_PORT_INDEX, 11, 12 + ProjectView::SETTINGS_FIELD_BASE}.each do |row|
    it "reverts the edit on esc instead of applying it (row #{ProjectView::SETTINGS_LABELS[row]})" do
      TuiContract.with_session("project-settings-esc") do |session|
        host = ApplySpyHost.new(session)
        host.tab = :project
        ctl = ProjectController.new(host)
        ctl.on_enter
        ctl.view.focus_pane(:settings)
        ctl.view.select_setting(row)
        before = ctl.view.@set_values.dup
        pins = ctl.view.@set_overridden.dup
        settings_key(ctl, Termisu::Input::Key::Backspace)
        settings_type(ctl, "99")
        ctl.view.@set_values.should_not eq(before)
        ctl.body_hint(:body).should contain("esc cancel")

        settings_key(ctl, Termisu::Input::Key::Escape)
        ctl.view.@set_values.should eq(before)
        ctl.view.@set_overridden.should eq(pins)
        ctl.view.settings_dirty?.should be_false
        ctl.view.protos_dirty?.should be_false
        host.applied.should be_empty
        host.protos.should be_empty
        host.focus_requests.last.should eq(:subtabs)
        ctl.body_hint(:body).should end_with("esc sub-tabs")
      end
    end
  end

  # ↵ is unchanged: it applies.
  it "still applies the edit on enter" do
    TuiContract.with_session("project-settings-enter") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      ctl.view.select_setting(11) # Connect timeout (s)
      settings_type(ctl, "9")
      settings_key(ctl, Termisu::Input::Key::Enter)
      host.applied.size.should eq(1)
    end
  end

  # A leave applies (DESIGN.md §7 2026-11-19) and drops only the bad edit. It used to reload the
  # whole card, so a valid connect timeout typed beside an invalid capture limit vanished while
  # the toast named only the capture limit.
  it "drops only the invalid field on leave, applies the rest and names what it dropped" do
    TuiContract.with_session("project-settings-leave-invalid") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      stored_cap = ctl.view.settings_values[11]
      ctl.view.select_setting(11) # Connect timeout (s)
      6.times { settings_key(ctl, Termisu::Input::Key::Backspace) }
      settings_type(ctl, "45")
      ctl.view.select_setting(13) # Capture body limit (MiB)
      6.times { settings_key(ctl, Termisu::Input::Key::Backspace) }
      settings_type(ctl, "abc")
      14.times { settings_key(ctl, Termisu::Input::Key::Up) } # ↑ off the top row leaves the card
      host.focus_requests.last.should eq(:subtabs)
      host.applied.size.should eq(1)
      host.applied.last.connect_secs.should eq(45)
      host.applied.last.capture_mib.should eq(stored_cap.to_i)
      host.statuses.last.should eq(%(capture limit "abc" invalid — dropped · network saved))
    end
  end

  it "applies nothing when the invalid field was the only edit, and still says it was dropped" do
    TuiContract.with_session("project-settings-leave-only-invalid") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      before = ctl.view.settings_values
      ctl.view.select_setting(12) # Idle timeout (s)
      settings_type(ctl, "x")
      14.times { settings_key(ctl, Termisu::Input::Key::Up) }
      host.applied.should be_empty
      ctl.view.settings_values.should eq(before)
      ctl.view.settings_dirty?.should be_false
      host.statuses.last.should eq(%(idle timeout "30x" invalid — dropped))
    end
  end

  # ↵ is not a leave: the refused value stays on screen to be fixed, and so does the other edit.
  it "keeps every pending edit when ↵ is refused" do
    TuiContract.with_session("project-settings-enter-invalid") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      ctl.view.select_setting(11)
      settings_type(ctl, "5")
      ctl.view.select_setting(13)
      settings_type(ctl, "z")
      settings_key(ctl, Termisu::Input::Key::Enter)
      host.applied.should be_empty
      ctl.view.settings_values[9].should end_with("5")
      ctl.view.settings_values[11].should end_with("z")
      host.statuses.last.should_not contain("dropped")
    end
  end

  # With a pending edit the esc promise sits early in the text-row hint, where an 80-column
  # footer still shows it (`Chrome.fit_hints` drops this hint from the right).
  it "keeps `esc cancel` when an 80-column footer fits the hint" do
    TuiContract.with_session("project-settings-hint") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      ctl.view.select_setting(11)
      settings_type(ctl, "9")
      Chrome.fit_hints(ctl.body_hint(:body), 50).should contain("esc cancel")
    end
  end

  # The sandbox and lens rows apply at once: esc never reverts THEIR action, so their tail
  # names only what it does cancel — another row's unapplied edit.
  it "does not promise esc cancels an instant toggle row" do
    TuiContract.with_session("project-settings-instant") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      ctl.view.select_setting(ProjectView::SETTINGS_SANDBOX_ROW)
      ctl.body_hint(:body).should end_with("esc sub-tabs")
      ctl.view.select_setting(11)
      settings_type(ctl, "9")
      [ProjectView::SETTINGS_SANDBOX_ROW, 0].each do |row|
        ctl.view.select_setting(row)
        ctl.body_hint(:body).should end_with("· esc cancel edits")
      end
    end
  end

  # Every other multi-line editor deletes forward on Delete; the DESCRIPTION card dropped it.
  it "deletes forward on Delete in the DESCRIPTION editor" do
    TuiContract.with_session("project-desc-delete") do |session|
      host = TuiContract::Host.new(session)
      ctl = ProjectController.new(host)
      host.tab = :project
      ctl.on_enter
      ctl.view.focus_pane(:desc)
      ctl.view.replace_desc("abc")
      ctl.view.enter_desc_insert!
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Home)).should be_true
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Right)).should be_true
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Delete)).should be_true
      ctl.view.desc_text.should eq("ac")
    end
  end

  # The `s` lens filters Probe's finding list too; there the toast names what it lists.
  it "names findings, not flows, when the lens turns off on Probe" do
    TuiContract.with_session("project-lens-noun") do |session|
      host = FakeHost.new(session, :probe)
      session.scope.disable
      ProjectController.new(host).toast_scope_state
      host.statuses.last.should eq("scope lens OFF — showing all findings")
      host.active_tab = :history
      ProjectController.new(host).toast_scope_state
      host.statuses.last.should eq("scope lens OFF — showing all flows")
    end
  end
end

private def desc_esc(ctl : ProjectController) : Nil
  ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape))
end

private def desc_ctrl_w(ctl : ProjectController) : Nil
  ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerW, Termisu::Input::Modifier::Ctrl))
end

# The Issues notes refusal (#1980), on the Project description. The first cut offered only a
# DESCRIPTION CHANGED confirm whose one answer was "discard", and cancelling it looped back to
# the same confirm on every later `esc`: the draft could never be saved over the peer's text.
# A guard on this pane can only be an interruption, never a veto.
describe "Project description conflict" do
  it "keeps the draft on a passive commit and names the key that resolves it" do
    TuiContract.with_session("project-description-conflict") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.view.replace_desc("draft")
      session.store.set_setting(ProjectView::DESC_KEY, "peer").should be_true
      ctl.commit.should be_false
      host.confirms.should be_empty
      host.statuses.last.should contain("description NOT saved — changed elsewhere (esc in it)")
      ctl.view.desc_text.should eq("draft")
      # A tab switch does not become a save by being repeated; only `esc` is the save key.
      ctl.commit.should be_false
      session.store.setting(ProjectView::DESC_KEY).should eq("peer")
    end
  end

  it "lets a second `esc` write, and the text that lands is the operator's" do
    TuiContract.with_session("project-description-overwrite") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.view.replace_desc("mine")
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS").should be_true
      desc_esc(ctl)
      session.store.setting(ProjectView::DESC_KEY).should eq("THEIRS") # first esc refuses
      host.confirms.should be_empty
      host.statuses.last.should contain("esc overwrites, ^W theirs")
      ctl.view.desc_insert_mode?.should be_true
      desc_esc(ctl)
      session.store.setting(ProjectView::DESC_KEY).should eq("mine")
      ctl.view.desc_insert_mode?.should be_false # a real save, so INS closes
      ctl.commit.should be_true
    end
  end

  it "will not carry an arm across a peer's SECOND write" do
    TuiContract.with_session("project-description-rearm") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.view.replace_desc("mine")
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS").should be_true
      desc_esc(ctl) # armed against "THEIRS"
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS, REVISED").should be_true
      desc_esc(ctl)
      session.store.setting(ProjectView::DESC_KEY).should eq("THEIRS, REVISED") # refused again
      host.statuses.count(&.includes?("esc overwrites, ^W theirs")).should eq(2)
      desc_esc(ctl) # now armed against what is really there
      session.store.setting(ProjectView::DESC_KEY).should eq("mine")
    end
  end

  it "cannot be pre-armed by an esc that had nothing to refuse" do
    TuiContract.with_session("project-description-prearm") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.view.replace_desc("one")
      desc_esc(ctl) # a clean save; nothing to arm against
      session.store.setting(ProjectView::DESC_KEY).should eq("one")
      ctl.editor_enter_insert
      ctl.view.replace_desc("two")
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS").should be_true
      desc_esc(ctl)
      session.store.setting(ProjectView::DESC_KEY).should eq("THEIRS") # refused, not overwritten
      host.statuses.last.should contain("esc overwrites, ^W theirs")
    end
  end

  it "takes theirs on ^W and drops the arm with it" do
    TuiContract.with_session("project-description-take-theirs") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.view.replace_desc("mine")
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS").should be_true
      desc_esc(ctl) # armed against "THEIRS"
      session.store.set_setting(ProjectView::DESC_KEY, "NEWER").should be_true
      desc_ctrl_w(ctl)
      ctl.view.desc_text.should eq("NEWER") # the peer's text, as it stands now, is on screen
      ctl.view.desc_insert_mode?.should be_false
      # A fresh edit that meets the armed bytes again must be refused, not written by the old arm.
      ctl.editor_enter_insert
      ctl.view.replace_desc("second")
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS").should be_true
      desc_esc(ctl)
      session.store.setting(ProjectView::DESC_KEY).should eq("THEIRS")
      ctl.view.desc_text.should eq("second")
      host.statuses.count(&.includes?("esc overwrites, ^W theirs")).should eq(2)
    end
  end

  it "announces a peer's write over the draft once, while the operator is still typing" do
    TuiContract.with_session("project-description-announce") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.on_external_change
      host.statuses.should be_empty # nothing typed, nothing to warn about
      ctl.view.replace_desc("mine")
      ctl.on_external_change
      host.statuses.should be_empty # typed, but the stored row has not moved
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS").should be_true
      ctl.on_external_change
      ctl.on_external_change # the tick fires on our own captures too
      host.statuses.count(&.includes?("description changed elsewhere")).should eq(1)
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS, REVISED").should be_true
      ctl.on_external_change
      host.statuses.count(&.includes?("description changed elsewhere")).should eq(2)
    end
  end
end

# ^W is a delete-word reflex (`LineEdit`, vim), so it may only take theirs while a refusal is
# armed — and then as one undoable edit, so a stray press costs a ^Z, never the draft.
describe "Project description ^W" do
  it "does nothing to the draft when no refusal is armed" do
    TuiContract.with_session("project-description-ctrl-w-unarmed") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.view.replace_desc("my draft")
      ctl.body_hint(:body).should end_with("esc save")
      ctl.body_hint(:body).should_not contain("^W")
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS").should be_true
      desc_ctrl_w(ctl) # a conflict exists, but nothing has refused yet
      ctl.view.desc_text.should eq("my draft")
      ctl.view.desc_insert_mode?.should be_true
    end
  end

  it "takes theirs as one undoable edit, so ^Z brings the draft back" do
    TuiContract.with_session("project-description-ctrl-w-undo") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.view.replace_desc("my draft")
      session.store.set_setting(ProjectView::DESC_KEY, "THEIRS").should be_true
      desc_esc(ctl)
      ctl.body_hint(:body).should end_with("esc overwrites · ^W theirs")
      desc_ctrl_w(ctl)
      ctl.view.desc_text.should eq("THEIRS")
      ctl.view.desc_insert_mode?.should be_false
      ctl.editor_undo.should be_true
      ctl.view.desc_text.should eq("my draft")
      # Back over the version the operator has now seen, so the next save is an ordinary one.
      ctl.editor_enter_insert
      desc_esc(ctl)
      session.store.setting(ProjectView::DESC_KEY).should eq("my draft")
    end
  end
end

describe "Project conflict and settings toasts" do
  it "fit the 59-column status line" do
    {ProjectController::DESC_PEER_CHANGED, ProjectController::DESC_REFUSED,
     ProjectController::DESC_CONFLICT, ProjectController::DESC_BUSY,
     IssuesController::NOTES_PEER_CHANGED, IssuesController::NOTES_REFUSED,
     IssuesController::NOTES_CONFLICT, IssuesController::NOTES_BUSY,
     IssuesController::NOTES_ISSUE_DELETED}.each do |toast|
      toast.size.should be <= 59
    end
  end

  it "keeps a settings leave-drop toast inside 59 columns, long typed value included" do
    TuiContract.with_session("project-settings-drop-toast") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      ctl.view.select_setting(11) # Connect timeout (s)
      6.times { settings_key(ctl, Termisu::Input::Key::Backspace) }
      settings_type(ctl, "not-a-number-at-all")
      ctl.view.select_setting(12) # Idle timeout (s): a valid edit beside it
      settings_type(ctl, "0")
      14.times { settings_key(ctl, Termisu::Input::Key::Up) }
      host.applied.size.should eq(1)
      host.statuses.last.should eq(%(connect timeout "not-a…" invalid — dropped · network saved))
      host.statuses.last.size.should be <= 59
    end
  end

  it "keeps a drop-everything toast inside 59 columns" do
    TuiContract.with_session("project-settings-drop-all-toast") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      # A stored upstream the parser refuses, so no typed edit can be blamed for it.
      ctl.view.spec_seed_stored("ftp://nope", {2 => "Invalid · ftp://nope"})
      ctl.view.select_setting(11)
      settings_type(ctl, "5")
      14.times { settings_key(ctl, Termisu::Input::Key::Up) }
      host.applied.should be_empty
      host.statuses.last.should eq("upstream proxy invalid — all network edits dropped")
      host.statuses.last.size.should be <= 59
    end
  end
end

module Gori::Tui
  class ProjectView
    # Seed the card as if this project had stored `raw` as its upstream: the baseline is what
    # the pane loaded, so `settings_dirty?` starts false.
    def spec_seed_stored(raw : String, values : Hash(Int32, String)) : Nil
      values.each { |i, v| @set_values[i] = v }
      @set_upstream_raw = raw
      @set_baseline = settings_values
    end
  end
end

describe "Project settings leave, auth beside a proxy change" do
  # Stored: an HTTP proxy with auth on. The operator turns the proxy off AND fixes the username,
  # then leaves. Reverting AUTH first dropped the username fix and still refused (auth needs a
  # proxy); the proxy is what that refusal is about, and a revert that does not clear it is
  # put back rather than blamed.
  it "blames the proxy for 'requires an upstream proxy' and keeps the username fix" do
    TuiContract.with_session("project-settings-auth-proxy") do |session|
      host = ApplySpyHost.new(session)
      host.tab = :project
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.view.focus_pane(:settings)
      ctl.view.spec_seed_stored("http://proxy.test:8080",
        {2 => "HTTP", 3 => "proxy.test", 4 => "8080", 6 => "on", 7 => "u", 8 => "p"})
      ctl.view.settings_dirty?.should be_false
      ctl.view.@set_values[2] = "None"
      ctl.view.@set_values[7] = "u2"
      ctl.view.select_setting(13)
      16.times { settings_key(ctl, Termisu::Input::Key::Up) }
      host.applied.size.should eq(1)
      host.applied.last.upstream.should eq("http://proxy.test:8080")
      host.applied.last.auth.try(&.username).should eq("u2")
      toast = host.statuses.last
      toast.should eq("upstream proxy invalid for auth — dropped · network saved")
      toast.size.should be <= 59
    end
  end
end
