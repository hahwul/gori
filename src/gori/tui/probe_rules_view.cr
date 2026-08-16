require "./screen"
require "./theme"
require "./frame"
require "../probe"
require "../store"
require "./viewport"

module Gori::Tui
  # The Probe tab's "Rules" sub-tab body: a navigable list of the scan rules that drive the
  # Findings sub-tab. Three sections — built-in PASSIVE and ACTIVE rules (per-rule enable/disable,
  # stored per project) and user-defined CUSTOM rules (string/regex matches, global or project
  # scope). Purely presentational: it owns the row list + selection + rendering; the controller
  # performs every persistence write (toggle / add / edit / delete) then calls reload.
  class ProbeRulesView
    # One displayed line: a non-selectable section HEADER, a built-in TOGGLE row, or a CUSTOM
    # rule row. `enabled` drives the [x]/[ ] box; `rule_id` is the built-in RuleInfo#id (toggle
    # key); `custom` carries the whole rule for edit/delete. `note` is a short right-aligned
    # badge ("opt-in", "needs OAST") and `desc` the one-line description shown in the footer
    # when this row is selected.
    struct Row
      getter kind : Symbol # :header | :empty | :builtin | :custom
      getter title : String
      getter meta : String
      getter? enabled : Bool
      getter rule_id : String
      getter custom : Probe::CustomRule?
      getter note : String
      getter desc : String

      def initialize(@kind, @title, @meta = "", @enabled = true, @rule_id = "", @custom = nil,
                     @note = "", @desc = "")
      end

      # An `:empty` placeholder is no more selectable than a header — it names an absence.
      # It used to be built AS a header, which drew it accent+bold like a section title;
      # it is its own kind now so it can read as the quiet prose it is.
      def selectable? : Bool
        kind != :header && kind != :empty
      end
    end

    def initialize
      @rows = [] of Row
      @sel = 0
      @scroll = 0
    end

    # Rebuild the row list from the built-in registries + this project's disabled set + the merged
    # global/project custom rules. Keeps the selection on a live selectable row.
    def reload(store : Store) : Nil
      disabled = store.probe_disabled_rules
      # Whether this project has a registered OAST listener. The out-of-band rules (ssrf_oast)
      # plan nothing without one, so the list SAYS so rather than showing a request cost the
      # rule cannot actually pay until a listener exists.
      oob_ready = oob_ready?(store)
      rows = [] of Row
      rows << Row.new(:header, "PASSIVE RULES")
      Probe::Passive::RULES.each { |r| rows << builtin_row(r.info, disabled) }
      # Sum the per-flow request cost of the ENABLED active rules so the header states the
      # automatic scan's volume up front — the one number an operator weighs before turning
      # Active on. Out-of-band rules cost nothing until a listener exists, so they are excluded
      # from the total unless one is (their sends are gated on the minter, not on the toggle).
      rows << Row.new(:header, "ACTIVE RULES", active_total_meta(disabled, oob_ready))
      Probe::Active::RULES.each { |r| rows << active_builtin_row(r, disabled, oob_ready) }
      rows << Row.new(:header, "CUSTOM RULES")
      custom = Probe.custom_rules(store)
      if custom.empty?
        rows << Row.new(:empty, "  no custom rules — press a to add")
      else
        custom.each { |c| rows << custom_row(c) }
      end
      @rows = rows
      clamp_selection
    end

    private def oob_ready?(store : Store) : Bool
      !store.oast_sessions.empty?
    rescue
      false
    end

    private def builtin_row(info : Probe::RuleInfo, disabled : Set(String)) : Row
      Row.new(:builtin, info.name, info.category, !disabled.includes?(info.id), info.id,
        desc: info.description)
    end

    # An active rule's row carries its per-flow request estimate next to the category, e.g.
    # "active · 1 req/flow" — the request cost the user asked to see for each active-scan item.
    # A default-OFF rule is badged "opt-in" (it ships disabled and must be turned on); an
    # out-of-band rule with no listener is badged "needs OAST" (enabled, but inert until one).
    private def active_builtin_row(rule : Probe::Active::Rule, disabled : Set(String),
                                   oob_ready : Bool) : Row
      info = rule.info
      meta = "#{info.category} · #{Probe::Active.estimate_label(rule.requests_per_flow)}"
      note = if Probe::DEFAULT_DISABLED_RULES.includes?(info.id)
               "opt-in"
             elsif Probe::OOB_RULE_IDS.includes?(info.id) && !oob_ready
               "needs OAST"
             else
               ""
             end
      Row.new(:builtin, info.name, meta, Probe.rule_enabled?(info.id, disabled), info.id,
        note: note, desc: info.description)
    end

    # Total per-flow request cost of the enabled active rules, as a header annotation. Sums the
    # low end of each rule's range (the differential rules quote a range; the low end is the
    # honest floor for a "how loud is Active" number). Out-of-band rules are counted only when a
    # listener makes their sends real.
    private def active_total_meta(disabled : Set(String), oob_ready : Bool) : String
      total = 0
      Probe::Active::RULES.each do |r|
        next unless Probe.rule_enabled?(r.info.id, disabled)
        next if Probe::OOB_RULE_IDS.includes?(r.info.id) && !oob_ready
        total += r.requests_per_flow.begin
      end
      "~#{total} req/flow enabled"
    end

    private def custom_row(c : Probe::CustomRule) : Row
      scope = c.global? ? "GLOBAL" : "PROJECT"
      Row.new(:custom, c.title, "#{scope} · #{c.side}/#{c.region} · #{c.kind}", c.enabled, c.code, c,
        desc: c.description)
    end

    def selected_row : Row?
      @rows[@sel]?
    end

    def selected_index : Int32
      @sel
    end

    # True when the highlight is on the first selectable row (↑ there pops to the sub-tab strip).
    def at_top? : Bool
      idxs = selectable_indices
      idxs.empty? || @sel == idxs.first
    end

    # Move the highlight among selectable rows (headers are skipped), clamped, no wrap.
    def move(delta : Int32) : Nil
      idxs = selectable_indices
      return if idxs.empty?
      pos = idxs.index(@sel) || 0
      @sel = idxs[(pos + delta).clamp(0, idxs.size - 1)]
    end

    def select_index(idx : Int32) : Nil
      @sel = idx if 0 <= idx < @rows.size && @rows[idx].selectable?
    end

    # Rows the list actually windows, once the description footer has taken its share.
    # `render`, `row_at` and `gauge_row_at` must all ask this the same way or they drift —
    # `row_at` used to take the whole rect, so a click on the FOOTER (prose about the selected
    # rule) resolved to the row one past the last visible one. Same shape as the Colormarker
    # note row and the Sitemap tag prompt.
    private def list_h(rect : Rect) : Int32
      (footer_text && rect.h >= 3) ? rect.h - 1 : rect.h
    end

    def row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless rect.contains?(mx, my)
      i = my - rect.y
      return nil if i < 0 || i >= list_h(rect)
      idx = @scroll + i
      (0 <= idx < @rows.size) ? idx : nil
    end

    # The row a click on the list's scroll gauge asks for. The gauge rides the card's right
    # hairline; the window is derived from the selection, so this answers with a selection.
    #
    # SNAPPED to the nearest selectable row: `@rows` interleaves three `:header` rows and an
    # `:empty` placeholder with the real ones, and `select_index` refuses those — so a raw
    # proportional hit made ~4 of ~40 track positions silent no-ops, a thumb that moved
    # nowhere. Every other gauge in this sweep resolves to a row the click can land on.
    def gauge_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      idx = Frame.scroll_gauge_row(Rect.new(rect.x, rect.y, rect.w, list_h(rect)), @rows.size, mx, my)
      return nil unless idx
      nearest_selectable(idx)
    end

    # The selectable row closest to `idx`, searching outward. nil only when the list holds no
    # selectable row at all (a filter that matched nothing).
    private def nearest_selectable(idx : Int32) : Int32?
      return idx if @rows[idx]?.try(&.selectable?)
      (1...@rows.size).each do |d|
        [idx - d, idx + d].each do |i|
          return i if 0 <= i < @rows.size && @rows[i].selectable?
        end
      end
      nil
    end

    private def selectable_indices : Array(Int32)
      (0...@rows.size).select { |i| @rows[i].selectable? }
    end

    private def clamp_selection : Nil
      idxs = selectable_indices
      @sel = idxs.empty? ? 0 : (idxs.includes?(@sel) ? @sel : idxs.first)
    end

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      # Reserve the bottom line for the selected rule's description when there is room — the one
      # place the Rules tab explains what a rule DOES, so an operator toggling it isn't guessing
      # from the name. Falls away on a very short pane (the list keeps every line it can).
      footer = footer_text
      list_h = list_h(rect)
      ensure_visible(list_h)
      list_h.times do |i|
        idx = @scroll + i
        break if idx >= @rows.size
        draw_row(screen, rect, @rows[idx], idx, rect.y + i, focused)
      end
      if footer && rect.h >= 3
        y = rect.bottom - 1
        screen.fill(Rect.new(rect.x, y, rect.w, 1), Theme.bg)
        screen.text(rect.x + 1, y, footer, Theme.muted, Theme.bg, width: rect.w - 2)
      end
      # This list runs to ~40 rows across three sections and had no scroll affordance at all,
      # so an operator scrolled past the ACTIVE section with nothing on screen saying there
      # was more. Tracks `list_h`, the rows actually windowed — not the footer under them.
      Frame.scroll_gauge(screen, Rect.new(rect.x, rect.y, rect.w, list_h),
        @rows.size, @scroll, focused)
    end

    # The selected selectable row's description, or nil (a header selected / no description).
    private def footer_text : String?
      row = @rows[@sel]?
      return nil unless row && row.selectable?
      row.desc.empty? ? nil : row.desc
    end

    # `@rows` is the flattened section list (headers + rules) the draw loop walks.
    private def ensure_visible(avail : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@sel, @scroll, avail, @rows.size)
    end

    # A section header: bold title, plus a right-aligned annotation when it carries one (the
    # ACTIVE total cost).
    private def draw_header(screen : Screen, rect : Rect, row : Row, y : Int32) : Nil
      screen.text(rect.x + 1, y, row.title, Theme.accent, Theme.bg, attr: Attribute::Bold)
      return if row.meta.empty?
      mx = rect.right - row.meta.size - 1
      screen.text(mx, y, row.meta, Theme.muted, Theme.bg) if mx > rect.x + row.title.size + 2
    end

    private def draw_row(screen : Screen, rect : Rect, row : Row, idx : Int32, y : Int32, focused : Bool) : Nil
      return draw_header(screen, rect, row, y) if row.kind == :header
      if row.kind == :empty
        screen.text(rect.x + 1, y, row.title.strip, Theme.muted, Theme.bg, width: {rect.w - 2, 1}.max)
        return
      end
      sel = idx == @sel
      bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
      screen.cell(rect.x, y, sel ? '▎' : ' ', Theme.accent, bg)
      # `✓`/`·` in accent — the same mark the Rewriter and Colormarker lists use for the same
      # question. This list used to answer it with a green `[x]`/`[ ]`, so three rule lists an
      # operator moves between spelled one state three ways. The checkbox also cost two extra
      # columns, which is why the name starts at +4 now rather than +6: same offsets as the
      # siblings, so the three lists line up when you switch tabs.
      screen.cell(rect.x + 2, y, row.enabled? ? '✓' : '·', row.enabled? ? Theme.accent : Theme.muted, bg)
      namex = rect.x + 4
      name_fg = sel ? Theme.text_bright : (row.enabled? ? Theme.text : Theme.muted)
      # The right side (meta column + optional note badge) is laid out first, so the name gets
      # whatever width remains to its left.
      nx = draw_annotations(screen, rect, row, y, namex, bg)
      namew = {nx - namex - 1, 0}.max
      screen.text(namex, y, row.title, name_fg, bg, width: namew)
    end

    # Draw the right-aligned meta column and, left of it, the yellow note badge ("opt-in" /
    # "needs OAST"). Returns the x where the name must stop.
    private def draw_annotations(screen : Screen, rect : Rect, row : Row, y : Int32, namex : Int32, bg : Color) : Int32
      rx = rect.right - row.meta.size - 1
      screen.text(rx, y, row.meta, Theme.muted, bg) if !row.meta.empty? && rx > namex
      return rx if row.note.empty?
      nx = rx - row.note.size - 2
      screen.text(nx, y, row.note, Theme.yellow, bg) if nx > namex
      nx
    end
  end
end
