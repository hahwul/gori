require "./verb/context"

module Gori
  # The verb system — the TUI's one source of truth for an action (P1). A single
  # Definition drives a keybinding, a command-palette entry AND a space-menu entry;
  # all three run the same Definition#call, so the TUI has no per-surface dispatch.
  #
  # It stops at the TUI, deliberately. `gori run` and `gori mcp` declare their own
  # commands and reach parity by calling the same engines (DESIGN.md §2.1), not by
  # reading this registry. The blocker is not wiring: a verb names no target, it
  # reads one from TUI selection state (`repeater_send` sends the ACTIVE sub-tab),
  # and a caller with an id but no selection cannot express that — see the argument
  # schema Definition does not have. Measured and decided in DESIGN.md §7
  # (2026-07-26), issue #357.
  module Verb
    # Where a verb may fire. The active surface (focused tab / open overlay)
    # selects which scope's keymap is consulted; Global verbs fire everywhere.
    enum Scope
      Global          # fires anywhere
      Sidebar         # the tab list has focus
      Body            # the content pane has focus (e.g. the History list)
      HistoryDetail   # a flow's detail view is open
      Repeater        # the Repeater tab has focus
      Fuzzer          # the Fuzzer tab has focus
      Miner           # the Miner (param-mining) tab has focus
      OastCallbacks   # the OAST tab's Callbacks sub-tab has focus
      OastProviders   # the OAST tab's Providers sub-tab has focus
      Sequencer       # the Sequencer (token-randomness) tab has focus
      Sitemap         # the Sitemap sub-tab (under Target) has focus
      Discover        # the Discover sub-tab (under Target) has focus
      Diff            # the Diff sub-tab (under Target) has focus — the retest report
      Params          # the Params sub-tab (under Target) has focus — the parameter inventory
      Issues          # the Issues list has focus
      IssuesDetail    # an issue's detail is open
      Evidence        # project-wide immutable snapshot archive
      Probe           # the Probe scan-issue list has focus
      ProbeDetail     # a Probe issue's detail is open
      ProbeRules      # the Probe tab's Rules sub-tab has focus (built-in + custom rule list)
      Authorize       # the Authorize (access-control / multi-identity) tab has focus
      Intercept       # the Intercept queue tab has focus
      Rewriter        # the Rewriter (Match & Replace rules) tab has focus
      Colormarker     # the Colormarker (History row-colour rules) tab has focus
      Comparer        # the Comparer tab has focus
      Decoder         # the Decoder tab has focus
      Jwt             # the JWT workbench tab has focus
      Cookie          # the Cookie workbench tab has focus (framework signed session cookies)
      Notes           # the Notes tab has focus (sub-tab strip space menu)
      ProjectDesc     # the Project tab's DESCRIPTION pane has focus (read mode)
      Project         # the Project tab's SCOPE rule list has focus
      HostOverrides   # the Project tab's HOST OVERRIDES list has focus
      Env             # the Project tab's ENVIRONMENT var list has focus
      ProjectActivity # the Project tab's ACTIVITY pane has focus (the #124 event feed)
      PaletteOpen     # the command palette overlay is up
      # The FOCUS dimension the other scopes don't have. Every scope above names a TAB (or an
      # overlay); `Keymap#lookup` is keyed by one of them alone, so a tab whose panes want the
      # same letter for two things could not say so and hand-rolled the second meaning in
      # `handle_body_key` — the root cause KEY_AUDIT §2d names. Editor is consulted AHEAD of the
      # tab's own scope whenever the focused pane is a text editor (Runner#scope_chain), which
      # is exactly the pane set those hand-rolled arms were disambiguating. It is ADDITIVE: the
      # tab scope is still consulted behind it, so a Repeater chord still fires in the Repeater's
      # request editor, and Global still backs both.
      Editor # the focused body pane is a text editor (READ or INS)
    end

    # The KIND of action, orthogonal to Scope (where it fires). Drives the
    # colour-coded sigil the command palette prints before each entry so users can
    # tell navigation from a state-changing action at a glance. Action is the default
    # (and covers every non-palette verb, which never renders a badge).
    enum Category
      Action     # does something / opens a tool (capture, intercept, scope, rules, CA …)
      Navigation # moves focus around the app (tab jumps, back to projects)
      Settings   # edits configuration (settings:*)
      System     # app lifecycle (quit, the palette itself)
    end

    # Which surface LISTS a verb (#1282). `Space` (the default) gives it a space-menu row;
    # `Palette` gives it none, at either level, and leaves it to the palette's typed search
    # (which finds the focused tab's actions) and to its chords. The space menu is for the
    # frequent, the palette for the long tail: a row that duplicates a direct chord for an
    # editing or navigation convenience, or a once-a-session configuration action, is placed
    # `menu: :palette`. Either way the verb runs through `Definition#call`.
    enum Placement
      Space
      Palette
    end

    # A keybinding as pure data (no terminal dependency). The TUI converts a
    # termisu key event into a Chord and looks it up in the Keymap.
    record Chord, key : String, ctrl : Bool = false, alt : Bool = false, shift : Bool = false do
      # The named (non-character) keys a chord may carry, matching the names
      # Tui::Keybind.from_event emits. Anything else must be a single ASCII char.
      NAMED_KEYS = %w[enter escape tab up down left right backspace space]

      # Human-readable label for palette hints, e.g. "ctrl-p", "g", "enter".
      def label : String
        String.build do |io|
          io << "ctrl-" if ctrl
          io << "alt-" if alt
          io << "shift-" if shift
          io << key
        end
      end

      # Inverse of #label: parse a stored chord string ("ctrl-shift-p", "enter", "[")
      # back into a Chord, or nil if it isn't valid. Modifier prefixes are stripped
      # GREEDILY from the front (each at most once; order-tolerant for hand-edits) so
      # the literal "-" key round-trips ("ctrl--" → ctrl + "-") and bracket/colon keys
      # survive. The remainder must be one ASCII char or one of NAMED_KEYS.
      def self.parse(s : String) : Chord?
        rest = s
        ctrl = alt = shift = false
        loop do
          if rest.starts_with?("ctrl-") && !ctrl
            ctrl = true
            rest = rest[5..]
          elsif rest.starts_with?("alt-") && !alt
            alt = true
            rest = rest[4..]
          elsif rest.starts_with?("shift-") && !shift
            shift = true
            rest = rest[6..]
          else
            break
          end
        end
        return nil if rest.empty?
        return nil unless NAMED_KEYS.includes?(rest) || (rest.size == 1 && rest[0].ascii?)
        new(rest, ctrl: ctrl, alt: alt, shift: shift)
      end
    end

    # One action. `handler` runs the action and returns an optional status-line
    # message. `available?` gates visibility/firing for the current context (P4).
    #
    # There is NO argument schema, and that absence is load-bearing: a verb reads
    # its target from TUI selection state rather than naming it, which is exactly
    # what keeps the registry TUI-only. Adding one is additive to this struct but
    # is a project of its own — it means giving the 224 per-tool intents in
    # verb/context/*.cr an explicit target — and it is the prerequisite for a
    # surface-neutral registry, not a follow-up to one (DESIGN.md §7, 2026-07-26).
    struct Definition
      getter id : String
      getter title : String
      getter description : String
      getter scope : Scope
      getter category : Category
      getter chords : Array(Chord)
      getter? hidden : Bool
      # Exposed for discoverability but not yet functional — the palette shows it
      # dimmed with a "soon" badge so users aren't surprised when it only toasts.
      getter? coming_soon : Bool
      # The single key that fronts this verb in the bottom-right "space" action
      # menu (helix leader). Optional: a verb already carrying a plain single-char
      # chord (y / f / / …) gets its menu key from that for free (see #menu_key);
      # this overrides for verbs whose only chord is ctrl/shift or none.
      getter mnemonic : Char?
      # Which group within the scope's space menu shows this verb: :common (every
      # displayable view, tab-wide) or a context section (a focus-area like
      # :request/:response/:template, or :tab/:subtab for the tab-bar/strip tiers).
      # Additive — `scope` still selects the tab; `section` subdivides it within
      # that scope's menu. Defaults to :common so untouched registrations render
      # exactly as they do today (one flat group).
      getter section : Symbol
      # The SEMANTIC band this verb sits in within whatever section shows it —
      # :view / :send / :triage / :copy / :scope / :danger / :wipe (see
      # Tui::SpaceMenu::GROUP_LABELS). The last two are a SEVERITY axis for verbs that
      # permanently destroy stored data: :danger deletes the SELECTED item(s) and may
      # ride a bare letter (the established `d`), while :wipe empties a whole
      # tab/project store and must answer a MODIFIED chord — ⇧X across the app (#899),
      # never a bare letter (registry_sweep_spec enforces the chord rule). Verbs that
      # only clear a text selection, marks, or scratch editor state are NOT destructive
      # and stay out of both. Orthogonal to `section`, which is a FOCUS-AREA
      # axis: `section` answers "which pane is focused" (and a section's verbs only
      # appear when that pane IS focused), while `group` answers "what kind of action
      # is this" and never gates visibility. The single-region scopes — History's Body
      # (19 entries), HistoryDetail (16), Probe (14), Sitemap (10) — have no focus
      # sub-areas at all, so `section` can never break their one flat list up; `group`
      # is what makes them scannable. Defaults to :none, which renders exactly as
      # before (no header, no subdivision), so an untagged scope is unchanged.
      getter group : Symbol
      # The sections (the active controller's `command_section`) in which this verb's CHORDS
      # fire, or nil for anywhere its scope does. A FOCUS gate on the key alone: the palette
      # and the space menu still run the verb wherever `available?` says (the menu already
      # draws a row only in its own `section`). It exists for a bare key one pane of a tab
      # owns while another pane's menu row spells the same letter — the Repeater's `p` pretty-
      # prints the RESPONSE while the request menu's `p` rewrites the request. Declared here
      # rather than folded into the `available:` lambda so the R1 guard
      # (spec/tui/menu_letter_meaning_spec.cr) can see which panes a chord is live in. Out of
      # its sections the press falls through the scope chain exactly like an unavailable verb
      # (`Keymap#resolve`), so a gate on a letter Global binds would reach Global — the guard
      # catches that as its own violation.
      getter chord_sections : Array(Symbol)?
      # The recurring intent this verb answers (`Verb::Lexicon`), which fixes its space-menu
      # letter: `:filter` is `/` on every tab that has one. A verb with an intent does not
      # spell a `mnemonic:` as well (`Registry#validate_intents!`). Nil for a scope-local
      # action, whose letter stays its own mnemonic or chord.
      getter intent : Symbol?
      # The `Verb::Family` this verb is a member of, or nil. Never spelled at registration: it
      # is derived from `intent` (a family's letter table names its member intents) and set by
      # `Registry#register_family`, so a member cannot name one family and answer another's
      # intent.
      getter family : Symbol?
      # A family member that ALSO keeps a level-1 row under its own letter (a `mnemonic:` or its
      # bare chord) — the loop action of the tab, e.g. Send to Repeater on the list scopes. Only
      # a member may be pinned, and only a pinned member may spell a `mnemonic:`
      # (`Registry#validate_intents!`).
      getter? pinned : Bool
      # Where the verb is listed (`Placement`): a space-menu row, or the palette's search only.
      # A palette-only verb has no `menu_key`, spells no `mnemonic:` and is never a family
      # member (`Registry#validate_intents!`), and its route in hint and Help text is
      # `Hotkeys.route`'s `^P → <title>` rather than a menu path.
      getter menu : Placement

      def initialize(@id : String, @title : String, @description : String, @scope : Scope,
                     @chords : Array(Chord) = [] of Chord, @hidden : Bool = false,
                     @available : ExecContext -> Bool = ->(_ctx : ExecContext) { true },
                     @coming_soon : Bool = false, @category : Category = Category::Action,
                     @mnemonic : Char? = nil, @section : Symbol = :common,
                     @group : Symbol = :none, @chord_sections : Array(Symbol)? = nil,
                     @intent : Symbol? = nil, @pinned : Bool = false,
                     @menu : Placement = Placement::Space,
                     &@handler : ExecContext -> String?)
      end

      def available?(ctx : ExecContext) : Bool
        @available.call(ctx)
      end

      # Whether a press of one of this verb's chords may fire it in the focused section —
      # `chord_sections`, asked by the scope chain on top of `available?`.
      def chord_live?(ctx : ExecContext) : Bool
        return true unless secs = @chord_sections
        secs.includes?(ctx.focused_section)
      end

      # This verb as a member of `family` (nil: of none) — the one way `family` is set, used by
      # `Registry#register_family`. A copy: a Definition is a value.
      def tagged(family : Symbol?) : Definition
        copy = dup
        copy.family = family
        copy
      end

      protected setter family : Symbol?

      # Whether only the palette lists this verb (`menu: :palette`): it has no space-menu row.
      def palette_only? : Bool
        @menu.palette?
      end

      # A member of a `Verb::Family`: the space menu lists it one level down, under the family.
      def member? : Bool
        !@family.nil?
      end

      # Whether the space menu can show this verb at EITHER level: its own level-1 letter, or a
      # row inside its family. What decides "this section has something to show"
      # (`Registry#has_section?`) and the menu's candidate set — `menu_key` alone answers only
      # level 1, and an unpinned member has none.
      def menu_listed? : Bool
        return false if palette_only?
        member? || !menu_key.nil?
      end

      # The LEVEL-1 key the space menu shows + binds: an explicit mnemonic, else the intent's
      # lexicon letter, else the first plain single-char chord (no ctrl/alt/shift), else
      # nil (verb is excluded from level 1 — it has no single-key handle). Hidden nav
      # chords like "enter"/"left"/"space" are multi-char names, so they never qualify.
      # A family member has no level-1 key unless it is `pinned?`: its letter is the family's
      # (`Registry#l2_key`), and a chord-derived letter would otherwise keep holding a level-1
      # slot the family exists to free. A palette-only verb has none: its chords stay chords.
      def menu_key : Char?
        return nil if palette_only?
        return nil if member? && !pinned?
        if m = @mnemonic
          return m
        end
        if (i = @intent) && (l = Lexicon.letter(i))
          return l
        end
        @chords.each do |c|
          next if c.ctrl || c.alt || c.shift
          return c.key[0] if c.key.size == 1
        end
        nil
      end

      # Runs the verb. The SAME path is used by keybindings and the palette.
      def call(ctx : ExecContext) : String?
        @handler.call(ctx)
      end
    end
  end
end

require "./verb/family"
require "./verb/registry"
require "./verb/lexicon"
require "./verb/os_profile"
require "./verb/keyset"
require "./verb/keymap"
require "./verb/reserved"
require "./verb/conflicts"
