require "../../redact/policy"
require "../../redact/wire"

# Frozen issue evidence (#1038) — reopens Gori::Tui::Runner (see tui/runner.cr for the
# event loop, Host facade, overlays, and rendering). Every entry point that freezes an
# exchange lands here: the Issues detail's RELATED row, the LINKS card's `f`, the LINK
# picker from History / the History detail / the Repeater, its "+ New issue…" row, and
# History's "Add issue". One snapshot builder, one pair of gates, one write.
#
# There is no "Link & freeze…" verb any more. Choosing between a pointer and the bytes made
# the operator understand an implementation detail (a link is mutable, retention and the next
# send can hollow it out) at the moment of FILING, and the answer was almost always "keep the
# bytes" — so ↵ on an issue freezes whenever the ref has an exchange, and says so when it
# cannot. The link is the primary act: a refusal, a declined gate or a quota wall changes what
# is KEPT, never whether the link happened, and the toast accounts for both halves.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # One ref, and either the copy of its exchange or the sentence that says why there is none
  # — `Evidence.snapshot_for`'s own words, the ones the CLI and MCP print. A ref with no
  # exchange is NOT dropped from the set the way the old freeze picker dropped it: it still
  # gets its link, and the refusal is what the toast names it with.
  record LinkSnapshot,
    kind : Store::LinkRefKind,
    id : Int64,
    snapshot : Evidence::Snapshot?,
    refusal : String? do
    def ref : {Store::LinkRefKind, Int64}
      {@kind, @id}
    end
  end

  # What one ↵ on the link picker did, and the single sentence it reports. A class-level
  # record because `Runner.new` owns a terminal and appears nowhere under spec/ — this is
  # the seam the spec drives, the way `Runner.drift_confirm_message` is.
  record LinkOutcome,
    owner : String,
    refs : Int32,
    linked : Int32,
    gone : Int32,
    frozen : Array(Int64),
    bytes : Int64,
    refusal : String? do
    def toast : String
      parts = [head]
      parts << "#{@refs - @gone - @linked} already linked" if @refs > 1 && @refs - @gone > @linked
      parts << "#{@gone} no longer available" if @gone > 0
      if @frozen.size == 1
        parts << "frozen as evidence ##{@frozen[0]} (#{Fmt.size(@bytes)})"
      elsif @frozen.size > 1
        parts << "#{@frozen.size} frozen (#{Fmt.size(@bytes)})"
      end
      # NAMED, never swallowed: "linked" on its own would read as if the bytes were kept.
      parts << "not frozen: #{@refusal}" if @refusal
      parts.join(" · ")
    end

    private def head : String
      return "already linked to #{@owner}" if @linked.zero? && @gone.zero?
      @refs == 1 ? "linked to #{@owner}" : "linked #{@linked} flows to #{@owner}"
    end
  end

  # --- the two gates the IssuesDetail verbs read ---------------------------

  # A LIVE History/Repeater row under the RELATED cursor that still resolves.
  def issue_related_freezable? : Bool
    res = issues_controller.view.selected_resolved_link || return false
    !res.stale? && Evidence.freezable?(res.link.ref_kind)
  end

  def issue_related_frozen? : Bool
    !issues_controller.view.selected_evidence.nil?
  end

  # `s` is offered on EVERY row a RELATED cursor can sit on. Each kind has a source tab, and
  # a source that is pruned, closed or (a Repeater id) reused is a sentence `issue_goto_link`
  # says — not a key that silently does nothing, which is what a tighter gate would make of
  # it on exactly the rows an operator most needs an answer about.
  def issue_related_goto? : Bool
    !issues_controller.view.selected_related.nil?
  end

  # --- Issues detail: RELATED row ------------------------------------------

  # `f` / space → Freeze as evidence on the open issue's selected RELATED row. The verb is
  # gated on `issue_related_freezable?`, so the row is a live flow/repeater; the row is
  # already linked, so the copy is written WITHOUT a second link.
  def issue_freeze_link : Nil
    issue = issues_controller.view.detail_issue || return
    res = issues_controller.view.selected_resolved_link || return
    snap = evidence_snapshot(res.link.ref_kind, res.link.ref_id) || return
    freeze_into_issue(issue.id, [snap], link: false) do |ids, refusal|
      refresh_issue_evidence(issue.id, ids.last?)
      refresh_evidence_markers
      @toast = refusal || "frozen as evidence ##{ids.last?} (#{Fmt.size(snap.bytes)}) — the live #{res.tag} row stays live"
    end
  end

  # ↵ on a RELATED row SHOWS that row's exchange, in place, whatever kind of row it is;
  # `s` (`issue_goto_link`) is what goes to the tab it lives in.
  #
  # It used to be one key with two behaviours in one list — a LIVE row teleported to
  # History/Repeater/Fuzzer/Miner, a FROZEN row opened a modal — so what ↵ did depended on a
  # badge two columns to the left. The Evidence tab already has the grammar this should be
  # (`↵ open · s source`), and RELATED now matches it.
  #
  # A fuzz or miner row is the one honest exception: a session is a template plus a run, with
  # no single exchange to show, so ↵ there opens the session and the hint says `↵ open
  # session` instead of `↵ view`. A stale row keeps the sentence it has always answered with.
  def issue_open_link : Nil
    row = issues_controller.view.selected_related
    unless row
      @toast = "no related link selected"
      return
    end
    if m = row.frozen
      open_evidence_viewer(m.id)
    elsif res = row.live
      if res.stale? || !Evidence.freezable?(res.link.ref_kind)
        navigate_link_ref(res.link.ref_kind, res.link.ref_id)
      else
        open_live_evidence_viewer(res)
      end
    end
  end

  # `s` on a RELATED row: the row's SOURCE, in its own tab — today's ↵ for a live row, and
  # for a frozen one the Evidence tab's `s`, id-reuse guard included.
  def issue_goto_link : Nil
    row = issues_controller.view.selected_related
    unless row
      @toast = "no related link selected"
      return
    end
    if m = row.frozen
      # An id ALONE is not the source: `repeaters.id` is reused, so a tab opened after the
      # source tab was closed can inherit its id while the copy outlives the close (#1048).
      return (@toast = EVIDENCE_SOURCE_REUSED) if evidence_source_reused?(m)
      unless @session.store.evidence_source_alive?(m)
        @toast = "the original #{m.source_label} is gone — the frozen copy is all there is"
        return
      end
      navigate_link_ref(m.source_kind, m.source_id)
    elsif res = row.live
      navigate_link_ref(res.link.ref_kind, res.link.ref_id)
    end
  end

  # `r` on the Issues detail: the selected RELATED row into a Repeater tab, nothing sent.
  #
  # It used to read `issues.flow_id` and only that — "Send linked flow to Repeater" — which
  # was the third verb on this card acting on a fact the card did not show, while the cursor
  # sat on a row the key ignored. Now the ROW is the target: a live flow row re-opens its
  # captured request, a FROZEN row duplicates its frozen request exactly as the Evidence
  # tab's own `r` does (one builder, `duplicate_evidence_into_repeater`).
  #
  # A cursor on any other row — a fuzz or miner session, which has no single exchange, or a
  # live repeater row, which IS a Repeater tab and is what `s` opens — FALLS BACK to the
  # issue's first flow row, which is what `r` has always meant here. A fallback, not a
  # refusal: the key's old meaning still has to work from wherever the cursor happens to be.
  def issue_repeater_flow : Nil
    view = issues_controller.view
    return unless view.detail_issue
    row = view.repeater_target_row
    unless row
      @toast = "nothing here to send to the Repeater — RELATED holds no flow or frozen copy"
      return
    end
    if m = row.frozen
      if ev = @session.store.get_evidence(m.id)
        duplicate_evidence_into_repeater(ev)
      else
        @toast = "frozen evidence ##{m.id} is gone — a peer may have deleted it"
        view.reload_detail_links(@session.store)
      end
    elsif res = row.live
      if @session.store.get_flow(res.link.ref_id)
        repeater_flow(res.link.ref_id)
      else
        # The row resolved when RELATED was last rebuilt; a peer's prune between then and
        # this keypress is the one way to get here, and it is the same sentence `s` gives.
        @toast = "that flow is no longer captured (pruned)"
      end
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
    linked = evidence_link_summary(m)
    confirm("DELETE FROZEN EVIDENCE",
      "Delete frozen evidence ##{m.id} (#{Evidence.label(m)},\n" \
      "#{m.source_label}, #{Fmt.size(m.bytes)})?\n\n" \
      "Affected Issue links: #{linked}\n\n" \
      "The live #{m.source_kind.tag} is not touched. This can't be undone.",
      confirm_label: "delete") do
      if @session.store.delete_evidence(m.id)
        refresh_issue_evidence(issue.id, nil)
        refresh_evidence_markers
        refresh_evidence_availability
        # No bytes, no url: the feed must not carry what the copy held.
        log_evidence_event("issue ##{issue.id}: deleted frozen evidence ##{m.id} (#{m.source_label})")
        @toast = "frozen evidence ##{m.id} deleted"
      else
        @toast = "could not delete (store busy) — nothing was changed, try again"
      end
    end
  end

  # The read-only viewer. The card itself never edits or sends; its copy callback applies
  # the same ambient #1035 body policy as the Evidence tab's copy/export actions.
  def open_evidence_viewer(id : Int64) : Nil
    ev = @session.store.get_evidence(id)
    unless ev
      @toast = "frozen evidence ##{id} is gone — a peer may have deleted it"
      issues_controller.view.reload_detail_links(@session.store)
      return
    end
    viewer = EvidenceViewer.new(ev)
    viewer.on_copy = ->(_text : String) {
      clean, count = sanitized_evidence(ev)
      text = evidence_pane_text(clean, viewer.pane)
      written = Clipboard.copy(text)
      marked = count ? " · SANITIZED (#{count})" : ""
      @toast = "copied frozen #{viewer.pane} (#{written}b)#{marked}#{Clipboard.note(written, text)}"
      nil
    }
    open_overlay(viewer)
  end

  # The same card over a LIVE ref, built from `Evidence.snapshot_for` — the builder the
  # freeze itself uses, so what ↵ shows and what `f` would keep are the same bytes by
  # construction rather than by two code paths agreeing.
  #
  # NOT the History drill-in, even for a flow that has a live id to hand it: reading must not
  # put a row of verbs that delete and send one keystroke from the reader. The argument is
  # `evidence_viewer.cr`'s own, and it is the same argument for both modes of the card.
  private def open_live_evidence_viewer(res : Links::Resolved) : Nil
    kind, id = res.link.ref_kind, res.link.ref_id
    snap = Evidence.snapshot_for(@session.store, kind, id)
    if snap.is_a?(String)
      @toast = live_view_refusal(kind, id, snap)
      return
    end
    viewer = EvidenceViewer.new(snap)
    viewer.on_copy = ->(_text : String) {
      clean, count = sanitized_snapshot(snap)
      text = snapshot_pane_text(clean, viewer.pane)
      written = Clipboard.copy(text)
      marked = count ? " · SANITIZED (#{count})" : ""
      # `frozen?` rather than a captured word: `f` can flip this card mid-session, and the
      # toast must name what the operator is now looking at.
      kindw = viewer.frozen? ? "frozen" : "live"
      @toast = "copied #{kindw} #{viewer.pane} (#{written}b)#{marked}#{Clipboard.note(written, text)}"
      nil
    }
    viewer.on_freeze = -> { freeze_from_live_viewer(viewer, snap, res) }
    open_overlay(viewer)
  end

  # `f` inside a LIVE viewer: the bytes on screen become a copy on the open issue and the
  # card flips to FROZEN without closing — the row it was opened from is already linked, so
  # nothing is linked a second time (`issue_freeze_link`'s own call).
  #
  # `after` puts the viewer back, because a copy over `LARGE_BYTES` or a drifted Repeater
  # raises a confirm over it; on the path where nothing displaced the card, re-opening it is
  # a no-op write of what the shell already holds.
  private def freeze_from_live_viewer(viewer : EvidenceViewer, snap : Evidence::Snapshot,
                                      res : Links::Resolved) : Nil
    issue = issues_controller.view.detail_issue || return
    back = -> { open_overlay(viewer) }
    freeze_into_issue(issue.id, [snap], link: false, after: back) do |ids, refusal|
      refresh_issue_evidence(issue.id, ids.last?)
      refresh_evidence_markers
      refresh_evidence_availability
      if id = ids.last?
        @session.store.get_evidence(id).try { |ev| viewer.frozen_as(ev) }
      end
      @toast = refusal || "frozen as evidence ##{ids.last?} (#{Fmt.size(snap.bytes)}) — the live #{res.tag} row stays live"
    end
  end

  # What ↵ says when the row resolves but has no exchange to show yet. `Runner.new` owns a
  # terminal and appears nowhere under spec/, so the sentence itself is built by the
  # class-level seam below and this half only answers the two questions that need the
  # session: is the source still there, and which key is `issue.goto-link` bound to.
  private def live_view_refusal(kind : Store::LinkRefKind, id : Int64, sentence : String) : String
    source = kind.repeater? ? !@session.store.get_repeater(id).nil? : !@session.store.flow_row(id).nil?
    Runner.live_view_refusal(kind, id, sentence, source,
      Hotkeys.binding_label(@session.registry, "issue.goto-link", "s"))
  end

  # `Evidence.snapshot_for`'s refusals are written for a FREEZE ("…then freeze the
  # exchange"), and ↵ here is a READ. The FACT comes back verbatim from that one builder —
  # three surfaces say it and they must not drift — and only the ADVICE is re-pointed at the
  # key this path actually has.
  #
  # Only when the source is still there for `s` to open. "no flow with id 12 — it may have
  # been pruned" is the other shape `snapshot_for` answers with, and a row that is gone has
  # nothing behind either key: offering one would be the lie `evidence_source_reused?` exists
  # to prevent one surface over.
  def self.live_view_refusal(kind : Store::LinkRefKind, id : Int64, sentence : String,
                             source : Bool, goto_key : String) : String
    return sentence unless source
    fact = sentence.partition(" — ")[0]
    where = kind.repeater? ? "the tab" : "it in History"
    "#{fact} — #{goto_key} opens #{where}"
  end

  # --- project-wide Evidence tab -------------------------------------------

  def selected_evidence_id : Int64?
    evidence_controller.view.selected_id
  end

  def evidence_has_links? : Bool
    evidence_controller.view.selected.try(&.issue_ids.empty?) == false
  end

  # `s` (open original source) is offered only when the live object this copy came FROM is
  # still that object — `Store#evidence_source_alive?`, the predicate `evidence_count_for`'s
  # marker already counted by. Existence alone was the bug: a Repeater id is reused, so after
  # closing the source tab and opening another, `s` navigated to an unrelated tab and
  # presented it as the original.
  def evidence_source_available? : Bool
    meta = evidence_controller.view.selected || return false
    @session.store.evidence_source_alive?(meta)
  end

  # One sentence for both surfaces that can be asked for a frozen row's source — the Evidence
  # tab's `s` and the Issues detail's.
  EVIDENCE_SOURCE_REUSED = "the original repeater tab is gone (its id was reused)"

  # A source id that now belongs to a DIFFERENT, newer Repeater tab than the one frozen from.
  # Distinguished from "gone" because the two need different sentences: `navigate_link_ref`
  # already says "repeater session gone" for an id with no row at all, and that sentence would
  # be a lie about an id whose row is right there — it is simply not this copy's tab.
  private def evidence_source_reused?(meta : Store::IssueEvidenceMeta) : Bool
    meta.source_kind.repeater? && !@session.store.get_repeater(meta.source_id).nil? &&
      !@session.store.evidence_source_alive?(meta)
  end

  def evidence_open : Nil
    id = selected_evidence_id || return
    open_evidence_viewer(id)
  end

  def evidence_filter : Nil
    evidence_controller.view.start_query
  end

  def evidence_compare : Nil
    view = evidence_controller.view
    previous = view.compare_anchor
    pair = view.compare_step
    unless pair
      @toast = previous ? "evidence comparison cancelled" : "evidence ##{view.compare_anchor} pinned as A — choose B and press c"
      return
    end
    first = @session.store.get_evidence(pair[0])
    second = @session.store.get_evidence(pair[1])
    unless first && second
      @toast = "one frozen copy is gone — choose the pair again"
      view.clear_compare
      view.reload(@session.store)
      return
    end
    first_before = first.meta.created_at < second.meta.created_at ||
                   (first.meta.created_at == second.meta.created_at && first.meta.id < second.meta.id)
    a, b = first_before ? {first, second} : {second, first}
    comparer_controller.view.set_pair(ComparerSlot.from_evidence(a), ComparerSlot.from_evidence(b))
    goto_tab(:comparer)
    @toast = "comparer: evidence ##{a.meta.id} → ##{b.meta.id}"
  end

  def evidence_open_issue : Nil
    meta = evidence_controller.view.selected || return
    ids = meta.issue_ids.select { |id| !@session.store.get_issue(id).nil? }
    return (@toast = "linked Issues are gone — this evidence is now orphaned") if ids.empty?
    return open_evidence_issue(ids.first) if ids.size == 1
    open_evidence_issue_picker("OPEN LINKED ISSUE", ids) { |id| open_evidence_issue(id) }
  end

  # The availability gate above normally keeps this verb off the key and out of the menu, so
  # the refusal here is the RACE: a peer instance (the project is one shared SQLite file) can
  # close the source tab and open a successor between the menu being built and the press.
  def evidence_open_source : Nil
    meta = evidence_controller.view.selected || return
    return (@toast = EVIDENCE_SOURCE_REUSED) if evidence_source_reused?(meta)
    navigate_link_ref(meta.source_kind, meta.source_id)
  end

  def evidence_duplicate_repeater : Nil
    ev = selected_evidence || return
    duplicate_evidence_into_repeater(ev)
  end

  # One frozen copy into a new Repeater tab, nothing sent — the Evidence tab's `r` and the
  # Issues detail's `r` on a FROZEN row, which are the same act and must not drift into two
  # spellings of the WS caveat below.
  private def duplicate_evidence_into_repeater(ev : Store::IssueEvidence) : Nil
    request = join_message(ev.request_head, ev.request_body)
    repeater_controller.repeater_from_request(ev.meta.url, String.new(request),
      ev.meta.protocol == "HTTP/2", nil, name: "evidence ##{ev.meta.id}")
    # A WebSocket copy is its HANDSHAKE (the frame transcript was never frozen), so the tab
    # this opens is an ordinary HTTP one — `repeater_flow` seeds a WS tab from a capture's
    # messages, and a snapshot has none to seed from. Say which, rather than letting the
    # operator press ^R expecting the socket back.
    handshake = Repeater::WsEngine.replayable?(String.new(ev.request_head))
    @toast = if handshake
               "evidence ##{ev.meta.id} duplicated as the HANDSHAKE — a frozen copy carries no frames; nothing was sent"
             else
               "evidence ##{ev.meta.id} duplicated into Repeater — nothing was sent"
             end
  end

  def evidence_link_issue : Nil
    meta = evidence_controller.view.selected || return
    ids = @session.store.issues.map(&.id).reject { |id| meta.issue_ids.includes?(id) }
    return (@toast = "this evidence is already linked to every Issue") if ids.empty?
    open_evidence_issue_picker("LINK EVIDENCE ##{meta.id}", ids) do |issue_id|
      if @session.store.link_evidence(meta.id, issue_id)
        evidence_controller.view.reload(@session.store)
        refresh_issue_evidence(issue_id, nil)
        @toast = "evidence ##{meta.id} linked to Issue ##{issue_id}"
      else
        @toast = "link failed — the evidence or Issue is gone"
      end
    end
  end

  def evidence_unlink_issue : Nil
    meta = evidence_controller.view.selected || return
    ids = meta.issue_ids.select { |id| !@session.store.get_issue(id).nil? }
    return (@toast = "this evidence has no Issue links") if ids.empty?
    open_evidence_issue_picker("UNLINK EVIDENCE ##{meta.id}", ids) do |issue_id|
      if @session.store.unlink_evidence(meta.id, issue_id)
        evidence_controller.view.reload(@session.store)
        refresh_issue_evidence(issue_id, nil)
        @toast = "evidence ##{meta.id} unlinked from Issue ##{issue_id}#{ids.size == 1 ? " — now orphaned" : ""}"
      else
        @toast = "unlink failed — the link is already gone"
      end
    end
  end

  def evidence_delete : Nil
    meta = evidence_controller.view.selected || return
    confirm("DELETE FROZEN EVIDENCE",
      "Delete evidence ##{meta.id} (#{Evidence.label(meta)}, #{Fmt.size(meta.bytes)})?\n\n" \
      "Affected Issue links: #{evidence_link_summary(meta)}\n\n" \
      "Its hashes and frozen bytes will be removed. The original #{meta.source_kind.tag}, if present, is not touched.",
      confirm_label: "delete") do
      if @session.store.delete_evidence(meta.id)
        evidence_controller.view.reload(@session.store)
        refresh_evidence_markers
        # Deleting the LAST copy takes the tab with it (the archive is what the tab is), and
        # this delete's own toast would otherwise overwrite the one that says so — leaving
        # the operator standing in Issues with no account of the tab that vanished.
        refresh_evidence_availability
        log_evidence_event("deleted frozen evidence ##{meta.id} (#{meta.source_label})")
        @toast = if @evidence_available
                   "frozen evidence ##{meta.id} deleted"
                 else
                   "frozen evidence ##{meta.id} deleted — the archive is empty, so Evidence closes until the next freeze"
                 end
      else
        @toast = "could not delete (store busy) — nothing was changed, try again"
      end
    end
  end

  # `y` on the list — the copy reflex every other list scope answers, on the one tab whose
  # rows ARE bytes. What the viewer's `y` copies for the pane it is showing, this copies for
  # the whole exchange, through the same ambient #1035 policy: a snapshot on the clipboard has
  # left the project, and the Evidence tab's other two exits (`⇧E` export, `space → Y` copy-as)
  # already pass it. A snapshot with no response copies its request alone rather than a
  # trailing blank — `response_head` is nil there, not empty.
  def evidence_copy : Nil
    ev = selected_evidence || return
    clean, count = sanitized_evidence(ev)
    request = EvidenceViewer.pane_text(clean.request_head, clean.request_body)
    text = if clean.response_head
             "#{request}\n\n#{EvidenceViewer.pane_text(clean.response_head, clean.response_body)}"
           else
             request
           end
    return (@toast = "evidence ##{ev.meta.id} has no bytes to copy") if text.empty?
    written = Clipboard.copy(text)
    marked = count ? " · SANITIZED (#{count})" : ""
    @toast = "copied evidence ##{ev.meta.id} (#{written}b)#{marked}#{Clipboard.note(written, text)}"
  end

  def evidence_export : Nil
    ev = selected_evidence || return
    open_export(:evidence_json, File.join(Dir.current, "evidence-#{ev.meta.id}.json")) do |path|
      clean, count = sanitized_evidence(ev)
      File.write(path, MCP::Serialize.evidence_json(clean, include_sensitive: false))
      marked = count ? " · SANITIZED (#{count})" : ""
      @toast = "exported evidence ##{ev.meta.id}#{marked} · #{path}"
      true
    rescue ex
      @toast = "evidence export failed: #{ex.message}"
      false
    end
  end

  private def evidence_copy_as_menu : {String, Array(CopyMenu::Option)}
    ev = selected_evidence || return {"COPY EVIDENCE AS", [] of CopyMenu::Option}
    clean, count = sanitized_evidence(ev)
    request = String.new(join_message(clean.request_head, clean.request_body))
    options = CopyMenu.request_options(request, clean.meta.url)
    if head = clean.response_head
      response = String.new(join_message(head, clean.response_body))
      options << CopyMenu::Option.new("Raw response", 's', response)
      options << CopyMenu::Option.new("Req + Res pair", 'p', "#{request}\n\n#{response}")
    end
    {CopyMenu.sanitized_title("COPY EVIDENCE AS", count), options}
  end

  private def selected_evidence : Store::IssueEvidence?
    selected_evidence_id.try { |id| @session.store.get_evidence(id) }
  end

  private def evidence_link_summary(meta : Store::IssueEvidenceMeta) : String
    return "none (orphaned)" if meta.issue_ids.empty?
    meta.issue_ids.map do |id|
      title = @session.store.get_issue(id).try(&.title).try { |s| " #{s.scrub.gsub(/\s+/, " ")}" } || ""
      "##{id}#{title}"
    end.join(", ")
  end

  private def open_evidence_issue(id : Int64) : Nil
    unless issues_controller.view.open_detail_id(id, @session.store)
      @toast = "Issue ##{id} is gone"
      return
    end
    goto_tab(:issues)
  end

  # `j`/`k` are left out on purpose: ChoicePicker tries a row mnemonic BEFORE its vim nav,
  # so binding them would take the two keys a long Issue list is scrolled with. Rows past
  # the end of this list are keyless and picked with ↑/↓ + ↵.
  EVIDENCE_PICK_KEYS = (('1'..'9').to_a + ('a'..'z').to_a.reject { |c| c == 'j' || c == 'k' })

  private def open_evidence_issue_picker(title : String, ids : Array(Int64), &picked : Int64 -> Nil) : Nil
    issues = ids.compact_map { |id| @session.store.get_issue(id) }
    return (@toast = "no Issues available") if issues.empty?
    choices = issues.map_with_index do |issue, i|
      # NOT `title` — a block assigning to the parameter's name rewrites it, and the card
      # opened headed by the LAST issue in the list instead of what it does.
      label = issue.title.scrub.gsub(/\s+/, " ")
      ChoicePicker::Choice.new("##{issue.id} [#{issue.status.label}] #{label}",
        EVIDENCE_PICK_KEYS[i]?, Theme.text, i)
    end
    picker = ChoicePicker.new(title, choices, -1, :evidence_issue)
    open_choice_picker(picker) do |choice|
      issues[choice.selected_value]?.try { |issue| picked.call(issue.id) }
    end
  end

  private def sanitized_evidence(ev : Store::IssueEvidence) : {Store::IssueEvidence, Int32?}
    matcher = Redact::Policy.ambient(@session.store) || return {ev, nil}
    request = Redact::Wire.message(ev.request_head, ev.request_body, matcher)
    response = Redact::Wire.message(ev.response_head, ev.response_body, matcher)
    clean = Store::IssueEvidence.new(ev.meta, request.head, request.body,
      ev.response_head.nil? ? nil : response.head, response.body)
    {clean, request.count + response.count}
  end

  # The live card's half of `sanitized_evidence` — same ambient #1035 policy, same two
  # messages, over the shape a live exchange comes in. A LIVE copy has to pass the policy for
  # the same reason a frozen one does: the clipboard leaves the project either way.
  private def sanitized_snapshot(snap : Evidence::Snapshot) : {Evidence::Snapshot, Int32?}
    matcher = Redact::Policy.ambient(@session.store) || return {snap, nil}
    request = Redact::Wire.message(snap.request_head, snap.request_body, matcher)
    response = Redact::Wire.message(snap.response_head, snap.response_body, matcher)
    clean = snap.copy_with(request_head: request.head, request_body: request.body,
      response_head: snap.response_head.nil? ? nil : response.head, response_body: response.body)
    {clean, request.count + response.count}
  end

  private def snapshot_pane_text(snap : Evidence::Snapshot, pane : Symbol) : String
    head, body = pane == :request ? {snap.request_head.as(Bytes?), snap.request_body} : {snap.response_head, snap.response_body}
    EvidenceViewer.pane_text(head, body)
  end

  private def evidence_pane_text(ev : Store::IssueEvidence, pane : Symbol) : String
    head, body = pane == :request ? {ev.request_head.as(Bytes?), ev.request_body} : {ev.response_head, ev.response_body}
    EvidenceViewer.pane_text(head, body)
  end

  private def join_message(head : Bytes, body : Bytes?) : Bytes
    return head unless body && !body.empty?
    io = IO::Memory.new(head.size + body.size)
    io.write(head)
    io.write(body)
    io.to_slice
  end

  # --- the LINKS card's `f` -------------------------------------------------

  # Runs from the card's `on_close` once the shell has dropped it (see LinksOverlay#pending_freeze).
  # Whatever happens — a refusal, a confirm declined, a copy written — the card comes back
  # on the row the operator was on, so `f` reads as an action inside the card rather than
  # a way out of it. The card arms `f` for an ISSUE owner only (a note holds no evidence),
  # so `owner_id` here is an issue.
  private def freeze_from_links_card(lo : LinksOverlay) : Nil
    owner_kind, owner_id, cursor = lo.owner_kind, lo.owner_id, lo.selected
    back = -> { open_links_overlay(owner_kind, owner_id, cursor: cursor) }
    res = lo.selected_link
    snap = res && !res.stale? ? evidence_snapshot(res.link.ref_kind, res.link.ref_id) : nil
    if res && res.stale?
      @toast = "#{res.label} — nothing left to freeze"
    end
    unless snap
      back.call
      return
    end
    freeze_into_issue(owner_id, [snap], link: false, after: back) do |ids, refusal|
      refresh_issue_evidence(owner_id, ids.last?)
      refresh_evidence_markers
      @toast = refusal || "frozen as evidence ##{ids.last?} (#{Fmt.size(snap.bytes)}) on issue ##{owner_id}"
    end
  end

  # --- ↵ on an issue row of the LINK picker ---------------------------------

  # The one-verb path (#1038). Runs from the picker's `on_close` (a gate raises a confirm, and
  # the shell would tear down a modal opened from inside the picker's own commit), so `back`
  # restores the History drill-in the pick was made from. The snapshots were taken BEFORE the
  # picker opened (`link_attach`) — an exchange that changes while the card is up is exactly
  # the race a freeze exists to close.
  #
  # Every ref is linked either way. Only the ones that HAVE an exchange ride the freeze, and a
  # declined gate falls back to the plain link rather than abandoning the operator's act: they
  # answered "don't keep these bytes", not "don't file this link".
  private def link_and_freeze(issue_id : Int64, owner : String,
                              snaps : Array(LinkSnapshot), back : Proc(Nil)) : Nil
    copies = snaps.compact_map(&.snapshot)
    none = [] of Int64
    if copies.empty?
      finish_link(issue_id, owner, snaps, none, nil)
      back.call
      return
    end
    declined = -> { finish_link(issue_id, owner, snaps, none, FREEZE_DECLINED) }
    freeze_into_issue(issue_id, copies, link: true, after: back, declined: declined) do |ids, refusal|
      finish_link(issue_id, owner, snaps, ids, refusal)
    end
  end

  FREEZE_DECLINED = "you chose not to keep the bytes"

  # Close the act and report it ONCE. The copies `write_frozen` managed carry their own link
  # (`freeze_evidence(link: true)`, one transaction); every other ref — never freezable, past
  # the refusal that stopped the batch, or frozen not at all — is linked here, so a quota wall
  # or a declined gate can never leave the operator with nothing.
  private def finish_link(issue_id : Int64, owner : String, snaps : Array(LinkSnapshot),
                          frozen : Array(Int64), refusal : String?) : Nil
    # `write_frozen` writes in order and stops at the first refusal, so the first `frozen.size`
    # freezable refs are the ones already linked; the rest still need their row.
    kept = 0
    plain = snaps.reject do |s|
      next false unless s.snapshot
      kept += 1
      kept <= frozen.size
    end
    live = plain.select { |s| !s.kind.flow? || !@session.store.flow_row(s.id).nil? }
    linked = frozen.size + @session.store.add_links(Store::LinkOwnerKind::Issue, issue_id, live.map(&.ref))
    refresh_link_owners(Store::LinkOwnerKind::Issue, issue_id)
    refresh_issue_evidence(issue_id, frozen.size == 1 ? frozen[0] : nil)
    refresh_evidence_markers unless frozen.empty?
    bytes = snaps.compact_map(&.snapshot)[0, frozen.size].sum(&.bytes)
    @toast = LinkOutcome.new(owner, snaps.size, linked, plain.size - live.size,
      frozen, bytes, refusal || unfrozen_reason(plain)).toast
  end

  # Why the refs that were not frozen were not. The FIRST refusal stands for the set — they
  # are nearly always the same sentence (a marked page of pending flows), and a toast is one
  # line. nil when there is nothing to explain.
  private def unfrozen_reason(plain : Array(LinkSnapshot)) : String?
    plain.each { |s| s.refusal.try { |r| return r } }
    nil
  end

  # "+ New issue…": the gates are answered BEFORE the form opens, so the form's commit —
  # which already chains the open-vs-stay confirm — never has to raise a second modal, and
  # the operator is not asked to type a title only to have the answer thrown away. A declined
  # gate opens the form anyway, with no copies: the issue and its link are still wanted.
  private def open_issue_form_freezing(refs : Array({Store::LinkRefKind, Int64}),
                                       snaps : Array(LinkSnapshot), typed : String) : Nil
    with_freeze_gates(snaps.compact_map(&.snapshot), "a new issue") do |copies|
      open_issue_form_for_link(refs, typed, snapshots: copies)
    end
  end

  # The drift question then the byte cost, then `open` with whatever survived them — the same
  # order and the same chaining `freeze_into_issue` uses, for callers that open a FORM instead
  # of writing (the two "+ New issue…" paths: the link picker's create row and History's Add
  # issue). Both gates open a modal and return, so `open` runs from their `on_close`.
  private def with_freeze_gates(copies : Array(Evidence::Snapshot), dest : String,
                                &open : Array(Evidence::Snapshot) -> Nil) : Nil
    plain = -> { open.call([] of Evidence::Snapshot) }
    return plain.call if copies.empty?
    full = -> { open.call(copies) }
    total = copies.sum(&.bytes)
    cost = -> {
      if total >= Evidence::LARGE_BYTES
        confirm_freeze_cost(total, copies.size, dest, full, declined: plain)
      else
        full.call
      end
      nil
    }
    # BEFORE the byte cost, which is the same order `freeze_into_issue` uses: "these bytes are
    # not one exchange" has to be answered before "these bytes cost 3 MB", or the operator
    # pays attention to the size of a copy they would not have taken.
    gate_request_drift(copies, cost, declined: plain)
  end

  # --- shared core ----------------------------------------------------------

  # The snapshot for one ref, or nil with the reason toasted — `Evidence.snapshot_for`'s
  # sentences, the same ones the CLI and MCP print.
  private def evidence_snapshot(kind : Store::LinkRefKind, id : Int64) : Evidence::Snapshot?
    snap = Evidence.snapshot_for(@session.store, kind, id)
    if snap.is_a?(String)
      @toast = snap
      return nil
    end
    snap
  end

  # The batch form, for the History list's marked set. Every ref comes back (#1038) — with
  # its copy, or with the sentence that says why it has none — because the LINK is the act
  # and a ref with no exchange still gets one. Capped like every other per-flow batch verb:
  # each copy is a blocking write on the render loop. Above the cap nothing is frozen and
  # everything is still linked, which is one transaction whatever the count.
  private def evidence_snapshots(refs : Array({Store::LinkRefKind, Int64})) : Array(LinkSnapshot)
    capped = refs.size > 1 && batch_within_cap(refs.map { |_, id| id }, "freezing").nil?
    refs.map do |kind, id|
      # A fuzz or miner session was never a candidate (`Evidence.freezable?`), so it carries NO
      # refusal — only a missing copy. The operator did not ask for bytes there, and a toast
      # explaining that a mining run is a template plus a run would ride every single link
      # made from those two tabs.
      next LinkSnapshot.new(kind, id, nil, nil) unless Evidence.freezable?(kind)
      next LinkSnapshot.new(kind, id, nil, FREEZE_CAPPED) if capped
      res = Evidence.snapshot_for(@session.store, kind, id)
      res.is_a?(String) ? LinkSnapshot.new(kind, id, nil, res) : LinkSnapshot.new(kind, id, res, nil)
    end
  end

  FREEZE_CAPPED = "freezing is capped at #{BATCH_SUBTAB_CAP} flows"

  # Confirm-if-large, then write every snapshot, then `yield` the ids written and the
  # refusal that stopped the batch, if one did (never called when nothing was written and
  # nothing refused). `after` runs on EVERY exit — declined confirm included — and is where
  # a caller puts the modal back where it was.
  private def freeze_into_issue(issue_id : Int64, snaps : Array(Evidence::Snapshot), *,
                                link : Bool, after : Proc(Nil)? = nil, declined : Proc(Nil)? = nil,
                                &done : Array(Int64), String? -> Nil) : Nil
    total = snaps.sum(&.bytes)
    write = -> {
      ids, refusal = write_frozen(issue_id, snaps, link)
      done.call(ids, refusal) unless ids.empty? && refusal.nil?
      nil
    }
    cost = -> {
      if total >= Evidence::LARGE_BYTES
        confirm_freeze_cost(total, snaps.size, "issue ##{issue_id}", write, after: after, declined: declined)
      else
        write.call
        after.try(&.call)
      end
      nil
    }
    gate_request_drift(snaps, cost, after: after, declined: declined)
  end

  # The drift question (#1038), raised BEFORE the byte cost and only when a snapshot needs
  # it. A Repeater tab whose request was edited after its stored response arrived freezes a
  # pair that never happened, which is the one thing frozen evidence exists not to produce —
  # so the TUI, which has an operator looking at the tab, ASKS rather than refusing the way
  # `gori run evidence freeze` and MCP `freeze_evidence` do. Saying it is the point; the
  # answer is the operator's.
  #
  # Same modal chaining as `confirm_freeze_cost` and for the same reason (every freeze is
  # raised from inside a picker's or card's `on_close`): `accept` carries on down the chain
  # — which runs `after` itself — and a decline runs `declined` and then `after` here, so
  # the picker or drill-in is restored on exactly one path either way.
  private def gate_request_drift(snaps : Array(Evidence::Snapshot), accept : Proc(Nil), *,
                                 after : Proc(Nil)? = nil, declined : Proc(Nil)? = nil) : Nil
    drifted = snaps.count(&.request_drifted?)
    if drifted.zero?
      accept.call
      return
    end
    ov = Runner.drift_confirm(drifted, snaps.size)
    accepted = false
    ov.on_commit = -> { accepted = true; true }
    ov.on_close = -> {
      if accepted
        accept.call
      else
        declined.try(&.call)
        after.try(&.call)
      end
    }
    open_overlay(ov)
  end

  # The card itself, and its wording. A class method because `Runner.new` owns a terminal and
  # appears nowhere under spec/ — this is the seam the spec drives through `OverlayHarness`.
  #
  # `danger: false`, so ↵ is "freeze anyway": nothing is destroyed by answering yes, the copy
  # is simply less useful than it looks, and the operator may well want it anyway (an edited
  # request beside the response it PROVOKED a change in is a legitimate thing to keep, as
  # long as gori said what it is).
  def self.drift_confirm(drifted : Int32, total : Int32) : ConfirmDialog
    ConfirmDialog.new("REQUEST EDITED SINCE THIS RESPONSE",
      drift_confirm_message(drifted, total),
      confirm_label: "freeze anyway", danger: false)
  end

  def self.drift_confirm_message(drifted : Int32, total : Int32) : String
    subject = if total == 1
                "This tab's request was edited after the response\n" \
                "stored beside it was received."
              elsif drifted == total
                "All #{total} of these tabs had their request edited after\n" \
                "their stored response was received."
              else
                "#{drifted} of these #{total} copies come from a tab whose request\n" \
                "was edited after its stored response arrived."
              end
    "#{subject}\n\n" \
    "A frozen copy is meant to be ONE exchange. This one\n" \
    "would pair the EDITED request with the OLDER response.\n\n" \
    "Send the tab again to freeze a matching pair."
  end

  # The byte-cost question. Built on ConfirmDialog directly rather than `confirm`: that
  # helper restores the modal it was raised OVER, and every freeze is raised from inside a
  # picker's or card's on_close — whose restore is the caller's `after`, run on both
  # outcomes (or `declined`, run only when the operator says no), which `confirm`'s
  # accept-only action cannot express.
  private def confirm_freeze_cost(total : Int64, count : Int32, dest : String, write : Proc(Nil), *,
                                  after : Proc(Nil)? = nil, declined : Proc(Nil)? = nil) : Nil
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
      declined.try(&.call) unless accepted
      after.try(&.call)
    }
    open_overlay(ov)
  end

  # Write the copies in order; stop at the first refusal (a quota reached mid-batch would
  # refuse every later one the same way). Answers {ids written, the refusal or nil} — the
  # caller composes ONE toast from both, so a refusal is never overwritten by a success
  # line that does not mention it.
  private def write_frozen(issue_id : Int64, snaps : Array(Evidence::Snapshot), link : Bool) : {Array(Int64), String?}
    ids = [] of Int64
    snaps.each do |snap|
      id, status = @session.store.freeze_evidence(issue_id, snap, link: link)
      return {ids, freeze_refusal(issue_id, status)} unless status.ok?
      ids << id
      refresh_evidence_availability
      log_evidence_frozen(issue_id, id, snap)
    end
    {ids, nil}
  end

  # The tail every "issue created" toast carries when the form was opened holding copies
  # (#1038) — the link picker's "+ New issue…" and History's "Add issue" alike. Written now
  # that there is an issue to own them; the links were filed with the insert, so `link: false`
  # and no second row. Empty when the form carried nothing, which is every other create path
  # (`issues_new`, the retest Diff's file-and-stay).
  private def write_form_snapshots(issue_id : Int64, form : IssueForm) : String
    return "" if form.snapshots.empty?
    frozen, refusal = write_frozen(issue_id, form.snapshots, false)
    refresh_evidence_markers
    parts = [] of String
    parts << (frozen.size == 1 ? "frozen as evidence ##{frozen[0]}" : "#{frozen.size} frozen") unless frozen.empty?
    # The refusal rides the SAME toast: a "created and linked" line alone would read as
    # success for copies that were never written.
    parts << "not frozen: #{refusal}" if refusal
    parts.empty? ? "" : " · #{parts.join(" · ")}"
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
