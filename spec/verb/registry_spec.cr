require "../spec_helper"

include Gori::Verb

# Minimal recording ExecContext for exercising handlers.
private class FakeContext < ExecContext
  property selected : Int64? = nil
  property tab : Symbol = :history
  getter calls = [] of Symbol

  def quit! : Nil
    @calls << :quit
  end

  def leave_project : Nil
    @calls << :leave_project
  end

  def current_tab : Symbol
    @tab
  end

  def focus_pane(pane : Symbol) : Nil
    @calls << :focus_pane
  end

  def enter_content : Nil
    @calls << :enter_content
  end

  def status(message : String) : Nil
    @calls << :status
  end

  def open_palette : Nil
    @calls << :open_palette
  end

  def open_notifications : Nil
    @calls << :open_notifications
  end

  def close_overlay : Nil
    @calls << :close_overlay
  end

  def refresh_screen : Nil
    @calls << :refresh_screen
  end

  def focus_tab(tab : Symbol) : Nil
    @calls << tab
  end

  def focus_visible_tab(n : Int32) : Nil
    @calls << :focus_visible_tab
  end

  def cycle_tab(delta : Int32) : Nil
    @calls << :cycle_tab
  end

  def menu_left : Nil
    @calls << :menu_left
  end

  def menu_right : Nil
    @calls << :menu_right
  end

  def move_selection(delta : Int32) : Nil
    @calls << :move
  end

  def open_detail : Nil
    @calls << :open_detail
  end

  def close_detail : Nil
    @calls << :close_detail
  end

  def toggle_follow : Nil
    @calls << :toggle_follow
  end

  def selected_flow_id : Int64?
    @selected
  end

  def copy_selection : Nil
    @calls << :copy
  end

  def history_query : Nil
    @calls << :history_query
  end

  def scroll_detail(delta : Int32) : Nil
    @calls << :scroll_detail
  end

  def detail_copy_selection : Nil
    @calls << :detail_copy_selection
  end

  def hscroll_detail(delta : Int32) : Nil
    @calls << :hscroll_detail
  end

  def toggle_detail_pane : Nil
    @calls << :toggle_detail_pane
  end

  def move_detail_pane(dir : Int32) : Nil
    @calls << :move_detail_pane
  end

  def toggle_detail_hex : Nil
    @calls << :toggle_detail_hex
  end

  def toggle_reveal : Nil
    @calls << :toggle_reveal
  end

  def toggle_pretty : Nil
    @calls << :toggle_pretty
  end

  def repeater_selected : Nil
    @calls << :repeater_selected
  end

  def repeater_new : Nil
    @calls << :repeater_new
  end

  def repeater_send : Nil
    @calls << :repeater_send
  end

  def repeater_send_group : Nil
    @calls << :repeater_send_group
  end

  def repeater_find_subtab : Nil
    @calls << :repeater_find_subtab
  end

  def repeater_subtab_count : Int32
    0
  end

  def subtab_search_open : Nil
    @calls << :subtab_search_open
  end

  def subtab_filter_open : Nil
    @calls << :subtab_filter_open
  end

  def subtab_search_count : Int32
    0
  end

  def repeater_rename_subtab : Nil
    @calls << :repeater_rename_subtab
  end

  def repeater_tag_subtab : Nil
    @calls << :repeater_tag_subtab
  end

  def repeater_filter_subtabs : Nil
    @calls << :repeater_filter_subtabs
  end

  def repeater_close_subtab : Nil
    @calls << :repeater_close_subtab
  end

  def repeater_duplicate_subtab : Nil
    @calls << :repeater_duplicate_subtab
  end

  def repeater_toggle_hex : Nil
    @calls << :repeater_toggle_hex
  end

  def repeater_toggle_decoded : Nil
    @calls << :repeater_toggle_decoded
  end

  def repeater_toggle_sni : Nil
    @calls << :repeater_toggle_sni
  end

  def repeater_toggle_auto_content_length : Nil
    @calls << :repeater_toggle_auto_content_length
  end

  def repeater_toggle_http2 : Nil
    @calls << :repeater_toggle_http2
  end

  def repeater_toggle_resp_diff : Nil
    @calls << :repeater_toggle_resp_diff
  end

  def repeater_toggle_resp_hex : Nil
    @calls << :repeater_toggle_resp_hex
  end

  def repeater_pretty_request : Nil
    @calls << :repeater_pretty_request
  end

  def repeater_auto_mark : Nil
    @calls << :repeater_auto_mark
  end

  def repeater_mark_word : Nil
    @calls << :repeater_mark_word
  end

  def repeater_insert_marker : Nil
    @calls << :repeater_insert_marker
  end

  def repeater_clear_marks : Nil
    @calls << :repeater_clear_marks
  end

  def repeater_attach_chain : Nil
    @calls << :repeater_attach_chain
  end

  def repeater_copy : Nil
    @calls << :repeater_copy
  end

  def repeater_copy_all : Nil
    @calls << :repeater_copy_all
  end

  def repeater_read_mode? : Bool
    false
  end

  def fuzz_selected : Nil
    @calls << :fuzz_selected
  end

  def fuzz_from_repeater : Nil
    @calls << :fuzz_from_repeater
  end

  def fuzz_run : Nil
    @calls << :fuzz_run
  end

  def fuzz_stop : Nil
    @calls << :fuzz_stop
  end

  def fuzz_new : Nil
    @calls << :fuzz_new
  end

  def fuzz_automark : Nil
    @calls << :fuzz_automark
  end

  def fuzz_attach_chain : Nil
    @calls << :fuzz_attach_chain
  end

  def fuzz_list_paste : Nil
    @calls << :fuzz_list_paste
  end

  def fuzz_pretty_template : Nil
    @calls << :fuzz_pretty_template
  end

  def fuzz_toggle_http2 : Nil
    @calls << :fuzz_toggle_http2
  end

  def fuzz_clear_marks : Nil
    @calls << :fuzz_clear_marks
  end

  def fuzzer_rename_subtab : Nil
    @calls << :fuzzer_rename_subtab
  end

  def fuzzer_close_subtab : Nil
    @calls << :fuzzer_close_subtab
  end

  def fuzzer_duplicate_subtab : Nil
    @calls << :fuzzer_duplicate_subtab
  end

  def fuzzer_copy : Nil
    @calls << :fuzzer_copy
  end

  def fuzzer_copy_all : Nil
    @calls << :fuzzer_copy_all
  end

  def fuzzer_read_mode? : Bool
    false
  end

  def mine_selected : Nil
    @calls << :mine_selected
  end

  def mine_from_repeater : Nil
    @calls << :mine_from_repeater
  end

  def mine_run : Nil
    @calls << :mine_run
  end

  def mine_stop : Nil
    @calls << :mine_stop
  end

  def miner_duplicate_subtab : Nil
    @calls << :miner_duplicate_subtab
  end

  def miner_finding_selected? : Bool
    false
  end

  def mine_repeater_selected : Nil
    @calls << :mine_repeater_selected
  end

  def sitemap_move(delta : Int32) : Nil
    @calls << :sitemap_move
  end

  def sitemap_toggle : Nil
    @calls << :sitemap_toggle
  end

  def sitemap_expand : Nil
    @calls << :sitemap_expand
  end

  def sitemap_collapse : Nil
    @calls << :sitemap_collapse
  end

  def sitemap_query : Nil
    @calls << :sitemap_query
  end

  def sitemap_tag : Nil
    @calls << :sitemap_tag
  end

  def sitemap_toggle_grouping : Nil
    @calls << :sitemap_toggle_grouping
  end

  def sitemap_discover : Nil
    @calls << :sitemap_discover
  end

  def sitemap_repeater : Nil
    @calls << :sitemap_repeater
  end

  def history_discover : Nil
    @calls << :history_discover
  end

  def discover_run : Nil
    @calls << :discover_run
  end

  def discover_stop : Nil
    @calls << :discover_stop
  end

  def discover_toggle_pause : Nil
    @calls << :discover_toggle_pause
  end

  def goto_discover : Nil
    @calls << :goto_discover
  end

  def scope_open : Nil
    @calls << :scope_open
  end

  def scope_add_host : Nil
    @calls << :scope_add_host
  end

  def scope_toggle_lens : Nil
    @calls << :scope_toggle_lens
  end

  def scope_add_rule : Nil
    @calls << :scope_add_rule
  end

  def scope_edit_rule : Nil
    @calls << :scope_edit_rule
  end

  def scope_delete_rule : Nil
    @calls << :scope_delete_rule
  end

  def scope_rule_selected? : Bool
    true
  end

  def probe_rule_toggle : Nil
    @calls << :probe_rule_toggle
  end

  def probe_rule_add : Nil
    @calls << :probe_rule_add
  end

  def probe_rule_edit : Nil
    @calls << :probe_rule_edit
  end

  def probe_rule_delete : Nil
    @calls << :probe_rule_delete
  end

  def probe_custom_rule_selected? : Bool
    true
  end

  def hostov_add_entry : Nil
    @calls << :hostov_add_entry
  end

  def hostov_edit_entry : Nil
    @calls << :hostov_edit_entry
  end

  def hostov_delete_entry : Nil
    @calls << :hostov_delete_entry
  end

  def hostov_entry_selected? : Bool
    true
  end

  def env_add_var : Nil
    @calls << :env_add_var
  end

  def env_edit_var : Nil
    @calls << :env_edit_var
  end

  def env_delete_var : Nil
    @calls << :env_delete_var
  end

  def env_edit_prefix : Nil
    @calls << :env_edit_prefix
  end

  def env_var_selected? : Bool
    true
  end

  def rules_open : Nil
    @calls << :rules_open
  end

  def issue_create : Nil
    @calls << :issue_create
  end

  def issues_new : Nil
    @calls << :issues_new
  end

  def issues_query : Nil
    @calls << :issues_query
  end

  def issues_move(delta : Int32) : Nil
    @calls << :issues_move
  end

  def issues_open : Nil
    @calls << :issues_open
  end

  def issue_close : Nil
    @calls << :issue_close
  end

  def issues_delete : Nil
    @calls << :issues_delete
  end

  def issue_severity(delta : Int32) : Nil
    @calls << :issue_severity
  end

  def issue_status(delta : Int32) : Nil
    @calls << :issue_status
  end

  def issue_set_severity : Nil
    @calls << :issue_set_severity
  end

  def issue_set_status : Nil
    @calls << :issue_set_status
  end

  def issue_edit_notes : Nil
    @calls << :issue_edit_notes
  end

  def issue_hscroll(delta : Int32) : Nil
    @calls << :issue_hscroll
  end

  def issue_edit_title : Nil
    @calls << :issue_edit_title
  end

  def issue_open_flow : Nil
    @calls << :issue_open_flow
  end

  def issue_repeater_flow : Nil
    @calls << :issue_repeater_flow
  end

  def issue_links : Nil
    @calls << :issue_links
  end

  def issue_open_link : Nil
    @calls << :issue_open_link
  end

  def issue_link_move(delta : Int32) : Nil
    @calls << :issue_link_move
  end

  def issues_notes_read_mode? : Bool
    false
  end

  def issues_copy : Nil
    @calls << :issues_copy
  end

  def issues_copy_all : Nil
    @calls << :issues_copy_all
  end

  def link_to_issue : Nil
    @calls << :link_to_issue
  end

  def link_to_note : Nil
    @calls << :link_to_note
  end

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

  def issues_export(format : Symbol) : Nil
    @calls << :issues_export
  end

  def probe_move(delta : Int32) : Nil
    @calls << :probe_move
  end

  def probe_open : Nil
    @calls << :probe_open
  end

  def probe_close : Nil
    @calls << :probe_close
  end

  def probe_query : Nil
    @calls << :probe_query
  end

  def probe_set_mode : Nil
    @calls << :probe_set_mode
  end

  def probe_clear : Nil
    @calls << :probe_clear
  end

  def probe_delete : Nil
    @calls << :probe_delete
  end

  def probe_dismiss : Nil
    @calls << :probe_dismiss
  end

  def probe_toggle_closed : Nil
    @calls << :probe_toggle_closed
  end

  def probe_dismiss_code : Nil
    @calls << :probe_dismiss_code
  end

  def probe_dismiss_host : Nil
    @calls << :probe_dismiss_host
  end

  def probe_open_flow : Nil
    @calls << :probe_open_flow
  end

  def probe_repeater_flow : Nil
    @calls << :probe_repeater_flow
  end

  def probe_promote : Nil
    @calls << :probe_promote
  end

  def probe_active_selected : Nil
    @calls << :probe_active_selected
  end

  def probe_active_rescan : Nil
    @calls << :probe_active_rescan
  end

  def probe_active_from_repeater : Nil
    @calls << :probe_active_from_repeater
  end

  def toggle_capture : Nil
    @calls << :toggle_capture
  end

  def intercept_toggle : Nil
    @calls << :intercept_toggle
  end

  def intercept_forward : Nil
    @calls << :intercept_forward
  end

  def intercept_drop : Nil
    @calls << :intercept_drop
  end

  def intercept_forward_all : Nil
    @calls << :intercept_forward_all
  end

  def intercept_query : Nil
    @calls << :intercept_query
  end

  def intercept_cycle_direction : Nil
    @calls << :intercept_cycle_direction
  end

  def selected_intercept_id : Int64?
    @selected
  end

  def export_ca : Nil
    @calls << :export_ca
  end

  def regenerate_ca : Nil
    @calls << :regenerate_ca
  end

  def import_ca : Nil
    @calls << :import_ca
  end

  def open_browser_picker : Nil
    @calls << :open_browser_picker
  end

  def comparer_pick(slot : Symbol) : Nil
    @calls << :comparer_pick
  end

  def comparer_swap : Nil
    @calls << :comparer_swap
  end

  def comparer_toggle_pane : Nil
    @calls << :comparer_toggle_pane
  end

  def comparer_add_selected : Nil
    @calls << :comparer_add_selected
  end

  def comparer_new : Nil
    @calls << :comparer_new
  end

  def comparer_close_subtab : Nil
    @calls << :comparer_close_subtab
  end

  def comparer_rename_subtab : Nil
    @calls << :comparer_rename_subtab
  end

  def comparer_duplicate_subtab : Nil
    @calls << :comparer_duplicate_subtab
  end

  def decoder_new : Nil
    @calls << :decoder_new
  end

  def decoder_close : Nil
    @calls << :decoder_close
  end

  def decoder_rename_subtab : Nil
    @calls << :decoder_rename_subtab
  end

  def decoder_duplicate_subtab : Nil
    @calls << :decoder_duplicate_subtab
  end

  def decoder_clear : Nil
    @calls << :decoder_clear
  end

  def decoder_copy : Nil
    @calls << :decoder_copy
  end

  def decoder_copy_selection : Nil
    @calls << :decoder_copy_selection
  end

  def decoder_copy_all : Nil
    @calls << :decoder_copy_all
  end

  def decoder_read_mode? : Bool
    false
  end

  def decoder_cycle_mode : Nil
    @calls << :decoder_cycle_mode
  end

  def decoder_save : Nil
    @calls << :decoder_save
  end

  def decoder_load : Nil
    @calls << :decoder_load
  end

  def jwt_new : Nil
    @calls << :jwt_new
  end

  def jwt_close : Nil
    @calls << :jwt_close
  end

  def jwt_rename_subtab : Nil
    @calls << :jwt_rename_subtab
  end

  def jwt_duplicate_subtab : Nil
    @calls << :jwt_duplicate_subtab
  end

  def jwt_clear : Nil
    @calls << :jwt_clear
  end

  def jwt_toggle_mode : Nil
    @calls << :jwt_toggle_mode
  end

  def jwt_cycle_alg : Nil
    @calls << :jwt_cycle_alg
  end

  def jwt_load_decoded : Nil
    @calls << :jwt_load_decoded
  end

  def jwt_copy : Nil
    @calls << :jwt_copy
  end

  def jwt_copy_all : Nil
    @calls << :jwt_copy_all
  end

  def jwt_copy_token : Nil
    @calls << :jwt_copy_token
  end

  def jwt_copy_attack : Nil
    @calls << :jwt_copy_attack
  end

  def jwt_read_mode? : Bool
    false
  end

  def notes_new : Nil
    @calls << :notes_new
  end

  def notes_close : Nil
    @calls << :notes_close
  end

  def notes_duplicate_subtab : Nil
    @calls << :notes_duplicate_subtab
  end

  def notes_copy : Nil
    @calls << :notes_copy
  end

  def notes_copy_all : Nil
    @calls << :notes_copy_all
  end

  def notes_read_mode? : Bool
    true
  end

  def notes_clear : Nil
    @calls << :notes_clear
  end

  def notes_edit : Nil
    @calls << :notes_edit
  end

  def notes_goto : Nil
    @calls << :notes_goto
  end

  def notes_find : Nil
    @calls << :notes_find
  end

  def notes_links : Nil
    @calls << :notes_links
  end

  def project_desc_read_mode? : Bool
    false
  end

  def project_copy : Nil
    @calls << :project_copy
  end

  def project_copy_all : Nil
    @calls << :project_copy_all
  end

  def read_selection_active? : Bool
    false
  end

  def read_select_line : Nil
    @calls << :read_select_line
  end

  def read_clear_selection : Nil
    @calls << :read_clear_selection
  end

  def read_copy : Nil
    @calls << :read_copy
  end

  def copy_as_open : Nil
    @calls << :copy_as_open
  end

  def send_to_open : Nil
    @calls << :send_to_open
  end

  def detail_navigable? : Bool
    false
  end

  def space_menu_title(verb_id : String) : String?
    nil
  end

  def open_settings(section : Symbol) : Nil
    @calls << :open_settings
  end

  def import_har : Nil
    @calls << :import_har
  end

  def import_urls : Nil
    @calls << :import_urls
  end

  def import_oas : Nil
    @calls << :import_oas
  end
