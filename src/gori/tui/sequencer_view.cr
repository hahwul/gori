require "json"
require "./screen"
require "./theme"
require "./frame"
require "./spark"
require "./fmt"
require "../store"
require "../sequencer"
require "../fuzz"
require "../repeater/flow_request"

module Gori::Tui
  # The view for ONE token-randomness session (a sub-tab under the Sequencer tab). The
  # request + token descriptor are chosen in the config overlay, then the engine collects
  # tokens in the background and this view streams them and grades their randomness.
  # Panes: :config (target/descriptor/progress), :samples (collected tokens), :analysis
  # (entropy figures + per-test verdicts + charts); :detail overlays a single token.
  # Mirrors MinerView's session shape; collected tokens stay in-memory (never persisted).
  class SequencerView
    PANE_ORDER      = [:config, :samples, :analysis]
    REPORT_THROTTLE = 25 # recompute the report every N new samples while running

    property name : String?
    getter focus : Symbol
    getter config : Sequencer::Config
    property job_id : Int32

    def initialize
      @target = ""
      @request = Bytes.empty
      @http2 = false
      @sni = ""
      @config = Sequencer::Config.new
      @last_synced_config = ""
      @name = nil.as(String?)
      @dirty = false

      @running = false
      @stop_requested = false
      @collected = 0
      @sent = 0
      @errors = 0
      @goal_display = 0
      @samples = [] of Sequencer::Sample
      @samples_rev = 0
      @report = nil.as(Sequencer::Stats::Report?)
      @report_rev = -1

      @focus = :config
      @sel = 0
      @scroll = 0
      @analysis_scroll = 0
      @analysis_line_count = 0
      @analysis_h = 0
      @side_by_side = true # last render layout (Samples | Analysis vs stacked)
      @detail_scroll = 0
      @job_id = 0
    end

    # --- seed / restore ---
    def load(target : String, request : Bytes, http2 : Bool, sni : String?, config : Sequencer::Config) : Nil
      @target = target
      @request = request
      @http2 = http2
      @sni = sni || ""
      @config = config
      @dirty = true
    end

    # Replace the config (a reconfigure of the token descriptor / goal via the overlay).
    def set_config(config : Sequencer::Config) : Nil
      @config = config
      @dirty = true
    end

    # Append more manual tokens (a repeated "Send selection to Sequencer" into an open
    # manual session — the "build a corpus by pasting" workflow).
    def append_manual_tokens(tokens : Array(String)) : Nil
      @config.manual_tokens.concat(tokens)
      @dirty = true
    end

    def restore(rec : Store::SequencerSessionRecord) : Nil
      @target = rec.target
      @request = rec.request
      @http2 = rec.http2?
      @sni = rec.sni || ""
      @name = rec.name
      apply_config_json(rec.config)
      @last_synced_config = rec.config
      @dirty = false
    end

    def apply_peer_session(rec : Store::SequencerSessionRecord) : Nil
      @target = rec.target
      @request = rec.request
      @http2 = rec.http2?
      @sni = rec.sni || ""
      @name = rec.name
      apply_config_json(rec.config)
      @last_synced_config = rec.config
      @dirty = false
    end

    def session_side_matches?(rec : Store::SequencerSessionRecord) : Bool
      @target == rec.target &&
        @request == rec.request &&
        @http2 == rec.http2? &&
        (sni_override || "") == (rec.sni || "") &&
        (@name || "") == (rec.name || "") &&
        @last_synced_config == rec.config
    end

    # --- persistence accessors ---
    def request_bytes : Bytes
      @request
    end

    def http2? : Bool
      @http2
    end

    def sni_override : String?
      s = @sni.strip
      s.empty? ? nil : s
    end

    def same?(other : SequencerView) : Bool
      object_id == other.object_id
    end

    def same?(oid : UInt64) : Bool
      object_id == oid
    end

    def dirty? : Bool
      @dirty
    end

    def clear_dirty : Nil
      @dirty = false
    end

    def mark_config_synced(config : String) : Nil
      @last_synced_config = config
    end

    def request_line : String
      String.new(@request[0, {@request.size, 256}.min]).each_line.first? || ""
    end

    def request_method : String
      request_line.strip.split(' ').first? || ""
    end

    def summary(max : Int32 = 32) : String
      if @config.mode.manual?
        s = "manual (#{@config.manual_tokens.size} tokens)"
        return s.size > max ? "#{s[0, max - 1]}…" : s
      end
      parts = request_line.strip.split(' ')
      s = "#{parts[0]?} #{parts[1]?}".strip
      s = "request" if s.empty?
      s.size > max ? "#{s[0, max - 1]}…" : s
    end

    def label(max : Int32 = 18) : String
      if (n = @name) && !(t = n.strip).empty?
        return t.size > max ? "#{t[0, max - 1]}…" : t
      end
      summary(max)
    end

    def target_origin : String
      return "manual" if @config.mode.manual?
      scheme, host, port = Repeater::FlowRequest.parse_target(@target)
      "#{scheme}://#{host}:#{port}"
    end

    def target : String
      @target
    end

    # --- focus ring ---
    def focus_pane(pane : Symbol) : Nil
      @focus = pane if PANE_ORDER.includes?(pane)
    end

    def focus_first : Nil
      @focus = :config
    end

    def focus_last : Nil
      @focus = :analysis
    end

    def at_top? : Bool
      @focus == :config
    end

    def samples_at_top? : Bool
      @sel == 0
    end

    def samples_at_bottom? : Bool
      return true if @samples.empty?
      @sel >= @samples.size - 1
    end

    def analysis_at_top? : Bool
      @analysis_scroll <= 0
    end

    # Last render put Samples and Analysis side-by-side (wide) vs stacked (narrow).
    def side_by_side? : Bool
      @side_by_side
    end

    def pane_advance(dir : Int32) : Bool
      idx = PANE_ORDER.index(@focus) || 0
      nidx = idx + dir
      return false unless 0 <= nidx < PANE_ORDER.size
      @focus = PANE_ORDER[nidx]
      true
    end

    # --- samples nav ---
    def samples_move(d : Int32) : Nil
      return if @samples.empty?
      @sel = (@sel + d).clamp(0, @samples.size - 1)
    end

    def analysis_scroll(d : Int32) : Nil
      max = {@analysis_line_count - @analysis_h, 0}.max
      @analysis_scroll = (@analysis_scroll + d).clamp(0, max)
    end

    def open_detail : Nil
      return if @samples.empty?
      @detail_scroll = 0
      @focus = :detail
    end

    def detail_scroll(d : Int32) : Nil
      @detail_scroll = {@detail_scroll + d, 0}.max
    end

    def close_detail : Nil
      @focus = :samples
    end

    # --- run state ---
    def running? : Bool
      @running
    end

    def stop_requested? : Bool
      @stop_requested
    end

    def request_stop : Nil
      @stop_requested = true
    end

    def begin_run : Nil
      @running = true
      @stop_requested = false
      @collected = 0
      @sent = 0
      @errors = 0
      @goal_display = @config.mode.manual? ? @config.manual_tokens.count { |t| !t.empty? } : @config.goal
      @samples.clear
      @samples_rev += 1
      @report = nil
      @report_rev = -1
      @sel = 0
      @scroll = 0
      @analysis_scroll = 0
    end

    def finish_run : Nil
      @running = false
    end

    def append_sample(s : Sequencer::Sample) : Nil
      @samples << s
      @samples_rev += 1
    end

    def apply_progress(collected : Int32, sent : Int32, goal : Int32, errors : Int32) : Nil
      @collected = collected
      @sent = sent
      @goal_display = goal
      @errors = errors
    end

    def collected_count : Int32
      @samples.count(&.token)
    end

    def selected_sample : Sequencer::Sample?
      @samples[@sel]?
    end

    # Lazily (re)compute the randomness report over the collected tokens. Throttled
    # during a run so a fast collection doesn't re-run the whole test suite per sample;
    # always fresh once the run finishes.
    def report : Sequencer::Stats::Report
      cached = @report
      return cached if cached && @report_rev == @samples_rev
      # Analyze is O(n) with large transient allocations (a full symbol bitstream), so scale
      # the mid-run recompute cadence with corpus size: a several-thousand-token paste rebuilds
      # only a handful of times instead of every 25 samples. The post-run path (!@running) below
      # still recomputes an exact final report.
      throttle = {REPORT_THROTTLE, @samples.size // 20}.max
      return cached if cached && @running && (@samples_rev - @report_rev) < throttle
      fresh = Sequencer::Stats.analyze(@samples.compact_map(&.token))
      @report = fresh
      @report_rev = @samples_rev
      fresh
    end

    # --- engine ---
    def build_engine(verify : Bool) : {Sequencer::Engine?, String?}
      if @config.mode.manual?
        return {nil, "no tokens to analyze — paste some first"} if @config.manual_tokens.all?(&.empty?)
        dummy = Fuzz::Sender.new(Fuzz::Origin.new("http", "localhost", 80), http2: false, verify: false)
        return {Sequencer::Engine.new(Bytes.empty, false, dummy, @config), nil}
      end
      scheme, host, port = Repeater::FlowRequest.parse_target(@target)
      return {nil, "invalid target — use scheme://host[:port]/path"} if host.empty?
      loc = @config.token_loc
      return {nil, "set a token location first"} if loc.selector.strip.empty? && !loc.kind.position?
      sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
        http2: @http2, verify: verify, sni: sni_override, timeout: @config.timeout)
      {Sequencer::Engine.new(@request, @http2, sender, @config), nil}
    rescue ex
      {nil, "config error: #{ex.message}"}
    end

    # --- config (de)serialization (opaque JSON; manual tokens are secrets, never stored) ---
    def config_json : String
      loc = @config.token_loc
      JSON.build do |j|
        j.object do
          j.field "mode", @config.mode.live_replay? ? "live" : "manual"
          j.field "kind", loc.kind.label
          j.field "selector", loc.selector
          j.field "pos_start", loc.pos_start
          j.field "pos_end", loc.pos_end
          j.field "goal", @config.goal
          j.field "concurrency", @config.concurrency
          j.field "notify", @config.notify.token
        end
      end
    end

    private def apply_config_json(s : String) : Nil
      return if s.strip.empty?
      any = JSON.parse(s)
      any["mode"]?.try(&.as_s?).try { |m| Sequencer::Mode.parse?(m) }.try { |m| @config.mode = m }
      kind = any["kind"]?.try(&.as_s?).try { |k| Sequencer::ExtractKind.parse?(k) } || @config.token_loc.kind
      selector = any["selector"]?.try(&.as_s?) || ""
      pstart = any["pos_start"]?.try(&.as_i?) || 0
      pend = any["pos_end"]?.try(&.as_i?) || 0
      @config.token_loc = Sequencer::TokenLoc.new(kind, selector, pstart, pend)
      any["goal"]?.try(&.as_i?).try { |n| @config.goal = n }
      any["concurrency"]?.try(&.as_i?).try { |n| @config.concurrency = n }
      any["notify"]?.try(&.as_s?).try { |t| Sequencer::NotifyMode.parse?(t) }.try { |m| @config.notify = m }
    rescue
      # malformed persisted config → keep defaults
    end

    # --- rendering ---
    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return render_detail(screen, rect, focused) if @focus == :detail
      cfg_h = {rect.h // 3, 7}.min
      cfg_h = rect.h - 4 if cfg_h > rect.h - 4
      cfg_h = {cfg_h, 3}.max
      cfg_rect = Rect.new(rect.x, rect.y, rect.w, cfg_h)
      lower = Rect.new(rect.x, rect.y + cfg_h, rect.w, {rect.h - cfg_h, 2}.max)
      render_config(screen, cfg_rect, focused && @focus == :config)

      @side_by_side = lower.w >= 84
      if @side_by_side
        sw = {lower.w * 42 // 100, 30}.max
        s_rect = Rect.new(lower.x, lower.y, sw, lower.h)
        a_rect = Rect.new(lower.x + sw, lower.y, lower.w - sw, lower.h)
        render_samples(screen, s_rect, focused && @focus == :samples)
        render_analysis(screen, a_rect, focused && @focus == :analysis)
      else
        sh = {lower.h * 45 // 100, 4}.max
        s_rect = Rect.new(lower.x, lower.y, lower.w, sh)
        a_rect = Rect.new(lower.x, lower.y + sh, lower.w, {lower.h - sh, 3}.max)
        render_samples(screen, s_rect, focused && @focus == :samples)
        render_analysis(screen, a_rect, focused && @focus == :analysis)
      end
    end

    private def render_config(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "SEQUENCER", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      chord, name = @running ? {"^X", "STOP"} : {"^R", "RUN"}
      Frame.toggle_badge(screen, rect.right - 1, rect.y, rect.x + "SEQUENCER".size + 4, chord, name, @running)
      x = rect.x + 2
      y = rect.y + 1
      screen.text(x, y, summary(rect.w - 4), Theme.text_bright, Theme.bg, Attribute::Bold)
      y += 1
      if y < rect.bottom - 1
        mode = @config.mode.live_replay? ? "live replay · #{target_origin}" : "manual paste"
        screen.text(x, y, mode, Theme.muted, Theme.bg, width: rect.w - 4)
      end
      y += 1
      if y < rect.bottom - 1
        screen.text(x, y, "token: #{@config.token_loc.label}", Theme.text, Theme.bg, width: rect.w - 4)
      end
      y += 1
      if y < rect.bottom - 1
        bar = progress_bar(rect.w - 4)
        screen.text(x, y, bar, Theme.accent, Theme.bg)
      end
      y += 1
      if y < rect.bottom - 1
        line = "#{@collected}/#{@goal_display <= 0 ? "?" : @goal_display.to_s} collected · #{@sent} sent · #{@errors} err"
        screen.text(x, y, line, Theme.muted, Theme.bg, width: rect.w - 4)
      end
    end

    private def progress_bar(w : Int32) : String
      total = @goal_display
      return "—" if total <= 0 || w <= 0
      filled = ((@collected.to_f / total) * w).to_i.clamp(0, w)
      "#{"█" * filled}#{"░" * (w - filled)}"
    end

    private def render_samples(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "SAMPLES (#{@samples.size})", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(1, 1)
      if @samples.empty?
        msg = if @running
                "collecting…"
              elsif @config.mode.manual?
                "paste tokens (space → Configure), then ^R"
              else
                "no samples — ^R to collect (space → Configure to set the token location)"
              end
        screen.text(inner.x + 1, inner.y, msg, Theme.muted, Theme.bg, width: inner.w - 1)
        return
      end
      screen.text(inner.x + 2, inner.y, "#", Theme.muted, Theme.bg)
      screen.text(inner.x + 8, inner.y, "STATUS", Theme.muted, Theme.bg)
      screen.text(inner.x + 16, inner.y, "TOKEN", Theme.muted, Theme.bg)
      screen.text(inner.right - 5, inner.y, "LEN", Theme.muted, Theme.bg)
      cap = inner.h - 1
      ensure_visible(cap)
      cap.times do |i|
        idx = @scroll + i
        break if idx >= @samples.size
        draw_sample(screen, inner, idx, inner.y + 1 + i, focused)
      end
      Frame.scroll_gauge(screen, Rect.new(inner.x, inner.y + 1, inner.w, cap), @samples.size, @scroll, focused)
    end

    private def draw_sample(screen : Screen, inner : Rect, idx : Int32, py : Int32, focused : Bool) : Nil
      s = @samples[idx]
      sel = idx == @sel
      bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(inner.x, py, inner.w, 1), bg)
      screen.cell(inner.x, py, sel ? '▎' : ' ', Theme.accent, bg)
      screen.text(inner.x + 2, py, (idx + 1).to_s, Theme.muted, bg, width: 5)
      status = s.status
      screen.text(inner.x + 8, py, status ? status.to_s : (s.error ? "ERR" : "—"),
        status ? Theme.status_color(status) : Theme.muted, bg, width: 7)
      tok_w = {inner.right - 5 - (inner.x + 16), 6}.max
      if tok = s.token
        screen.text(inner.x + 16, py, preview(tok, tok_w), sel ? Theme.text_bright : Theme.text, bg, width: tok_w)
        screen.text(inner.right - 5, py, s.length.to_s, Theme.muted, bg, width: 5)
      else
        screen.text(inner.x + 16, py, s.error || "no token", Theme.red, bg, width: tok_w)
      end
    end

    # Escape non-printables so a binary token can't corrupt the row, then truncate.
    private def preview(tok : String, w : Int32) : String
      clean = String.build do |io|
        tok.each_char do |c|
          io << (c.ascii_control? || c.ord > 0x7e ? '·' : c)
        end
      end
      clean.size > w ? "#{clean[0, w - 1]}…" : clean
    end

    private def ensure_visible(cap : Int32) : Nil
      return if cap <= 0
      # Auto-follow the tail while a run streams (unless the user scrolled up).
      @sel = @samples.size - 1 if @running && @sel >= @samples.size - 1
      @scroll = @sel if @sel < @scroll
      @scroll = @sel - cap + 1 if @sel >= @scroll + cap
      @scroll = 0 if @scroll < 0
    end

    # --- analysis pane ---
    private def render_analysis(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "ANALYSIS", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(1, 1)
      @analysis_h = {inner.h, 0}.max
      return if inner.h <= 0 || inner.w <= 2
      rep = report
      if rep.usable_count == 0
        @analysis_line_count = 1
        @analysis_scroll = 0
        screen.text(inner.x + 1, inner.y, @running ? "collecting…" : "no tokens yet", Theme.muted, Theme.bg)
        return
      end
      lines = analysis_lines(rep, inner.w)
      @analysis_line_count = lines.size
      max_scroll = {lines.size - inner.h, 0}.max
      @analysis_scroll = @analysis_scroll.clamp(0, max_scroll)
      inner.h.times do |i|
        li = @analysis_scroll + i
        break if li >= lines.size
        draw_analysis_line(screen, inner, lines[li], inner.y + i)
      end
      Frame.scroll_gauge(screen, inner, lines.size, @analysis_scroll, focused)
    end

    # A flat display line for the analysis pane. `kind` ∈ :banner :kv :divider :test :spark.
    private record ALine, kind : Symbol, a : String, b : String, verdict : Sequencer::Stats::Verdict? = nil

    private def analysis_lines(rep : Sequencer::Stats::Report, w : Int32) : Array(ALine)
      lines = [] of ALine
      lines << ALine.new(:banner, rep.rating.label, rep.rationale)
      lines << ALine.new(:kv, "effective", "#{Fmt.bits(rep.effective_entropy)}")
      lines << ALine.new(:kv, "shannon", "#{Fmt.bits(rep.bits_per_char)}/char")
      lines << ALine.new(:kv, "charset", "#{rep.charset_size} (#{rep.charset_label})")
      len = rep.variable_length ? "#{rep.min_len}-#{rep.max_len} var" : "#{rep.min_len} fixed"
      lines << ALine.new(:kv, "length", len)
      lines << ALine.new(:kv, "unique", "#{Fmt.pct(rep.uniqueness)}")
      lines << ALine.new(:divider, "tests", "")
      rep.tests.each { |t| lines << ALine.new(:test, t.name, t.value, t.verdict) }
      spark_w = {w - 8, 6}.max
      unless rep.char_counts.empty?
        counts = rep.char_counts.first(spark_w).map { |(_, c)| c }
        lines << ALine.new(:spark, "char", Spark.line(counts, {counts.size, spark_w}.min))
      end
      unless rep.per_pos_entropy.empty?
        pos = rep.per_pos_entropy.map { |e| (e * 100).round.to_i }
        lines << ALine.new(:spark, "pos", Spark.line(pos, spark_w))
      end
      lines
    end

    private def draw_analysis_line(screen : Screen, inner : Rect, line : ALine, py : Int32) : Nil
      case line.kind
      when :banner
        color = rating_color(line.a)
        screen.fill(Rect.new(inner.x, py, inner.w, 1), color)
        ink = Theme.ink_on(color)
        screen.text(inner.x + 1, py, " #{line.a} ", ink, color, Attribute::Bold)
        screen.text(inner.x + 3 + line.a.size, py, line.b, ink, color, width: {inner.w - 4 - line.a.size, 1}.max)
      when :divider
        screen.text(inner.x, py, "── #{line.a} ", Theme.muted, Theme.bg)
        w = inner.w - line.a.size - 4
        screen.text(inner.x + line.a.size + 4, py, "─" * {w, 0}.max, Theme.border, Theme.bg) if w > 0
      when :kv
        screen.text(inner.x, py, line.a, Theme.muted, Theme.bg, width: 10)
        screen.text(inner.x + 10, py, line.b, Theme.text, Theme.bg, width: {inner.w - 10, 1}.max)
      when :test
        screen.text(inner.x, py, line.a, Theme.text, Theme.bg, width: 13)
        screen.text(inner.x + 13, py, line.b, Theme.muted, Theme.bg, width: {inner.w - 20, 1}.max)
        if v = line.verdict
          screen.text(inner.right - 5, py, v.label, verdict_color(v), Theme.bg)
        end
      when :spark
        screen.text(inner.x, py, line.a, Theme.muted, Theme.bg, width: 5)
        screen.text(inner.x + 5, py, line.b, Theme.text, Theme.bg, width: {inner.w - 5, 1}.max)
      end
    end

    private def rating_color(label : String) : Color
      case label
      when "SECURE"   then Theme.green
      when "MODERATE" then Theme.yellow
      when "WEAK"     then Theme.orange
      else                 Theme.red
      end
    end

    private def verdict_color(v : Sequencer::Stats::Verdict) : Color
      case v
      in Sequencer::Stats::Verdict::Pass then Theme.green
      in Sequencer::Stats::Verdict::Warn then Theme.yellow
      in Sequencer::Stats::Verdict::Fail then Theme.red
      in Sequencer::Stats::Verdict::Info then Theme.muted
      end
    end

    # --- detail overlay for one sample ---
    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "TOKEN", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(2, 1)
      s = selected_sample
      unless s
        screen.text(inner.x, inner.y, "no sample selected", Theme.muted, Theme.bg)
        return
      end
      lines = detail_lines(s)
      lines.each_with_index do |(lbl, val, color), i|
        y = inner.y + i - @detail_scroll
        next unless inner.y <= y < inner.bottom
        screen.text(inner.x, y, lbl, Theme.muted, Theme.bg)
        screen.text(inner.x + 10, y, val, color, Theme.bg, width: {inner.w - 10, 1}.max)
      end
    end

    private def detail_lines(s : Sequencer::Sample) : Array({String, String, Color})
      [
        {"index", (s.index).to_s, Theme.text},
        {"status", s.status.try(&.to_s) || "—", s.status ? Theme.status_color(s.status) : Theme.muted},
        {"length", s.length.to_s, Theme.text},
        {"duration", s.duration_us > 0 ? Fmt.dur(s.duration_us) : "—", Theme.muted},
        {"error", s.error || "—", s.error ? Theme.red : Theme.muted},
        {"token", s.token || "—", Theme.text_bright},
      ]
    end

    # --- click hit-test ---
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return :detail if @focus == :detail && rect.contains?(mx, my)
      cfg_h = {rect.h // 3, 7}.min
      cfg_h = rect.h - 4 if cfg_h > rect.h - 4
      cfg_h = {cfg_h, 3}.max
      return :config if my < rect.y + cfg_h
      return nil unless rect.contains?(mx, my)
      lower = Rect.new(rect.x, rect.y + cfg_h, rect.w, rect.h - cfg_h)
      if lower.w >= 84
        sw = {lower.w * 42 // 100, 30}.max
        mx < lower.x + sw ? :samples : :analysis
      else
        sh = {lower.h * 45 // 100, 4}.max
        my < lower.y + sh ? :samples : :analysis
      end
    end
  end
end
