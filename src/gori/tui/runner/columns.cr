# User-defined History columns (#819) — ExecContext verb implementations; reopens
# Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade and overlays).
#
# A column is an extract descriptor the History list DRAWS: `header:x-request-id`,
# `jsonpath:data.id`, a regex capture. `Gori::DisplayColumns` owns the model and the project
# store owns the rows; what lives here is the TUI's whole editing surface for them — a list card
# and the per-column form it hands off to, no tab of their own.
#
# Every mutation goes straight to the store and is followed by `reload_columns`, so the list
# under the card redraws with the new set on the very next frame. That immediacy is the point:
# the card floats over the thing it edits, and the operator judges a descriptor by what appears
# in the rows behind it, not by what the form says.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def open_history_columns : Nil
    open_history_columns_at(nil)
  end

  private def open_history_columns_at(cursor : Int32?) : Nil
    list = ColumnsOverlay.new(history_controller.view.columns, cursor)
    list.on_delete = ->(col : Gori::Store::DisplayColumn) { delete_history_column(col) }
    list.on_move = ->(col : Gori::Store::DisplayColumn, dir : Int32) { move_history_column(col, dir) }
    list.on_close = -> {
      if pending = list.pending
        open_history_column_form(pending, list.selected)
      end
    }
    open_overlay(list)
  end

  private def delete_history_column(col : Gori::Store::DisplayColumn) : Bool
    ok = @session.store.delete_display_column(col.id)
    history_controller.reload_columns if ok
    ok
  end

  private def move_history_column(col : Gori::Store::DisplayColumn, dir : Int32) : Bool
    ok = @session.store.move_display_column(col.id, dir)
    history_controller.reload_columns if ok
    ok
  end

  private def open_history_column_form(pending : ColumnsOverlay::Pending, cursor : Int32) : Nil
    all = history_controller.view.columns
    idx = pending.index
    editing = idx ? all[idx]? : nil
    form = editing ? ColumnOverlay.editing(editing) : ColumnOverlay.adding
    # What this descriptor pulls out of the flow under the History cursor. Injected, because the
    # card holds neither a store nor a selection — and answered live, so the operator judges the
    # descriptor against a real message rather than against their memory of one.
    form.on_preview = ->(f : ColumnOverlay) { preview_history_column(f) }
    form.on_commit = -> { save_history_column(form) }
    # Both paths — saved or cancelled — return to a FRESHLY built list, so it shows whatever the
    # commit just wrote.
    form.on_close = -> { open_history_columns_at(cursor) }
    open_overlay(form)
  end

  # The value the form's descriptor would draw for the selected flow, or nil when there is no
  # flow to read (an empty list, or a row a peer deleted between frames).
  #
  # ONE flow, and only while the form is open — the same P8 discipline the row loop keeps. The
  # body read is capped exactly as the list's is, so a preview cannot pull a multi-MiB BLOB that
  # the column itself would never have read.
  private def preview_history_column(form : ColumnOverlay) : String?
    id = history_controller.selected_flow_id
    return nil unless id
    col = Gori::Store::DisplayColumn.new(0_i64, 0, form.label, form.side, form.kind,
      form.selector, form.pos_start, form.pos_end, form.width)
    prepared = Gori::DisplayColumns.prepare([col])
    detail = @session.store.get_flow(id, body_max: prepared.body_scoped? ? Gori::DisplayColumns::BODY_CAP : 0)
    return nil unless detail
    value = prepared.values(detail).first?
    # An empty answer says so in WORDS rather than leaving the band blank: "this descriptor found
    # nothing in the flow you are looking at" and "the preview has not run" are different facts,
    # and a blank band cannot tell them apart.
    (value.nil? || value.empty?) ? "no match in flow ##{id}" : value
  end

  private def save_history_column(form : ColumnOverlay) : Bool
    # `apply_extract_rule`'s guard, verbatim, and for the reason its own comment gives: the
    # overlay's `invalid_reason` catches the local shape (an empty label, a missing selector, a
    # regex that will not compile, a `position` range whose end is not past its start) and the
    # Save row renders it — but `↵` on the last text row commits anyway, so a column the form
    # said was incomplete was persisted, took cells from HOST and PATH, and drew a blank-headed
    # cell for the rest of the engagement. Returning false keeps the card up on the field that
    # is wrong.
    if reason = form.invalid_reason
      # Named, not merely refused. `↵` that does nothing reads as a dropped keystroke; the Save
      # row already carries this sentence, but the caret is on the field the operator was typing
      # in when they pressed it.
      @toast = I18n.sys("column not saved — %{reason}", reason: reason)
      return false
    end
    store = @session.store
    if id = form.edit_id
      unless store.update_display_column(id, form.label, form.kind, form.selector,
               form.pos_start, form.pos_end, form.side, form.width)
        @toast = I18n.sys("could not save %{label} — the store is busy", label: form.label)
        return false
      end
      @toast = I18n.sys("updated column %{label}", label: form.label)
    else
      # Re-checked at the commit and not only on the list card: a peer (the CLI, MCP, another
      # gori against this project) can have filled the last slot while this form was open.
      if Gori::DisplayColumns.load(store).size >= Gori::DisplayColumns::MAX_COLUMNS
        @toast = I18n.sys("%{MAX_COLUMNS} columns is the limit — delete one first", MAX_COLUMNS: Gori::DisplayColumns::MAX_COLUMNS)
        return false
      end
      if store.insert_display_column(form.label, form.kind, form.selector,
           form.pos_start, form.pos_end, form.side, form.width) == 0
        @toast = I18n.sys("could not save %{label} — the store is busy", label: form.label)
        return false
      end
      @toast = I18n.sys("added column %{label}", label: form.label)
    end
    history_controller.reload_columns
    true
  end
end
