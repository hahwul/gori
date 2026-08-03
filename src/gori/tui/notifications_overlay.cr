require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./notifications"

module Gori::Tui
  # The notification center: a centered overlay listing recent notifications (newest
  # first). Pure state (the anchored cursor) + render; the injected closures run a note's
  # `goto` and the palette hop. Reads the live store, so a note pushed by a drain while the
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

    # The id of the note the cursor is anchored to (see index_in). nil when the store is
    # empty, or when the cursor has never landed on a note.
    @anchor : Int32?

    def initialize(@store : Notifications)
      @selected = 0
      # Seeded at open — the Runner builds a fresh overlay per open_notifications, so this
      # IS the open — which covers the cursor the operator never moved. `latest` is the
      # newest note, i.e. row 0 of the newest-first list, and is O(1) where `all` reverses
      # the whole ring.
      @anchor = @store.latest.try(&.id)
    end

    def reset : Nil
      @selected = 0
      @anchor = @store.latest.try(&.id)
    end

    def notes : Array(Notifications::Note)
      @store.all
    end

    # Where the cursor sits in `list`. The overlay holds no snapshot on purpose — `notes`
    # re-derives the live store on every call, so a drain's note appears at once — and
    # pushes PREPEND (Notifications#all is `@notes.reverse`). A bare Int32 cursor therefore
    # slides onto the neighbour the moment any background completion lands: a Probe issue,
    # an OAST callback, a fuzz/miner/discover Done. The operator arrows to a note, reads the
    # frame, presses ↵ — and run_goto jumps somewhere they never selected.
    #
    # OastController#drain_events guards the identical shape by capturing {session_id, uid}
    # before its inserts and re-anchoring @cb_sel after ("a bare `@cb_sel` would silently
    # slide onto a neighbor"). A Note's `id` is that stable key here: monotonic, and `clear`
    # does not reset the counter, so an id is never recycled onto a different note.
    #
    # @selected is the FALLBACK, consulted only when the anchor no longer resolves — the
    # note aged out of the ring, or the store was cleared under us. OAST's re-anchor is a
    # no-op in exactly that case and for the same reason: leaving the cursor near where it
    # was beats snapping to the top of a list the operator never touched.
    private def index_in(list : Array(Notifications::Note)) : Int32
      return 0 if list.empty?
      if a = @anchor
        if i = list.index { |n| n.id == a }
          return i
        end
      end
      @selected.clamp(0, list.size - 1)
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
      elsif c == 'c' && !ev.ctrl? && !ev.alt?
        # Guarded, and not merely for tidiness. `Event::Key#char` is `@char || key.to_char`,
        # so `^C` reports 'c' — and this branch WIPES the whole store. It used to be
        # unreachable by accident: the shell claimed ^C for the quit-arm before any overlay
        # saw a key. That stopped being true when the quit-arm learned to yield while a modal
        # is up (so ^D could reach the Fuzzer payload editor), which quietly handed this
        # branch the one chord an operator presses to LEAVE. Pressing it here erased every
        # notification instead. A destructive mnemonic must own its guard rather than borrow
        # one from a Runner invariant that can change out from under it.
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

    # Both movers re-anchor: the cursor lands on a note, and it is that note the overlay
    # holds onto until the operator moves again.
    def move(d : Int32) : Nil
      list = notes
      @selected = (index_in(list) + d).clamp(0, {list.size - 1, 0}.max)
      @anchor = list[@selected]?.try(&.id)
    end

    def set_selected(idx : Int32) : Nil
      list = notes
      @selected = idx.clamp(0, {list.size - 1, 0}.max)
      @anchor = list[@selected]?.try(&.id)
    end

    def selected_note : Notifications::Note?
      list = notes
      list[index_in(list)]?
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
      # ONE reversed copy per frame, and one resolved cursor: `notes` allocates, draw_row
      # used to call it per row, and the window must be computed against the SAME index the
      # highlight uses or the two disagree the first time a drain prepends.
      list = notes
      Frame.card(screen, box, "NOTIFICATIONS", border: Theme.border_focus)
      meta = "#{list.size} item#{list.size == 1 ? "" : "s"}"
      screen.text({box.right - meta.size - 2, box.x + 16}.max, box.y, meta, Theme.muted, Theme.panel)

      cap = list_capacity(box)
      if list.empty?
        screen.text(box.x + 3, box.y + 2, "(no notifications yet)", Theme.muted, Theme.panel) if cap > 0
        return
      end
      sel = index_in(list)
      start = list_window(cap, list, sel)
      cap.times do |row|
        i = start + row
        break if i >= list.size
        draw_row(screen, box, list[i], i == sel, box.y + 2 + row)
      end
    end

    private def draw_row(screen : Screen, box : Rect, note : Notifications::Note, sel : Bool, py : Int32) : Nil
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
      list = notes
      i = list_window(cap, list, index_in(list)) + row
      i < list.size ? i : nil
    end

    private def list_capacity(box : Rect) : Int32
      {box.bottom - 1 - (box.y + 2), 0}.max
    end

    # Takes the list and the RESOLVED cursor rather than reading @selected: after a drain
    # prepends, @selected is the stale row number and scrolling by it would put the window
    # somewhere the highlight is not.
    private def list_window(cap : Int32, list : Array(Notifications::Note), sel : Int32) : Int32
      return 0 if cap <= 0 || list.size <= cap
      { {sel - cap + 1, 0}.max, list.size - cap }.min
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
