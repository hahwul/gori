require "./screen"
require "./frame"
require "./theme"
require "../verb"
require "../hotkeys"

module Gori::Tui
  # The "space" action menu — a leader popup CENTERED in the body. Pressing space in
  # a navigable area opens it; it lists that area's own verbs (the Verb::Scope +
  # Verb::Section captured at open), each fronted by a single mnemonic key. Pressing
  # the key runs the verb through the SAME Verb::Definition#call path as a keybinding
  # and the palette (P1 — no separate execution path).
  #
  # Where Ctrl-P's PaletteState is a centered fuzzy-typed modal (Global verbs, plus this
  # same area's verbs once a query is typed — #1282), the space menu is mnemonic-only (no
  # text input, no fuzzy filter): the shown set is exactly `Registry#for_view` narrowed to
  # verbs the menu lists (`Definition#menu_listed?`). THAT — the interaction, not the position — is what keeps
  # the two surfaces from collapsing into each other. Both are centered cards; one is typed,
  # one is one-keypress. Adding a query line here would make it a second palette wherever it
  # was drawn — typing already has a home, and it finds these rows too.
  #
  # Grouping runs on two orthogonal axes:
  #   * `Verb::Definition#section` — FOCUS AREA. Splits into a COMMON band (tab-wide)
  #     and a CONTEXT band (the focused pane / tab bar / sub-tab strip). A section's
  #     verbs appear ONLY while that area is focused.
  #   * `Verb::Definition#group` — SEMANTIC BAND (VIEW / SEND / TRIAGE / COPY / SCOPE /
  #     DANGER). Never gates visibility; it subdivides whatever bands `section`
  #     produced. This is what makes the single-region scopes scannable — History's
  #     Body is 19 entries with no focus sub-areas at all, so `section` alone can
  #     never break it up.
  # A bucket whose verbs are all `:none` keeps its own label and renders exactly as it
  # did before, so an untagged scope is untouched.
  #
  # Layout is a single narrow column until that column would not fit, then COLUMN-MAJOR
  # multi-column (see #layout) — read down, then across. Group headers never strand at
  # a column's last row (#pad_rows); a group larger than the space left in a column
  # does continue into the next one, which reads correctly in down-then-across order.
  # Two levels (#1274 WP9). A `Verb::Family` draws as ONE row at level 1, under its own key
  # and in its own band; the key (or ↵/a click on the row) re-draws the card with the family's
  # members, each on the letter the family table gives its intent (#descend), and esc/⌫ come
  # back up (#back). The row is drawn whenever the view REGISTERS a member — never decided by
  # `available?`, and never collapsed into a lone member — so the keys that reach a member are
  # the same in every state of the tab.
  #
  # Pure input/state + rendering; the Runner owns opening/closing, capturing the
  # scope+section, and executing the selection.
  class SpaceMenu
    # Tallest ONE COLUMN may grow before the layout either adds a column or (when it
    # can't) scrolls. box() still clamps to the body, so this is only the "don't grow
    # past this even on a tall terminal" ceiling. History's Body — the busiest scope at
    # 19 entries, 25 rows with its semantic headers — exceeds this on purpose: it is
    # what a second column is for.
    MAX_ROWS = 16

    # Fixed per-row chrome around the title: left border(1) + selection indicator(1) +
    # mnemonic key(1) + gap(1) + scroll-marker column(1) + right border(1) = 6, plus
    # room for an optional dim direct-chord label (e.g. `^R`) when the verb has a
    # rebindable binding that differs from the space mnemonic. At ncols == 1 this is
    # exactly the box width over the title; see #cell_w for the multi-column split.
    CHROME = 6

    SECTION_LABELS = {
      :common => "COMMON", :request => "REQUEST", :response => "RESPONSE", :target => "TARGET",
      :template => "TEMPLATE", :config => "CONFIG", :results => "RESULTS", :detail => "DETAIL",
      :input => "INPUT", :chain => "CHAIN", :output => "OUTPUT", :tab => "SUB-TABS", :subtab => "SUB-TABS",
    } of Symbol => String

    # The one label both strip sections render under. `:subtab` (new/close/duplicate/rename/
    # tag/mark) and `:tab` (search/filter the strip) are the SAME IDEA — they only ever
    # differed in which focus level used to reveal them — so they are one bucket here.
    SUBTAB_LABEL = SECTION_LABELS[:subtab]

    # The semantic bands a bucket is subdivided into, in RENDER ORDER — read top-to-
    # bottom / left-to-right, so the order is the reading order and the destructive
    # bands land last, in severity order (a destructive key is never the neighbour of
    # the key above it by accident, and the widest blast radius sits at the very end).
    # A verb's Verb::Definition#group picks its band; :none-tagged verbs are not
    # subdivided at all (see #split_semantic).
    GROUP_ORDER = [:view, :send, :triage, :copy, :scope, :danger, :wipe]

    GROUP_LABELS = {
      :view   => "VIEW",   # inspect / filter / display toggles — changes what you SEE
      :send   => "SEND",   # hand the selection to another tool (Repeater, Fuzzer, …)
      :triage => "TRIAGE", # mark, tag, file, link, promote — engagement bookkeeping
      :copy   => "COPY",   # copy out (clipboard / copy-as)
      :scope  => "SCOPE",  # scope lens + scope membership
      :danger => "DANGER", # permanently deletes the SELECTED item(s) — a flow, a rule, a var
      :wipe   => "WIPE",   # empties the whole tab/project store — the ⇧X verbs (#899)
    } of Symbol => String

    # The bands that destroy stored data. They close the card in every bucket — after the
    # untagged leftovers too — so a destructive key never sits above an ordinary one.
    DESTRUCTIVE_GROUPS = {:danger, :wipe}

    # Below this many interior rows a column is too stubby to be worth splitting into,
    # so a very short terminal keeps the single-column vertical scroll (▲/▼) instead of
    # sprouting 3-row columns. Only consulted when the list does not already fit.
    MIN_COL_ROWS = 8

    # Gap between adjacent columns in the multi-column layout.
    COL_GAP = 2

    getter selected : Int32

    # The level-2 card's only row when the view registers members of the family but none is
    # available right now. The family key opened a card rather than dismissing, so a second
    # key typed blind lands here instead of reaching the pane behind it.
    INERT_TITLE = "nothing here right now"

    # One row of the card:
    #   * a VERB row (`verb` set) runs its verb — at level 1 on its `menu_key`, at level 2 on
    #     its family letter;
    #   * a FAMILY row (`family` set, level 1 only) descends into the family;
    #   * an INERT row (neither) is the dim "nothing here right now" line.
    # `id`/`title`/`menu_key`/`scope` read like the Definition an entry used to be, so a
    # caller that only asks those questions does not care which kind it holds.
    struct Entry
      getter key : Char?
      getter scope : Verb::Scope
      getter section : Symbol
      getter group : Symbol
      getter verb : Verb::Definition?
      getter family : Verb::Family?

      def initialize(@key : Char?, @scope : Verb::Scope, @section : Symbol, @group : Symbol,
                     @verb : Verb::Definition? = nil, @family : Verb::Family? = nil)
      end

      def self.for_verb(v : Verb::Definition, key : Char) : Entry
        new(key, v.scope, v.section, v.group, verb: v)
      end

      def id : String
        if v = @verb
          v.id
        elsif f = @family
          "family:#{f.id}"
        else
          "inert"
        end
      end

      def title : String
        @verb.try(&.title) || @family.try(&.title) || INERT_TITLE
      end

      def menu_key : Char?
        @key
      end

      # A family row: activating it descends rather than running anything.
      def family? : Bool
        @verb.nil? && !@family.nil?
      end

      def inert? : Bool
        @verb.nil? && @family.nil?
      end
    end

    # One group of entries within the popup: `start`/`count` index into the flat
    # @entries array (contiguous per group, in open()'s build order).
    private record Group, label : String, start : Int32, count : Int32

    # One drawable row: either a dim section header (`label` set, `entry` nil) or
    # a single entry row (`entry` set to its index in @entries). Always exactly
    # one entry per row — no packing.
    private record DisplayRow, label : String?, entry : Int32?

    def initialize(@registry : Verb::Registry)
      @entries = [] of Entry
      @selected = 0
      # The row offset ←/→ AIMS for, kept across a run of column moves — a text editor's
      # "desired column", and here for the same reason editors have one.
      #
      # Without it the two directions do not round-trip: a → whose landing offset holds a
      # GROUP HEADER falls to the nearest entry row, and the ← back then measures from THAT
      # offset and finds a different entry than the one it started on. The method's contract
      # is "keeping its row offset within the column"; this is what keeps it. Every other way
      # the selection moves (↑/↓, a click, a fresh open) clears it, so the stickiness lasts
      # exactly as long as the operator is walking sideways.
      @col_off = nil.as(Int32?)
      @scroll = 0  # top visible row (display-row space) — keeps the selection on-screen
      @title_w = 0 # widest entry title, cached at open() (drives the popup width)
      # Empty ⇒ single flat column, no headers (today's exact pre-grouping layout).
      # ≥2 entries ⇒ a COMMON + CONTEXT grouped render with a header per group.
      @groups = [] of Group
      @section_label = "" # context label appended to the card title ("SPACE · RESPONSE")
    end

    # The rows shown at the current level. Level 1: the scope-local, non-hidden, available
    # verbs carrying a menu_key, plus one row per family the view registers a member of —
    # flattened in group order (COMMON first, then CONTEXT) when grouped. Level 2: the
    # family's available members in table order.
    def entries : Array(Entry)
      @entries
    end

    @ctx = nil.as(Verb::ExecContext?)
    # What #open was called with, kept so #back can rebuild level 1.
    @view = nil.as({Verb::Scope, Symbol, Bool, String?}?)
    # The family whose members are drawn, or nil at level 1.
    @level = nil.as(Verb::Family?)
    # Level 1's selection + scroll while level 2 is up, restored by #back.
    @l1_state = nil.as({Int32, Int32}?)

    # The family whose card is up, or nil at level 1.
    def level : Verb::Family?
      @level
    end

    # Open scoped to `scope`+`section` (captured by the Runner at the space
    # keystroke, before the overlay/focus state can change). Seeds the entry list
    # and the group split.
    # `banner` overrides the card's context label when the caller has something to say about
    # the CURRENT STATE rather than the focus area — History's "3 MARKED" (#442), so a batch
    # action can never be a surprise. It wins over the section label and, crucially, applies to
    # the single-group branch too: History Body has no context section, so a section label
    # alone would never render.
    # `subtabs` — the active tab carries a sub-tab strip, so the strip's own verbs join the
    # card as their own bucket NO MATTER which focus level opened it (#1055). Before, they
    # were a context section like any other and so appeared only with the strip focused: from
    # the body one had to walk focus up a level first, and with numbered tab jumps landing
    # anywhere, "what space offers here" depended on which row the cursor happened to sit on.
    # The bucket is the SAME set and the SAME letters on all nine strips — see the uniform
    # table in .github/DESIGN.md — which is what makes it learnable as one thing rather than
    # nine.
    def open(scope : Verb::Scope, section : Symbol, ctx : Verb::ExecContext, banner : String? = nil,
             subtabs : Bool = false) : Nil
      @ctx = ctx
      @view = {scope, section, subtabs, banner}
      @level = nil
      @l1_state = nil
      reset_position
      build_level1(scope, section, ctx, banner, subtabs)
    end

    # Draw `family`'s members in place of level 1: the view's AVAILABLE members, in the
    # family table's order, each on the table's letter — or, when none is available, the one
    # inert row. False (and nothing changes) unless level 1 is up and draws that family's row.
    def descend(family : Verb::Family) : Bool
      return false unless @level.nil? && (view = @view) && (ctx = @ctx)
      return false unless @entries.any? { |e| e.family? && e.family.try(&.id) == family.id }
      scope, section, subtabs, _ = view
      @l1_state = {@selected, @scroll}
      @level = family
      reset_position
      @entries = level2_entries(family, scope, section, ctx, subtabs)
      @entries << Entry.new(nil, scope, section, :none) if @entries.empty?
      @groups = [] of Group
      measure(ctx)
      true
    end

    # A family's available members in its table order, each on the table's letter. Sub-tabs…
    # (`Registry::SUBTABS_FOLD`) is the SUB-TABS bucket instead: its available rows in the
    # bucket's own order, each on its own `menu_key` — the letters it has with the strip
    # focused, so `n` from the strip is `T n` from a pane.
    private def level2_entries(family : Verb::Family, scope : Verb::Scope, section : Symbol,
                               ctx : Verb::ExecContext, subtabs : Bool) : Array(Entry)
      view = @registry.for_view(scope, section, ctx, subtabs)
      if family.id == Verb::Registry::SUBTABS_FOLD.id
        return view.compact_map do |v|
          next unless Verb::Registry::SUBTAB_SECTIONS.includes?(v.section)
          next unless k = v.menu_key
          Entry.for_verb(v, k)
        end
      end
      rows = view.select { |v| v.family == family.id }.compact_map do |v|
        next unless (i = v.intent) && (k = family.letter(i))
        {family.order(i) || 0, Entry.for_verb(v, k)}
      end
      rows.sort_by!(&.[0]).map(&.[1])
    end

    # Up one level: level 1 again, with the selection it had. False at level 1 — the caller
    # closes the menu instead.
    def back : Bool
      return false unless @level && (view = @view) && (ctx = @ctx)
      scope, section, subtabs, banner = view
      @level = nil
      reset_position
      build_level1(scope, section, ctx, banner, subtabs)
      if saved = @l1_state
        @selected = saved[0].clamp(0, {@entries.size - 1, 0}.max)
        @scroll = saved[1]
      end
      @l1_state = nil
      true
    end

    # ↵, a click or a row's key on `entry`: a family row descends (and nil comes back), a verb
    # row hands back its verb for the caller to run, and the inert row does nothing.
    def activate(entry : Entry?) : Verb::Definition?
      return nil unless entry
      if f = entry.family
        descend(f) if entry.family?
        return nil
      end
      entry.verb
    end

    # Where a STICKY family's card comes back to once its member has run: the family and the
    # highlighted row. Nil when the card up is not a sticky family's — the menu just closes.
    def sticky_point : {Verb::Family, Int32}?
      return nil unless (f = @level) && f.sticky?
      {f, @selected}
    end

    # Re-draw a sticky family's card at its row, over a menu #open just rebuilt for the same
    # view. False when that family no longer has a row there.
    def resume(point : {Verb::Family, Int32}) : Bool
      family, row = point
      return false unless descend(family)
      set_selected(row)
      true
    end

    private def reset_position : Nil
      @selected = 0
      @scroll = 0
      @col_off = nil
    end

    private def build_level1(scope : Verb::Scope, section : Symbol, ctx : Verb::ExecContext,
                             banner : String?, subtabs : Bool) : Nil
      all = level1_entries(scope, section, ctx, subtabs)
      buckets, context = focus_buckets(all, section, subtabs)

      # Each focus-area bucket is then subdivided by the SEMANTIC axis when its verbs
      # carry one — that is what breaks the single-region scopes (History's 19-entry
      # Body) into scannable bands. An untagged bucket keeps its own label and renders
      # exactly as it did before.
      groups = [] of {String, Array(Entry)}
      buckets.each { |(label, entries)| groups.concat(split_semantic(label, entries)) }

      if groups.size <= 1
        # Nothing to distinguish — one flat column, no headers.
        @entries = groups.empty? ? ([] of Entry) : groups[0][1]
        @groups = [] of Group
      else
        @entries = groups.flat_map(&.[1])
        idx = 0
        @groups = groups.map do |(glabel, verbs)|
          g = Group.new(glabel, idx, verbs.size)
          idx += verbs.size
          g
        end
      end
      # The card-title suffix tracks the FOCUS AREA only, never the semantic bands: a
      # semantically-grouped single-region menu (History Body) still reads a bare
      # "SPACE", because there is no focused sub-area to name. A banner always wins.
      # From the strip itself there is no pane bucket to name, but the card should still say
      # what it is scoped to — so the strip's own label stands in.
      @section_label = banner || (context.empty? ? (strip_focus?(section, subtabs) ? SUBTAB_LABEL : "") : section_label(section))
      measure(ctx)
    end

    # Widest of the entry titles AND the group headers ("─ LABEL ─", 4 chars of
    # chrome around the label) — a grouped view with a long section label (e.g.
    # SECTION_LABELS additions) must still fit inside the box the entries sized.
    private def measure(ctx : Verb::ExecContext) : Nil
      entry_w = @entries.empty? ? 0 : @entries.max_of { |e| Screen.draw_width(menu_title(e, ctx)) + hint_w(e) }
      header_w = @groups.empty? ? 0 : @groups.max_of { |g| Screen.draw_width(g.label) + 4 }
      # A level-2 card is often a few short rows under a long breadcrumb ("SPACE › SEND FLOW
      # TO · 3 MARKED"), so it is also as wide as its title. Level 1 keeps its width.
      title_w = @level ? Screen.draw_width(card_title) : 0
      @title_w = {entry_w, header_w, title_w}.max
    end

    # Level 1's rows before bucketing, in registration order: every available verb with a
    # level-1 letter (a pinned member included), and one row per family the view REGISTERS a
    # member of, at its first member's place. A family row is static on purpose — see the
    # class comment — so its members are read with `registered_in_view`, not `for_view`.
    #
    # The family row files under the first bucket, in render order, that holds a member
    # (COMMON, then SUB-TABS, then the pane), and in the family's own band — but only when
    # another row of that bucket is in that band already (#banded_home?).
    #
    # In a pane view of a tab with a strip the SUB-TABS bucket folds into one Sub-tabs… row
    # (`Registry::SUBTABS_FOLD`, #1274 Decision 8), static like a family row and filed in the
    # SUB-TABS bucket, where only the bucket's `pinned:` rows keep a level-1 row beside it. A
    # family member there keeps its family's row instead (`Registry.folded?`).
    private def level1_entries(scope : Verb::Scope, section : Symbol, ctx : Verb::ExecContext,
                               subtabs : Bool) : Array(Entry)
      registered, fold_row = unfolded(scope, section, subtabs)
      rows = [fold_row].compact
      seen = Set(Symbol).new
      registered.each do |v|
        if (k = v.menu_key) && v.available?(ctx)
          rows << Entry.for_verb(v, k)
        end
        next unless (fid = v.family) && seen.add?(fid)
        next unless f = @registry.family(fid)
        home = registered.select { |m| m.family == fid }.min_by { |m| bucket_rank(m.section, section, subtabs) }
        next if bucket_rank(home.section, section, subtabs) == Int32::MAX
        rows << Entry.new(f.key, scope, home.section, f.group, family: f)
      end
      rows.map { |e| (f = e.family) && !banded_home?(e, rows, section, subtabs) ? Entry.new(e.key, e.scope, e.section, :none, family: f) : e }
    end

    # The verbs the view registers, less the ones a pane view folds into Sub-tabs…, and that
    # row when it is drawn: static like a family row, filed in the SUB-TABS bucket.
    private def unfolded(scope : Verb::Scope, section : Symbol, subtabs : Bool) : {Array(Verb::Definition), Entry?}
      registered = @registry.registered_in_view(scope, section, subtabs)
      return {registered, nil} unless Verb::Registry.folds?(section, subtabs)
      folded, kept = registered.partition { |v| Verb::Registry.folded?(v) }
      return {kept, nil} unless folded.any?(&.menu_listed?)
      fold = Verb::Registry::SUBTABS_FOLD
      {kept, Entry.new(fold.key, scope, :subtab, :none, family: fold)}
    end

    # Whether a family row's bucket already has its family's band: another level-1 row there
    # (a non-member, or a pinned member) carries the family's `group`. Only then does the row
    # take that band. Otherwise it stays an untagged row, because a band holding the family row
    # alone is a header over one row: in an untagged bucket (the Repeater's COMMON, the
    # Fuzzer's) it would also push everything else under a `─ COMMON ─` header the card never
    # had, and in a banded one (ProbeDetail, whose only other band is DANGER) it sat above the
    # rest as a one-row `─ SEND ─` (#1295).
    private def banded_home?(e : Entry, rows : Array(Entry), section : Symbol, subtabs : Bool) : Bool
      rank = bucket_rank(e.section, section, subtabs)
      rows.any? do |r|
        (v = r.verb) && (!v.member? || v.pinned?) && v.group == e.group && bucket_rank(r.section, section, subtabs) == rank
      end
    end

    # Which focus bucket a verb of `v_section` lands in — 0 COMMON, 1 SUB-TABS, 2 the pane —
    # or Int32::MAX when #focus_buckets would draw it in none. Mirrors #focus_buckets.
    private def bucket_rank(v_section : Symbol, section : Symbol, subtabs : Bool) : Int32
      return 0 if v_section == :common
      return 1 if subtabs && Verb::Registry::SUBTAB_SECTIONS.includes?(v_section)
      return 2 if v_section == section && section != :common && !strip_focus?(section, subtabs)
      Int32::MAX
    end

    # The FOCUS-AREA split of `all`, in render order — COMMON, then the SUB-TABS bucket when
    # the tab has a strip, then the focused pane's own section. Returned alongside that last
    # one because the card's title suffix is the pane's label, and only when there IS a pane
    # bucket to name.
    #
    # Only NON-EMPTY sections become a bucket — an empty COMMON (never happens in practice,
    # but defensive) or an empty pane bucket (the common case for single-region tabs, or a
    # section nothing is tagged for yet) simply drops out rather than rendering a header with
    # nothing under it.
    private def focus_buckets(all : Array(Entry), section : Symbol, subtabs : Bool)
      common = all.select { |v| v.section == :common }
      strip = subtabs ? all.select { |v| Verb::Registry::SUBTAB_SECTIONS.includes?(v.section) } : [] of Entry
      # The focused pane's own bucket, suppressed when that pane IS the strip (or the tab
      # bar's `:tab`): `strip` already carries those rows, and drawing them again under a
      # second header would be the same action listed twice with the same letter.
      context = if section == :common || strip_focus?(section, subtabs)
                  [] of Entry
                else
                  all.select { |v| v.section == section }
                end

      buckets = [] of {String, Array(Entry)}
      buckets << {SECTION_LABELS[:common], common} unless common.empty?
      buckets << {SUBTAB_LABEL, strip} unless strip.empty?
      buckets << {section_label(section), context} unless context.empty?
      {buckets, context}
    end

    # The strip (or the tab bar) is what has focus, so the SUB-TABS bucket IS the context.
    private def strip_focus?(section : Symbol, subtabs : Bool) : Bool
      subtabs && Verb::Registry::SUBTAB_SECTIONS.includes?(section)
    end

    private def section_label(section : Symbol) : String
      SECTION_LABELS[section]? || section.to_s.upcase
    end

    # One bucket's rows: its semantic bands (GROUP_ORDER, non-empty only) when ANY verb
    # in it carries a `group`, else the bucket itself under its own focus-area label.
    # Verbs left `:none` inside an otherwise-tagged bucket keep that bucket's label as a
    # band of their own, so a half-tagged scope can never silently drop a verb — the worst
    # case is one extra header, never a missing action. That band sits ahead of DANGER and
    # WIPE: a scope that tags only its one clear (Notes) must not lead with it.
    private def split_semantic(label : String, verbs : Array(Entry)) : Array({String, Array(Entry)})
      return [{label, verbs}] if verbs.all? { |v| v.group == :none }
      bands = semantic_bands(verbs, GROUP_ORDER.reject { |g| DESTRUCTIVE_GROUPS.includes?(g) })
      rest = verbs.select { |v| v.group == :none }
      bands << {label, rest} unless rest.empty?
      bands + semantic_bands(verbs, DESTRUCTIVE_GROUPS.to_a)
    end

    private def semantic_bands(verbs : Array(Entry), groups : Array(Symbol)) : Array({String, Array(Entry)})
      groups.compact_map do |g|
        band = verbs.select { |v| v.group == g }
        {GROUP_LABELS[g], band} unless band.empty?
      end
    end

    # A boolean toggle's `ExecContext#menu_state`, drawn as ●/○.
    def self.on_off(on : Bool) : String
      on ? "on" : "off"
    end

    # Whether a sticky family's card comes back after one of its members ran. `before` and
    # `after` are the Runner's snapshots of every surface a verb could open (overlays, pickers,
    # prompts, a pane that took the keys): any change means the member asked for something of
    # its own, and the card would cover it. `was` is the view the card was built for and
    # `here` the one in front now; a card describing another view is closed, not redrawn.
    def self.resume_sticky?(before, after, was : ActionContext, here : ActionContext) : Bool
      before == after && here.scope == was.scope && here.section == was.section && here.subtabs == was.subtabs
    end

    # What a family row shows in the hint column: it opens a card, the way a title's `…` says.
    FAMILY_HINT = "›"

    # Extra width when we paint the dim hint column (state and/or chord) next to the title.
    private def hint_w(e : Entry) : Int32
      state, chord = hint_parts(e)
      return 0 unless state || chord
      Screen.draw_width([state, chord].compact.join(' ')) + 1
    end

    # The hint column's two parts: the row's state (`ExecContext#menu_state` as ●/○ or a
    # short value) and its direct chord. A family row has only its `›`.
    private def hint_parts(e : Entry) : {String?, String?}
      return {nil, FAMILY_HINT} if e.family?
      return {nil, nil} unless v = e.verb
      {state_label(v), chord_hint(v, e.key)}
    end

    private def state_label(v : Verb::Definition) : String?
      case state = @ctx.try(&.menu_state(v.id))
      when nil   then nil
      when "on"  then "●"
      when "off" then "○"
      else            state
      end
    end

    # Effective direct chord (e.g. `^R`), or nil when unbound / identical to the
    # single-char letter the row is drawn on (no need to repeat `y` next to mnemonic `y`).
    private def chord_hint(v : Verb::Definition, key : Char?) : String?
      return nil unless chord = Hotkeys.binding_for(@registry, v.id)
      label = Hotkeys.display_label(chord)
      return nil if key && (label == key.to_s || label == key.to_s.upcase)
      label
    end

    private def menu_title(e : Entry, ctx : Verb::ExecContext) : String
      return INERT_TITLE if e.inert?
      ctx.space_menu_title(e.id) || e.title
    end

    def move(delta : Int32) : Nil
      return if @entries.empty?
      @selected = (@selected + delta).clamp(0, @entries.size - 1)
      @col_off = nil # ↑/↓ redefine where sideways aims from — see @col_off
    end

    # Move the selection one COLUMN left/right, keeping its row offset within the column.
    # ↑/↓ already walk the whole list in reading order (down a column, then on to the top
    # of the next), so ←/→ is the across axis that layout implies. A no-op in the
    # single-column layout — there is nowhere to go — and at the outer columns.
    #
    # It never lands on a header or a column-break filler: it takes the nearest ENTRY row
    # in the target column, searching down from the same offset then up. Needs `body`
    # because how many columns exist is a function of the space available (see #grid).
    def move_column(delta : Int32, body : Rect) : Nil
      return if @entries.empty? || delta == 0
      g = grid(body)
      return if g.ncols <= 1 || g.col_rows <= 0
      rows = g.rows
      sel_row = rows.index { |r| r.entry == @selected } || 0
      col = sel_row // g.col_rows
      # The offset this move AIMS for, which is not always the one the selection sits at —
      # see @col_off. Falls back to the live position for the first move of a run.
      #
      # CLAMPED to the grid in hand, because the grid is a function of the popup's live size:
      # a resize between two sideways moves can shorten the columns under a remembered aim,
      # and an aim past `col_rows` fails every offset the scan below produces — ←/→ would go
      # quietly dead until something else cleared it.
      off = ({@col_off || (sel_row % g.col_rows), 0}.max).clamp(0, g.col_rows - 1)
      target = (col + delta).clamp(0, g.ncols - 1)
      return if target == col
      base = target * g.col_rows
      (0...g.col_rows).each do |d|
        {off + d, off - d}.each do |o|
          next if o < 0 || o >= g.col_rows
          next unless row = rows[base + o]?
          if idx = row.entry
            @selected = idx
            # The AIM is kept, not `o`: the landing offset may have been displaced by a
            # header, and remembering the displaced one is exactly what stopped ←/→ from
            # returning where it came from.
            @col_off = off
            return
          end
        end
      end
    end

    def selected_entry : Entry?
      @entries[@selected]?
    end

    # The highlighted row's verb — nil on a family row or the inert row.
    def selected_verb : Verb::Definition?
      selected_entry.try(&.verb)
    end

    # The row whose key matches `c` (the key the user pressed in the menu), at this level.
    def entry_for(c : Char) : Entry?
      @entries.find { |e| e.key == c }
    end

    # The verb `c` runs at this level — nil for an unmapped key and for a family key.
    def verb_for(c : Char) : Verb::Definition?
      entry_for(c).try(&.verb)
    end

    # Sets the active entry, clamped to the populated range (for click-select).
    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@entries.size - 1, 0}.max)
      @col_off = nil # a click names a new place to aim from — see @col_off
    end

    # The full row list this frame: a dim header row per group (only when ≥2
    # groups — see #open) interleaved with exactly one row per entry, in
    # @entries order. Rebuilt on demand (cheap — a handful of rows) so
    # box()/render()/row_at() always agree on the exact same layout.
    private def display_rows : Array(DisplayRow)
      return @entries.each_index.map { |i| DisplayRow.new(nil, i) }.to_a if @groups.empty?
      rows = [] of DisplayRow
      @groups.each do |g|
        rows << DisplayRow.new(g.label, nil)
        (g.start...(g.start + g.count)).each { |i| rows << DisplayRow.new(nil, i) }
      end
      rows
    end

    # The resolved column grid for a given body, AND the exact row list to
    # draw (padded, see #pad_rows). `ncols` == 1 is the pre-column layout in every
    # respect (including vertical scroll and an unpadded row list), so a narrow or short
    # terminal behaves exactly as it did. Columns are filled COLUMN-MAJOR: column c holds
    # rows [c*col_rows, (c+1)*col_rows), so reading order is down-then-across and a
    # group's rows stay contiguous.
    private record Grid, ncols : Int32, col_rows : Int32, viewport : Int32, rows : Array(DisplayRow)

    # Push a group header off the LAST row of a column: a header there is stranded, with
    # every one of its entries in the next column (the bug the first column build had —
    # History's `─ TRIAGE ─` sat alone at the bottom of column 1 while t/T/a started
    # column 2). A filler row takes that slot instead and the header moves over with its
    # items. Fillers are inert everywhere: not drawn, not selectable, not clickable.
    private def pad_rows(rows : Array(DisplayRow), col_rows : Int32) : Array(DisplayRow)
      return rows if col_rows <= 1
      out = [] of DisplayRow
      rows.each do |r|
        out << DisplayRow.new(nil, nil) if r.label && (out.size % col_rows) == col_rows - 1
        out << r
      end
      out
    end

    # How many columns to use, how the rows divide between them, and the padded rows.
    # Multi-column only kicks in when the list does NOT already fit AND a column would be
    # tall enough to be worth having (MIN_COL_ROWS) AND at least two columns fit the
    # width — otherwise a single scrolling column, exactly as before.
    private def grid(body : Rect) : Grid
      base = display_rows
      avail = { {body.h - 2, MAX_ROWS}.min, 1 }.max # interior rows one column may use
      cell = @title_w + 3                           # indicator + key + gap + title
      fit = {(body.w - 3 + COL_GAP) // (cell + COL_GAP), 1}.max
      if base.size <= avail || avail < MIN_COL_ROWS || fit < 2
        return Grid.new(1, base.size, {base.size, avail}.min, base)
      end
      ncols = {(base.size + avail - 1) // avail, fit}.min
      col_rows = (base.size + ncols - 1) // ncols
      # Padding adds rows, which can push the balanced height back up — settle it by
      # growing the column (up to avail), then by adding a column. Bounded: each pass
      # strictly grows col_rows or ncols, both of which are capped.
      4.times do
        need = (pad_rows(base, col_rows).size + ncols - 1) // ncols
        break if need <= col_rows
        if need <= avail
          col_rows = need
        elsif ncols < fit
          ncols += 1
          col_rows = (base.size + ncols - 1) // ncols
        else
          col_rows = avail
          break
        end
      end
      Grid.new(ncols, col_rows, {col_rows, avail}.min, pad_rows(base, col_rows))
    end

    # The interior width of ONE column inside a drawn box (indicator + key + gap +
    # title). The single source both render and row_at derive their x math from, so the
    # two can never disagree. At ncols == 1 this is `b.w - 3`, i.e. exactly the width the
    # pre-column layout used (CHROME = the 3 here + scroll gutter + 2 borders).
    private def cell_w(b : Rect, ncols : Int32) : Int32
      {(b.w - 3 - (ncols - 1) * COL_GAP) // ncols, 1}.max
    end

    # The popup box: CENTERED in `body` (like the palette's card), as wide as its
    # column(s) need and as tall as one column's rows need (+ frame). Empty Rect when
    # there's nothing to show or it can't fit.
    #
    # Centered rather than bottom-right (the original helix-leader placement): the card
    # had grown past what a corner can hold — History's Body alone is 19 entries — and
    # anchored at the bottom-right it covered exactly the columns the operator decides
    # from (PATH / STATUS / SIZE / DUR). Centering is also gori's own idiom for a modal
    # card; the corner popup was the outlier. What keeps this from collapsing into a
    # second Ctrl-P is the INTERACTION, not the position: no query line, no fuzzy
    # filter — one mnemonic keypress per action (see the class comment).
    def box(body : Rect) : Rect
      return Rect.new(0, 0, 0, 0) if @entries.empty?
      g = grid(body)
      cell = @title_w + 3
      # left border + columns (+ gaps) + scroll gutter + right border
      w = {3 + g.ncols * cell + (g.ncols - 1) * COL_GAP, body.w - 2}.min
      h = {g.viewport + 2, body.h}.min
      return Rect.new(0, 0, 0, 0) if w < 10 || h < 3
      x = body.x + (body.w - w) // 2
      y = body.y + (body.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Draws the popup card — one "‹key›  Title" row at a time, with a dim
    # "─ LABEL ─" row between groups (omitted entirely for a single group). The
    # selected row gets the accent band + a ▎ indicator (matches the palette / ":"
    # row style).
    def render(screen : Screen, body : Rect) : Nil
      b = box(body)
      return if b.empty?
      Frame.card(screen, b, card_title, border: Theme.border_focus)

      g = grid(body)
      rows = g.rows
      viewport = b.h - 2
      cw = cell_w(b, g.ncols)
      ensure_visible(rows, viewport, g)
      # The scroll affordance is per-COLUMN-height now: with ncols == 1 that is the whole
      # list (identical to before), and with columns it is how far one column reaches.
      visible = {viewport, g.col_rows - @scroll}.min
      (0...viewport).each do |i|
        ry = b.y + 1 + i
        # One background sweep per screen row, then each column paints into its own cell.
        # A row that is short in one column (the last column is partly empty when the
        # rows do not divide evenly) simply leaves that cell blank.
        screen.fill(Rect.new(b.x + 1, ry, b.w - 2, 1), Theme.panel)
        if mark = scroll_marker(i, visible, viewport, g.col_rows)
          screen.cell(b.right - 2, ry, mark, Theme.muted, Theme.panel)
        end
        (0...g.ncols).each do |c|
          ridx = c * g.col_rows + @scroll + i
          next if ridx >= rows.size || @scroll + i >= g.col_rows
          draw_cell(screen, rows[ridx], b.x + 1 + c * (cw + COL_GAP), ry, cw)
        end
      end
    end

    # "SPACE · RESPONSE" at level 1; at level 2 a breadcrumb, "SPACE › SEND FLOW TO", which
    # keeps the state banner ("· 3 MARKED", #442) — the batch sends are the rows it is for.
    def card_title : String
      if f = @level
        banner = @view.try(&.[3])
        return banner ? "SPACE › #{f.crumb} · #{banner}" : "SPACE › #{f.crumb}"
      end
      @section_label.empty? ? "SPACE" : "SPACE · #{@section_label}"
    end

    # One cell of the grid: a dim "─ LABEL ─" header, an entry row, or nothing at all
    # for a pad_rows filler. `cx`/`cw` are the cell's own left edge and width, so this is
    # identical whether it is the only column or one of several.
    private def draw_cell(screen : Screen, row : DisplayRow, cx : Int32, ry : Int32, cw : Int32) : Nil
      return if row.label.nil? && row.entry.nil? # a pad_rows filler — draws as blank
                # A header row is never "active" (row.entry is nil, never equal to @selected), so
                # this covers both rows uniformly.
      active = row.entry == @selected
      bg = active ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(cx, ry, cw, 1), bg) if active
      if label = row.label
        # Clamp to the cell (mirrors the entry row's width below) so a long header can
        # never paint past its column / the scroll-marker gutter.
        screen.text(cx + 1, ry, "─ #{label} ─", Theme.muted, bg, width: {cw - 1, 0}.max)
        return
      end
      return unless idx = row.entry
      e = @entries[idx]
      screen.cell(cx, ry, active ? '▎' : ' ', Theme.accent, bg)
      if e.inert?
        screen.text(cx + 3, ry, INERT_TITLE, Theme.muted, bg, width: {cw - 3, 0}.max)
        return
      end
      screen.text(cx + 1, ry, e.key.to_s, Theme.accent, bg, Attribute::Bold)
      # Reserve room inside the cell for (when set) the dim hint column — the row's state
      # and its direct chord, so rebinds stay visible without changing mnemonics.
      state, chord = hint_parts(e)
      title_text = @ctx.try { |c| menu_title(e, c) } || e.title
      screen.text(cx + 3, ry, title_text, active ? Theme.text_bright : Theme.text, bg,
        width: {cw - 3 - hint_w(e), 0}.max)
      draw_hint(screen, state, chord, cx + cw, ry, bg)
    end

    # The hint column, right-aligned at `right`: the chord last, the state to its left.
    private def draw_hint(screen : Screen, state : String?, chord : String?, right : Int32, ry : Int32, bg : Color) : Nil
      x = right
      if chord
        x -= Screen.draw_width(chord)
        screen.text(x, ry, chord, Theme.muted, bg)
        x -= 1
      end
      if state
        x -= Screen.draw_width(state)
        screen.text(x, ry, state, state == "●" ? Theme.accent : Theme.muted, bg)
      end
    end

    # The scroll affordance for row `i`: ▲ on the top row when entries are hidden
    # above, ▼ on the bottom row when hidden below, ↕ when a 1-row viewport hides
    # both — so it's obvious the popup scrolls (nil = list fully shown, no marker).
    # Mirrors settings_view's marker convention.
    private def scroll_marker(i : Int32, visible : Int32, rows : Int32, total : Int32) : Char?
      above = @scroll > 0
      below = @scroll + rows < total
      first = i == 0
      last = i == visible - 1
      return '↕' if first && last && above && below
      return '▲' if first && above
      return '▼' if last && below
      nil
    end

    # Scroll so the selection stays visible when a COLUMN is shorter than the rows it
    # holds (short terminals) — mirrors the palette/command-line behaviour. Works in
    # DISPLAY-ROW space (headers count as rows) so it's correct whether or not this
    # frame has a header at all, and in column space so the offset is the selection's
    # position WITHIN its own column (identical to the flat case at ncols == 1).
    private def ensure_visible(rows : Array(DisplayRow), viewport : Int32, g : Grid) : Nil
      return if viewport <= 0 || rows.empty?
      sel_row = rows.index { |r| r.entry == @selected } || 0
      off = g.col_rows > 0 ? sel_row % g.col_rows : sel_row
      @scroll = off if off < @scroll
      @scroll = off - viewport + 1 if off >= @scroll + viewport
      @scroll = 0 if @scroll < 0
    end

    # Maps a click in `body` to an entry index (or nil) — inverts box()/render()'s grid.
    # Header rows and the inter-column gap aren't clickable.
    def row_at(body : Rect, mx : Int32, my : Int32) : Int32?
      b = box(body)
      return nil if b.empty?
      viewport = b.h - 2
      i = my - (b.y + 1)
      return nil if i < 0 || i >= viewport
      return nil if mx <= b.x || mx >= b.right - 1
      g = grid(body)
      cw = cell_w(b, g.ncols)
      rel = mx - (b.x + 1)
      c = rel // (cw + COL_GAP)
      return nil if c >= g.ncols                   # the scroll gutter, not a column
      return nil if rel - c * (cw + COL_GAP) >= cw # landed in the gap between columns
      return nil if @scroll + i >= g.col_rows
      rows = g.rows
      ridx = c * g.col_rows + @scroll + i
      return nil if ridx >= rows.size
      rows[ridx].entry # nil for a header or a pad_rows filler — neither is clickable
    end
  end
end
