require "../../spec_helper"
require "../../support/memory_backend"

class Gori::Tui::NotesController
  def attach_preedit_note_for_spec(view : Gori::Tui::NotesView) : Nil
    @notes = view
  end
end

# Keep the production event funnel and preedit routing; only replace terminal-dependent
# key/mouse dispatch with the mode/focus transitions being exercised.
private class PreeditRunner < Gori::Tui::Runner
  def prepare(view : Gori::Tui::NotesView) : Nil
    controller = Gori::Tui::NotesController.allocate
    controller.attach_preedit_note_for_spec(view)
    @tabs = {:notes => controller.as(Gori::Tui::TabController)}
    @active_tab = :notes
    @focus = :body
    @overlay = Gori::Tui::OverlayKind::None
    @paste_newline = Gori::Tui::PasteNewline.new
    @paste_stall = Gori::Tui::PasteStall.new
    @backend = MemoryBackend.new(80, 24)
  end

  def feed(event : Termisu::Event::Any) : Nil
    handle(event)
  end

  private def handle_key(event : Termisu::Event::Key) : Nil
    if event.key.back_tab?
      @focus = :subtabs
    else
      @tabs[:notes].handle_body_key(event)
    end
  end

  private def handle_mouse(event : Termisu::Event::Mouse) : Nil
    @focus = :subtabs if event.press? && !event.wheel?
  end
end

describe "Runner preedit lifecycle" do
  it "clears composition before Escape leaves insert mode or Tab changes focus" do
    {Termisu::Input::Key::Escape, Termisu::Input::Key::BackTab}.each do |key|
      view = Gori::Tui::NotesView.new
      view.enter_insert!
      runner = PreeditRunner.allocate
      runner.prepare(view)
      runner.feed(Termisu::Event::Preedit.new("ㅎ"))
      view.read_edit_buffer[0].@preedit.should eq("ㅎ")
      runner.feed(Termisu::Event::Key.new(key))
      runner.feed(Termisu::Event::Preedit.new(""))
      view.enter_insert!
      view.read_edit_buffer[0].@preedit.should eq("")
      view.current_text.should eq("")
      view.dirty?.should be_false
    end
  end

  it "clears composition before a click moves focus" do
    view = Gori::Tui::NotesView.new
    view.enter_insert!
    runner = PreeditRunner.allocate
    runner.prepare(view)
    runner.feed(Termisu::Event::Preedit.new("ㅎ"))
    runner.feed(Termisu::Event::Mouse.new(1, 1, Termisu::Event::Mouse::Button::Left))
    runner.feed(Termisu::Event::Preedit.new(""))
    view.read_edit_buffer[0].@preedit.should eq("")
    view.current_text.should eq("")
  end

  it "commits text once and clears composition before a newline or bulk paste" do
    view = Gori::Tui::NotesView.new
    view.enter_insert!
    runner = PreeditRunner.allocate
    runner.prepare(view)
    runner.feed(Termisu::Event::Preedit.new("ㅎ"))
    runner.feed(Termisu::Event::Key.new(Termisu::Input::Key::Unknown, char: '한'))
    view.current_text.should eq("한")
    runner.feed(Termisu::Event::Preedit.new("ㄱ"))
    runner.feed(Termisu::Event::Key.new(Termisu::Input::Key::Enter))
    view.read_edit_buffer[0].@preedit.should eq("")
    view.current_text.should eq("한\n")
    runner.feed(Termisu::Event::Preedit.new("ㄴ"))
    runner.feed(Termisu::Event::Key.new(Termisu::Input::Key::PasteStart))
    view.read_edit_buffer[0].@preedit.should eq("")
    runner.feed(Termisu::Event::Key.new(Termisu::Input::Key::LowerX, char: 'x'))
    view.current_text.should eq("한\n")
    runner.feed(Termisu::Event::Key.new(Termisu::Input::Key::PasteEnd))
    view.current_text.should eq("한\nx")
  end

  it "keeps composing through resize, pointer motion, wheel and release events" do
    view = Gori::Tui::NotesView.new
    view.enter_insert!
    runner = PreeditRunner.allocate
    runner.prepare(view)
    runner.feed(Termisu::Event::Preedit.new("ㅎ"))
    runner.feed(Termisu::Event::Resize.new(60, 12))
    runner.feed(Termisu::Event::Mouse.new(1, 1, Termisu::Event::Mouse::Button::Left, motion: true))
    runner.feed(Termisu::Event::Mouse.new(1, 1, Termisu::Event::Mouse::Button::WheelDown))
    runner.feed(Termisu::Event::Mouse.new(1, 1, Termisu::Event::Mouse::Button::Release))
    view.read_edit_buffer[0].@preedit.should eq("ㅎ")
    runner.feed(Termisu::Event::Preedit.new(""))
    view.read_edit_buffer[0].@preedit.should eq("")
  end
end
