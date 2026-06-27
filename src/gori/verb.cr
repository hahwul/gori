require "./verb/context"

module Gori
  # The verb system — gori's "same surface" core (P1). A single Definition is the
  # one source of truth that drives a keybinding AND a command-palette entry (and
  # later an MCP tool + CLI subcommand). No per-surface code paths.
  module Verb
    # Where a verb may fire. The active surface (focused tab / open overlay)
    # selects which scope's keymap is consulted; Global verbs fire everywhere.
    enum Scope
      Global         # fires anywhere
      Sidebar        # the tab list has focus
      Body           # the content pane has focus (e.g. the History list)
      HistoryDetail  # a flow's detail view is open
      Replay         # the Replay tab has focus
      Fuzzer         # the Fuzzer tab has focus
      Sitemap        # the Sitemap tab has focus
      Findings       # the Findings list has focus
      FindingsDetail # a finding's detail is open
      Intercept      # the Intercept queue tab has focus
      Comparer       # the Comparer tab has focus
      Project        # the Project tab's SCOPE rule list has focus
      PaletteOpen    # the command palette overlay is up
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

    # A keybinding as pure data (no terminal dependency). The TUI converts a
    # termisu key event into a Chord and looks it up in the Keymap.
    record Chord, key : String, ctrl : Bool = false, alt : Bool = false, shift : Bool = false do
      # The named (non-character) keys a chord may carry, matching the names
      # Tui::Keybind.from_event emits. Anything else must be a single ASCII char.
      NAMED_KEYS = %w(enter escape tab up down left right backspace space)

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
    # Argument schemas (for palette prompts / MCP) are intentionally absent this
    # milestone — no verb takes arguments yet, and the field is additive later.
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

      def initialize(@id : String, @title : String, @description : String, @scope : Scope,
                     @chords : Array(Chord) = [] of Chord, @hidden : Bool = false,
                     @available : ExecContext -> Bool = ->(_ctx : ExecContext) { true },
                     @coming_soon : Bool = false, @category : Category = Category::Action,
                     @mnemonic : Char? = nil,
                     &@handler : ExecContext -> String?)
      end

      def available?(ctx : ExecContext) : Bool
        @available.call(ctx)
      end

      # The key the space menu shows + binds: an explicit mnemonic, else the first
      # plain single-char chord (no ctrl/alt/shift), else nil (verb is excluded
      # from the menu — it has no single-key handle). Hidden nav chords like
      # "enter"/"left"/"space" are multi-char names, so they never qualify.
      def menu_key : Char?
        if m = @mnemonic
          return m
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

require "./verb/registry"
require "./verb/os_profile"
require "./verb/keymap"
require "./verb/reserved"
require "./verb/conflicts"
