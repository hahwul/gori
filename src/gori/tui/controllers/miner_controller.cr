require "../tab_controller"
require "../miner_view"
require "../mine_config_overlay"
require "../../store"
require "../../miner"
require "../../env"

module Gori::Tui
  # One open mining session (a sub-tab under the Miner tab). `flow_id` is the source
  # History flow, or nil for a Repeater-seeded one. `db_id` is the persisted
  # `miner_sessions` row id (nil only if the store was closing).
  record MinerTab, view : MinerView, flow_id : Int64?, db_id : Int64?

  # The Miner tab: independent param-mining sessions (sub-tabs). A run is a BACKGROUND
  # job — starting one from History's space menu does NOT switch here; progress shows on
  # the bottom bar and completion posts a notification (see start_run / apply_event). The
  # session (request + config) persists across reopen; results stay in-memory.
  class MinerController < TabController
    DRAIN_CAP = 512 # bounded per-tick drain so a fast run can't starve render

    def initialize(host : Host)
      super(host)
      @miners = [] of MinerTab
      @host.session.store.miner_sessions.each do |rec|
        view = MinerView.new
        view.restore(rec)
        @miners << MinerTab.new(view, rec.flow_id, rec.id)
      end
      @current_idx = @miners.empty? ? -1 : 0
      @mine_events = Channel({MinerView, Miner::Event}).new(256)
    end

    def tab : Symbol
      :miner
    end

    def command_scope : Verb::Scope
      Verb::Scope::Miner
    end

    # Space menu CONTEXT section. Summary is a thin overview with no section-tagged
    # verbs — map it to :common so the menu stays a flat COMMON list (no empty
    # "SUMMARY" header). Results/detail keep their identity for future section verbs.
    def command_section : Symbol
      case current_view.try(&.focus)
      when :results, :detail then :results
      else                        :common
      end
    end

    # --- shell-facing accessors ---
    def count : Int32
      @miners.size
    end

    def empty? : Bool
      @miners.empty?
    end

    def current_view : MinerView?
      current_tab_obj.try(&.view)
    end

    def subtab_labels : Array(String)
      @miners.map_with_index { |t, i| "#{i + 1}:#{t.view.label(18)}" }
    end

    # Show the strip from the FIRST session (not ≥2): a single mine still labels its
    # chip and exposes the strip's space-menu (^W close). Empty → no strip.
    def subtab_strip_shown? : Bool
      !@miners.empty?
    end

    def subtab_index : Int32
      @current_idx
    end

    def view_at(idx : Int32) : MinerView?
      (0 <= idx < @miners.size) ? @miners[idx].view : nil
    end

    def body_badge : Symbol
      :body # read-only display + a navigable findings table — never an editor
    end

    def body_hint(focus : Symbol) : String
      v = current_view
      return "↹/esc tabs · mine from History/Repeater (space → Mine parameters)" unless v
      case v.focus
      when :results then "↑/↓ select · ↵ detail · ^X stop · space cmds · ↹ pane · esc tabs"
      when :detail  then "↑/↓ scroll · esc back"
      else               "↓ findings · ^X stop · space cmds · ↹ pane · esc tabs"
      end
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: !current_view.nil?)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @current_idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          if v = current_view
            v.render(screen, body, body_focused)
          else
            screen.text(body.x + 1, body.y,
              "no mining sessions — from History/Repeater press space → \"Mine parameters\"", Theme.muted)
          end
        end
      end
    end

    # --- input ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      v = current_view
      if v.nil?
        key = ev.key
        # Empty placeholder: esc / ↑ pop to the tab bar (mirrors other empty multi-session tabs).
        if key.escape? || key.up? || key.lower_k?
          @host.request_focus(:menu)
          return true
        end
        return false
      end
      if navigable_pane?(v.focus) && ev.key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      c = ev.char || ev.key.to_char
      return true if dispatch_chord(chord_action(ev, c), v, c)
      return false if (ev.ctrl? || ev.alt?) && !ev.key.escape? # ^X stop etc. → keymap verb
      ev.key.escape? ? handle_escape(v) : handle_pane_key(ev, v)
      true
    end

    private def dispatch_chord(action : Symbol?, v : MinerView, c : Char?) : Bool
      case action
      when :palette then @host.open_palette
      when :close   then request_close
      when :switch  then switch_subtab(c)
      else               return false
      end
      true
    end

    private def navigable_pane?(pane : Symbol) : Bool
      pane == :summary || pane == :results
    end

    private def chord_action(ev : Termisu::Event::Key, c : Char?) : Symbol?
      return nil unless ev.ctrl?
      key = ev.key
      case
      when key.lower_p?         then :palette
      when key.lower_w?         then :close
      when c && '1' <= c <= '9' then :switch
      end
    end

    # esc focus ring: detail → results/summary area; else sub-tab strip (when shown)
    # then tab bar — same body → subtabs → menu ladder as Repeater/Fuzzer/Decoder.
    private def handle_escape(v : MinerView) : Nil
      if v.focus == :detail
        v.close_detail
      else
        @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      end
    end

    private def switch_subtab(c : Char?) : Nil
      return unless c
      idx = c.to_i - 1
      @current_idx = idx if idx < @miners.size
    end

    private def handle_pane_key(ev : Termisu::Event::Key, v : MinerView) : Nil
      case v.focus
      when :summary then handle_summary(ev, v)
      when :results then handle_results(ev, v)
      when :detail  then handle_detail(ev, v)
      end
    end

    private def handle_summary(ev : Termisu::Event::Key, v : MinerView) : Nil
      key = ev.key
      if key.down? || key.lower_j?
        v.focus_pane(:results)
      elsif key.up? || key.lower_k?
        @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      end
    end

    private def handle_results(ev : Termisu::Event::Key, v : MinerView) : Nil
      key = ev.key
      case
      when key.enter?              then v.open_detail
      when key.down?, key.lower_j? then v.results_move(1)
      when key.up?, key.lower_k?   then v.results_at_top? ? v.focus_pane(:summary) : v.results_move(-1)
      end
    end

    private def handle_detail(ev : Termisu::Event::Key, v : MinerView) : Nil
      key = ev.key
      if key.up? || key.lower_k?
        v.detail_scroll(-1)
      elsif key.down? || key.lower_j?
        v.detail_scroll(1)
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = body_rect_below_filter(rect)
      return true unless v = current_view
      if pane = v.pane_at(body, mx, my)
        v.focus_pane(pane) unless pane == :detail
        @host.focus_body
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      if v = current_view
        case v.focus
        when :results then v.results_move(step)
        when :detail  then v.detail_scroll(step)
        end
      end
      true
    end

    def commit : Nil
      save_current
    end

    def locked? : Bool
      return false unless v = current_view
      v.running? || (@host.active_tab == :miner && @host.focus == :body)
    end

    # --- focus ring ---
    def pane_advance(dir : Int32) : Bool
      current_view.try(&.pane_advance(dir)) || false
    end

    def focus_first : Nil
      current_view.try(&.focus_first)
    end

    def focus_last : Nil
      current_view.try(&.focus_last)
    end

    # --- sub-tab filter (issue #121) ---
    def subtab_filter_enabled? : Bool
      true
    end

    def filter_fields : Array(String)
      %w(name host method) # mining sessions carry an HTTP request (target + method)
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @miners.map do |t|
        v = t.view
        Repeater::SubtabFilter::Subject.new(v.name, v.summary(200), v.target, v.request_method, [] of String)
      end
    end

    # --- sub-tab nav (filter-aware: ←/→ skip hidden chips; ^1-9 escapes the filter) ---
    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@current_idx, dir)
        @current_idx = t
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @miners.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      @current_idx = idx
    end

    # Notification "jump to result": focus the session row with this db_id.
    def reveal_session(id : Int64) : Nil
      if idx = index_for_db_id(id)
        @current_idx = idx
        @host.focus_body
      end
    end

    def current_session_db_id : Int64?
      return nil if @current_idx < 0 || @current_idx >= @miners.size
      @miners[@current_idx].db_id
    end

    def index_for_db_id(id : Int64) : Int32?
      @miners.index { |t| t.db_id == id }
    end

    def db_id_at(idx : Int32) : Int64?
      @miners[idx]?.try(&.db_id)
    end

    # --- rename (orthogonal rename prompt drives this by VIEW identity) ---
    def apply_rename(view : MinerView, name : String) : Nil
      return unless tab = @miners.find(&.view.same?(view))
      clean = name.strip
      view.name = clean.empty? ? nil : clean
      if id = tab.db_id
        @host.session.store.set_miner_session_name(id, view.name)
      end
    end

    # --- cross-tab seeds (build the config-overlay seed) ---
    def build_seed_from_flow(id : Int64) : MineSeed?
      return nil unless detail = @host.session.store.get_flow(id)
      built = Repeater::FlowRequest.build(detail)
      appl = Miner::Detect.detect(built.bytes)
      summary = request_summary(built.bytes)
      MineSeed.new(built.target, built.bytes, built.http2, nil, id, summary, appl.applicable, appl.default)
    end

    def build_seed_from_request(target : String, request_text : String, http2 : Bool, sni : String?) : MineSeed
      bytes = text_to_request(request_text)
      appl = Miner::Detect.detect(bytes)
      MineSeed.new(target, bytes, http2, sni, nil, request_summary(bytes), appl.applicable, appl.default)
    end

    private def request_summary(bytes : Bytes) : String
      line = String.new(bytes[0, {bytes.size, 256}.min]).each_line.first? || ""
      parts = line.strip.split(' ')
      s = "#{parts[0]?} #{parts[1]?}".strip
      s.empty? ? "request" : s
    end

    # Normalize editor text to CRLF line endings (h2 reframing + injection boundary scan
    # expect them); captured flows are already CRLF.
    private def text_to_request(text : String) : Bytes
      Env.expand(text).gsub(/\r?\n/, "\r\n").to_slice
    end

    # --- start a session (called by the Runner after the config overlay confirms) ---
    def start_session(seed : MineSeed, config : Miner::Config) : Nil
      view = MinerView.new
      view.load(seed.target, seed.request, seed.http2, seed.sni, config)
      open_session(view, seed.flow_id) # NB: NO goto_tab — the job runs in the background
      start_run(view)
    end

    private def open_session(view : MinerView, flow_id : Int64?) : Nil
      @miners << MinerTab.new(view, flow_id, persist_new(view, flow_id))
      @current_idx = @miners.size - 1
    end

    # Content-only clone of the active miner session (request + config; no findings/links).
    def miner_duplicate : Nil
      return @host.status("no miner session open to duplicate") unless src = current_view
      view = MinerView.new
      view.duplicate_from(src)
      open_session(view, nil)
      @host.goto_tab(:miner)
      @host.status("duplicated miner session (#{@miners.size} open)")
    end

    # Seed handed to RepeaterController for "Send to Repeater" (Miner finding → injected request).
    record RepeaterSeed,
      target : String,
      request_text : String,
      http2 : Bool,
      sni : String?,
      label : String # sub-tab chip + toast ("name (location)")

    # True when the focused session has a selected finding (gates space → Send to Repeater).
    def finding_selected? : Bool
      !current_view.try(&.selected_finding).nil?
    end

    # Inject the selected finding into the session request; nil when nothing is selected.
    def selected_repeater_seed : RepeaterSeed?
      return nil unless v = current_view
      return nil unless f = v.selected_finding
      injected = v.request_with_finding(f)
      # Repeater editors store LF text; send expands back to CRLF (RepeaterView#expanded_text_to_bytes).
      # Same LF shape as History→Repeater (origin_form_text) and hand-authored tabs.
      text = String.new(injected).scrub.gsub("\r\n", "\n")
      RepeaterSeed.new(v.target, text, v.http2?, v.sni_override, "#{f.name} (#{f.location.label})")
    end

    private def persist_new(view : MinerView, flow_id : Int64?) : Int64?
      id = @host.session.store.insert_miner_session(view.target_origin, view.request_bytes, view.http2?,
        view.sni_override, view.config_json, flow_id, @miners.size, view.name)
      id == 0 ? nil : id
    end

    private def start_run(view : MinerView) : Nil
      engine, err = view.build_engine(!@host.session.config.insecure_upstream?)
      unless engine
        @host.status(err || "cannot mine")
        return
      end
      view.begin_run
      view.job_id = @host.jobs.start(:miner, view.summary, goto: goto_for(view))
      events = @mine_events
      spawn(name: "gori-miner") do
        engine.run do |ev|
          case ev
          when Miner::ProgressEvent
            select
            when events.send({view, ev})
            else
            end
          else
            events.send({view, ev}) # Baseline/Finding/Done/Error — blocking, never dropped
          end
          engine.stop if view.stop_requested?
        end
      ensure
        view.finish_run # backstop — the drain's Done also clears it
      end
      @host.status("mining #{view.target_origin} in the background — watch the bottom bar / notifications")
    end

    # --- run controls (mine.run re-runs the current session; mine.stop halts it) ---
    def mine_run : Nil
      return unless v = current_view
      if v.running?
        @host.status("already mining — ^X to stop")
        return
      end
      # Flush any trailing Done/Error from a just-finished run before start_run rebinds
      # job_id: the engine sends its terminal event BEFORE the fiber's `ensure` flips
      # running? false, so a re-run landing in that window would otherwise settle the
      # stale event against the NEW job (premature/wrong "done", orphaned spinner).
      drain_events
      start_run(v)
    end

    def mine_stop : Nil
      return unless (v = current_view) && v.running?
      v.request_stop
      @host.status("stopping…")
    end

    # --- async (run loop) ---
    def drain_events : Bool
      applied = false
      n = 0
      while n < DRAIN_CAP && (pair = nonblocking_event)
        n += 1
        v, ev = pair
        next unless @miners.any?(&.view.same?(v)) # session closed mid-run → drop
        apply_event(v, ev)
        applied = true
      end
      applied
    end

    private def nonblocking_event : {MinerView, Miner::Event}?
      select
      when p = @mine_events.receive
        p
      else
        nil
      end
    end

    private def apply_event(v : MinerView, ev : Miner::Event) : Nil
      case ev
      when Miner::BaselineEvent then v.apply_baseline(ev)
      when Miner::FindingEvent  then v.append_finding(ev.finding)
      when Miner::ProgressEvent
        v.apply_progress(ev.progress)
        @host.jobs.progress(v.job_id, ev.progress.names_done.to_i, ev.progress.names_total.to_i, "#{ev.progress.found} found")
      when Miner::DoneEvent
        v.finish_run
        finish_job(v, ev)
      when Miner::ErrorEvent
        v.finish_run
        @host.jobs.finish(v.job_id, :error, ev.message)
        msg = "Miner: #{ev.message} on #{v.summary}"
        log_event(v, :error, msg)
        push_mine_notification(v, :error, msg)
        @host.status("miner error: #{ev.message}") if v.config.notify.posts_notification?(0, error: true)
      end
    end

    private def finish_job(v : MinerView, ev : Miner::DoneEvent) : Nil
      return if @host.jobs.errored?(v.job_id) # an ErrorEvent already finalized this run — the
      #                                         engine's trailing DoneEvent must not log/notify success
      n = v.found_count
      @host.jobs.finish(v.job_id, :done, "#{n} found")
      msg = "Miner: #{n} param#{n == 1 ? "" : "s"} found on #{v.summary}#{ev.stopped ? " (stopped)" : ""}"
      level = n > 0 ? :success : :info
      log_event(v, level, msg)
      push_mine_notification(v, level, msg, found: n)
      @host.status(msg) if v.config.notify.posts_notification?(n)
    end

    private def push_mine_notification(v : MinerView, level : Symbol, msg : String, found : Int32 = 0) : Nil
      return unless v.config.notify.posts_notification?(found, error: level == :error)
      @host.notifications.push(level, msg, goto_for(v), source: "miner")
    end

    # #124: append every mine completion/error to the store event feed UNCONDITIONALLY —
    # independent of the human NotifyMode gate above ("log freely, interrupt deliberately").
    private def log_event(v : MinerView, level : Symbol, msg : String) : Nil
      g = goto_for(v)
      @host.session.store.insert_event("miner", "job_done", level.to_s, msg,
        goto_tab: g.try(&.tab.to_s), goto_session_id: g.try(&.session_id))
    end

    private def goto_for(v : MinerView) : Jobs::Goto?
      tab = @miners.find(&.view.same?(v))
      (tab && (id = tab.db_id)) ? Jobs::Goto.new(:miner, id) : nil
    end

    # --- close / persist ---
    def request_close : Nil
      return unless tab = current_tab_obj
      @host.confirm("CLOSE MINER", "Close mining session \"#{tab.view.summary}\"?\nIts config and results are discarded.",
        confirm_label: "close", danger: true) { close_tab }
    end

    def close_tab : Nil
      return if @current_idx < 0 || @current_idx >= @miners.size
      tab = @miners[@current_idx]
      tab.view.request_stop # halt a running mine before detaching (the run fiber polls this)
      # Finish the job NOW: once the view leaves @miners, drain_events drops its remaining
      # events (incl. Done), so jobs.finish would never run and the bottom-bar spinner would
      # animate forever. The background fiber still unwinds on its own via request_stop.
      @host.jobs.finish(tab.view.job_id, :stopped, "closed") if tab.view.running?
      if id = tab.db_id
        @host.session.store.delete_miner_session(id)
      end
      @miners.delete_at(@current_idx)
      @current_idx = @miners.empty? ? -1 : @current_idx.clamp(0, @miners.size - 1)
      @host.status(@miners.empty? ? "closed — none open" : "closed (#{@miners.size} open)")
    end

    def save_current : Nil
      return unless tab = current_tab_obj
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      cfg = v.config_json
      @host.session.store.update_miner_session(id, v.target_origin, v.request_bytes, v.http2?, v.sni_override, cfg, v.name)
      v.mark_config_synced(cfg)
      v.clear_dirty
    end

    # Live converge with miner_sessions after a data_version bump. Soft-sync only —
    # never full restore (would wipe findings + force focus defaults).
    def reconcile : Nil
      rows = @host.session.store.miner_sessions
      by_id = rows.index_by(&.id)
      cur_db = current_tab_obj.try(&.db_id)
      cur_view = current_tab_obj.try(&.view)

      @miners.each do |tab|
        next unless (id = tab.db_id) && (row = by_id[id]?)
        next if miner_tab_locked?(tab)
        v = tab.view
        next if v.session_side_matches?(row)
        v.apply_peer_session(row)
      end

      local_ids = @miners.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = MinerView.new
        view.restore(row)
        @miners << MinerTab.new(view, row.flow_id, row.id)
      end

      @miners.reject! do |tab|
        (id = tab.db_id) && !by_id.has_key?(id) && !miner_tab_locked?(tab)
      end

      @miners.sort_by! do |tab|
        if (id = tab.db_id) && (row = by_id[id]?)
          {row.position, id}
        else
          {Int32::MAX, Int64::MAX}
        end
      end

      @current_idx =
        if cur_db && (idx = @miners.index { |t| t.db_id == cur_db })
          idx
        elsif (cv = cur_view) && (idx = @miners.index { |t| t.view.same?(cv) })
          idx
        elsif @miners.empty?
          -1
        else
          @current_idx.clamp(0, @miners.size - 1)
        end
    end

    private def current_tab_obj : MinerTab?
      return nil if @current_idx < 0 || @current_idx >= @miners.size
      @miners[@current_idx]
    end

    private def miner_tab_locked?(tab : MinerTab) : Bool
      v = tab.view
      v.running? || v.dirty?
    end
  end
end
