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

  def replay_selected : Nil; end

  def replay_new : Nil; end

  def replay_send : Nil; end

  def sitemap_move(delta : Int32) : Nil; end

  def sitemap_toggle : Nil; end

  def sitemap_expand : Nil; end

  def sitemap_collapse : Nil; end

  def sitemap_query : Nil; end

  def scope_open : Nil; end

  def scope_add_host : Nil; end

  def scope_toggle_lens : Nil; end

  def rules_open : Nil; end

  def finding_create : Nil; end

  def findings_new : Nil; end

  def findings_move(delta : Int32) : Nil; end

  def findings_open : Nil; end

  def finding_close : Nil; end

  def findings_delete : Nil; end

  def finding_severity(delta : Int32) : Nil; end

  def finding_status(delta : Int32) : Nil; end

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

  def selected_intercept_id : Int64?
    nil
  end

  def export_ca : Nil; end

  def open_browser_picker : Nil; end

  def open_settings(section : Symbol) : Nil; end
end
