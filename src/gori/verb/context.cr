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

      # History view
      abstract def move_selection(delta : Int32) : Nil
      abstract def open_detail : Nil
      abstract def close_detail : Nil
      abstract def toggle_follow : Nil
      abstract def selected_flow_id : Int64?
      abstract def copy_selection : Nil
      abstract def history_query : Nil # focus the QL filter bar
      # History destructive actions (space-menu only; each opens a confirm first).
      abstract def history_delete : Nil # delete the selected/open flow
      abstract def history_clear : Nil  # wipe every History flow for this project

      # detail view
      abstract def scroll_detail(delta : Int32) : Nil
      # Copy the selection (or current line) from the navigable detail text pane.
      abstract def detail_copy_selection : Nil
      # Horizontal companion to scroll_detail (shift+←/→) — scrolls a long
      # request/response/decoded line sideways instead of right-clipping it.
      abstract def hscroll_detail(delta : Int32) : Nil
      abstract def toggle_detail_pane : Nil
      # Walk the detail panes (REQ→RES→FRAMES) by `dir` (+1 right, −1 left); left
      # past REQUEST returns to the History list.
      abstract def move_detail_pane(dir : Int32) : Nil
      # Toggle a raw hex dump of the current detail pane (request/response bytes).
      abstract def toggle_detail_hex : Nil
      # Toggle whitespace reveal (·→␍␊) in the req/res views (smuggling inspection).
      abstract def toggle_reveal : Nil
      # Toggle pretty-print of req/res bodies (display only; `p` in History detail).
      abstract def toggle_pretty : Nil

      # repeater workbench (text editing + focus/pane nav stay inline; these request-pane
      # toggles are verbs so they're keymap-driven and rebindable)
      abstract def repeater_selected : Nil       # load History's selection into Repeater
      abstract def repeater_new : Nil            # open a blank, hand-authored repeater request
      abstract def repeater_send : Nil           # resend the (edited) request to the target
      abstract def repeater_send_group : Nil     # pipeline %%%-split requests on one connection
      abstract def repeater_find_subtab : Nil    # open the sub-tab search picker (filter + jump)
      abstract def repeater_subtab_count : Int32 # open repeater session count (gates the search menu entry)
      # Generic sub-tab search — the Repeater picker generalised to Fuzzer/Notes/Decoder so
      # jumping to a sub-tab never depends on the fragile Ctrl+digit chord (which many
      # terminals can't deliver). Operate on the active tab; count gates the menu entry.
      abstract def subtab_search_open : Nil                # open the sub-tab search picker for the active tab
      abstract def subtab_search_count : Int32             # active tab's open sub-tab count (gates the search entry)
      abstract def subtab_filter_open : Nil                # open the `/` sub-tab filter bar for the active tab (issue #121)
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
      abstract def repeater_minimize : Nil     # squash the request (strip cosmetic headers/cookies/params) in the background
      abstract def fuzz_pretty_template : Nil
      abstract def fuzz_toggle_http2 : Nil    # flip the fuzz transport h1↔h2 (override seed protocol)
      abstract def repeater_auto_mark : Nil     # wrap every request param value in §…§
      abstract def repeater_mark_word : Nil     # toggle a marker around the token at the cursor
      abstract def repeater_insert_marker : Nil # drop a single § at the cursor (bracket by hand)
      abstract def repeater_clear_marks : Nil   # strip all markers (and their chains)
      abstract def repeater_attach_chain : Nil  # open the chain-edit prompt for the marker at the cursor
      abstract def repeater_copy : Nil          # copy selection or current line (READ panes)
      abstract def repeater_copy_all : Nil      # copy the whole focused pane text
      abstract def repeater_read_mode? : Bool   # focused pane is READ (y/copy verbs gate on this)

      # fuzzer workbench (run/stop/marking handled inline; these power the palette + cross-tab)
      abstract def fuzz_selected : Nil           # send History's selection to the Fuzzer tab
      abstract def fuzz_from_repeater : Nil        # turn the current Repeater request into a fuzz template
      abstract def fuzz_run : Nil                # start the fuzz run
      abstract def fuzz_stop : Nil               # stop the running fuzz
      abstract def fuzz_new : Nil                # open a blank fuzz session
      abstract def fuzz_automark : Nil           # auto-mark every request parameter
      abstract def fuzz_attach_chain : Nil       # open the chain-edit prompt for the marker at the template cursor
      abstract def fuzz_list_paste : Nil         # open the payload-set editor pre-seeded to a List (multi-line, one value per line)
      abstract def fuzz_clear_marks : Nil        # strip all §…§ markers (and their chains) from the template
      abstract def fuzzer_rename_subtab : Nil    # open the rename prompt for the active sub-tab
      abstract def fuzzer_close_subtab : Nil     # close the active sub-tab (confirm-gated)
      abstract def fuzzer_duplicate_subtab : Nil # clone the active sub-tab's content into a new sibling
      abstract def fuzzer_copy : Nil             # copy selection or current line (READ panes)
      abstract def fuzzer_copy_all : Nil         # copy the whole focused pane text
      abstract def fuzzer_read_mode? : Bool      # focused pane is READ (y/copy verbs gate on this)

      # param miner (cross-tab seeds open a config popup, then mining runs in background)
      abstract def mine_selected : Nil            # mine History's selected flow (opens the config popup)
      abstract def mine_from_repeater : Nil         # mine the current Repeater request
      abstract def mine_run : Nil                 # re-run mining for the focused Miner session
      abstract def mine_stop : Nil                # stop the running mine
      abstract def miner_duplicate_subtab : Nil   # clone the active miner sub-tab's content into a new sibling
      abstract def miner_finding_selected? : Bool # a finding is selected in the focused miner session
      abstract def mine_repeater_selected : Nil     # send the selected miner finding to Repeater

      # sitemap tree
      abstract def sitemap_move(delta : Int32) : Nil
      abstract def sitemap_toggle : Nil
      abstract def sitemap_expand : Nil
      abstract def sitemap_collapse : Nil
      abstract def sitemap_query : Nil           # focus the QL filter bar
      abstract def sitemap_tag : Nil             # tag the selected path with a memo
      abstract def sitemap_toggle_grouping : Nil # fold/unfold numeric path-param sequences
      abstract def sitemap_discover : Nil        # spider + brute-force the selected host/path
      abstract def sitemap_repeater : Nil        # send the selected endpoint to Repeater
      abstract def history_discover : Nil        # spider + brute-force the selected flow's host
      abstract def discover_run : Nil            # start / re-run the current Discover run
      abstract def discover_stop : Nil           # stop the running Discover run
      abstract def discover_toggle_pause : Nil   # pause / resume the running Discover run
      abstract def goto_discover : Nil           # focus the Target tab's Discover sub-tab

      # scope lens
      abstract def scope_open : Nil        # jump to the Project tab's scope editor
      abstract def scope_add_host : Nil    # add the selected flow's host to scope
      abstract def scope_toggle_lens : Nil # toggle the scope display lens on/off (filters History/Sitemap)

      # scope rule editing (Project tab SCOPE pane — also drives its "space" action menu)
      abstract def scope_add_rule : Nil        # open the SCOPE rule popup to add a rule
      abstract def scope_edit_rule : Nil       # open the SCOPE rule popup to edit the selected rule
      abstract def scope_delete_rule : Nil     # remove the selected rule
      abstract def scope_rule_selected? : Bool # a scope rule is selected (gates edit/delete in the menu)

      # Probe → Rules sub-tab: toggle the selected rule, and add/edit/delete a custom rule.
      abstract def probe_rule_toggle : Nil            # enable/disable the selected Probe rule
      abstract def probe_rule_add : Nil               # open the custom-rule popup to add a rule
      abstract def probe_rule_edit : Nil              # edit the selected custom rule
      abstract def probe_rule_delete : Nil            # delete the selected custom rule (with confirm)
      abstract def probe_custom_rule_selected? : Bool # a CUSTOM (user) rule is selected (gates edit/delete)

      # hostname-override editing (Project tab HOST OVERRIDES pane — a DISTINCT pane
      # from SCOPE; also drives its own "space" action menu)
      abstract def hostov_add_entry : Nil        # open the inline add-row for a new IP→host override
      abstract def hostov_edit_entry : Nil       # edit the selected override in place
      abstract def hostov_delete_entry : Nil     # remove the selected override
      abstract def hostov_entry_selected? : Bool # an override exists (gates edit/delete in the menu)

      # environment-variable editing (Project tab ENV pane — a DISTINCT pane; also
      # drives its own "space" action menu). The token prefix ($) is a GLOBAL setting,
      # so env.edit-prefix changes it app-wide (not just for this project).
      abstract def env_add_var : Nil        # open the inline add-row for a new $KEY var
      abstract def env_edit_var : Nil       # edit the selected env var in place
      abstract def env_delete_var : Nil     # remove the selected env var
      abstract def env_edit_prefix : Nil    # edit the global $KEY token prefix
      abstract def env_var_selected? : Bool # a var exists (gates edit/delete in the menu)

      # match&replace lens
      abstract def rules_open : Nil # open the match&replace overlay editor

      # issues
      abstract def issue_create : Nil # new issue from the selected flow
      abstract def issues_new : Nil   # new blank issue
      abstract def issues_query : Nil # focus the `/` filter bar (list)
      abstract def issues_move(delta : Int32) : Nil
      abstract def issues_open : Nil
      abstract def issue_close : Nil
      abstract def issues_delete : Nil
      abstract def issue_severity(delta : Int32) : Nil # ±1 step (hidden [ ] chords)
      abstract def issue_status(delta : Int32) : Nil   # ±1 step (hidden { } chords)
      abstract def issue_set_severity : Nil            # open the severity colour picker
      abstract def issue_set_status : Nil              # open the triage-status colour picker
      abstract def issue_edit_notes : Nil
      abstract def issues_notes_read_mode? : Bool # detail open, notes not in INS (gates y/copy)
      abstract def issues_copy : Nil              # copy selection from issue notes (READ)
      abstract def issues_copy_all : Nil          # copy all issue notes (space menu)
      # Horizontal scroll (shift+←/→) for notes in READ (no-op in INS — follow_x tracks the caret).
      abstract def issue_hscroll(delta : Int32) : Nil
      abstract def issue_edit_title : Nil               # rename + set severity via the form overlay
      abstract def issue_open_flow : Nil                # open the linked flow's detail in History
      abstract def issue_repeater_flow : Nil              # send the linked flow to Repeater
      abstract def issue_links : Nil                    # open the links overlay for the open issue
      abstract def issue_open_link : Nil                # open the selected related item in its tab
      abstract def issue_link_move(delta : Int32) : Nil # move selection in the RELATED list
      abstract def issues_export(format : Symbol) : Nil # :markdown | :json → project dir

      # entity links (cross-tab attach + link-target ids for availability gating)
      abstract def link_to_issue : Nil
      abstract def link_to_note : Nil
      abstract def link_flow_id : Int64?
      abstract def link_repeater_id : Int64?
      abstract def link_fuzz_id : Int64?
      abstract def link_miner_id : Int64?

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
      abstract def probe_repeater_flow : Nil   # send the issue's sample flow to Repeater
      abstract def probe_promote : Nil       # create a Issue from the open issue

      # probe active scan — manual, on-demand run of the request-sending active rules against ONE
      # flow, regardless of the current Probe mode. Each opens a confirm dialog showing the
      # expected request count, then runs the probes in the background.
      abstract def probe_active_selected : Nil      # active-scan History's selected (or open) flow
      abstract def probe_active_rescan : Nil        # re-active-scan the selected Probe issue's sample flow
      abstract def probe_active_from_repeater : Nil # active-scan the current Repeater session's last send

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
      abstract def import_ca : Nil     # adopt an externally-created root CA (cert + key PEM)

      # browser: open a system browser pre-trusting gori's CA + routed via the proxy
      abstract def open_browser_picker : Nil

      # comparer: diff two arbitrary flows (multi-session sub-tabs)
      abstract def comparer_pick(slot : Symbol) : Nil # open the flow picker for slot :a / :b
      abstract def comparer_swap : Nil                # swap the A and B flows
      abstract def comparer_toggle_pane : Nil         # toggle the diff between the requests and the responses
      abstract def comparer_add_selected : Nil        # send History's selected flow to the next Comparer slot
      abstract def comparer_new : Nil                 # open a fresh blank comparison sub-tab
      abstract def comparer_close_subtab : Nil        # close the active comparison (keeps ≥1)
      abstract def comparer_rename_subtab : Nil       # rename the active comparison chip
      abstract def comparer_duplicate_subtab : Nil    # clone the active A/B pair

      # decoder: the encode/decode/hash workbench (sub-tab + output actions; the body's
      # text editing + focus nav stay inline, these power the space menu + palette)
      abstract def decoder_new : Nil              # open a fresh blank conversion sub-tab
      abstract def decoder_close : Nil            # close the active conversion sub-tab (keeps ≥1)
      abstract def decoder_rename_subtab : Nil    # open the rename prompt for the active sub-tab
      abstract def decoder_duplicate_subtab : Nil # clone the active conversion into a new sibling
      abstract def decoder_clear : Nil            # clear the current input + chain
      abstract def decoder_copy : Nil             # copy the entire current output to the clipboard
      abstract def decoder_copy_selection : Nil   # copy selection from INPUT/OUTPUT (READ)
      abstract def decoder_copy_all : Nil         # copy the whole focused pane text (space menu / palette fallback)
      abstract def decoder_read_mode? : Bool      # INPUT READ or OUTPUT pane (gates y/copy)
      abstract def decoder_cycle_mode : Nil       # cycle the output display (text/hex/base64)
      abstract def decoder_save : Nil             # save the current chain by name (in-body prompt)
      abstract def decoder_load : Nil             # load a saved chain by name (in-body prompt)

      # jwt: the decode / re-sign / attack-payload workbench (sub-tab + lens actions; the
      # body's text editing + focus nav stay inline, these power the space menu + palette)
      abstract def jwt_new : Nil               # open a fresh blank JWT session sub-tab
      abstract def jwt_close : Nil             # close the active JWT session (keeps ≥1)
      abstract def jwt_rename_subtab : Nil     # open the rename prompt for the active sub-tab
      abstract def jwt_duplicate_subtab : Nil  # clone the active session into a new sibling
      abstract def jwt_clear : Nil             # clear the token + editors of the active session
      abstract def jwt_toggle_mode : Nil       # flip the DECODE ⇄ ENCODE lens
      abstract def jwt_cycle_alg : Nil         # cycle the signing alg (HS256/384/512/none)
      abstract def jwt_load_decoded : Nil      # seed the ENCODE editors from the INPUT token's claims
      abstract def jwt_copy : Nil              # copy selection or the focused pane's content
      abstract def jwt_copy_all : Nil          # copy the focused pane's content (space-menu fallback)
      abstract def jwt_copy_token : Nil        # copy the re-signed OUTPUT token
      abstract def jwt_copy_attack : Nil       # copy the selected ATTACK payload's token
      abstract def jwt_read_mode? : Bool       # focused pane is READ (gates y/copy/select verbs)

      # notes: the multi-note scratchpad (sub-tab actions; the body's text editing
      # stays inline, these power the space menu reachable from the sub-tab strip)
      abstract def notes_new : Nil              # open a fresh blank note sub-tab
      abstract def notes_close : Nil            # close the active note sub-tab (keeps ≥1)
      abstract def notes_duplicate_subtab : Nil # clone the active note's text into a new sibling
      abstract def notes_copy : Nil             # copy selection or current line (READ mode)
      abstract def notes_copy_all : Nil         # copy the entire current note to the clipboard
      abstract def notes_read_mode? : Bool      # READ vs INS (gates y/copy verbs)
      abstract def notes_clear : Nil            # clear the current note's text
      abstract def notes_edit : Nil             # open the current note in the external editor
      abstract def notes_goto : Nil             # open the go-to-line prompt
      abstract def notes_find : Nil             # open the find-in-note prompt
      abstract def notes_links : Nil            # open the links overlay for the current note

      # project: description pane copy actions (READ mode on the DESCRIPTION card)
      abstract def project_desc_read_mode? : Bool
      abstract def project_copy : Nil
      abstract def project_copy_all : Nil

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
