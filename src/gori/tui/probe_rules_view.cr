require "./screen"
require "./theme"
require "../probe"
require "../store"

module Gori::Tui
  # The Probe tab's "Rules" sub-tab body: a navigable list of the scan rules that drive the
  # Findings sub-tab. Three sections — built-in PASSIVE and ACTIVE rules (per-rule enable/disable,
  # stored per project) and user-defined CUSTOM rules (string/regex matches, global or project
  # scope). Purely presentational: it owns the row list + selection + rendering; the controller
  # performs every persistence write (toggle / add / edit / delete) then calls reload.
  class ProbeRulesView
    # One displayed line: a non-selectable section HEADER, a built-in TOGGLE row, or a CUSTOM
    # rule row. `enabled` drives the [x]/[ ] box; `rule_id` is the built-in RuleInfo#id (toggle
    # key); `custom` carries the whole rule for edit/delete.
    struct Row
      getter kind : Symbol # :header | :builtin | :custom
      getter title : String
      getter meta : String
      getter? enabled : Bool
      getter rule_id : String
      getter custom : Probe::CustomRule?

      def initialize(@kind, @title, @meta = "", @enabled = true, @rule_id = "", @custom = nil)
      end

      def selectable? : Bool
        kind != :header
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
      rows = [] of Row
      rows << Row.new(:header, "PASSIVE RULES")
      Probe::Passive::RULES.each { |r| rows << builtin_row(r.info, disabled) }
      rows << Row.new(:header, "ACTIVE RULES")
      Probe::Active::RULES.each { |r| rows << active_builtin_row(r, disabled) }
      rows << Row.new(:header, "CUSTOM RULES")
      custom = Probe.custom_rules(store)
      if custom.empty?
        rows << Row.new(:header, "  (none — press a to add a custom rule)")
      else
        custom.each { |c| rows << custom_row(c) }
      end
      @rows = rows
      clamp_selection
    end

    private def builtin_row(info : Probe::RuleInfo, disabled : Set(String)) : Row
      Row.new(:builtin, info.name, info.category, !disabled.includes?(info.id), info.id)
    end

    # An active rule's row carries its per-flow request estimate next to the category, e.g.
    # "active · 1 req/flow" — the request cost the user asked to see for each active-scan item.
    private def active_builtin_row(rule : Probe::Active::Rule, disabled : Set(String)) : Row
      info = rule.info
      meta = "#{info.category} · #{Probe::Active.estimate_label(rule.requests_per_flow)}"
      Row.new(:builtin, info.name, meta, !disabled.includes?(info.id), info.id)
    end

    private def custom_row(c : Probe::CustomRule) : Row
      scope = c.global? ? "GLOBAL" : "PROJECT"
      Row.new(:custom, c.title, "#{scope} · #{c.side}/#{c.region} · #{c.kind}", c.enabled, c.code, c)
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

    def row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless rect.contains?(mx, my)
      idx = @scroll + (my - rect.y)
      (0 <= idx < @rows.size) ? idx : nil
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
      ensure_visible(rect.h)
      rect.h.times do |i|
        idx = @scroll + i
        break if idx >= @rows.size
        draw_row(screen, rect, @rows[idx], idx, rect.y + i, focused)
      end
    end

    private def ensure_visible(avail : Int32) : Nil
      return if avail <= 0
      @scroll = @sel if @sel < @scroll
      @scroll = @sel - avail + 1 if @sel >= @scroll + avail
      @scroll = @scroll.clamp(0, {@rows.size - avail, 0}.max)
    end

    private def draw_row(screen : Screen, rect : Rect, row : Row, idx : Int32, y : Int32, focused : Bool) : Nil
      if row.kind == :header
        screen.text(rect.x + 1, y, row.title, Theme.accent, Theme.bg, attr: Attribute::Bold)
        return
      end
      sel = idx == @sel
      bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
      screen.cell(rect.x, y, sel ? '▎' : ' ', Theme.accent, bg)
      box = row.enabled? ? "[x]" : "[ ]"
      screen.text(rect.x + 2, y, box, row.enabled? ? Theme.green : Theme.muted, bg)
      namex = rect.x + 6
      name_fg = sel ? Theme.text_bright : (row.enabled? ? Theme.text : Theme.muted)
      rx = rect.right - row.meta.size - 1
      namew = {rx - namex - 1, 0}.max
      screen.text(namex, y, row.title, name_fg, bg, width: namew)
      screen.text(rx, y, row.meta, Theme.muted, bg) if !row.meta.empty? && rx > namex
    end
  end
end
