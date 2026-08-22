require "json"

# SAVED_VIEWS section: the GLOBAL half of the History view library. See settings.cr for the
# module-level overview and the load/save/serialize orchestration, and saved_views.cr for what
# a view IS and how the two scopes fold together.
module Gori::Settings
  # A named History query that lives in settings.json and therefore appears in EVERY project.
  # The counterpart to a `saved_views` row; both fold into the runtime `SavedViews::View` list
  # through `SavedViews.merged`, exactly the way `ColormarkerRule` and `color_rules` do.
  #
  # `id` is NUMERIC, and that is load-bearing rather than aesthetic: `Settings.entry_identity`'s
  # `:id` arm reads `as_i64?`, and an entry it cannot identify makes `merge_entry_list` fall back
  # to deciding the whole list as one blob — which DELETES a view a peer created while we held
  # an older snapshot. The `oast_providers` hex-slug shape is precisely why that section is not
  # in `RULE_SECTION_LISTS`; this one is, so it pays the numeric-id price to get the entry-wise
  # merge.
  record SavedView,
    id : Int64,    # monotonic, from `saved_views_next_id`; never reused
    name : String, # the operator-facing label, unique among GLOBAL views
    query : String # History QL — the same language the filter bar speaks

  class_property saved_views : Array(SavedView) = [] of SavedView

  # The next global view id, monotonic and NEVER reused — same reasoning as
  # `colormarker_next_rule_id`: a project's `history_view` pointer is keyed by this id and lives
  # in a different file this process may never open again, so handing a deleted view's number to
  # the next one created would silently activate a view the operator never picked.
  #
  # Counts from ONE, so 0 is free to mean "the write did not commit" in `add_saved_view`.
  class_property saved_views_next_id : Int64 = 1_i64

  private def self.parse_saved_views(node : JSON::Any) : Nil
    self.saved_views = parse_saved_view_list(node["views"]?)
    stored = node["next_view_id"]?.try(&.as_i64?) || 0_i64
    # Never go BACKWARDS from the ids actually present, whatever the file says — see
    # `parse_colormarker`.
    self.saved_views_next_id = {stored, next_id_after(saved_views.max_of?(&.id) || 0_i64), 1_i64}.max
  end

  # Tolerant parse, same spirit as the colour-rule parser: a non-array (or absent) node keeps
  # the current value, and an entry with a blank name or a blank query is DROPPED rather than
  # raised on, so a typo in a hand-edited `views` array cannot take the whole file down through
  # `load`'s blanket rescue.
  #
  # A view with no query narrows nothing, which is what the `All` BUILTIN already is — keeping
  # one here would put a second, unremarkable "All" in the picker under a name that promises
  # otherwise. The query is NOT otherwise validated here: `SavedViews.unusable_query_reason`
  # guards the write paths, and a parse that dropped every view whose fields this build does not
  # know would silently eat an operator's library on a downgrade.
  private def self.parse_saved_view_list(node : JSON::Any?) : Array(SavedView)
    arr = node.try(&.as_a?)
    return saved_views unless arr
    list = [] of SavedView
    seen = Set(Int64).new
    names = Set(String).new
    arr.each do |e|
      next unless o = e.as_h?
      name = (o["name"]?.try(&.as_s?) || "").strip
      query = o["query"]?.try(&.as_s?) || ""
      next if name.empty? || query.blank?
      # First name wins on a hand-authored duplicate, so the file loads deterministically and
      # `resolve_by_name` cannot depend on array order.
      next unless names.add?(name.downcase)
      list << SavedView.new(claim_id(o["id"]?.try(&.as_i64?), seen), name, query)
    end
    list
  end

  # Re-read the `saved_views` section from settings.json into memory, leaving every other
  # section alone. The twin of `reload_colormarker_from_disk`, for the same reasons and with the
  # same contract: see it and `Settings.reload_section`.
  def self.reload_saved_views_from_disk : Nil
    reload_section("saved_views") do |node|
      held = saved_views_next_id
      parse_saved_views(node)
      # Only ever upward — a lower number on disk would re-mint a live view's id.
      self.saved_views_next_id = {saved_views_next_id, held}.max
    end
  end

  # --- global view CRUD -------------------------------------------------------------------
  # Each mutation re-reads the section, rewrites the array and persists via `save` (atomic +
  # 3-way merge, reconciled by view id inside this section). Every answer is a COMMIT answer,
  # so memory is snapshotted and rolled back when `save` refuses — see `add_colormarker_rule`
  # for the full reasoning; the failure here is the same shape (a view left live in every
  # project after the operator was told it was not added).
  #
  # Order carries no meaning: a view is chosen by pick, not matched in sequence. There is
  # deliberately no `move_saved_view`.

  # Returns the new view's id, or 0 when the write did not reach disk.
  def self.add_saved_view(name : String, query : String) : Int64
    reload_saved_views_from_disk # before both the snapshot and the mint
    prev_views = saved_views
    prev_next = saved_views_next_id
    id = saved_views_next_id
    self.saved_views_next_id = next_id_after(id) # saturating — see `next_id_after`
    self.saved_views = saved_views + [SavedView.new(id, name.strip, query)]
    return id if save
    self.saved_views = prev_views
    # The counter too: a burned id is not cosmetic here — a project's `history_view` pointer
    # outlives the view it names, which is the whole reason ids are never reused.
    self.saved_views_next_id = prev_next
    0_i64
  end

  def self.update_saved_view(id : Int64, name : String, query : String) : Bool
    reload_saved_views_from_disk # a view a peer deleted must not come back as an edit
    prev_views = saved_views
    found = false
    self.saved_views = saved_views.map do |v|
      next v unless v.id == id
      found = true
      SavedView.new(id, name.strip, query)
    end
    ok = found && save
    self.saved_views = prev_views unless ok
    ok
  end

  def self.delete_saved_view(id : Int64) : Bool
    reload_saved_views_from_disk
    prev_views = saved_views
    kept = saved_views.reject { |v| v.id == id }
    return false if kept.size == saved_views.size
    self.saved_views = kept
    return true if save
    self.saved_views = prev_views
    false
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). The views go;
  # `saved_views_next_id` STAYS, for the same reason `reset_colormarker` keeps its counter — a
  # project store's `history_view` key is a global view id and survives this reset, so reusing
  # an id would silently activate a stale pointer's view.
  private def self.reset_saved_views : Nil
    self.saved_views = [] of SavedView
  end

  # Omit the whole block when there is nothing to say, so an untouched install never writes a
  # "saved_views" section. The counter is written even with an empty list — it is what keeps a
  # deleted view's id from being handed out again after the last view is removed.
  private def self.serialize_saved_views(j : JSON::Builder) : Nil
    return if saved_views.empty? && saved_views_next_id <= 1
    j.field "saved_views" do
      j.object do
        j.field "next_view_id", saved_views_next_id
        j.field "views" do
          j.array do
            saved_views.each do |v|
              j.object do
                j.field "id", v.id
                j.field "name", v.name
                j.field "query", v.query
              end
            end
          end
        end
      end
    end
  end
end
