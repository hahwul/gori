require "../retest_overlay"
require "../../retest"

# Issue-linked retest (#1036) — reopens Gori::Tui::Runner (see tui/runner.cr for the event
# loop, Host facade, overlays and rendering).
#
# The RETEST card is a modal opened from the Issues detail. Every domain edge is injected
# here, so the card itself never touches the Store: adding a step (a Repeater picker, then a
# role picker, then the assertion prompt), editing one, reordering, removing, running, and
# opening the History flow one result row recorded.
#
# Each hand-off rides the base's nested-modal seam (`Overlay#on_close`) rather than a
# shell-side flag: a key arms `pending`, the shell drops the card, and `on_close` puts the
# next modal up in its place — the pattern `open_links_overlay` documents. The chain always
# ends by REOPENING this card at the cursor it left, so a three-step add does not feel like
# three separate errands.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- the gates the IssuesDetail verbs read -------------------------------

  def issue_retest_available? : Bool
    !issues_controller.view.detail_issue.nil?
  end

  # space → "Retest…" on the Issues detail.
  def issue_retest : Nil
    issue = issues_controller.view.detail_issue || return
    open_retest_overlay(issue.id)
  end

  # --- the card -------------------------------------------------------------

  # `mode`/`cursor` restore where the operator was when the card is rebuilt after a
  # sub-modal — the `open_links_overlay(cursor:)` convention.
  def open_retest_overlay(issue_id : Int64, mode : Symbol = :steps, cursor : Int32 = 0) : Nil
    issue = @session.store.get_issue(issue_id)
    return (@toast = "issue ##{issue_id} no longer exists") unless issue
    ov = RetestOverlay.new(issue_id, issue.title)
    load_retest_card(ov)
    ov.restore_cursor(mode, cursor)
    ov.on_move = ->(delta : Int32) { nudge_retest_step(ov, delta) }
    ov.on_stop = -> { issues_controller.stop_retest }
    ov.on_close = -> { retest_hand_off(ov) }
    open_overlay(ov)
  end

  # Push the current plan + the rows to show into the card. While a run is in flight the
  # RESULTS half shows the LIVE rows (converted to the stored shape) rather than the last
  # run's: a card that kept showing the previous verdict while sends were going out would be
  # describing a run that is no longer the current answer.
  private def load_retest_card(ov : RetestOverlay) : Nil
    store = @session.store
    id = ov.issue_id
    planned = Retest.plan(store, id)
    running = issues_controller.retest_running_issue == id
    if running
      ov.load(planned, nil, live_retest_rows(id))
      ov.set_running(true, issues_controller.retest_progress_line)
    else
      run = store.last_retest_run(id)
      ov.load(planned, run, run ? store.retest_run_steps(run.id) : [] of Store::RetestRunStep)
      ov.set_running(false)
    end
  end

  # The in-flight rows, in the SAME shape the card draws a stored run in — so the RESULTS
  # half has one renderer and a live row cannot quietly look different from the row the same
  # step produces once persisted.
  private def live_retest_rows(issue_id : Int64) : Array(Store::RetestRunStep)
    issues_controller.retest_live_rows.map_with_index do |r, i|
      p = r.planned
      Store::RetestRunStep.new(0_i64, 0_i64, i + 1, p.step.role, p.step.ref_kind, p.step.ref_id,
        p.label, p.method, p.url, p.step.assertion, r.outcome, r.detail,
        r.observation.status, r.observation.duration_us, r.observation.bytes,
        r.observation.flow_id)
    end
  end

  # Runs after the shell has dropped the card (see `Overlay#on_close`). At most one of the
  # five is armed; esc arms none and the chain simply ends.
  private def retest_hand_off(ov : RetestOverlay) : Nil
    case ov.pending
    when :add              then open_retest_session_picker(ov)
    when :edit             then open_retest_role_picker(ov, ov.selected_step)
    when :remove           then remove_retest_step(ov)
    when :run              then start_retest_from_card(ov, allow_cleanup: false)
    when :run_with_cleanup then start_retest_from_card(ov, allow_cleanup: true)
    when :open_flow        then open_retest_result_flow(ov)
    end
  end

  private def reopen_retest(ov : RetestOverlay) : Nil
    open_retest_overlay(ov.issue_id, ov.mode, ov.selected)
  end

  # --- add: pick a Repeater session -----------------------------------------

  # The same sub-tab picker the LINKS card adds a repeater with, so "which session" is one
  # list in both places. A project with no sessions is said out loud and pops straight back.
  private def open_retest_session_picker(ov : RetestOverlay) : Nil
    rows = repeater_controller.subtab_search_rows
    if rows.empty?
      @toast = "no repeater sessions — send a request to the Repeater first"
      return reopen_retest(ov)
    end
    sp = SubtabPicker.new("PICK REPEATER FOR RETEST", rows, action: "add")
    picked = nil.as(Int64?)
    sp.on_commit = -> {
      if idx = sp.selected_index
        if rid = repeater_controller.db_id_at(idx)
          picked = rid
        else
          @toast = "session not persisted"
        end
      end
      true
    }
    sp.on_close = -> {
      if rid = picked
        open_retest_role_picker(ov, nil, add_repeater_id: rid)
      else
        reopen_retest(ov)
      end
    }
    open_overlay(sp)
  end

  # --- role, then assertion --------------------------------------------------

  RETEST_ROLE_KEYS = {'s', 'b', 'v', 'c', 'x'}

  # `step` is the step being edited (nil for an add); `add_repeater_id` the session an add
  # just picked. Exactly one is set.
  private def open_retest_role_picker(ov : RetestOverlay, step : Retest::Planned?,
                                      add_repeater_id : Int64? = nil) : Nil
    if step.nil? && add_repeater_id.nil?
      return reopen_retest(ov)
    end
    current = step.try(&.step.role) || Store::RetestRole::Variant
    choices = Store::RetestRole.values.map_with_index do |role, i|
      ChoicePicker::Choice.new("#{role.label.ljust(9)} #{retest_role_blurb(role)}",
        RETEST_ROLE_KEYS[i]?, retest_role_color(role), role.value)
    end
    picker = ChoicePicker.new(step ? "STEP ROLE" : "NEW STEP — ROLE", choices, current.value, :retest_role)
    chosen = nil.as(Store::RetestRole?)
    picker.on_commit = -> {
      chosen = Store::RetestRole.from_value(picker.selected_value)
      true
    }
    picker.on_close = -> {
      if role = chosen
        open_retest_assertion_prompt(ov, step, role, add_repeater_id)
      else
        reopen_retest(ov)
      end
    }
    open_overlay(picker)
  end

  private def retest_role_blurb(role : Store::RetestRole) : String
    case role
    in .setup?    then "establish the precondition (a failure here halts the measurement)"
    in .baseline? then "the anchor body:same / body:diff compare against"
    in .variant?  then "the case under test"
    in .control?  then "the negative case"
    in .cleanup?  then "undo (skipped after a refused send unless allowed)"
    end
  end

  private def retest_role_color(role : Store::RetestRole) : Color
    case role
    in .setup?, .cleanup? then Theme.muted
    in .baseline?         then Theme.syn_header
    in .variant?          then Theme.accent
    in .control?          then Theme.text
    end
  end

  # The assertion is typed, not picked: the grammar's whole point is that one line says both
  # what to look at and what it should be (`json:data.role=admin`), and a picker would have
  # to ask for the path in a prompt anyway. The card carries the accepted forms and validates
  # live; an unparseable one keeps it OPEN with the parser's own sentence as the toast —
  # never silently stored, which is how a step would end up asserting nothing.
  private def open_retest_assertion_prompt(ov : RetestOverlay, step : Retest::Planned?,
                                           role : Store::RetestRole,
                                           add_repeater_id : Int64?) : Nil
    initial = step.try(&.step.assertion) || ""
    prompt = RetestAssertOverlay.new(step ? "EXPECTED RESULT" : "NEW STEP — EXPECTED RESULT",
      retest_assert_subject(step, role, add_repeater_id), initial)
    committed = false
    prompt.on_commit = -> {
      parsed = Retest::Assertion.parse(prompt.value)
      if parsed.is_a?(String)
        # First line only: the parser's long form lists every accepted spelling, which the
        # card itself already shows.
        @toast = parsed.lines.first.strip
        false
      else
        committed = true
        apply_retest_step(ov, step, role, add_repeater_id, parsed.to_s)
        true
      end
    }
    prompt.on_close = -> { reopen_retest(ov) unless committed }
    open_overlay(prompt)
  end

  # `baseline · GET https://a.test/me` — which step the card is about, resolved from whichever
  # end is set (an edit has the step, an add has only the session it just picked).
  private def retest_assert_subject(step : Retest::Planned?, role : Store::RetestRole,
                                    add_repeater_id : Int64?) : String
    if s = step
      return "#{role.label} · #{s.method} #{s.url}"
    end
    return role.label unless rid = add_repeater_id
    rec = @session.store.get_repeater(rid)
    return "#{role.label} · repeater ##{rid}" unless rec
    label = rec.name.presence || "repeater ##{rid}"
    "#{role.label} · #{label} → #{rec.target}"
  end

  # The write, shared by add and edit. Reopening the card is what makes the three-modal
  # chain land back where it started; a failed write says so and still reopens, so the
  # operator sees the plan that actually exists rather than the one they typed.
  private def apply_retest_step(ov : RetestOverlay, step : Retest::Planned?,
                                role : Store::RetestRole, add_repeater_id : Int64?,
                                assertion : String) : Nil
    store = @session.store
    if rid = add_repeater_id
      _, status = store.add_retest_step(ov.issue_id, role, Store::LinkRefKind::Repeater, rid, assertion)
      @toast = case status
               in .ok?         then "retest step added"
               in .issue_gone? then "issue ##{ov.issue_id} was deleted — nothing added"
               in .step_gone?  then "the step disappeared before it could be written"
               in .busy?       then "nothing added (project busy)"
               end
    elsif s = step
      @toast = case store.update_retest_step(s.step.id, role: role, assertion: assertion)
               in .ok?                      then "retest step updated"
               in .issue_gone?, .step_gone? then "that step was deleted — nothing updated"
               in .busy?                    then "NOT updated (project busy)"
               end
    end
    refresh_issue_retest_summary
    reopen_retest(ov)
  end

  # --- reorder and remove ----------------------------------------------------

  # ⇧J / ⇧K, in place: the card stays up (reordering is a repeatable edit), so this writes
  # and pushes the new plan straight back rather than going through the hand-off seam.
  private def nudge_retest_step(ov : RetestOverlay, delta : Int32) : Nil
    step = ov.selected_step || return
    target = step.step.position + delta
    return if target < 1 || target > ov.steps.size
    case @session.store.move_retest_step(step.step.id, target)
    in .ok?                      then nil
    in .issue_gone?, .step_gone? then return (@toast = "that step was deleted")
    in .busy?                    then return (@toast = "NOT moved (project busy)")
    end
    load_retest_card(ov)
    ov.set_selected(target - 1)
  end

  # No confirm: a step is a line of a test plan, re-added in three keystrokes, and nothing
  # it references is touched. The `d` that DOES ask on this tab is the issue delete.
  private def remove_retest_step(ov : RetestOverlay) : Nil
    step = ov.selected_step
    unless step
      return reopen_retest(ov)
    end
    @toast = case @session.store.remove_retest_step(step.step.id)
             in .ok?                      then "retest step removed"
             in .issue_gone?, .step_gone? then "that step was already gone"
             in .busy?                    then "NOT removed (project busy)"
             end
    refresh_issue_retest_summary
    reopen_retest(ov)
  end

  # --- running ---------------------------------------------------------------

  # `r`. A batch containing a state-changing method is CONFIRMED first, with the exact
  # request count — the rule every other active tool on this surface follows, and the one
  # the issue names. An all-safe batch runs straight away: a dialog that always fires trains
  # the operator to answer without reading it.
  private def start_retest_from_card(ov : RetestOverlay, allow_cleanup : Bool) : Nil
    issue_id = ov.issue_id
    planned = Retest.plan(@session.store, issue_id)
    if planned.empty?
      @toast = "no retest steps — press a to add one"
      return reopen_retest(ov)
    end
    unless planned.any?(&.runnable?)
      @toast = "no runnable step — every step's Repeater session is gone"
      return reopen_retest(ov)
    end
    unless note = Retest.confirm_note(planned)
      launch_retest(issue_id, planned, allow_cleanup)
      return
    end
    # The dialog SAYS which of the two run keys raised it, because the difference is what
    # happens after a refusal and that is the one thing the operator is agreeing to here.
    # `confirm` is a two-button card, so the choice is made by the key (`r` / `⇧R`) rather
    # than by a third button — and the default, `r`, is the conservative one the issue
    # requires.
    tail = allow_cleanup ? "Cleanup steps WILL be sent even if gori refuses a send (⇧R)." : "Cleanup steps are not sent if gori refuses a send."
    confirm("RUN RETEST", "#{note}\n\nRun it now? #{tail}",
      confirm_label: "run", cancel_label: "cancel", danger: true) do
      launch_retest(issue_id, planned, allow_cleanup)
    end
  end

  # Land on RESULTS: the operator asked to run, and the rows are the answer. The card fills
  # in as the drain delivers them.
  #
  # A REFUSED start (another run already in flight) still reopens the card — on STEPS, where
  # it was. `start_retest` has already said why, and dropping the operator back to the bare
  # detail would read as "the key did nothing".
  private def launch_retest(issue_id : Int64, planned : Array(Retest::Planned),
                            allow_cleanup : Bool) : Nil
    started = issues_controller.start_retest(issue_id, planned, allow_cleanup)
    open_retest_overlay(issue_id, started ? :results : :steps, 0)
  end

  # ↵ on a RESULT row: the History flow THIS send recorded — the exact response the row
  # reports, which the Repeater tab no longer holds (its own response was never overwritten;
  # see `Retest::LiveBackend`). A row from `--no-record-history` has none and says so.
  private def open_retest_result_flow(ov : RetestOverlay) : Nil
    row = ov.selected_result
    unless row && (fid = row.flow_id)
      @toast = "this step's send was not recorded in History"
      return reopen_retest(ov)
    end
    if history_controller.view.open_detail_id(fid, @session.store)
      @active_tab = :history
      @focus = :body
      @overlay = OverlayKind::Detail
      @toast = "flow ##{fid} — the response this retest step reported"
    else
      @toast = "flow ##{fid} is no longer captured"
      reopen_retest(ov)
    end
  end

  # --- live updates ----------------------------------------------------------

  # Drained on the render loop. Pushes the live rows into an OPEN retest card, and reloads
  # it from the store once the run has ended so the card shows the persisted summary rather
  # than a transient copy of it.
  def drain_retest_run : Bool
    drained = issues_controller.drain_retest
    finished = issues_controller.take_retest_finished
    ov = active_overlay.as?(RetestOverlay)
    if ov && (drained || finished)
      load_retest_card(ov)
    end
    refresh_issue_retest_summary if finished
    drained || !finished.nil?
  end

  # The Issue detail's one-line retest state. Recomputed on every write and at the end of a
  # run — never per repaint, for the reason `Issue#cvss_score` is resolved once.
  def refresh_issue_retest_summary : Nil
    issues_controller.view.refresh_retest_summary(@session.store)
  end
end
