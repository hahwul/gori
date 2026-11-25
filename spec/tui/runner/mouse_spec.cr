require "../../spec_helper"
require "../../support/memory_backend"

include Gori::Tui

private def mouse_code : String
  File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "tui", "runner", "mouse.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

# `Runner.new` owns a terminal and appears nowhere under spec/, so the press path is pinned by
# reading the source with comments stripped.
describe "Runner left press" do
  it "clears the toast's stamp with the toast, as a key does" do
    press = mouse_code[/private def press_left.*?\n  end/m].not_nil!
    press.should match(/@toast = nil\n\s*@toast_seen = nil/)
  end

  it "arms the pair swallow for a space-menu row it ran" do
    # A sticky family's card closes and reopens on a row click, and a family row descends
    # inside the same open menu: the modal layer reads the same before and after, so the row
    # click has to say so itself.
    body = mouse_code[/private def click_space_menu.*?\n  end/m].not_nil!
    arm = body.index!("@modal_pressed = true")
    arm.should be < body.index!("activate_space_entry")
  end
end

# The press path itself, with the tiers below it replaced by a script: each scripted press
# says what the screen does to the modal layer. Everything `press_left` decides — the
# double-click window, the swallow, the toast — runs as shipped.
private class PairRunner < Runner
  @clicks = 0
  @script = [] of Symbol
  getter clicks : Int32
  getter toast : String?

  def prepare : Nil
    @backend = MemoryBackend.new(80, 24)
    @overlay = OverlayKind::None
    @focus = :menu # off the body: an unswallowed pair falls back to a plain click
    @clicks = 0
    @script = [] of Symbol
  end

  def script(*steps : Symbol) : Nil
    @script = steps.to_a
  end

  def menu_open=(v : Bool) : Nil
    @space_menu_open = v
  end

  def press(mx : Int32 = 10, my : Int32 = 10) : Nil
    press_left(Layout.compute(80, 24), mx, my)
  end

  # Not taken, as a tab that implements no double-click answers. Stubbed rather than reached:
  # the real one types every controller's `handle_double_click`, and EvidenceController's asks
  # its Host for `evidence_open`, which FakeHost (loaded beside this file) does not have.
  private def dispatch_double_click(layout : Layout, mx : Int32, my : Int32) : Bool
    false
  end

  # :commit closes the card the press landed on and leaves a toast (a picker row, a confirm
  # button); :open raises one (a top-bar chip); :select touches nothing modal (a list row).
  private def dispatch_click(layout : Layout, mx : Int32, my : Int32) : Nil
    @clicks += 1
    case @script.shift? || :select
    when :commit
      @space_menu_open = false
      @toast = "status set"
    when :open
      @space_menu_open = true
    end
  end
end

describe "Runner double-click over a modal change" do
  it "swallows the press that pairs with one that committed a card, and keeps its toast" do
    r = PairRunner.allocate
    r.prepare
    r.menu_open = true
    r.script(:commit, :select)
    r.press
    r.press # same cell, inside the window: the other half of the double-click
    r.clicks.should eq(1)
    r.toast.should eq("status set")
  end

  it "swallows the press that pairs with one that opened a card" do
    r = PairRunner.allocate
    r.prepare
    r.script(:open, :commit)
    r.press
    r.press # would be click-away on the card the first press opened
    r.clicks.should eq(1)
  end

  it "leaves a double-click that changed no modal to the ordinary path" do
    r = PairRunner.allocate
    r.prepare
    r.script(:select, :select)
    r.press
    r.press
    r.clicks.should eq(2)
  end

  it "swallows only the paired press: a third press is a fresh click" do
    r = PairRunner.allocate
    r.prepare
    r.menu_open = true
    r.script(:commit, :select)
    r.press
    r.press
    r.press
    r.clicks.should eq(2)
    r.toast.should be_nil # a press the shell acted on clears the toast, as a key does
  end

  it "does not swallow a press in another cell" do
    r = PairRunner.allocate
    r.prepare
    r.menu_open = true
    r.script(:commit, :select)
    r.press(10, 10)
    r.press(11, 10)
    r.clicks.should eq(2)
  end
end
