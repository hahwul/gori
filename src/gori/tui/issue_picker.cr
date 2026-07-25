require "./screen"
require "./theme"
require "./frame"
require "./picker_overlay"
require "../store"

module Gori::Tui
  # Pick an issue to attach the current workbench ref to. Mirrors FlowPicker's
  # in-memory filter. A pinned "+ New issue…" row (always first) hands off to the
  # NEW ISSUE form for create-and-link.
  #
  # A dumb form object on the Overlay seam: which ref gets attached, and what the
  # create row does, are both the injected `on_commit` (Runner#link_to_issue).
  class IssuePicker < FilterPickerOverlay
    CREATE_LABEL = "+ New issue…"
    IDLE_HINT    = "type to filter · ↑/↓ select · ↵ link · esc cancel"
    # The card's own hint row names the create row too; the shell's bottom row does not.
    CARD_HINT = "type to filter · ↑/↓ select · ↵ link / create · esc cancel"

    @indexed : Array({Store::Issue, String})

    def initialize(@rows : Array(Store::Issue))
      @indexed = @rows.map { |f| {f, haystack(f)} }
      @filtered = @rows
      # Prefer the first existing issue when present (create is always index 0).
      @selected = @rows.empty? ? 0 : 1
    end

    # Total navigable rows: create action + filtered issues.
    def entry_count : Int32
      1 + @filtered.size
    end

    def selected_create? : Bool
      @selected == 0
    end

    def selected_issue : Store::Issue?
      return nil if selected_create?
      @filtered[@selected - 1]?
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::IssuePick
    end

    def title : String
      "PICK ISSUE"
    end

    def hint : String
      IDLE_HINT
    end

    protected def refilter : Nil
      terms = @query.downcase.split
      @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay)| terms.all? { |t| hay.includes?(t) } }.map(&.first)
      # Keep create at 0; land on first match when any, else the create row.
      @selected = @filtered.empty? ? 0 : 1
      @scroll = 0
    end

    private def haystack(f : Store::Issue) : String
      "#{f.title} #{f.host} #{f.severity.label} #{f.status.label} ##{f.id}".downcase
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 80}.min
      h = area.h - 2
      return nil if w < 30 || h < 8
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      list_h = list_height(box)
      i = my - (box.y + LIST_OFFSET)
      return nil if i < 0 || i >= list_h
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < entry_count ? ri : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return unless box
      Frame.card(screen, box, title, border: Theme.border_focus)
      list_top = render_filter(screen, box, CARD_HINT)
      list_h = list_height(box)
      ensure_visible(list_h)
      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= entry_count
        if ri == 0
          draw_create(screen, box, list_top + i, ri == @selected)
        else
          draw_row(screen, box, list_top + i, @filtered[ri - 1], ri == @selected)
        end
      end
    end

    private def draw_create(screen : Screen, box : Rect, ry : Int32, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.accent
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      screen.text(box.x + 3, ry, CREATE_LABEL, fg, bg, width: box.w - 5)
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, f : Store::Issue, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      label = "##{f.id} [#{f.severity.label}] #{f.title}"
      screen.text(box.x + 3, ry, label, fg, bg, width: box.w - 5)
    end
  end
end
