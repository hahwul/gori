require "../../src/gori"

# A RECORDING ExecContext for exercising registry/palette logic and the verb bodies
# themselves. Every command method (the Nil-returning "do something" half of the
# interface) appends a Call instead of doing work, so a spec can assert exactly which
# intent a verb dispatched — and in what order, which matters for the verbs that chain
# two calls (detail.repeater closes the detail BEFORE opening the Repeater). The query
# half (selected_flow_id, *_read_mode?, *_count …) stays settable state, since verbs
# read it through `available?` gates rather than driving it.
class FakeExecContext < Gori::Verb::ExecContext
  # One recorded dispatch: the ExecContext method plus its stringified arguments
  # (Symbol/Int32 both render usefully, and a String comparison keeps assertions terse).
  record Call, name : Symbol, args : Array(String)

  getter calls = [] of Call

  property selected : Int64? = nil
  property current_tab : Symbol = :history # settable so tab-gated verbs (Decoder, …) can be exercised

  # The recorded method names in dispatch order — the usual assertion target.
  def call_names : Array(Symbol)
    @calls.map(&.name)
  end

  # Arguments of the one recorded call named `name`, or nil when it never fired. RAISES
  # when the intent fired more than once: returning the first match would let a handler
  # that dispatched the same intent twice with different arguments (focus_pane(:menu)
  # then focus_pane(:subtabs)) hide behind the one the spec happened to expect.
  def args_for(name : Symbol) : Array(String)?
    found = @calls.select { |c| c.name == name }
    if found.size > 1
      raise "#{name} was dispatched #{found.size} times (#{found.map(&.args).inspect}); assert on #calls instead"
    end
    found.first?.try(&.args)
  end

  private def rec(name : Symbol) : Nil
    @calls << Call.new(name, [] of String)
  end

  private def rec(name : Symbol, *args) : Nil
    @calls << Call.new(name, args.map(&.to_s).to_a)
  end

  def quit! : Nil
    rec(:quit!)
  end

  def leave_project : Nil
    rec(:leave_project)
  end

  def status(message : String) : Nil
    rec(:status, message)
  end

  def open_palette : Nil
    rec(:open_palette)
  end

  def open_notifications : Nil
    rec(:open_notifications)
  end

  def open_passthrough : Nil
    rec(:open_passthrough)
  end

  def open_listeners : Nil
    rec(:open_listeners)
  end

  def close_overlay : Nil
    rec(:close_overlay)
  end

  def refresh_screen : Nil
    rec(:refresh_screen)
  end

  def toggle_pet : Nil
    rec(:toggle_pet)
  end

  def focus_pane(pane : Symbol) : Nil
    rec(:focus_pane, pane)
  end

  def enter_content : Nil
    rec(:enter_content)
  end

  def focus_tab(tab : Symbol) : Nil
    rec(:focus_tab, tab)
  end

  def focus_visible_tab(n : Int32) : Nil
    rec(:focus_visible_tab, n)
  end

  def cycle_tab(delta : Int32) : Nil
    rec(:cycle_tab, delta)
  end

  def menu_left : Nil
    rec(:menu_left)
  end

  def menu_right : Nil
    rec(:menu_right)
  end

  def move_selection(delta : Int32) : Nil
    rec(:move_selection, delta)
  end

  def open_detail : Nil
    rec(:open_detail)
  end

  def close_detail : Nil
    rec(:close_detail)
  end

  def toggle_follow : Nil
    rec(:toggle_follow)
  end

  def selected_flow_id : Int64?
    @selected
  end

  # Multi-select marks (#442). `marks` is settable state (the query half); the effective
  # target set derives from it exactly as the Runner's does — marks if any, else the cursor
  # — so a spec can exercise the marks-vs-cursor rule without a live view. Defaults to
  # empty so every `available?` lambda is safe on a bare FakeExecContext
  # (spec/verbs/registry_sweep_spec.cr).
  property marks = [] of Int64

  def selected_flow_ids : Array(Int64)
    return marks unless marks.empty?
    [@selected].compact
  end

  def marked_flow_count : Int32
    marks.size
  end

  def history_mark_toggle : Nil
    rec(:history_mark_toggle)
  end

  def history_mark_all : Nil
    rec(:history_mark_all)
  end

  def history_mark_clear : Nil
    rec(:history_mark_clear)
  end

  def history_mark_extend(delta : Int32) : Nil
    rec(:history_mark_extend, delta)
  end

  def copy_selection : Nil
    rec(:copy_selection)
  end

  def history_query : Nil
    rec(:history_query)
  end

  def history_delete : Nil
    rec(:history_delete)
  end

  def history_clear : Nil
    rec(:history_clear)
  end

  def scroll_detail(delta : Int32) : Nil
    rec(:scroll_detail, delta)
  end

  def detail_copy_selection : Nil
    rec(:detail_copy_selection)
  end

  def hscroll_detail(delta : Int32) : Nil
    rec(:hscroll_detail, delta)
  end

  def toggle_detail_pane : Nil
    rec(:toggle_detail_pane)
  end

  def move_detail_pane(dir : Int32) : Nil
    rec(:move_detail_pane, dir)
  end

  def toggle_detail_hex : Nil
    rec(:toggle_detail_hex)
  end

  def toggle_reveal : Nil
    rec(:toggle_reveal)
  end

  def toggle_pretty : Nil
    rec(:toggle_pretty)
  end

  def repeater_selected : Nil
    rec(:repeater_selected)
  end

  def repeater_new : Nil
    rec(:repeater_new)
  end

  def repeater_send : Nil
    rec(:repeater_send)
  end

  def repeater_send_group : Nil
    rec(:repeater_send_group)
  end

  def repeater_find_subtab : Nil
    rec(:repeater_find_subtab)
  end

  property repeater_tab_count : Int32 = 0

  def repeater_subtab_count : Int32
    @repeater_tab_count
  end

  def subtab_search_open : Nil
    rec(:subtab_search_open)
  end

  def subtab_filter_open : Nil
    rec(:subtab_filter_open)
  end

  property subtab_search_tab_count : Int32 = 0

  def subtab_search_count : Int32
    @subtab_search_tab_count
  end

  def repeater_rename_subtab : Nil
    rec(:repeater_rename_subtab)
  end

  def repeater_tag_subtab : Nil
    rec(:repeater_tag_subtab)
  end

  def repeater_filter_subtabs : Nil
    rec(:repeater_filter_subtabs)
  end

  def repeater_close_subtab : Nil
    rec(:repeater_close_subtab)
  end

  def repeater_duplicate_subtab : Nil
    rec(:repeater_duplicate_subtab)
  end

  def repeater_toggle_hex : Nil
    rec(:repeater_toggle_hex)
  end

  def repeater_toggle_decoded : Nil
    rec(:repeater_toggle_decoded)
  end

  def repeater_toggle_sni : Nil
    rec(:repeater_toggle_sni)
  end

  def repeater_toggle_auto_content_length : Nil
    rec(:repeater_toggle_auto_content_length)
  end

  def repeater_toggle_http2 : Nil
    rec(:repeater_toggle_http2)
  end

  def repeater_toggle_resp_diff : Nil
    rec(:repeater_toggle_resp_diff)
  end

  def repeater_toggle_resp_hex : Nil
    rec(:repeater_toggle_resp_hex)
  end

  def repeater_pretty_request : Nil
    rec(:repeater_pretty_request)
  end

  def repeater_minimize : Nil
    rec(:repeater_minimize)
  end

  def fuzz_pretty_template : Nil
    rec(:fuzz_pretty_template)
  end

  def fuzz_toggle_http2 : Nil
    rec(:fuzz_toggle_http2)
  end

  def repeater_auto_mark : Nil
    rec(:repeater_auto_mark)
  end

  def repeater_mark_word : Nil
    rec(:repeater_mark_word)
  end

  def repeater_insert_marker : Nil
    rec(:repeater_insert_marker)
  end

  def repeater_clear_marks : Nil
    rec(:repeater_clear_marks)
  end

  def repeater_attach_chain : Nil
    rec(:repeater_attach_chain)
  end

  def repeater_copy : Nil
    rec(:repeater_copy)
  end

  def repeater_copy_all : Nil
    rec(:repeater_copy_all)
  end

  property repeater_read_mode : Bool = false # settable so grouped-menu specs can exercise the read-mode verbs

  def repeater_read_mode? : Bool
    @repeater_read_mode
  end

  def fuzz_selected : Nil
    rec(:fuzz_selected)
  end

  def fuzz_from_repeater : Nil
    rec(:fuzz_from_repeater)
  end

  def fuzz_run : Nil
    rec(:fuzz_run)
  end

  def fuzz_stop : Nil
    rec(:fuzz_stop)
  end

  def fuzz_new : Nil
    rec(:fuzz_new)
  end

  def fuzz_automark : Nil
    rec(:fuzz_automark)
  end

  def fuzz_attach_chain : Nil
    rec(:fuzz_attach_chain)
  end

  def fuzz_list_paste : Nil
    rec(:fuzz_list_paste)
  end

  def fuzz_clear_marks : Nil
    rec(:fuzz_clear_marks)
  end

  def fuzzer_rename_subtab : Nil
    rec(:fuzzer_rename_subtab)
  end

  def fuzzer_close_subtab : Nil
    rec(:fuzzer_close_subtab)
  end

  def fuzzer_duplicate_subtab : Nil
    rec(:fuzzer_duplicate_subtab)
  end

  def fuzzer_copy : Nil
    rec(:fuzzer_copy)
  end

  def fuzzer_copy_all : Nil
    rec(:fuzzer_copy_all)
  end

  # Settable so the read-mode-gated Fuzzer verbs can be exercised.
  property? fuzzer_read_mode : Bool = false

  def mine_selected : Nil
    rec(:mine_selected)
  end

  def mine_from_repeater : Nil
    rec(:mine_from_repeater)
  end

  def mine_run : Nil
    rec(:mine_run)
  end

  def mine_stop : Nil
    rec(:mine_stop)
  end

  def sequence_selected : Nil
    rec(:sequence_selected)
  end

  def sequence_from_repeater : Nil
    rec(:sequence_from_repeater)
  end

  def sequence_from_sitemap : Nil
    rec(:sequence_from_sitemap)
  end

  def sequence_run : Nil
    rec(:sequence_run)
  end

  def sequence_stop : Nil
    rec(:sequence_stop)
  end

  def sequence_configure : Nil
    rec(:sequence_configure)
  end

  def miner_duplicate_subtab : Nil
    rec(:miner_duplicate_subtab)
  end

  property? miner_has_issue = false

  def miner_finding_selected? : Bool
    @miner_has_issue
  end

  def mine_repeater_selected : Nil
    rec(:mine_repeater_selected)
  end

  def sitemap_move(delta : Int32) : Nil
    rec(:sitemap_move, delta)
  end

  def sitemap_toggle : Nil
    rec(:sitemap_toggle)
  end

  def sitemap_expand : Nil
    rec(:sitemap_expand)
  end

  def sitemap_collapse : Nil
    rec(:sitemap_collapse)
  end

  def sitemap_query : Nil
    rec(:sitemap_query)
  end

  def sitemap_tag : Nil
    rec(:sitemap_tag)
  end

  def sitemap_toggle_grouping : Nil
    rec(:sitemap_toggle_grouping)
  end

  def sitemap_discover : Nil
    rec(:sitemap_discover)
  end

  def sitemap_repeater : Nil
    rec(:sitemap_repeater)
  end

  def sitemap_mark_toggle : Nil
    rec(:sitemap_mark_toggle)
  end

  def sitemap_mark_clear : Nil
    rec(:sitemap_mark_clear)
  end

  def sitemap_mark_extend(delta : Int32) : Nil
    rec(:sitemap_mark_extend, delta)
  end

  # Settable so the availability sweep can exercise the marked-only entries (sitemap.mark-clear
  # renders only while a mark is set), the way `current_tab` is settable for the tab gates.
  property sitemap_marked_count : Int32 = 0

  def history_discover : Nil
    rec(:history_discover)
  end

  def discover_run : Nil
    rec(:discover_run)
  end

  def discover_stop : Nil
    rec(:discover_stop)
  end

  def discover_toggle_pause : Nil
    rec(:discover_toggle_pause)
  end

  def goto_discover : Nil
    rec(:goto_discover)
  end

  def oast_listen : Nil
    rec(:oast_listen)
  end

  def oast_stop : Nil
    rec(:oast_stop)
  end

  def oast_generate : Nil
    rec(:oast_generate)
  end

  def oast_copy : Nil
    rec(:oast_copy)
  end

  def oast_filter : Nil
    rec(:oast_filter)
  end

  def oast_add_provider : Nil
    rec(:oast_add_provider)
  end

  def oast_edit_provider : Nil
    rec(:oast_edit_provider)
  end

  def oast_toggle_provider : Nil
    rec(:oast_toggle_provider)
  end

  def oast_delete_provider : Nil
    rec(:oast_delete_provider)
  end

  # Settable so the listener-gated OAST insert verbs can be exercised.
  property? oast_payload_available : Bool = false

  def oast_insert_payload : Nil
    rec(:oast_insert_payload)
  end

  def oast_copy_payload : Nil
    rec(:oast_copy_payload)
  end

  def scope_open : Nil
    rec(:scope_open)
  end

  def scope_add_host : Nil
    rec(:scope_add_host)
  end

  def scope_toggle_lens : Nil
    rec(:scope_toggle_lens)
  end

  property scope_has_rule : Bool = false

  def scope_add_rule : Nil
    rec(:scope_add_rule)
  end

  def scope_edit_rule : Nil
    rec(:scope_edit_rule)
  end

  def scope_delete_rule : Nil
    rec(:scope_delete_rule)
  end

  def scope_rule_selected? : Bool
    @scope_has_rule
  end

  property probe_has_custom_rule : Bool = false

  def probe_rule_toggle : Nil
    rec(:probe_rule_toggle)
  end

  def probe_rule_add : Nil
    rec(:probe_rule_add)
  end

  def probe_rule_edit : Nil
    rec(:probe_rule_edit)
  end

  def probe_rule_delete : Nil
    rec(:probe_rule_delete)
  end

  def probe_custom_rule_selected? : Bool
    @probe_has_custom_rule
  end

  property hostov_has_entry : Bool = false

  def hostov_add_entry : Nil
    rec(:hostov_add_entry)
  end

  def hostov_edit_entry : Nil
    rec(:hostov_edit_entry)
  end

  def hostov_delete_entry : Nil
    rec(:hostov_delete_entry)
  end

  def hostov_entry_selected? : Bool
    @hostov_has_entry
  end

  property env_has_var : Bool = false

  def env_add_var : Nil
    rec(:env_add_var)
  end

  def env_edit_var : Nil
    rec(:env_edit_var)
  end

  def env_delete_var : Nil
    rec(:env_delete_var)
  end

  def env_edit_prefix : Nil
    rec(:env_edit_prefix)
  end

  def env_var_selected? : Bool
    @env_has_var
  end

  def issue_create : Nil
    rec(:issue_create)
  end

  def issues_new : Nil
    rec(:issues_new)
  end

  def issues_query : Nil
    rec(:issues_query)
  end

  def issues_move(delta : Int32) : Nil
    rec(:issues_move, delta)
  end

  def issues_open : Nil
    rec(:issues_open)
  end

  def issue_close : Nil
    rec(:issue_close)
  end

  def issues_delete : Nil
    rec(:issues_delete)
  end

  # Issues multi-select, mirroring the History pair above: `issue_marks` is settable state
  # (the query half) and `selected_issue` the cursor row, with the effective target set
  # derived exactly as the Runner's is — marks if any, else the cursor. Both default to empty
  # so every `available?` lambda is safe on a bare FakeExecContext.
  property issue_marks = [] of Int64
  property selected_issue = nil.as(Int64?)

  def selected_issue_ids : Array(Int64)
    return issue_marks unless issue_marks.empty?
    [@selected_issue].compact
  end

  def selected_issue_id : Int64?
    @selected_issue
  end

  def marked_issue_count : Int32
    issue_marks.size
  end

  def issues_mark_toggle : Nil
    rec(:issues_mark_toggle)
  end

  def issues_mark_all : Nil
    rec(:issues_mark_all)
  end

  def issues_mark_clear : Nil
    rec(:issues_mark_clear)
  end

  def issues_mark_extend(delta : Int32) : Nil
    rec(:issues_mark_extend, delta)
  end

  def issue_severity(delta : Int32) : Nil
    rec(:issue_severity, delta)
  end

  def issue_status(delta : Int32) : Nil
    rec(:issue_status, delta)
  end

  def issue_set_severity : Nil
    rec(:issue_set_severity)
  end

  def issue_set_status : Nil
    rec(:issue_set_status)
  end

  def issue_edit_notes : Nil
    rec(:issue_edit_notes)
  end

  def issue_hscroll(delta : Int32) : Nil
    rec(:issue_hscroll, delta)
  end

  def issue_edit_title : Nil
    rec(:issue_edit_title)
  end

  def issue_open_flow : Nil
    rec(:issue_open_flow)
  end

  def issue_repeater_flow : Nil
    rec(:issue_repeater_flow)
  end

  def issues_export(format : Symbol) : Nil
    rec(:issues_export, format)
  end

  def probe_move(delta : Int32) : Nil
    rec(:probe_move, delta)
  end

  def probe_open : Nil
    rec(:probe_open)
  end

  def probe_close : Nil
    rec(:probe_close)
  end

  def probe_query : Nil
    rec(:probe_query)
  end

  def probe_set_mode : Nil
    rec(:probe_set_mode)
  end

  def probe_clear : Nil
    rec(:probe_clear)
  end

  def probe_delete : Nil
    rec(:probe_delete)
  end

  def probe_dismiss : Nil
    rec(:probe_dismiss)
  end

  def probe_toggle_closed : Nil
    rec(:probe_toggle_closed)
  end

  def probe_dismiss_code : Nil
    rec(:probe_dismiss_code)
  end

  def probe_dismiss_host : Nil
    rec(:probe_dismiss_host)
  end

  def probe_open_flow : Nil
    rec(:probe_open_flow)
  end

  def probe_repeater_flow : Nil
    rec(:probe_repeater_flow)
  end

  def probe_promote : Nil
    rec(:probe_promote)
  end

  def probe_active_selected : Nil
    rec(:probe_active_selected)
  end

  def probe_active_rescan : Nil
    rec(:probe_active_rescan)
  end

  def probe_active_from_repeater : Nil
    rec(:probe_active_from_repeater)
  end

  def toggle_capture : Nil
    rec(:toggle_capture)
  end

  def intercept_toggle : Nil
    rec(:intercept_toggle)
  end

  def intercept_forward : Nil
    rec(:intercept_forward)
  end

  def intercept_drop : Nil
    rec(:intercept_drop)
  end

  def intercept_forward_all : Nil
    rec(:intercept_forward_all)
  end

  def intercept_query : Nil
    rec(:intercept_query)
  end

  def intercept_cycle_direction : Nil
    rec(:intercept_cycle_direction)
  end

  property intercept_selected : Int64? = nil # settable so the held-message-gated verbs can be exercised

  def selected_intercept_id : Int64?
    @intercept_selected
  end

  def intercept_mark_toggle : Nil
    rec(:intercept_mark_toggle)
  end

  def intercept_mark_all : Nil
    rec(:intercept_mark_all)
  end

  def intercept_mark_clear : Nil
    rec(:intercept_mark_clear)
  end

  def intercept_mark_extend(delta : Int32) : Nil
    rec(:intercept_mark_extend, delta)
  end

  property marked_intercept : Int32 = 0 # settable so the mark-gated verbs can be exercised

  def marked_intercept_count : Int32
    @marked_intercept
  end

  def export_ca : Nil
    rec(:export_ca)
  end

  def regenerate_ca : Nil
    rec(:regenerate_ca)
  end

  def import_ca : Nil
    rec(:import_ca)
  end

  def open_browser_picker : Nil
    rec(:open_browser_picker)
  end

  def comparer_pick(slot : Symbol) : Nil
    rec(:comparer_pick, slot)
  end

  def comparer_swap : Nil
    rec(:comparer_swap)
  end

  def comparer_toggle_pane : Nil
    rec(:comparer_toggle_pane)
  end

  def comparer_add_selected : Nil
    rec(:comparer_add_selected)
  end

  def comparer_new : Nil
    rec(:comparer_new)
  end

  def comparer_close_subtab : Nil
    rec(:comparer_close_subtab)
  end

  def comparer_rename_subtab : Nil
    rec(:comparer_rename_subtab)
  end

  def comparer_duplicate_subtab : Nil
    rec(:comparer_duplicate_subtab)
  end

  def decoder_new : Nil
    rec(:decoder_new)
  end

  def decoder_close : Nil
    rec(:decoder_close)
  end

  def decoder_rename_subtab : Nil
    rec(:decoder_rename_subtab)
  end

  def decoder_duplicate_subtab : Nil
    rec(:decoder_duplicate_subtab)
  end

  def decoder_clear : Nil
    rec(:decoder_clear)
  end

  def decoder_copy : Nil
    rec(:decoder_copy)
  end

  def decoder_copy_selection : Nil
    rec(:decoder_copy_selection)
  end

  def decoder_copy_all : Nil
    rec(:decoder_copy_all)
  end

  property decoder_read_mode : Bool = false # settable so grouped-menu specs can exercise COMMON's Copy

  def decoder_read_mode? : Bool
    @decoder_read_mode
  end

  def decoder_cycle_mode : Nil
    rec(:decoder_cycle_mode)
  end

  def decoder_save : Nil
    rec(:decoder_save)
  end

  def decoder_load : Nil
    rec(:decoder_load)
  end

  def jwt_new : Nil
    rec(:jwt_new)
  end

  def jwt_close : Nil
    rec(:jwt_close)
  end

  def jwt_rename_subtab : Nil
    rec(:jwt_rename_subtab)
  end

  def jwt_duplicate_subtab : Nil
    rec(:jwt_duplicate_subtab)
  end

  def jwt_clear : Nil
    rec(:jwt_clear)
  end

  def jwt_toggle_mode : Nil
    rec(:jwt_toggle_mode)
  end

  def jwt_cycle_alg : Nil
    rec(:jwt_cycle_alg)
  end

  def jwt_load_decoded : Nil
    rec(:jwt_load_decoded)
  end

  def jwt_copy : Nil
    rec(:jwt_copy)
  end

  def jwt_copy_all : Nil
    rec(:jwt_copy_all)
  end

  def jwt_copy_token : Nil
    rec(:jwt_copy_token)
  end

  def jwt_copy_attack : Nil
    rec(:jwt_copy_attack)
  end

  property jwt_read_mode : Bool = false # settable so grouped-menu specs can exercise COMMON's Copy

  def jwt_read_mode? : Bool
    @jwt_read_mode
  end

  property rewriter_rule_selected : Bool = false # settable so the has-rule gate can be exercised

  def rewriter_add : Nil
    rec(:rewriter_add)
  end

  def rewriter_edit : Nil
    rec(:rewriter_edit)
  end

  def rewriter_toggle : Nil
    rec(:rewriter_toggle)
  end

  def rewriter_delete : Nil
    rec(:rewriter_delete)
  end

  def rewriter_move(dir : Int32) : Nil
    rec(:rewriter_move, dir)
  end

  def rewriter_duplicate : Nil
    rec(:rewriter_duplicate)
  end

  def rewriter_reload : Nil
    rec(:rewriter_reload)
  end

  def rewriter_rule_selected? : Bool
    @rewriter_rule_selected
  end

  def notes_new : Nil
    rec(:notes_new)
  end

  def notes_close : Nil
    rec(:notes_close)
  end

  def notes_duplicate_subtab : Nil
    rec(:notes_duplicate_subtab)
  end

  def notes_copy : Nil
    rec(:notes_copy)
  end

  def notes_copy_all : Nil
    rec(:notes_copy_all)
  end

  # Settable; defaults ON — the Notes body opens in read mode.
  property? notes_read_mode : Bool = true

  def notes_clear : Nil
    rec(:notes_clear)
  end

  def notes_export : Nil
    rec(:notes_export)
  end

  def notes_edit : Nil
    rec(:notes_edit)
  end

  def notes_goto : Nil
    rec(:notes_goto)
  end

  def notes_find : Nil
    rec(:notes_find)
  end

  def notes_links : Nil
    rec(:notes_links)
  end

  # Settable so project.copy / project.select-line can be exercised.
  property? project_desc_read_mode : Bool = false

  def project_copy : Nil
    rec(:project_copy)
  end

  def project_copy_all : Nil
    rec(:project_copy_all)
  end

  property selection_active : Bool = false # settable so selection-gated verbs (send-to, clear-selection) can be exercised

  def read_selection_active? : Bool
    selection_active
  end

  def read_select_line : Nil
    rec(:read_select_line)
  end

  def read_clear_selection : Nil
    rec(:read_clear_selection)
  end

  def read_copy : Nil
    rec(:read_copy)
  end

  def copy_as_open : Nil
    rec(:copy_as_open)
  end

  getter send_to_opened : Bool = false

  def send_to_open : Nil
    @send_to_opened = true
    rec(:send_to_open)
  end

  property detail_navigable : Bool = false # settable so grouped-menu specs can exercise detail.select-line

  def detail_navigable? : Bool
    @detail_navigable
  end

  def space_menu_title(verb_id : String) : String?
    nil
  end

  def issue_links : Nil
    rec(:issue_links)
  end

  def issue_open_link : Nil
    rec(:issue_open_link)
  end

  def issue_link_move(delta : Int32) : Nil
    rec(:issue_link_move, delta)
  end

  # Settable so the issue-notes read verbs can be exercised.
  property? issues_notes_read_mode : Bool = false

  def issues_copy : Nil
    rec(:issues_copy)
  end

  def issues_copy_all : Nil
    rec(:issues_copy_all)
  end

  def link_to_issue : Nil
    rec(:link_to_issue)
  end

  def link_to_note : Nil
    rec(:link_to_note)
  end

  # The four linkable-entity ids, settable so both sides of the link.* gates can be
  # exercised (a verb is offered only once the entity has a persisted row to point at).
  property link_flow : Int64? = nil
  property link_repeater : Int64? = nil
  property link_fuzz : Int64? = nil
  property link_miner : Int64? = nil

  def link_flow_id : Int64?
    @link_flow
  end

  def link_repeater_id : Int64?
    @link_repeater
  end

  def link_fuzz_id : Int64?
    @link_fuzz
  end

  def link_miner_id : Int64?
    @link_miner
  end

  def open_settings(section : Symbol) : Nil
    rec(:open_settings, section)
  end

  def open_preferences : Nil
    rec(:open_preferences)
  end

  def import_har : Nil
    rec(:import_har)
  end

  def import_urls : Nil
    rec(:import_urls)
  end

  def import_oas : Nil
    rec(:import_oas)
  end

  def import_postman : Nil
    rec(:import_postman)
  end

  def import_insomnia : Nil
    rec(:import_insomnia)
  end

  def import_burp : Nil
    rec(:import_burp)
  end
end

# Fire one verb on a fresh recording context and return the intents it dispatched, IN
# ORDER — the shape every spec/verbs/*_spec.cr asserts on. Lives here rather than being
# re-declared per file so a change to it (say, also asserting arguments) is one edit.
def verb_intents(registry : Gori::Verb::Registry, id : String,
                 ctx = FakeExecContext.new) : Array(Symbol)
  registry[id].call(ctx)
  ctx.call_names
end
