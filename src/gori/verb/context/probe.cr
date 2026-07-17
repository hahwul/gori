# Probe (passive/active scan issues) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # Probe → Rules sub-tab: toggle the selected rule, and add/edit/delete a custom rule.
  abstract def probe_rule_toggle : Nil            # enable/disable the selected Probe rule
  abstract def probe_rule_add : Nil               # open the custom-rule popup to add a rule
  abstract def probe_rule_edit : Nil              # edit the selected custom rule
  abstract def probe_rule_delete : Nil            # delete the selected custom rule (with confirm)
  abstract def probe_custom_rule_selected? : Bool # a CUSTOM (user) rule is selected (gates edit/delete)

  # probe (passive/active scan issues — grouped by code+host)
  abstract def probe_move(delta : Int32) : Nil
  abstract def probe_open : Nil          # open the selected issue's detail
  abstract def probe_close : Nil         # back to the list
  abstract def probe_query : Nil         # focus the `/` filter bar
  abstract def probe_set_mode : Nil      # open the OFF/Passive/Active picker
  abstract def probe_clear : Nil         # delete all issues (after a confirm)
  abstract def probe_delete : Nil        # delete the open/selected issue (after a confirm)
  abstract def probe_dismiss : Nil       # toggle dismiss (open ↔ false-positive) on the target issue
  abstract def probe_toggle_closed : Nil # flip the open-only ⇄ show-closed list lens
  abstract def probe_dismiss_code : Nil  # bulk-dismiss every open issue with the target's code
  abstract def probe_dismiss_host : Nil  # bulk-dismiss every open issue on the target's host
  abstract def probe_open_flow : Nil     # open the issue's sample flow in History
  abstract def probe_repeater_flow : Nil # send the issue's sample flow to Repeater
  abstract def probe_promote : Nil       # create a Issue from the open issue

  # probe active scan — manual, on-demand run of the request-sending active rules against ONE
  # flow, regardless of the current Probe mode. Each opens a confirm dialog showing the
  # expected request count, then runs the probes in the background.
  abstract def probe_active_selected : Nil      # active-scan History's selected (or open) flow
  abstract def probe_active_rescan : Nil        # re-active-scan the selected Probe issue's sample flow
  abstract def probe_active_from_repeater : Nil # active-scan the current Repeater session's last send
end
