require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "../settings"

module Gori::Tui
  # The TLS-passthrough list: every host gori relayed WITHOUT decrypting it, opened from the
  # `bypass:N` top-bar chip (or the app.passthrough palette entry). Read-only — the rules
  # themselves are edited in settings:network, and duplicating that editor here would be two
  # places to change one list.
  #
  #   updates.acme.test        *.acme.test        2m ago       14 conns
  #   push.acme.test           push.acme.test     11m ago       3 conns
  #
  # This answers the question a bypassed host otherwise leaves unanswerable: nothing is
  # captured for it, so History has no row, Sitemap has no node, and "why is this host
  # missing?" had only a gori.log line for an answer (#497). Each row names the PATTERN as
  # well as the host, because the operator's next move is usually to delete the rule.
  #
  # Not a flow list and deliberately unlike one: no ids, no marks, no verbs. Nothing here can
  # be sent to the repeater or probed, because gori never saw the bytes.
  class PassthroughOverlay < Overlay
    # ^P leaves for the command palette, like every other list overlay. Injected because
    # raising another modal is the shell's job (see Runner#open_passthrough).
    property on_palette : Proc(Nil)?

    def initialize
      @selected = 0
      @hosts = Settings.passthrough_hosts
    end

    # Re-snapshot from the live inventory. The overlay holds a COPY rather than reading
    # Settings per draw so the rows can't shift under a click that was hit-tested against
    # the previous frame; `r` refreshes it on demand.
    def reload : Nil
      @hosts = Settings.passthrough_hosts
      @selected = @selected.clamp(0, {@hosts.size - 1, 0}.max)
    end

    def hosts : Array(Settings::PassthroughHost)
      @hosts
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Passthrough
    end

    def title : String
      "TLS PASSTHROUGH"
    end

    def hint : String
      "↑/↓ scroll · r refresh · esc close"
    end

    # Read-only: no ↵ commit, nothing to apply. esc closes, r re-snapshots, ↑/↓ scroll.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      if ev.ctrl? && k.lower_p?
        on_palette.try(&.call)
      elsif k.escape?
        return :cancel
      elsif k.up? || k.lower_k?
        move(-1)
      elsif k.down? || k.lower_j?
        move(1)
      elsif (ev.char || k.to_char) == 'r'
        reload
      end
      :stay
    end

    # A click inside the card selects a row (there is nothing to open); outside dismisses.
    # Never :commit — a read-only list that closed itself on a row click would look like it
    # had done something.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
      end
      :stay
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {@hosts.size - 1, 0}.max)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@hosts.size - 1, 0}.max)
    end

    # Centered box, sized to the content (min 6 rows) — mirrors NotificationsOverlay so the
    # geometry math stays consistent across the list overlays. Wider than that one (72 vs 60)
    # because a row carries host AND pattern, and the pattern is the field that must never be
    # the thing that gets dropped.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 72}.min
      rows = {@hosts.size, 6}.max
      h = {area.h - 2, rows + 4}.min # title gap + list + footer + bottom border
      return nil if w < 32 || h < 7
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "passthrough list needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "TLS PASSTHROUGH", border: Theme.border_focus)
      meta = "#{@hosts.size} host#{@hosts.size == 1 ? "" : "s"}"
      screen.text({box.right - meta.size - 2, box.x + 18}.max, box.y, meta, Theme.muted, Theme.panel)

      cap = list_capacity(box)
      return if cap <= 0
      if @hosts.empty?
        screen.text(box.x + 3, box.y + 2, empty_message, Theme.muted, Theme.panel)
      else
        start = list_window(cap)
        cap.times do |row|
          i = start + row
          break if i >= @hosts.size
          draw_row(screen, box, i, box.y + 2 + row)
        end
      end
      draw_footer(screen, box)
    end

    # "Nothing bypassed yet" and "no rules configured" are DIFFERENT facts and must not read
    # the same: the first means the rules exist and no client has hit them, the second means
    # this list can never fill. Only the second is answerable from Settings.tls_passthrough.
    private def empty_message : String
      return "(no TLS passthrough rules configured)" if Settings.tls_passthrough.empty?
      "(no host has been bypassed yet)"
    end

    # The last row inside the card: where the rules live, plus the truncation notice. The cap
    # is stated OUT LOUD rather than silently showing the first N of more (see
    # Settings::PASSTHROUGH_INVENTORY_MAX).
    private def draw_footer(screen : Screen, box : Rect) : Nil
      y = box.bottom - 2 # box.bottom - 1 is the card's bottom border (Frame.card)
      return if y <= box.y + 1
      over = Settings.passthrough_over_cap
      if over > 0
        text = "capped at #{Settings::PASSTHROUGH_INVENTORY_MAX} hosts · #{over} later bypassed connection#{over == 1 ? "" : "s"} not listed"
        screen.text(box.x + 3, y, text, Theme.yellow, Theme.panel, width: {box.w - 4, 1}.max)
      else
        # Session-global, not per-project: `tls_passthrough` is a global setting and the proxy
        # keeps running across a project switch, so this list does too. Said here because the
        # chip sits in per-project chrome, where the opposite would be the fair guess.
        screen.text(box.x + 3, y, "session-wide · edit the rules in settings:network",
          Theme.muted, Theme.panel, width: {box.w - 4, 1}.max)
      end
    end

    # host · pattern · age · connection count. The pattern gets its own column rather than
    # riding in an aside that a narrow pane can drop — naming the rule to delete is the point
    # of the row, so it is the last thing that may be squeezed, not the first.
    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      entry = @hosts[i]
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.yellow, bg)

      conns = "#{entry.connections} conn#{entry.connections == 1 ? "" : "s"}"
      stamp = ago(entry.first_seen)
      tail = "#{stamp}  #{conns}"
      tail_x = box.right - 1 - Screen.display_width(tail)

      host_x = box.x + 3
      # Split the free width between host and pattern, host first: an over-long host must not
      # push the pattern off the row entirely.
      avail = {tail_x - 1 - host_x, 2}.max
      host_w = {avail // 2, 1}.max
      drawn = screen.text(host_x, py, entry.host, sel ? Theme.text_bright : Theme.text, bg, width: host_w)
      pat_x = {drawn + 2, host_x + host_w + 1}.min
      pat_w = {tail_x - 1 - pat_x, 0}.max
      screen.text(pat_x, py, entry.pattern, Theme.yellow, bg, width: pat_w) if pat_w > 0
      screen.text(tail_x, py, tail, Theme.muted, bg) if tail_x > pat_x
    end

    # Row index under (mx,my) — inverts render's windowed layout so a click maps to the same
    # row that was drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 2)
      return nil if row < 0 || row >= cap
      i = list_window(cap) + row
      i < @hosts.size ? i : nil
    end

    # One row above the border is reserved for the footer (see draw_footer), which is the
    # single row of difference from NotificationsOverlay's otherwise identical geometry.
    private def list_capacity(box : Rect) : Int32
      {box.bottom - 2 - (box.y + 2), 0}.max
    end

    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || @hosts.size <= cap
      { {@selected - cap + 1, 0}.max, @hosts.size - cap }.min
    end

    # Compact relative age: "3s" / "5m" / "2h" / "1d". Mirrors NotificationsOverlay#ago, but
    # over a wall-clock Time (the inventory is written by a proxy fiber and read much later,
    # so it records when the bypass happened, not a monotonic tick).
    private def ago(t : Time) : String
      secs = (Time.local - t).total_seconds.to_i
      return "#{secs}s" if secs < 60
      mins = secs // 60
      return "#{mins}m" if mins < 60
      hours = mins // 60
      return "#{hours}h" if hours < 24
      "#{hours // 24}d"
    end
  end
end
