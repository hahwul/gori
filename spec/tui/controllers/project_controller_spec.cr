require "../../support/tui_contract"

include Gori::Tui

describe ProjectController do
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
end
