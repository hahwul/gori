require "../../spec_helper"
require "../../support/memory_backend"

include Gori::Tui

describe "find prompt layout" do
  it "keeps the query and replacement inputs visible at compact terminal widths" do
    {40, 55, 80}.each do |width|
      row = Layout.compute(width, 24).status
      {
        {"find › ", "no matches · tab replace · ↑↓/↵ step · esc done", "no matches"},
        {"find    › ", "no matches · tab edit find · ↑↓ step", "no matches"},
        {"replace › ", "↵ replace all · esc done", "replace all"},
      }.each do |(label, hint, essential)|
        field, fitted = Runner.find_row_layout(row, label, hint)
        fitted.should contain(essential)
        field.w.should be >= Runner::FIND_INPUT_MIN
        (field.right + 1 + Screen.draw_width(fitted)).should be <= row.right
        backend = MemoryBackend.new(width, 24)
        screen = Screen.new(backend)
        screen.input_line(field.x, field.y, "needle123", 9, "", Theme.text_bright, Theme.panel, width: field.w)
        backend.row(field.y).should contain("needle123")
      end
    end
  end
end

# The prompt normally runs inside a terminal-backed Runner. Keep its rendering, event funnel,
# and prompt dispatch while providing a memory screen and only the prompt's initial state.
private class FindPromptRunner < Runner
  getter search_cx : Int32
  getter search_replace_cx : Int32

  def prepare(value : String, caret : Int32, *, replace : Bool = false) : Nil
    @backend = MemoryBackend.new(40, 24)
    @paste_newline = PasteNewline.new
    @paste_stall = PasteStall.new
    @overlay = OverlayKind::None
    @search_open = true
    @search_target = :notes
    @search_buffer = value
    @search_cx = caret
    @search_replace = replace
    @search_replace_buffer = value
    @search_replace_cx = caret
    @search_preedit = ""
    @search_hits = [] of {Int32, Int32}
  end

  def paint : String
    layout = Layout.compute(40, 24)
    render_search_prompt(Screen.new(@backend), layout.status)
    @backend.as(MemoryBackend).row(layout.status.y)
  end

  def feed(ev : Termisu::Event::Any) : Nil
    handle(ev)
  end

  private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
    dispatch_click(Layout.compute(40, 24), ev.x - 1, ev.y - 1)
  end
end

describe "find prompt pointer input" do
  it "uses the painted scroll offset to position the caret in the query and replacement" do
    value = "0123456789abcdefghijklmnopqrstuvwxyz"
    [false, true].each do |replace|
      runner = FindPromptRunner.allocate
      runner.prepare(value, value.size, replace: replace)
      row = runner.paint
      x = row.index('z').not_nil!
      runner.feed(Termisu::Event::Mouse.new(x + 1, 23, Termisu::Event::Mouse::Button::Left))
      (replace ? runner.search_replace_cx : runner.search_cx).should eq(value.size - 1)
    end
  end

  it "does not remap a click on IME composition to an unrelated committed character" do
    runner = FindPromptRunner.allocate
    runner.prepare("abcdef", 2)
    runner.feed(Termisu::Event::Preedit.new("한"))
    row = runner.paint
    row.should contain("ab한")
    x = row.index('c').not_nil!
    runner.feed(Termisu::Event::Mouse.new(x + 1, 23, Termisu::Event::Mouse::Button::Left))
    runner.search_cx.should eq(2)
    row = runner.paint
    x = row.index('e', row.index("abcdef").not_nil!).not_nil!
    runner.feed(Termisu::Event::Mouse.new(x + 1, 23, Termisu::Event::Mouse::Button::Left))
    runner.search_cx.should eq(4)
  end
end
