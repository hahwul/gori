# The entity-links overlay (Issue/Note ⇄ flow / repeater / fuzz / mine session) —
# reopens Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays,
# and rendering). Every domain edge is injected at `open_links_overlay`, so the overlay
# itself stays free of Store lookups.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- entity links overlay ------------------------------------------------

  # Opened from an Issue/Note (space → l). Every domain edge is injected: opening a
  # link, removing one, and the add hand-off. The add round-trip rides the base's
  # nested-modal seam (Overlay#on_close) rather than any shell-side flag, so the three
  # @link_add_* ivars this used to need are gone.
  # `cursor` restores the selection when the card is rebuilt for a reason the user did
  # not ask for (a source with nothing to link); the ordinary pop-back after a
  # sub-picker leaves it at the top, which is what the pre-seam rebuild did.
  def open_links_overlay(owner_kind : Store::LinkOwnerKind, owner_id : Int64,
                         cursor : Int32? = nil) : Nil
    lo = LinksOverlay.new(owner_kind, owner_id)
    lo.reload(@session.store)
    lo.set_selected(cursor) if cursor
    opening = nil.as(Store::EntityLink?)
    # ↵/o: record what to open and let the shell drop the card. The navigation itself
    # must run AFTER that drop — navigate_link_ref sets its own @overlay for a flow (the
    # History DETAIL drill-in), which close_active_overlay would otherwise wipe. A ↵
    # with nothing selected reports false and leaves the card up, as it always did.
    lo.on_commit = -> {
      if res = lo.selected_link
        opening = res.link
        true
      else
        false
      end
    }
    lo.on_remove = -> { remove_selected_link(lo) }
    # Runs after the shell has dropped this card (see Overlay#on_close). At most one of
    # the two is armed: a source key sets pending_add, ↵/o sets `opening`, esc neither.
    lo.on_close = -> {
      if kind = lo.pending_add
        open_link_add_picker(lo, kind)
      elsif link = opening
        navigate_link_ref(link.ref_kind, link.ref_id)
      end
    }
    open_overlay(lo)
  end

  # Put the chosen add sub-picker up in the links card's place. Whichever way it exits —
  # a pick, esc, or click-away — its own on_close pops back to a FRESH links card, which
  # is what the pre-seam close_flow_picker/close_subtab_picker pair did by rebuilding the
  # overlay. "Nothing to pick" (already toasted) pops straight back.
  private def open_link_add_picker(lo : LinksOverlay, kind : Char) : Nil
    owner_kind, owner_id = lo.owner_kind, lo.owner_id
    picker = build_link_add_picker(lo, kind)
    unless picker
      # Nothing to link (already toasted). The user never left the list, so put them
      # back on the row they were on rather than snapping to the top.
      open_links_overlay(owner_kind, owner_id, cursor: lo.selected)
      return
    end
    picker.on_close = -> { open_links_overlay(owner_kind, owner_id) }
    open_overlay(picker)
  end

  # The add sub-picker for a source key, with its commit wired to attach the pick to
  # THIS overlay's owner — that closure is what used to be @link_add_owner /
  # @link_add_ref_kind on the Runner. nil means the source had nothing to offer.
  private def build_link_add_picker(lo : LinksOverlay, kind : Char) : PickerOverlay?
    case kind
    when 'f' then link_add_flow_picker(lo)
    when 'r' then link_add_subtab_picker(lo, "PICK REPEATER", repeater_controller.subtab_search_rows,
      Store::LinkRefKind::Repeater, "no repeater sessions to link") { |i| repeater_controller.db_id_at(i) }
    when 'z' then link_add_subtab_picker(lo, "PICK FUZZ", fuzzer_controller.subtab_search_rows,
      Store::LinkRefKind::Fuzz, "no fuzz sessions to link") { |i| fuzzer_controller.db_id_at(i) }
    when 'm' then link_add_subtab_picker(lo, "PICK MINER", miner_controller.subtab_search_rows,
      Store::LinkRefKind::Miner, "no miner sessions to link") { |i| miner_controller.db_id_at(i) }
    end
  end

  private def link_add_flow_picker(lo : LinksOverlay) : PickerOverlay
    fp = FlowPicker.new(@session.store.recent_flows(500), :link)
    fp.on_commit = -> {
      if row = fp.selected_row
        commit_link_to_owner(lo.owner_kind, lo.owner_id, Store::LinkRefKind::Flow, row.id)
      end
      true
    }
    fp
  end

  # One builder for the three session pickers (repeater / fuzz / miner): they differ
  # only by heading, row source, link kind and how a sub-tab index resolves to a DB id.
  private def link_add_subtab_picker(lo : LinksOverlay, title : String, rows : Array(SubtabPicker::Row),
                                     ref_kind : Store::LinkRefKind, empty_toast : String,
                                     &db_id : Int32 -> Int64?) : PickerOverlay?
    if rows.empty?
      @toast = empty_toast
      return nil
    end
    sp = SubtabPicker.new(title, rows, action: "link")
    sp.on_commit = -> {
      if idx = sp.selected_index
        if rid = db_id.call(idx)
          commit_link_to_owner(lo.owner_kind, lo.owner_id, ref_kind, rid)
        else
          @toast = "session not persisted"
        end
      end
      true
    }
    sp
  end

  private def remove_selected_link(lo : LinksOverlay) : Nil
    return unless link = lo.selected_entity_link
    @session.store.remove_link(link.id)
    lo.reload(@session.store)
    refresh_link_owners(lo.owner_kind, lo.owner_id)
    @toast = "link removed"
  end

  private def refresh_link_owners(kind : Store::LinkOwnerKind, id : Int64) : Nil
    case kind
    when .issue?
      issues_controller.view.reload_detail_links(@session.store)
    when .note?
      refresh_note_link_preview(id)
    end
  end

  # ↵ on the link picker. The two create rows hand off — "+ New issue…" to the NEW ISSUE
  # form, "+ New note…" to a blank note — and every other row takes the link directly.
  # A create row arms on_close rather than opening the next modal here, because that
  # modal claims @overlay and the shell's close would tear it straight back down;
  # on_close runs after the drop, so the hand-off is the last write (see Overlay).
  private def link_picked(lp : LinkPicker, refs : Array({Store::LinkRefKind, Int64})) : Bool
    if kind = lp.selected_create
      # The filter doubles as the new issue's title: type it, ↵, and the form is filled.
      typed = lp.query.strip
      lp.on_close = kind.issue? ? -> { open_issue_form_for_link(refs, typed) } : -> { create_note_and_link(refs) }
      return true
    end
    if row = lp.selected_row
      if commit_links_to_owner(row.kind, row.id, refs) && refs.size == 1
        # commit_links_to_owner already reported the counts for a batch; the single case
        # names WHICH owner took the link. One list now holds both kinds, so a bare
        # "linked" no longer says what was picked. Built from the owner's IDENTITY, not
        # from the row's display label — `3:` there is a sub-tab position, not an id.
        owner = case row.kind
                in .issue? then "issue ##{row.id}: #{link_title_snip(row.name)}"
                in .note?  then "note #{link_title_snip(row.name)}"
                end
        @toast = "linked to #{owner}"
      end
    end
    true
  end

  # Transition from the link picker into the NEW ISSUE form. Ownership of the ref moves
  # INTO the form (C3's `link_ref:`), so dropping the form — esc, click-away — drops the
  # pending link with it; nothing is parked on the Runner. `typed` is whatever was in the
  # filter box, and it WINS over the flow-derived title: the operator naming the issue is
  # more specific than "GET /path".
  private def open_issue_form_for_link(refs : Array({Store::LinkRefKind, Int64}), typed : String = "") : Nil
    ref = refs.first
    # The form's own fields describe ONE flow (title/host/evidence); the rest of a marked
    # set rides along as extra_flow_ids and is linked after the insert (#442).
    extra = refs[1..].select { |kind, _| kind.flow? }.map { |_, id| id }
    if ref[0].flow?
      if row = @session.store.flow_row(ref[1])
        title = typed.empty? ? "#{row.method} #{row.target}" : typed
        open_issue_form(IssueForm.new(title, row.host, ref[1],
          link_ref: ref, extra_flow_ids: extra))
        return
      end
    end
    open_issue_form(IssueForm.new(typed, link_ref: ref, extra_flow_ids: extra))
  end

  # Blank note + link the workbench ref(s), then ask open vs stay. Reached from the link
  # picker's "+ New note…" row, on the same on_close hand-off as the issue form —
  # create_note_and_link ends on the open-vs-stay confirm, which claims @overlay.
  private def create_note_and_link(refs : Array({Store::LinkRefKind, Int64})) : Nil
    note_id = notes_controller.create_blank_note_id
    commit_links_to_owner(Store::LinkOwnerKind::Note, note_id, refs)
    # commit_links_to_owner set an ACCURATE batch summary — a mark whose flow is gone was
    # dropped, not attached. Prefix it rather than overwriting it: a flat "linked N flows"
    # here claimed the whole marked set even when two of them no longer resolved.
    @toast = refs.size == 1 ? "note created and linked" : "note created · #{@toast}"
    offer_open_created(:note, note_id)
  end

  # After create-and-link from a workbench picker: offer to jump to the new
  # owner, or stay on the caller tab. Default selection is stay (cancel) so a
  # reflexive ↵ doesn't yank focus away mid-recon.
  private def offer_open_created(kind : Symbol, id : Int64) : Nil
    # Drop whatever raised this BEFORE the confirm goes up. The issue path arrives from
    # inside the NEW ISSUE form's own on_commit, so `confirm` would otherwise capture
    # that form as its `parent` and restore it on close — landing "stay" back on a
    # filled-in create form for the issue that was just created, where a reflexive ↵
    # files a duplicate. The note path already gets here with nothing held (it runs from
    # the picker's on_close), so this is a no-op there.
    leave_overlay
    case kind
    when :issue
      confirm("ISSUE CREATED",
        "issue ##{id} created and linked.\nOpen it now, or stay here?",
        confirm_label: "open", cancel_label: "stay", danger: false) do
        navigate_to_created_issue(id)
      end
    when :note
      confirm("NOTE CREATED",
        "note created and linked.\nOpen it now, or stay here?",
        confirm_label: "open", cancel_label: "stay", danger: false) do
        navigate_to_created_note(id)
      end
    else
      @overlay = OverlayKind::None
    end
  end

  private def navigate_to_created_issue(id : Int64) : Nil
    @active_tab = :issues
    @focus = :body
    @overlay = OverlayKind::None
    if issues_controller.view.open_by_id(@session.store, id)
      @toast = "opened issue ##{id}"
    else
      issues_controller.view.reload(@session.store)
      @toast = "issue ##{id} created"
    end
  end

  private def navigate_to_created_note(id : Int64) : Nil
    @active_tab = :notes
    @focus = :body
    @overlay = OverlayKind::None
    if notes_controller.view.switch_note_by_id(id)
      notes_controller.refresh_link_preview
      @toast = "opened note"
    else
      @toast = "note created"
    end
  end

  private def commit_link_to_owner(owner_kind : Store::LinkOwnerKind, owner_id : Int64,
                                   ref_kind : Store::LinkRefKind, ref_id : Int64) : Bool
    if @session.store.add_link(owner_kind, owner_id, ref_kind, ref_id)
      @toast = "linked"
      refresh_link_owners(owner_kind, owner_id)
      true
    else
      @toast = "already linked"
      false
    end
  end

  # Batch form (#442): attach N refs to ONE owner, after the issue/note was picked once.
  # A single ref delegates to commit_link_to_owner so that path stays byte-identical to before;
  # N goes through Store#add_links — ONE transaction for the whole set, because add_link blocks
  # the calling fiber on a write-batch reply and this runs on the render loop. Then it reports
  # once: one toast, one refresh_link_owners. A ref whose flow is gone (a stale mark) is dropped
  # before the write rather than filing an orphan link row, and counted in the summary.
  # Returns true when at least one link was created.
  private def commit_links_to_owner(owner_kind : Store::LinkOwnerKind, owner_id : Int64,
                                    refs : Array({Store::LinkRefKind, Int64})) : Bool
    return false if refs.empty?
    return commit_link_to_owner(owner_kind, owner_id, refs.first[0], refs.first[1]) if refs.size == 1
    live = refs.select { |kind, rid| !kind.flow? || !@session.store.flow_row(rid).nil? }
    gone = refs.size - live.size
    linked = @session.store.add_links(owner_kind, owner_id, live)
    refresh_link_owners(owner_kind, owner_id)
    parts = ["linked #{linked}"]
    parts << "#{live.size - linked} already linked" if live.size > linked
    parts << "#{gone} no longer available" if gone > 0
    @toast = parts.join(" · ")
    linked > 0
  end

  def navigate_link_ref(ref_kind : Store::LinkRefKind, ref_id : Int64) : Nil
    case ref_kind
    when .flow?
      if history_controller.view.open_detail_id(ref_id, @session.store)
        @active_tab = :history
        @focus = :body
        @overlay = OverlayKind::Detail
      else
        @toast = "flow no longer captured"
      end
    when .repeater?
      if idx = repeater_controller.index_for_db_id(ref_id)
        @active_tab = :repeater
        repeater_controller.jump_subtab(idx)
        @focus = :body
      else
        @toast = "repeater session gone"
      end
    when .fuzz?
      if idx = fuzzer_controller.index_for_db_id(ref_id)
        @active_tab = :fuzzer
        fuzzer_controller.jump_subtab(idx)
        @focus = :body
      else
        @toast = "fuzz session gone"
      end
    when .miner?
      if idx = miner_controller.index_for_db_id(ref_id)
        @active_tab = :miner
        miner_controller.jump_subtab(idx)
        @focus = :body
      else
        @toast = "miner session gone"
      end
    end
  end

  private def refresh_note_link_preview(note_id : Int64) : Nil
    notes_controller.view.link_preview = note_link_preview_line(note_id)
  end

  private def note_link_preview_line(note_id : Int64) : String
    links = @session.store.list_links(Store::LinkOwnerKind::Note, note_id)
    return "" if links.empty?
    first = links.first
    line = Links.resolve(@session.store, first).line
    links.size > 1 ? "#{line} (+#{links.size - 1})" : line
  end

  # Every attachable owner on one list: issues first (the usual destination for evidence),
  # then the open notes. `detail` is scan context AND filter fodder — an issue's host and
  # status, a note's first line — so `issue pending h.test` narrows without leaving the card.
  private def link_picker_rows : Array(LinkPicker::Row)
    rows = @session.store.issues.map do |f|
      # Joined from the parts that are actually there: an issue filed from a Repeater/Fuzz
      # session carries no host, and "#{nil} · open" renders as a dangling "· open".
      detail = [f.host, f.status.label].compact.reject(&.empty?).join(" · ")
      LinkPicker::Row.new(Store::LinkOwnerKind::Issue, f.id,
        "##{f.id} [#{f.severity.label}] #{f.title}", f.title, detail)
    end
    doc = Notes.load(@session.store)
    doc.notes.each_with_index do |entry, i|
      # "untitled", not "note N": `name` is what the toast says after the kind word, and
      # that fallback rendered as "linked to note note 1".
      name = Notes.title(entry.text) || "untitled"
      # The BODY's first line, not the note's — line one is the title, and echoing it in
      # the detail column just prints every note's name twice.
      body = entry.text.lines.map(&.strip).reject(&.empty?)
      rows << LinkPicker::Row.new(Store::LinkOwnerKind::Note, entry.id, "#{i + 1}:#{name}",
        name, body.size > 1 ? body[1] : "")
    end
    rows
  end
end
