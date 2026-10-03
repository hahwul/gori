require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../settings"
require "../host_overrides"

module Gori::Tui
  # A global list of string PAIRS edited in place: the hostname overrides and the environment
  # variables. Both edit a WORKING COPY the open-site persists (`on_save`) on every mutation, so
  # esc just closes and the base `on_commit` is never reached; both add and edit through one
  # inline "A B" row. A subclass names the pair (`parse_entry`, `entry_text`, the toast
  # wording) and draws its rows and the `header_rows` above the list.
  abstract class PairListOverlay < Overlay
    # Injected at the open-site (Runner#open_settings). `on_save` persists the working copy
    # and reports whether the write landed, so the toast can tell "saved" from
    # "applied but not written".
    property on_palette : Proc(Nil)?
    property on_save : Proc(Bool)?
    property on_toast : Proc(String, Nil)?

    @items = [] of {String, String}
    @selected = 0
    @adding = false
    @edit_index : Int32? = nil # non-nil ⇒ editing that row
    # The add/edit row is a real `TextField`, like every form row in gori. A hand-rolled
    # `@input`/`@icx`/`@preedit` triple used to stand in for it, which meant the row was
    # text the pointer could not reach: no caret on a press, no drag to select, no
    # double-click for a word — all of which a TextField already answers, because it
    # remembers the geometry it was last drawn at (`hit?`).
    @field = TextField.new

    # The pair the inline row's text parses to, nil when it does not.
    private abstract def parse_entry(text : String) : {String, String}?

    # The inline row's text for editing a stored pair.
    private abstract def entry_text(a : String, b : String) : String

    # What one entry is called in a toast ("host override").
    private abstract def noun : String

    private abstract def invalid_toast : String
    private abstract def dup_toast : String
    private abstract def empty_text : String
    private abstract def too_small_what : String
    private abstract def meta : String

    # Card lines between the title and the list.
    private abstract def header_rows : Int32
    private abstract def draw_header(screen : Screen, box : Rect) : Nil
    private abstract def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil

    def adding? : Bool
      @adding
    end

    # Whether an inline editor holds typed input — it then owns every key and the pointer.
    private def row_open? : Bool
      @adding
    end

    # Close the open inline editor; false when none was open.
    private def cancel_row : Bool
      return false unless @adding
      cancel_add
      true
    end

    # a add · ↵/e edit · d delete · esc close. ^P jumps back to the palette. The add/edit
    # row is a sub-mode of this same overlay (it owns every key while open), not a
    # separate shell state.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      return handle_add_key(ev) if @adding
      key = ev.key
      if ev.ctrl? && key.lower_p?
        on_palette.try(&.call)
      elsif key.escape?
        return :cancel
      elsif key.up? || key.lower_k?
        move(-1)
      elsif key.down? || key.lower_j?
        move(1)
      elsif page_key(ev)
        # PgUp/PgDn/Home/End — the list contract, `Overlay#page_key`
      elsif key.enter?
        edit_start
      else
        # Only an UNMODIFIED letter is a mnemonic. `Event::Key#char` is `@char || key.to_char`,
        # so `^D` reports 'd' — and the shell no longer claims that chord: the quit arm yields
        # ^C/^D while a modal is up (Runner.quit_chord_claimed?, so ^D can reach the Fuzzer's
        # payload editor). Unguarded, the operator's quit press deleted a global entry and
        # wrote settings.json. Same guard, same reason, as notifications_overlay.cr:103.
        handle_list_char(ev.ctrl? || ev.alt? ? nil : (ev.char || key.to_char))
      end
      :stay
    end

    private def handle_list_char(c : Char?) : Nil
      case c
      when 'e' then edit_start
      when 'a' then add_start
      when 'd' then delete_and_persist
      end
    end

    # The inline add/edit row: ↵ commits, ⌫ on an empty input cancels, esc cancels. Never
    # closes the overlay — it drops back to the list.
    private def handle_add_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      if key.escape?
        cancel_add
      elsif key.enter?
        commit_and_persist
      elsif key.backspace?
        # ⌫ on an already-empty row means "I am done here", so the empty check comes BEFORE
        # the field sees the key — `TextField#backspace` on an empty value is a silent no-op
        # and the row would sit there with no way out but esc.
        cancel_add unless backspace
      elsif key.tab?
        # ↹ types the pair's separator rather than jumping focus. There is nowhere to jump
        # to: this row is one field holding two values, and the pair is what `commit_entry`
        # parses. Deliberate.
        @field.insert(' ')
      else
        # Everything else goes through the shared editor: caret motion, word jumps, ⌥⌫ and
        # selection — the keys this row used to answer with `move_cursor(±1)` alone.
        @field.handle_edit_key(ev)
      end
      :stay
    end

    private def delete_and_persist : Nil
      return unless name = delete_selected
      toast(persist ? "#{noun} deleted: #{name}" : "#{noun} deleted: #{name} — could not save to #{Settings.path}")
    end

    private def commit_and_persist : Nil
      # `added` / `updated`, like the Project panes that edit the same lists. `@edit_index` is
      # non-nil exactly when this commit came from `e`; read before `commit_entry` clears it.
      verb = @edit_index ? "updated" : "added"
      case commit_entry
      when :empty   then toast("#{noun}: empty")
      when :invalid then toast(invalid_toast)
      when :dup     then toast(dup_toast)
      when :ok
        toast(persist ? "#{noun} #{verb} — #{@items.size} total" : "#{noun} applied — could not save to #{Settings.path}")
      end
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
    # key does, so while an inline editor is open it cancels the ROW and leaves the modal up
    # — a stray click can't silently drop what was typed AND take the editor down with it.
    # The second click, now on the plain list, closes. Mirrors PreferencesOverlay#handle_click;
    # the keyboard path already read this way and only the mouse diverged.
    #
    # An UNDRAWN card (nil box — the "needs a larger window" path) is exempt: there is no
    # card on screen to click a second time, so that click must always dismiss.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil?
      return (cancel_row ? :stay : :cancel) unless box.contains?(mx, my)
      # A press inside an open inline editor is a CARET, not a row pick — the row is text.
      return :stay if row_open? && click_text_field(mx, my)
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

    # A pair on a row opens its editor — what ↵ / `e` do, and the same method. On the open
    # row's text the pair selects a word (the base, over `text_fields`); off every row it
    # passes, so the shell delivers the second press as an ordinary click.
    def handle_double_click(area : Rect, mx : Int32, my : Int32) : Symbol
      return :stay if super == :stay
      return :pass unless box = overlay_box(area)
      return :pass unless idx = row_at(box, mx, my)
      set_selected(idx)
      edit_start
      :stay
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {@items.size - 1, 0}.max)
    end

    def entry_count : Int32
      @items.size
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@items.size - 1, 0}.max)
    end

    def add_start : Nil
      open_row(nil, "")
    end

    def edit_start : Nil
      return if @items.empty?
      a, b = @items[@selected]
      open_row(@selected, entry_text(a, b))
    end

    private def open_row(idx : Int32?, text : String) : Nil
      @adding = true
      @edit_index = idx
      @field.set(text)
    end

    def cancel_add : Nil
      @adding = false
      @edit_index = nil
      @field.set("")
    end

    # Whether there was anything to delete — the callers read this to tell a ⌫ that edited
    # the text from one on an empty row, which cancels.
    def backspace : Bool
      return false if @field.value.empty?
      @field.backspace
      true
    end

    def set_preedit(text : String) : Nil
      @field.set_preedit(text)
    end

    # The pointer contract (see `Overlay#text_fields`): listing the field is the whole opt-in
    # for caret-on-press, drag-select and double-click-word. Only while a row is OPEN —
    # otherwise a click on the list would place a caret in a field nobody is looking at.
    def text_fields : Array(TextField)
      row_open? ? [@field] : [] of TextField
    end

    # Commit the add/edit row. Returns :ok|:empty|:invalid|:dup. On :ok the working copy is
    # mutated (the Runner then persists). Dedupes on the pair's first value (excluding the
    # row being edited).
    #
    # NOT `commit`: that name belongs to `Overlay`, whose `commit : Bool` runs the injected
    # on_commit closure and tells the shell whether to close. Crystal has no `override`
    # keyword, so naming this one `commit` silently replaced the base contract — inert only
    # because this editor never returns a :commit outcome (it persists per mutation), and a
    # landmine the moment one is added: the shell would run this field parser instead of the
    # closure and read its truthy Symbol as "close me".
    def commit_entry : Symbol
      text = @field.value
      return :empty if text.strip.empty?
      parsed = parse_entry(text)
      return :invalid unless parsed
      a, _ = parsed
      idx = @edit_index
      return :dup if @items.each_with_index.any? { |(k, _), i| k == a && i != idx }
      if idx
        @items[idx] = parsed
        @selected = idx
      else
        @items << parsed
        @selected = @items.size - 1
      end
      cancel_add
      :ok
    end

    # Removes the selected entry, returning its first value (for the toast) or nil.
    def delete_selected : String?
      return nil if @items.empty?
      a, _ = @items[@selected]
      @items.delete_at(@selected)
      @selected = @selected.clamp(0, {@items.size - 1, 0}.max)
      a
    end

    # The list's first line, under the title gap and the header.
    private def list_top(box : Rect) : Int32
      box.y + 1 + header_rows
    end

    # Interior list rows between the header and the bottom border.
    private def list_capacity(box : Rect) : Int32
      {box.bottom - 1 - list_top(box), 0}.max
    end

    # First visible row index, scrolled to keep @selected on screen without overscrolling.
    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || @items.size <= cap
      { {@selected - cap + 1, 0}.max, @items.size - cap }.min
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, too_small_what)
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)
      Frame.border_meta(screen, box, title, meta, bg: Theme.panel)
      draw_header(screen, box)

      cap = list_capacity(box)
      @list_last_h = cap
      y = list_top(box)
      rows = cap
      if @adding
        draw_add_row(screen, box, y)
        y += 1
        rows -= 1
      end
      return if rows <= 0
      if @items.empty?
        screen.text(box.x + 3, y, empty_text, Theme.muted, Theme.panel) unless @adding
        return
      end
      start = list_window(rows)
      rows.times do |row|
        i = start + row
        break if i >= @items.size
        draw_row(screen, box, i, y + row)
      end
      # `y`/`rows` are already past the add-row when one is open, so the gauge measures the
      # entries actually windowed rather than the card interior.
      Frame.scroll_gauge(screen, Rect.new(box.x + 1, y, box.w - 2, rows),
        @items.size, start, true, Theme.panel)
    end

    private def draw_add_row(screen : Screen, box : Rect, py : Int32) : Nil
      bg = Theme.accent_bg
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      # The marker column every other row in this list writes — the add-row used to skip it,
      # so the one row that HAS the focus was the only one without the bar that says so.
      screen.cell(box.x + 1, py, '▎', Theme.accent, bg)
      x = box.x + 3
      x = screen.text(x, py, @edit_index ? "edit " : "add ", Theme.accent, bg)
      w = {box.right - 1 - x, 3}.max
      # `TextField#render` is what records the geometry `hit?` inverts, so drawing through it
      # is what makes the pointer work — not merely tidier than `screen.input_line`.
      @field.render(screen, x, py, w, true, Theme.text_bright, bg)
    end

    # The row a click on the list's scroll gauge asks for. The gauge rides the card's right
    # hairline; the window is derived from the selection, so this answers with a selection.
    # `y`/`rows` mirror render exactly: the add-row, when open, takes the first interior line.
    def gauge_row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      cap = list_capacity(box)
      y = list_top(box) + (@adding ? 1 : 0)
      rows = cap - (@adding ? 1 : 0)
      return nil if rows <= 0
      Frame.scroll_gauge_row(Rect.new(box.x + 1, y, box.w - 2, rows), @items.size, mx, my)
    end

    # Row index under (mx,my) — inverts render's windowed layout (add-row offset +
    # list_window scroll) so a click maps to the same row that was drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - list_top(box)
      return nil if row < 0 || row >= cap
      row -= 1 if @adding # the add-row occupies the first interior line
      return nil if row < 0
      i = list_window({cap - (@adding ? 1 : 0), 0}.max) + row
      i < @items.size ? i : nil
    end
  end

  # Global hostname-overrides editor (settings → "Hostname overrides"): a process-wide
  # /etc/hosts (Settings.hostname_overrides). Each row maps a host to the IP the proxy
  # DIALS for it; SNI / cert / Host header keep the original host (Proxy::Upstream.dial).
  # Layered UNDER each project's own HOST OVERRIDES pane (the project wins on a clash).
  #
  # Edits a WORKING COPY of {host, ip} pairs; the Runner persists it (Settings.save) on
  # every mutation, and the live proxy picks the change up on the next flow (so esc just
  # closes). Single-line "IP host" entry (/etc/hosts order), mirroring the Project tab's
  # HOST OVERRIDES pane.
  #
  #   10.0.0.1     → staging.acme.test   ▎ selected
  class HostsOverlay < PairListOverlay
    def initialize
      reset
    end

    # Rebuild the working copy from persisted config (called when the overlay opens), so
    # any uncommitted add-row from a prior session is dropped.
    def reset : Nil
      @items = Settings.hostname_overrides.dup # {host, ip}
      @selected = 0
      cancel_add
    end

    # The working copy to persist (the Runner writes it to Settings + saves).
    def to_overrides : Array({String, String})
      @items
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Hosts
    end

    def title : String
      "HOSTNAME OVERRIDES"
    end

    def hint : String
      return %(type "IP host" · ↵ save · esc cancel) if @adding
      "↑/↓ select · a add · ↵/e edit · d delete · esc close"
    end

    # "IP host", /etc/hosts order.
    private def parse_entry(text : String) : {String, String}?
      HostOverrides.parse_line(text.strip)
    end

    private def entry_text(a : String, b : String) : String
      "#{b} #{a}"
    end

    private def noun : String
      "host override"
    end

    private def invalid_toast : String
      %(host override: need "IP host" — a valid IP + a hostname)
    end

    private def dup_toast : String
      "host override: host already mapped — edit it (e)"
    end

    private def empty_text : String
      "no overrides — press a to add"
    end

    private def too_small_what : String
      "hostname editor needs a larger window"
    end

    # `global`, for the reason `EnvOverlay` gives: the Project tab's HOST OVERRIDES pane is
    # this card's twin under a title one word apart, and the layering between them (project
    # wins) is invisible unless each says which it is.
    private def meta : String
      "global · #{@items.size} entr#{@items.size == 1 ? "y" : "ies"}"
    end

    private def header_rows : Int32
      1
    end

    # A brief format example so the "IP HOSTNAME" entry shape is clear at a glance.
    private def draw_header(screen : Screen, box : Rect) : Nil
      screen.text(box.x + 3, box.y + 1, "IP HOSTNAME · e.g. 10.0.0.1 example.com", Theme.muted, Theme.panel, width: {box.w - 5, 1}.max)
    end

    # Centered overlay box for `area` — the exact rect render() draws into, or nil when
    # even a windowed list can't fit. Height shrinks to the content (incl. the add-row when
    # open) but is capped to the area, so a short terminal scrolls instead of demanding all
    # rows. The key-hint lives in the status bar (key_hints), so no row is reserved here.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 56}.min
      # Show a comfortable minimum of 6 list rows even for a short/empty list (so a
      # 1-entry editor isn't a cramped sliver), capped to what the terminal can fit.
      rows = {@items.size + (@adding ? 1 : 0), 6}.max
      h = {area.h - 2, rows + 3}.min # title gap + list + bottom border
      return nil if w < 28 || h < 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      host, ip = @items[i]
      sel = i == @selected && !@adding
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      ipw = {box.w * 2 // 5, 8}.max
      screen.text(box.x + 3, py, ip, Theme.accent, bg, width: ipw)
      ax = box.x + 3 + ipw
      screen.text(ax, py, "→ ", Theme.muted, bg) if box.right - 1 > ax
      hx = ax + 2
      screen.text(hx, py, host, sel ? Theme.text_bright : Theme.text, bg, width: {box.right - 1 - hx, 1}.max) if box.right - 1 > hx
    end
  end
end
