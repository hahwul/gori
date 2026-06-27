require "./screen"
require "./theme"

module Gori::Tui
  # The Help tab: a static, scrollable keyboard + mouse cheat-sheet. Read-only —
  # ↑/↓ (or the wheel) scroll; there's nothing to select. The content is curated
  # from the same shortcuts the status bar hints advertise, grouped by area.
  class HelpView
    # One rendered line: a section :head, a key/desc :item, or a blank :gap.
    record Row, kind : Symbol, a : String, b : String

    KEY_W = 16 # left key column width before the description

    # {section title, [{keys, description}, ...]} — the source of the rendered rows.
    SECTIONS = [
      {"GLOBAL", [
        {"^P", "command palette"},
        {"space", "focus-area action menu"},
        {"c", "toggle capture"},
        {"^B", "reveal whitespace (·→␍␊)"},
        {"^D / ^C ×2", "quit gori"},
        {"q", "back to projects (on the tab bar)"},
        {"settings:hotkeys", "rebind any shortcut below (^P → settings:hotkeys)"},
      ]},
      {"TABS & FOCUS", [
        {"←/→", "switch tab (on the tab bar)"},
        {"↹ / ⇧↹", "focus ring: tab bar ↔ panes"},
        {"↵ / ↓", "enter the tab body"},
        {"1-9", "jump to the Nth visible tab"},
        {"settings:tabs", "show/hide + reorder tabs"},
        {"esc", "pop back to the tab bar"},
      ]},
      {"MOUSE", [
        {"click tab", "switch to it"},
        {"click row", "select · click again opens"},
        {"click pane", "focus · in an editor, place the caret"},
        {"sub-tab chip", "switch · right-click renames (Replay/Fuzzer)"},
        {"wheel", "scroll / move the selection"},
        {"click outside", "close a popup"},
      ]},
      {"HISTORY", [
        {"↑/↓ · ↵", "move · open the flow"},
        {"^R", "send the flow to Replay"},
        {"⇧I", "send the flow to the Fuzzer"},
        {"⇧F", "create a finding"},
        {"f · /", "follow newest · filter (query language)"},
        {"i", "toggle intercept hold-mode"},
        {"x · b · p", "in a flow: hex · whitespace · pretty bodies"},
      ]},
      {"REPLAY", [
        {"^R", "send the request"},
        {"^N / ^W", "new / close a sub-tab"},
        {"r", "rename the sub-tab (on the strip)"},
        {"^X", "hex-edit the request"},
        {"^S", "SNI override (on the target)"},
        {"↹", "cycle target → request → response"},
        {"x · d · p", "response: hex · diff · pretty"},
      ]},
      {"FUZZER", [
        {"⇧I", "send a flow/replay here (History/Replay)"},
        {"^N / ^W", "new / close a sub-tab"},
        {"^A · ^K · ^T · ^U", "auto-mark params · mark word · mark point (manual §) · clear §"},
        {"^O", "focus the config pane (lands on Payload)"},
        {"config", "payload type/fields · ⏎ +add · ▸ Advanced (mode/engine/match/filter)"},
        {"wordlist path", "⇥/type to auto-complete from the dir + ~/.gori/wordlists"},
        {"^R · ^X", "run · stop"},
        {"↑/↓ · ↵", "results: select · open detail"},
        {"o · m", "sort · matched-only"},
        {"r", "rename the sub-tab (on the strip)"},
      ]},
      {"COMPARER", [
        {"a · b", "pick flow A · flow B"},
        {"←/→", "compare requests ⟷ responses"},
        {"s", "swap A ⇄ B"},
        {"Send to Comparer", "from History (space menu)"},
      ]},
      {"EDITORS", [
        {"^G · ^F", "go to line · find"},
        {"^E", "open the field in $EDITOR"},
        {"^B", "reveal whitespace"},
      ]},
      {"OTHER TABS", [
        {"Sitemap", "↑/↓ move · / filter · ↵/→ expand · ← collapse"},
        {"Findings", "/ filter · ↵ open · n new · space triage · x export"},
        {"Notes", "type to edit · ^N new · ^1-9 switch"},
        {"Project", "scope rules + the description editor"},
        {"Intercept", "↵/e edit · f fwd · d drop · F all · c catch dir · / condition"},
      ]},
      {"CONVERT", [
        {"type / ↹", "edit input · switch input ↔ chain"},
        {"chain", "base64 > url-encode > sha256 ( > | , )"},
        {"↹ / ↵", "complete the suggested converter (popup)"},
        {"^Y · ^X", "copy output · cycle text/hex/base64"},
        {"^S · ^O", "save chain by name · load a saved chain"},
        {"^N · ^W", "new · close conversion sub-tab"},
        {"^1-9 · r", "switch sub-tab · rename (on the strip)"},
        {"space", "command menu (on the sub-tab strip)"},
      ]},
      {"OVERLAYS", [
        {"palette / settings", "↑/↓ · ↵ · esc"},
        {"confirm", "←/→ choose · y / n · ↵"},
        {"settings: mouse", "toggle mouse support on/off"},
      ]},
    ]

    @rows : Array(Row)
    @scroll : Int32 = 0

    def initialize
      @rows = build_rows
    end

    private def build_rows : Array(Row)
      rows = [] of Row
      SECTIONS.each_with_index do |(title, items), si|
        rows << Row.new(:gap, "", "") if si > 0
        rows << Row.new(:head, title, "")
        items.each { |(k, d)| rows << Row.new(:item, k, d) }
      end
      rows
    end

    # Scroll by `delta` lines (the wheel + ↑/↓). render clamps the floor; the top
    # clamp lands in clamp_scroll so a tall pane never scrolls past the last line.
    def move(delta : Int32) : Nil
      @scroll = {@scroll + delta, 0}.max
    end

    # The Runner pops focus to the tab bar when ↑ is pressed at the top (like the lists).
    def at_top? : Bool
      @scroll == 0
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      clamp_scroll(rect.h)
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= @rows.size
        draw_row(screen, rect, rect.y + i, @rows[li])
      end
    end

    private def draw_row(screen : Screen, rect : Rect, y : Int32, row : Row) : Nil
      case row.kind
      when :head
        screen.text(rect.x + 1, y, row.a, Theme.accent, attr: Attribute::Bold, width: {rect.w - 2, 1}.max)
      when :item
        screen.text(rect.x + 2, y, row.a, Theme.text_bright, width: {KEY_W, {rect.w - 3, 1}.max}.min)
        dx = rect.x + 2 + KEY_W
        screen.text(dx, y, row.b, Theme.muted, width: {rect.right - dx - 1, 1}.max) if dx < rect.right - 1
        # :gap → blank line
      end
    end

    private def clamp_scroll(h : Int32) : Nil
      max = {@rows.size - h, 0}.max
      @scroll = @scroll.clamp(0, max)
    end
  end
end
