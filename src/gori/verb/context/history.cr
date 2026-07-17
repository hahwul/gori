# History (list + detail pane) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
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
end
