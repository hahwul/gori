require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./path_complete"

module Gori::Tui
  # Centered popup collecting the source path for palette → "Import: HAR / URLs /
  # OpenAPI". One path field with an inline PathComplete dropdown — CAImportOverlay's
  # shape minus its second field.
  #
  # This REPLACED a one-row prompt on the status bar. A filesystem path is long and the
  # status row is the dimmest, most cramped strip in the UI: the input got whatever was
  # left after the prefix and hint, and the completion dropdown had to be drawn ABOVE
  # the row (`rect.y - 9`) because there was nothing below it. Centered, the path gets a
  # full card width and the dropdown hangs under the field where it belongs.
  #
  # Surfaces used by the Runner: `handle_key` returns :submit on ↵, :cancel on esc,
  # :stay otherwise. On :submit the Runner reads `path` and runs the import.
  class ImportOverlay
    getter kind : Symbol

    def initialize(@kind : Symbol)
      @field = TextField.new("")
      @path_complete = PathComplete.new
    end

    def path : String
      @field.value.strip
    end

    # The source format, for the card title and the Runner's result toast — one source
    # so the popup and the toast can't disagree about what was imported.
    def label : String
      case @kind
      when :har  then "HAR"
      when :urls then "URLs"
      when :oas  then "OpenAPI"
      else            "file"
      end
    end

    private def blurb : String
      case @kind
      when :har  then "Load flows from a browser or proxy HAR export into History."
      when :urls then "Load a text file of URLs into History — one URL per line."
      when :oas  then "Build request templates from an OpenAPI spec into History."
      else            "Load flows into History."
      end
    end

    # --- input ---------------------------------------------------------------
    # :submit when the user commits, :cancel on esc, else :stay.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key

      # esc peels one layer at a time: the dropdown first, the popup only once it's
      # down — so a stray esc can't discard a long path the user just typed.
      if key.escape?
        return :cancel unless @path_complete.open?
        @path_complete.close
        return :stay
      end

      return commit_or_complete(key) if key.tab? || key.enter?

      if key.back_tab? || key.up?
        @path_complete.move(-1) if @path_complete.open?
        return :stay
      end
      if key.down?
        @path_complete.move(1) if @path_complete.open?
        return :stay
      end

      @field.handle_edit_key(ev)
      @path_complete.refresh(@field.value) # keep the dropdown in lockstep
      :stay
    end

    # ↹/↵ with the dropdown up accepts the highlighted entry: a directory keeps the list
    # open so the user can keep drilling, a file closes it — and ↵ landing on a file
    # commits in that same keystroke rather than making the user press it twice (carried
    # over from the old bottom prompt). With no dropdown up, ↵ submits what was typed.
    private def commit_or_complete(key : Termisu::Input::Key) : Symbol
      if @path_complete.open? && (res = @path_complete.accept)
        insert, is_dir = res
        @field.set(insert)
        if is_dir
          @path_complete.refresh(insert)
        else
          @path_complete.close
          return :submit if key.enter?
        end
        return :stay
      end
      key.enter? ? :submit : :stay
    end

    def set_preedit(text : String) : Nil
      @field.set_preedit(text)
    end

    # Wheel support — the Runner routes a scroll here, and the only scrollable thing is
    # the completion list.
    def move(d : Int32) : Nil
      @path_complete.move(d) if @path_complete.open?
    end

    # --- rendering -----------------------------------------------------------
    LABEL_W = 8 # value column offset ("Path" + padding)

    # Tall enough (14) that PathComplete's 8-row cap fits under the field instead of
    # being clipped; `area` still wins on a short terminal.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 76}.min
      h = {area.h - 4, 14}.min
      return nil if w < 40 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        unless area.empty?
          screen.text(area.x + 1, area.y, "import needs a larger window · esc to close",
            Theme.muted, Theme.bg)
        end
        return
      end
      Frame.card(screen, box, "IMPORT #{label.upcase} · source path", bg: Theme.bg,
        border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, blurb, Theme.muted, Theme.bg, width: box.w - 4)
      render_field(screen, box)
      screen.text(box.x + 2, box.bottom - 2,
        "type to complete · ↹ pick · ↑↓ browse · ↵ import · esc cancel",
        Theme.muted, Theme.bg, width: box.w - 4)
      render_dropdown(screen, box)
    end

    # The single field is always focused (there's nowhere else to go), so it always
    # carries the focus band — no "which row am I on?" ambiguity to resolve.
    private def render_field(screen : Screen, box : Rect) : Nil
      y = field_y(box)
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.accent_bg)
      screen.text(box.x + 2, y, "Path", Theme.text_bright, Theme.accent_bg)
      vx = value_x(box)
      vw = {box.right - 2 - vx, 1}.max
      @field.render(screen, vx, y, vw, true, Theme.text_bright, Theme.accent_bg)
    end

    private def render_dropdown(screen : Screen, box : Rect) : Nil
      return unless @path_complete.open?
      @path_complete.render(screen, value_x(box), field_y(box) + 1, box.inset(1, 1))
    end

    private def field_y(box : Rect) : Int32
      box.y + 3
    end

    private def value_x(box : Rect) : Int32
      box.x + 2 + LABEL_W
    end

    # --- mouse ---------------------------------------------------------------
    # A click inside the card is inert but CONSUMED — there's one field and it already
    # holds focus, so there's nothing to select; returning true just stops the Runner
    # reading it as a click-away dismiss. (Picking a dropdown row by mouse would mean
    # inverting PathComplete's private scroll window; it's keyboard-only there for the
    # CA import popup too, so this stays consistent rather than special-casing one call
    # site of a shared widget.)
    def handle_click(box : Rect, mx : Int32, my : Int32) : Bool
      box.contains?(mx, my)
    end
  end
end
