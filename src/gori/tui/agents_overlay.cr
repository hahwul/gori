require "./screen"
require "./fmt"
require "./theme"
require "./frame"
require "./overlay"
require "../agent_presence"
require "../plural"

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
  class AgentsOverlay < ListCard
    # Bare `t` on the selected row: message that agent without leaving for the palette (#1090).
    property on_tell : Proc(Gori::AgentPresence::Entry, Nil)?

    def initialize(@probe : Proc(Array(Gori::AgentPresence::Entry)))
      @rows = @probe.call
    end

    # Re-run the probe (bare `r`, or opening the card). Holds a COPY so a click hit-tests
    # against the frame it was drawn on.
    def reload : Nil
      @rows = @probe.call
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
    end

    # The row the cursor is on, for the tell affordance.
    def selected_entry : Gori::AgentPresence::Entry?
      @rows[@selected]?
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
      cleaned = name.scrub.gsub(/\p{C}/, "").gsub(/\s+/, " ").strip
      return nil if cleaned.empty?
      Screen.fit(cleaned, CLIENT_MAX_CELLS)
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Agents
    end

    def title : String
      "AGENTS"
    end

    def hint : String
      "↑/↓ scroll · t tell · r re-check · esc close"
    end

    # Bare `t` messages the selected agent. Same shape as on_palette: the callback drops this
    # modal and raises the prompt, so the key returns :stay rather than asking the shell to
    # close on top of it.
    private def card_key(ev : Termisu::Event::Key) : Bool
      return false unless tell?(ev)
      (entry = selected_entry) && on_tell.try(&.call(entry))
      true
    end

    # Bare `t` — a mnemonic, so the ctrl/alt guard keeps `^T` off it, same as the `r` arm
    # (`ListCard#handle_nav`).
    private def tell?(ev : Termisu::Event::Key) : Bool
      return false if ev.ctrl? || ev.alt?
      (ev.char || ev.key.to_char) == 't' && !on_tell.nil? && !selected_entry.nil?
    end

    def entry_count : Int32
      @rows.size
    end

    # 76 columns for a row that carries a client, a pid, an attach time, a mode, and a selection
    # source without any of them being the one squeezed out.
    private def card_w : Int32
      76
    end

    private def meta : String
      Gori.plural(@rows.size, "client")
    end

    private def empty_text : String
      "(no MCP client is attached to this project)"
    end

    private def too_small_what : String
      "agent list needs a larger window"
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
      attached = row.attached_at.try { |t| "attached #{Fmt.ago_phrase(Time.utc - t)}" } || "attached ?"
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
  end
end
