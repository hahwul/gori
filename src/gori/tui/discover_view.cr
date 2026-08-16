require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "./traffic_empty_state"
require "../discover"
require "./viewport"

module Gori::Tui
  # One discovery run (a spider + brute session). Ephemeral (in-memory) — the durable
  # output is the Sitemap flows the controller persists. The engine reference is held so
  # the controller can pause/resume/stop it directly.
  class DiscoverRun
    getter target : String
    getter config : Discover::Config
    property id : Int32 = 0
    property job_id : Int32 = 0
    # :idle | :running | :paused | :done | :budget_exhausted | :stopped | :error.
    # `:budget_exhausted` is its own state, not a flavour of :done: a crawl that ran out of
    # `max_requests` left `queued` candidates it never looked at, and rendering that as
    # "done" is what let `5 found` stand for a 283-candidate wordlist of which 275 were
    # never sent.
    property status : Symbol = :idle
    getter findings = [] of Discover::Finding
    # The flow each finding was persisted as, INDEX-ALIGNED with `findings` — nil until the
    # controller's persist batch commits (or forever, if that write failed). It is what turns
    # a findings row into something openable: the run is in-memory and holds no bytes, the
    # STORE holds the request/response, and this is the only link between the two.
    getter flow_ids = [] of Int64?
    property stats : Discover::RunStats? = nil
    property sent = 0_i64
    property found = 0
    property errors = 0_i64
    property queued = 0
    property error_msg : String? = nil
    property engine : Discover::Engine? = nil
    property? stop_requested = false
    getter started_at : Time::Instant

    def initialize(@target : String, @config : Discover::Config)
      @started_at = Time.instant
    end

    def running? : Bool
      @status == :running || @status == :paused
    end

    # True when a cap halted the crawl with candidates still in the frontier.
    def budget_exhausted? : Bool
      @status == :budget_exhausted
    end

    def paused? : Bool
      @status == :paused
    end

    def same?(other : DiscoverRun) : Bool
      object_id == other.object_id
    end

    # Record a finding and the slot its flow id will land in. One method, so the two arrays
    # cannot drift: an unaligned `flow_ids` would open the request/response of the WRONG
    # endpoint, which is worse than opening none.
    def add_finding(f : Discover::Finding) : Int32
      @findings << f
      @flow_ids << nil
      @findings.size - 1
    end

    def set_flow_id(idx : Int32, id : Int64) : Nil
      @flow_ids[idx] = id if 0 <= idx < @flow_ids.size
    end

    def flow_id_at(idx : Int32) : Int64?
      @flow_ids[idx]?
    end

    def begin_run : Nil
      @status = :running
      @stop_requested = false
      @findings.clear
      @flow_ids.clear
      @stats = nil
      @sent = 0_i64
      @found = 0
      @errors = 0_i64
      @queued = 0
      @error_msg = nil
    end

    def request_stop : Nil
      @stop_requested = true
      @engine.try(&.stop)
    end

    def stop_requested? : Bool
      @stop_requested
    end

    def pause : Nil
      return unless @status == :running
      @engine.try(&.pause)
      @status = :paused
    end

    def resume : Nil
      return unless @status == :paused
      @engine.try(&.resume)
      @status = :running
    end

    def label(max : Int32 = 24) : String
      t = @target
      t.size > max ? "#{t[0, max - 1]}…" : t
    end

    def techniques : String
      parts = [] of String
      parts << "spider" if @config.spider?
      parts << "brute" if @config.bruteforce?
      parts.join("+")
    end
  end

  # The Discover sub-tab body: a RUNS list over every session launched this run of the TUI
  # (in flight AND finished) + a live findings table for the SELECTED run. Runs are launched
  # from the config overlay (Sitemap/History space menu, or ^R here to re-run the selected
  # one); ^X/p act on the SELECTED row.
  #
  # Every run stays on screen because every action here is per-run. The pane used to draw a
  # single summary card for `current` and cycle with [ / ]: launching a second `Discover
  # here` moved the selection to the new run and left the first one — still crawling — with
  # no visible row, no status, and no reachable ^X.
  class DiscoverView
    PANE_ORDER = [:runs, :findings]

    # The RUNS card's title, as a constant because THREE places measure it: the card, the
    # run badge's `min_x`, and that badge's hit-test. It used to read `RUNS (#{@runs.size})`,
    # so the badge's left stop moved every time the count gained a digit.
    RUNS_TITLE = "RUNS"

    # Run-row column widths. The blocks are laid out from the right edge and DROP when the
    # body is narrow (counts first, then techniques) so a run's target and its status —
    # the two things an action needs — survive at any width.
    RUN_STATUS_W   =  9
    RUN_TECH_W     = 13
    RUN_COUNT_W    = 20
    RUN_TARGET_MIN = 16

    getter focus : Symbol

    def initialize
      @runs = [] of DiscoverRun
      @sel = 0
      @fsel = 0
      @scroll = 0
      @rscroll = 0
      @focus = :runs
    end

    def empty? : Bool
      @runs.empty?
    end

    def count : Int32
      @runs.size
    end

    def runs : Array(DiscoverRun)
      @runs
    end

    def current : DiscoverRun?
      @runs[@sel]?
    end

    def add(run : DiscoverRun) : Nil
      @runs << run
      @sel = @runs.size - 1
      @fsel = 0
      @scroll = 0
    end

    def switch(dir : Int32) : Nil
      return if @runs.size < 2
      @sel = (@sel + dir).clamp(0, @runs.size - 1)
      @fsel = 0
      @scroll = 0
    end

    def select_run_by_id(id : Int32) : Nil
      if idx = @runs.index { |r| r.id == id }
        select_run(idx)
      end
    end

    def any_running? : Bool
      @runs.any?(&.running?)
    end

    # Drop a finished run's row (the list is otherwise append-only for the whole session).
    # REFUSES a live one — `DiscoverController#drain_events` skips events whose run is no
    # longer in `@runs`, so removing a crawling run would leave its engine fiber sending with
    # nothing on screen to stop it. Returns false when it refused or the run was already gone,
    # so the caller can say why. The guard lives here, next to the array it protects, rather
    # than only at the one call site that reports it.
    def dismiss(run : DiscoverRun) : Bool
      return false if run.running?
      idx = @runs.index(&.same?(run))
      return false unless idx
      @runs.delete_at(idx)
      @sel = @sel.clamp(0, {@runs.size - 1, 0}.max)
      @fsel = 0
      @scroll = 0
      @rscroll = 0
      true
    end

    # --- focus ring (RUNS list ↹ FINDINGS table) ---
    def focus_pane(pane : Symbol) : Nil
      @focus = pane if PANE_ORDER.includes?(pane)
    end

    def focus_first : Nil
      @focus = :runs
    end

    def focus_last : Nil
      @focus = :findings
    end

    def pane_advance(dir : Int32) : Bool
      idx = PANE_ORDER.index(@focus) || 0
      nidx = idx + dir
      return false unless 0 <= nidx < PANE_ORDER.size
      @focus = PANE_ORDER[nidx]
      true
    end

    # --- nav ---
    def move_run(d : Int32) : Nil
      switch(d)
    end

    def runs_at_top? : Bool
      @sel <= 0
    end

    def runs_at_bottom? : Bool
      @sel >= @runs.size - 1
    end

    def move(d : Int32) : Nil
      return unless r = current
      return if r.findings.empty?
      @fsel = (@fsel + d).clamp(0, r.findings.size - 1)
    end

    def selected_finding : Discover::Finding?
      current.try(&.findings[@fsel]?)
    end

    # The stored flow behind the cursor row, or nil when the row has none yet (the persist
    # batch has not committed) or never will (the store write failed). Only meaningful with a
    # finding under the cursor — `selected_finding` is what says whether there is one.
    def selected_flow_id : Int64?
      return nil unless r = current
      return nil unless r.findings[@fsel]?
      r.flow_id_at(@fsel)
    end

    # Pull the findings cursor back inside the selected run's list.
    #
    # `move` clamps as it steps, but a RE-RUN (`^R`) empties `findings` on the run object while
    # `@fsel` lives here, so a cursor parked on row 9 of a 10-finding run survives into a re-run
    # that finds 3. That left the selection band drawn on nothing and `selected_finding` nil
    # with rows plainly on screen — which `open_flow_target` would then report as "this run
    # found nothing". Called from render, alongside the scroll anchor it already fixes up.
    private def clamp_findings(r : DiscoverRun) : Nil
      return if r.findings.empty? # nothing to clamp to; the empty-state message is correct
      @fsel = r.findings.size - 1 if @fsel >= r.findings.size
      @fsel = 0 if @fsel < 0
    end

    def findings_at_top? : Bool
      @fsel == 0
    end

    # --- rendering ---
    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      # Nothing crawled yet: both lists are empty, so tiling two cards spends the whole pane
      # on a pair of empty frames and one grey line. The onboarding card is what the sibling
      # sub-tab (Sitemap) has always shown in the same situation — this pane said one sentence
      # inside a RUNS frame instead, and the asymmetry inside one tab read as breakage.
      # `pane_at`/`click` decline in the same state, so the mouse cannot address a pane that
      # was never drawn.
      if @runs.empty?
        TrafficEmptyState.render(screen, rect, variant: :discover)
        return
      end
      runs_rect, res_rect = pane_rects(rect)
      render_runs(screen, runs_rect, focused && @focus == :runs)
      render_findings(screen, res_rect, focused && @focus == :findings) unless res_rect.empty?
    end

    # The {runs, findings} rects for `rect`, TILING it exactly: the two cover `rect` and
    # nothing outside it. Shared with `pane_at`/`click` via `runs_pane_height`.
    #
    # The findings height was floored at 1 with no ceiling, so on a 1-row body the card was
    # placed at `rect.y + 1` — a whole row outside the rect this view was handed, which
    # nothing repaints. A pane the container cannot pay for is now declined outright.
    private def pane_rects(rect : Rect) : {Rect, Rect}
      runs_h = runs_pane_height(rect)
      {Rect.new(rect.x, rect.y, rect.w, runs_h),
       Rect.new(rect.x, rect.y + runs_h, rect.w, {rect.h - runs_h, 0}.max)}
    end

    # The RUNS card grows a row per run so a second and third crawl are VISIBLE rather than
    # cycled to. It stops growing once the findings table is down to its last six rows (the
    # list scrolls from there), and on a body too short for even that the card is clamped to
    # `rect.h - 3` so the findings card is never squeezed out of existence.
    private def runs_pane_height(rect : Rect) : Int32
      # borders(2) + column header(1) + one row per run + divider(1) + detail(2)
      h = {@runs.size + 6, {rect.h - 6, 7}.max}.min
      h = rect.h - 3 if h > rect.h - 3
      # Floored at 1 so the card never vanishes, then capped at what the container actually
      # granted — a floor with no ceiling is what puts a pane outside its own rect.
      { {h, 1}.max, rect.h }.min
    end

    # {rows_y, rows_cap, detail_y} for the RUNS card's interior — the row band and the
    # selected-run detail band. Shared by render and the click hit-test so a click can't
    # land on a row the renderer put somewhere else. `detail_y` is -1 when the card is too
    # short for the detail band (it is the first thing to go).
    private def run_bands(card : Rect) : {Int32, Int32, Int32}
      inner = card.inset(1, 1)
      return {inner.y, 0, -1} if inner.h <= 0
      detail_h = inner.h >= 5 ? 3 : 0
      list_h = inner.h - detail_h
      hdr = list_h >= 2 ? 1 : 0
      {inner.y + hdr, {list_h - hdr, 1}.max, detail_h > 0 ? inner.y + list_h : -1}
    end

    private def render_runs(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, RUNS_TITLE, border: Frame.pane_border(focused), bg: Theme.bg)
      inner = rect.inset(1, 1)
      return if inner.h <= 0 || inner.w <= 0
      r = current
      unless r
        screen.text(inner.x + 1, inner.y,
          "no runs — from Sitemap/History press space → \"Discover here\"", Theme.muted, Theme.bg, width: inner.w - 1)
        return
      end
      # The badge tracks the SELECTED row, which is what ^R/^X act on — so a stopped run
      # selected while another still crawls offers RUN, not STOP.
      chord, name = r.running? ? {"^X", "STOP"} : {"^R", "RUN"}
      badge_x = Frame.toggle_badge(screen, rect.right - 1, rect.y, rect.x + RUNS_TITLE.size + 4, chord, name, r.running?)
      # The count rides `border_meta`, not the title, like the FINDINGS card below it: a title
      # that grows a digit moves every `min_x` derived from its width — the run badge's is.
      # AFTER the badge and stopped at its left edge, because this border already carries one
      # and the meta was otherwise drawn first and painted straight over.
      Frame.border_meta(screen, rect, RUNS_TITLE, @runs.size.to_s, right_edge: badge_x - 1)

      rows_y, rows_cap, detail_y = run_bands(rect)
      runs_header_row(screen, inner) if rows_y > inner.y
      ensure_run_visible(rows_cap)
      rows_cap.times do |i|
        idx = @rscroll + i
        break if idx >= @runs.size
        draw_run_row(screen, inner, @runs[idx], idx, rows_y + i, focused)
      end
      Frame.scroll_gauge(screen, Rect.new(inner.x, rows_y, inner.w, rows_cap), @runs.size, @rscroll, focused)
      return if detail_y < 0
      Frame.inner_divider(screen, inner, detail_y, Theme.bg, Frame.pane_border(focused))
      render_run_detail(screen, inner, detail_y + 1, r)
    end

    # Column x-offsets for one run row: {target_w, tech_x, status_x, counts_x}, where a
    # negative x means the block does not fit and is not drawn.
    private def run_layout(inner : Rect) : {Int32, Int32, Int32, Int32}
      x = inner.x + 2
      edge = inner.right
      counts_x = -1
      if edge - x >= RUN_TARGET_MIN + RUN_TECH_W + RUN_STATUS_W + RUN_COUNT_W
        counts_x = edge - RUN_COUNT_W
        edge = counts_x
      end
      status_x = edge - RUN_STATUS_W
      status_x = -1 if status_x < x + 8
      tech_x = -1
      tech_x = status_x - RUN_TECH_W if status_x >= 0 && status_x - x >= RUN_TARGET_MIN + RUN_TECH_W
      right_block = tech_x >= 0 ? tech_x : (status_x >= 0 ? status_x : edge)
      target_w = {right_block - x - 1, 4}.max
      {target_w, tech_x, status_x, counts_x}
    end

    private def runs_header_row(screen : Screen, inner : Rect) : Nil
      target_w, tech_x, status_x, counts_x = run_layout(inner)
      screen.text(inner.x + 2, inner.y, "TARGET", Theme.muted, Theme.bg, width: target_w)
      screen.text(tech_x, inner.y, "HOW", Theme.muted, Theme.bg, width: RUN_TECH_W - 1) if tech_x >= 0
      screen.text(status_x, inner.y, "STATUS", Theme.muted, Theme.bg, width: RUN_STATUS_W - 1) if status_x >= 0
      screen.text(counts_x, inner.y, "FOUND·SENT·QUEUE", Theme.muted, Theme.bg, width: RUN_COUNT_W) if counts_x >= 0
    end

    private def draw_run_row(screen : Screen, inner : Rect, r : DiscoverRun, idx : Int32,
                             py : Int32, focused : Bool) : Nil
      sel = idx == @sel
      bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(inner.x, py, inner.w, 1), bg)
      screen.cell(inner.x, py, sel ? '▎' : ' ', Theme.accent, bg)
      target_w, tech_x, status_x, counts_x = run_layout(inner)
      screen.text(inner.x + 2, py, r.target, sel ? Theme.text_bright : Theme.text, bg, width: target_w)
      screen.text(tech_x, py, r.techniques, Theme.accent, bg, width: RUN_TECH_W - 1) if tech_x >= 0
      screen.text(status_x, py, short_status(r), status_hue(r.status), bg, width: RUN_STATUS_W - 1) if status_x >= 0
      screen.text(counts_x, py, run_counts(r), Theme.muted, bg, width: RUN_COUNT_W) if counts_x >= 0
    end

    # `:budget_exhausted` shortened for the fixed column — the detail band below spells out
    # what it cost. Not "done": the crawl left candidates it never looked at.
    private def short_status(r : DiscoverRun) : String
      r.status == :budget_exhausted ? "budget" : r.status.to_s
    end

    # Rounded (`Fmt.count`) so the column stays fixed-width on a long crawl; the detail band
    # carries the exact figures for the selected run.
    private def run_counts(r : DiscoverRun) : String
      "#{Fmt.count(r.found.to_i64)}f · #{Fmt.count(r.sent)}s · #{Fmt.count(r.queued.to_i64)}q"
    end

    private def render_run_detail(screen : Screen, inner : Rect, y : Int32, r : DiscoverRun) : Nil
      w = {inner.w - 1, 1}.max
      cap = r.config.max_requests.try { |m| " · cap #{m}" } || ""
      screen.text(inner.x + 1, y, "#{r.techniques} · #{r.config.containment.label} · depth #{r.config.max_depth}#{cap}",
        Theme.muted, Theme.bg, width: w)
      return if y + 1 >= inner.bottom
      screen.text(inner.x + 1, y + 1, run_detail_note(r), detail_hue(r.status), Theme.bg, width: w)
    end

    # What the selected row's status COST the operator: an error's message, a budget stop's
    # unexplored remainder (never rendered as "done" — see DiscoverRun#status), else the
    # suppression breakdown once the engine reported stats.
    private def run_detail_note(r : DiscoverRun) : String
      case r.status
      when :error
        "error: #{r.error_msg}"
      when :budget_exhausted
        "budget exhausted · #{r.queued} queued unexplored — raise max requests to finish"
      else
        if s = r.stats
          drift = s.drift_suppressed > 0 ? " · drift #{s.drift_suppressed}" : ""
          "fp-cut #{s.calibrated_out} · dedup #{s.dedup_suppressed} · tmpl #{s.template_suppressed} · clust #{s.cluster_suppressed}#{drift}"
        else
          "found #{r.found} · #{r.sent} sent · #{r.queued} queued · #{r.errors} err"
        end
      end
    end

    private def detail_hue(s : Symbol) : Color
      s == :error || s == :budget_exhausted ? status_hue(s) : Theme.muted
    end

    # `cap` is `run_bands`' row band — the header above it is not scrolled — and `@runs` is
    # what the draw loop walks. Sibling of `ensure_visible` below, which windows the FINDINGS
    # of the selected run; this one windows the runs themselves.
    private def ensure_run_visible(cap : Int32) : Nil
      @rscroll = Viewport.scroll_to_show(@sel, @rscroll, cap, @runs.size)
    end

    private def status_hue(s : Symbol) : Color
      case s
      when :running          then Theme.accent
      when :paused           then Theme.yellow
      when :error            then Theme.red
      when :budget_exhausted then Theme.yellow
      when :stopped          then Theme.muted
      else                        Theme.green
      end
    end

    private def render_findings(screen : Screen, rect : Rect, focused : Bool) : Nil
      r = current
      n = r ? r.findings.size : 0
      Frame.card(screen, rect, "FINDINGS", border: Frame.pane_border(focused), bg: Theme.bg)
      Frame.border_meta(screen, rect, "FINDINGS", n.to_s)
      inner = rect.inset(1, 1)
      # A card under 3 rows has no interior — `inset` floors the height at 0 but keeps
      # `inner.y` one row down, so an unguarded placeholder lands OUTSIDE the pane.
      # (`render_runs` has carried this guard all along; this pane did not.)
      return if inner.h <= 0 || inner.w <= 0
      return unless r
      if r.findings.empty?
        # "no endpoints found" over a crawl that stopped on its budget is the claim this
        # tab must never make — it did not look.
        msg = if r.running?
                "discovering… endpoints appear here"
              elsif r.budget_exhausted?
                "none found in the #{r.sent} requests the budget allowed — #{r.queued} candidates unexplored"
              elsif r.stats
                "no endpoints found"
              else
                "no run yet — ^R to run"
              end
        screen.text(inner.x + 1, inner.y, msg, Theme.muted, Theme.bg)
        return
      end
      header_row(screen, inner)
      cap = inner.h - 1
      clamp_findings(r) # before ensure_visible: the scroll anchor is derived from @fsel
      ensure_visible(cap, r)
      cap.times do |i|
        idx = @scroll + i
        break if idx >= r.findings.size
        draw_row(screen, inner, r.findings[idx], idx, inner.y + 1 + i, focused)
      end
      # The RUNS card six rows above has had a gauge all along; this one had none. A
      # difference like that INSIDE one view reads as breakage rather than as a gap. Rows
      # start at `inner.y + 1` — `inner.y` is the header — so the gauge measures from there.
      Frame.scroll_gauge(screen, Rect.new(inner.x, inner.y + 1, inner.w, cap),
        r.findings.size, @scroll, focused)
    end

    private def header_row(screen : Screen, inner : Rect) : Nil
      screen.text(inner.x + 2, inner.y, "CODE", Theme.muted, Theme.bg)
      screen.text(inner.x + 7, inner.y, "SOURCE", Theme.muted, Theme.bg)
      screen.text(inner.x + 20, inner.y, "URL", Theme.muted, Theme.bg)
      screen.text(inner.right - 6, inner.y, "CONF", Theme.muted, Theme.bg)
    end

    private def draw_row(screen : Screen, inner : Rect, f : Discover::Finding, idx : Int32, py : Int32, focused : Bool) : Nil
      sel = idx == @fsel
      bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(inner.x, py, inner.w, 1), bg)
      screen.cell(inner.x, py, sel ? '▎' : ' ', Theme.accent, bg)
      screen.text(inner.x + 2, py, f.status.try(&.to_s) || "—", status_color(f.status), bg, width: 4)
      screen.text(inner.x + 7, py, f.source.label, Theme.accent, bg, width: 12)
      urlw = {inner.w - 20 - 6, 4}.max
      screen.text(inner.x + 20, py, f.url, sel ? Theme.text_bright : Theme.text, bg, width: urlw)
      conf = (f.confidence * 100).to_i
      screen.text(inner.right - 6, py, "#{conf}%", conf >= 90 ? Theme.green : Theme.yellow, bg)
    end

    private def status_color(s : Int32?) : Color
      return Theme.muted unless s
      case s
      when 200..299 then Theme.green
      when 300..399 then Theme.accent
      when 400..499 then Theme.yellow
      else               Theme.red
      end
    end

    # `cap` is the rows region — `inner.h - 1`, the column header above it is not scrolled.
    # The count lives on the RUN, not on the view: `@scroll`/`@fsel` window `r.findings`,
    # which is what the draw loop walks, and switching runs re-enters here with a different
    # list under the same offset — the case the tail clamp exists for.
    private def ensure_visible(cap : Int32, r : DiscoverRun) : Nil
      @scroll = Viewport.scroll_to_show(@fsel, @scroll, cap, r.findings.size)
    end

    # --- click hit-test ---
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless rect.contains?(mx, my)
      # With no runs the renderer draws the onboarding card over the whole rect and no panes at
      # all, so there is nothing here to focus. Without this the hit-test would still hand back
      # :runs / :findings off `pane_rects`, focusing a pane that is not on screen.
      #
      # This is the only guard `click` needs as well, even though it consults `gauge_hit` first:
      # `Frame.scroll_gauge_row` refuses whenever `total <= track`, so an empty list has no
      # gauge to hit, and the findings gauge bails on `current`. Everything else in `click` is
      # downstream of this call.
      return nil if @runs.empty?
      runs_rect, res_rect = pane_rects(rect) # the tiling render draws into, not a re-derivation
      return :runs if runs_rect.contains?(mx, my)
      res_rect.contains?(mx, my) ? :findings : nil
    end

    # Focus the clicked pane, and select the row under the cursor in EITHER list — clicking a
    # row is the discoverable way to reach an earlier crawl before pressing ^X on it, and
    # FINDINGS used to fall out of this method one line in, so a click there focused the pane
    # and left the cursor where it was. Its own sibling four lines up already selected.
    def click(rect : Rect, mx : Int32, my : Int32) : Nil
      # Either card's scroll gauge first: it rides the frame hairline, which `pane_at` and
      # both row hit-tests exclude.
      if hit = gauge_hit(rect, mx, my)
        pane, row = hit
        focus_pane(pane)
        pane == :runs ? select_run(row) : (@fsel = row)
        return
      end
      return unless pane = pane_at(rect, mx, my)
      focus_pane(pane)
      runs_card, res_card = pane_rects(rect) # the tiling render drew into, not a re-derivation
      if pane == :runs
        rows_y, rows_cap, _ = run_bands(runs_card)
        row = my - rows_y
        return unless 0 <= row < rows_cap
        idx = @rscroll + row
        return unless 0 <= idx < @runs.size
        select_run(idx)
      else
        return unless idx = findings_row_at(res_card, my)
        @fsel = idx
      end
    end

    # Mouse: the findings index under `my` within the FINDINGS card, or nil (no run, empty
    # list, the header row, or past the last populated row). Mirrors render_findings'
    # inset → header → @scroll+i. Y-only, like every other list hit-test here.
    private def findings_row_at(card : Rect, my : Int32) : Int32?
      r = current
      return nil if r.nil? || r.findings.empty?
      inner = card.inset(1, 1)
      return nil if inner.h <= 0 || inner.w <= 0
      i = my - (inner.y + 1) # rows start one line below the header
      return nil if i < 0 || i >= {inner.h - 1, 0}.max
      idx = @scroll + i
      idx < r.findings.size ? idx : nil
    end

    # The RUNS / FINDINGS row a click on either card's scroll gauge asks for. Both scrolls
    # are derived from their selection, so both answer with a selection.
    def gauge_hit(rect : Rect, mx : Int32, my : Int32) : {Symbol, Int32}?
      runs_card, res_card = pane_rects(rect)
      rows_y, rows_cap, _ = run_bands(runs_card)
      if row = Frame.scroll_gauge_row(Rect.new(runs_card.inset(1, 1).x, rows_y, runs_card.inset(1, 1).w, rows_cap),
           @runs.size, mx, my)
        return {:runs, row}
      end
      r = current || return nil
      inner = res_card.inset(1, 1)
      return nil if inner.h <= 1
      if row = Frame.scroll_gauge_row(Rect.new(inner.x, inner.y + 1, inner.w, inner.h - 1),
           r.findings.size, mx, my)
        return {:findings, row}
      end
      nil
    end

    # Hit-test the RUNS card's run control (^R:RUN / ^X:STOP). It tracks the SELECTED row,
    # exactly as render_runs draws it, so the click acts on the run the badge is describing.
    def run_chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      r = current || return nil
      card, _ = pane_rects(rect)
      return nil if card.empty?
      chord, name = r.running? ? {"^X", "STOP"} : {"^R", "RUN"}
      Frame.right_badge_hit(mx, my, card.y, card.right - 1, card.x + RUNS_TITLE.size + 4,
        [{:run, chord, name}] of {Symbol, String, String})
    end

    private def select_run(idx : Int32) : Nil
      return if idx == @sel
      @sel = idx
      @fsel = 0
      @scroll = 0
    end
  end
end
