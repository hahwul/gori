require "./screen"
require "./theme"
require "./frame"
require "../url"
require "./flow_status"
require "./picker_overlay"
require "../store"

module Gori::Tui
  # The Comparer's flow picker overlay (a/b → choose a flow for slot A/B). Lists a
  # snapshot of recent flows with a type-to-filter bar (in-memory substring match —
  # no per-keystroke SQL) and returns the highlighted row.
  #
  # A dumb form object on the Overlay seam: what happens to the pick is the injected
  # `on_commit`, so the SAME picker serves the Comparer (load the flow into slot A/B,
  # Runner#comparer_pick) and the entity-link flow (attach the flow to an issue/note,
  # opened as a child of LinksOverlay) with no mode flag here. `target` survives only
  # as the card's heading.
  class FlowPicker < FilterPickerOverlay
    IDLE_HINT = "type to filter · ↑/↓ select · ↵ choose · esc cancel"

    getter target : Symbol
    @indexed : Array({Store::FlowRow, String}) # each row paired with its precomputed filter haystack

    # `scoped` — the caller drew these rows THROUGH the active Scope lens, so an empty list
    # means "nothing in scope", not "nothing captured". The picker holds rows and cannot ask
    # the Scope itself, and the two readings send the operator opposite ways: one hunts for
    # traffic gori supposedly lost, the other presses `s`.
    def initialize(@rows : Array(Store::FlowRow), @target : Symbol, @scoped : Bool = false)
      # Precompute each row's filter haystack ONCE (not per keystroke) so typing into
      # a 2000-row snapshot doesn't rebuild 2000 strings on every character.
      @indexed = @rows.map { |row| {row, haystack(row)} }
      @filtered = @rows
    end

    def selected_row : Store::FlowRow?
      @filtered[@selected]?
    end

    def entry_count : Int32
      @filtered.size
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::ComparerPick
    end

    def title : String
      "PICK FLOW"
    end

    def hint : String
      IDLE_HINT
    end

    # Recompute the visible rows from the precomputed haystacks: every whitespace-
    # separated term must appear (case-insensitive). Resets the cursor to the top.
    protected def refilter : Nil
      terms = query.downcase.split
      @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay)| terms.all? { |t| hay.includes?(t) } }.map(&.first)
      @selected = 0
      @scroll = 0
    end

    private def haystack(row : Store::FlowRow) : String
      "#{row.method} #{row.host}#{Url.origin_path(row.target)} #{row.status}".downcase
    end

    def render(screen : Screen, area : Rect) : Nil
      box, list_top, list_h = render_card(screen, area, "PICK FLOW #{@target.to_s.upcase}", IDLE_HINT, "flow picker needs a larger window") || return

      if @filtered.empty?
        # Same three-way split the Sitemap draws (sitemap_view.cr): a live filter, the lens,
        # or a genuinely empty project — never one sentence covering two of them.
        msg, hint =
          if !@rows.empty?
            {"no flows match", nil}
          elsif @scoped
            {"no flows in scope", "s toggles the lens"}
          else
            {"no flows captured yet", nil}
          end
        screen.text(box.x + 3, list_top, msg, Theme.muted, Theme.panel)
        screen.text(box.x + 3, list_top + 2, hint, Theme.muted, Theme.panel) if hint && list_h > 2
        return
      end

      each_visible_row(list_top, list_h, @filtered.size) do |ry, ri|
        draw_row(screen, box, ry, @filtered[ri], ri == @selected)
      end
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, row : Store::FlowRow, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)

      method_x = box.x + 3
      host_x = method_x + 8
      status_x = box.right - 5
      host_w = {status_x - host_x - 1, 1}.max

      screen.text(method_x, ry, row.method, Theme.method_color(row.method), bg, width: 7)
      screen.text(host_x, ry, "#{row.host}#{Url.origin_path(row.target)}", fg, bg, width: host_w)
      status, scolor = FlowStatus.cell(row)
      screen.text(status_x, ry, status, scolor, bg, width: 4)
    end
  end
end
