# Frozen issue evidence (#1038) — reopens Gori::Tui::Runner (see tui/runner.cr for the
# event loop, Host facade, overlays, and rendering). Every entry point that freezes an
# exchange lands here: the Issues detail's RELATED row, the LINKS card's `f`, the
# "Link & freeze…" picker from History / the History detail / the Repeater, and the
# "+ New issue…" row of that picker. One snapshot builder, one confirm, one write.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- the two gates the IssuesDetail verbs read ---------------------------

  # A LIVE History/Repeater row under the RELATED cursor that still resolves.
  def issue_related_freezable? : Bool
    res = issues_controller.view.selected_resolved_link || return false
    !res.stale? && Evidence.freezable?(res.link.ref_kind)
  end

  def issue_related_frozen? : Bool
    !issues_controller.view.selected_evidence.nil?
  end

  # --- Issues detail: RELATED row ------------------------------------------

  # `f` / space → Freeze as evidence on the open issue's selected RELATED row. The row is
  # already linked, so the copy is written WITHOUT a second link.
  def issue_freeze_link : Nil
    issue = issues_controller.view.detail_issue || return
    if issues_controller.view.selected_evidence
      @toast = "this row already is the frozen copy"
      return
    end
    res = issues_controller.view.selected_resolved_link
    unless res
      @toast = "select a related History flow or Repeater row to freeze"
      return
    end
    if res.stale?
      @toast = "#{res.label} — nothing left to freeze"
      return
    end
    snap = evidence_snapshot(res.link.ref_kind, res.link.ref_id) || return
    freeze_into_issue(issue.id, [snap], link: false) do |ids|
      refresh_issue_evidence(issue.id, ids.last?)
      refresh_evidence_markers
      @toast = "frozen as evidence ##{ids.last?} (#{Fmt.size(snap.bytes)}) — the live #{res.tag} row stays live"
    end
  end

  # ↵ on a FROZEN row: the read-only viewer over the detail. A LIVE row keeps the
  # navigation `issue.open-link` has always done.
  def issue_open_link : Nil
    if m = issues_controller.view.selected_evidence
      open_evidence_viewer(m.id)
    elsif res = issues_controller.view.selected_resolved_link
      navigate_link_ref(res.link.ref_kind, res.link.ref_id)
    else
      @toast = "no related link selected"
    end
  end

  # The frozen copy's only way out. A confirm — the bytes cannot be recovered from the
  # source, which is why they were frozen — then the row goes and RELATED re-reads.
  def issue_evidence_delete : Nil
    issue = issues_controller.view.detail_issue || return
    m = issues_controller.view.selected_evidence
    unless m
      @toast = "select a FROZEN row to delete"
      return
    end
    confirm("DELETE FROZEN EVIDENCE",
      "Delete frozen evidence ##{m.id} (#{Evidence.label(m)},\n" \
      "#{m.source_label}, #{Fmt.size(m.bytes)}) from issue ##{issue.id}?\n\n" \
      "The live #{m.source_kind.tag} is not touched. This can't be undone.",
      confirm_label: "delete") do
      if @session.store.delete_evidence(m.id)
        refresh_issue_evidence(issue.id, nil)
        refresh_evidence_markers
        # No bytes, no url: the feed must not carry what the copy held.
        log_evidence_event("issue ##{issue.id}: deleted frozen evidence ##{m.id} (#{m.source_label})")
        @toast = "frozen evidence ##{m.id} deleted"
      else
        @toast = "could not delete (store busy) — nothing was changed, try again"
      end
    end
  end

  # The read-only viewer. `y` copies the shown pane through the same clipboard path the
  # History detail uses — the bytes are the operator's own capture, and the copy is the
  # decoded text the card shows.
  def open_evidence_viewer(id : Int64) : Nil
    ev = @session.store.get_evidence(id)
    unless ev
      @toast = "frozen evidence ##{id} is gone — a peer may have deleted it"
      issues_controller.view.reload_detail_links(@session.store)
      return
    end
    viewer = EvidenceViewer.new(ev)
    viewer.on_copy = ->(text : String) {
      written = Clipboard.copy(text)
      @toast = "copied frozen #{viewer.pane} (#{written}b)#{Clipboard.note(written, text)}"
      nil
    }
    open_overlay(viewer)
  end

  # --- the LINKS card's `f` -------------------------------------------------

  # Runs from the card's `on_close` once the shell has dropped it (see LinksOverlay#pending_freeze).
  # Whatever happens — a refusal, a confirm declined, a copy written — the card comes back
  # on the row the operator was on, so `f` reads as an action inside the card rather than
  # a way out of it. A note owner has no evidence to hold; the refusal says so.
  private def freeze_from_links_card(lo : LinksOverlay) : Nil
    owner_kind, owner_id, cursor = lo.owner_kind, lo.owner_id, lo.selected
    back = -> { open_links_overlay(owner_kind, owner_id, cursor: cursor) }
    res = lo.selected_link
    unless res
      back.call
      return
    end
    unless owner_kind.issue?
      @toast = "frozen evidence belongs to an issue — link this to an issue to freeze it"
      back.call
      return
    end
    if res.stale?
      @toast = "#{res.label} — nothing left to freeze"
      back.call
      return
    end
    snap = evidence_snapshot(res.link.ref_kind, res.link.ref_id)
    unless snap
      back.call
      return
    end
    freeze_into_issue(owner_id, [snap], link: false, after: back) do |ids|
      refresh_issue_evidence(owner_id, ids.last?)
      refresh_evidence_markers
      @toast = "frozen as evidence ##{ids.last?} (#{Fmt.size(snap.bytes)}) on issue ##{owner_id}"
    end
  end

  # --- the LINK & FREEZE picker ---------------------------------------------

  def link_attach_freeze : Nil
    link_attach(freeze: true)
  end

  # ↵ on an existing issue in the picker's freeze mode. Runs from the picker's `on_close`
  # (a large copy raises a confirm, and the shell would tear down a modal opened from
  # inside the picker's own commit), so `back` restores the History drill-in the pick was
  # made from, exactly as the picker's own `on_close` did before it was replaced.
  private def link_and_freeze(issue_id : Int64, refs : Array({Store::LinkRefKind, Int64}),
                              back : Proc(Nil)) : Nil
    snaps = evidence_snapshots(refs)
    if snaps.empty?
      back.call
      return
    end
    skipped = refs.size - snaps.size
    freeze_into_issue(issue_id, snaps, link: true, after: back) do |ids|
      refresh_issue_evidence(issue_id, nil)
      refresh_evidence_markers
      @toast = if ids.size == 1 && skipped == 0
                 "linked to issue ##{issue_id} and frozen as evidence ##{ids[0]} (#{Fmt.size(snaps[0].bytes)})"
               else
                 parts = ["linked & frozen #{ids.size} on issue ##{issue_id}"]
                 parts << "#{skipped} skipped" if skipped > 0
                 parts.join(" · ")
               end
    end
  end

  # "+ New issue…" in freeze mode: the byte cost is asked about BEFORE the form opens, so
  # the form's commit — which already chains the open-vs-stay confirm — never has to raise a
  # second one. The snapshots are taken now and handed to the form; an exchange that changes
  # while the operator types the title is exactly the race a freeze exists to close.
  private def open_issue_form_for_freeze(refs : Array({Store::LinkRefKind, Int64}), typed : String) : Nil
    snaps = evidence_snapshots(refs)
    return if snaps.empty?
    total = snaps.sum(&.bytes)
    if total >= Evidence::LARGE_BYTES
      confirm_freeze_cost(total, snaps.size, "a new issue", -> { open_issue_form_for_link(refs, typed, snapshots: snaps) })
    else
      open_issue_form_for_link(refs, typed, snapshots: snaps)
    end
  end

  # After the form has filed the issue and linked its refs: write the copies. No confirm
  # here (see above); a refusal is reported, the issue stays filed. Returns the ids.
  private def freeze_form_snapshots(issue_id : Int64, snaps : Array(Evidence::Snapshot)) : Array(Int64)
    ids = [] of Int64
    snaps.each do |snap|
      id, status = @session.store.freeze_evidence(issue_id, snap, link: false)
      if status.ok?
        ids << id
        log_evidence_frozen(issue_id, id, snap)
      else
        status(freeze_refusal(issue_id, status))
        break
      end
    end
    ids
  end

  # --- shared core ----------------------------------------------------------

  # The snapshot for one ref, or nil with the reason toasted. A Repeater tab that was never
  # sent is refused rather than frozen request-only: a row badged FROZEN that holds no
  # response would be evidence of a response that never happened.
  private def evidence_snapshot(kind : Store::LinkRefKind, id : Int64) : Evidence::Snapshot?
    case kind
    when .flow?
      if d = @session.store.get_flow(id)
        return Evidence.from_flow(d)
      end
      @toast = "flow ##{id} is no longer captured — nothing to freeze"
    when .repeater?
      rec = @session.store.get_repeater_full(id)
      unless rec
        @toast = "repeater ##{id} is gone — nothing to freeze"
        return nil
      end
      snap = Evidence.from_repeater(rec)
      return snap if snap
      @toast = "repeater ##{id} has never been sent — send it, then freeze the exchange"
    else
      @toast = "only a History flow or a Repeater exchange can be frozen"
    end
    nil
  end

  # The batch form, for the History list's marked set: refs that cannot be frozen are
  # skipped and counted rather than aborting the rest (#442's rule). Capped like every
  # other per-flow batch verb — each copy is a blocking write on the render loop.
  private def evidence_snapshots(refs : Array({Store::LinkRefKind, Int64})) : Array(Evidence::Snapshot)
    snaps = [] of Evidence::Snapshot
    if refs.size > 1
      # Refused whole above the cap (the toast is set there), never silently trimmed.
      return snaps unless batch_within_cap(refs.map { |_, id| id }, "freeze")
    end
    refs.each do |kind, id|
      if snap = evidence_snapshot(kind, id)
        snaps << snap
      end
    end
    snaps
  end

  # Confirm-if-large, then write every snapshot, then `yield` the ids written (never
  # called when none was). `after` runs on EVERY exit — declined confirm included — and is
  # where a caller puts the modal back where it was.
  private def freeze_into_issue(issue_id : Int64, snaps : Array(Evidence::Snapshot), *,
                                link : Bool, after : Proc(Nil)? = nil,
                                &done : Array(Int64) -> Nil) : Nil
    total = snaps.sum(&.bytes)
    write = -> {
      ids = write_frozen(issue_id, snaps, link)
      done.call(ids) unless ids.empty?
      nil
    }
    if total >= Evidence::LARGE_BYTES
      confirm_freeze_cost(total, snaps.size, "issue ##{issue_id}", write, after)
    else
      write.call
      after.try(&.call)
    end
  end

  # The byte-cost question. Built on ConfirmDialog directly rather than `confirm`: that
  # helper restores the modal it was raised OVER, and every freeze is raised from inside a
  # picker's or card's on_close — whose restore is the caller's `after`, run on both
  # outcomes, which `confirm`'s accept-only action cannot express.
  private def confirm_freeze_cost(total : Int64, count : Int32, dest : String,
                                  write : Proc(Nil), after : Proc(Nil)? = nil) : Nil
    what = count == 1 ? "This copy is" : "These #{count} copies are"
    ov = ConfirmDialog.new("FREEZE EVIDENCE",
      "#{what} #{Fmt.size(total)} of request/response bytes,\n" \
      "kept in the project until deleted by hand\n" \
      "(#{Fmt.size(@session.store.evidence_bytes)} of #{Fmt.size(Evidence::QUOTA_BYTES)} used).\n\n" \
      "Freeze on #{dest}?",
      confirm_label: "freeze", danger: false)
    accepted = false
    ov.on_commit = -> { accepted = true; true }
    ov.on_close = -> {
      write.call if accepted
      after.try(&.call)
    }
    open_overlay(ov)
  end

  # Write the copies in order; stop at the first refusal (a quota reached mid-batch would
  # refuse every later one the same way) and report it.
  private def write_frozen(issue_id : Int64, snaps : Array(Evidence::Snapshot), link : Bool) : Array(Int64)
    ids = [] of Int64
    snaps.each do |snap|
      id, status = @session.store.freeze_evidence(issue_id, snap, link: link)
      unless status.ok?
        status(freeze_refusal(issue_id, status))
        break
      end
      ids << id
      log_evidence_frozen(issue_id, id, snap)
    end
    ids
  end

  private def freeze_refusal(issue_id : Int64, status : Store::FreezeStatus) : String
    case status
    in .issue_gone? then "issue ##{issue_id} no longer exists — nothing was frozen"
    in .quota?
      "evidence quota reached (#{Fmt.size(@session.store.evidence_bytes)} of #{Fmt.size(Evidence::QUOTA_BYTES)}) — delete a frozen copy first"
    in .busy? then "could not freeze (store busy) — nothing was written, try again"
    in .ok?   then "" # unreachable: callers ask only on a refusal
    end
  end

  # The activity feed gets the FACT — which issue, which source, how many bytes — and never
  # the bytes or the url: the feed is general-purpose and is read by every peer.
  private def log_evidence_frozen(issue_id : Int64, id : Int64, snap : Evidence::Snapshot) : Nil
    log_evidence_event("issue ##{issue_id}: frozen evidence ##{id} from #{snap.source_kind.tag} ##{snap.source_id} (#{Fmt.size(snap.bytes)})")
  end

  private def log_evidence_event(message : String) : Nil
    @session.store.insert_event("issues", "evidence", "info", message, goto_tab: "issues",
      actor: FlowSource::Surface::Tui.token)
  end

  # The two "a frozen copy exists" markers — the History detail's stats line and the
  # Repeater's RESPONSE border — re-counted after any write that changes the answer. Both
  # are no-ops with nothing open, and both are one indexed COUNT.
  private def refresh_evidence_markers : Nil
    history_controller.view.refresh_evidence_marker(@session.store)
    repeater_controller.refresh_evidence_marker
  end

  # Re-read the open detail's RELATED rows if it is this issue, and land the cursor on the
  # copy just written so the band and the toast agree.
  private def refresh_issue_evidence(issue_id : Int64, select_id : Int64?) : Nil
    view = issues_controller.view
    return unless view.detail_issue.try(&.id) == issue_id
    view.reload_detail_links(@session.store)
    view.select_evidence(select_id) if select_id
  end
end
