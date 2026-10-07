require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "./text_field"
require "./hosts_overlay"
require "../settings"
require "../env"
require "../plural"

module Gori::Tui
  # Global environment-variable editor (settings:env). Edits a working copy of the
  # prefix sigil + {key, value} pairs; the Runner persists to Settings on every
  # mutation. Entry form: "KEY VALUE" or "KEY=value".
  class EnvOverlay < PairListOverlay
    # The token grammar this install reads, READ-ONLY here and read LIVE — not a working copy
    # like the prefix beside it. Switching it has to re-spell the tokens already stored in
    # project DBs, in drafts, in rule replacements and in slot headers; a key on this card could
    # only set the setting and leave those bytes mis-spelled, so the switch is
    # `gori settings env-syntax` alone. The card still NAMES the grammar, because `HOST →
    # api.test` reads the same whether the editors resolve `$HOST` or `$ENV.HOST`.
    def syntax : Env::Syntax
      Settings.env_syntax
    end

    def initialize
      @prefix = Settings.env_prefix
      # The prefix row is a second inline editor, sharing the add/edit row's `@field` — they
      # are never open at once.
      @prefix_editing = false
      reset
    end

    def reset : Nil
      @items = Settings.env_vars.dup
      @prefix = Settings.env_prefix
      @selected = 0
      cancel_add
      cancel_prefix_edit
    end

    # The PREFIX and the vars, and deliberately not the syntax: this card does not edit the
    # grammar, and it reads it live. Widening the tuple would break every caller for no gain.
    def to_config : {String, Array({String, String})}
      {@prefix, @items}
    end

    def prefix_editing? : Bool
      @prefix_editing
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Env
    end

    def title : String
      "ENVIRONMENT"
    end

    def hint : String
      return "type prefix · ↵ save · esc cancel" if @prefix_editing
      return %(type "KEY VALUE" · ↵ save · esc cancel) if @adding
      "↑/↓ select · a add · ↵/e edit · d delete · p prefix · esc close"
    end

    # The list keys plus `p`, which edits the prefix sigil — a second sub-mode that, like the
    # add/edit row, owns every key while open.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      return handle_prefix_key(ev) if @prefix_editing
      super
    end

    private def handle_list_char(c : Char?) : Nil
      c == 'p' ? prefix_edit_start : super
    end

    private def handle_prefix_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      if key.escape?
        cancel_prefix_edit
      elsif key.enter?
        commit_prefix_and_persist
      elsif key.backspace?
        # The empty check comes BEFORE the field sees the key: `TextField#backspace` on an
        # empty value is a silent no-op, and ⌫ on an empty row means "I am done here".
        cancel_prefix_edit unless backspace
      else
        @field.handle_edit_key(ev)
      end
      :stay
    end

    private def commit_prefix_and_persist : Nil
      case commit_prefix
      when :empty then toast("env prefix: empty")
      when :ok
        toast(persist ? "env prefix saved — #{@prefix.inspect}" : "prefix applied — could not save to #{Settings.path}")
      end
    end

    # "KEY VALUE" or "KEY=value".
    private def parse_entry(text : String) : {String, String}?
      Env.parse_line(text)
    end

    private def entry_text(a : String, b : String) : String
      "#{a} #{b}"
    end

    private def noun : String
      "env var"
    end

    private def invalid_toast : String
      %(env var: need "KEY VALUE" or "KEY=value" — KEY is [A-Za-z_][A-Za-z0-9_]*)
    end

    private def dup_toast : String
      "env var: KEY already defined — edit it (e)"
    end

    private def empty_text : String
      "no env vars — press a to add"
    end

    private def too_small_what : String
      "env editor needs a larger window"
    end

    private def row_open? : Bool
      @adding || @prefix_editing
    end

    private def cancel_row : Bool
      return super unless @prefix_editing
      cancel_prefix_edit
      true
    end

    # The list holds still while an inline editor is open.
    def move(d : Int32) : Nil
      super unless row_open?
    end

    def prefix_edit_start : Nil
      cancel_add
      @prefix_editing = true
      @field.set(@prefix)
    end

    def cancel_prefix_edit : Nil
      @prefix_editing = false
      @field.set("")
    end

    private def open_row(idx : Int32?, text : String) : Nil
      cancel_prefix_edit
      super
    end

    def commit_prefix : Symbol
      text = @field.value.strip
      return :empty if text.empty?
      @prefix = text
      cancel_prefix_edit
      :ok
    end

    def overlay_box(area : Rect) : Rect?
      rows = {@items.size + (@adding ? 1 : 0) + (@prefix_editing ? 1 : 0), 6}.max
      area.card?(56, rows + 4, 28, 8)
    end

    # `global` in the meta, because this card has a TWIN: the Project tab's Env pane, with the
    # same title, holding a different list. This one is layered UNDER it (the project wins on
    # a clash), and an operator reading `ENVIRONMENT · no env vars` here while `$API` resolves
    # in the editor behind it has been told nothing about which of the two they are looking at.
    # Same word the Rewriter and Colormarker rows carry as `G`.
    # The live SPELLING rides the meta line, because it is the one thing about this card that
    # an operator cannot infer from the rows: `HOST → api.test` reads the same whether the
    # editor two tabs over resolves `$HOST` or `$ENV.HOST`.
    private def meta : String
      "global · #{Env.spell("KEY", Env::Namespace::Env, syntax, @prefix)} · " \
      "#{Gori.plural(@items.size, "var")}"
    end

    private def header_rows : Int32
      2
    end

    private def draw_header(screen : Screen, box : Rect) : Nil
      draw_prefix_row(screen, box, box.y + 1)
      screen.text(box.x + 3, box.y + 2, "KEY VALUE · e.g. HOST api.example.com", Theme.muted, Theme.panel, width: {box.w - 5, 1}.max)
    end

    private def draw_prefix_row(screen : Screen, box : Rect, py : Int32) : Nil
      bg = @prefix_editing ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      x = box.x + 3
      if @prefix_editing
        x = screen.text(x, py, "prefix ", Theme.accent, bg)
        w = {box.right - 1 - x, 3}.max
        @field.render(screen, x, py, w, true, Theme.text_bright, bg)
      else
        screen.text(x, py, "prefix ", Theme.muted, bg)
        x = screen.text(x + 7, py, @prefix, Theme.text_bright, bg, width: {box.right - x - 8, 1}.max)
        # The grammar sits on the SAME row as the sigil: they are the two halves of one
        # spelling, and the syntax on a row of its own read as a third kind of thing to edit.
        # It is REPORTED, not edited — `p` is the only key on this row.
        x = screen.text(x + 2, py, "syntax ", Theme.muted, bg) if box.right - 2 > x + 2
        screen.text(x, py, syntax.namespaced? ? "namespaced" : "bare", Theme.text_bright, bg,
          width: {box.right - 2 - x, 0}.max)
        # Only the key this row owns. The card is capped at 56 cells and the spelling eats most
        # of them, so `gori settings env-syntax` — the one way to change the value beside it —
        # would not fit here at any width; the docs carry it.
        hint = "p edit"
        screen.text({box.right - hint.size - 3, x + 1}.max, py, hint, Theme.muted, bg)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      key, val = @items[i]
      sel = i == @selected && !row_open?
      bg = Frame.row_band(screen, box, py, sel)
      kw = {box.w * 2 // 5, 8}.max
      screen.text(box.x + 3, py, key, Theme.syn_header, bg, width: kw)
      ax = box.x + 3 + kw
      screen.text(ax, py, "→ ", Theme.muted, bg) if box.right - 1 > ax
      vx = ax + 2
      draw_env_value(screen, vx, py, val, sel, bg, {box.right - 1 - vx, 1}.max)
    end

    private def draw_env_value(screen : Screen, x : Int32, y : Int32, val : String, sel : Bool, bg : Color, width : Int32) : Nil
      return if width <= 0
      line = Highlight.env_line(val, Theme.text)
      Highlight.draw(screen, x, y, line, width: width)
    end
  end
end
