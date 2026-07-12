require "./screen"
require "./theme"

module Gori::Tui
  # The Help tab: a static, scrollable keyboard + mouse cheat-sheet. Read-only —
  # ↑/↓ (or the wheel) scroll; there's nothing to select. The content is curated
  # from the same shortcuts the status bar hints advertise, grouped by area.
  class HelpView
    # One rendered line: a section :head, a key/desc :item, or a blank :gap.
    record Row, kind : Symbol, a : String, b : String

    # Left key column width + gap before the description. Long enough for labels like
    # "palette / settings" / "Settings: Hotkeys" so they don't run into the desc text.
    KEY_W = 20
    KEY_GAP =  2

    # {section title, [{keys, description}, ...]} — the source of the rendered rows.
    SECTIONS = [
      {"GLOBAL", [
        {"^P", "command palette"},
        {"space", "focus-area action menu"},
        {"c", "toggle capture"},
        {"s · m", "toggle scope lens (or click scope:N) · Match & Replace rules"},
        {"n", "notification center (or click the notify:N badge)"},
        {"^B", "reveal whitespace (·→␍␊)"},
        {"^D / ^C ×2", "quit gori"},
        {"q", "back to projects (on the tab bar)"},
        {"Settings: Hotkeys", "rebind any shortcut below (^P → Settings: Hotkeys)"},
      ]},
      {"TABS & FOCUS", [
        {"←/→", "switch tab (on the tab bar)"},
        {"↹ / ⇧↹", "focus ring: tab bar ↔ panes"},
        {"↵ / ↓", "enter the tab body"},
        {"1-9", "jump to the Nth visible tab"},
        {"Settings: Tabs", "show/hide + reorder tabs"},
        {"esc", "pop back to the tab bar"},
      ]},
      {"MOUSE", [
        {"click tab", "switch to it"},
        {"click row", "select · click again opens"},
        {"click pane", "focus · in an editor, place the caret"},
        {"sub-tab chip", "switch · right-click renames (Replay/Fuzzer/Convert)"},
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
        {"detail", "↑/↓ move · ⇧arrows select · y copy · space cmds · ⇧←/→ h-scroll"},
        {"x · b · p", "in detail: hex · whitespace · pretty bodies"},
      ]},
      {"REPLAY", [
        {"^R", "send the request"},
        {"^N / ^W", "new / close a sub-tab"},
        {"r", "rename the sub-tab (on the strip)"},
        {"i / ↵", "enter INS (edit) on request/target · esc back to READ"},
        {"space", "command menu (READ mode on request/target/response)"},
        {"y · O", "copy selection/line · copy all pane (READ)"},
        {"⇧arrows", "select text (line or char)"},
        {"^X", "hex-edit the request"},
        {"^S", "SNI override (on the target)"},
        {"^L", "toggle auto Content-Length"},
        {"↹", "cycle target → request → response"},
        {"x · d · p", "response: hex · diff · pretty"},
        {"⇧←/→", "response: scroll a long line sideways"},
      ]},
      {"FUZZER", [
        {"⇧I", "send a flow/replay here (History/Replay)"},
        {"^N / ^W", "new / close a sub-tab"},
        {"i / ↵", "enter INS (edit) on target/template · esc back to READ"},
        {"space", "command menu (READ mode on target/template/results/detail)"},
        {"y · O", "copy selection/line · copy all pane (READ)"},
        {"⇧arrows", "select text (line or char)"},
        {"^A · ^K · ^T · ^U", "auto-mark params · mark word · mark point (manual §) · clear §"},
        {"^O", "focus the config pane (payload sets · Mode · Advanced · Run)"},
        {"config", "↑/↓ rows · ↵ edit a set / Add / Advanced / Run · ←/→ Mode · Del remove a set"},
        {"^L", "add a List payload set (one value per line, paste splits)"},
        {"set editor", "↹/↑↓ fields · List = multi-line · wordlist path auto-completes · esc applies"},
        {"^R · ^X", "run · stop"},
        {"↑/↓ · ↵", "results: select · open detail"},
        {"o · m", "sort · matched-only"},
        {"r", "rename the sub-tab (on the strip)"},
        {"⇧←/→", "detail: scroll a long line sideways"},
      ]},
      {"COMPARER", [
        {"a · b", "pick flow A · flow B"},
        {"←/→", "compare requests ⟷ responses"},
        {"s", "swap A ⇄ B"},
        {"^N / ^W · r", "new / close / rename comparison sub-tab"},
        {"Send to Comparer", "from History (space menu) — fills the active sub-tab"},
      ]},
      {"EDITORS", [
        {"^G · ^F", "go to line · find"},
        {"^E", "open the field in $EDITOR"},
        {"^B", "reveal whitespace"},
      ]},
      {"OTHER TABS", [
        {"Sitemap", "↑/↓ · / filter · ↵/→ expand · t tag · g group · ⇧S scope"},
        {"Findings", "detail notes: i/↵ edit · x line · ⇧select · y copy · space cmds · ↑/↓ links"},
        {"Prism", "↑/↓ ↵ open · m mode · c dismiss · a all · / filter · ⇧S scope · space cmds"},
        {"Notes", "i/↵ edit · x line · ⇧arrows select · y copy · space cmds (Copy selected when highlighted)"},
        {"Project", "desc: i/↵ edit · x line · ⇧arrows select · y copy · space cmds"},
        {"Intercept", "↵/e edit · f fwd · d drop · F all · c catch dir · / condition · ⇧←/→ h-scroll preview"},
      ]},
      {"CONVERT", [
        {"i / ↵", "enter INS on INPUT · esc back to READ"},
        {"INPUT READ", "⇧arrows select · y copy · space cmds"},
        {"chain", "always editable — base64 > url-encode > sha256 ( > | , )"},
        {"↹ / ↵", "complete the suggested converter (popup)"},
        {"OUTPUT", "↑/↓ move · ⇧arrows select · y copy · ⇧←/→ h-scroll"},
        {"^Y · ^X", "copy all output · cycle text/hex/base64"},
        {"^S · ^O", "save chain by name · load a saved chain"},
        {"^N · ^W", "new · close conversion sub-tab"},
        {"^1-9 · r", "switch sub-tab · rename (on the strip)"},
        {"space", "command menu (on the sub-tab strip)"},
      ]},
      {"OVERLAYS", [
        {"palette / settings", "↑/↓ · ↵ · esc"},
        {"confirm", "←/→ choose · y / n · ↵"},
        {"Settings: Editor", "toggle mouse support (Mouse field)"},
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
        kw = {KEY_W, {rect.w - 3 - KEY_GAP, 1}.max}.min
        screen.text(rect.x + 2, y, row.a, Theme.text_bright, width: kw)
        dx = rect.x + 2 + KEY_W + KEY_GAP
        screen.text(dx, y, row.b, Theme.muted, width: {rect.right - dx - 1, 1}.max) if dx < rect.right - 1
        # :gap → blank line
      end
    end

    private def clamp_scroll(h : Int32) : Nil
      max = {@rows.size - h, 0}.max
      @scroll = @scroll.clamp(0, max)
    end

    # --- the "About" sub-tab page ---------------------------------------------
    # Static centered brand block: same art as the project picker, plus version,
    # author credit, and the repository URL (Links page removed — everything lives here).
    ART_GAP = 1 # blank row between the art and the wordmark (mirrors ProjectPicker)

    def render_about(screen : Screen, rect : Rect) : Nil
      return if rect.empty?
      # Text stack under the art: wordmark · version · blank · byline · github
      text_h = 5
      show_art = rect.h >= Brand::ART_H + ART_GAP + text_h + 1 && rect.w >= 32
      block_h = show_art ? Brand::ART_H + ART_GAP + text_h : text_h
      top = rect.y + {(rect.h - block_h) // 2, 0}.max

      if show_art
        Brand.draw_art(screen, Brand.art_origin_x(rect.x, rect.w), top)
        top += Brand::ART_H + ART_GAP
      end

      centered(screen, rect, top, "gori", Theme.accent, attr: Attribute::Bold)
      centered(screen, rect, top + 1, "v#{Gori::VERSION}", Theme.text_bright)
      centered(screen, rect, top + 3, Brand::BYLINE, Theme.muted) if top + 3 < rect.bottom
      centered(screen, rect, top + 4, Gori::REPOSITORY_URL, Theme.muted) if top + 4 < rect.bottom
    end

    # Back-compat alias (HelpController used to call render_version).
    def render_version(screen : Screen, rect : Rect) : Nil
      render_about(screen, rect)
    end

    # Horizontally center `text` on row `y` within `rect` (mirrors ProjectPicker).
    private def centered(screen : Screen, rect : Rect, y : Int32, text : String, fg : Color,
                         attr : Attribute = Attribute::None) : Nil
      x = rect.x + {(rect.w - text.size) // 2, 0}.max
      screen.text(x, y, text, fg, Theme.bg, attr: attr)
    end
  end
end
