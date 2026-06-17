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
      abstract def cycle_tab(delta : Int32) : Nil

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

      # replay workbench (editing + focus/pane toggles are handled inline, not via verbs)
      abstract def replay_selected : Nil # load History's selection into Replay
      abstract def replay_send : Nil     # resend the (edited) request to the target

      # sitemap tree
      abstract def sitemap_move(delta : Int32) : Nil
      abstract def sitemap_toggle : Nil
      abstract def sitemap_expand : Nil
      abstract def sitemap_collapse : Nil

      # scope lens
      abstract def scope_open : Nil     # open the scope overlay editor
      abstract def scope_add_host : Nil # add the selected flow's host to scope

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
      abstract def finding_edit_notes : Nil

      # intercept (hold-and-decide; P4)
      abstract def intercept_toggle : Nil      # toggle the hold queue on/off
      abstract def intercept_forward : Nil     # forward the selected held message (edited bytes)
      abstract def intercept_drop : Nil        # drop the selected held message
      abstract def intercept_forward_all : Nil # forward every held message
      abstract def selected_intercept_id : Int64?

      # capture / proxy control
      abstract def toggle_capture : Nil

      # certificate authority
      abstract def export_ca : Nil
    end
  end
end
