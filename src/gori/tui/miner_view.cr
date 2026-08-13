require "json"
require "./screen"
require "./theme"
require "./frame"
require "./read_pane"
require "../host_overrides"
require "../store"
require "../miner"
require "../fuzz"
require "../repeater/flow_request"
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
    # PROVENANCE: `@request` is a CAPTURED FLOW's stored bytes (a History/Sitemap/Issues
    # seed), not something the operator drafted. This view has NO editor at all —
    # `@request` is only ever assigned from a seed or from the store — so the flag is
    # decided once, at load, and there is no draft interpretation to fall back to.
    # See `Miner::PlanOptions#evidence?`.
    getter? evidence : Bool

    def initialize
      @target = ""
      @request = Bytes.empty
      @http2 = false
      @sni = ""
      @evidence = false
      @config = Miner::Config.new
      @last_synced_config = "" # last store config blob applied (reconcile equality)
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
      # The FINDING pane's row cursor, selection, scroll and draw-state. `line_select_only`: a row
      # is a label and a value in two columns, so selection is whole rows and the copy payload is
      # `"label  value"` (see `detail_plain`). The pane paints its own two columns, so
      # `ReadPane#render` is never called — `viewport_top` and `row_marked?` are.
      @finding = ReadPane.new(line_select_only: true)
      @job_id = 0
    end

    # Seed a fresh session from the config overlay. `evidence` is the seed's `flow_id`
    # having been non-nil (a History/Sitemap/Issues flow); a Repeater-sourced seed is
    # editor text the operator authored and stays a draft.
    def load(target : String, request : Bytes, http2 : Bool, sni : String?,
             config : Miner::Config, evidence : Bool = false) : Nil
      @target = target
      @request = request
      @http2 = http2
      @sni = sni || ""
      @config = config
      @evidence = evidence
      @dirty = true
    end

    def restore(rec : Store::MinerSessionRecord) : Nil
      @target = rec.target
      @request = rec.request
      @http2 = rec.http2?
      @sni = rec.sni || ""
      # Provenance survives a restart: `flow_id` is what `insert_miner_session` already
      # stored for a flow-seeded session and nothing else sets it.
      @evidence = !rec.flow_id.nil?
      @name = rec.name
      apply_config_json(rec.config)
      @last_synced_config = rec.config
      @dirty = false
    end

    # Live cross-session request-side sync. Updates seed request/config WITHOUT
    # wiping focus, in-memory findings, scroll/selection, or a running job.
    def apply_peer_session(rec : Store::MinerSessionRecord) : Nil
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

    def session_side_matches?(rec : Store::MinerSessionRecord) : Bool
      @target == rec.target &&
        @request == rec.request &&
        @http2 == rec.http2? &&
        (sni_override || "") == (rec.sni || "") &&
        (@name || "") == (rec.name || "") &&
        @last_synced_config == rec.config
    end

    # Content-only clone for sub-tab Duplicate: request + config. No findings/progress.
    def duplicate_from(src : MinerView) : Nil
      @target = src.@target
      @request = src.@request.dup
      @http2 = src.@http2
      @sni = src.@sni
      @evidence = src.evidence? # the same bytes carry the same provenance
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

    def mark_config_synced(config : String) : Nil
      @last_synced_config = config
    end

    def request_line : String
      String.new(@request[0, {@request.size, 256}.min]).each_line.first? || ""
    end

    # HTTP method from the request line — feeds the sub-tab filter's `method:`.
    def request_method : String
      request_line.strip.split(' ').first? || ""
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
      scheme, host, port = Repeater::FlowRequest.parse_target(@target)
      "#{scheme}://#{host}:#{port}"
    end

    # The session target as stored (scheme://host[:port]) — feeds Repeater seeds.
    def target : String
      @target
    end

    # Build a Repeater-ready request with the selected finding's parameter injected at
    # its discovered location. Uses the discovery canary when present (so a reflection
    # finding still echoes on re-send); otherwise a short non-empty probe value.
    def request_with_finding(f : Miner::Finding) : Bytes
      value = f.canary.presence || "1"
      Miner::Inject.apply(@request, f.location, [{f.name, value}],
        @config.add_content_length_when_missing?)
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
      @finding.reset
      @focus = :detail
    end

    # ↑/↓ (⇧ to select) walk the FINDING's fields; the wheel scrolls the viewport.
    def detail_scroll(d : Int32) : Nil
      with_finding { @finding.move(d, 0) }
    end

    def detail_move(d : Int32, selecting : Bool) : Nil
      with_finding { @finding.move(d, 0, selecting: selecting) }
    end

    def detail_wheel(d : Int32) : Nil
      with_finding { @finding.scroll_view(d) }
    end

    def detail_motion_key(ev : Termisu::Event::Key) : Bool
      return false if selected_finding.nil?
      sync_finding
      @finding.motion_key(ev)
    end

    def detail_select_line : Nil
      with_finding { @finding.select_line }
    end

    def detail_clear_selection : Nil
      @finding.clear_selection
    end

    def detail_selection? : Bool
      @finding.selection?
    end

    def detail_copy_text : String
      return "" if selected_finding.nil?
      sync_finding
      @finding.copy_text
    end

    def detail_copy_all : String
      return "" if selected_finding.nil?
      sync_finding
      @finding.copy_all
    end

    # The FINDING card's interior — the rect `render_detail` draws into.
    def detail_body(rect : Rect) : Rect
      rect.inset(2, 1)
    end

    def detail_click(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      body = detail_body(rect)
      return if body.empty?
      with_finding { @finding.click(body, mx, my, selecting) }
    end

    def close_detail : Nil
      @focus = :results
    end

    # --- run state ---
    def running? : Bool
      @running
    end

    # The running engine, so ^X can reach it directly. Set by MinerController before the run
    # fiber is spawned; mirrors `DiscoverRun#engine`, the one tab whose stop was already prompt.
    property engine : Miner::Engine? = nil

    def stop_requested? : Bool
      @stop_requested
    end

    # Stop NOW, not at the next event. The flag alone reached the engine only through
    # `engine.stop if view.stop_requested?` inside the controller's `engine.run { }` block, so
    # it took effect only when the next event arrived. `Baseline#calibrate` runs before the
    # first event and fires its probes concurrently when the run is unpaced — so a ^X there
    # stopped nothing and the mine then started anyway (P4: the operator decides what leaves).
    def request_stop : Nil
      @stop_requested = true
      @engine.try(&.stop)
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

    # A FINISHED mine that left candidate names untested because the request cap ran out.
    # Derived rather than carried, the way `gori run mine` and MCP derive it: the engine
    # already publishes both halves on `Miner::Progress`. Guarded on `max_requests` being
    # set so a run STOPPED by hand (^X) is not relabelled as a budget hit.
    def budget_exhausted? : Bool
      return false if @running
      return false unless @config.max_requests
      @progress.names_total > 0 && @progress.names_done < @progress.names_total
    end

    # "N of M names untested" — what a budget-halted mine actually did, for the surfaces
    # that would otherwise say "0 found" over a wordlist it never opened.
    def budget_note : String
      "budget exhausted · #{@progress.names_total - @progress.names_done} of " \
      "#{@progress.names_total} names untested — raise max requests to finish"
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
    # Build an engine ready to run, or {nil, error}. `scope` becomes the interactive
    # `Gori::Outbound` decision the sender dials through: no up-front allowlist gate (the
    # operator typed this target), but Sandbox mode and explicit EXCLUDE rules hard-block
    # every send — the same protection Discover already applies per-request.
    # `overrides` is the project's hostname overrides (the Project tab's HOST OVERRIDES
    # pane). It has NO default on purpose: the Miner tab ignored them for as long as the
    # tab has existed (#367), which pinned a host to a staging IP everywhere except here,
    # so a call site that forgets them again has to be a compile error.
    def build_engine(verify : Bool, scope : Gori::Scope,
                     overrides : Gori::HostOverrides?) : {Miner::Engine?, String?}
      # @request / @target keep their `$VAR` tokens (that is what gets persisted and what
      # the operator sees); Miner::Plan expands both exactly once, at build time — unless
      # these bytes are EVIDENCE, in which case it expands neither and refuses neither.
      # A flow-seeded mine of `?$filter=…&$top=10` was refused outright ("unresolved env
      # $filter, $top"), and once the operator followed that advice every probe went out
      # with the PARAMETER NAMES rewritten. `gori run mine --flow N` never did either.
      options = Miner::PlanOptions.new(String.new(@request), evidence: @evidence,
        target: @target, http2: @http2,
        locations: @config.locations, config: @config, verify: verify, sni: sni_override,
        overrides: overrides)
      plan = Miner::Plan.build(options, Gori::Outbound.interactive(scope))
      {plan.engine, nil}
    rescue ex : Miner::PlanError
      {nil, mine_plan_error(ex)}
    rescue ex
      {nil, "config error: #{ex.message}"}
    end

    # The Miner tab's wording for a plan this view's state can't produce. The builder
    # reports the machine-readable `reason`; the sentence (and the pane it points at) is ours.
    private def mine_plan_error(ex : Miner::PlanError) : String
      case ex.reason
      in Miner::PlanError::Reason::NoTarget, Miner::PlanError::Reason::BadTarget
        "invalid target — use scheme://host[:port]/path"
      in Miner::PlanError::Reason::NoLocations
        "no locations selected"
      in Miner::PlanError::Reason::Wordlist
        "wordlist error: #{ex.detail}"
      in Miner::PlanError::Reason::NoNames
        "wordlist is empty"
      in Miner::PlanError::Reason::UnresolvedEnv
        "unresolved env #{ex.detail} — add it in the Project tab's ENV pane"
      end
    end

    # --- config (de)serialization (opaque JSON in miner_sessions.config) ---
    def config_json : String
      JSON.build do |j|
        j.object do
          j.field "locations" do
            j.array { @config.locations.each { |l| j.string l.label } }
          end
          j.field "concurrency", @config.concurrency
          j.field "max_requests", @config.max_requests
          j.field "notify", @config.notify.token
          j.field "keep_alive", @config.keep_alive?
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
      # Absent (an older row) reads as nil ⇒ uncapped, which is what those runs were.
      @config.max_requests = any["max_requests"]?.try(&.as_i64?)
      any["notify"]?.try(&.as_s?).try { |mode| Miner::NotifyMode.parse?(mode) }.try { |m| @config.notify = m }
      # `!= false`, not `|| false`: a session persisted before this key existed has no
      # `keep_alive` field at all, and reading a missing key as "off" would silently opt an
      # old session out of the default the overlay shows it as having.
      @config.keep_alive = any["keep_alive"]?.try(&.as_bool?) != false
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
    # The {summary, results} rects for `rect`, TILING it exactly. ONE derivation, shared by
    # `render` and `pane_at`, so the hit-test cannot drift from the drawn geometry.
    #
    # Both heights were floored at 1 with no ceiling at the container, so on a 1-row body
    # the results card was placed at `rect.y + 1` — a whole row outside the rect this view
    # was handed, which nothing repaints. The floor is now capped at what the container
    # granted and a zero-row pane is declined instead of being given a row it doesn't have.
    private def pane_rects(rect : Rect) : {Rect, Rect}
      sum_h = {rect.h // 3, 8}.min
      sum_h = rect.h - 3 if sum_h > rect.h - 3
      sum_h = { {sum_h, 1}.max, rect.h }.min
      {Rect.new(rect.x, rect.y, rect.w, sum_h),
       Rect.new(rect.x, rect.y + sum_h, rect.w, {rect.h - sum_h, 0}.max)}
    end

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      return render_detail(screen, rect, focused) if @focus == :detail
      sum_rect, res_rect = pane_rects(rect)
      render_summary(screen, sum_rect, focused && @focus == :summary)
      render_results(screen, res_rect, focused && @focus == :results) unless res_rect.empty?
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
      # Guarded like every line below it: on a 1-2 row card `rect.y + 1` is the bottom
      # border row or past the card entirely, and this line alone was unconditional.
      screen.text(x, y, summary(rect.w - 4), Theme.text_bright, Theme.bg, Attribute::Bold) if y < rect.bottom - 1
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
      if budget_exhausted? && y < rect.bottom - 1
        screen.text(x, y, budget_note, Theme.yellow, Theme.bg, width: rect.w - 4)
        y += 1
      end
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
      Frame.card(screen, rect, "FINDINGS", border: Frame.pane_border(focused), bg: Theme.bg)
      Frame.border_meta(screen, rect, "FINDINGS", @results.size.to_s)
      inner = rect.inset(1, 1)
      # A card under 3 rows has no interior — `inset` floors the height at 0 but keeps
      # `inner.y` one row down, so an unguarded placeholder lands OUTSIDE the pane.
      return if inner.h <= 0 || inner.w <= 0
      if @results.empty?
        # Distinguish never-run from a completed run that found nothing, using the
        # same signal the status line does (names_total > 0 ⇒ a run happened).
        # "no hidden parameters found" over a wordlist the budget never opened is the one
        # claim this pane must not make — it did not look.
        msg = if @running
                "mining… discovered parameters appear here"
              elsif budget_exhausted?
                "none found in the #{@progress.names_done} of #{@progress.names_total} names the budget allowed"
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
      # Gauge over the rows region (below the header), aligned to what @scroll windows.
      Frame.scroll_gauge(screen, Rect.new(inner.x, inner.y + 1, inner.w, cap), @results.size, @scroll, focused)
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
      return if inner.h <= 0 || inner.w <= 0 # see render_results: no interior to draw into
      f = selected_finding
      unless f
        screen.text(inner.x, inner.y, "no finding selected", Theme.muted, Theme.bg)
        return
      end
      lines = detail_lines(f)
      sync_finding
      top = @finding.viewport_top(inner.h)
      inner.h.times do |i|
        li = top + i
        break if li >= lines.size
        lbl, val, color = lines[li]
        y = inner.y + i
        bg = focused && @finding.row_marked?(li) ? Theme.accent_bg : Theme.bg
        screen.fill(Rect.new(inner.x, y, inner.w, 1), bg) if bg != Theme.bg
        screen.text(inner.x, y, lbl, Theme.muted, bg)
        screen.text(inner.x + 12, y, val, color, bg, width: inner.w - 12)
      end
      Frame.scroll_gauge(screen, inner, lines.size, top, focused)
    end

    # ONE field row projected to ONE line of text — the copy payload, 1:1 with the screen rows.
    private def detail_plain(row : {String, String, Color}) : String
      "#{row[0]}  #{row[1]}"
    end

    # Point the row cursor at the selected finding's fields. Idempotent, so every gesture and
    # every verb can call it and none can act on a pane sourced from another finding.
    private def sync_finding : Nil
      f = selected_finding
      unless f
        @finding.source(0, ->(_i : Int32) { "" })
        return
      end
      ls = detail_lines(f)
      @finding.source(ls.size, ->(i : Int32) { detail_plain(ls[i]) })
    end

    private def with_finding(&) : Nil
      return if selected_finding.nil?
      sync_finding
      yield
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
    # Derived from `pane_rects`, the same tiling `render` draws into, so the two cannot
    # drift; it also used to skip the ceiling `render` skipped, agreeing with a results
    # card placed outside the container.
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless rect.contains?(mx, my)
      return :detail if @focus == :detail
      sum_rect, res_rect = pane_rects(rect)
      return :results if res_rect.contains?(mx, my)
      sum_rect.contains?(mx, my) ? :summary : nil
    end

    # Mouse: the findings index under a click, or nil (outside the pane, on the header row,
    # or past the last populated row). Mirrors render_results' inset → header → @scroll+i.
    # The pane drew a cursor and moved it with ↑/↓ and the wheel from the start; only the
    # pointer had no way to place it, so a click landed on a row and selected nothing.
    def results_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if @focus == :detail || @results.empty?
      _, res = pane_rects(rect)
      return nil if res.empty? || !res.contains?(mx, my)
      inner = res.inset(1, 1)
      return nil if inner.h <= 0 || inner.w <= 0
      i = my - (inner.y + 1) # rows start one line below the header
      return nil if i < 0 || i >= {inner.h - 1, 0}.max
      idx = @scroll + i
      idx < @results.size ? idx : nil
    end

    # The row a click on the scroll gauge asks for. The gauge rides the frame's right hairline,
    # one column outside the list rect, so `row_at` cannot answer it — and `@scroll` here is
    # DERIVED from the selection, so the answer is a selection. See `Frame.scroll_gauge_row`.
    def results_gauge_row(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if @focus == :detail
      _, res = pane_rects(rect)
      return nil if res.empty?
      inner = res.inset(1, 1)
      return nil if inner.h <= 0 || inner.w <= 0
      # Rows start one line below the header — the band the draw hands the gauge.
      Frame.scroll_gauge_row(Rect.new(inner.x, inner.y + 1, inner.w, inner.h - 1),
        @results.size, mx, my)
    end

    def select_result_row(idx : Int32) : Nil
      @sel = idx.clamp(0, {@results.size - 1, 0}.max)
    end

    def results_selected_index : Int32
      @sel
    end

    # Hit-test the MINER card's run control. It is drawn in the same dress as the Repeater's
    # ` ^R:SEND ` and the Fuzzer's ` ^R:RUN `, both of which answer a click; this one and its
    # Sequencer/Discover twins did not. Geometry mirrors render_summary exactly.
    def summary_chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @focus == :detail
      sum, _ = pane_rects(rect)
      return nil if sum.empty?
      chord, name = @running ? {"^X", "STOP"} : {"^R", "MINE"}
      Frame.right_badge_hit(mx, my, sum.y, sum.right - 1, sum.x + "MINER".size + 4,
        [{:run, chord, name}] of {Symbol, String, String})
    end
  end
end
