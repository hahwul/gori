require "../../src/gori"

# A no-op ExecContext for exercising registry/palette logic in specs.
class FakeExecContext < Gori::Verb::ExecContext
  property selected : Int64? = nil
  property current_tab : Symbol = :history # settable so tab-gated verbs (Decoder, …) can be exercised

  def quit! : Nil; end

  def leave_project : Nil; end

  def status(message : String) : Nil; end

  def open_palette : Nil; end

  def open_notifications : Nil; end

  def close_overlay : Nil; end

  def refresh_screen : Nil; end

  def focus_pane(pane : Symbol) : Nil; end

  def enter_content : Nil; end

  def focus_tab(tab : Symbol) : Nil; end

  def focus_visible_tab(n : Int32) : Nil; end

  def cycle_tab(delta : Int32) : Nil; end

  def menu_left : Nil; end

  def menu_right : Nil; end

  def move_selection(delta : Int32) : Nil; end

  def open_detail : Nil; end

  def close_detail : Nil; end

  def toggle_follow : Nil; end

  def selected_flow_id : Int64?
    @selected
  end

  def copy_selection : Nil; end

  def history_query : Nil; end

  def history_delete : Nil; end

  def history_clear : Nil; end

  def scroll_detail(delta : Int32) : Nil; end

  def detail_copy_selection : Nil; end

  def hscroll_detail(delta : Int32) : Nil; end

  def toggle_detail_pane : Nil; end

  def move_detail_pane(dir : Int32) : Nil; end

  def toggle_detail_hex : Nil; end

  def toggle_reveal : Nil; end

  def toggle_pretty : Nil; end

  def repeater_selected : Nil; end

  def repeater_new : Nil; end

  def repeater_send : Nil; end

  def repeater_send_group : Nil; end

  def repeater_find_subtab : Nil; end

  property repeater_tab_count : Int32 = 0

  def repeater_subtab_count : Int32
    @repeater_tab_count
  end

  def subtab_search_open : Nil; end

  def subtab_filter_open : Nil; end

  property subtab_search_tab_count : Int32 = 0

  def subtab_search_count : Int32
    @subtab_search_tab_count
  end

  def repeater_rename_subtab : Nil; end

  def repeater_tag_subtab : Nil; end

  def repeater_filter_subtabs : Nil; end

  def repeater_close_subtab : Nil; end

  def repeater_duplicate_subtab : Nil; end

  def repeater_toggle_hex : Nil; end

  def repeater_toggle_decoded : Nil; end

  def repeater_toggle_sni : Nil; end

  def repeater_toggle_auto_content_length : Nil; end

  def repeater_toggle_http2 : Nil; end

  def repeater_toggle_resp_diff : Nil; end

  def repeater_toggle_resp_hex : Nil; end

  def repeater_pretty_request : Nil; end

  def repeater_minimize : Nil; end

  def fuzz_pretty_template : Nil; end

  def fuzz_toggle_http2 : Nil; end

  def repeater_auto_mark : Nil; end

  def repeater_mark_word : Nil; end

  def repeater_insert_marker : Nil; end

  def repeater_clear_marks : Nil; end

  def repeater_attach_chain : Nil; end

  def repeater_copy : Nil; end

  def repeater_copy_all : Nil; end

  property repeater_read_mode : Bool = false # settable so grouped-menu specs can exercise the read-mode verbs

  def repeater_read_mode? : Bool
    @repeater_read_mode
  end

  def fuzz_selected : Nil; end

  def fuzz_from_repeater : Nil; end

  def fuzz_run : Nil; end

  def fuzz_stop : Nil; end

  def fuzz_new : Nil; end

  def fuzz_automark : Nil; end

  def fuzz_attach_chain : Nil; end

  def fuzz_list_paste : Nil; end

  def fuzz_clear_marks : Nil; end

  def fuzzer_rename_subtab : Nil; end

  def fuzzer_close_subtab : Nil; end

  def fuzzer_duplicate_subtab : Nil; end

  def fuzzer_copy : Nil; end

  def fuzzer_copy_all : Nil; end

  def fuzzer_read_mode? : Bool
    false
  end

  def mine_selected : Nil; end

  def mine_from_repeater : Nil; end

  def mine_run : Nil; end

  def mine_stop : Nil; end

  def miner_duplicate_subtab : Nil; end

  property? miner_has_issue = false

  def miner_finding_selected? : Bool
    @miner_has_issue
  end

  def mine_repeater_selected : Nil; end

  def sitemap_move(delta : Int32) : Nil; end

  def sitemap_toggle : Nil; end

  def sitemap_expand : Nil; end

  def sitemap_collapse : Nil; end

  def sitemap_query : Nil; end

  def sitemap_tag : Nil; end

  def sitemap_toggle_grouping : Nil; end

  def sitemap_discover : Nil; end

  def sitemap_repeater : Nil; end

  def history_discover : Nil; end

  def discover_run : Nil; end

  def discover_stop : Nil; end

  def discover_toggle_pause : Nil; end

  def goto_discover : Nil; end

  def scope_open : Nil; end

  def scope_add_host : Nil; end

  def scope_toggle_lens : Nil; end

  property scope_has_rule : Bool = false

  def scope_add_rule : Nil; end

  def scope_edit_rule : Nil; end

  def scope_delete_rule : Nil; end

  def scope_rule_selected? : Bool
    @scope_has_rule
  end

  property probe_has_custom_rule : Bool = false

  def probe_rule_toggle : Nil; end

  def probe_rule_add : Nil; end

  def probe_rule_edit : Nil; end

  def probe_rule_delete : Nil; end

  def probe_custom_rule_selected? : Bool
    @probe_has_custom_rule
  end

  property hostov_has_entry : Bool = false

  def hostov_add_entry : Nil; end

  def hostov_edit_entry : Nil; end

  def hostov_delete_entry : Nil; end

  def hostov_entry_selected? : Bool
    @hostov_has_entry
  end

  property env_has_var : Bool = false

  def env_add_var : Nil; end

  def env_edit_var : Nil; end

  def env_delete_var : Nil; end

  def env_edit_prefix : Nil; end

  def env_var_selected? : Bool
    @env_has_var
  end

  def rules_open : Nil; end

  def issue_create : Nil; end

  def issues_new : Nil; end

  def issues_query : Nil; end

  def issues_move(delta : Int32) : Nil; end

  def issues_open : Nil; end

  def issue_close : Nil; end

  def issues_delete : Nil; end

  def issue_severity(delta : Int32) : Nil; end

  def issue_status(delta : Int32) : Nil; end

  def issue_set_severity : Nil; end

  def issue_set_status : Nil; end

  def issue_edit_notes : Nil; end

  def issue_hscroll(delta : Int32) : Nil; end

  def issue_edit_title : Nil; end

  def issue_open_flow : Nil; end

  def issue_repeater_flow : Nil; end

  def issues_export(format : Symbol) : Nil; end

  def probe_move(delta : Int32) : Nil; end

  def probe_open : Nil; end

  def probe_close : Nil; end

  def probe_query : Nil; end

  def probe_set_mode : Nil; end

  def probe_clear : Nil; end

  def probe_delete : Nil; end

  def probe_dismiss : Nil; end

  def probe_toggle_closed : Nil; end

  def probe_dismiss_code : Nil; end

  def probe_dismiss_host : Nil; end

  def probe_open_flow : Nil; end

  def probe_repeater_flow : Nil; end

  def probe_promote : Nil; end

  def probe_active_selected : Nil; end

  def probe_active_rescan : Nil; end

  def probe_active_from_repeater : Nil; end

  def toggle_capture : Nil; end

  def intercept_toggle : Nil; end

  def intercept_forward : Nil; end

  def intercept_drop : Nil; end

  def intercept_forward_all : Nil; end

  def intercept_query : Nil; end

  def intercept_cycle_direction : Nil; end

  def selected_intercept_id : Int64?
    nil
  end

  def export_ca : Nil; end

  def regenerate_ca : Nil; end

  def import_ca : Nil; end

  def open_browser_picker : Nil; end

  def comparer_pick(slot : Symbol) : Nil; end

  def comparer_swap : Nil; end

  def comparer_toggle_pane : Nil; end

  def comparer_add_selected : Nil; end

  def comparer_new : Nil; end

  def comparer_close_subtab : Nil; end

  def comparer_rename_subtab : Nil; end

  def comparer_duplicate_subtab : Nil; end

  def decoder_new : Nil; end

  def decoder_close : Nil; end

  def decoder_rename_subtab : Nil; end

  def decoder_duplicate_subtab : Nil; end

  def decoder_clear : Nil; end

  def decoder_copy : Nil; end

  def decoder_copy_selection : Nil; end

  def decoder_copy_all : Nil; end

  property decoder_read_mode : Bool = false # settable so grouped-menu specs can exercise COMMON's Copy

  def decoder_read_mode? : Bool
    @decoder_read_mode
  end

  def decoder_cycle_mode : Nil; end

  def decoder_save : Nil; end

  def decoder_load : Nil; end

  def jwt_new : Nil; end

  def jwt_close : Nil; end

  def jwt_rename_subtab : Nil; end

  def jwt_duplicate_subtab : Nil; end

  def jwt_clear : Nil; end

  def jwt_toggle_mode : Nil; end

  def jwt_cycle_alg : Nil; end

  def jwt_load_decoded : Nil; end

  def jwt_copy : Nil; end

  def jwt_copy_all : Nil; end

  def jwt_copy_token : Nil; end

  def jwt_copy_attack : Nil; end

  property jwt_read_mode : Bool = false # settable so grouped-menu specs can exercise COMMON's Copy

  def jwt_read_mode? : Bool
    @jwt_read_mode
  end

  def notes_new : Nil; end

  def notes_close : Nil; end

  def notes_duplicate_subtab : Nil; end

  def notes_copy : Nil; end

  def notes_copy_all : Nil; end

  def notes_read_mode? : Bool
    true
  end

  def notes_clear : Nil; end

  def notes_edit : Nil; end

  def notes_goto : Nil; end

  def notes_find : Nil; end

  def notes_links : Nil; end

  def project_desc_read_mode? : Bool
    false
  end

  def project_copy : Nil; end

  def project_copy_all : Nil; end

  property selection_active : Bool = false # settable so selection-gated verbs (send-to, clear-selection) can be exercised

  def read_selection_active? : Bool
    selection_active
  end

  def read_select_line : Nil; end

  def read_clear_selection : Nil; end

  def read_copy : Nil; end

  def copy_as_open : Nil; end

  getter send_to_opened : Bool = false

  def send_to_open : Nil
    @send_to_opened = true
  end

  property detail_navigable : Bool = false # settable so grouped-menu specs can exercise detail.select-line

  def detail_navigable? : Bool
    @detail_navigable
  end

  def space_menu_title(verb_id : String) : String?
    nil
  end

  def issue_links : Nil; end

  def issue_open_link : Nil; end

  def issue_link_move(delta : Int32) : Nil; end

  def issues_notes_read_mode? : Bool
    false
  end

  def issues_copy : Nil; end

  def issues_copy_all : Nil; end

  def link_to_issue : Nil; end

  def link_to_note : Nil; end

  def link_flow_id : Int64?
    nil
  end

  def link_repeater_id : Int64?
    nil
  end

  def link_fuzz_id : Int64?
    nil
  end

  def link_miner_id : Int64?
    nil
  end

  def open_settings(section : Symbol) : Nil; end

  def import_har : Nil; end

  def import_urls : Nil; end

  def import_oas : Nil; end
end
