require "./screen"
require "./theme"
require "./frame"
require "../settings"
require "../host_overrides"

module Gori::Tui
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
  class HostsOverlay
    def initialize
      @items = [] of {String, String} # {host, ip}
      @selected = 0
      @adding = false
      @edit_index = nil.as(Int32?) # non-nil ⇒ editing that row
      @input = ""                  # add-row text ("IP host")
      @icx = 0
      @preedit = ""
      reset
    end

    # Rebuild the working copy from persisted config (called when the overlay opens), so
    # any uncommitted add-row from a prior session is dropped.
    def reset : Nil
      @items = Settings.hostname_overrides.dup
      @selected = 0
      cancel_add
    end

    # The working copy to persist (the Runner writes it to Settings + saves).
    def to_overrides : Array({String, String})
      @items
    end

    def adding? : Bool
      @adding
    end

    def select_move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {@items.size - 1, 0}.max)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@items.size - 1, 0}.max)
    end

    def add_start : Nil
      @adding = true
      @edit_index = nil
      @input = ""
      @icx = 0
      @preedit = ""
    end

    def edit_start : Nil
      return if @items.empty?
      host, ip = @items[@selected]
      @adding = true
      @edit_index = @selected
      @input = "#{ip} #{host}"
      @icx = @input.size
      @preedit = ""
    end

    def cancel_add : Nil
      @adding = false
      @edit_index = nil
      @input = ""
      @icx = 0
      @preedit = ""
    end

    def input(ch : Char) : Nil
      @input = "#{@input[0, @icx]}#{ch}#{@input[@icx..]}"
      @icx += 1
      @preedit = ""
    end

    def backspace : Bool
      return false if @icx == 0
      @input = "#{@input[0, @icx - 1]}#{@input[@icx..]}"
      @icx -= 1
      true
    end

    def move_cursor(d : Int32) : Nil
      @icx = (@icx + d).clamp(0, @input.size)
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    # Commit the add/edit row ("IP host", /etc/hosts order). Returns :ok|:empty|:invalid|
    # :dup. On :ok the working copy is mutated (the Runner then persists). Dedupes on the
    # host (excluding the row being edited).
    def commit : Symbol
      text = @input.strip
      return :empty if text.empty?
      parts = text.split(/\s+/, 2)
      return :invalid if parts.size < 2
      ip = parts[0]
      host = parts[1].strip.downcase
      return :invalid unless HostOverrides.valid?(host, ip)
      idx = @edit_index
      return :dup if @items.each_with_index.any? { |(h, _), i| h == host && i != idx }
      if idx
        @items[idx] = {host, ip}
        @selected = idx
      else
        @items << {host, ip}
        @selected = @items.size - 1
      end
      cancel_add
      :ok
    end

    # Removes the selected override, returning its host (for the toast) or nil.
    def delete_selected : String?
      return nil if @items.empty?
      host, _ = @items[@selected]
      @items.delete_at(@selected)
      @selected = @selected.clamp(0, {@items.size - 1, 0}.max)
      host
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

    # Interior list rows between the title gap (box.y+2) and the bottom border.
    private def list_capacity(box : Rect) : Int32
      {box.bottom - 1 - (box.y + 2), 0}.max
    end

    # First visible row index, scrolled to keep @selected on screen without overscrolling.
    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || @items.size <= cap
      { {@selected - cap + 1, 0}.max, @items.size - cap }.min
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "hostname editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "HOSTNAME OVERRIDES", border: Theme.border_focus)
      meta = "#{@items.size} entr#{@items.size == 1 ? "y" : "ies"}"
      screen.text({box.right - meta.size - 2, box.x + 20}.max, box.y, meta, Theme.muted, Theme.panel)
      # A brief format example so the "IP HOSTNAME" entry shape is clear at a glance.
      screen.text(box.x + 3, box.y + 1, "IP HOSTNAME · e.g. 10.0.0.1 example.com", Theme.muted, Theme.panel, width: {box.w - 5, 1}.max)

      cap = list_capacity(box)
      y = box.y + 2
      rows = cap
      if @adding
        draw_add_row(screen, box, y)
        y += 1
        rows -= 1
      end
      return if rows <= 0
      if @items.empty?
        screen.text(box.x + 3, y, "(no overrides — a to add)", Theme.muted) unless @adding
        return
      end
      start = list_window(rows)
      rows.times do |row|
        i = start + row
        break if i >= @items.size
        draw_row(screen, box, i, y + row)
      end
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

    private def draw_add_row(screen : Screen, box : Rect, py : Int32) : Nil
      bg = Theme.accent_bg
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      x = box.x + 3
      x = screen.text(x, py, @edit_index ? "edit " : "add ", Theme.accent, bg)
      w = {box.right - 1 - x, 3}.max
      screen.input_line(x, py, @input, @icx, @preedit, Theme.text_bright, bg, width: w)
    end

    # Row index under (mx,my) — inverts render's windowed layout (add-row offset +
    # list_window scroll) so a click maps to the same row that was drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 2)
      return nil if row < 0 || row >= cap
      row -= 1 if @adding # the add-row occupies the first interior line
      return nil if row < 0
      i = list_window({cap - (@adding ? 1 : 0), 0}.max) + row
      i < @items.size ? i : nil
    end
  end
end
