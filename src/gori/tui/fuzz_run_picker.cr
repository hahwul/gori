require "./picker_overlay"
require "./fmt"
require "../store"

module Gori::Tui
  # Saved runs for the active Fuzzer session. It deliberately reuses OverlayKind::Choice: the
  # shell dispatches through the Overlay object, while the enum only names the modal tier.
  class FuzzRunPicker < PickerOverlay
    record PendingAction, kind : Symbol, id : Int64

    getter rows : Array(Store::FuzzRunRecord)
    getter pending_action : PendingAction?

    def initialize(@rows : Array(Store::FuzzRunRecord))
      @pending_action = nil.as(PendingAction?)
    end

    def key : OverlayKind
      OverlayKind::Choice
    end

    def title : String
      I18n.ui("FUZZ RUN HISTORY")
    end

    def hint : String
      I18n.ui("↑/↓ select · ↵ load · d delete · esc cancel")
    end

    def entry_count : Int32
      @rows.size
    end

    def selected_row : Store::FuzzRunRecord?
      @rows[@selected]?
    end

    def arm_load : Bool
      return false unless row = selected_row
      @pending_action = PendingAction.new(:load, row.id)
      true
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape? then :cancel
      when key.up?     then move(-1); :stay
      when key.down?   then move(1); :stay
      when key.enter?  then :commit
      else
        if (char = ev.char) && !ev.ctrl? && !ev.alt?
          case char
          when 'j' then move(1)
          when 'k' then move(-1)
          when 'd'
            if row = selected_row
              @pending_action = PendingAction.new(:delete, row.id)
              return :cancel
            end
          end
        end
        :stay
      end
    end

    def overlay_box(area : Rect) : Rect?
      return nil if @rows.empty?
      w = {area.w - 4, 96}.min
      h = {@rows.size + 2, 4}.max
      h = {h, area.h - 2}.min
      return nil if w < 42 || h < 4
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      i = my - box.y - 1
      return nil if i < 0 || i >= box.h - 2
      return nil if mx <= box.x || mx >= box.right - 1
      idx = @scroll + i
      idx < @rows.size ? idx : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "no saved fuzz runs · esc to close", Theme.muted, Theme.bg)
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)
      visible = box.h - 2
      ensure_visible(visible)
      visible.times do |i|
        idx = @scroll + i
        break if idx >= @rows.size
        draw_row(screen, box, box.y + 1 + i, @rows[idx], idx == @selected)
      end
    end

    private def draw_row(screen : Screen, box : Rect, y : Int32,
                         row : Store::FuzzRunRecord, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg)
      screen.cell(box.x + 1, y, active ? '▎' : ' ', Theme.accent, bg)
      proto = row.proto_label
      label = "##{row.id}  #{row.status.upcase} · #{proto} · #{row.mode}"
      stats = "#{row.matched}/#{row.sent} hit"
      sx = box.right - 2 - stats.size
      screen.text(box.x + 3, y, label, active ? Theme.text_bright : Theme.text, bg,
        width: {sx - box.x - 4, 1}.max)
      screen.text(sx, y, stats, row.matched > 0 ? Theme.green : Theme.muted, bg)
    end
  end
end
