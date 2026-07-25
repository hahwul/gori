require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./notifications"

module Gori::Tui
  # The notification center: a centered overlay listing recent notifications (newest
  # first). Pure state (@selected) + render; the injected closures run a note's `goto`
  # and the palette hop. Reads the live store, so a note pushed by a drain while the
  # center is open appears at once. Chosen over a persistent "Activity" tab — lighter,
  # and it reuses the existing modal-overlay machinery.
  #
  #   ▎ ✓ Miner: 3 params found on GET /api/x          3s
  #     ⚠ Repeater: upstream timeout                      5m
  #
  # Migrated onto the polymorphic Overlay seam (see overlay.cr). `c` clears the store
  # this overlay was handed, so it stays a plain key case; the two actions that belong
  # to the SHELL (jump to a note's result, hop to the palette) are injected closures.
  class NotificationsOverlay < Overlay
    # ^P leaves the center for the command palette. Injected because raising another
    # modal is the shell's job — and it must close this one FIRST, or the shell's own
    # close would land on top of the palette. See Runner#open_notifications.
    property on_palette : Proc(Nil)?

    def initialize(@store : Notifications)
      @selected = 0
    end

    def reset : Nil
      @selected = 0
    end

    def notes : Array(Notifications::Note)
      @store.all
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Notifications
    end

    def title : String
      "NOTIFICATIONS"
    end

    def hint : String
      "↑/↓ select · ↵ open · c clear · esc close"
    end

    # Formerly Runner#handle_notifications_key. ↵ commits (the open-site's closure jumps
    # to the selected note's result); `c` empties the store in place and stays open.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      c = ev.char
      if ev.ctrl? && k.lower_p?
        @on_palette.try(&.call)
      elsif k.escape?
        return :cancel
      elsif k.up?
        move(-1)
      elsif k.down?
        move(1)
      elsif k.enter?
        return :commit
      elsif c == 'c'
        @store.clear
        reset
      end
      :stay
    end

    # A click on a row selects it and opens it (same as ↵); a click elsewhere inside the
    # card does nothing; a click outside dismisses. Mirrors Runner#click_notifications.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit
      end
      :stay
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {notes.size - 1, 0}.max)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {notes.size - 1, 0}.max)
    end

    def selected_note : Notifications::Note?
      notes[@selected]?
    end

    # Centered box for `area`, sized to the content (min 6 rows), or nil when it can't
    # fit. Mirrors HostsOverlay#overlay_box so the geometry math is consistent.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 60}.min
      rows = {notes.size, 6}.max
      h = {area.h - 2, rows + 3}.min # title gap + list + bottom border
      return nil if w < 28 || h < 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "notifications need a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "NOTIFICATIONS", border: Theme.border_focus)
      meta = "#{notes.size} item#{notes.size == 1 ? "" : "s"}"
      screen.text({box.right - meta.size - 2, box.x + 16}.max, box.y, meta, Theme.muted, Theme.panel)

      cap = list_capacity(box)
      if notes.empty?
        screen.text(box.x + 3, box.y + 2, "(no notifications yet)", Theme.muted, Theme.panel) if cap > 0
        return
      end
      start = list_window(cap)
      cap.times do |row|
        i = start + row
        break if i >= notes.size
        draw_row(screen, box, i, box.y + 2 + row)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      note = notes[i]
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      g, gc = glyph(note.level)
      screen.cell(box.x + 3, py, g, gc, bg)
      bold = note.read ? Attribute::None : Attribute::Bold
      fg = sel ? Theme.text_bright : Theme.text
      stamp = ago(note.created_at)
      # Agent-originated notes (an MCP co-pilot acting in the loop) get a distinct "ai"
      # tag so the human can see at a glance which entries the AI produced. Other sources
      # already name themselves in the message ("Miner: …", "Probe: …"), so no tag.
      msg_x = box.x + 5
      if note.agent?
        tag = "ai"
        screen.text(msg_x, py, tag, Theme.accent, bg, Attribute::Bold)
        msg_x += tag.size + 1
      end
      msg_w = {box.right - 1 - msg_x - (stamp.size + 1), 1}.max
      screen.text(msg_x, py, note.message, fg, bg, bold, width: msg_w)
      screen.text(box.right - 1 - stamp.size, py, stamp, Theme.muted, bg)
    end

    # Row index under (mx,my) — inverts render's windowed layout so a click maps to the
    # same row that was drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 2)
      return nil if row < 0 || row >= cap
      i = list_window(cap) + row
      i < notes.size ? i : nil
    end

    private def list_capacity(box : Rect) : Int32
      {box.bottom - 1 - (box.y + 2), 0}.max
    end

    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || notes.size <= cap
      { {@selected - cap + 1, 0}.max, notes.size - cap }.min
    end

    private def glyph(level : Symbol) : {Char, Color}
      case level
      when :success then {'✓', Theme.green}
      when :warn    then {'⚠', Theme.yellow}
      when :error   then {'✗', Theme.red}
      else               {'·', Theme.muted}
      end
    end

    # Compact relative age: "3s" / "5m" / "2h" / "1d".
    private def ago(t : Time::Instant) : String
      secs = (Time.instant - t).total_seconds.to_i
      return "#{secs}s" if secs < 60
      mins = secs // 60
      return "#{mins}m" if mins < 60
      hours = mins // 60
      return "#{hours}h" if hours < 24
      "#{hours // 24}d"
    end
  end
end
