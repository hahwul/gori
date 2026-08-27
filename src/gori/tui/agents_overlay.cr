require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "../agent_presence"

module Gori::Tui
  # The MCP clients bound to THIS project (#815), opened from the `mcp:` top-bar chip or the
  # app.agents palette entry. Read-only — every row is a live `gori mcp` process, held there by
  # its own flock, and the TUI edits none of it. Modelled on ListenersOverlay: another read-only
  # inventory reached from a top-bar chip.
  #
  #   claude-code (2.1.0)   pid 48213   attached 3m ago   actions   via workspace-created
  #   (unnamed client)      pid 51002   attached just now read-only via switch_project
  #
  # Rows come from an INJECTED probe rather than a live filesystem read per draw, so a spec can
  # verify the render with a fixed list and no `.agents` directory — and, like the listeners
  # overlay, so the rows cannot shift under a click hit-tested against the previous frame.
  class AgentsOverlay < Overlay
    # ^P leaves for the command palette, like every other list overlay.
    property on_palette : Proc(Nil)?

    def initialize(@probe : Proc(Array(Gori::AgentPresence::Entry)))
      @selected = 0
      @rows = @probe.call
    end

    # Re-run the probe (bare `r`, or opening the card). Holds a COPY so a click hit-tests
    # against the frame it was drawn on.
    def reload : Nil
      @rows = @probe.call
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
    end

    def rows : Array(Gori::AgentPresence::Entry)
      @rows
    end

    # The top-bar chip label for a set of attached clients (#815). Pure so a spec pins it
    # without a Runner:
    #   []              → ""              (no chip — nothing is attached)
    #   ["claude-code"] → "mcp:claude-code"
    #   [nil]           → "mcp"           (attached, name unknown)
    #   ["a", "b"]      → "mcp:a +1"
    #   [nil, nil]      → "mcp +1"
    # The name is run through `safe_client` first — a handshake string is not trusted.
    def self.chip_label(clients : Array(String?)) : String
      return "" if clients.empty?
      first = safe_client(clients.first)
      base = first ? "mcp:#{first}" : "mcp"
      clients.size > 1 ? "#{base} +#{clients.size - 1}" : base
    end

    # A client name is a value the peer sent over the handshake — hostile text, same stance as
    # a captured method or header. Strip control characters (`\p{C}`), collapse whitespace, and
    # cap the display width so a pathological name cannot blow out the chip or a card row.
    CLIENT_MAX_CELLS = 24

    def self.safe_client(name : String?) : String?
      return nil unless name
      cleaned = name.gsub(/\p{C}/, "").gsub(/\s+/, " ").strip
      return nil if cleaned.empty?
      Screen.fit(cleaned, CLIENT_MAX_CELLS)
    end

    # Relative "attached N ago" wording — the picker's own vocabulary ("just now", "3m ago"),
    # written here rather than reached into the picker so this overlay stays spec-testable on
    # its own.
    def self.relative_time(span : Time::Span) : String
      secs = span.total_seconds
      return "just now" if secs < 60
      return "#{(secs / 60).to_i}m ago" if secs < 3600
      return "#{(secs / 3600).to_i}h ago" if secs < 86_400
      "#{(secs / 86_400).to_i}d ago"
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Agents
    end

    def title : String
      "AGENTS"
    end

    def hint : String
      "↑/↓ scroll · r re-check · esc close"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      if ev.ctrl? && k.lower_p?
        on_palette.try(&.call)
      elsif k.escape?
        return :cancel
      else
        handle_nav(ev)
      end
      :stay
    end

    # ↑/↓ + j/k, and bare `r` to re-check. The ctrl/alt guard is the same one ListenersOverlay
    # documents at length: `Event::Key#char` folds ^R back to 'r' and the termisu parser emits
    # ^K as `Key::LowerK + Ctrl`, so a chord would otherwise trigger the letter arms. Claimed
    # and dropped rather than fallen through, because this overlay returns :stay either way.
    private def handle_nav(ev : Termisu::Event::Key) : Nil
      k = ev.key
      if k.up?
        move(-1)
      elsif k.down?
        move(1)
      elsif ev.ctrl? || ev.alt?
        # a chord is not a mnemonic
      elsif k.lower_k?
        move(-1)
      elsif k.lower_j?
        move(1)
      elsif (ev.char || k.to_char) == 'r'
        reload
      end
    end

    # A click inside selects a row (nothing to open); outside dismisses. Never :commit — a
    # read-only list that closed itself on a row click would look like it had acted.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if row = gauge_row_at(box, mx, my)
        set_selected(row)
      elsif idx = row_at(box, mx, my)
        set_selected(idx)
      end
      :stay
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {@rows.size - 1, 0}.max)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@rows.size - 1, 0}.max)
    end

    # Same geometry as ListenersOverlay — the sibling read-only list. 76 columns for a row that
    # carries a client, a pid, an attach time, a mode, and a selection source without any of them
    # being the one squeezed out.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 76}.min
      rows = {@rows.size, 6}.max
      h = {area.h - 2, rows + 4}.min # title gap + list + footer + bottom border
      return nil if w < 32 || h < 7
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "agent list needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "AGENTS", border: Theme.border_focus)
      meta = "#{@rows.size} client#{@rows.size == 1 ? "" : "s"}"
      Frame.border_meta(screen, box, "AGENTS", meta, bg: Theme.panel)

      cap = list_capacity(box)
      return if cap <= 0
      start = list_window(cap)
      if @rows.empty?
        screen.text(box.x + 3, box.y + 2, "(no MCP client is attached to this project)", Theme.muted, Theme.panel)
      else
        cap.times do |row|
          i = start + row
          break if i >= @rows.size
          draw_row(screen, box, i, box.y + 2 + row)
        end
      end
      Frame.scroll_gauge(screen, Rect.new(box.x + 1, box.y + 2, box.w - 2, cap),
        @rows.size, start, true, Theme.panel)
      draw_footer(screen, box)
    end

    # What the list itself cannot say: these rows are processes, they vanish on their own when
    # the process exits, and `r` re-checks. The same role ListenersOverlay's footer plays.
    private def draw_footer(screen : Screen, box : Rect) : Nil
      y = box.bottom - 2
      return if y <= box.y + 1
      screen.text(box.x + 3, y,
        "rows are gori mcp processes bound to this project · a row leaves when its process exits · r re-checks",
        Theme.muted, Theme.panel, width: {box.w - 4, 1}.max)
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      row = @rows[i]
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)

      # Every segment is clipped to the card's inner right edge (`right`). `screen.text` with no
      # width clips to the WHOLE SCREEN, not the card — so a long client name (safe_client caps
      # each of name and version at 24 cells, ~51 together) or a narrow card (overlay_box allows
      # down to 32 wide) would push `pid`/`attached`/`mode` past `box.right`, painting over the
      # Frame.card border and into the backdrop. `draw_seg` bounds each and advances x by only
      # what it drew, so a truncated field stops the row instead of overrunning it.
      right = box.right - 2
      x = box.x + 3
      name = AgentsOverlay.safe_client(row.client) || "(unnamed client)"
      label = row.client_version ? "#{name} (#{AgentsOverlay.safe_client(row.client_version) || "?"})" : name
      x = draw_seg(screen, x, py, label, sel ? Theme.text_bright : Theme.text, bg, right)
      x = draw_seg(screen, x + 2, py, row.pid ? "pid #{row.pid}" : "pid ?", Theme.muted, bg, right)
      attached = row.attached_at.try { |t| "attached #{AgentsOverlay.relative_time(Time.utc - t)}" } || "attached ?"
      x = draw_seg(screen, x + 2, py, attached, Theme.muted, bg, right)
      mode = row.read_only ? "read-only" : "actions"
      x = draw_seg(screen, x + 2, py, mode, row.read_only ? Theme.muted : Theme.accent, bg, right)
      # selection_source is gori's own word (workspace-created / switch_project / …), not a
      # handshake string, so it needs no safe_client — draw_seg's width bound handles length.
      if src = row.selection_source
        draw_seg(screen, x + 2, py, "via #{src}", Theme.muted, bg, right)
      end
    end

    # Draw one row segment clipped to `right` (the card's last drawable inner column) and return
    # the x just past what was drawn. A segment that would start at or past `right` draws nothing
    # and returns `x` unchanged, so the next segment's `x + 2` cannot march off the card either.
    private def draw_seg(screen : Screen, x : Int32, py : Int32, text : String, fg : Color,
                         bg : Color, right : Int32) : Int32
      avail = right - x
      return x if avail <= 0
      screen.text(x, py, text, fg, bg, width: avail)
    end

    def gauge_row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      Frame.scroll_gauge_row(Rect.new(box.x + 1, box.y + 2, box.w - 2, list_capacity(box)),
        @rows.size, mx, my)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 2)
      return nil if row < 0 || row >= cap
      i = list_window(cap) + row
      i < @rows.size ? i : nil
    end

    private def list_capacity(box : Rect) : Int32
      {box.bottom - 2 - (box.y + 2), 0}.max
    end

    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || @rows.size <= cap
      { {@selected - cap + 1, 0}.max, @rows.size - cap }.min
    end
  end
end
