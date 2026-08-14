require "json"
require "./screen"
require "./theme"
require "./frame"
require "./read_pane"
require "./traffic_empty_state"
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
      # The ANALYSIS report's row cursor, selection and scroll. `line_select_only`: a row here is
      # a label/value pair drawn in two columns (or a banner, or a sparkline), so a char rectangle
      # would address cells that are not adjacent — selection is whole rows, and the copy payload
      # is the row projected to `"label  value"`. The pane paints its own rows (`draw_analysis_line`
      # is kind-specific), so `ReadPane#render` is never called; `viewport_top` + `row_marked?` are.
      # Before this, the entropy report was readable and there was no way to get it out.
      @analysis = ReadPane.new(line_select_only: true)
      @analysis_w = 0      # last drawn interior width — `analysis_lines` sizes its sparkline from it
      @side_by_side = true # last render layout (Samples | Analysis vs stacked)
      # The TOKEN pane's row cursor — same shape as ANALYSIS above, over its six `label  value`
      # field rows. The token itself is the thing an operator reaches for, and this pane had no
      # copy of any kind.
      @token = ReadPane.new(line_select_only: true)
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

    # The host an Issue filed from this session belongs to. nil for a manual paste, which has
    # no origin at all — `insert_issue` takes a nilable host for exactly that case.
    def target_host : String?
      return nil if @config.mode.manual?
      _, host, _ = Repeater::FlowRequest.parse_target(@target)
      host.empty? ? nil : host
    end

    # What this session's report is ABOUT — see `Sequencer::Present::Subject`. Built here
    # because the view is the only place holding the descriptor, the origin and the operator's
    # name for the session at once, so the exported file and an Issue promoted from the same
    # verdict cannot describe the run differently.
    def subject : Sequencer::Present::Subject
      Sequencer::Present::Subject.new(
        descriptor: @config.token_loc.label,
        origin: @config.mode.manual? ? nil : target_origin,
        mode: @config.mode.label,
        session: @name.try(&.strip).presence)
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
      @analysis.at_top?
    end

    def analysis : ReadPane
      @analysis
    end

    # The ANALYSIS card's interior — the rect `render_analysis` draws into, so the row cursor's
    # click and the draw address the same rows. Empty when the pane is not on screen.
    def analysis_body(rect : Rect) : Rect
      _, _, an = pane_rects(rect)
      an.empty? ? an : an.inset(1, 1)
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

    # ↑/↓ (⇧ to select) walk the report rows; the wheel scrolls the viewport and leaves the
    # cursor put — the split every read pane in the tree makes.
    def analysis_scroll(d : Int32) : Nil
      sync_analysis
      @analysis.move(d, 0)
    end

    def analysis_move(d : Int32, selecting : Bool) : Nil
      sync_analysis
      @analysis.move(d, 0, selecting: selecting)
    end

    def analysis_wheel(d : Int32) : Nil
      sync_analysis
      @analysis.scroll_view(d)
    end

    def analysis_motion_key(ev : Termisu::Event::Key) : Bool
      sync_analysis
      @analysis.motion_key(ev)
    end

    def analysis_select_line : Nil
      sync_analysis
      @analysis.select_line
    end

    def analysis_clear_selection : Nil
      @analysis.clear_selection
    end

    def analysis_selection? : Bool
      @analysis.selection?
    end

    def analysis_copy_text : String
      sync_analysis
      @analysis.copy_text
    end

    def analysis_copy_all : String
      sync_analysis
      @analysis.copy_all
    end

    def analysis_click(body : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      sync_analysis
      @analysis.click(body, mx, my, selecting)
    end

    # Point the row cursor at the current report. Idempotent — `report` is the engine's own cached
    # value — so every gesture and every verb can call it and none can act on a stale row count.
    private def sync_analysis : Nil
      ls = analysis_lines(report, {@analysis_w, 20}.max)
      @analysis.source(ls.size, ->(i : Int32) { analysis_plain(ls[i]) })
    end

    # ONE report row projected to ONE line of text — the copy payload, 1:1 with the screen rows so
    # row N of a paste is row N of the report. A banner and a divider carry their own words; a
    # kv/test/spark row is `label  value`.
    private def analysis_plain(l : ALine) : String
      case l.kind
      when :banner  then "#{l.a} — #{l.b}"
      when :divider then "-- #{l.a} --"
      when :test    then (v = l.verdict) ? "#{l.a}  #{l.b}  #{v.label}" : "#{l.a}  #{l.b}"
      else               "#{l.a}  #{l.b}"
      end
    end

    def open_detail : Nil
      return if @samples.empty?
      @token.reset
      @focus = :detail
    end

    def detail_scroll(d : Int32) : Nil
      with_token { @token.move(d, 0) }
    end

    def detail_move(d : Int32, selecting : Bool) : Nil
      with_token { @token.move(d, 0, selecting: selecting) }
    end

    def detail_wheel(d : Int32) : Nil
      with_token { @token.scroll_view(d) }
    end

    def detail_motion_key(ev : Termisu::Event::Key) : Bool
      return false if selected_sample.nil?
      sync_token
      @token.motion_key(ev)
    end

    def detail_select_line : Nil
      with_token { @token.select_line }
    end

    def detail_clear_selection : Nil
      @token.clear_selection
    end

    def detail_selection? : Bool
      @token.selection?
    end

    def detail_copy_text : String
      return "" if selected_sample.nil?
      sync_token
      @token.copy_text
    end

    def detail_copy_all : String
      return "" if selected_sample.nil?
      sync_token
      @token.copy_all
    end

    # The TOKEN card's interior — the rect `render_detail` draws into (it takes the whole body).
    def detail_body(rect : Rect) : Rect
      rect.inset(2, 1)
    end

    def detail_click(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      body = detail_body(rect)
      return if body.empty?
      with_token { @token.click(body, mx, my, selecting) }
    end

    private def sync_token : Nil
      smp = selected_sample
      unless smp
        @token.source(0, ->(_i : Int32) { "" })
        return
      end
      ls = detail_lines(smp)
      @token.source(ls.size, ->(i : Int32) { "#{ls[i][0]}  #{ls[i][1]}" })
    end

    private def with_token(&) : Nil
      return if selected_sample.nil?
      sync_token
      yield
    end

    def close_detail : Nil
      @focus = :samples
    end

    # --- run state ---
    def running? : Bool
      @running
    end

    # The running engine, so ^X can reach it directly. Set by SequencerController before the
    # run fiber is spawned; mirrors `DiscoverRun#engine`, the one tab whose stop was prompt.
    property engine : Sequencer::Engine? = nil

    def stop_requested? : Bool
      @stop_requested
    end

    # Stop NOW, not at the next event. The flag alone reached the engine only through
    # `engine.stop if view.stop_requested?` inside the controller's `engine.run { }` block, so
    # it took effect only once the next event arrived — and a collection whose samples are slow
    # has long windows with none (P4: the operator decides what leaves the machine).
    def request_stop : Nil
      @stop_requested = true
      @engine.try(&.stop)
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
      @analysis.reset
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
      Frame.card(screen, rect, "SAMPLES", border: Frame.pane_border(focused), bg: Theme.bg)
      Frame.border_meta(screen, rect, "SAMPLES", @samples.size.to_s)
      inner = rect.inset(1, 1)
      # A card under 3 rows has no interior — `inset` floors the height at 0 but keeps
      # `inner.y` one row down, so an unguarded placeholder lands OUTSIDE the pane.
      return if inner.h <= 0 || inner.w <= 0
      if @samples.empty?
        # MANUAL mode keeps its line: there is no run to explain there — the tokens come from a
        # paste, and the card's "re-sends this request" would describe a mode this session is
        # not in. The collecting and never-run states get the card, the same two the Fuzzer's
        # RESULTS pane has always answered with one.
        if !@running && @config.mode.manual?
          screen.text(inner.x + 1, inner.y, "paste tokens (space → Configure), then ^R",
            Theme.muted, Theme.bg, width: inner.w - 1)
          return
        end
        TrafficEmptyState.render(screen, inner, variant: :sequencer_samples, running: @running)
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
      @analysis_w = inner.w
      return if inner.h <= 0 || inner.w <= 2
      rep = report
      if rep.usable_count == 0
        @analysis.source(0, ->(_i : Int32) { "" })
        screen.text(inner.x + 1, inner.y, @running ? "collecting…" : "no tokens yet", Theme.muted, Theme.bg)
        return
      end
      lines = analysis_lines(rep, inner.w)
      sync_analysis
      top = @analysis.viewport_top(inner.h) # the state half of ReadPane#render — this pane draws its own rows
      inner.h.times do |i|
        li = top + i
        break if li >= lines.size
        draw_analysis_line(screen, inner, lines[li], inner.y + i, focused && @analysis.row_marked?(li))
      end
      Frame.scroll_gauge(screen, inner, lines.size, top, focused)
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

    # `marked` = this row is under the row cursor or inside a selection. The whole row is tinted
    # (never a character span): its two columns are not one run of text — see `@analysis`.
    private def draw_analysis_line(screen : Screen, inner : Rect, line : ALine, py : Int32,
                                   marked : Bool = false) : Nil
      # The banner paints its own full-width fill, so a band under it would be invisible anyway.
      screen.fill(Rect.new(inner.x, py, inner.w, 1), Theme.accent_bg) if marked && !line.kind.==(:banner)
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
      sync_token
      top = @token.viewport_top(inner.h)
      inner.h.times do |i|
        li = top + i
        break if li >= lines.size
        lbl, val, color = lines[li]
        y = inner.y + i
        bg = focused && @token.row_marked?(li) ? Theme.accent_bg : Theme.bg
        screen.fill(Rect.new(inner.x, y, inner.w, 1), bg) if bg != Theme.bg
        screen.text(inner.x, y, lbl, Theme.muted, bg)
        screen.text(inner.x + 10, y, val, color, bg, width: {inner.w - 10, 1}.max)
      end
      Frame.scroll_gauge(screen, inner, lines.size, top, focused)
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

    # Mouse: the sample index under a click, or nil (outside SAMPLES, on the header row, or
    # past the last populated row). Mirrors render_samples' inset → header → @scroll+i. The
    # cursor moved with ↑/↓ and the wheel and could not be placed with the pointer.
    def samples_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if @focus == :detail || @samples.empty?
      _, s_rect, _ = pane_rects(rect)
      return nil if s_rect.empty? || !s_rect.contains?(mx, my)
      inner = s_rect.inset(1, 1)
      return nil if inner.h <= 0 || inner.w <= 0
      i = my - (inner.y + 1) # rows start one line below the header
      return nil if i < 0 || i >= {inner.h - 1, 0}.max
      idx = @scroll + i
      idx < @samples.size ? idx : nil
    end

    # The row a click on the scroll gauge asks for. The gauge rides the frame's right hairline,
    # one column outside the list rect, so `row_at` cannot answer it — and `@scroll` here is
    # DERIVED from the selection, so the answer is a selection. See `Frame.scroll_gauge_row`.
    def samples_gauge_row(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if @focus == :detail
      _, s_rect, _ = pane_rects(rect)
      return nil if s_rect.empty?
      inner = s_rect.inset(1, 1)
      return nil if inner.h <= 0 || inner.w <= 0
      Frame.scroll_gauge_row(Rect.new(inner.x, inner.y + 1, inner.w, inner.h - 1),
        @samples.size, mx, my)
    end

    def select_sample_row(idx : Int32) : Nil
      @sel = idx.clamp(0, {@samples.size - 1, 0}.max)
    end

    def samples_selected_index : Int32
      @sel
    end

    # Hit-test the SEQUENCER card's run control — same dress as the Repeater's ` ^R:SEND `
    # and the Fuzzer's ` ^R:RUN `, which both answer a click. Mirrors render_config.
    def config_chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @focus == :detail
      cfg, _, _ = pane_rects(rect)
      return nil if cfg.empty?
      chord, name = @running ? {"^X", "STOP"} : {"^R", "RUN"}
      Frame.right_badge_hit(mx, my, cfg.y, cfg.right - 1, cfg.x + "SEQUENCER".size + 4,
        [{:run, chord, name}] of {Symbol, String, String})
    end
  end
end
