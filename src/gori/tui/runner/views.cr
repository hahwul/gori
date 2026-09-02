# History views (#776) — ExecContext verb implementations; reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade and overlays).
#
# A view is a named QL query the History list ANDs over the filter bar, the way the ⇧S scope
# lens does. `SavedViews` owns the model and the two stores; what lives here is the TUI's whole
# editing surface for them, and it is deliberately overlays-only — no tab, no form.
#
# The editing model is "the filter bar IS the editor". A view is BORN from a filter the operator
# already typed and can see (`+ Save current filter…`), and it is edited by loading it back into
# that same bar (`^E`) and re-saving under the same name. That is why there is no query field
# anywhere here: a second place to write a QL query would be a second place for it to be wrong,
# with none of the bar's completion, highlighting or live row count.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # The `+ Save current filter as a view…` row's index. Negative so it can never collide with a
  # position in the merged list.
  VIEW_ROW_SAVE = -1

  # `v` — the picker. A `LibraryPicker` for the same reason the session-slot picker is one: it
  # is exactly that shape, a filterable name + detail list whose actions the open-site injects.
  # The detail column carries each view's QL, because "what am I looking at" is a question about
  # the query, not the name.
  def open_history_view_picker : Nil
    store = @session.store
    views = SavedViews.merged(store)
    active = history_controller.view.active_view
    bar = history_controller.view.query
    lp = LibraryPicker.new(I18n.ui("HISTORY VIEW"), view_rows(views, active, bar), I18n.ui("view"), I18n.ui("activate"))
    # Open ON the view that is on. This card is a MODE selector, not a "load one of your saved
    # recipes" library like the Decoder's and the Rewriter's — the two the picker was built for,
    # where nothing is currently loaded and row 0 is the only honest place to start. Here there
    # always IS a current answer, so parking the cursor on row 0 made ↑/↓ step from somewhere the
    # operator is not, and made `●` something they had to go find. `views` and the rows are built
    # in the same order, so the array index IS the visual position on a card with no filter typed
    # yet.
    lp.set_selected(views.index { |v| active_view_matches?(v, active) } || 0)
    lp.on_commit = -> {
      # Index against the SAME array the rows were built from, and re-resolve by KEY rather than
      # trusting the position: the two stores can be edited from the CLI, from MCP or by a peer
      # between this card opening and ↵, and activating "whatever is fourth now" would filter by
      # a view the operator never saw.
      if i = lp.selected_index
        i == VIEW_ROW_SAVE ? open_view_save(bar) : activate_view(view_at(views, i))
      end
      true
    }
    lp.on_delete = ->(i : Int32) { delete_view(lp, i, views) }
    lp.on_edit = ->(i : Int32) { edit_view_query(view_at(views, i)) }
    open_overlay(lp)
  end

  # One row per view, plus the save row when there is a filter to save. The `●` marker and the
  # G/P/· scope badge are the two things the list has to answer at a glance: which one is on,
  # and which store it would be edited in.
  private def view_rows(views : Array(SavedViews::View), active : SavedViews::View?,
                        bar : String) : Array(LibraryPicker::Row)
    rows = views.map_with_index do |v, i|
      detail = v.narrowing? ? v.query : "everything — no source term"
      # The scope badge only where there IS a store to name. A builtin's `·` beside the
      # separators rendered as `· · ·`, which reads as a formatting bug rather than as "this one
      # ships with gori" — and "ships with gori" is already what having no badge says.
      detail = "#{v.badge} · #{detail}" unless v.builtin?
      detail = "● active · #{detail}" if active_view_matches?(v, active)
      LibraryPicker::Row.new(i, v.name, detail)
    end
    # Only when the bar HAS something to save. An entry that opens a name prompt for an empty
    # query would only ever end in a refusal, and it is the operator's own filter — not a menu
    # item — that makes the action available.
    unless bar.blank?
      rows << LibraryPicker::Row.new(VIEW_ROW_SAVE, "+ Save current filter as a view…", bar)
    end
    rows
  end

  # The view a picker row index names, or nil for the `+ Save current filter…` row.
  #
  # NOT a bare `views[i]?`: that row carries index `VIEW_ROW_SAVE` (-1), and Crystal's
  # `Array#[]?` WRAPS a negative index rather than answering nil — so `^E` on the save row would
  # have edited the LAST view in the list, overwriting the filter the operator had just typed
  # with an unrelated query. One helper, so no call site can forget the guard again.
  private def view_at(views : Array(SavedViews::View), i : Int32) : SavedViews::View?
    i < 0 ? nil : views[i]?
  end

  # `active` is nil for All, and All is a row like any other — so "nothing is narrowing" has to
  # mark the All row rather than none of them.
  private def active_view_matches?(view : SavedViews::View, active : SavedViews::View?) : Bool
    active ? view.key == active.key : view.key == SavedViews.all_view.key
  end

  # ↵ — make this the project's view, and persist it. The toast names the QUERY as well as the
  # name: a view is a standing filter the operator may not revisit for days, and the one moment
  # it can be explained for free is the moment it is switched on.
  private def activate_view(view : SavedViews::View?) : Nil
    return unless view
    store = @session.store
    unless SavedViews.set_active(store, view)
      # The store refused the write (busy/locked/closing). Applying the view in memory anyway
      # would leave the list filtered by something the next restart forgets, with no way to tell
      # the two states apart — so refuse both halves and say so.
      @toast = "could not save the view — the project store is busy"
      return
    end
    history_controller.view.set_view(view)
    history_controller.view.reload(store)
    @toast = view.narrowing? ? "view: #{view.name} — #{view.query}" : "view: #{view.name} — no narrowing"
  end

  # ^E — load the view's query into the filter bar and open it for editing. This is the ONLY
  # place a view's query is REPLACED into the bar, and it is explicit on purpose: picking a view
  # (↵) is a mode that leaves what the operator typed alone, which is the whole point of #776.
  # Re-saving under the same name updates the view.
  private def edit_view_query(view : SavedViews::View?) : Nil
    # nil is the `+ Save current filter…` row (see `view_at`). SAY so, rather than letting the
    # card come down on a keystroke that did nothing — ^X on the same row already answers, and
    # a silent dismissal is indistinguishable from ^E having worked.
    unless view
      @toast = "pick a view to edit — ↵ on this row saves the filter instead"
      return
    end
    unless view.narrowing?
      @toast = "#{view.name} has no query to edit"
      return
    end
    if view.builtin?
      # Loaded, not refused: a built-in is a fine STARTING POINT for a view of your own, and the
      # bar is where you would tailor it. Saving it lands in one of the two writable scopes, so
      # nothing here can modify the built-in itself.
      @toast = "#{view.name} is built in — edit and save it under a new name"
    end
    history_controller.set_history_query(view.query)
    history_controller.history_query
  end

  # ^X — delete a saved view, in place, the way every other LibraryPicker delete works. Built-ins
  # are refused by name rather than hidden: an operator who tries is asking a reasonable question
  # and deserves the answer.
  private def delete_view(lp : LibraryPicker, i : Int32, views : Array(SavedViews::View)) : Nil
    return @toast = "pick a view to delete" if i == VIEW_ROW_SAVE
    return unless view = views[i]?
    if view.builtin?
      @toast = "#{view.name} is a built-in view — it can't be deleted"
      return
    end
    store = @session.store
    unless SavedViews.remove(store, view)
      @toast = "could not delete #{view.name} — the store is busy"
      return
    end
    # Deleting the ACTIVE view leaves a dangling pointer; drop back to All rather than keep
    # filtering by something no longer in the list.
    if (active = history_controller.view.active_view) && active.key == view.key
      SavedViews.set_active(store, nil)
      history_controller.view.set_view(nil)
      history_controller.view.reload(store)
    end
    fresh = SavedViews.merged(store)
    lp.set_rows(view_rows(fresh, history_controller.view.active_view, history_controller.view.query))
    @toast = "deleted view #{view.name}"
    # The card stays up and its rows were just replaced, so the closure the open-site installed
    # is now indexing a stale array. Reinstall both hooks against the fresh one.
    lp.on_commit = -> {
      if j = lp.selected_index
        j == VIEW_ROW_SAVE ? open_view_save(history_controller.view.query) : activate_view(view_at(fresh, j))
      end
      true
    }
    lp.on_delete = ->(j : Int32) { delete_view(lp, j, fresh) }
    lp.on_edit = ->(j : Int32) { edit_view_query(view_at(fresh, j)) }
  end

  # `+ Save current filter…` — step one: the name. Seeded with the active view's name when one
  # is on, so "tweak the filter and re-save" is ↵↵ rather than retyping.
  private def open_view_save(query : String) : Nil
    if reason = SavedViews.unusable_query_reason(query)
      @toast = "can't save this filter: #{reason}"
      return
    end
    seed = history_controller.view.active_view.try { |v| v.builtin? ? "" : v.name } || ""
    np = NamePromptOverlay.new(I18n.ui("SAVE VIEW"), query, seed)
    np.on_commit = -> {
      name = np.name
      if reason = SavedViews.unusable_name_reason(name)
        @toast = reason
        false # keep the card up — the operator has a name to fix, not a decision to redo
      else
        open_view_scope(name, query)
        true
      end
    }
    open_overlay(np)
  end

  # Step two: which store. Asked rather than defaulted because the two answers mean different
  # things — a `src:` view belongs in every project, a `host:api.acme.test` one belongs in this
  # engagement — and that is a judgement only the operator can make. Same two-scope question
  # `gori run views add --scope` and MCP `create_view{scope}` ask.
  private def open_view_scope(name : String, query : String) : Nil
    cp = ChoicePicker.new(I18n.ui("SAVE VIEW WHERE"), [
      ChoicePicker::Choice.new("PROJECT — this engagement only", 'p', Theme.accent, 0),
      ChoicePicker::Choice.new("GLOBAL — every project", 'g', Theme.orange, 1),
    ], 0, :view_scope)
    # esc on the scope step goes back to the name, so a typed name is not lost to a keystroke
    # the operator meant as "wait, which scope?". The seam allows it: a modal opened from inside
    # another's commit is not closed afterwards (see `close_active_overlay`).
    open_choice_picker(cp) { |p| save_view(name, query, p.selected_value == 1 ? "global" : "project") }
  end

  # Create, update or MOVE, decided by where a view of this name already lives. One flow rather
  # than three verbs, because from the operator's side there is one intent — "this filter, under
  # this name, in this scope" — and the difference is a fact about the stores, not about what
  # they asked for. Each outcome names itself in the toast so the fact is never a surprise.
  private def save_view(name : String, query : String, scope : String) : Nil
    store = @session.store
    views = SavedViews.merged(store)
    same = views.find { |v| !v.builtin? && v.scope == scope && v.name.downcase == name.downcase }
    other = views.find { |v| !v.builtin? && v.scope != scope && v.name.downcase == name.downcase }

    if same
      unless SavedViews.update(store, same, name, query)
        return @toast = "could not update #{name} — the store is busy"
      end
      activate_view(SavedViews::View.new(same.id, name, query, scope))
      @toast = "updated view #{name} (#{scope})"
    elsif other
      # The name exists in the OTHER scope. Re-home it and take the new query with it, rather
      # than leaving two views one `--view NAME` would silently have to choose between.
      # Name and query travel WITH the move (see `SavedViews.set_scope`), so there is no
      # follow-up edit whose refusal could leave the list filtered by a query that was never
      # persisted — and no window where the destination holds the OLD name.
      unless moved = SavedViews.set_scope(store, other, scope, name, query)
        return @toast = "could not move #{name} to #{scope} — the store is busy"
      end
      activate_view(moved)
      @toast = "moved view #{name} to #{scope}"
    else
      unless created = SavedViews.add(store, name, query, scope)
        return @toast = "could not save #{name} — the store is busy"
      end
      activate_view(created)
      @toast = "saved view #{name} (#{scope})"
    end
  end
end
