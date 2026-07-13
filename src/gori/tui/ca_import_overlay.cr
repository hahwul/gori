require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./path_complete"

module Gori::Tui
  # Full-area popup collecting an externally-created root CA's certificate + private
  # key PEM paths for `gori ca import` (palette → "Import CA certificate"). Two path
  # fields with an inline PathComplete dropdown, modeled on FuzzSetOverlay's
  # field+dropdown pattern but far simpler (no payload grammar).
  #
  # Surfaces used by the Runner: handle_key returns :submit when the user commits
  # (↵ on the Key row), :cancel on esc, :stay otherwise. On :submit the Runner reads
  # cert_path / key_path and runs the destructive-CA confirm before calling
  # CertAuthority#import!. set_preedit routes composing (IME) text to the focused row.
  class CAImportOverlay
    ROWS = [:cert, :key]

    def initialize
      @sel = 0 # row cursor: 0 = Certificate, 1 = Private key
      @fields = {
        :cert => TextField.new(""),
        :key  => TextField.new(""),
      }
      @path_complete = PathComplete.new
    end

    def cert_path : String
      @fields[:cert].value.strip
    end

    def key_path : String
      @fields[:key].value.strip
    end

    private def focused : Symbol
      ROWS[@sel]? || :cert
    end

    private def on_last_row? : Bool
      @sel == ROWS.size - 1
    end

    # --- input ---------------------------------------------------------------
    # :submit when the user commits (↵ on the last row), :cancel on esc, else :stay.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key

      # The path dropdown owns navigation keys while it's open.
      if @path_complete.open?
        case
        when key.tab?, key.enter?   then return accept_path
        when key.back_tab?, key.up? then @path_complete.move(-1); return :stay
        when key.down?              then @path_complete.move(1); return :stay
        when key.escape?            then @path_complete.close; return :stay
        else # printables fall through → edit + refilter
        end
      end

      return :cancel if key.escape?
      if key.tab? || key.down?
        move_row(1); return :stay
      elsif key.back_tab? || key.up?
        move_row(-1); return :stay
      elsif key.enter?
        return :submit if on_last_row?
        move_row(1); return :stay
      end

      @fields[focused].handle_edit_key(ev)
      @path_complete.refresh(@fields[focused].value) # keep the dropdown in lockstep
      :stay
    end

    # Switching rows closes the dropdown (it reopens as the user types), so opening
    # the overlay doesn't immediately bury the form under a directory listing.
    private def move_row(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, ROWS.size - 1)
      @path_complete.close
    end

    private def accept_path : Symbol
      res = @path_complete.accept
      return :stay unless res
      path, is_dir = res
      @fields[focused].set(path)
      is_dir ? @path_complete.refresh(path) : @path_complete.close
      :stay
    end

    def set_preedit(text : String) : Nil
      @fields[focused]?.try(&.set_preedit(text))
    end

    def move(d : Int32) : Nil
      move_row(d)
    end

    # --- rendering -----------------------------------------------------------
    LABEL_W = 14 # value column offset (widest label "Private key" + padding)

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 72}.min
      h = {area.h - 4, 11}.min
      return nil if w < 40 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "CA import needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "IMPORT CA · cert + key PEM", bg: Theme.bg, border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1,
        "Adopt an external root CA. Both files must be a matching pair.",
        Theme.muted, Theme.bg, width: box.w - 4)
      render_field(screen, box, :cert, "Certificate", 0)
      render_field(screen, box, :key, "Private key", 1)
      screen.text(box.x + 2, box.bottom - 2,
        "type to complete · ↹/↵ pick · ⇥/↑↓ field · ↵ submits · esc cancels",
        Theme.muted, Theme.bg, width: box.w - 4)
      render_dropdown(screen, box)
    end

    private def render_field(screen : Screen, box : Rect, f : Symbol, label : String, i : Int32) : Nil
      y = box.y + 3 + i
      foc = @sel == i
      bg = foc ? Theme.accent_bg : Theme.bg
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if foc
      screen.text(box.x + 2, y, label, foc ? Theme.text_bright : Theme.muted, bg)
      vx = box.x + 2 + LABEL_W
      vw = {box.right - 2 - vx, 1}.max
      @fields[f].render(screen, vx, y, vw, foc, foc ? Theme.text_bright : Theme.text, bg)
    end

    private def render_dropdown(screen : Screen, box : Rect) : Nil
      return unless @path_complete.open?
      vx = box.x + 2 + LABEL_W
      y = box.y + 3 + @sel + 1
      @path_complete.render(screen, vx, y, box.inset(1, 1))
    end

    # --- mouse ---------------------------------------------------------------
    # Focus the field row under a click. Returns true when the click was inside the box.
    def handle_click(box : Rect, mx : Int32, my : Int32) : Bool
      return false unless box.contains?(mx, my)
      i = my - (box.y + 3)
      if 0 <= i < ROWS.size
        @sel = i
        @path_complete.close
      end
      true
    end
  end
end
