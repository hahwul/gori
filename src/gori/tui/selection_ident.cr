module Gori::Tui
  # A tab's SELECTION identity — everything `TabController#write_mcp_selection` will put in
  # the `ui_state` row, folded to one comparable value (#1091).
  #
  # It exists because the publish gate is a DIFF: `Runner#ui_state_identity` is compared on
  # every 50 ms tick and the row is only rewritten when it moved. Before this, that tuple was
  # `{active_tab, focus, selected_flow_id, subtab}` — none of which a mark gesture touches —
  # so marking four rows in History published nothing at all and an agent reading
  # `get_current_context` a second later was told the operator had selected nothing.
  #
  # DERIVED, not a bumped revision counter. A counter would be an unbounded obligation: every
  # one of the ~14 `@marks` mutators across the four list views, and every future one, would
  # have to remember to bump it — and a missed bump is exactly the silent never-republished
  # bug above, invisible to every payload spec (those read the real state; the gate would read
  # the counter). These fields are read from the SAME state the payload serialises, so the two
  # cannot disagree. The audit that makes this sound: no mutator in any of the four views can
  # change the mark SET while leaving both `marks` and the cursor where they were — adds only
  # arrive from gestures that move the count, removes only from prunes that lower it.
  #
  # Accepted residual, stated rather than hidden: a store reload that leaves `rows`, `cursor`,
  # `cursor_id` AND `marks` all identical while sliding one marked row out of the visible
  # window leaves `marked_hidden_count` stale until the next gesture. Bounded, self-healing,
  # and about a decoration field — never about which ids the agent would act on.
  #
  # Every field must be O(1) and allocation-free to read: this is on the tick. In particular
  # `TabController#subtab_count` (builds an `Array(String)` via `subtab_labels`) and
  # `#marked_subtab_indices` (allocates AND calls `SubtabMarks#retain`) may NOT feed it —
  # `subtabs` comes from `SubtabMarks#size`, a `Hash#size`.
  #
  # A `record`, so it is a STRUCT and `==` is field-wise. As a class `==` would be reference
  # equality and the gate would fire on every tick (or never) — `selection_ident_spec.cr`
  # pins that it is a value type.
  record SelectionIdent,
    marks : Int32 = 0,        # mark_count on the tab's list
    cursor : Int32 = 0,       # the cursor's row INDEX (every list view keeps one)
    cursor_id : Int64 = 0,    # the cursor row's integer id; 0 where the tab has none
    cursor_key : String = "", # the cursor row's string key, where `cursor_id` cannot say it
    rows : Int32 = 0,         # rows the current narrowing shows
    query : String = "",      # the live QL / filter text ("" = none)
    view : String = "",       # the active saved view's key ("" = none)
    scoped : Bool = false,    # the `s` scope lens
    subtabs : Int32 = 0       # marked chips on the strip (SubtabMarks#size)
end
