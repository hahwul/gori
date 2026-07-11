require "termisu"
require "../verb"
require "../session"
require "./screen"
require "./geometry"
require "./frame"
require "./chrome"
require "./theme"
require "./jobs"
require "./notifications"

module Gori::Tui
  # The narrow facade a TabController is given to drive the shell's cross-cutting
  # state (P5 — state changes are mediated). A controller never touches the
  # Runner's ivars directly; it asks the Host. Runner implements this. Keeping it
  # thin is deliberate: a controller can only nudge the shell through these, so two
  # controllers can never re-couple via shared private state.
  module Host
    abstract def status(message : String) : Nil       # set the transient status/toast line
    abstract def request_overlay(kind : Symbol) : Nil # set @overlay (controllers can't write it directly)
    abstract def request_focus(pane : Symbol) : Nil   # drive the focus model via focus_pane (:menu | :subtabs | :body)
    abstract def focus_body : Nil                     # raw: focus the body WITHOUT resetting the pane (for clicks)
    abstract def switch_tab(tab : Symbol) : Nil       # change the active tab (with save-on-leave + on_enter)
    abstract def goto_tab(tab : Symbol) : Nil         # raw: set active tab + body focus, no on_enter/view_focus_first (e.g. ^R → Replay)
    abstract def open_palette : Nil                   # open the command palette overlay
    abstract def open_space_menu : Nil                # open the space action menu (bottom-right)
    # Open the Fuzzer's payload-set editor overlay (nil = add a new set, else edit that
    # index) / the advanced-settings overlay. The Runner builds them from the current view.
    abstract def open_fuzz_set_editor(edit_index : Int32?) : Nil
    abstract def open_fuzz_advanced_editor : Nil
    # Open the Project SCOPE rule popup (nil edit_id = add; else edit that rule id).
    # Kind/type/pattern seed the form when editing (or defaults for add).
    abstract def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
    # Destructive-action confirmation modal; `action` runs on confirm.
    abstract def confirm(title : String, message : String, *, confirm_label : String, danger : Bool, &action : -> Nil) : Nil
    abstract def session : Session             # store / scope / proxy / registry / interceptor
    abstract def overlay : Symbol              # read the overlay state (e.g. History reads :detail)
    abstract def active_tab : Symbol           # read the active tab (Replay reconcile gates on it)
    abstract def focus : Symbol                # read the focus model (:menu | :subtabs | :body)
    abstract def reveal? : Bool                # global whitespace-reveal pref, pushed into views
    abstract def toggle_reveal : Nil           # flip the whitespace-reveal pref (^B from any view)
    abstract def pretty? : Bool                # global pretty-print-bodies pref, pushed into views
    abstract def toggle_pretty : Nil           # flip the pretty-print pref (`p` from History/Replay)
    abstract def jobs : Jobs                   # shared background-job registry (bottom-bar activity)
    abstract def notifications : Notifications # shared notification store (center + badge)
    abstract def toggle_scope_lens : Nil       # flip the scope display lens (Project settings pane row/click)
    # Persist + apply the Project settings pane's per-project network config; returns a toast.
    abstract def apply_project_network(bind_host : String, bind_port : Int32, upstream : String) : String
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
      yield frame_inner(rect)
    end

    # One cell inside a body frame — shared by render and click hit-tests.
    def frame_inner(rect : Rect) : Rect
      rect.inset(1, 1)
    end

    # True when the outer body shell should gild its border — single-pane tabs only.
    # Multi-pane views (Replay, Fuzzer, …) highlight the focused pane themselves.
    def shell_focused(focus : Symbol, *, multi_pane : Bool) : Bool
      focus == :body && !multi_pane
    end

    # Frame the tab body, carve the sub-tab strip from the interior top when
    # `labels` is given, then yield the remaining content rect.
    def framed_body(screen : Screen, rect : Rect, shell_focused : Bool,
                    subtabs_focused : Bool, labels : Array(String)?, active : Int32,
                    prev_start : Int32 = 0, & : Rect ->) : Int32
      new_start = prev_start
      framed(screen, rect, shell_focused) do |inner|
        if labels
          sub_rect, content = carve_subtab_row(inner)
          new_start = render_subtab_strip(screen, sub_rect, labels, active, subtabs_focused, prev_start)
          yield content
        else
          yield inner
        end
      end
      new_start
    end

    # Content rect inside a framed body after optional sub-tab carving — keeps
    # render and click geometry aligned.
    def content_rect(rect : Rect, *, strip : Bool) : Rect
      inner = frame_inner(rect)
      strip ? carve_subtab_row(inner)[1] : inner
    end

    # The sub-tab strip inside a framed body (nil when hidden).
    def strip_rect(rect : Rect, *, strip : Bool) : Rect?
      return nil unless strip
      carve_subtab_row(frame_inner(rect))[0]
    end

    # Height of the sub-tab chrome carved off a body rect: one tab row on an elevated
    # band + one hairline that anchors the strip to the body card below.
    STRIP_H = 2

    # Carve the top of a body rect for the sub-tab strip, returning {strip, body_below}.
    # Degenerate heights keep the body on `rect`.
    def carve_subtab_row(rect : Rect) : {Rect, Rect}
      h = {STRIP_H, rect.h}.min
      sub = Rect.new(rect.x, rect.y, rect.w, h)
      body = rect.h > h ? Rect.new(rect.x, rect.y + h, rect.w, rect.h - h) : rect
      {sub, body}
    end

    # The clickable 1-row chip band within a carved strip (hit-tests ignore the divider).
    def tab_row(strip : Rect) : Rect
      Rect.new(strip.x, strip.y, strip.w, 1)
    end

    # The frame-less segmented control shared by Replay, Notes, Fuzzer, … `focused` =
    # the strip itself holds focus (←/→ switch) → active chip lights FOCUS_GOLD and the
    # divider hairline matches.
    def render_subtab_strip(screen : Screen, rect : Rect, labels : Array(String),
                            active : Int32, focused : Bool, prev_start : Int32 = 0) : Int32
      return prev_start if rect.empty?
      new_start = Chrome.render_tab_strip(screen, tab_row(rect), labels, active, focused, prev_start)
      return prev_start if rect.h < 2
      border = focused ? Theme.focus_gold : Theme.border
      screen.hline(rect.x, rect.y + 1, rect.w, fg: border, bg: Theme.bg)
      new_start
    end
  end

  # The shell controller for ONE top-level tab. It owns its view object and all the
  # per-tab input/render/focus logic that used to live in Runner's `case @active_tab`
  # ladders. Concrete defaults make most hooks optional, so a simple read-only tab
  # (Help) overrides only `tab`/`render_body`/`command_scope`, while a rich tab
  # (Replay) overrides the input/focus/lifecycle hooks too.
  abstract class TabController
    property subtab_start : Int32 = 0

    def initialize(@host : Host)
    end

    # --- identity ---
    abstract def tab : Symbol                # the registry key (== Chrome::TABS symbol)
    abstract def command_scope : Verb::Scope # the space-menu scope when this tab + body has focus

    # The space menu's CONTEXT section when this tab's body holds focus — the current
    # focus-area within the tab (e.g. Replay :request/:response/:target). Default
    # :common: single-region tabs (History, Sitemap, …) have no sub-area to single
    # out, so their menu is just the one COMMON group, identical to today.
    def command_section : Symbol
      :common
    end

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

    # Page/jump keyboard nav (PageUp/PageDown → ±one screenful; Home/End → top/bottom).
    # `delta` is a signed row count; Home/End pass a large magnitude and rely on the
    # view's own clamping (so the exact value only needs to exceed the list length).
    # Return true if this tab has a navigable body that consumed it. Default: not
    # navigable — editors leave this false so the physical keys fall through untouched.
    def body_scroll(delta : Int32) : Bool
      false
    end

    # Same notch, but with the pointer position + body rect — lets a multi-pane tab
    # (Project) scroll the pane UNDER the cursor instead of the focused one. Defaults
    # to the coordinate-free handle_wheel, so single-target tabs need no change.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      handle_wheel(step)
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

    # Whether the sub-tab strip is drawn AND `:subtabs` is a focusable pane. Default:
    # only with ≥2 chips — a lone chip has nowhere to switch to, so the row is better
    # spent on the body. Replay/Fuzzer override to show a single chip too, so the active
    # session is always labelled and the strip's space-menu is reachable with one open
    # tab. The Runner reads this (not a raw count) so render + focus + click stay in sync.
    def subtab_strip_shown? : Bool
      (subtab_labels.try(&.size) || 0) >= 2
    end

    # Move the active sub-tab by ±1 (strip ←/→), or jump to an absolute index (^1-9).
    def move_subtab(dir : Int32) : Nil
    end

    def jump_subtab(idx : Int32) : Nil
    end

    # Rows for the "find sub-tab" search picker (space → search). Default: one row per
    # strip label — good enough for Fuzzer/Notes/Convert. Replay overrides to add a
    # summary/URL detail line. Only meaningful when there are ≥2 sub-tabs (the verb gates
    # on subtab_count), so jumping to a sub-tab never needs the Ctrl+digit chord.
    def subtab_search_rows : Array(SubtabPicker::Row)
      (subtab_labels || [] of String).map_with_index do |label, i|
        SubtabPicker::Row.new(i, label, "")
      end
    end

    # Open sub-tab count — gates the search entry. Derived from the strip labels.
    def subtab_count : Int32
      subtab_labels.try(&.size) || 0
    end

    # A FIXED strip (Help): the chip set is constant — no ^N/^W create/close and the
    # body is read-only. The shell drops "new/close/edit" from the strip hint for it.
    def subtabs_fixed? : Bool
      false
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

    # Focus a specific session/sub-tab by its persisted id (notification "jump to
    # result"). Default no-op; Replay/Fuzzer/Miner controllers override to reveal the row.
    def reveal_session(id : Int64) : Nil
    end
  end
end
