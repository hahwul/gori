# Repeater workbench — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # repeater workbench (text editing + focus/pane nav stay inline; these request-pane
  # toggles are verbs so they're keymap-driven and rebindable)
  abstract def repeater_selected : Nil                   # load History's selection into Repeater
  abstract def repeater_new : Nil                        # open a blank, hand-authored repeater request
  abstract def repeater_send : Nil                       # resend the (edited) request to the target
  abstract def repeater_send_group : Nil                 # pipeline %%%-split requests on one connection
  abstract def repeater_find_subtab : Nil                # open the sub-tab search picker (filter + jump)
  abstract def repeater_subtab_count : Int32             # open repeater session count (gates the search menu entry)
  abstract def repeater_rename_subtab : Nil              # open the rename prompt for the active sub-tab
  abstract def repeater_tag_subtab : Nil                 # open the tag editor for the active sub-tab (issue #121)
  abstract def repeater_filter_subtabs : Nil             # open the `/` tag-filter bar over the sub-tab strip
  abstract def repeater_close_subtab : Nil               # close the active sub-tab (confirm-gated)
  abstract def repeater_duplicate_subtab : Nil           # clone the active sub-tab's content into a new sibling
  abstract def repeater_toggle_hex : Nil                 # toggle byte-exact hex editing of the request pane
  abstract def repeater_toggle_decoded : Nil             # toggle the envelope/decoded split sub-pane (SAML/GraphQL)
  abstract def repeater_toggle_sni : Nil                 # toggle the SNI-override sub-field (target pane)
  abstract def repeater_toggle_auto_content_length : Nil # recompute Content-Length on send
  abstract def repeater_toggle_http2 : Nil               # flip the request transport h1↔h2 (override captured protocol)
  abstract def repeater_toggle_resp_diff : Nil           # switch the response pane between raw and diff-vs-previous
  abstract def repeater_toggle_resp_hex : Nil            # toggle a raw hex dump of the response bytes
  abstract def repeater_pretty_request : Nil
  abstract def repeater_minimize : Nil      # squash the request (strip cosmetic headers/cookies/params) in the background
  abstract def repeater_auto_mark : Nil     # wrap every request param value in §…§
  abstract def repeater_mark_word : Nil     # toggle a marker around the token at the cursor
  abstract def repeater_insert_marker : Nil # drop a single § at the cursor (bracket by hand)
  abstract def repeater_clear_marks : Nil   # strip all markers (and their chains)
  abstract def repeater_attach_chain : Nil  # open the chain-edit prompt for the marker at the cursor
  abstract def repeater_copy : Nil          # copy selection or current line (READ panes)
  abstract def repeater_copy_all : Nil      # copy the whole focused pane text
  abstract def repeater_read_mode? : Bool   # focused pane is READ (y/copy verbs gate on this)
end
