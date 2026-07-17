require "./context/comparer"
require "./context/decoder"
require "./context/discover"
require "./context/env"
require "./context/fuzzer"
require "./context/history"
require "./context/host_overrides"
require "./context/intercept"
require "./context/issues"
require "./context/jwt"
require "./context/miner"
require "./context/notes"
require "./context/oast"
require "./context/probe"
require "./context/project"
require "./context/repeater"
require "./context/rewriter"
require "./context/scope"
require "./context/sequencer"
require "./context/sitemap"

module Gori
  module Verb
    # The narrow facade a verb handler is given. Verbs express *intents* through
    # it; they never touch raw TUI/proxy/store state directly (P5 — state changes
    # are mediated). The TUI App provides the concrete implementation; tests use
    # a recording double. Keeping this interface thin is deliberate (P0): it is
    # the entire surface verbs can affect, so it doubles as the action catalogue.
    abstract class ExecContext
      # app lifecycle / messaging
      abstract def quit! : Nil         # exit gori entirely
      abstract def leave_project : Nil # close the project, back to the picker
      abstract def status(message : String) : Nil

      # overlays
      abstract def open_palette : Nil
      abstract def open_notifications : Nil # open the notification center (background-job results)
      abstract def close_overlay : Nil

      # Emergency full repaint: redraw every cell (a full sync, not a diff). Recovers from
      # corruption the diff-renderer can't reach — e.g. stray glyphs a binary body's
      # accidental wide/emoji graphemes left behind by desyncing cursor tracking.
      abstract def refresh_screen : Nil

      # the currently focused tab (so verbs can gate by context, P4)
      abstract def current_tab : Symbol

      # pane focus (:sidebar | :body) and tab navigation
      abstract def focus_pane(pane : Symbol) : Nil
      abstract def focus_tab(tab : Symbol) : Nil
      # Focus the Nth (1-based) VISIBLE tab — the positional number-key target, which
      # follows the user's settings:tabs order/visibility. Out-of-range n is a no-op.
      abstract def focus_visible_tab(n : Int32) : Nil
      abstract def cycle_tab(delta : Int32) : Nil
      # Horizontal tab-bar navigation (←/→ on the menu). Like cycle_tab(±1), but → past
      # the last visible tab lands on the far-right "more" dropdown affordance (holding
      # the settings-hidden tabs) instead of wrapping; ← steps back off it.
      abstract def menu_left : Nil
      abstract def menu_right : Nil
      # Descend from the tab menu into the active tab's content. Tabs with a
      # navigable sub-tab strip (Repeater/Notes) land on the STRIP first; others go
      # straight to the body. (The strip then descends into the editor itself.)
      abstract def enter_content : Nil
      # Generic sub-tab search — the Repeater picker generalised to Fuzzer/Notes/Decoder so
      # jumping to a sub-tab never depends on the fragile Ctrl+digit chord (which many
      # terminals can't deliver). Operate on the active tab; count gates the menu entry.
      abstract def subtab_search_open : Nil    # open the sub-tab search picker for the active tab
      abstract def subtab_search_count : Int32 # active tab's open sub-tab count (gates the search entry)
      abstract def subtab_filter_open : Nil    # open the `/` sub-tab filter bar for the active tab (issue #121)

      # entity links (cross-tab attach + link-target ids for availability gating)
      abstract def link_to_issue : Nil
      abstract def link_to_note : Nil
      abstract def link_flow_id : Int64?
      abstract def link_repeater_id : Int64?
      abstract def link_fuzz_id : Int64?
      abstract def link_miner_id : Int64?

      # capture / proxy control
      abstract def toggle_capture : Nil

      # certificate authority
      abstract def export_ca : Nil
      abstract def regenerate_ca : Nil # mint a fresh root CA (after a confirm)
      abstract def import_ca : Nil     # adopt an externally-created root CA (cert + key PEM)

      # browser: open a system browser pre-trusting gori's CA + routed via the proxy
      abstract def open_browser_picker : Nil

      # READ editors: line select / selection state (space menu + x/v chords).
      abstract def read_selection_active? : Bool
      abstract def read_select_line : Nil
      abstract def read_clear_selection : Nil
      # The unified "Copy" verb's fallback: selection if one is active, else the
      # whole focused pane. Routes to the active tab's existing copy delegators
      # (not new copy logic) — mirrors read_selection_active?'s per-tab dispatch.
      abstract def read_copy : Nil
      # "Copy as X": open a centered picker of the focused HTTP message's copy formats
      # (url/headers/body/cookies/curl/raw). Focus-aware — the offered set follows the
      # active pane; degrades to read_copy when the context has no format variants.
      abstract def copy_as_open : Nil
      # "Send selection to X": open a centered picker of string-handling destinations
      # (Decoder for now) and route the current selection into the chosen one's input.
      # Gated by read_selection_active?; the payload comes from read_selection_text.
      abstract def send_to_open : Nil
      abstract def detail_navigable? : Bool # History detail text pane (not hex)
      # Override a verb's space-menu title (nil → use the registered default).
      abstract def space_menu_title(verb_id : String) : String?

      # settings: open the config editor for a section (:network | :editor | :theme |
      # :tabs | :hotkeys). :tabs opens the tab-bar customizer overlay.
      abstract def open_settings(section : Symbol) : Nil

      # import: palette-only bulk importers — each opens a path prompt, parses the
      # file, and inserts flows into History (Sitemap derives from the same store).
      abstract def import_har : Nil
      abstract def import_urls : Nil
      abstract def import_oas : Nil
    end
  end
end
