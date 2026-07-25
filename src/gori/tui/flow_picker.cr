require "./screen"
require "./theme"
require "./frame"
require "./url"
require "./flow_status"
require "./picker_overlay"
require "../store"

module Gori::Tui
  # The Comparer's flow picker overlay (a/b → choose a flow for slot A/B). Lists a
  # snapshot of recent flows with a type-to-filter bar (in-memory substring match —
  # no per-keystroke SQL) and returns the highlighted row.
  #
  # A dumb form object on the Overlay seam: what happens to the pick is the injected
  # `on_commit`, so the SAME picker serves the Comparer (load the flow into slot A/B,
  # Runner#comparer_pick) and the entity-link flow (attach the flow to an issue/note,
  # opened as a child of LinksOverlay) with no mode flag here. `target` survives only
  # as the card's heading.
  class FlowPicker < FilterPickerOverlay
    IDLE_HINT = "type to filter · ↑/↓ select · ↵ choose · esc cancel"

    getter target : Symbol
    @indexed : Array({Store::FlowRow, String}) # each row paired with its precomputed filter haystack

    def initialize(@rows : Array(Store::FlowRow), @target : Symbol)
      # Precompute each row's filter haystack ONCE (not per keystroke) so typing into
      # a 2000-row snapshot doesn't rebuild 2000 strings on every character.
      @indexed = @rows.map { |row| {row, haystack(row)} }
      @filtered = @rows
    end

    def selected_row : Store::FlowRow?
      @filtered[@selected]?
    end

    def entry_count : Int32
      @filtered.size
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::ComparerPick
    end

    def title : String
      "PICK FLOW"
    end

    def hint : String
      IDLE_HINT
    end

    # Recompute the visible rows from the precomputed haystacks: every whitespace-
    # separated term must appear (case-insensitive). Resets the cursor to the top.
    protected def refilter : Nil
      terms = @query.downcase.split
      @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay)| terms.all? { |t| hay.includes?(t) } }.map(&.first)
      @selected = 0
      @scroll = 0
    end

    private def haystack(row : Store::FlowRow) : String
      "#{row.method} #{row.host}#{Url.origin_path(row.target)} #{row.status}".downcase
    end

    # A centred card filling most of the body area (stable height — it doesn't
    # resize as the filter narrows). nil when there isn't room to draw.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 96}.min
      h = area.h - 2
      return nil if w < 30 || h < 8
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx, my), mirroring render's list loop; nil outside the list.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      list_h = list_height(box)
      i = my - (box.y + LIST_OFFSET)
      return nil if i < 0 || i >= list_h
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < @filtered.size ? ri : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "flow picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "PICK FLOW #{@target.to_s.upcase}", border: Theme.border_focus)

      list_top = render_filter(screen, box, IDLE_HINT)
      list_h = list_height(box)
      ensure_visible(list_h)

      if @filtered.empty?
        msg = @rows.empty? ? "no flows captured yet" : "no flows match"
        screen.text(box.x + 3, list_top, msg, Theme.muted, Theme.panel)
        return
      end

      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @filtered.size
        draw_row(screen, box, list_top + i, @filtered[ri], ri == @selected)
      end
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, row : Store::FlowRow, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)

      method_x = box.x + 3
      host_x = method_x + 8
      status_x = box.right - 5
      host_w = {status_x - host_x - 1, 1}.max

      screen.text(method_x, ry, row.method, Theme.method_color(row.method), bg, width: 7)
      screen.text(host_x, ry, "#{row.host}#{Url.origin_path(row.target)}", fg, bg, width: host_w)
      status, scolor = FlowStatus.cell(row)
      screen.text(status_x, ry, status, scolor, bg, width: 4)
    end
  end
end
