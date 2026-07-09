require "json"
require "./screen"
require "./theme"
require "./frame"
require "../store"
require "../miner"
require "../fuzz"
require "../replay/flow_request"
require "./subtab_clone"

module Gori::Tui
  # The view for ONE mining session (a sub-tab under the Miner tab). Read-only: the
  # request + locations are chosen once in the config overlay, then the engine runs in
  # the background and this view shows live progress + the discovered parameters.
  # Panes: :summary (target/baseline/progress) and :results (findings table); :detail
  # overlays a single finding. Mirrors FuzzerView's session shape, minus the editors.
  class MinerView
    PANE_ORDER = [:summary, :results]

    property name : String?
    getter focus : Symbol
    getter config : Miner::Config
    property job_id : Int32

    def initialize
      @target = ""
      @request = Bytes.empty
      @http2 = false
      @sni = ""
      @config = Miner::Config.new
      @name = nil.as(String?)
      @dirty = false

      @running = false
      @stop_requested = false
      @baseline_stable = true
      @baseline_warning = nil.as(String?)
      @progress = Miner::Progress.new(0, 0, 0, 0, 0)
      @results = [] of Miner::Finding

      @focus = :summary
      @sel = 0
      @scroll = 0
      @detail_scroll = 0
      @job_id = 0
    end

    # Seed a fresh session from the config overlay.
    def load(target : String, request : Bytes, http2 : Bool, sni : String?, config : Miner::Config) : Nil
      @target = target
      @request = request
      @http2 = http2
      @sni = sni || ""
      @config = config
      @dirty = true
    end

    def restore(rec : Store::MinerSessionRecord) : Nil
      @target = rec.target
      @request = rec.request
      @http2 = rec.http2?
      @sni = rec.sni || ""
      @name = rec.name
      apply_config_json(rec.config)
      @dirty = false
    end

    # Content-only clone for sub-tab Duplicate: request + config. No findings/progress.
    def duplicate_from(src : MinerView) : Nil
      @target = src.@target
      @request = src.@request.dup
      @http2 = src.@http2
      @sni = src.@sni
      apply_config_json(src.config_json)
      @name = SubtabClone.copy_name(src.name)
      @dirty = true
      @running = false
      @stop_requested = false
      @results.clear
      @progress = Miner::Progress.new(0, 0, 0, 0, 0)
      @sel = 0
      @scroll = 0
      @job_id = 0
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

    def same?(other : MinerView) : Bool
      same?(other.object_id)
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

    def request_line : String
      String.new(@request[0, {@request.size, 256}.min]).each_line.first? || ""
    end

    def summary(max : Int32 = 32) : String
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
      scheme, host, port = Replay::FlowRequest.parse_target(@target)
      "#{scheme}://#{host}:#{port}"
    end

    # --- focus ring ---
    def focus_pane(pane : Symbol) : Nil
      @focus = pane if PANE_ORDER.includes?(pane)
    end

    def focus_first : Nil
      @focus = :summary
    end

    def focus_last : Nil
      @focus = :results
    end

    def at_top? : Bool
      @focus == :summary
    end

    def results_at_top? : Bool
      @sel == 0
    end

    def pane_advance(dir : Int32) : Bool
      idx = PANE_ORDER.index(@focus) || 0
      nidx = idx + dir
      return false unless 0 <= nidx < PANE_ORDER.size
      @focus = PANE_ORDER[nidx]
      true
    end

    # --- results nav ---
    def results_move(d : Int32) : Nil
      return if @results.empty?
      @sel = (@sel + d).clamp(0, @results.size - 1)
    end

    def open_detail : Nil
      return if @results.empty?
      @detail_scroll = 0
      @focus = :detail
    end

    def detail_scroll(d : Int32) : Nil
      @detail_scroll = {@detail_scroll + d, 0}.max
    end

    def close_detail : Nil
      @focus = :results
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
      @results.clear
      @sel = 0
      @progress = Miner::Progress.new(0, 0, 0, 0, 0)
      @baseline_warning = nil
      @baseline_stable = true
    end

    def finish_run : Nil
      @running = false
    end

    def apply_progress(p : Miner::Progress) : Nil
      @progress = p
    end

    def apply_baseline(ev : Miner::BaselineEvent) : Nil
      @baseline_stable = ev.stable
      @baseline_warning = ev.warning
    end

    def append_finding(f : Miner::Finding) : Nil
      @results << f
    end

    def found_count : Int32
      @results.size
    end

    def selected_finding : Miner::Finding?
      @results[@sel]?
    end

    # --- engine ---
    def build_engine(verify : Bool) : {Miner::Engine?, String?}
      scheme, host, port = Replay::FlowRequest.parse_target(@target)
      return {nil, "invalid target — use scheme://host[:port]/path"} if host.empty?
      return {nil, "no locations selected"} if @config.locations.empty?
      names = Miner::Wordlist.load(@config.user_wordlist)
      return {nil, "wordlist is empty"} if names.empty?
      sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
        http2: @http2, verify: verify, sni: sni_override, timeout: @config.timeout)
      {Miner::Engine.new(@request, @http2, names, sender, @config), nil}
    rescue ex
      {nil, "config error: #{ex.message}"}
    end

    # --- config (de)serialization (opaque JSON in miner_sessions.config) ---
    def config_json : String
      JSON.build do |j|
        j.object do
          j.field "locations" do
            j.array { @config.locations.each { |l| j.string l.label } }
          end
          j.field "concurrency", @config.concurrency
          j.field "notify", @config.notify.token
          j.field "stability_rounds", @config.stability_rounds
          j.field "confirm_rounds", @config.confirm_rounds
          j.field "buckets" do
            j.object { @config.bucket_size.each { |k, v| j.field k.label, v } }
          end
          if w = @config.user_wordlist
            j.field "user_wordlist", w
          end
        end
      end
    end

    private def apply_config_json(s : String) : Nil
      return if s.strip.empty?
      any = JSON.parse(s)
      if locs = any["locations"]?.try(&.as_a?)
        parsed = locs.compact_map { |x| Miner::Location.parse?(x.as_s? || "") }
        @config.locations = parsed unless parsed.empty?
      end
      any["concurrency"]?.try(&.as_i?).try { |n| @config.concurrency = n }
      any["notify"]?.try(&.as_s?).try { |s| Miner::NotifyMode.parse?(s) }.try { |m| @config.notify = m }
      any["stability_rounds"]?.try(&.as_i?).try { |n| @config.stability_rounds = n }
      any["confirm_rounds"]?.try(&.as_i?).try { |n| @config.confirm_rounds = n }
      if buckets = any["buckets"]?.try(&.as_h?)
        buckets.each do |k, v|
          loc = Miner::Location.parse?(k)
          val = v.as_i?
          @config.bucket_size[loc] = val if loc && val
        end
      end
      any["user_wordlist"]?.try(&.as_s?).try { |w| @config.user_wordlist = w }
    rescue
      # malformed persisted config → keep defaults
    end

    # --- rendering ---
    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return render_detail(screen, rect, focused) if @focus == :detail
      sum_h = {rect.h // 3, 8}.min
      sum_h = rect.h - 3 if sum_h > rect.h - 3
      sum_rect = Rect.new(rect.x, rect.y, rect.w, {sum_h, 1}.max)
      res_rect = Rect.new(rect.x, rect.y + sum_rect.h, rect.w, {rect.h - sum_rect.h, 1}.max)
      render_summary(screen, sum_rect, focused && @focus == :summary)
      render_results(screen, res_rect, focused && @focus == :results)
    end

    private def render_summary(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "MINER", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      # Run control on the border: while mining a lit ` ^X:STOP `, otherwise a muted
      # ` ^R:MINE ` (run / re-run) — so both chords stay in view once findings fill the
      # pane. A state-swapping badge, not a boolean toggle: the chord itself changes.
      chord, name = @running ? {"^X", "STOP"} : {"^R", "MINE"}
      Frame.toggle_badge(screen, rect.right - 1, rect.y, rect.x + "MINER".size + 4, chord, name, @running)
      x = rect.x + 2
      y = rect.y + 1
      screen.text(x, y, summary(rect.w - 4), Theme.text_bright, Theme.bg, Attribute::Bold)
      y += 1
      screen.text(x, y, target_origin, Theme.muted, Theme.bg, width: rect.w - 4) if y < rect.bottom - 1
      y += 1
      locs = @config.locations.map(&.label).join(", ")
      screen.text(x, y, "scope: #{locs}", Theme.text, Theme.bg, width: rect.w - 4) if y < rect.bottom - 1
      y += 1
      if y < rect.bottom - 1
        bar = progress_bar(rect.w - 4)
        screen.text(x, y, bar, Theme.accent, Theme.bg)
      end
      y += 1
      if y < rect.bottom - 1
        line = "found #{@progress.found} · #{@progress.names_done}/#{@progress.names_total} names · #{@progress.sent} sent · #{@progress.errors} err"
        screen.text(x, y, line, Theme.muted, Theme.bg, width: rect.w - 4)
      end
      y += 1
      if (w = @baseline_warning) && y < rect.bottom - 1
        screen.text(x, y, "⚠ #{w}", Theme.yellow, Theme.bg, width: rect.w - 4)
      end
    end

    private def progress_bar(w : Int32) : String
      total = @progress.names_total
      return "—" if total <= 0
      filled = ((@progress.names_done.to_f / total) * w).to_i.clamp(0, w)
      "#{"█" * filled}#{"░" * (w - filled)}"
    end

    private def render_results(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "FINDINGS (#{@results.size})", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(1, 1)
      if @results.empty?
        # Distinguish never-run from a completed run that found nothing, using the
        # same signal the status line does (names_total > 0 ⇒ a run happened).
        msg = if @running
                "mining… discovered parameters appear here"
              elsif @progress.names_total > 0
                "no hidden parameters found"
              else
                "no run yet — ^R to mine"
              end
        screen.text(inner.x + 1, inner.y, msg, Theme.muted, Theme.bg)
        return
      end
      header_row(screen, inner)
      cap = inner.h - 1
      ensure_visible(cap)
      cap.times do |i|
        idx = @scroll + i
        break if idx >= @results.size
        draw_result(screen, inner, idx, inner.y + 1 + i, focused)
      end
    end

    private def header_row(screen : Screen, inner : Rect) : Nil
      screen.text(inner.x + 2, inner.y, "PARAMETER", Theme.muted, Theme.bg)
      screen.text(inner.x + name_w(inner) + 3, inner.y, "WHERE", Theme.muted, Theme.bg)
      screen.text(inner.x + name_w(inner) + 13, inner.y, "EVIDENCE", Theme.muted, Theme.bg)
      screen.text(inner.x + name_w(inner) + 24, inner.y, "CONF", Theme.muted, Theme.bg)
    end

    private def name_w(inner : Rect) : Int32
      {inner.w - 38, 12}.max
    end

    private def draw_result(screen : Screen, inner : Rect, idx : Int32, py : Int32, focused : Bool) : Nil
      f = @results[idx]
      sel = idx == @sel
      bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(inner.x, py, inner.w, 1), bg)
      screen.cell(inner.x, py, sel ? '▎' : ' ', Theme.accent, bg)
      nw = name_w(inner)
      screen.text(inner.x + 2, py, f.name, sel ? Theme.text_bright : Theme.text, bg, width: nw)
      screen.text(inner.x + nw + 3, py, f.location.label, Theme.accent, bg, width: 9)
      screen.text(inner.x + nw + 13, py, f.evidence.label, Theme.text, bg, width: 10)
      cc = f.confidence.confirmed? ? Theme.green : Theme.yellow
      screen.text(inner.x + nw + 24, py, f.confidence.confirmed? ? "yes" : "tent", cc, bg)
    end

    private def ensure_visible(cap : Int32) : Nil
      return if cap <= 0
      @scroll = @sel if @sel < @scroll
      @scroll = @sel - cap + 1 if @sel >= @scroll + cap
      @scroll = 0 if @scroll < 0
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "FINDING", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(2, 1)
      f = selected_finding
      unless f
        screen.text(inner.x, inner.y, "no finding selected", Theme.muted, Theme.bg)
        return
      end
      lines = detail_lines(f)
      lines.each_with_index do |(lbl, val, color), i|
        y = inner.y + i - @detail_scroll
        next unless inner.y <= y < inner.bottom
        screen.text(inner.x, y, lbl, Theme.muted, Theme.bg)
        screen.text(inner.x + 12, y, val, color, Theme.bg, width: inner.w - 12)
      end
    end

    private def detail_lines(f : Miner::Finding) : Array({String, String, Color})
      [
        {"parameter", f.name, Theme.text_bright},
        {"location", f.location.label, Theme.accent},
        {"evidence", f.evidence.label, Theme.text},
        {"confidence", f.confidence.label, f.confidence.confirmed? ? Theme.green : Theme.yellow},
        {"canary", f.canary || "—", Theme.muted},
        {"status", f.status.try(&.to_s) || "—", Theme.text},
        {"len Δ", f.delta.to_s, Theme.text},
        {"target", target_origin, Theme.muted},
      ]
    end

    # --- click hit-test ---
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return :detail if @focus == :detail && rect.contains?(mx, my)
      sum_h = {rect.h // 3, 8}.min
      sum_h = rect.h - 3 if sum_h > rect.h - 3
      return :summary if my < rect.y + sum_h
      rect.contains?(mx, my) ? :results : nil
    end
  end
end
