require "./screen"
require "./theme"
require "./frame"
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
    property status : Symbol = :idle # :idle | :running | :paused | :done | :stopped | :error
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

  # The Discover sub-tab body: a summary/control card + a live findings table for the
  # SELECTED run (multiple runs cycle with [ / ]). Read-only — runs are launched from the
  # config overlay (Sitemap/History space menu or ^R here).
  class DiscoverView
    def initialize
      @runs = [] of DiscoverRun
      @sel = 0
      @fsel = 0
      @scroll = 0
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
        @sel = idx
        @fsel = 0
        @scroll = 0
      end
    end

    def any_running? : Bool
      @runs.any?(&.running?)
    end

    # --- nav ---
    def move(d : Int32) : Nil
      return unless r = current
      return if r.findings.empty?
      @fsel = (@fsel + d).clamp(0, r.findings.size - 1)
    end

    def selected_finding : Discover::Finding?
      current.try(&.findings[@fsel]?)
    end

    def at_top? : Bool
      @fsel == 0
    end

    # --- rendering ---
    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      sum_h = {rect.h // 3, 7}.min
      sum_h = rect.h - 3 if sum_h > rect.h - 3
      sum_rect = Rect.new(rect.x, rect.y, rect.w, {sum_h, 1}.max)
      res_rect = Rect.new(rect.x, rect.y + sum_rect.h, rect.w, {rect.h - sum_rect.h, 1}.max)
      render_summary(screen, sum_rect, focused)
      render_findings(screen, res_rect, focused)
    end

    private def render_summary(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "DISCOVER", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      r = current
      unless r
        screen.text(rect.x + 2, rect.y + 1,
          "no runs — from Sitemap/History press space → \"Discover here\"", Theme.muted, Theme.bg, width: rect.w - 4)
        return
      end
      running = r.running?
      chord, name = running ? {"^X", "STOP"} : {"^R", "RUN"}
      Frame.toggle_badge(screen, rect.right - 1, rect.y, rect.x + "DISCOVER".size + 4, chord, name, running)
      x = rect.x + 2
      y = rect.y + 1
      hdr = @runs.size > 1 ? "run #{@sel + 1}/#{@runs.size}  #{r.label(rect.w - 20)}" : r.label(rect.w - 6)
      screen.text(x, y, hdr, Theme.text_bright, Theme.bg, Attribute::Bold, width: rect.w - 4)
      y += 1
      if y < rect.bottom - 1
        screen.text(x, y, "#{r.techniques} · #{r.config.containment.label} · depth #{r.config.max_depth}",
          Theme.muted, Theme.bg, width: rect.w - 4)
      end
      y += 1
      if y < rect.bottom - 1
        st = r.status == :error ? "error: #{r.error_msg}" : r.status.to_s
        screen.text(x, y, st, status_hue(r.status), Theme.bg, width: rect.w - 4)
      end
      y += 1
      if y < rect.bottom - 1
        screen.text(x, y, "found #{r.found} · #{r.sent} sent · #{r.queued} queued · #{r.errors} err",
          Theme.muted, Theme.bg, width: rect.w - 4)
      end
      y += 1
      if (s = r.stats) && y < rect.bottom - 1
        screen.text(x, y, "fp-cut #{s.calibrated_out} · dedup #{s.dedup_suppressed} · tmpl #{s.template_suppressed} · clust #{s.cluster_suppressed}",
          Theme.muted, Theme.bg, width: rect.w - 4)
      end
    end

    private def status_hue(s : Symbol) : Color
      case s
      when :running then Theme.accent
      when :paused  then Theme.yellow
      when :error   then Theme.red
      when :stopped then Theme.muted
      else               Theme.green
      end
    end

    private def render_findings(screen : Screen, rect : Rect, focused : Bool) : Nil
      r = current
      n = r ? r.findings.size : 0
      Frame.card(screen, rect, "FINDINGS (#{n})", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(1, 1)
      return unless r
      if r.findings.empty?
        msg = r.running? ? "discovering… endpoints appear here" : (r.stats ? "no endpoints found" : "no run yet — ^R to run")
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
      rect.contains?(mx, my) ? :findings : nil
    end
  end
end
