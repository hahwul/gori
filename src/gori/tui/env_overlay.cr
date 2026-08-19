require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "./text_field"
require "./overlay"
require "../settings"
require "../env"

module Gori::Tui
  # Global environment-variable editor (settings:env). Edits a working copy of the
  # prefix sigil + {key, value} pairs; the Runner persists to Settings on every
  # mutation. Entry form: "KEY VALUE" or "KEY=value".
  class EnvOverlay < Overlay
    # Injected at the open-site (Runner#open_settings). Like the Hostnames editor this one
    # persists on every mutation rather than on ↵, so esc just closes and the base
    # `on_commit` is never reached; `on_save` reports whether the write landed.
    property on_palette : Proc(Nil)?
    property on_save : Proc(Bool)?
    property on_toast : Proc(String, Nil)?

    def initialize
      @items = [] of {String, String}
      @prefix = Settings.env_prefix
      @selected = 0
      @adding = false
      @prefix_editing = false
      @edit_index = nil.as(Int32?)
      # One `TextField` shared by the two inline editors this overlay opens (the add/edit row
      # and the prefix row) — they are never open at once, and both used to stand on the same
      # hand-rolled `@input`/`@icx`/`@preedit` triple. A TextField remembers the geometry it
      # was drawn at, which is what gives the row a caret on a press, drag-select and
      # double-click-word; the triple gave it none of them.
      @field = TextField.new
      reset
    end

    def reset : Nil
      @items = Settings.env_vars.dup
      @prefix = Settings.env_prefix
      @selected = 0
      cancel_add
      cancel_prefix_edit
    end

    def to_config : {String, Array({String, String})}
      {@prefix, @items}
    end

    def adding? : Bool
      @adding
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

    # a add · ↵/e edit · d delete · p edit the prefix sigil · esc close. ^P jumps back to
    # the palette. The prefix and add/edit rows are sub-modes of this same overlay — each
    # owns every key while open — not separate shell states.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      return handle_prefix_key(ev) if @prefix_editing
      return handle_add_key(ev) if @adding
      key = ev.key
      if ev.ctrl? && key.lower_p?
        on_palette.try(&.call)
      elsif key.escape?
        return :cancel
      elsif key.up? || key.lower_k?
        select_move(-1)
      elsif key.down? || key.lower_j?
        select_move(1)
      elsif key.enter?
        edit_start
      else
        # Only an UNMODIFIED letter is a mnemonic. `Event::Key#char` is `@char || key.to_char`,
        # so `^D` reports 'd' — and the shell no longer claims that chord: the quit arm yields
        # ^C/^D while a modal is up (Runner.quit_chord_claimed?, so ^D can reach the Fuzzer's
        # payload editor). Unguarded, the operator's quit press deleted a global env var and
        # wrote settings.json. Same guard, same reason, as notifications_overlay.cr:103.
        handle_list_char(ev.ctrl? || ev.alt? ? nil : (ev.char || key.to_char))
      end
      :stay
    end

    private def handle_list_char(c : Char?) : Nil
      case c
      when 'e' then edit_start
      when 'a' then add_start
      when 'p' then prefix_edit_start
      when 'd' then delete_and_persist
      end
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

    private def handle_add_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      if key.escape?
        cancel_add
      elsif key.enter?
        commit_and_persist
      elsif key.backspace?
        cancel_add unless backspace
      elsif key.tab?
        # ↹ types the KEY/VALUE separator rather than jumping focus. There is nowhere to jump
        # to — this row is one field holding a pair, which `commit_entry` parses. Deliberate,
        # and the same in the hostname editor next door.
        @field.insert(' ')
      else
        # Caret motion, word jumps, ⌥⌫ and selection now come from the shared editor; this
        # row used to answer arrows with `move_cursor(±1)` and nothing else.
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

    private def commit_and_persist : Nil
      verb = @edit_index ? "updated" : "added"
      case commit_entry
      when :empty   then toast("env var: empty")
      when :invalid then toast(%(env var: need "KEY VALUE" or "KEY=value" — KEY is [A-Za-z_][A-Za-z0-9_]*))
      when :dup     then toast("env var: KEY already defined — edit it (e)")
      when :ok
        # `added` / `updated` — see HostsOverlay#commit_and_persist, which this mirrors.
        toast(persist ? "env var #{verb} — #{@items.size} total" : "env var applied — could not save to #{Settings.path}")
      end
    end

    private def delete_and_persist : Nil
      return unless key_name = delete_selected
      toast(persist ? "env var deleted: #{key_name}" : "env var deleted: #{key_name} — could not save to #{Settings.path}")
    end

    private def persist : Bool
      (s = on_save) ? s.call : true
    end

    private def toast(msg : String) : Nil
      on_toast.try(&.call(msg))
    end

    # A click outside dismisses (esc); a row click selects it (add/edit/delete stay
    # keyboard-driven).
    #
    # "dismisses (esc)" is meant LITERALLY: click-away goes through the same guard the esc
    # key does, so while either sub-mode is open — the add/edit row or the prefix row, both
    # of which hold typed input — it cancels the ROW and leaves the modal up. A stray click
    # can't silently drop what was typed AND take the editor down with it; the second click,
    # now on the plain list, closes. Mirrors PreferencesOverlay#handle_click; the keyboard
    # path already read this way and only the mouse diverged.
    #
    # An UNDRAWN card (nil box — the "needs a larger window" path) is exempt: there is no
    # card on screen to click a second time, so that click must always dismiss.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil?
      unless box.contains?(mx, my)
        if @prefix_editing
          cancel_prefix_edit
        elsif @adding
          cancel_add
        else
          return :cancel
        end
        return :stay
      end
      # A press inside an open inline editor is a CARET, not a row pick — the row is text.
      return :stay if (@adding || @prefix_editing) && click_text_field(mx, my)
      # The gauge on the card's right hairline, before `row_at` — which has no `mx` bound.
      if row = gauge_row_at(box, mx, my)
        set_selected(row)
        return :stay
      end
      if idx = row_at(box, mx, my)
        set_selected(idx)
      end
      :stay
    end

    def move(step : Int32) : Nil
      select_move(step)
    end

    def select_move(d : Int32) : Nil
      return if @prefix_editing || @adding
      @selected = (@selected + d).clamp(0, {@items.size - 1, 0}.max)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@items.size - 1, 0}.max)
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

    def add_start : Nil
      cancel_prefix_edit
      @adding = true
      @edit_index = nil
      @field.set("")
    end

    def edit_start : Nil
      return if @items.empty?
      key, val = @items[@selected]
      cancel_prefix_edit
      @adding = true
      @edit_index = @selected
      @field.set("#{key} #{val}")
    end

    def cancel_add : Nil
      @adding = false
      @edit_index = nil
      @field.set("")
    end

    def input(ch : Char) : Nil
      @field.insert(ch)
    end

    # Whether there was anything to delete — the callers read this to tell a ⌫ that edited
    # the text from one on an empty row, which cancels the row.
    def backspace : Bool
      return false if @field.value.empty?
      @field.backspace
      true
    end

    def set_preedit(text : String) : Nil
      @field.set_preedit(text)
    end

    # The pointer contract (see `Overlay#text_fields`) — listed only while one of the two
    # inline editors is open, so a click on the list cannot place a caret in a field that is
    # not on screen.
    def text_fields : Array(TextField)
      (@adding || @prefix_editing) ? [@field] : [] of TextField
    end

    def commit_prefix : Symbol
      text = @field.value.strip
      return :empty if text.empty?
      @prefix = text
      cancel_prefix_edit
      :ok
    end

    # NOT `commit`: that name belongs to `Overlay`, whose `commit : Bool` runs the injected
    # on_commit closure and tells the shell whether to close. Crystal has no `override`
    # keyword, so naming this one `commit` silently replaced the base contract — inert only
    # because this editor never returns a :commit outcome (it persists per mutation), and a
    # landmine the moment one is added: the shell would run this field parser instead of the
    # closure and read its truthy Symbol as "close me". (`commit_prefix` does not collide.)
    def commit_entry : Symbol
      text = @field.value.strip
      return :empty if text.empty?
      parsed = Env.parse_line(text)
      return :invalid unless parsed
      key, val = parsed
      idx = @edit_index
      return :dup if @items.each_with_index.any? { |(k, _), i| k == key && i != idx }
      if idx
        @items[idx] = {key, val}
        @selected = idx
      else
        @items << {key, val}
        @selected = @items.size - 1
      end
      cancel_add
      :ok
    end

    def delete_selected : String?
      return nil if @items.empty?
      key, _ = @items[@selected]
      @items.delete_at(@selected)
      @selected = @selected.clamp(0, {@items.size - 1, 0}.max)
      key
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 56}.min
      rows = {@items.size + (@adding ? 1 : 0) + (@prefix_editing ? 1 : 0), 6}.max
      h = {area.h - 2, rows + 4}.min
      return nil if w < 28 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    private def list_capacity(box : Rect) : Int32
      {box.bottom - 1 - (box.y + 3), 0}.max
    end

    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || @items.size <= cap
      { {@selected - cap + 1, 0}.max, @items.size - cap }.min
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "env editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "ENVIRONMENT", border: Theme.border_focus)
      meta = "#{@items.size} var#{@items.size == 1 ? "" : "s"}"
      Frame.border_meta(screen, box, "ENVIRONMENT", meta, bg: Theme.panel)
      draw_prefix_row(screen, box, box.y + 1)
      screen.text(box.x + 3, box.y + 2, "KEY VALUE · e.g. HOST api.example.com", Theme.muted, Theme.panel, width: {box.w - 5, 1}.max)

      cap = list_capacity(box)
      y = box.y + 3
      rows = cap
      if @adding
        draw_add_row(screen, box, y)
        y += 1
        rows -= 1
      end
      return if rows <= 0
      if @items.empty?
        screen.text(box.x + 3, y, "no env vars — press a to add", Theme.muted, Theme.panel) unless @adding
        return
      end
      start = list_window(rows)
      rows.times do |row|
        i = start + row
        break if i >= @items.size
        draw_row(screen, box, i, y + row)
      end
      Frame.scroll_gauge(screen, Rect.new(box.x + 1, y, box.w - 2, rows),
        @items.size, start, true, Theme.panel)
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
        screen.text(x + 7, py, @prefix, Theme.text_bright, bg, width: {box.right - x - 8, 1}.max)
        hint = "p edit"
        screen.text({box.right - hint.size - 3, x + 8}.max, py, hint, Theme.muted, bg)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      key, val = @items[i]
      sel = i == @selected && !@adding && !@prefix_editing
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
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

    private def draw_add_row(screen : Screen, box : Rect, py : Int32) : Nil
      bg = Theme.accent_bg
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      # The marker column every other row writes — the add-row used to skip it, so the one
      # row that HAS the focus was the only one without the bar that says so.
      screen.cell(box.x + 1, py, '▎', Theme.accent, bg)
      x = box.x + 3
      x = screen.text(x, py, @edit_index ? "edit " : "add ", Theme.accent, bg)
      w = {box.right - 1 - x, 3}.max
      @field.render(screen, x, py, w, true, Theme.text_bright, bg)
    end

    # The row a click on the list's scroll gauge asks for. The gauge rides the card's right
    # hairline; the window is derived from the selection, so this answers with a selection.
    # `y`/`rows` mirror render exactly: the add-row, when open, takes the first interior line.
    def gauge_row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      cap = list_capacity(box)
      y = box.y + 3 + (@adding ? 1 : 0)
      rows = cap - (@adding ? 1 : 0)
      return nil if rows <= 0
      Frame.scroll_gauge_row(Rect.new(box.x + 1, y, box.w - 2, rows), @items.size, mx, my)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 3)
      return nil if row < 0 || row >= cap
      row -= 1 if @adding
      return nil if row < 0
      i = list_window({cap - (@adding ? 1 : 0), 0}.max) + row
      i < @items.size ? i : nil
    end
  end
end
