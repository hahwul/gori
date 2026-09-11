require "./screen"
require "./theme"
require "./frame"
require "./picker_overlay"
require "../store"
require "../retest"

module Gori::Tui
  # The RETEST card for one Issue (#1036): the ordered Repeater sends that reproduce the
  # finding, and the result table the last run produced.
  #
  # A CARD rather than a third pane in the Issue detail, and the row budget is the reason.
  # `IssuesView#detail_split` already clamps RELATED down to nothing on a short terminal to
  # keep NOTES a single text row, so a permanently-mounted third card would take rows from
  # the pane an operator reads and types in — for a feature most issues never configure. The
  # detail carries a ONE-LINE retest summary instead, drawn only when the issue has a
  # retest, and this card is where the steps are edited and run.
  #
  # Two modes in one card, toggled with ⇥: STEPS is the plan, RESULTS is what the last run
  # said. They are the same object's two halves — the issue's own table has role, name,
  # expected AND actual in one row — and splitting them into two modals would mean losing
  # the plan's cursor every time a run finished.
  #
  # Every domain edge is injected at the open-site (`Runner#open_retest_overlay`): add,
  # edit, move, remove, run, stop, and opening a result row's recorded flow. The card itself
  # never touches the Store.
  class RetestOverlay < PickerOverlay
    STEPS_HINT   = "↑/↓ select · a add · e edit · ⇧J/⇧K move · d remove · r run · ⇧R run+cleanup · ⇥ results · esc close"
    RESULTS_HINT = "↑/↓ select · ↵ open the recorded response · ⇥ steps · r re-run · ⇧R run+cleanup · esc close"
    RUNNING_HINT = "running… · s stop · esc close (the run continues)"

    # Fixed gutters, so role and outcome line up down the card whatever the rows say.
    ROLE_W    =  9
    OUTCOME_W = 13

    getter issue_id : Int64
    getter issue_title : String
    # :steps | :results
    getter mode : Symbol
    getter? running : Bool

    # Armed by a key and read by `on_close` once the shell has dropped the card — the
    # `LinksOverlay#pending_add` seam. Each of these opens ANOTHER modal (a session picker,
    # a step form, a confirm), and a modal opened from inside this card's key handler would
    # be torn straight back down by the shell's own close.
    getter pending : Symbol?

    property on_move : Proc(Int32, Nil)?
    property on_stop : Proc(Nil)?

    def initialize(@issue_id : Int64, @issue_title : String)
      @steps = [] of Retest::Planned
      @results = [] of Store::RetestRunStep
      @run = nil.as(Store::RetestRun?)
      @mode = :steps
      @running = false
      @pending = nil
      @progress = ""
      # The plan's cost, computed ONCE per `load` — `Retest.confirm_note` walks the steps
      # three times over and allocates three arrays, and the footer needs it twice per frame
      # (text and colour). The same hoist `IssuesView#refresh_retest_summary` makes, for the
      # reason its own comment gives: recomputed on a WRITE, never per repaint.
      @plan_note = nil.as(String?)
      @runnable = 0
    end

    # The plan, the last run's rows, and whether a run is in flight — pushed by the
    # open-site and by the run fiber's drain, never read from here.
    def load(steps : Array(Retest::Planned), run : Store::RetestRun?,
             results : Array(Store::RetestRunStep)) : Nil
      @steps = steps
      @run = run
      @results = results
      @plan_note = Retest.confirm_note(steps)
      @runnable = steps.count(&.runnable?)
      clamp_selection
    end

    def set_running(running : Bool, progress : String = "") : Nil
      @running = running
      @progress = progress
    end

    def steps : Array(Retest::Planned)
      @steps
    end

    def selected_step : Retest::Planned?
      return nil unless @mode == :steps
      @steps[@selected]?
    end

    def selected_result : Store::RetestRunStep?
      return nil unless @mode == :results
      @results[@selected]?
    end

    # Put the cursor back where it was after the open-site rebuilds the card — the
    # `open_links_overlay(cursor:)` convention.
    def restore_cursor(mode : Symbol, index : Int32) : Nil
      @mode = mode == :results ? :results : :steps
      set_selected(index)
    end

    def entry_count : Int32
      @mode == :results ? @results.size : @steps.size
    end

    # --- Overlay contract (see overlay.cr) ---

    def key : OverlayKind
      OverlayKind::Retest
    end

    def title : String
      "RETEST — ISSUE ##{@issue_id}"
    end

    def hint : String
      return RUNNING_HINT if @running
      @mode == :results ? RESULTS_HINT : STEPS_HINT
    end

    # ⇥ swaps the halves; every edit key arms a hand-off and drops the card.
    #
    # `r` is armed in BOTH modes on purpose: after reading a failed result table, re-running
    # is the next thing an operator does, and making them press ⇥ first to reach the key
    # would be a mode where one is not needed. `s` stops a run in flight.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      # Unmodified letters only — `^D` reports 'd', and `d` here removes a step. Same guard
      # `LinksOverlay#handle_key` states.
      ch = (ev.ctrl? || ev.alt?) ? nil : (ev.char || ev.key.to_char)
      # NOT `out` — that is Crystal's C-binding output-parameter keyword, and using it as a
      # local here is a PARSE error whose message ("can't define def inside def") points at
      # the next method rather than at this line.
      if answered = handle_always_key(ev, ch)
        return answered
      end
      # An edit mid-run would send a step the plan no longer holds.
      @running ? :stay : handle_edit_key(ev, ch)
    end

    # The keys that mean the same thing in both halves AND during a run: navigation, the
    # mode swap, run and stop. nil = not one of them, so the caller may go on to the edits.
    private def handle_always_key(ev : Termisu::Event::Key, ch : Char?) : Symbol?
      key = ev.key
      case
      when key.escape? then return :cancel
        # ⇧J/⇧K reorder one row over while `j`/`k` move the cursor, and a terminal may report
        # the shifted press EITHER way — so both halves need guarding and neither guard alone
        # is enough:
        #
        #   * the CHARACTER, not `key.lower_k?`, because a shifted press usually arrives as
        #     the capital (`ev.char == 'K'`) carrying no shift flag at all; a `key.lower_k?`
        #     arm takes it for navigation and the reorder is never reached. Seen in a real
        #     tmux pty, not in the spec — `OverlayHarness#press` sets `shift:` by hand.
        #   * `!ev.shift?`, because a terminal whose protocol reports shift+LOWERCASE hits
        #     `ch == 'k'` here and returns before `handle_edit_key` runs — which made the
        #     shifted arms there dead code for exactly the spelling their comment names.
      when key.up?, !ev.shift? && ch == 'k'   then move(-1)
      when key.down?, !ev.shift? && ch == 'j' then move(1)
      when key.tab?                           then toggle_mode
        # `!ev.shift?`, for the same reason the nav arms carry it: a terminal that reports
        # shift+LOWERCASE would otherwise match here and ⇧R would silently be a plain run.
      when !ev.shift? && ch == 'r' then return arm_run(cleanup: false)
        # ⇧R is the operator "explicitly permitting" cleanup after a refused send — the one
        # thing the issue's safety rule requires a way to say, and which the CLI
        # (`--allow-cleanup`) and MCP (`allow_cleanup`) already had. A two-button confirm
        # cannot ask it, so it is a key: a run that skipped its cleanup says "re-run with
        # cleanup allowed to send it", and on this surface that sentence now names something.
      when ch == 'R', ev.shift? && ch == 'r' then return arm_run(cleanup: true)
      when ch == 's'                         then return stop_run
      else                                        return nil
      end
      :stay
    end

    # ⇧J/⇧K are accepted as the typed capital OR as an explicitly-shifted lowercase, because
    # which one a terminal reports depends on its keyboard protocol and both mean the gesture.
    private def handle_edit_key(ev : Termisu::Event::Key, ch : Char?) : Symbol
      key = ev.key
      case
      when key.enter?                        then return arm_open
      when ch == 'a'                         then return arm(:add)
      when ch == 'e'                         then return arm(:edit, needs_step: true)
      when ch == 'd'                         then return arm(:remove, needs_step: true)
      when ch == 'J', ev.shift? && ch == 'j' then nudge(1)
      when ch == 'K', ev.shift? && ch == 'k' then nudge(-1)
      end
      :stay
    end

    # A click on a row SELECTS it, and never commits: every commit here opens a second
    # modal, and a stray click that teleported the operator into a recorded flow is the
    # failure `LinksOverlay#handle_click` names one card over.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
      end
      :stay
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 104}.min
      h = area.h - 2
      return nil if w < 40 || h < 10
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      top = list_top(box)
      i = my - top
      return nil if i < 0 || i >= list_h(box)
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < entry_count ? ri : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "retest card needs a larger window")
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, header_line, Theme.muted, Theme.panel, width: box.w - 4)
      Frame.tee_divider(screen, box, box.y + 2)

      h = list_h(box)
      ensure_visible(h)
      if entry_count == 0
        screen.text(box.x + 3, list_top(box), empty_line, Theme.muted, Theme.panel, width: box.w - 6)
      else
        (0...h).each do |i|
          ri = @scroll + i
          break if ri >= entry_count
          draw_row(screen, box, list_top(box) + i, ri)
        end
      end
      screen.text(box.x + 2, box.bottom - 2, footer_line, footer_color, Theme.panel, width: box.w - 4)
    end

    # --- internals -----------------------------------------------------------

    private def list_top(box : Rect) : Int32
      box.y + 3
    end

    # `bottom - 2`: `Rect#bottom` is one PAST the last row, so `bottom - 1` is the card's own
    # bottom border and `bottom - 2` is the row the verdict / progress line takes.
    private def list_h(box : Rect) : Int32
      {box.bottom - 2 - list_top(box), 0}.max
    end

    private def toggle_mode : Nil
      @mode = @mode == :steps ? :results : :steps
      @selected = 0
      @scroll = 0
    end

    private def clamp_selection : Nil
      @selected = @selected.clamp(0, {entry_count - 1, 0}.max)
    end

    # `r` lives in `handle_always_key` so it works in both halves — which put it AHEAD of the
    # `@running` guard that keeps edits out of an in-flight run. Mid-run it then dropped the
    # card, re-planned, was refused by `start_retest` ("a retest is already running"), and
    # reopened on STEPS: the operator's live RESULTS view and cursor thrown away by a key the
    # running hint never offered. `stop_run` already models the shape; this is its mirror.
    private def arm_run(cleanup : Bool) : Symbol
      return :stay if @running
      arm(cleanup ? :run_with_cleanup : :run)
    end

    private def arm(what : Symbol, needs_step : Bool = false) : Symbol
      return :stay if needs_step && selected_step.nil?
      @pending = what
      :cancel
    end

    # ↵ in RESULTS opens the History flow THIS row's send recorded. A row with no flow id
    # (`--no-record-history`, or a store that was busy) has nothing to open and says so
    # rather than closing the card on a key that would do nothing.
    private def arm_open : Symbol
      return :stay unless @mode == :results
      row = selected_result
      return :stay if row.nil? || row.flow_id.nil?
      @pending = :open_flow
      :cancel
    end

    private def stop_run : Symbol
      return :stay unless @running
      on_stop.try(&.call)
      :stay
    end

    # ⇧J/⇧K reorder in place — the card stays up, because reordering is a repeatable edit
    # (the same reason `LinksOverlay`'s `d` stays open). The open-site rewrites the
    # positions and pushes the new plan back through `load`.
    private def nudge(delta : Int32) : Nil
      return unless @mode == :steps
      return if selected_step.nil?
      on_move.try(&.call(delta))
    end

    private def header_line : String
      t = Issues::Export.one_line(@issue_title)
      max = 48
      t = "#{t[0, max - 1]}…" if t.size > max
      "#{t} · #{@steps.size} step#{@steps.size == 1 ? "" : "s"} · #{@mode == :results ? "RESULTS" : "STEPS"}"
    end

    private def empty_line : String
      if @mode == :results
        "no run yet — press r to run this retest"
      else
        "no steps — press a to add a Repeater session as the baseline"
      end
    end

    private def footer_line : String
      return @progress.empty? ? "running…" : @progress if @running
      if @mode == :results && (r = @run)
        t = Retest::Tally.new(r.total, r.passed, r.failed, r.inconclusive, r.errored, r.blocked, r.skipped)
        return "#{r.verdict.label.upcase} · #{Retest.summary_line(t)} · #{Fmt.ago(Time.unix(r.started_at // 1_000_000))}"
      end
      # STEPS: the confirm's own sentence, shown BEFORE `r` rather than only in the dialog,
      # so an operator can see what a run costs while they are still building it.
      @plan_note || "#{@runnable} request#{@runnable == 1 ? "" : "s"} · all safe methods"
    end

    private def footer_color : Color
      return Theme.accent if @running
      if @mode == :results && (r = @run)
        return verdict_color(r.verdict)
      end
      @plan_note ? Theme.yellow : Theme.muted
    end

    private def draw_row(screen : Screen, box : Rect, y : Int32, idx : Int32) : Nil
      active = idx == @selected
      bg = active ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg)
      screen.cell(box.x + 1, y, active ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      right = box.right - 2
      if @mode == :results
        draw_result_row(screen, x, y, right, bg, active, @results[idx])
      else
        draw_step_row(screen, x, y, right, bg, active, idx, @steps[idx])
      end
    end

    private def draw_step_row(screen : Screen, x : Int32, y : Int32, right : Int32, bg : Color,
                              active : Bool, idx : Int32, pl : Retest::Planned) : Nil
      pos = "#{idx + 1}."
      screen.text(x, y, pos, Theme.muted, bg, width: 3)
      screen.text(x + 3, y, pl.role.label, role_color(pl.role), bg, width: ROLE_W)
      cx = x + 3 + ROLE_W
      # A step that cannot run is the row that must not read like an ordinary one: a retest
      # which quietly became shorter is not a retest that passed.
      fg = pl.runnable? ? (active ? Theme.text_bright : Theme.text) : Theme.muted
      tail = pl.runnable? ? "" : "  ⚠ #{pl.missing}"
      # The METHOD is on the row, not only in the footer tally: it is what makes "this step
      # changes state" visible per row rather than as a number.
      line = "#{pl.method} #{Issues::Export.one_line(pl.label)}  expect #{expected_of(pl)}#{tail}"
      screen.text(cx, y, line, fg, bg, width: {right - cx, 1}.max)
    end

    private def draw_result_row(screen : Screen, x : Int32, y : Int32, right : Int32, bg : Color,
                                active : Bool, row : Store::RetestRunStep) : Nil
      screen.text(x, y, "#{row.position}.", Theme.muted, bg, width: 3)
      screen.text(x + 3, y, row.role.label, role_color(row.role), bg, width: ROLE_W)
      cx = x + 3 + ROLE_W
      screen.text(cx, y, row.outcome.label.upcase, outcome_color(row.outcome), bg,
        width: OUTCOME_W, attr: Attribute::Bold)
      cx += OUTCOME_W
      fg = active ? Theme.text_bright : Theme.text
      expect = row.assertion.empty? ? "—" : row.assertion
      line = "#{Issues::Export.one_line(row.label)}  expect #{expect}  → #{Issues::Export.one_line(row.detail)}"
      screen.text(cx, y, line, fg, bg, width: {right - cx, 1}.max)
    end

    private def expected_of(pl : Retest::Planned) : String
      pl.step.assertion.empty? ? "—" : pl.step.assertion
    end

    # The roles carry the same accent the rest of the app gives a lifecycle: the anchor and
    # the case under test read first, the housekeeping pair stays quiet.
    private def role_color(role : Store::RetestRole) : Color
      case role
      in .setup?    then Theme.muted
      in .baseline? then Theme.syn_header
      in .variant?  then Theme.accent
      in .control?  then Theme.text
      in .cleanup?  then Theme.muted
      end
    end

    private def outcome_color(o : Store::RetestOutcome) : Color
      case o
      in .pass?         then Theme.green
      in .fail?         then Theme.red
      in .blocked?      then Theme.orange
      in .error?        then Theme.orange
      in .inconclusive? then Theme.yellow
      in .skipped?      then Theme.muted
      end
    end

    private def verdict_color(v : Store::RetestVerdict) : Color
      case v
      in .pass?         then Theme.green
      in .fail?         then Theme.red
      in .blocked?      then Theme.orange
      in .inconclusive? then Theme.yellow
      end
    end
  end
end