end

describe Gori::Verb do
  describe "P1: one definition feeds both keymap and palette" do
    it "resolves the same verb id via a chord AND a palette search" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)

      # keybinding path: ctrl-p (Global) -> app.palette
      via_key = keymap.lookup(Chord.new("p", ctrl: true), Scope::Body)
      via_key.should eq("app.palette")

      # palette path: the Ctrl-P palette is the Global (app-control) surface
      via_palette = reg.for_scope(Scope::Global, FakeContext.new, "palette").map(&.id)
      via_palette.should contain("app.palette")
    end
  end

  describe Keymap do
    it "prefers a scope-specific binding then falls back to Global" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)

      # escape in PaletteOpen -> palette.close (scope-specific)
      keymap.lookup(Chord.new("escape"), Scope::PaletteOpen).should eq("palette.close")
      # escape in HistoryDetail -> detail.close (different verb, same chord)
      keymap.lookup(Chord.new("escape"), Scope::HistoryDetail).should eq("detail.close")
      # ←/→ in HistoryDetail walk the panes (left no longer just closes)
      keymap.lookup(Chord.new("right"), Scope::HistoryDetail).should eq("detail.next-pane")
      keymap.lookup(Chord.new("left"), Scope::HistoryDetail).should eq("detail.prev-pane")
      keymap.lookup(Chord.new("x"), Scope::HistoryDetail).should eq("detail.select-line")
      keymap.lookup(Chord.new("x", ctrl: true), Scope::HistoryDetail).should eq("detail.toggle-hex")
      # ^U in the Fuzzer pretty-prints the template (must NOT be intercepted as clear-marks
      # anymore — clear-marks moved to the space menu as fuzz.clear-marks).
      keymap.lookup(Chord.new("u", ctrl: true), Scope::Fuzzer).should eq("fuzz.pretty-template")
      # a Global chord (^P palette) resolves from ANY scope
      keymap.lookup(Chord.new("p", ctrl: true), Scope::Body).should eq("app.palette")
      # 'q' (back to projects) is bound only on the tab bar (Sidebar), not in a body —
      # as a Global chord it used to dump you to the picker mid-browse.
      keymap.lookup(Chord.new("q"), Scope::Sidebar).should eq("app.back-key")
      keymap.lookup(Chord.new("q"), Scope::Body).should be_nil
      # an unbound chord
      keymap.lookup(Chord.new("z"), Scope::Body).should be_nil
      # scope-specific: the top menu navigates horizontally, the body vertically
      keymap.lookup(Chord.new("right"), Scope::Sidebar).should eq("sidebar.next")
      keymap.lookup(Chord.new("down"), Scope::Sidebar).should eq("sidebar.enter")
      keymap.lookup(Chord.new("down"), Scope::Body).should eq("body.down")
    end

    it "supports multiple chords per verb" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      keymap.lookup(Chord.new("j"), Scope::Body).should eq("body.down")
      keymap.lookup(Chord.new("down"), Scope::Body).should eq("body.down")
    end

    it "binds bare 's' to the scope-lens toggle from any scope (was jump-to-editor)" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      keymap.lookup(Chord.new("s"), Scope::Body).should eq("scope.toggle-lens")
      keymap.lookup(Chord.new("s"), Scope::Sitemap).should eq("scope.toggle-lens")

      ctx = FakeContext.new
      reg["scope.toggle-lens"].call(ctx)
      ctx.calls.should contain(:scope_toggle_lens)

      # jumping to the scope rule editor is still reachable, now palette-only (no chord)
      reg["scope.edit"].call(ctx)
      ctx.calls.should contain(:scope_open)
    end

    it "binds ctrl-n to a new blank repeater in the Repeater scope" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      keymap.lookup(Chord.new("n", ctrl: true), Scope::Repeater).should eq("repeater.new")

      ctx = FakeContext.new
      reg["repeater.new"].call(ctx)
      ctx.calls.should contain(:repeater_new)
    end

    it "descends from the tab menu via enter_content (so sub-tab tabs land on the strip first)" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      # ↓/↵/j on the tab bar resolve to sidebar.enter…
      keymap.lookup(Chord.new("down"), Scope::Sidebar).should eq("sidebar.enter")
      keymap.lookup(Chord.new("enter"), Scope::Sidebar).should eq("sidebar.enter")

      # …which descends through enter_content (NOT focus_pane), letting the Runner
      # route Repeater/Notes onto their sub-tab strip before the body.
      ctx = FakeContext.new
      reg["sidebar.enter"].call(ctx)
      ctx.calls.should contain(:enter_content)
      ctx.calls.should_not contain(:focus_pane)
    end
  end

  describe "migrated tab-local chords resolve in their per-tab scope" do
    it "binds the Repeater request-pane toggles + send in Repeater scope" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("r", ctrl: true), Scope::Repeater).should eq("repeater.send")
      km.lookup(Chord.new("x", ctrl: true), Scope::Repeater).should eq("repeater.toggle-hex")
      km.lookup(Chord.new("s", ctrl: true), Scope::Repeater).should eq("repeater.toggle-sni")
      km.lookup(Chord.new("l", ctrl: true), Scope::Repeater).should eq("repeater.toggle-auto-content-length")
    end

    it "binds the Fuzzer run/stop/automark chords in Fuzzer scope" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("r", ctrl: true), Scope::Fuzzer).should eq("fuzz.run")
      km.lookup(Chord.new("x", ctrl: true), Scope::Fuzzer).should eq("fuzz.stop")
      km.lookup(Chord.new("a", ctrl: true), Scope::Fuzzer).should eq("fuzz.automark")
    end

    it "binds the Intercept catch chords in Intercept scope, shadowing the Global/Body keys" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("c"), Scope::Intercept).should eq("intercept.direction")
      km.lookup(Chord.new("/"), Scope::Intercept).should eq("intercept.filter")
      # …without breaking capture (`c`) elsewhere or History's `/` filter
      km.lookup(Chord.new("c"), Scope::Body).should eq("capture.toggle")
      km.lookup(Chord.new("/"), Scope::Body).should eq("history.query")
    end

    it "routes the new Repeater toggle verbs through the matching ExecContext methods" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new
      reg["repeater.toggle-hex"].call(ctx)
      reg["repeater.toggle-decoded"].call(ctx)
      reg["repeater.toggle-sni"].call(ctx)
      reg["repeater.toggle-auto-content-length"].call(ctx)
      ctx.calls.should contain(:repeater_toggle_hex)
      ctx.calls.should contain(:repeater_toggle_decoded)
      ctx.calls.should contain(:repeater_toggle_sni)
      ctx.calls.should contain(:repeater_toggle_auto_content_length)
    end

    it "routes the Round-4 Repeater :subtab/:response verbs through the matching ExecContext methods" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new
      reg["repeater.rename-subtab"].call(ctx)
      reg["repeater.close-subtab"].call(ctx)
      reg["repeater.toggle-diff"].call(ctx)
      reg["repeater.toggle-resp-hex"].call(ctx)
      ctx.calls.should contain(:repeater_rename_subtab)
      ctx.calls.should contain(:repeater_close_subtab)
      ctx.calls.should contain(:repeater_toggle_resp_diff)
      ctx.calls.should contain(:repeater_toggle_resp_hex)
    end

    it "routes the Round-4 Fuzzer :subtab verbs through the matching ExecContext methods" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new
      reg["fuzz.rename-subtab"].call(ctx)
      reg["fuzz.close-subtab"].call(ctx)
      ctx.calls.should contain(:fuzzer_rename_subtab)
      ctx.calls.should contain(:fuzzer_close_subtab)
    end

    it "routes the palette-only Refresh screen verb (no chord) to refresh_screen" do
      reg = Gori::Verbs.registry
      reg["view.refresh"].chords.empty?.should be_true # palette-only, unbound
      ctx = FakeContext.new
      reg["view.refresh"].call(ctx)
      ctx.calls.should contain(:refresh_screen)
    end
  end

  describe Registry do
    it "gates verbs by availability (P4) and hides cursor verbs from the palette" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new

      # no selection -> open-detail unavailable, copy unavailable
      ids = reg.search("", ctx).map(&.id)
      ids.should_not contain("body.open")
      ids.should_not contain("history.copy")
      ids.should_not contain("body.down") # hidden

      ctx.selected = 5_i64
      ids2 = reg.search("", ctx).map(&.id)
      ids2.should contain("body.open")
      ids2.should contain("history.copy")
    end

    it "fuzzy-ranks results and rejects non-subsequence queries" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new
      reg.search("quit", ctx).first.id.should eq("app.quit")
      reg.search("zzxq-nope", ctx).should be_empty
    end

    it "for_scope is STRICTLY scope-local — no Global fallback (the two surfaces are disjoint)" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new
      ctx.selected = 5_i64 # so the flow-gated Body actions are available

      body = reg.for_scope(Scope::Body, ctx)
      body.each do |v|
        v.hidden?.should be_false
        v.scope.should eq(Scope::Body) # strictly Body — Global app-control stays out of ":"
      end
      ids = body.map(&.id)
      ids.should contain("history.repeater") # an area action surfaces
      ids.should_not contain("app.quit")   # app-control belongs to Ctrl-P, not ":"
      ids.should_not contain("nav.next-tab")

      # The palette source is the Global slice (app control) — and it has NO area actions.
      gids = reg.for_scope(Scope::Global, ctx).map(&.id)
      gids.should contain("app.quit")
      gids.should contain("nav.next-tab") # tab navigation lives in Ctrl-P
      gids.any?(&.starts_with?("history.")).should be_false

      # fuzzy query narrows within the scope (same ranking as #search)
      reg.for_scope(Scope::Body, ctx, "repeater").first.id.should eq("history.repeater")
    end

    it "rejects duplicate ids" do
      reg = Registry.new
      reg.register(Definition.new("dup", "A", "", Scope::Global) { |_| nil })
      expect_raises(Gori::Error, /duplicate/) do
        reg.register(Definition.new("dup", "B", "", Scope::Global) { |_| nil })
      end
    end
  end

  describe "handler execution" do
    it "runs through Definition#call and returns the handler's status message" do
      ctx = FakeContext.new
      verb = Definition.new("t.msg", "T", "", Scope::Global) { |_c| "did it" }
      verb.call(ctx).should eq("did it")

      reg = Gori::Verbs.registry
      reg["app.quit"].call(ctx)
      ctx.calls.should contain(:quit)
    end
  end
end
