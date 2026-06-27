require "../../src/gori"

# A no-op ExecContext for exercising registry/palette logic in specs.
class FakeExecContext < Gori::Verb::ExecContext
  property selected : Int64? = nil

  def quit! : Nil; end

  def leave_project : Nil; end

  def status(message : String) : Nil; end

  def open_palette : Nil; end

  def close_overlay : Nil; end

  def current_tab : Symbol
    :history
  end

  def focus_pane(pane : Symbol) : Nil; end

  def enter_content : Nil; end

  def focus_tab(tab : Symbol) : Nil; end

  def focus_visible_tab(n : Int32) : Nil; end

  def cycle_tab(delta : Int32) : Nil; end

  def move_selection(delta : Int32) : Nil; end

  def open_detail : Nil; end

  def close_detail : Nil; end

  def toggle_follow : Nil; end

  def selected_flow_id : Int64?
    @selected
  end

  def copy_selection : Nil; end

  def history_query : Nil; end

  def scroll_detail(delta : Int32) : Nil; end

  def toggle_detail_pane : Nil; end

  def move_detail_pane(dir : Int32) : Nil; end

  def toggle_detail_hex : Nil; end

  def toggle_reveal : Nil; end

  def toggle_pretty : Nil; end

  def replay_selected : Nil; end

  def replay_new : Nil; end

  def replay_send : Nil; end

  def replay_toggle_hex : Nil; end

  def replay_toggle_sni : Nil; end

  def replay_toggle_auto_content_length : Nil; end

  def fuzz_selected : Nil; end

  def fuzz_from_replay : Nil; end

  def fuzz_run : Nil; end

  def fuzz_stop : Nil; end

  def fuzz_new : Nil; end

  def fuzz_automark : Nil; end

  def sitemap_move(delta : Int32) : Nil; end

  def sitemap_toggle : Nil; end

  def sitemap_expand : Nil; end

  def sitemap_collapse : Nil; end

  def sitemap_query : Nil; end

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

  def rules_open : Nil; end

  def finding_create : Nil; end

  def findings_new : Nil; end

  def findings_query : Nil; end

  def findings_move(delta : Int32) : Nil; end

  def findings_open : Nil; end

  def finding_close : Nil; end

  def findings_delete : Nil; end

  def finding_severity(delta : Int32) : Nil; end

  def finding_status(delta : Int32) : Nil; end

  def finding_set_severity : Nil; end

  def finding_set_status : Nil; end

  def finding_edit_notes : Nil; end

  def finding_edit_title : Nil; end

  def finding_open_flow : Nil; end

  def finding_replay_flow : Nil; end

  def findings_export(format : Symbol) : Nil; end

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

  def open_browser_picker : Nil; end

  def comparer_pick(slot : Symbol) : Nil; end

  def comparer_swap : Nil; end

  def comparer_toggle_pane : Nil; end

  def comparer_add_selected : Nil; end

  def open_settings(section : Symbol) : Nil; end
end
