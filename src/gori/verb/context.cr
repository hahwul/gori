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
      abstract def close_overlay : Nil

      # the currently focused tab (so verbs can gate by context, P4)
      abstract def current_tab : Symbol

      # pane focus (:sidebar | :body) and tab navigation
      abstract def focus_pane(pane : Symbol) : Nil
      abstract def focus_tab(tab : Symbol) : Nil
      # Focus the Nth (1-based) VISIBLE tab — the positional number-key target, which
      # follows the user's settings:tabs order/visibility. Out-of-range n is a no-op.
      abstract def focus_visible_tab(n : Int32) : Nil
      abstract def cycle_tab(delta : Int32) : Nil
      # Descend from the tab menu into the active tab's content. Tabs with a
      # navigable sub-tab strip (Replay/Notes) land on the STRIP first; others go
      # straight to the body. (The strip then descends into the editor itself.)
      abstract def enter_content : Nil

      # History view
      abstract def move_selection(delta : Int32) : Nil
      abstract def open_detail : Nil
      abstract def close_detail : Nil
      abstract def toggle_follow : Nil
      abstract def selected_flow_id : Int64?
      abstract def copy_selection : Nil
      abstract def history_query : Nil # focus the QL filter bar

      # detail view
      abstract def scroll_detail(delta : Int32) : Nil
      abstract def toggle_detail_pane : Nil
      # Walk the detail panes (REQ→RES→FRAMES) by `dir` (+1 right, −1 left); left
      # past REQUEST returns to the History list.
      abstract def move_detail_pane(dir : Int32) : Nil
      # Toggle a raw hex dump of the current detail pane (request/response bytes).
      abstract def toggle_detail_hex : Nil
      # Toggle whitespace reveal (·→␍␊) in the req/res views (smuggling inspection).
      abstract def toggle_reveal : Nil

      # replay workbench (editing + focus/pane toggles are handled inline, not via verbs)
      abstract def replay_selected : Nil # load History's selection into Replay
      abstract def replay_new : Nil      # open a blank, hand-authored replay request
      abstract def replay_send : Nil     # resend the (edited) request to the target

      # fuzzer workbench (run/stop/marking handled inline; these power the palette + cross-tab)
      abstract def fuzz_selected : Nil    # send History's selection to the Fuzzer tab
      abstract def fuzz_from_replay : Nil # turn the current Replay request into a fuzz template
      abstract def fuzz_run : Nil         # start the fuzz run
      abstract def fuzz_stop : Nil        # stop the running fuzz
      abstract def fuzz_new : Nil         # open a blank fuzz session
      abstract def fuzz_automark : Nil    # auto-mark every request parameter

      # sitemap tree
      abstract def sitemap_move(delta : Int32) : Nil
      abstract def sitemap_toggle : Nil
      abstract def sitemap_expand : Nil
      abstract def sitemap_collapse : Nil
      abstract def sitemap_query : Nil # focus the QL filter bar

      # scope lens
      abstract def scope_open : Nil        # jump to the Project tab's scope editor
      abstract def scope_add_host : Nil    # add the selected flow's host to scope
      abstract def scope_toggle_lens : Nil # toggle the scope display lens on/off (filters History/Sitemap)

      # match&replace lens
      abstract def rules_open : Nil # open the match&replace overlay editor

      # findings
      abstract def finding_create : Nil # new finding from the selected flow
      abstract def findings_new : Nil   # new blank finding
      abstract def findings_move(delta : Int32) : Nil
      abstract def findings_open : Nil
      abstract def finding_close : Nil
      abstract def findings_delete : Nil
      abstract def finding_severity(delta : Int32) : Nil
      abstract def finding_status(delta : Int32) : Nil
      abstract def finding_edit_notes : Nil
      abstract def finding_edit_title : Nil               # rename + set severity via the form overlay
      abstract def finding_open_flow : Nil                # open the linked flow's detail in History
      abstract def finding_replay_flow : Nil              # send the linked flow to Replay
      abstract def findings_export(format : Symbol) : Nil # :markdown | :json → project dir

      # intercept (hold-and-decide; P4)
      abstract def intercept_toggle : Nil          # toggle the hold queue on/off
      abstract def intercept_forward : Nil         # forward the selected held message (edited bytes)
      abstract def intercept_drop : Nil            # drop the selected held message
      abstract def intercept_forward_all : Nil     # forward every held message
      abstract def intercept_query : Nil           # focus the catch-condition filter bar
      abstract def intercept_cycle_direction : Nil # cycle catch direction (all/req/res)
      abstract def selected_intercept_id : Int64?

      # capture / proxy control
      abstract def toggle_capture : Nil

      # certificate authority
      abstract def export_ca : Nil
      abstract def regenerate_ca : Nil # mint a fresh root CA (after a confirm)

      # browser: open a system browser pre-trusting gori's CA + routed via the proxy
      abstract def open_browser_picker : Nil

      # settings: open the config editor for a section (:network | :editor | :theme |
      # :tabs | :hotkeys). :tabs opens the tab-bar customizer overlay.
      abstract def open_settings(section : Symbol) : Nil
    end
  end
end
