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

      # replay workbench (text editing + focus/pane nav stay inline; these request-pane
      # toggles are verbs so they're keymap-driven and rebindable)
      abstract def replay_selected : Nil       # load History's selection into Replay
      abstract def replay_new : Nil            # open a blank, hand-authored replay request
      abstract def replay_send : Nil           # resend the (edited) request to the target
      abstract def replay_find_subtab : Nil    # open the sub-tab search picker (filter + jump)
      abstract def replay_subtab_count : Int32 # open replay session count (gates the search menu entry)
      # Generic sub-tab search — the Replay picker generalised to Fuzzer/Notes/Convert so
      # jumping to a sub-tab never depends on the fragile Ctrl+digit chord (which many
      # terminals can't deliver). Operate on the active tab; count gates the menu entry.
      abstract def subtab_search_open : Nil                # open the sub-tab search picker for the active tab
      abstract def subtab_search_count : Int32             # active tab's open sub-tab count (gates the search entry)
      abstract def replay_rename_subtab : Nil              # open the rename prompt for the active sub-tab
      abstract def replay_tag_subtab : Nil                 # open the tag editor for the active sub-tab (issue #121)
      abstract def replay_filter_subtabs : Nil             # open the `/` tag-filter bar over the sub-tab strip
      abstract def replay_close_subtab : Nil               # close the active sub-tab (confirm-gated)
      abstract def replay_duplicate_subtab : Nil           # clone the active sub-tab's content into a new sibling
      abstract def replay_toggle_hex : Nil                 # toggle byte-exact hex editing of the request pane
      abstract def replay_toggle_decoded : Nil             # toggle the envelope/decoded split sub-pane (SAML/GraphQL)
      abstract def replay_toggle_sni : Nil                 # toggle the SNI-override sub-field (target pane)
      abstract def replay_toggle_auto_content_length : Nil # recompute Content-Length on send
      abstract def replay_toggle_resp_diff : Nil           # switch the response pane between raw and diff-vs-previous
      abstract def replay_toggle_resp_hex : Nil            # toggle a raw hex dump of the response bytes
      # mark-transform mode: mark request values (§…§) and attach Convert chains applied on send
      abstract def replay_toggle_mark_transform : Nil # toggle MARK mode on/off
      abstract def replay_pretty_request : Nil
      abstract def fuzz_pretty_template : Nil
      abstract def replay_auto_mark : Nil     # wrap every request param value in §…§
      abstract def replay_mark_word : Nil     # toggle a marker around the token at the cursor
      abstract def replay_insert_marker : Nil # drop a single § at the cursor (bracket by hand)
      abstract def replay_clear_marks : Nil   # strip all markers (and their chains)
      abstract def replay_attach_chain : Nil  # open the chain-edit prompt for the marker at the cursor
      abstract def replay_copy : Nil          # copy selection or current line (READ panes)
      abstract def replay_copy_all : Nil      # copy the whole focused pane text
      abstract def replay_read_mode? : Bool   # focused pane is READ (y/copy verbs gate on this)

      # fuzzer workbench (run/stop/marking handled inline; these power the palette + cross-tab)
      abstract def fuzz_selected : Nil           # send History's selection to the Fuzzer tab
      abstract def fuzz_from_replay : Nil        # turn the current Replay request into a fuzz template
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
      abstract def mine_from_replay : Nil         # mine the current Replay request
      abstract def mine_run : Nil                 # re-run mining for the focused Miner session
      abstract def mine_stop : Nil                # stop the running mine
      abstract def miner_duplicate_subtab : Nil   # clone the active miner sub-tab's content into a new sibling
      abstract def miner_finding_selected? : Bool # a finding is selected in the focused miner session
      abstract def mine_replay_selected : Nil     # send the selected miner finding to Replay

      # sitemap tree
      abstract def sitemap_move(delta : Int32) : Nil
      abstract def sitemap_toggle : Nil
      abstract def sitemap_expand : Nil
      abstract def sitemap_collapse : Nil
      abstract def sitemap_query : Nil           # focus the QL filter bar
      abstract def sitemap_tag : Nil             # tag the selected path with a memo
      abstract def sitemap_toggle_grouping : Nil # fold/unfold numeric path-param sequences

      # scope lens
      abstract def scope_open : Nil        # jump to the Project tab's scope editor
      abstract def scope_add_host : Nil    # add the selected flow's host to scope
      abstract def scope_toggle_lens : Nil # toggle the scope display lens on/off (filters History/Sitemap)

      # scope rule editing (Project tab SCOPE pane — also drives its "space" action menu)
      abstract def scope_add_rule : Nil        # open the SCOPE rule popup to add a rule
      abstract def scope_edit_rule : Nil       # open the SCOPE rule popup to edit the selected rule
      abstract def scope_delete_rule : Nil     # remove the selected rule
      abstract def scope_rule_selected? : Bool # a scope rule is selected (gates edit/delete in the menu)

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

      # findings
      abstract def finding_create : Nil # new finding from the selected flow
      abstract def findings_new : Nil   # new blank finding
      abstract def findings_query : Nil # focus the `/` filter bar (list)
      abstract def findings_move(delta : Int32) : Nil
      abstract def findings_open : Nil
      abstract def finding_close : Nil
      abstract def findings_delete : Nil
      abstract def finding_severity(delta : Int32) : Nil # ±1 step (hidden [ ] chords)
      abstract def finding_status(delta : Int32) : Nil   # ±1 step (hidden { } chords)
      abstract def finding_set_severity : Nil            # open the severity colour picker
      abstract def finding_set_status : Nil              # open the triage-status colour picker
      abstract def finding_edit_notes : Nil
      abstract def findings_notes_read_mode? : Bool # detail open, notes not in INS (gates y/copy)
      abstract def findings_copy : Nil              # copy selection from finding notes (READ)
      abstract def findings_copy_all : Nil          # copy all finding notes (space menu)
      # Horizontal scroll (shift+←/→) for notes in READ (no-op in INS — follow_x tracks the caret).
      abstract def finding_hscroll(delta : Int32) : Nil
      abstract def finding_edit_title : Nil               # rename + set severity via the form overlay
      abstract def finding_open_flow : Nil                # open the linked flow's detail in History
      abstract def finding_replay_flow : Nil              # send the linked flow to Replay
      abstract def finding_links : Nil                    # open the links overlay for the open finding
      abstract def finding_open_link : Nil                # open the selected related item in its tab
      abstract def finding_link_move(delta : Int32) : Nil # move selection in the RELATED list
      abstract def findings_export(format : Symbol) : Nil # :markdown | :json → project dir

      # entity links (cross-tab attach + link-target ids for availability gating)
      abstract def link_to_finding : Nil
      abstract def link_to_note : Nil
      abstract def link_flow_id : Int64?
      abstract def link_replay_id : Int64?
      abstract def link_fuzz_id : Int64?
      abstract def link_miner_id : Int64?

      # prism (passive/active scan issues — grouped by code+host)
      abstract def prism_move(delta : Int32) : Nil
      abstract def prism_open : Nil          # open the selected issue's detail
      abstract def prism_close : Nil         # back to the list
      abstract def prism_query : Nil         # focus the `/` filter bar
      abstract def prism_set_mode : Nil      # open the OFF/Passive/Active picker
      abstract def prism_clear : Nil         # delete all issues (after a confirm)
      abstract def prism_delete : Nil        # delete the open/selected issue (after a confirm)
      abstract def prism_dismiss : Nil       # toggle dismiss (open ↔ false-positive) on the target issue
      abstract def prism_toggle_closed : Nil # flip the open-only ⇄ show-closed list lens
      abstract def prism_dismiss_code : Nil  # bulk-dismiss every open issue with the target's code
      abstract def prism_dismiss_host : Nil  # bulk-dismiss every open issue on the target's host
      abstract def prism_open_flow : Nil     # open the issue's sample flow in History
      abstract def prism_replay_flow : Nil   # send the issue's sample flow to Replay
      abstract def prism_promote : Nil       # create a Finding from the open issue

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

      # comparer: diff two arbitrary flows (multi-session sub-tabs)
      abstract def comparer_pick(slot : Symbol) : Nil # open the flow picker for slot :a / :b
      abstract def comparer_swap : Nil                # swap the A and B flows
      abstract def comparer_toggle_pane : Nil         # toggle the diff between the requests and the responses
      abstract def comparer_add_selected : Nil        # send History's selected flow to the next Comparer slot
      abstract def comparer_new : Nil                 # open a fresh blank comparison sub-tab
      abstract def comparer_close_subtab : Nil        # close the active comparison (keeps ≥1)
      abstract def comparer_rename_subtab : Nil       # rename the active comparison chip
      abstract def comparer_duplicate_subtab : Nil    # clone the active A/B pair

      # convert: the encode/decode/hash workbench (sub-tab + output actions; the body's
      # text editing + focus nav stay inline, these power the space menu + palette)
      abstract def convert_new : Nil              # open a fresh blank conversion sub-tab
      abstract def convert_close : Nil            # close the active conversion sub-tab (keeps ≥1)
      abstract def convert_rename_subtab : Nil    # open the rename prompt for the active sub-tab
      abstract def convert_duplicate_subtab : Nil # clone the active conversion into a new sibling
      abstract def convert_clear : Nil            # clear the current input + chain
      abstract def convert_copy : Nil             # copy the entire current output to the clipboard
      abstract def convert_copy_selection : Nil   # copy selection from INPUT/OUTPUT (READ)
      abstract def convert_copy_all : Nil         # copy the whole focused pane text (space menu / palette fallback)
      abstract def convert_read_mode? : Bool      # INPUT READ or OUTPUT pane (gates y/copy)
      abstract def convert_cycle_mode : Nil       # cycle the output display (text/hex/base64)
      abstract def convert_save : Nil             # save the current chain by name (in-body prompt)
      abstract def convert_load : Nil             # load a saved chain by name (in-body prompt)

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
