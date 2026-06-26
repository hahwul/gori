require "termisu"
require "../verb"
require "../session"
require "./screen"
require "./geometry"
require "./frame"
require "./chrome"
require "./theme"

module Gori::Tui
  # The narrow facade a TabController is given to drive the shell's cross-cutting
  # state (P5 — state changes are mediated). A controller never touches the
  # Runner's ivars directly; it asks the Host. Runner implements this. Keeping it
  # thin is deliberate: a controller can only nudge the shell through these, so two
  # controllers can never re-couple via shared private state.
  module Host
    abstract def status(message : String) : Nil       # set the transient status/toast line
    abstract def request_overlay(kind : Symbol) : Nil  # set @overlay (controllers can't write it directly)
    abstract def request_focus(pane : Symbol) : Nil    # drive the focus model via focus_pane (:menu | :subtabs | :body)
    abstract def focus_body : Nil                      # raw: focus the body WITHOUT resetting the pane (for clicks)
    abstract def switch_tab(tab : Symbol) : Nil        # change the active tab (with save-on-leave + on_enter)
    abstract def goto_tab(tab : Symbol) : Nil          # raw: set active tab + body focus, no on_enter/view_focus_first (e.g. ^R → Replay)
    abstract def open_palette : Nil                    # open the command palette overlay
    abstract def open_command : Nil                    # open the ":" context command line
    # Destructive-action confirmation modal; `action` runs on confirm.
    abstract def confirm(title : String, message : String, *, confirm_label : String, danger : Bool, &action : -> Nil) : Nil
    abstract def session : Session                     # store / scope / proxy / registry / interceptor
    abstract def overlay : Symbol                      # read the overlay state (e.g. History reads :detail)
    abstract def active_tab : Symbol                   # read the active tab (Replay reconcile gates on it)
    abstract def focus : Symbol                         # read the focus model (:menu | :subtabs | :body)
    abstract def reveal? : Bool                        # global whitespace-reveal pref, pushed into views
    abstract def toggle_reveal : Nil                   # flip the whitespace-reveal pref (^B from any view)
    abstract def pretty? : Bool                        # global pretty-print-bodies pref, pushed into views
    abstract def toggle_pretty : Nil                   # flip the pretty-print pref (`p` from History/Replay)
  end

  # Shared, state-free body chrome used by BOTH Runner and the per-tab
  # controllers, so the framed-card outline and the Replay/Notes sub-tab strip are
  # drawn identically wherever they appear. Extracted from Runner so a controller
  # can frame its own body without reaching back into the shell.
  module BodyChrome
    extend self

    # Frame a single body pane and yield the inset interior. Gold outline when the
    # body holds focus, hairline at rest. Outline-only on the canvas (bg = BG),
    # distinct from the lifted PANEL-filled modal overlays.
    def framed(screen : Screen, rect : Rect, focused : Bool, & : Rect ->) : Nil
      Frame.card(screen, rect, bg: Theme.bg, border: focused ? Theme.focus_gold : Theme.border)
      yield rect.inset(1, 1)
    end

    # Carve the top row of a body rect for the sub-tab strip, returning
    # {strip_row, body_below}. Degenerate heights keep the body on `rect`.
    def carve_subtab_row(rect : Rect) : {Rect, Rect}
      sub = Rect.new(rect.x, rect.y, rect.w, 1)
      body = rect.h > 1 ? Rect.new(rect.x, rect.y + 1, rect.w, rect.h - 1) : rect
      {sub, body}
    end

    # The frame-less, 1-row segmented control shared by Replay and Notes. `focused`
    # = the strip itself holds focus (←/→ switch) → active chip lights ACCENT_BG.
    def render_subtab_strip(screen : Screen, rect : Rect, labels : Array(String),
                            active : Int32, focused : Bool) : Nil
      return if rect.empty?
      Chrome.render_tab_strip(screen, rect, labels, active, focused)
    end
  end

  # The shell controller for ONE top-level tab. It owns its view object and all the
  # per-tab input/render/focus logic that used to live in Runner's `case @active_tab`
  # ladders. Concrete defaults make most hooks optional, so a simple read-only tab
  # (Help) overrides only `tab`/`render_body`/`command_scope`, while a rich tab
  # (Replay) overrides the input/focus/lifecycle hooks too.
  abstract class TabController
    def initialize(@host : Host)
    end

    # --- identity ---
    abstract def tab : Symbol                # the registry key (== Chrome::TABS symbol)
    abstract def command_scope : Verb::Scope # the `:` command-line scope when this tab + body has focus

    # --- rendering --- (`focus` is the shell's @focus: :menu | :subtabs | :body)
    abstract def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil

    # --- input (return true = handled; false = fall through to the verb keymap) ---
    # Called only when this tab is active, no overlay is open, and @focus == :body.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      false
    end

    # Called when a left-click lands in the body rect (after the strip is handled).
    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      false
    end

    # A scroll-wheel notch over the body (already ±3-scaled).
    def handle_wheel(step : Int32) : Bool
      false
    end

    # Live IME composition text for the focused body field. Return true if consumed.
    def set_preedit(text : String) : Bool
      false
    end

    # --- sub-tab strip (Replay/Notes); nil = no strip ---
    def subtab_labels : Array(String)?
      nil
    end

    def subtab_index : Int32
      0
    end

    # Move the active sub-tab by ±1 (strip ←/→), or jump to an absolute index (^1-9).
    def move_subtab(dir : Int32) : Nil
    end

    def jump_subtab(idx : Int32) : Nil
    end

    # --- status bar ---
    def body_badge : Symbol # :editor (captures text) | :body (navigable/read-only)
      :body
    end

    def body_hint(focus : Symbol) : String
      ""
    end

    # --- orthogonal ^G/^F prompts: the symbol naming the currently-focused
    # searchable pane (e.g. :replay_request, :notes), or nil if none. The shell's
    # goto/search prompt dispatches on this symbol. A future cleanup could return a
    # richer Searchable object to also fold the shell's per-symbol jump/search
    # dispatch into the controller. ---
    def goto_symbol : Symbol?
      nil
    end

    # --- focus ring (Tab/Shift-Tab across panes); false = no further pane ---
    def pane_advance(dir : Int32) : Bool
      false
    end

    def focus_first : Nil
    end

    def focus_last : Nil
    end

    # --- lifecycle ---
    def on_enter : Nil # tab became active — refresh derived data
    end

    def on_external_change : Nil # another connection committed to the project DB
    end

    def commit : Nil # flush any in-progress edit before leave/quit
    end

    def locked? : Bool # a destructive op is gated (e.g. last note can't close)
      false
    end
  end
end
