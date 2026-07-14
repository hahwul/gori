require "./screen"
require "./theme"
require "./frame"

module Gori::Tui
  # A centered yes/no confirmation modal for destructive actions — deleting a
  # project, closing a Repeater/Notes sub-tab. Pure state + rendering: the host
  # (the Runner's overlay, the ProjectPicker's mode) drives it and decides what a
  # confirmation actually does. Selection defaults to Cancel — the safe choice —
  # so a reflexive ↵ never destroys anything; the operator must move to (or press
  # `y` for) the danger button on purpose.
  class ConfirmDialog
    getter title : String
    getter message : String

    def initialize(@title : String, @message : String, *,
                   @confirm_label : String = "confirm", @cancel_label : String = "cancel",
                   @danger : Bool = true)
      @selected = :cancel # safe default
    end

    # Toggle between the two buttons (←/→ or Tab). With only two choices the
    # direction is irrelevant — any move flips the selection.
    def move(_dir : Int32 = 1) : Nil
      @selected = @selected == :confirm ? :cancel : :confirm
    end

    def select_confirm : Nil
      @selected = :confirm
    end

    def select_cancel : Nil
      @selected = :cancel
    end

    def confirm_selected? : Bool
      @selected == :confirm
    end

    # Centered card over `area` (the body rect). Multi-line messages split on
    # '\n'; the card sizes to the widest of message / title / button row.
    def render(screen : Screen, area : Rect) : Nil
      lines = @message.split('\n')
      return if area.w < 18 || area.h < lines.size + 6
      box = overlay_box(area)
      Frame.card(screen, box, @title, border: Theme.border_focus)

      lines.each_with_index do |line, i|
        screen.text(box.x + 3, box.y + 2 + i, line, Theme.text, Theme.panel, width: box.w - 6)
      end
      render_buttons(screen, box)
    end

    # Inverts render's centering math: the centered card rect for `area`. Pure;
    # IDENTICAL sizing to render (caller guards on area.w/area.h being too small).
    def overlay_box(area : Rect) : Rect
      lines = @message.split('\n')
      # Empty when render would decline to draw (same guard as render): a click then
      # falls through dismiss_zone?/!contains? and closes instead of acting on a
      # phantom box (e.g. firing the destructive button on an undrawn modal).
      return Rect.new(area.x, area.y, 0, 0) if area.w < 18 || area.h < lines.size + 6
      content = {longest(lines), @title.size + 2, button_row_width}.max
      h = lines.size + 6
      w = (content + 6).clamp(16, {area.w - 2, 60}.min)
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    private def longest(lines : Array(String)) : Int32
      lines.max_of { |l| Screen.display_width(l) }
    end

    private def button_row_width : Int32
      btn_width(@confirm_label) + 4 + btn_width(@cancel_label)
    end

    private def btn_width(label : String) : Int32
      label.size + 2
    end

    private def render_buttons(screen : Screen, box : Rect) : Nil
      confirm_rect, cancel_rect = button_rects(box)
      render_button(screen, confirm_rect.x, confirm_rect.y, @confirm_label, @selected == :confirm, @danger)
      render_button(screen, cancel_rect.x, cancel_rect.y, @cancel_label, @selected == :cancel, false)
    end

    # Inverts render_buttons' x/y placement: the {confirm, cancel} button rects
    # in `box`. Shared by render and button_at so the click target = the drawn
    # button. Each button is " label " wide; a 4-cell gap sits between them.
    def button_rects(box : Rect) : {Rect, Rect}
      x = box.x + (box.w - button_row_width) // 2
      y = box.bottom - 3
      confirm = Rect.new(x, y, btn_width(@confirm_label), 1)
      cancel = Rect.new(confirm.right + 4, y, btn_width(@cancel_label), 1)
      {confirm, cancel}
    end

    # Maps a click to :confirm/:cancel when it lands on that button, else nil
    # (gaps between/around buttons return nil).
    def button_at(box : Rect, mx : Int32, my : Int32) : Symbol?
      confirm_rect, cancel_rect = button_rects(box)
      return :confirm if confirm_rect.contains?(mx, my)
      return :cancel if cancel_rect.contains?(mx, my)
      nil
    end

    # Draws ` label ` at (x, y); selected fills a band (RED for the danger button,
    # accent otherwise), at rest the danger label stays red text. Returns the x
    # just past the button so the next one can be placed.
    private def render_button(screen : Screen, x : Int32, y : Int32, label : String,
                              selected : Bool, danger : Bool) : Int32
      text = " #{label} "
      if selected
        bg = danger ? Theme.red : Theme.accent_bg
        screen.fill(Rect.new(x, y, text.size, 1), bg)
        screen.text(x, y, text, Theme.text_bright, bg, attr: Attribute::Bold)
      else
        screen.text(x, y, text, danger ? Theme.red : Theme.muted, Theme.panel)
      end
      x + text.size
    end
  end
end
