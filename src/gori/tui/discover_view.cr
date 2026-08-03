require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "../discover"

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

    def begin_run : Nil
      @status = :running
      @stop_requested = false
      @findings.clear
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

    def findings_at_top? : Bool
      @fsel == 0
    end

    # --- rendering ---
    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
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
      title = "RUNS (#{@runs.size})"
      Frame.card(screen, rect, title, border: Frame.pane_border(focused), bg: Theme.bg)
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
      Frame.toggle_badge(screen, rect.right - 1, rect.y, rect.x + title.size + 4, chord, name, r.running?)

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
          "fp-cut #{s.calibrated_out} · dedup #{s.dedup_suppressed} · tmpl #{s.template_suppressed} · clust #{s.cluster_suppressed}"
        else
          "found #{r.found} · #{r.sent} sent · #{r.queued} queued · #{r.errors} err"
        end
      end
    end

    private def detail_hue(s : Symbol) : Color
      s == :error || s == :budget_exhausted ? status_hue(s) : Theme.muted
    end

    private def ensure_run_visible(cap : Int32) : Nil
      return if cap <= 0
      @rscroll = @sel if @sel < @rscroll
      @rscroll = @sel - cap + 1 if @sel >= @rscroll + cap
      @rscroll = 0 if @rscroll < 0
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
      Frame.card(screen, rect, "FINDINGS (#{n})", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
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
      ensure_visible(cap, r)
      cap.times do |i|
        idx = @scroll + i
        break if idx >= r.findings.size
        draw_row(screen, inner, r.findings[idx], idx, inner.y + 1 + i, focused)
      end
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

    private def ensure_visible(cap : Int32, r : DiscoverRun) : Nil
      return if cap <= 0
      @scroll = @fsel if @fsel < @scroll
      @scroll = @fsel - cap + 1 if @fsel >= @scroll + cap
      @scroll = 0 if @scroll < 0
    end

    # --- click hit-test ---
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless rect.contains?(mx, my)
      runs_rect, res_rect = pane_rects(rect) # the tiling render draws into, not a re-derivation
      return :runs if runs_rect.contains?(mx, my)
      res_rect.contains?(mx, my) ? :findings : nil
    end

    # Focus the clicked pane, and on a RUNS row select that run — clicking a row is the
    # discoverable way to reach an earlier crawl before pressing ^X on it.
    def click(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless pane = pane_at(rect, mx, my)
      focus_pane(pane)
      return unless pane == :runs
      card, _ = pane_rects(rect) # the same rect render framed, so a row click can't miss it
      rows_y, rows_cap, _ = run_bands(card)
      row = my - rows_y
      return unless 0 <= row < rows_cap
      idx = @rscroll + row
      return unless 0 <= idx < @runs.size
      select_run(idx)
    end

    private def select_run(idx : Int32) : Nil
      return if idx == @sel
      @sel = idx
      @fsel = 0
      @scroll = 0
    end
  end
end
