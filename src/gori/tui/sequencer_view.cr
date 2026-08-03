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
    # PROVENANCE: `@request` is a CAPTURED FLOW's stored bytes, not a request the operator
    # drafted. Like MinerView this session has NO editor — `@request` is only ever assigned
    # from a seed or from the store — so the flag is decided once, at load, and there is no
    # draft interpretation to fall back to. See `Sequencer::PlanOptions#evidence?`.
    getter? evidence : Bool

    def initialize
      @target = ""
      @request = Bytes.empty
      @http2 = false
      @sni = ""
      @evidence = false
      @config = Sequencer::Config.new
      @last_synced_config = ""
      @name = nil.as(String?)
      @dirty = false

      @running = false
      @stop_requested = false
      @collected = 0
      @sent = 0
      @requests = 0_i64
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
    # `evidence` is the seed's `flow_id` having been non-nil (a History/Sitemap/Issues
    # flow); a Repeater-sourced or current-session seed is a draft.
    def load(target : String, request : Bytes, http2 : Bool, sni : String?,
             config : Sequencer::Config, evidence : Bool = false) : Nil
      @target = target
      @request = request
      @http2 = http2
      @sni = sni || ""
      @config = config
      @evidence = evidence
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
      # Provenance survives a restart: `flow_id` is what `insert_sequencer_session`
      # already stored for a flow-seeded session and nothing else sets it.
      @evidence = !rec.flow_id.nil?
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
      @evidence = !rec.flow_id.nil? # see restore
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

    # `requests` is the TRUE wire count (`Fuzz::CappedBackend#sent`, what `max_requests` is
    # enforced against); `sent` counts collection attempts, and a retry charges only the
    # former. Both are shown, and only when they differ — see `results_count_label` in
    # FuzzerView for the same rule.
    def apply_progress(collected : Int32, sent : Int32, goal : Int32, errors : Int32,
                       requests : Int64 = 0_i64) : Nil
      @collected = collected
      @sent = sent
      @goal_display = goal
      @errors = errors
      @requests = requests
    end

    # Errored sends so far — `DoneEvent` does not carry an error count, so the terminal
    # apply reuses the last one the progress stream reported.
    def errors_count : Int32
      @errors
    end

    # A FINISHED collection that fell short of its goal because the request cap ran out.
    # Guarded on `max_requests` so a hand-stopped (^X) or error-ended run is not relabelled.
    def budget_exhausted? : Bool
      return false if @running
      return false unless @config.max_requests
      @goal_display > 0 && @collected < @goal_display
    end

    def budget_note : String
      "budget exhausted · #{@collected} of #{@goal_display} tokens collected — " \
      "raise max requests to finish (the verdict below rests on this sample)"
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
    # Gather this session's state into `Sequencer::PlanOptions` and let the shared builder
    # assemble the run — the view no longer knows how a collection is wired together.
    #
    # `scope` becomes the interactive `Gori::Outbound` decision every collected sample is
    # dialled through. The Sequencer used to build a bare `Fuzz::Sender` with NO gate at
    # all, so Sandbox mode did not contain it — the exact omission the Outbound seam makes
    # impossible (the decision is now a constructor argument). `overrides` is the project's
    # LIVE `Session#host_overrides` (the instance the HOST OVERRIDES pane edits and the
    # proxy reads), and it has no default: every TUI workbench tool silently took a nil one
    # and dialled the real DNS answer while `gori run sequence` pinned the override (#367),
    # so a caller has to say what it means rather than inherit that bug back.
    def build_engine(verify : Bool, scope : Gori::Scope,
                     overrides : Gori::HostOverrides?) : {Sequencer::Engine?, String?}
      # `evidence` skips the draft-time passes for a captured seed: with it off, sequencing
      # a capture whose head carried `$filter`/`$top` was refused outright, and setting the
      # variables the refusal named rewrote the request on the wire. `gori run sequence
      # --flow N` never did either.
      options = Sequencer::PlanOptions.new(@request, evidence: @evidence,
        target: @target, http2: @http2,
        config: @config, verify: verify, sni: sni_override, overrides: overrides)
      {Sequencer::Plan.build(options, Gori::Outbound.interactive(scope)).engine, nil}
    rescue ex : Sequencer::PlanError
      {nil, plan_error(ex)}
    rescue ex
      {nil, "config error: #{ex.message}"}
    end

    # The Sequencer tab's wording for a plan this view's state can't produce. The builder
    # reports the machine-readable `reason`; the hint (and the hotkeys it names) is ours.
    private def plan_error(ex : Sequencer::PlanError) : String
      case ex.reason
      in Sequencer::PlanError::Reason::NoTokens
        "no tokens to analyze — paste some first"
      in Sequencer::PlanError::Reason::NoTarget, Sequencer::PlanError::Reason::BadTarget
        "invalid target — use scheme://host[:port]/path"
      in Sequencer::PlanError::Reason::NoTokenLoc
        "set a token location first"
      in Sequencer::PlanError::Reason::UnresolvedEnv
        "unresolved env #{ex.detail} — add it in the Project tab's ENV pane"
      end
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
          j.field "max_requests", @config.max_requests
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
      # Absent (an older row) reads as nil => uncapped, which is what those runs were.
      @config.max_requests = any["max_requests"]?.try(&.as_i64?)
      any["concurrency"]?.try(&.as_i?).try { |n| @config.concurrency = n }
      any["notify"]?.try(&.as_s?).try { |t| Sequencer::NotifyMode.parse?(t) }.try { |m| @config.notify = m }
    rescue
      # malformed persisted config → keep defaults
    end

    # --- rendering ---
    # The {config, samples, analysis} rects for `rect`, TILING it exactly: the three cover
    # `rect` and nothing outside it. ONE derivation, shared by `render` and `pane_at`, so a
    # click can never be resolved against a geometry the renderer did not use.
    #
    # Each height is FLOORED for legibility (a config card under 3 rows says nothing worth
    # framing), and a floor with no matching CEILING is exactly what let this view paint
    # outside its container: on a 2-row body `cfg_h` floored back up to 3 and the lower pane
    # to 2, so five rows were drawn into two — over the status row and into the bottom
    # margin, which no later pass repaints. Every floor is therefore capped at what the
    # container actually granted, and a pane that comes out zero rows tall is declined by
    # `render` rather than handed a minimum the container cannot pay for.
    #
    # `sw` needs no cap: it is gated behind `lower.w >= 84`, far above its floor of 30.
    private def pane_rects(rect : Rect) : {Rect, Rect, Rect}
      cfg_h = {rect.h // 3, 7}.min
      cfg_h = rect.h - 4 if cfg_h > rect.h - 4
      cfg_h = { {cfg_h, 3}.max, rect.h }.min
      cfg_rect = Rect.new(rect.x, rect.y, rect.w, cfg_h)
      lower = Rect.new(rect.x, rect.y + cfg_h, rect.w, {rect.h - cfg_h, 0}.max)
      if lower.w >= 84
        sw = {lower.w * 42 // 100, 30}.max
        {cfg_rect,
         Rect.new(lower.x, lower.y, sw, lower.h),
         Rect.new(lower.x + sw, lower.y, lower.w - sw, lower.h)}
      else
        sh = { {lower.h * 45 // 100, 4}.max, lower.h }.min
        {cfg_rect,
         Rect.new(lower.x, lower.y, lower.w, sh),
         Rect.new(lower.x, lower.y + sh, lower.w, lower.h - sh)}
      end
    end

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      return render_detail(screen, rect, focused) if @focus == :detail
      cfg_rect, s_rect, a_rect = pane_rects(rect)
      # The layout flag the CONTROLLER reads for ↑/↓ pane traversal, so it is written here
      # and never by `pane_at` — a hit-test must not move focus state as a side effect.
      @side_by_side = rect.w >= 84
      render_config(screen, cfg_rect, focused && @focus == :config)
      render_samples(screen, s_rect, focused && @focus == :samples) unless s_rect.empty?
      render_analysis(screen, a_rect, focused && @focus == :analysis) unless a_rect.empty?
    end

    private def render_config(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "SEQUENCER", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      chord, name = @running ? {"^X", "STOP"} : {"^R", "RUN"}
      Frame.toggle_badge(screen, rect.right - 1, rect.y, rect.x + "SEQUENCER".size + 4, chord, name, @running)
      x = rect.x + 2
      y = rect.y + 1
      # Guarded like every line below it: on a 1-2 row card `rect.y + 1` is the bottom
      # border row or past the card entirely, and this line alone was unconditional.
      screen.text(x, y, summary(rect.w - 4), Theme.text_bright, Theme.bg, Attribute::Bold) if y < rect.bottom - 1
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
        wire = @requests > @sent ? " · #{@requests} requests" : ""
        line = "#{@collected}/#{@goal_display <= 0 ? "?" : @goal_display.to_s} collected · #{@sent} sent#{wire} · #{@errors} err"
        screen.text(x, y, line, Theme.muted, Theme.bg, width: rect.w - 4)
      end
      y += 1
      if budget_exhausted? && y < rect.bottom - 1
        screen.text(x, y, budget_note, Theme.yellow, Theme.bg, width: rect.w - 4)
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
      # A card under 3 rows has no interior — `inset` floors the height at 0 but keeps
      # `inner.y` one row down, so an unguarded placeholder lands OUTSIDE the pane.
      return if inner.h <= 0 || inner.w <= 0
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
      return if inner.h <= 0 || inner.w <= 0 # see render_samples: no interior to draw into
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
    # Derived from `pane_rects`, the same tiling `render` draws into — the two used to
    # re-compute the geometry independently, so the hit-test faithfully agreed with the
    # INFLATED rects rather than with the pane the operator could see.
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless rect.contains?(mx, my)
      return :detail if @focus == :detail
      cfg_rect, s_rect, a_rect = pane_rects(rect)
      return :samples if s_rect.contains?(mx, my)
      return :analysis if a_rect.contains?(mx, my)
      cfg_rect.contains?(mx, my) ? :config : nil
    end
  end
end
