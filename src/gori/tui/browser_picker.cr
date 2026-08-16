require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "../browser"
require "./viewport"

module Gori::Tui
  # The "Open browser" overlay (palette → browser.open). Lists the browsers
  # detected on this system; ↵ launches the highlighted one pre-trusted (gori's
  # CA trusted + proxy set). A dumb list: the Runner owns detection, and the launch
  # itself rides in as the `on_commit` closure at the open-site.
  class BrowserPicker < Overlay
    getter selected : Int32

    # `certutil_available` is resolved once by the caller (Runner) rather than probed
    # here on every render — detection belongs to the Runner, per this class's doc.
    def initialize(@browsers : Array(Browser::Found), @certutil_available : Bool = true)
      @selected = 0
      @scroll = 0
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Browser
    end

    def title : String
      "BROWSER"
    end

    def hint : String
      "↑/↓ select · ↵ open · esc cancel"
    end

    # ↑/↓ (or k/j) pick, ↵ launches the highlighted browser, esc cancels. Any other key
    # is swallowed — the list stays up.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape? then :cancel
      when key.up?, key.lower_k?
        move(-1)
        :stay
      when key.down?, key.lower_j?
        move(1)
        :stay
      when key.enter? then :commit
      else                 :stay
      end
    end

    # A click on a row selects AND launches it (matching the ↵ model); a click outside
    # the card dismisses; a click inside but off any row keeps it open.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit
      end
      :stay
    end

    def move(delta : Int32) : Nil
      return if @browsers.empty?
      @selected = (@selected + delta).clamp(0, @browsers.size - 1)
    end

    def selected_browser : Browser::Found?
      @browsers[@selected]?
    end

    # Geometry of the centered card over `area` — inverse of render's offset
    # math. Returns nil when render would draw nothing (same w/h guard).
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 52}.min
      h = {@browsers.size + 4, area.h - 2}.min
      return nil if w < 24 || area.h < 6
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Browser-row index under (mx,my), mirroring render's list loop; nil outside.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      i = my - list_top
      return nil if i < 0 || i >= list_h
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < @browsers.size ? ri : nil
    end

    private def ensure_visible(list_h : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@selected, @scroll, list_h, @browsers.size)
    end

    # Clamp + set the highlighted row (mirrors `move`'s clamp).
    def set_selected(idx : Int32) : Nil
      return if @browsers.empty?
      @selected = idx.clamp(0, @browsers.size - 1)
    end

    # Centered list card over `area` (the body rect).
    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "browser picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      w = box.w
      Frame.card(screen, box, "OPEN BROWSER", border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, "pre-trusted · proxy auto-set", Theme.muted, Theme.panel)
      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      ensure_visible(list_h) # keep @selected on screen — the list can exceed list_h on a short terminal
      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @browsers.size
        b = @browsers[ri]
        ry = list_top + i
        active = ri == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 3, ry, b.name, active ? Theme.text_bright : Theme.text, bg, width: w - 16)
        kind = b.kind.to_s.downcase
        if b.kind.firefox? && !@certutil_available
          kind = "#{kind} ⚠"
          screen.text(box.right - Screen.display_width(kind) - 2, ry, kind, Theme.yellow, bg)
        else
          screen.text(box.right - kind.size - 2, ry, kind, Theme.muted, bg)
        end
      end
    end
  end
end
