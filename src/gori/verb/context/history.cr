# History (list + detail pane) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # History view
  abstract def move_selection(delta : Int32) : Nil
  abstract def open_detail : Nil
  abstract def close_detail : Nil
  abstract def toggle_follow : Nil
  abstract def selected_flow_id : Int64?

  # --- multi-select marks (#442) ---
  # The effective target set every BATCH-capable History verb acts on:
  #
  #     the marks if any are set, else the cursor row
  #
  # (and, when the flow detail is open, just that flow — it's pinned to one). One rule, so
  # a verb never needs a notion of "batch mode" and keeps its single registered call path
  # (P1). `selected_flow_id` above is UNCHANGED — it still means the cursor row alone, so
  # every single-only verb needs no edit.
  abstract def selected_flow_ids : Array(Int64)
  # The TRUE mark count — 0 means "cursor mode", which selected_flow_ids.size cannot say
  # (it returns 1 either way). Gates the clear-marks verb and drives the menu titles.
  abstract def marked_flow_count : Int32
  abstract def history_mark_toggle : Nil                # flip the cursor row's mark, then advance
  abstract def history_mark_all : Nil                   # mark every row in the current filtered list
  abstract def history_mark_clear : Nil                 # drop every mark
  abstract def history_mark_extend(delta : Int32) : Nil # ⇧↑/⇧↓: extend a range from the anchor

  abstract def copy_selection : Nil
  abstract def history_query : Nil # focus the QL filter bar
  # History destructive actions (space-menu only; each opens a confirm first).
  abstract def history_delete : Nil # delete the selected/open flow
  abstract def history_clear : Nil  # wipe every History flow for this project

  # detail view
  abstract def scroll_detail(delta : Int32) : Nil
  # Copy the selection (or current line) from the navigable detail text pane.
  abstract def detail_copy_selection : Nil
  # (There is no horizontal companion to scroll_detail: the detail's req/res panes
  # soft-wrap, so a long line is already on the next row rather than off the edge.)
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
