require "./screen"
require "./theme"
require "./brand"
require "../hotkeys"

module Gori::Tui
  # The Help tab: a scrollable keyboard + mouse cheat-sheet. Read-only —
  # ↑/↓ (or the wheel) scroll; there's nothing to select. When constructed with a
  # registry, rebindable rows resolve their key column through Hotkeys (same path
  # as the command palette) so a rebind is reflected here.
  class HelpView
    # One rendered line: a section :head, a key/desc :item, or a blank :gap.
    record Row, kind : Symbol, a : String, b : String

    # Left key column width + gap before the description. Long enough for labels like
    # "palette / settings" / "Settings: Hotkeys" so they don't run into the desc text.
    KEY_W = 20
    KEY_GAP =  2

    # `verb_id` non-nil ⇒ resolve the key label from the effective keymap at build time.
    record Item, key : String, desc : String, verb_id : String? = nil

    # {section title, items} — the source of the rendered rows.
    SECTIONS = [
      {"GLOBAL", [
        Item.new("^P", "command palette", "app.palette"),
        Item.new("space", "focus-area action menu"),
        Item.new("c", "toggle capture", "capture.toggle"),
        Item.new("i", "toggle intercept", "intercept.toggle"),
        Item.new("s", "toggle scope lens (or click scope:N)", "scope.toggle-lens"),
        Item.new("^P", "Match & Replace (palette; rebindable)", "rules.edit"),
        Item.new("badge / ^P", "notification center (palette; rebindable)", "app.notifications"),
        Item.new("^B", "reveal whitespace (·→␍␊)", "view.reveal-ws"),
        Item.new("^D / ^C ×2", "quit gori"),
        Item.new("q", "back to projects (on the tab bar)"),
        Item.new("?", "open this Help tab", "tab.help"),
        Item.new("Settings: Hotkeys", "rebind any shortcut below (^P → Settings: Hotkeys)"),
      ]},
      {"TABS & FOCUS", [
        Item.new("←/→", "switch tab (on the tab bar)"),
        Item.new("↹ / ⇧↹", "focus ring: tab bar ↔ panes"),
        Item.new("↵ / ↓", "enter the tab body"),
        Item.new("1-9", "jump to the Nth visible tab"),
        Item.new("Settings: Tabs", "show/hide + reorder tabs"),
        Item.new("esc", "pop back to the tab bar"),
      ]},
      {"MOUSE", [
        Item.new("click tab", "switch to it"),
        Item.new("click row", "select · click again opens"),
        Item.new("click pane", "focus · in an editor, place the caret"),
        Item.new("sub-tab chip", "switch · right-click renames (Repeater/Fuzzer/Decoder)"),
        Item.new("wheel", "scroll / move the selection"),
        Item.new("click outside", "close a popup"),
      ]},
      {"HISTORY", [
        Item.new("↑/↓ · ↵", "move · open the flow"),
        Item.new("^R", "send the flow to Repeater", "history.repeater"),
        Item.new("⇧I", "send the flow to the Fuzzer", "history.fuzz"),
        Item.new("⇧F", "create a finding", "finding.create"),
        Item.new("f", "follow newest", "history.toggle-follow"),
        Item.new("/", "filter (query language)", "history.query"),
        Item.new("y", "copy flow", "history.copy"),
        Item.new("i", "toggle intercept hold-mode", "intercept.toggle"),
        Item.new("detail", "↑/↓ move · ⇧arrows select · y copy · space cmds · ⇧←/→ h-scroll"),
        Item.new("x · b · p", "in detail: hex · whitespace · pretty bodies"),
      ]},
      {"REPEATER", [
        Item.new("^R", "send the request", "repeater.send"),
        Item.new("^N / ^W", "new / close a sub-tab"),
        Item.new("r", "rename the sub-tab (on the strip)"),
        Item.new("/", "filter sub-tabs (tag: name: host: method:)", "repeater.filter-subtabs"),
        Item.new("↹", "complete filter field/value while filtering"),
        Item.new("t", "tag the active sub-tab (on the strip)", "repeater.tag-subtab"),
        Item.new("i / ↵", "enter INS (edit) on request/target · esc back to READ"),
        Item.new("space", "command menu (READ mode on request/target/response)"),
        Item.new("y", "copy selection/line (READ)", "repeater.copy"),
        Item.new("⇧arrows", "select text (line or char)"),
        Item.new("^X", "hex-edit the request", "repeater.toggle-hex"),
        Item.new("^S", "SNI override (on the target)", "repeater.toggle-sni"),
        Item.new("^L", "toggle auto Content-Length", "repeater.toggle-auto-content-length"),
        Item.new("^V", "toggle transport HTTP/1.1 ↔ HTTP/2", "repeater.toggle-http2"),
        Item.new("space → g", "send group: %%%-split requests on one connection"),
        Item.new("↹", "cycle target → request → response"),
        Item.new("d", "response: toggle diff", "repeater.toggle-diff"),
        Item.new("p", "response: pretty bodies", "repeater.toggle-pretty"),
        Item.new("x", "response: hex dump (pane-local)"),
        Item.new("⇧←/→", "response: scroll a long line sideways"),
      ]},
      {"FUZZER", [
        Item.new("⇧I", "send a flow/repeater here (History/Repeater)"),
        Item.new("^N / ^W", "new / close a sub-tab"),
        Item.new("i / ↵", "enter INS (edit) on target/template · esc back to READ"),
        Item.new("space", "command menu (READ mode on target/template/results/detail)"),
        Item.new("y · O", "copy selection/line · copy all pane (READ)"),
        Item.new("⇧arrows", "select text (line or char)"),
        Item.new("^A · ^K · ^T · ^U", "auto-mark params · mark word · mark point (manual §) · clear §"),
        Item.new("^V", "toggle transport HTTP/1.1 ↔ HTTP/2"),
        Item.new("^O", "focus the config pane (payload sets · Mode · Advanced · Run)"),
        Item.new("config", "↑/↓ rows · ↵ edit a set / Add / Advanced / Run · ←/→ Mode · Del remove a set"),
        Item.new("^L", "add a List payload set (one value per line, paste splits)"),
        Item.new("set editor", "↹/↑↓ fields · List = multi-line · wordlist path auto-completes · esc applies"),
        Item.new("^R · ^X", "run · stop"),
        Item.new("↑/↓ · ↵", "results: select · open detail"),
        Item.new("o · m", "sort · matched-only"),
        Item.new("r", "rename the sub-tab (on the strip)"),
        Item.new("⇧←/→", "detail: scroll a long line sideways"),
      ]},
      {"COMPARER", [
        Item.new("a · b", "pick flow A · flow B"),
        Item.new("←/→", "compare requests ⟷ responses"),
        Item.new("s", "swap A ⇄ B"),
        Item.new("^N / ^W · r", "new / close / rename comparison sub-tab"),
        Item.new("Send to Comparer", "from History (space menu) — fills the active sub-tab"),
      ]},
      {"EDITORS", [
        Item.new("^G · ^F", "go to line · find"),
        Item.new("^E", "open the field in $EDITOR"),
        Item.new("^B", "reveal whitespace"),
      ]},
      {"OTHER TABS", [
        Item.new("Sitemap", "↑/↓ · / filter · ↵/→ expand · t tag · g group · ⇧S scope"),
        Item.new("Findings", "detail notes: i/↵ edit · x line · ⇧select · y copy · space cmds · ↑/↓ links"),
        Item.new("Probe", "↑/↓ ↵ open · m mode · c dismiss · a all · / filter · ⇧S scope · space cmds"),
        Item.new("Notes", "i/↵ edit · x line · ⇧arrows select · y copy · space cmds (Copy selected when highlighted)"),
        Item.new("Project", "desc: i/↵ edit · x line · ⇧arrows select · y copy · space cmds"),
        Item.new("Intercept", "↵/e edit · f fwd · d drop · ⇧F all · c catch · / condition · i on/off · ⇧←/→ h-scroll"),
      ]},
      {"DECODER", [
        Item.new("i / ↵", "enter INS on INPUT · esc back to READ"),
        Item.new("INPUT READ", "⇧arrows select · y copy · space cmds"),
        Item.new("chain", "always editable — base64 > url-encode > sha256 ( > | , )"),
        Item.new("↹ / ↵", "complete the suggested converter (popup)"),
        Item.new("OUTPUT", "↑/↓ move · ⇧arrows select · y copy · ⇧←/→ h-scroll"),
        Item.new("^Y · ^X", "copy all output · cycle text/hex/base64"),
        Item.new("^S · ^O", "save chain by name · load a saved chain"),
        Item.new("^N · ^W", "new · close conversion sub-tab"),
        Item.new("^1-9 · r", "switch sub-tab · rename (on the strip)"),
        Item.new("space", "command menu (on the sub-tab strip)"),
      ]},
      {"OVERLAYS", [
        Item.new("palette / settings", "↑/↓ · ↵ · esc"),
        Item.new("confirm", "←/→ choose · y / n · ↵"),
        Item.new("Settings: Editor", "toggle mouse support (Mouse field)"),
      ]},
    ]

    @rows : Array(Row)
    @scroll : Int32 = 0

    def initialize(registry : Verb::Registry? = nil)
      @rows = build_rows(registry)
    end

    # Rebuild from the live registry (call after a hotkeys save so Help stays honest).
    def reload(registry : Verb::Registry) : Nil
      @rows = build_rows(registry)
      @scroll = 0
    end

    private def build_rows(registry : Verb::Registry?) : Array(Row)
      rows = [] of Row
      SECTIONS.each_with_index do |(title, items), si|
        rows << Row.new(:gap, "", "") if si > 0
        rows << Row.new(:head, title, "")
        items.each do |item|
          key = item.key
          if (id = item.verb_id) && registry
            key = Hotkeys.binding_label(registry, id, item.key)
          end
          rows << Row.new(:item, key, item.desc)
        end
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

      centered(screen, rect, top, "gori", Theme.focus_gold, attr: Attribute::Bold)
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
