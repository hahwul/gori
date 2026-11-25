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
      host.statuses.last.should contain(%(invalid capture limit "abc"))
      host.statuses.last.should contain("that edit dropped")
      host.statuses.last.should contain("project network saved")
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
      host.statuses.last.should contain("invalid idle timeout")
      host.statuses.last.should contain("that edit dropped")
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

describe "Project description conflict" do
  it "keeps the draft on passive commit and only reloads the saved text on confirmed discard" do
    TuiContract.with_session("project-description-conflict") do |session|
      host = ApplySpyHost.new(session)
      ctl = ProjectController.new(host)
      ctl.on_enter
      ctl.editor_enter_insert
      ctl.view.replace_desc("draft")
      session.store.set_setting(ProjectView::DESC_KEY, "peer").should be_true
      ctl.commit.should be_false
      host.confirms.should be_empty
      host.statuses.last.should contain("your draft")
      ctl.view.desc_text.should eq("draft")

      host.under_modal = -> {
        ctl.view.desc_text.should eq("draft")
        session.store.set_setting(ProjectView::DESC_KEY, "newer peer value").should be_true
        nil
      }
      ctl.editor_exit_insert.should be_true
      host.confirms.last[0].should eq("DESCRIPTION CHANGED")
      ctl.view.desc_text.should eq("newer peer value")
      ctl.view.desc_insert_mode?.should be_false
      ctl.commit.should be_true
    end
  end
end
