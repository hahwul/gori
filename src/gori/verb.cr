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
      Sitemap        # the Sitemap tab has focus
      Findings       # the Findings list has focus
      FindingsDetail # a finding's detail is open
      Intercept      # the Intercept queue tab has focus
      PaletteOpen    # the command palette overlay is up
    end

    # A keybinding as pure data (no terminal dependency). The TUI converts a
    # termisu key event into a Chord and looks it up in the Keymap.
    record Chord, key : String, ctrl : Bool = false, alt : Bool = false, shift : Bool = false do
      # Human-readable label for palette hints, e.g. "ctrl-p", "g", "enter".
      def label : String
        String.build do |io|
          io << "ctrl-" if ctrl
          io << "alt-" if alt
          io << "shift-" if shift
          io << key
        end
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
      getter chords : Array(Chord)
      getter? hidden : Bool

      def initialize(@id : String, @title : String, @description : String, @scope : Scope,
                     @chords : Array(Chord) = [] of Chord, @hidden : Bool = false,
                     @available : ExecContext -> Bool = ->(_ctx : ExecContext) { true },
                     &@handler : ExecContext -> String?)
      end

      def available?(ctx : ExecContext) : Bool
        @available.call(ctx)
      end

      # Runs the verb. The SAME path is used by keybindings and the palette.
      def call(ctx : ExecContext) : String?
        @handler.call(ctx)
      end
    end
  end
end

require "./verb/registry"
require "./verb/keymap"
