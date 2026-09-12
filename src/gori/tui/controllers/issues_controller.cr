require "../tab_controller"
require "../issues_view"
require "../clipboard"
require "../../store"
require "../../issues_export"
require "../../hotkeys"
require "../../evidence"
require "../../retest"
require "../../retest/live_backend"
require "../../host_overrides"
require "../../outbound"
require "../../settings"

module Gori::Tui
  # The Issues tab: the triage list + an issue's detail (with an inline notes
  # editor) + Markdown/JSON export. Owns IssuesView. The "new/edit issue" FORM is
  # a shell overlay (@overlay == :issue_new), so it stays in the Runner; the three
  # cross-tab jumps (issue → its flow in History, issue → Repeater, new-from-flow)
  # are shell mediators. Detail notes use READ/INS (like Notes): the shell routes
  # detail keys here before the focus ring when an issue is open.
  class IssuesController < TabController
    def initialize(host : Host)
      super(host)
      @issues = IssuesView.new
      # The peer notes value an `esc` overwrite is currently armed against — see
      # `save_notes_or_report`. nil when nothing is armed, which is every state but the one
      # right after a refusal the operator has read.
      @notes_overwrite_armed = nil.as(String?)
    end

    # Would `commit` REFUSE the open Issues writeup right now? Asked by the quit and
    # leave-project prompts, which are the two places the buffer dies for good and the only two
    # where a status line arrives too late to be read (the loop breaks immediately after
    # `commit_pending_edits`).
    #
    # Gated on INS exactly as `commit` is, so the prompt describes what will actually happen. A
    # dirty buffer the NOR/INS chip stepped out of is dropped at quit too — but by the INS gate,
    # not by this conflict, and a line blaming a peer for it would send the operator looking for
    # a collision that is not the reason. That silence is older than this guard and is its own
    # question.
    #
    # `@host.session.store`, not a cached row: the answer has to be about the version on disk at
    # the moment the operator is being asked, which is the moment they can still act on it.
    def notes_conflict_pending? : Bool
      return false unless @issues.notes_insert_mode?
      @issues.notes_conflict?(@host.session.store)
    end

    def view : IssuesView
      @issues
    end

    # --- retest (#1036) ------------------------------------------------------
    #
    # A run is a background fiber whose rows arrive through `@retest_events` and are drained
    # on the MAIN fiber by `drain_retest` — the shape `AuthorizeController` uses, and for the
    # same reason: the sends are seconds long and the render loop must not block on them.
    #
    # The state lives on the CONTROLLER and not on the card, because the card is a modal the
    # operator can close (its own hint says the run continues). A run parked on the overlay
    # would be unreachable the moment they pressed esc — and its `finish` would then never
    # clear the job in the bottom bar.

    # One message from the run fiber. `gen` stamps the BATCH it belongs to, so a row from a
    # superseded run cannot land in the next one's table. `done` is the terminal marker the
    # fiber always sends last (from an `ensure`), and it — not a row count — is what says the
    # fiber has exited.
    record RetestEvent,
      gen : Int32,
      result : Retest::StepResult? = nil,
      report : Retest::RunReport? = nil,
      error : String? = nil,
      done : Bool = false

    @retest_events = Channel(RetestEvent).new(64)
    @retest_gen = 0
    @retest_active_gen = nil.as(Int32?)
    @retest_issue_id = nil.as(Int64?)
    @retest_rows = [] of Retest::StepResult
    @retest_planned = 0
    @retest_stop = false
    @retest_job_id = nil.as(Int32?)
    # Set by the drain when a run ENDS, read once by the shell so the open card can reload
    # the persisted rows. A flag rather than a callback: the drain runs on the render loop
    # and must not reach into overlay state itself.
    @retest_finished = nil.as(Int64?)

    def retest_running? : Bool
      !@retest_active_gen.nil?
    end

    # Which issue's retest is in flight — the card refuses to edit or re-run while its own
    # issue is running, and says so for someone else's.
    def retest_running_issue : Int64?
      @retest_issue_id if retest_running?
    end

    # The rows the live run has produced so far, for the card's RESULTS half while it fills.
    def retest_live_rows : Array(Retest::StepResult)
      @retest_rows
    end

    def retest_progress_line : String
      return "" unless retest_running?
      "sending step #{{@retest_rows.size + 1, @retest_planned}.min} of #{@retest_planned}…"
    end

    # The issue whose run just ended, consumed once.
    def take_retest_finished : Int64?
      id = @retest_finished
      @retest_finished = nil
      id
    end

    def stop_retest : Nil
      return unless retest_running?
      @retest_stop = true
      @host.status("retest: stopping after the current step…")
    end

    # Start a run on a background fiber. Returns false when one is already in flight — a
    # second run against the same target while the first is mid-sequence would interleave
    # two states on the origin and report both.
    #
    # Everything the fiber needs is read HERE, on the main fiber: the scope (`Outbound`), the
    # project's live `HostOverrides` (the one mutex-guarded instance the Project tab edits in
    # place, so an override fixed a moment ago is honoured — the distinction
    # `Authorize::Engine.live` documents), and the plan itself. The fiber must not touch a
    # view.
    def start_retest(issue_id : Int64, planned : Array(Retest::Planned),
                     allow_cleanup : Bool = false) : Bool
      if retest_running?
        @host.status("a retest is already running")
        return false
      end
      if planned.empty?
        @host.status("this issue has no retest steps")
        return false
      end
      session = @host.session
      outbound = Gori::Outbound.interactive(session.scope)
      overrides = session.host_overrides
      verify = Settings.verify_upstream?
      @retest_stop = false
      @retest_rows = [] of Retest::StepResult
      @retest_planned = planned.size
      @retest_issue_id = issue_id
      gen = (@retest_gen += 1)
      @retest_active_gen = gen
      noun = "#{planned.size} step#{planned.size == 1 ? "" : "s"}"
      @retest_job_id = @host.jobs.start(:retest, "issue ##{issue_id} · #{noun}",
        Jobs::Goto.new(:issues))
      @host.status("retest: running #{noun} for issue ##{issue_id}…")
      store = session.store
      events = @retest_events
      stop = -> { @retest_stop }
      spawn(name: "retest-run") do
        backend = Retest::LiveBackend.new(store, outbound,
          issue_id: issue_id, surface: Gori::FlowSource::Surface::Tui,
          overrides: overrides, verify: verify)
        report = Retest.execute(store, planned, backend,
          issue_id: issue_id, surface: Gori::FlowSource::Surface::Tui,
          allow_cleanup: allow_cleanup, stop: stop,
          on_step: ->(r : Retest::StepResult) { events.send(RetestEvent.new(gen, result: r)); nil })
        events.send(RetestEvent.new(gen, report: report))
      rescue ex
        # Anything the engine's own per-step handling cannot see — building the backend, a
        # store that closed under us. Without this the fiber would die before its marker and
        # leave the tab wedged as "running".
        events.send(RetestEvent.new(gen, error: ex.message || "retest run failed"))
      ensure
        # ALWAYS last, and there is exactly one sender, so the channel's FIFO order puts it
        # after every row it follows.
        events.send(RetestEvent.new(gen, done: true))
      end
      true
    end

    # How many rows one drain applies. A retest is a handful of steps, so this is only a
    # ceiling against a pathological plan holding the render loop.
    RETEST_DRAIN_CAP = 64

    # Main-fiber drain; true when anything arrived (the render loop redraws on it).
    def drain_retest : Bool
      drained = false
      RETEST_DRAIN_CAP.times do
        break unless ev = next_retest_event
        drained = true
        next unless ev.gen == @retest_active_gen # a superseded run's trailing rows
        apply_retest_event(ev)
      end
      drained
    end

    # One queued event if any, else nil — the non-blocking channel poll
    # `AuthorizeController#next_outcome` uses.
    private def next_retest_event : RetestEvent?
      select
      when ev = @retest_events.receive
        ev
      else
        nil
      end
    end

    private def apply_retest_event(ev : RetestEvent) : Nil
      if r = ev.result
        @retest_rows << r
        return
      end
      if msg = ev.error
        @host.status("retest: #{msg}")
        @retest_job_id.try { |id| @host.jobs.finish(id, :error, msg) }
        return
      end
      if report = ev.report
        finish_retest(report)
        return
      end
      return unless ev.done
      # The marker with no report before it: the fiber died on the rescue path, which
      # already reported. Clear the run so the tab is not wedged.
      @retest_active_gen = nil
      @retest_finished = @retest_issue_id
      @retest_job_id.try { |id| @host.jobs.finish(id, :error, "retest did not finish") unless @host.jobs.errored?(id) }
      @retest_job_id = nil
    end

    private def finish_retest(report : Retest::RunReport) : Nil
      @retest_active_gen = nil
      @retest_finished = @retest_issue_id
      line = "retest: #{report.verdict.label.upcase} — #{Retest.summary_line(report.tally)}"
      line += " (the summary was NOT saved)" unless report.stored.ok?
      @host.status(line)
      @retest_job_id.try do |id|
        @host.jobs.finish(id, report.verdict.pass? ? :done : :error, Retest.summary_line(report.tally))
      end
      @retest_job_id = nil
    end

    # `Runner#stop_all_jobs` — the project-level halt. The fiber owns its own sockets and
    # checks the flag between steps, so this is the same cooperative stop the card's `s` is.
    def halt_retest : Nil
      @retest_stop = true if retest_running?
    end

    def tab : Symbol
      :issues
    end

    def command_scope : Verb::Scope
      @issues.detail_open? ? Verb::Scope::IssuesDetail : Verb::Scope::Issues
    end

    # PageUp/PageDown/Home/End over the issues list (view clamps the selection). The
    # detail view is a short title/notes/links form with no vertical body to page, so
    # leave those keys untouched when it's open.
    def body_scroll(delta : Int32) : Bool
      return false if @issues.detail_open?
      end_range_gesture unless preview_scroll_focused? # a page key is cursor nav, like ↑/↓
      @issues.move(delta)
      true
    end

    def page_rows : Int32?
      @issues.detail_open? || preview_scroll_focused? ? nil : @issues.list_page_rows
    end

    # ⇥ / ⇧⇥ across this tab's panes. The focus-ring hook — a `key.tab?` arm in
    # `handle_body_key` never ran (the Runner claims ⇥ for the ring first), so the
    # `↹ preview` the hint promised was mouse-only.
    #
    # An open DETAIL walks its own two panes (`IssuesView#step_detail_focus`) and never
    # answers false. It used to answer false unconditionally, which sent focus to the tab bar
    # while `handle_detail_key` stayed gated on `@focus == :body` — one ⇥ and the detail was
    # still on screen with every key dead, back keys included. On the LIST page false is
    # correct and is what returns focus to the tab bar off either end.
    def pane_advance(dir : Int32) : Bool
      return @issues.step_detail_focus(dir) if @issues.detail_open?
      return false unless @issues.preview_enabled?
      @issues.step_preview_focus(dir)
    end

    def body_badge : Symbol
      # INS wins over the drill-in: what the keys under your fingers DO outranks where you
      # are, and it is also what `body_editor?` (paste routing, the copy verbs' INS gate)
      # reads this for.
      return :editor if @issues.notes_insert_mode?
      @issues.detail_open? ? :detail : :body
    end

    def body_hint(focus : Symbol) : String
      reg = @host.session.registry
      filt = Hotkeys.binding_label(reg, "issues.filter", "/")
      nnew = Hotkeys.binding_label(reg, "issues.new", "n")
      # ⇧X is now named in the MARKS state only — see the note under `export` below for why it
      # left the three list lines, and the marks branch for why "clear ALL" has to stay said
      # there in words.
      clear = Hotkeys.binding_label(reg, "issues.clear", "⇧X")
      # ⇧E is the one key the triage loop ENDS on, and the strip named it nowhere at any
      # width — the space menu was its only advertisement, which cost `Space E` every time.
      # It takes ⇧X's slot rather than joining it: these lines are already the longest on the
      # tab, and of the two, the destructive one is the one with somewhere else to live (the
      # space menu's WIPE group, where a delete is read deliberately rather than reached for).
      # That reverses #899's call for this list alone; ⇧X stays named in the MARKS state
      # below, where "clear ALL" is the sentence that keeps the two meanings apart.
      export = Hotkeys.binding_label(reg, "issues.export-key", "⇧E")
      if @issues.detail_open?
        # Dropped whole when there is nowhere to step — see DrillIn::Host's `step_available?`.
        step = @issues.step_available? ? "{issue.next-item}/{issue.prev-item} issue · " : ""
        if @issues.notes_insert_mode?
          "type to edit · ⇧arrows select · ^Y copy · esc save · ^W discard"
        elsif @issues.notes_focused?
          keys("↑/↓ move · ⇧arrows select · {issue.copy} copy · {editor.insert}/↵ edit · #{step}space cmds · ↹/←/esc related")
        else
          # `↹/↓ notes` and nothing else for the way down: `i` no longer enters the editor
          # from here (it prints `insert_key_refusal` instead, like the five workbench tabs
          # with a read-only pane beside an editor), and ↵ in this pane shows the selected
          # RELATED row's exchange. Naming either as the route into NOTES was wrong.
          related_hint(step)
        end
      elsif @issues.querying?
        "type to filter · ↹ complete · ↓ list · ? reference · ↵ apply · esc clear"
      elsif @issues.preview_enabled? && @issues.preview_focus == :preview
        "↑/↓ scroll preview · ↹ list · ↵ open full · #{export} export · space cmds · esc tabs"
      elsif @issues.mark_count > 0
        # Marks re-point what `space` acts on AND take over esc (handle_body_key shadows
        # issues.leave while a set is live), so the standing "esc tabs" hint would be wrong.
        #
        # `clear ALL` in capitals, and `esc drops marks` spelled out, because this is the one
        # state where the two words mean different sets: `space`/`d` act on the marks, ⇧X does
        # not — it wipes the project. A bare "clear" here would read as "clear the marked ones".
        mark = Hotkeys.binding_label(reg, "issues.mark-toggle", "t")
        "#{@issues.mark_count} marked · #{mark} mark · ⇧↑/⇧↓ range · space acts on marks · #{clear} clear ALL · esc drops marks"
      elsif @issues.preview_enabled?
        "↑/↓ move · ↵ open · ↹ preview · #{filt} filter · #{nnew} new · #{export} export · space cmds · esc tabs"
      else
        "↑/↓ move · ↵ open · #{filt} filter · #{nnew} new · #{export} export · space cmds · esc tabs"
      end
    end

    # The detail's strip while the RELATED card owns the keyboard. Three of its tokens are
    # read off the row under the cursor rather than printed unconditionally:
    #
    #   * `f freeze` — named only when the verb is offered. A FROZEN, stale, fuzz or miner row
    #     has nothing to freeze, and `Hotkeys.expand` never consults a gate; the same
    #     drop-the-token rule `step` follows.
    #   * `s source` — the same rule: with no RELATED row under the cursor there is nothing to
    #     go to, and the verb refuses.
    #   * `↵ view` / `↵ open session` — ↵ SHOWS the row's exchange in place, on every kind that
    #     has one. A fuzz or miner row has none (a session is a template plus a run), so there ↵
    #     opens the session and the token says which of the two it is about to do.
    #
    # The `o flow` token is gone with the verb: the primary flow is the card's FIRST ROW now,
    # and `s source` above is what opens it in History. `r repeater` stays and reads as a
    # row verb like the three beside it — it sends the row under the cursor, falling back to
    # the first flow row (see `Runner#issue_repeater_flow`).
    private def related_hint(step : String) : String
      freeze = related_freezable? ? "{issue.freeze-link} freeze · " : ""
      goto = @issues.selected_related ? "{issue.goto-link} source · " : ""
      open = related_session? ? "↵ open session" : "↵ view"
      keys("↑/↓ links · #{open} · #{goto}#{freeze}{issue.repeater-flow} repeater · ↹/↓ notes · #{step}space cmds · ←/esc back")
    end

    # The RELATED cursor sits on a live flow/repeater row that still resolves — the gate
    # `issue.freeze-link` is registered with (`Runner#issue_related_freezable?`), read here
    # for the hint so the strip cannot promise a key the verb refuses.
    private def related_freezable? : Bool
      res = @issues.selected_resolved_link || return false
      !res.stale? && Evidence.freezable?(res.link.ref_kind)
    end

    # A LIVE fuzz/miner row — the one RELATED kind whose ↵ navigates rather than showing an
    # exchange, because a session has none to show. Read off the same `Evidence.freezable?`
    # the Runner branches on, so the strip and the key cannot disagree.
    private def related_session? : Bool
      res = @issues.selected_resolved_link || return false
      !Evidence.freezable?(res.link.ref_kind)
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      # An open DETAIL is two cards that light their OWN borders (RELATED / NOTES), so the
      # shell frame stands down while one is up: gilding it as well read as "the whole tab is
      # focused" and left the card that actually owns the keyboard with nothing to distinguish
      # it. The LIST page is the other case — neither the list nor its preview draws a card of
      # its own, so the shell outline IS the list's border and keeps the gold.
      @issues.step_keys = step_key_labels if @issues.detail_open?
      shell = BodyChrome.shell_focused(focus, multi_pane: @issues.detail_open? && detail_card_lit?(rect))
      BodyChrome.framed(screen, rect, shell) { |inner| @issues.render(screen, inner, focused: focused) }
    end

    # The effective chords for the item step — see HistoryController#step_key_labels for why
    # each half is read from its own verb rather than derived from the other.
    private def step_key_labels : {String, String}
      reg = @host.session.registry
      {Hotkeys.binding_label(reg, "issue.next-item", DrillIn::NEXT_KEY),
       Hotkeys.binding_label(reg, "issue.prev-item", DrillIn::PREV_KEY)}
    end

    # Is the card that OWNS the keyboard actually on screen to light? Handing the shell frame
    # over assumes one of the two always is, and under nine interior rows that is false:
    # `detail_split` drops RELATED entirely there (`rel_h = 0`) and the detail OPENS on
    # RELATED, so a body of 8 rows — `Layout.usable?` admits a 16-row terminal — would have
    # shown the shell grey, RELATED undrawn and NOTES resting, with nothing gold anywhere
    # while the body held the keyboard. Worse than the whole-tab gild it replaces, and it
    # healed on the first ⇥, which reads as "the tab was dead until I moved".
    #
    # Measured with `Frame.card`'s own refusal (`render_related_card` / `render_notes_card`
    # return on the same test), so this cannot drift from what was painted.
    private def detail_card_lit?(rect : Rect) : Bool
      inner = detail_inner(rect)
      card = @issues.notes_focused? ? @issues.notes_card_rect(inner) : @issues.links_card_rect(inner)
      card.h >= 2 && card.w >= 2
    end

    # The DETAIL's rect inside the drill-in. `frame_inner` alone stopped being the answer
    # once the list rail could sit above it, and every detail hit-test in this file measures
    # against THIS — a card drawn under the rail and clicked as though it were not there is a
    # dead row, which is the failure `detail_split`'s own comment exists to prevent.
    private def detail_inner(rect : Rect) : Rect
      @issues.detail_body_rect(BodyChrome.frame_inner(rect))
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # Which pane the last press inside an open detail landed on. `supports_drag?` is asked with
    # NO coordinates — `drag_press_target?` runs it immediately after the click — and the drag
    # cannot be resolved from the CURRENT pointer either, since extending a notes selection
    # means dragging past the card's edge. So the click records where it began.
    #
    # Not the focus flag, which was the first spelling of this guard and does not cover the
    # state it was written for: a press on RELATED that asks to leave the editor and is REFUSED
    # (a peer rewrote the notes) leaves focus and INS on NOTES, so the motion after it would
    # extend the editor's selection from rows the pointer never touched — in the one state
    # where the operator has just been told their text is at risk.
    @detail_press = :none

    # The NOTES pane of an open issue only: the issue LIST selects rows. No focus/save side
    # effects — the press that began the gesture already ran them.
    def supports_drag? : Bool
      @issues.detail_open? && @detail_press == :notes
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless supports_drag?
      @issues.notes_drag_to_cursor(detail_inner(rect), mx, my)
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless @issues.detail_open?
      inner = detail_inner(rect)
      return double_click_related(inner, mx, my) if @issues.links_card_rect(inner).contains?(mx, my)
      # The NOTES BODY, and only it. `notes_select_word` forces INSERT and hit-tests nothing,
      # so a pair of presses on the meta block up top (title, chips, timestamps, evidence)
      # used to drop the operator into the editor with a word selected at clamped
      # coordinates — a gesture on a read-only row that starts an edit somewhere else.
      return false unless @issues.notes_body_rect(inner).contains?(mx, my)
      @issues.notes_select_word(inner, mx, my)
    end

    # A double-click on the RELATED card. On a row it is `issue.open-link` — the row's own ↵,
    # which CROSSES TABS, so it is the double-click here for the same reason the Sitemap /
    # Activity / Discover rows open on one. The first press of the pair already selected the
    # row and focused the card; off a row there is nothing left to do, and the press is still
    # consumed so it cannot fall through and be read as a second single click.
    private def double_click_related(inner : Rect, mx : Int32, my : Int32) : Bool
      # INS still on means the FIRST press of this pair asked to leave the editor and was
      # refused (a peer rewrote the notes) — see `leave_notes_editor`. Consume this one rather
      # than answering false: falling through to the ordinary click would run the save again,
      # and a refusal ARMS the next attempt, so a fast double-click would overwrite the peer
      # without the operator ever reading the line that warned them.
      return true if @issues.notes_insert_mode?
      if row = @issues.links_row_at(inner, mx, my)
        @issues.focus_links!
        @issues.select_link(row)
        @host.issue_open_link
      elsif row = @issues.links_gauge_row_at(inner, mx, my)
        # The gauge is a SCROLLBAR, not a row. A second press on it means what the first meant
        # — jump the cursor — and never "open", which is not a gesture a scrollbar has; without
        # this arm the pair simply died on the bare `true` below, indistinguishable from a row
        # that failed to open.
        @issues.focus_links!
        @issues.select_link(row)
      end
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      @detail_press = :none
      return handle_detail_click(inner, mx, my) if @issues.detail_open?
      @host.focus_body
      if @issues.preview_enabled? && @issues.preview_at?(inner, mx, my)
        @issues.set_preview_focus(:preview)
        return true
      end
      list_rect, _ = @issues.list_split(inner)
      # The list's scroll gauge on the frame's right hairline: jump the cursor to the row it
      # points at. Before the filter-bar arm, which has no `mx` bound of its own.
      if row = @issues.gauge_row_at(inner, mx, my)
        @issues.set_preview_focus(:list)
        @issues.select_index(row)
        return true
      end
      if my == list_rect.y && !@issues.querying?
        @issues.start_query
        return true
      end
      return true unless idx = @issues.list_row_at(inner, mx, my)
      @issues.set_preview_focus(:list)
      if idx == @issues.selected_index
        issues_open
      else
        end_range_gesture # a plain click collapses the range, same as a plain arrow
        @issues.select_index(idx)
      end
      true
    end

    # A click inside an open detail. BOTH cards are live: the RELATED rows take the cursor,
    # the NOTES body places the caret. It used to reach only NOTES — every cell of the RELATED
    # card was inert, so the pane the detail OPENS on could not be touched with the mouse at
    # all.
    private def handle_detail_click(inner : Rect, mx : Int32, my : Int32) : Bool
      # The detail is a body pane like any other, and this branch never took focus: with the
      # tab bar focused, a click placed the notes caret and then sent the typing to the bar.
      @host.focus_body
      rail = @issues.rail_rect(inner)
      inner = @issues.detail_body_rect(inner)
      # A rail row: open THAT issue, staying in the drill-in. The rail shows the list, so a
      # click on it means what a click on the list means.
      if i = DrillIn.rail_row_at(rail, mx, my)
        issue_step_item(i - @issues.rail_cursor)
        return true
      end
      # The crumb's `‹` — a real button now. Ahead of every pane hit-test, because it rides a
      # row nothing else in the drill-in claims (the frame's top edge, or the rail's divider)
      # and because "leave" must win over any stray column that also matches.
      if (c = @issues.detail_crumb) && Frame.crumb_hit_rect(inner, c).try(&.contains?(mx, my))
        # Persist first, and stay when that write is refused — leaving by pointer means what
        # `esc` means (`leave_notes_editor`). Without it this one gesture would be the only
        # way out of the detail that silently drops an unsaved writeup, which is exactly the
        # text a conflict refusal has just told the operator to look at.
        issue_close if leave_notes_editor
        return true
      end
      card = @issues.notes_card_rect(inner)
      # NOR/INS chip on the NOTES card border toggles insert. `↵` on the way IN, and on the way
      # out the `^W`-less half of `esc`: it drops to READ without saving, which is what makes
      # re-entry the ordinary way back into an edit in progress (see `enter_notes_insert!`,
      # which skips its re-seed over unsaved text for exactly this). Deliberately NOT
      # `leave_notes_editor` — that is `esc`, and this chip is the other gesture.
      if !card.empty? && Frame.mode_badge_hit(mx, my, card.y, card.right - 1, card.x + 7,
           @issues.notes_insert_mode?)
        if @issues.notes_insert_mode?
          @issues.exit_notes_insert!
        else
          @issues.enter_notes_insert!
        end
        return true
      end
      return true if click_related(inner, mx, my)
      notes_rect = @issues.notes_body_rect(inner)
      if notes_rect.contains?(mx, my)
        @detail_press = :notes # the motion that continues this press belongs to the editor
        @issues.notes_click_to_cursor(inner, mx, my)
      end
      true
    end

    # The RELATED card's own clicks: a link row (or the scroll gauge on its right border)
    # takes the cursor, and any other cell of the card just moves focus there — the pointer
    # twin of ⇥/esc, and the only affordance an issue with no links has at all. Answers
    # false when the pointer is not on the card, so NOTES still gets its click.
    private def click_related(inner : Rect, mx : Int32, my : Int32) : Bool
      card = @issues.links_card_rect(inner)
      return false unless card.contains?(mx, my)
      return true unless leave_notes_editor # refused save: the editor keeps the focus
      @issues.focus_links!
      if row = @issues.links_row_at(inner, mx, my) || @issues.links_gauge_row_at(inner, mx, my)
        @issues.select_link(row)
      end
      true
    end

    # Leaving the NOTES editor by POINTER means what `esc` means: persist, or report and stay.
    # Answers whether the editor is really done with — a conflict refusal keeps INS on, and a
    # click must not pull focus out from under text that was never written.
    private def leave_notes_editor : Bool
      return true unless @issues.notes_insert_mode?
      save_notes_or_report
      !@issues.notes_insert_mode?
    end

    def handle_wheel(step : Int32) : Bool
      if @issues.detail_open?
        if @issues.notes_insert_mode? || @issues.notes_focused?
          @issues.notes_scroll_wheel(step)
        else
          @issues.scroll_links_wheel(step)
        end
      else
        # Deliberately NOT end_range_gesture: a wheel reads as "scroll the viewport", not as
        # a selection gesture, so it must not destroy a mark set the way a cursor key does.
        @issues.move(step)
      end
      true
    end

    # Pointer-aware: the preview under the cursor scrolls without taking focus from the list.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      if @issues.detail_open?
        # Pointer-aware inside the detail too: RELATED scrolls under the pointer while the
        # NOTES editor keeps the keyboard, and vice versa. Off both cards (the meta block up
        # top) the focused pane still moves, which is what `handle_wheel` answers.
        inner = detail_inner(rect)
        return (@issues.scroll_links_wheel(step); true) if @issues.links_card_rect(inner).contains?(mx, my)
        return (@issues.notes_scroll_wheel(step); true) if @issues.notes_card_rect(inner).contains?(mx, my)
        return handle_wheel(step)
      end
      if @issues.preview_enabled? && @issues.preview_at?(rect.inset(1, 1), mx, my)
        @issues.wheel_preview(step)
      else
        @issues.move(step)
      end
      true
    end

    # esc clears the marks; Tab cycles list ↔ preview focus when that layout is active. Runs
    # BEFORE the Issues keymap, so the esc branch shadows issues.leave ONLY while marks are
    # set — with none set, esc still pops to the tab bar. (The `/` filter bar claims every
    # key ahead of this while it's up, so filter-esc is unaffected.)
    # The list's `/` query bar and the detail's NOTES editor in INS.
    def body_takes_text? : Bool
      @issues.querying? || @issues.notes_insert_mode?
    end

    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if @issues.detail_open?
      return false if ev.ctrl? || ev.alt?
      if ev.key.escape? && @issues.mark_count > 0
        @issues.clear_marks
        return true
      end
      false
    end

    def handle_detail_key(ev : Termisu::Event::Key) : Bool
      return false unless @issues.detail_open?
      key = ev.key
      c = ev.char || key.to_char
      if @issues.notes_insert_mode?
        return handle_notes_insert_key(ev, key, c)
      end
      if key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      if @issues.notes_focused?
        return handle_notes_read_key(ev, key, c)
      end
      false
    end

    # RELATED is a read-only pane sitting beside an editor, which is the exact shape the five
    # workbench tabs answer with a named refusal (`TabController#insert_key_refusal`). This one
    # used to claim `i` from ANY detail focus and drop straight into the notes editor, so the
    # Global `intercept.toggle` vanished on this tab with nothing said — the silent half of the
    # contradiction the other five had already been taught to speak.
    #
    # `i` from RELATED now does nothing loudly. That is #1051's grammar for this pane: ↵ shows
    # the row's exchange, `s` goes to its source, `f` freezes it — every key acts on the ROW
    # under the cursor, and dropping the cursor into another pane's editor was never part of
    # it. `↹`/`↓` is the way down, as the strip says.
    #
    # nil on the LIST (Global `i` still toggles intercept there) and nil with NOTES focused,
    # where `handle_notes_read_key` claims `i` for the editor it belongs to and this is never
    # reached.
    def insert_key_refusal : String?
      return nil unless @issues.detail_open? && !@issues.notes_focused?
      "RELATED is read-only — i edits the NOTES pane (↹/↓ down); intercept toggles from the tab bar"
    end

    # `↵`/`i` (INSERT), `x` (select line) and `y` (copy) used to be arms here. They are now
    # `editor.insert` / `editor.insert-enter` in `Scope::Editor` and `issue.select-line` /
    # `issue.copy` in `Scope::IssuesDetail` — chords those two verbs have carried since they
    # were written, and which this handler was what made dead (KEY_AUDIT §2d/§2e).
    private def handle_notes_read_key(ev : Termisu::Event::Key, key, c : Char?) : Bool
      selecting = ev.shift?
      case
      when key.escape?
        @issues.focus_links!
      when key.enter? then return false # editor.insert-enter
      when nav_up?(ev)                       then notes_read_up(ev, selecting)
      when nav_down?(ev)                     then @issues.notes_read_move(1, 0, selecting: selecting)
      when key.left?                         then notes_read_left(ev, selecting)
      when key.right?                        then @issues.notes_read_move(0, 1, selecting: selecting)
      when @issues.notes_read_motion_key(ev) then nil # Home/End/Page — the shared editor set
      # `x` is NOT claimed here: `issue.select-line` is a plain chord gated on
      # `issues_notes_read_mode?`, which is exactly this pane, so the `return false` below
      # hands the letter to the keymap and a rebind of that verb moves the live key. The arm
      # that stood here called `notes_select_line` directly, which is why a rebind moved
      # nothing — and it needed its own bare-only guard (`ev.char` falls back to
      # `key.to_char`, so `^X` reached it) that the keymap does not need.
      #
      # `y` DOES stay claimed, and stays modifier-blind: its Ctrl form IS `issue.copy`'s
      # pinned `^Y`, and taking the same action is what that chord is for in this pane.
      when c == 'y' then issues_notes_copy
      else
        return false # i INSERT, x select-line, y copy, Global breath keys …
      end
      true
    end

    # --- Verb::Scope::Editor — the NOTES pane of an open issue ---
    # Notes-focused only. `i` from the RELATED pane used to enter notes INSERT from here,
    # silently shadowing the Global intercept toggle with no message (KEY_AUDIT §2e, the
    # one `i` claim of the nine that printed no refusal). `insert_key_refusal` below says so
    # instead and points at `issue.edit-notes`, the registered verb that already does it.
    def editor_pane? : Bool
      @issues.detail_open? && @issues.notes_focused?
    end

    def editor_enter_insert : Bool
      return false unless editor_pane?
      @issues.enter_notes_insert!
      true
    end

    def editor_append_insert : Bool
      return false unless editor_pane?
      @issues.notes_read_move(0, 1)
      editor_enter_insert
    end

    def editor_exit_insert : Bool
      return false unless @issues.detail_open? && @issues.notes_insert_mode?
      @issues.exit_notes_insert!
      true
    end

    def editor_undo : Bool
      editor_pane? && @issues.notes_read_undo
    end

    def editor_to_top : Bool
      return false unless editor_pane?
      @issues.notes_read_to_edge(-1)
      true
    end

    def editor_to_bottom : Bool
      return false unless editor_pane?
      @issues.notes_read_to_edge(1)
      true
    end

    # `↑` on the first NOTES row and `←` at the start of a line hand focus back to RELATED —
    # the return leg of the ↓ handoff in `issue_link_move`, and the only keyboard way OUT of
    # this pane besides `esc`. Both keys are free at those edges: `ReadCursor#move` CLAMPS the
    # column rather than wrapping to the previous line's end, so neither did anything at all
    # there before.
    #
    # Folded INTO the two motion arms rather than sitting ahead of them as two more `when`s:
    # `handle_notes_read_key` sits exactly on the cyclomatic ceiling CI gates, so a third arm
    # tipped it over — and "does this key leave the pane" is local to the key anyway.
    private def notes_read_up(ev : Termisu::Event::Key, selecting : Bool) : Nil
      return @issues.focus_links! if notes_crossing?(ev) && @issues.notes_at_top?
      @issues.notes_read_move(-1, 0, selecting: selecting)
    end

    private def notes_read_left(ev : Termisu::Event::Key, selecting : Bool) : Nil
      return @issues.focus_links! if notes_crossing?(ev) && @issues.notes_at_doc_start?
      @issues.notes_read_move(0, -1, selecting: selecting)
    end

    # A crossing claims only a BARE press. ⇧ means a ⇧arrow selection is mid-build and leaving
    # the pane would abandon it instead of extending it; ⌃/⌥ belong to
    # `notes_read_motion_key`, the shared editor set that owns ⌃←/⌥← as word motion. Same
    # guard, same reason, as `RewriterController#handle_preview_in_key`.
    private def notes_crossing?(ev : Termisu::Event::Key) : Bool
      !ev.shift? && !ev.ctrl? && !ev.alt?
    end

    private def handle_notes_insert_key(ev : Termisu::Event::Key, key, c : Char?) : Bool
      case
      when ev.ctrl? && key.lower_w?
        # Disarmed on the way out: an arm granted for a refusal the operator then answered with
        # `^W` must not still be sitting there for the NEXT edit of this issue, where a second
        # `esc` would write over a peer without ever showing the refusal that earns it.
        @notes_overwrite_armed = nil
        @issues.cancel_notes_edit
      when ev.ctrl_z? then @issues.notes_undo
      when (ev.ctrl? || ev.alt?) && !@issues.notes_word_delete_key?(ev) && !editing_motion?(ev)
        # Every other modified chord defers to the central keymap so it stays rebindable —
        # `^Y` Copy above all, which is the only way to copy an INS selection here (bare `y`
        # is a literal character, and typing it would REPLACE the selection). ⌥⌫ and ⌥/⌃
        # motion are this editor's own and are excluded above.
        return false
      when key.escape? then save_notes_or_report
      when key.enter?  then @issues.notes_newline
        # Before plain ⌫, which would swallow the modified form as a one-character delete.
      when @issues.notes_word_delete_key?(ev) then @issues.notes_motion_key(ev)
      when key.backspace?                     then @issues.notes_backspace
        # ⇧arrows select, Page keys, ⌥←/→ by word — TextArea#handle_motion_key.
      when @issues.notes_motion_key(ev) then nil
      else
        if c && !ev.ctrl? && !ev.alt?
          @issues.notes_insert(c)
          report_replaced(@issues.notes_last_replaced) # a printable over a selection REPLACES it
          @issues.set_preedit("")
        end
      end
      true
    end

    # ⇧←/→ used to h-scroll the notes pane, which shadowed the character selection every other
    # text pane gives them. `handle_notes_read_key` took the chord back for the selection, and
    # the notes pane now soft-wraps — there is nothing off to the side to scroll to — so the
    # `hscroll_notes` chain is gone rather than kept as a no-op that still moves a caret.

    def set_preedit(text : String) : Bool
      if @issues.querying?
        @issues.query_set_preedit(text)
        true
      elsif @issues.notes_insert_mode?
        @issues.set_preedit(text)
        true
      else
        false
      end
    end

    def querying? : Bool
      @issues.querying?
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      return true if query_nav(ev)
      case
      when key.enter?     then query_enter
      when key.escape?    then query_escape
      when key.tab?       then @issues.query_complete
      when key.backspace? then @issues.query_backspace
        # Above the printable arm below, which would otherwise type the `?` (see ql_help_key?).
      when TabController.ql_help_key?(ev, @issues.query) then @host.open_help_query(:issues)
      else
        if c && !ev.ctrl? && !ev.alt?
          @issues.query_insert(c)
          @issues.query_set_preedit("")
        end
      end
      true
    end

    # ↓/↑ drive the dropdown, ←/→ the caret. Handled ahead of the `case` above rather than as
    # four more arms in it, for the reason `SitemapController#query_nav` gives: the two
    # dropdown keys push `handle_query_key` past the complexity gate CI runs, and "move
    # something" is a different question from "what does this key do". Both keys were DEAD in
    # this bar before the dropdown — a one-line field has no second row to move a caret to —
    # which is why they can be claimed without displacing anything.
    private def query_nav(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when act = LineEdit.action(ev) # ⌃/⌥←→, Home/End, Delete, ⌥⌫ — before the bare arrows
        @issues.query_edit(act)
      when key.down?  then @issues.popup_down
      when key.up?    then @issues.popup_up
      when key.left?  then @issues.query_move(-1)
      when key.right? then @issues.query_move(1)
      else                 return false
      end
      true
    end

    # Open dropdown ⇒ ↵ takes the highlighted candidate and shuts it; closed ⇒ apply the
    # filter and leave edit mode. Mirrors History and Sitemap — one grammar, one set of
    # gestures.
    private def query_enter : Nil
      if @issues.popup_open?
        @issues.query_complete(close: true)
      else
        @issues.stop_query
      end
    end

    # esc closes the dropdown first, so opening the list to look at it never costs the typed
    # query.
    private def query_escape : Nil
      return @issues.popup_close if @issues.popup_open?
      @issues.cancel_query
    end

    def on_enter : Nil
      @issues.reload(@host.session.store)
    end

    # `refresh_detail` reloads the list too, so it REPLACES the bare reload this used to do
    # rather than joining it. Without it the tab was refreshed in halves: the list behind an
    # open issue picked up a peer's severity/status/notes edit while the detail card on top of
    # it kept rendering the row it was opened with — the same split HistoryController closed
    # with its own detail refresh. It is gated on `detail_open?` inside the view, not on an
    # overlay: an Issues detail is in-tab state, so `@host.overlay` is `:none` while it is up.
    def on_external_change : Nil
      return unless @issues.refresh_detail(@host.session.store, announce: true)
      # An INS buffer is never overwritten (refresh_detail leaves it alone and says so here).
      # Announce instead — the alternative is the operator finding out at `esc`, when the save
      # is refused for a reason nothing on screen had hinted at. Latched to once per distinct
      # peer value: this tick also fires on this session's OWN captures.
      @host.status("notes changed by another session — esc will refuse to overwrite; ^W discards yours")
    end

    # The flush the shell runs on a tab switch and on `commit_pending_edits` (quit /
    # leave-project). NO retry hint here, unlike the `esc` path: on a tab switch the buffer
    # really is still there, but on the quit path the Runner is torn down immediately after —
    # nothing more is drawn and the text goes with the session. That last case is pre-existing
    # and deliberate (quit wins; `NotesView#save` keeps `@dirty` on a failed write and nobody
    # blocks the exit on it either), so this reports without promising a retry that one of its
    # three callers cannot honour.
    def commit : Nil
      # Still INS-gated, deliberately, now that `IssuesView#notes_dirty?` can be true in READ
      # (the NOR/INS chip leaves the editor without saving). `esc` is this pane's save key and
      # the chip is not — flushing a buffer the operator stepped out of would persist an edit
      # they never committed, on a tab switch they may not connect to it. What that buffer
      # needed was to stop being silently ERASED, and it no longer is: the tick and a re-entry
      # both leave it alone, so `i` picks the text back up exactly where it was.
      return unless @issues.notes_insert_mode?
      # The lost-update refusal belongs here as much as on `esc`: a tab switch and a quit both
      # route through this, and either one would have written this window's buffer over a peer's
      # writeup without the operator ever seeing the two versions.
      #
      # NOT armable from here, unlike `esc`. A tab switch is not a save — the buffer stays in
      # the view and `i` picks it back up — so the honest answer is "not saved, here is where to
      # go", and the message names the pane's own key rather than turning an unrelated keypress
      # into a write. The quit caller is louder still: `Runner#quit_message` /
      # `leave_confirm_message` put this conflict in the modal, because a status line posted
      # from inside a teardown is never rendered and the operator would have learned about it
      # by finding the writeup gone.
      if @issues.notes_conflict?(@host.session.store)
        @host.status("notes NOT saved — another session rewrote them; esc in the notes pane overwrites theirs, ^W takes theirs")
        return
      end
      return if @issues.save_notes(@host.session.store)
      @host.status("notes NOT saved — project busy")
    end

    # `esc` out of the notes editor. IssuesView#save_notes returns false when the write was
    # rolled back (cross-process SQLite busy/lock) and then leaves the buffer AND insert mode
    # exactly as they were, so the typed text is still on screen and a second `esc` is a real
    # retry. Say so — reporting nothing is what made a busy project look like it had saved
    # while it had discarded the writeup.
    private def save_notes_or_report : Nil
      # Ahead of the write, because `update_issue` sets the column wholesale — there is no
      # row-version to lose the race against, so the last esc in either window silently won and
      # the other operator's writeup was simply gone. Stay in INS on the refusal, so the typed
      # text is still on screen.
      #
      # And the refusal ARMS the next `esc` rather than standing forever. A guard on this pane
      # can only be an interruption, never a veto: the operator is the one who knows whether
      # their paragraph or the peer's is the one to keep, and a refusal with no way through left
      # them with three keys that all lose their text (`^W` takes the peer's, a tab switch
      # refuses again, quitting drops it). Second `esc` writes. That is the same shape as every
      # other "are you sure" in the app — informed, then allowed — and the informing is the part
      # that was missing, not the forbidding.
      #
      # Armed against the VALUE, so it cannot be pre-armed and cannot go stale: a peer who
      # writes again between the two presses moves the key, and the second `esc` refuses afresh
      # against the version nobody has seen yet.
      if key = @issues.notes_conflict_key(@host.session.store)
        if @notes_overwrite_armed != key
          @notes_overwrite_armed = key
          @host.status("notes NOT saved — another session rewrote them; esc again overwrites theirs, ^W takes theirs, ^Y copies yours")
          return
        end
      end
      # Either there was no conflict, or the operator answered one. Disarm before the write, so
      # an arm can never outlive the press it was granted for.
      @notes_overwrite_armed = nil
      return if @issues.save_notes(@host.session.store)
      @host.status("notes NOT saved — project busy; your text is still here, esc to retry")
    end

    def issues_notes_read_mode? : Bool
      @issues.detail_open? && @issues.notes_focused? && !@issues.notes_insert_mode?
    end

    def issues_notes_selection_active? : Bool
      @issues.notes_selection?
    end

    def issues_notes_select_line : Nil
      @issues.notes_select_line
    end

    def issues_notes_clear_selection : Nil
      @issues.notes_clear_selection
    end

    def issues_move(delta : Int32) : Nil
      if @issues.preview_enabled? && @issues.preview_focus == :preview
        @issues.move(delta)
        return
      end
      # ↑ at the top row pops focus up to the tab bar. The cursor stays put there, so the
      # marks (and any range in flight) stay put with it.
      if delta < 0 && @issues.at_top?
        return @host.request_focus(:menu)
      end
      end_range_gesture
      @issues.move(delta)
    end

    # A plain (unshifted) cursor key ends the ⇧arrow range gesture and hands its marks back
    # (IssuesView#end_mark_gesture). Says so only when marks actually went away, so arrowing
    # down an unmarked list stays silent — and names what survived, since `t`/⇧T marks are
    # deliberately not the gesture's to drop.
    private def end_range_gesture : Nil
      return if @issues.end_mark_gesture == 0
      n = @issues.mark_count
      @host.status(n == 0 ? "selection cleared" : "selection cleared — #{n} still marked")
    end

    # A preview pane (not the list) holds focus, so ↑/↓ and the wheel scroll that pane.
    private def preview_scroll_focused? : Bool
      @issues.preview_enabled? && @issues.preview_focus != :list
    end

    def issues_open : Nil
      @issues.open_detail(@host.session.store)
    end

    def issue_close : Nil
      @issues.close_detail
    end

    # `⇧N`/`⇧P` inside the drill-in: open the next/previous issue WITHOUT going back to the list.
    # See HistoryController#detail_step_item for why the step exists at all.
    #
    # Saves the notes buffer first, exactly as leaving by pointer or `esc` does, and ABORTS
    # when that write is refused — a conflict keeps INS on with the typed text still on
    # screen, and stepping off it would drop the paragraph the operator was just warned
    # about. Same rule the sub-tab strip follows: save the outgoing one FIRST.
    def issue_step_item(delta : Int32) : Nil
      return unless @issues.detail_open?
      return unless leave_notes_editor
      # Anchored on the issue the detail HAS OPEN, and clamped BEFORE the list is touched:
      # `select_index` re-seeds the ⇧-range mark anchor even when the index does not move,
      # so a step at either end would quietly destroy a range the operator had built.
      here = @issues.detail_row_index || return
      target = here + delta
      return if target < 0 || target >= @issues.row_count
      notes = @issues.notes_focused?
      # `select_index`, not `move`: `move` routes to the PREVIEW pane whenever that side holds
      # focus, and its focus survives opening the detail (the preview is not drawn there, so
      # nothing resets it). A step would then scroll a pane nobody can see.
      @issues.select_index(target)
      issues_open
      # The LEVEL survives the step, as the pane does on History: `open_detail` lands every
      # open on RELATED, which is right for a fresh drill-in and wrong for a step taken while
      # reading the notes.
      @issues.focus_notes! if notes
    end

    # --- marks (multi-select) -------------------------------------------------

    # The effective target set for a batch verb: the marks if any, else the cursor row.
    # Runner#issues_target_ids wraps this with the open-detail case.
    def target_issue_ids : Array(Int64)
      @issues.target_ids
    end

    def marked_issue_count : Int32
      @issues.mark_count
    end

    # The one privileged target when a batch verb needs a single representative — the value
    # the severity/status picker opens on (see IssuesView#primary_target_id).
    def primary_target_issue_id : Int64?
      @issues.primary_target_id
    end

    def issues_mark_toggle : Nil
      return @host.status("no issue to mark") unless @issues.selected_id
      @issues.toggle_mark
      @host.status(mark_status)
    end

    def issues_mark_all : Nil
      return @host.status("no issues to mark") if @issues.empty?
      @issues.mark_all
      @host.status(mark_status)
    end

    def issues_mark_clear : Nil
      @issues.clear_marks
      @host.status("marks cleared")
    end

    def issues_mark_extend(delta : Int32) : Nil
      return if @issues.empty?
      @issues.extend_marks(delta)
      @host.status(mark_status)
    end

    # Shared mark toast — says the count AND how much of it is off-window, matching the
    # filter-bar chip, so a set larger than the visible list is never a surprise.
    private def mark_status : String
      n = @issues.mark_count
      return "no marks — verbs act on the cursor row" if n == 0
      hidden = @issues.marked_hidden_count
      msg = "#{n} issue#{n == 1 ? "" : "s"} marked"
      msg += " (#{hidden} not visible)" if hidden > 0
      msg
    end

    # Space-menu delete. Capture the ids NOW so a peer write between the confirm opening and
    # being accepted can't retarget it. Works from the list (marks, else the cursor row) or
    # from the open detail, which is pinned to ONE issue.
    def issues_delete : Nil
      from_detail = @issues.detail_open?
      ids = from_detail ? [@issues.detail_issue.try(&.id)].compact : @issues.target_ids
      return if ids.empty?
      # Marks can outlive the visible list (a filter change, a peer delete), so a batch
      # confirm spells out the split: this dialog — not the list chip — is the last thing
      # read before data is destroyed.
      # Two labels — see HistoryController#delete_selected, which this mirrors: the confirm
      # body quotes the name, the toast reports it after a colon.
      name =
        if ids.size == 1
          @issues.issue_summary(ids.first)
        else
          hidden = @issues.hidden_count(ids)
          "#{ids.size} issues#{hidden > 0 ? " (#{hidden} not visible)" : ""}"
        end
      label = ids.size == 1 ? "“#{name}”" : name
      # Frozen evidence is project-wide (#1039): deleting an Issue removes only these
      # memberships. Say that explicitly so the operator never reads the confirm as a byte
      # deletion, especially when a snapshot is shared with another Issue.
      frozen = ids.sum { |id| @host.session.store.issue_evidence(id).size }
      frozen_note = frozen > 0 ? "\n#{frozen} frozen evidence link#{frozen == 1 ? " is" : "s are"} removed; the archived cop#{frozen == 1 ? "y stays" : "ies stay"}." : ""
      @host.confirm(ids.size == 1 ? "DELETE ISSUE" : "DELETE ISSUES",
        "Delete #{label}?#{frozen_note}\nThis can't be undone.", confirm_label: "delete", danger: true) do
        # A rolled-back write (cross-process SQLite busy/lock) leaves the issues AND the marks
        # in place — say so instead of reporting a delete that didn't happen, so the set is
        # still there to retry.
        unless @issues.delete_ids(@host.session.store, ids)
          @host.status("issue NOT deleted (project busy) — the marks are kept, try again")
          next
        end
        @host.status("issue deleted: #{name}")
      end
    end

    # ⇧X — the whole-tab wipe, in the family History, Probe, Authorize and the ACTIVITY feed
    # already share (#899). This tab was the one clear-all-shaped list left out of that
    # rollout, so the chord an operator learns as "clears this tab" answered nothing here.
    #
    # The count comes from the STORE, never `@issues.empty?`: that answers for the FILTERED
    # list, so `/ severity:critical` matching nothing would have turned a project holding 40
    # issues into a "nothing to clear" toast — the one reading of this key that would be a
    # lie. It is also the number the confirm names, so the gate and the prompt cannot
    # disagree, and it is read at PRESS time, so a peer's writes since the last reload count.
    #
    # An empty project gets a toast rather than a dialog, the way `probe_clear` and
    # `activity_clear` answer theirs: an advertised key that opens a dialog over nothing reads
    # as busywork, and one that answers with silence reads as a key that failed.
    #
    # Deliberately NOT mark-aware. With three rows marked `d` deletes those three and this
    # deletes everything — so the confirm says ALL and names the total, which is the number
    # that differs from the mark count the operator is looking at.
    def issues_clear : Nil
      n = @host.session.store.count_issues
      return @host.status("issues: nothing to clear") if n <= 0
      # Same split the per-issue delete confirm spells out, project-wide: `clear_issues` drops
      # `evidence_issue_links` unqualified and leaves every `issue_evidence` row standing
      # (#1039). Saying "frozen evidence goes too" claimed a byte deletion this wipe does not
      # do — and the copies it names outlive it, orphaned but visible in the Evidence tab.
      frozen = @host.session.store.count_evidence_links
      frozen_note = frozen > 0 ? "\n#{frozen} frozen evidence link#{frozen == 1 ? " is" : "s are"} removed; " \
                                 "the archived cop#{frozen == 1 ? "y stays" : "ies stay"} in the Evidence tab." : ""
      @host.confirm("CLEAR ISSUES",
        "Delete ALL #{n} issue#{n == 1 ? "" : "s"} for this project?\n" \
        "Their notes, CVSS scores and related links go too.#{frozen_note}\nThis can't be undone.",
        confirm_label: "clear", danger: true) do
        ok = @issues.clear(@host.session.store)
        @host.status(ok ? "issues cleared" : "issues NOT cleared (project busy) — every issue is still there")
      end
    end

    # `]`/`[` and `}`/`{`. A rolled-back write leaves the issue on its OLD value, which the
    # re-read then paints back — indistinguishable from "the key did nothing" unless it says
    # so. Same sentence Runner#apply_issue_choice uses for the picker path.
    def issue_severity(delta : Int32) : Nil
      return if @issues.severity_delta(delta, @host.session.store)
      @host.status("severity NOT changed — project busy; try again")
    end

    def issue_status(delta : Int32) : Nil
      return if @issues.status_delta(delta, @host.session.store)
      @host.status("status NOT changed — project busy; try again")
    end

    def issue_edit_notes : Nil
      @issues.enter_notes_insert!
    end

    def issue_link_move(delta : Int32) : Nil
      return if @issues.notes_insert_mode? || @issues.notes_focused?
      # ↓ past the last RELATED row hands focus to NOTES instead of clamping — the missing
      # entry that made NOTES unreachable in READ mode at all. Every other route into it went
      # through INS (`i`, `↵`, `e`) or the mouse, so "read the writeup without opening an
      # editor over it" had no keyboard path.
      #
      # Deliberately HERE, on the keyboard path, and not in `IssuesView#move_links`, which
      # `scroll_links_wheel` shares: a wheel reads as "scroll the viewport", not as a focus
      # gesture, and must not move focus out from under the pointer.
      if delta > 0 && @issues.links_at_bottom?
        @issues.focus_notes!
        return
      end
      @issues.move_links(delta)
    end

    def issues_copy : Nil
      text = @issues.notes_copy_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard#{Clipboard.note(written, text)}")
    end

    # The notes selection (or current line) text without copying — "Send selection to".
    def issues_notes_selection_text : String
      @issues.notes_copy_text
    end

    def issues_copy_all : Nil
      # With no issue open, `y` is the LIST's copy: every marked row, or the cursor row.
      unless @issues.detail_open?
        n = @issues.mark_count
        return copy_text(@issues.copy_rows_text, n > 1 ? "#{n} issues" : nil)
      end
      text = @issues.notes_copy_all
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied notes to clipboard (#{written}b)#{Clipboard.note(written, text)}")
    end

    # `y` in the notes pane: the selection when one is held, else the WHOLE notes. The keymap's
    # `issue.copy` (-> Runner#read_copy) has always answered that way, but this pane raw-
    # dispatches `y` ahead of the keymap and fell back to the caret's LINE — so the chord the
    # verb registers and the key the operator actually presses gave different answers.
    def issues_notes_copy : Nil
      issues_notes_selection_active? ? issues_copy : issues_copy_all
    end

    # Write the issue report to `path` (the destination came from ExportOverlay — this used
    # to hardcode <project dir>/issues.{md,json} and clobber it silently). Returns true when
    # the shell should close the popup; false keeps it up so a correctable failure doesn't
    # cost the typed path.
    #
    # The trailing newline mirrors `gori run issues --export=PATH`, so this and the CLI write
    # byte-identical files for the same project and format (`--format=markdown|json`; the
    # CLI's DEFAULT --format is `text`, a different report entirely). JSON.build emits no
    # trailing newline of its own, so the JSON export gains one here.
    def issues_export_to(format : Symbol, path : String) : Bool
      store = @host.session.store
      issues = store.issues
      if issues.empty?
        @host.status("no issues to export")
        return true
      end
      content = case format
                when :json  then Issues::Export.json(issues, store)
                when :sarif then Issues::Export.sarif(issues, store, @host.session.project.name)
                else             Issues::Export.markdown(issues, store, @host.session.project.name)
                end
      File.write(path, content.ends_with?('\n') ? content : "#{content}\n")
      msg = "exported #{issues.size} issue#{issues.size == 1 ? "" : "s"} → #{path}"
      # Only warn when the report landed INSIDE the ephemeral project dir. The path used to
      # always be in there, so the warning was unconditional; now the operator picks it, and
      # a file written to their cwd survives the project just fine.
      if @host.session.project.ephemeral? && path.starts_with?(@host.session.project.dir)
        msg += "  ⚠ temp project — copy it before closing"
      end
      @host.status(msg)
      true
    rescue ex
      @host.status("export failed: #{ex.message}")
      false
    end
  end
end
