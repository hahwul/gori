require "./screen"
require "./theme"
require "./frame"
require "../url"
require "./flow_status"
require "./picker_overlay"
require "../store"

module Gori::Tui
  # The Comparer and entity-link picker searches saved flow labels and shows a bounded
  # window of matches. Only the selected row is handed to the caller.
  #
  # A dumb form object on the Overlay seam: what happens to the pick is the injected
  # `on_commit`, so the SAME picker serves the Comparer (load the flow into slot A/B,
  # Runner#comparer_pick) and the entity-link flow (attach the flow to an issue/note,
  # opened as a child of LinksOverlay) with no mode flag here. `target` survives only
  # as the card's heading.
  class FlowPicker < FilterPickerOverlay
    DISPLAY_LIMIT = 500
    SEARCH_DELAY  = 175.milliseconds

    getter target : Symbol
    @indexed : Array({Store::FlowRow, String})
    @search_at : Time::Instant? = nil
    @control : Store::QueryControl? = nil
    @search_error : String? = nil
    @search_changed = false
    @more_results = false

    # `scoped` — the caller drew these rows THROUGH the active Scope lens, so an empty list
    # means "nothing in scope", not "nothing captured". The picker holds rows and cannot ask
    # the Scope itself, and the two readings send the operator opposite ways: one hunts for
    # traffic gori supposedly lost, the other presses `s`.
    def initialize(@rows : Array(Store::FlowRow), @target : Symbol, @scoped : Bool = false, *,
                   @store : Store? = nil, @filter : QL::Filter = QL::EMPTY, @hide_static : Bool = false,
                   @limit : Int32 = DISPLAY_LIMIT)
      @indexed = @rows.map { |row| {row, haystack(row)} }
      @filtered = @rows
      @search_at = Time.instant if @store
    end

    def self.for_store(store : Store, target : Symbol, filter : QL::Filter = QL::EMPTY, *,
                       scoped : Bool = false, hide_static : Bool = false, limit : Int32 = DISPLAY_LIMIT) : self
      new([] of Store::FlowRow, target, scoped, store: store, filter: filter, hide_static: hide_static, limit: limit)
    end

    def tick(now : Time::Instant) : Bool
      if (at = @search_at) && at <= now && (store = @store)
        @search_at = nil
        start_search(store, query)
      end
      changed = @search_changed
      @search_changed = false
      changed
    end

    def deactivate : Nil
      cancel_search
    end

    private def cancel_search : Nil
      @search_at = nil
      @control.try(&.cancel)
      @control = nil
    end

    private def start_search(store : Store, text : String) : Nil
      control = Store::QueryControl.new
      @control = control
      spawn(name: "gori-flow-picker-search") do
        rows = store.search_flow_labels(text, @filter, @limit + 1, control: control)
        next unless @control.same?(control)
        @more_results = rows.size > @limit
        rows.pop if @more_results
        @filtered = rows
      rescue Store::QueryCancelled
        # An edit or dismissal replaced this query.
      rescue ex
        @search_error = "could not search flows" if @control.same?(control)
        ::Log.warn(exception: ex) { "flow picker search failed" }
      ensure
        if @control.same?(control)
          @control = nil
          @search_changed = true
        end
      end
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
      return "type to filter · esc cancel" if @filtered.empty?
      "type to filter · ↑/↓ select · ↵ choose · esc cancel"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      return :stay if ev.key.enter? && @filtered.empty?
      super
    end

    # Recompute the visible rows from the precomputed haystacks: every whitespace-
    # separated term must appear (case-insensitive). Resets the cursor to the top.
    protected def refilter : Nil
      if @store
        cancel_search
        @search_error = nil
        @more_results = false
        @filtered = [] of Store::FlowRow
        @search_at = Time.instant + SEARCH_DELAY
      else
        terms = query.downcase.split
        @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay)| terms.all? { |t| hay.includes?(t) } }.map(&.first)
      end
      @selected = 0
      @scroll = 0
    end

    private def haystack(row : Store::FlowRow) : String
      "#{row.method} #{row.host}#{Url.origin_path(row.target)} #{row.status}".downcase
    end

    def render(screen : Screen, area : Rect) : Nil
      box, list_top, list_h = render_card(screen, area, "PICK FLOW #{@target.to_s.upcase}", "flow picker needs a larger window") || return

      if @filtered.empty?
        msg, hint = empty_message
        screen.text(box.x + 3, list_top, msg, Theme.muted, Theme.panel, width: box.w - 4)
        screen.text(box.x + 3, list_top + 1, hint, Theme.muted, Theme.panel, width: box.w - 4) if hint && list_h > 1
        return
      end

      if @more_results
        screen.text(box.x + 2, list_top - 1, " #{@limit} shown · refine filter ", Theme.muted, Theme.panel, width: box.w - 4)
      end
      each_visible_row(list_top, list_h, @filtered.size) do |ry, ri|
        draw_row(screen, box, ry, @filtered[ri], ri == @selected)
      end
    end

    private def empty_message : {String, String?}
      return {"searching flows…", nil} if @search_at || @control
      if error = @search_error
        return {error, nil}
      end
      return {"no flows match", nil} unless query.blank?
      return {"no flows in scope", "Esc, then disable Scope lens"} if @scoped && !@hide_static
      return {"no flows visible", "Esc, then check the filters"} if @scoped
      return {"no flows visible", "Esc, then show static assets"} if @hide_static
      {"no flows captured yet", nil}
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
