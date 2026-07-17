require "../tab_controller"
require "../sequencer_view"
require "../sequence_config_overlay"
require "../../store"
require "../../sequencer"
require "../../env"
require "../../proxy/codec/http1"

module Gori::Tui
  # One open sequencing session (a sub-tab under the Sequencer tab). `flow_id` is the
  # source History flow (nil for a manual or Repeater-seeded one); `db_id` is the
  # persisted `sequencer_sessions` row id.
  record SequencerTab, view : SequencerView, flow_id : Int64?, db_id : Int64?

  # The Sequencer tab: independent token-randomness sessions (sub-tabs). A collection is
  # a BACKGROUND job — seeding one from History's space menu does NOT switch here; a
  # manual paste ("Send selection to Sequencer") does. Session config persists across
  # reopen; collected tokens are live secrets and stay in-memory (never on disk).
  class SequencerController < TabController
    DRAIN_CAP = 512

    def initialize(host : Host)
      super(host)
      @sessions = [] of SequencerTab
      @host.session.store.sequencer_sessions.each do |rec|
        view = SequencerView.new
        view.restore(rec)
        @sessions << SequencerTab.new(view, rec.flow_id, rec.id)
      end
      @current_idx = @sessions.empty? ? -1 : 0
      @seq_events = Channel({SequencerView, Sequencer::Event}).new(256)
    end

    def tab : Symbol
      :sequencer
    end

    def command_scope : Verb::Scope
      Verb::Scope::Sequencer
    end

    def command_section : Symbol
      :common
    end

    # --- shell-facing accessors ---
    def count : Int32
      @sessions.size
    end

    def empty? : Bool
      @sessions.empty?
    end

    def current_view : SequencerView?
      current_tab_obj.try(&.view)
    end

    def subtab_labels : Array(String)
      @sessions.map_with_index { |t, i| "#{i + 1}:#{t.view.label(18)}" }
    end

    def subtab_strip_shown? : Bool
      !@sessions.empty?
    end

    def subtab_index : Int32
      @current_idx
    end

    def view_at(idx : Int32) : SequencerView?
      (0 <= idx < @sessions.size) ? @sessions[idx].view : nil
    end

    def body_badge : Symbol
      :body # read-only display + navigable tables — never an editor
    end

    def body_hint(focus : Symbol) : String
      v = current_view
      return "↹/esc tabs · send a request here (space → Send to Sequencer) or a selection" unless v
      case v.focus
      when :samples  then "↑/↓ select · ↵ detail · ^X stop · c config · space cmds · ↹ pane · esc tabs"
      when :analysis then "↑/↓ scroll · ^R run · c config · ↹ pane · esc tabs"
      when :detail   then "↑/↓ scroll · esc back"
      else                "^R run · c config · space cmds · ↹ pane · esc tabs"
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
              "no sequencer sessions — from History/Repeater press space → \"Send to Sequencer\", or select a token and use \"Send selection to\"", Theme.muted)
          end
        end
      end
    end

    # --- input ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      v = current_view
      if v.nil?
        key = ev.key
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
      if c == 'c' && !ev.ctrl? && !ev.alt? && v.focus != :detail
        @host.reconfigure_sequence
        return true
      end
      return false if (ev.ctrl? || ev.alt?) && !ev.key.escape? # ^R/^X → keymap verb
      ev.key.escape? ? handle_escape(v) : handle_pane_key(ev, v)
      true
    end

    private def dispatch_chord(action : Symbol?, v : SequencerView, c : Char?) : Bool
      case action
      when :palette then @host.open_palette
      when :close   then request_close
      when :switch  then switch_subtab(c)
      else               return false
      end
      true
    end

    private def navigable_pane?(pane : Symbol) : Bool
      pane == :config || pane == :samples || pane == :analysis
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

    private def handle_escape(v : SequencerView) : Nil
      if v.focus == :detail
        v.close_detail
      else
        @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      end
    end

    private def switch_subtab(c : Char?) : Nil
      return unless c
      idx = c.to_i - 1
      @current_idx = idx if idx < @sessions.size
    end

    private def handle_pane_key(ev : Termisu::Event::Key, v : SequencerView) : Nil
      case v.focus
      when :config   then handle_config(ev, v)
      when :samples  then handle_samples(ev, v)
      when :analysis then handle_analysis(ev, v)
      when :detail   then handle_detail(ev, v)
      end
    end

    private def handle_config(ev : Termisu::Event::Key, v : SequencerView) : Nil
      key = ev.key
      if key.down? || key.lower_j?
        v.focus_pane(:samples)
      elsif key.up? || key.lower_k?
        @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      end
    end

    private def handle_samples(ev : Termisu::Event::Key, v : SequencerView) : Nil
      key = ev.key
      case
      when key.enter?              then v.open_detail
      when key.down?, key.lower_j? then v.samples_move(1)
      when key.up?, key.lower_k?   then v.samples_at_top? ? v.focus_pane(:config) : v.samples_move(-1)
      end
    end

    private def handle_analysis(ev : Termisu::Event::Key, v : SequencerView) : Nil
      key = ev.key
      if key.up? || key.lower_k?
        v.analysis_scroll(-1)
      elsif key.down? || key.lower_j?
        v.analysis_scroll(1)
      end
    end

    private def handle_detail(ev : Termisu::Event::Key, v : SequencerView) : Nil
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
        when :samples  then v.samples_move(step)
        when :analysis then v.analysis_scroll(step)
        when :detail   then v.detail_scroll(step)
        end
      end
      true
    end

    def commit : Nil
      save_current
    end

    def locked? : Bool
      return false unless v = current_view
      v.running? || (@host.active_tab == :sequencer && @host.focus == :body)
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

    # --- sub-tab filter ---
    def subtab_filter_enabled? : Bool
      true
    end

    def filter_fields : Array(String)
      %w(name host method)
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @sessions.map do |t|
        v = t.view
        Repeater::SubtabFilter::Subject.new(v.name, v.summary(200), v.target, v.request_method, [] of String)
      end
    end

    # --- sub-tab nav ---
    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@current_idx, dir)
        @current_idx = t
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @sessions.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      @current_idx = idx
    end

    def reveal_session(id : Int64) : Nil
      if idx = index_for_db_id(id)
        @current_idx = idx
        @host.focus_body
      end
    end

    def current_session_db_id : Int64?
      return nil if @current_idx < 0 || @current_idx >= @sessions.size
      @sessions[@current_idx].db_id
    end

    def index_for_db_id(id : Int64) : Int32?
      @sessions.index { |t| t.db_id == id }
    end

    def db_id_at(idx : Int32) : Int64?
      @sessions[idx]?.try(&.db_id)
    end

    # --- rename ---
    def apply_rename(view : SequencerView, name : String) : Nil
      return unless tab = @sessions.find(&.view.same?(view))
      clean = name.strip
      view.name = clean.empty? ? nil : clean
      if id = tab.db_id
        @host.session.store.set_sequencer_session_name(id, view.name)
      end
    end

    # --- cross-tab seeds ---
    def build_seed_from_flow(id : Int64) : SequenceSeed?
      return nil unless detail = @host.session.store.get_flow(id)
      built = Repeater::FlowRequest.build(detail)
      loc = nil.as(Sequencer::TokenLoc?)
      cookies = [] of String
      headers = [] of String
      if raw = flow_response(detail)
        loc = Sequencer::Extract.autodetect(raw)
        cookies = Sequencer::Extract.candidate_cookies(raw)
        headers = Sequencer::Extract.candidate_headers(raw)
      end
      SequenceSeed.new(built.target, built.bytes, built.http2, detail.sni, id,
        request_summary(built.bytes), Sequencer::Mode::LiveReplay, loc, cookies, headers)
    end

    def build_seed_from_request(target : String, request_text : String, http2 : Bool, sni : String?) : SequenceSeed
      bytes = text_to_request(request_text)
      SequenceSeed.new(target, bytes, http2, sni, nil, request_summary(bytes),
        Sequencer::Mode::LiveReplay, nil, [] of String, [] of String)
    end

    # A seed describing the CURRENT session, for reconfiguring its descriptor in place.
    def build_seed_from_current : SequenceSeed?
      return nil unless v = current_view
      return nil if v.config.mode.manual? # manual sessions have no descriptor to configure
      SequenceSeed.new(v.target, v.request_bytes, v.http2?, v.sni_override, nil,
        v.summary, v.config.mode, v.config.token_loc, [] of String, [] of String)
    end

    private def flow_response(detail : Store::FlowDetail) : Repeater::Result?
      head = detail.response_head
      return nil unless head
      resp = Proxy::Codec::Http1.parse_response_head(head) rescue nil
      Repeater::Result.new(head, detail.response_body, resp, 0_i64)
    end

    private def request_summary(bytes : Bytes) : String
      line = String.new(bytes[0, {bytes.size, 256}.min]).each_line.first? || ""
      parts = line.strip.split(' ')
      s = "#{parts[0]?} #{parts[1]?}".strip
      s.empty? ? "request" : s
    end

    private def text_to_request(text : String) : Bytes
      Env.expand(text).gsub(/\r?\n/, "\r\n").to_slice
    end

    # --- send-selection: selected text becomes manual sample(s) ---
    def sequence_from_text(payload : String) : Nil
      tokens = payload.split(/\r?\n/).map(&.strip).reject(&.empty?)
      return @host.status("nothing to analyze") if tokens.empty?
      if (v = current_view) && v.config.mode.manual? && @host.active_tab == :sequencer
        v.append_manual_tokens(tokens)
        save_current
        drain_events
        start_run(v)
        @host.status("added #{tokens.size} token#{tokens.size == 1 ? "" : "s"} — analyzing")
      else
        config = Sequencer::Config.new(mode: Sequencer::Mode::Manual, manual_tokens: tokens)
        view = SequencerView.new
        view.load("", Bytes.empty, false, nil, config)
        open_session(view, nil)
        @host.goto_tab(:sequencer)
        start_run(view)
        @host.status("sequencer ← #{tokens.size} manual token#{tokens.size == 1 ? "" : "s"}")
      end
    end

    # --- start / reconfigure sessions (called by the Runner after the overlay confirms) ---
    def start_session(seed : SequenceSeed, config : Sequencer::Config) : Nil
      view = SequencerView.new
      view.load(seed.target, seed.request, seed.http2, seed.sni, config)
      open_session(view, seed.flow_id) # NB: NO goto_tab — the collection runs in the background
      start_run(view)
    end

    def reconfigure_current(config : Sequencer::Config) : Nil
      return unless v = current_view
      v.set_config(config)
      save_current
      drain_events
      start_run(v)
    end

    private def open_session(view : SequencerView, flow_id : Int64?) : Nil
      @sessions << SequencerTab.new(view, flow_id, persist_new(view, flow_id))
      @current_idx = @sessions.size - 1
    end

    private def persist_new(view : SequencerView, flow_id : Int64?) : Int64?
      # Manual sessions hold only pasted tokens (secrets) and an empty request — kept
      # purely in-memory (db_id nil), like ephemeral WS/gRPC repeaters. This also avoids a
      # NOT NULL constraint on the empty `request` blob, and honours "tokens never persist".
      return nil if view.config.mode.manual?
      id = @host.session.store.insert_sequencer_session(view.target_origin, view.request_bytes, view.http2?,
        view.sni_override, view.config_json, flow_id, @sessions.size, view.name)
      id == 0 ? nil : id
    end

    private def start_run(view : SequencerView) : Nil
      engine, err = view.build_engine(!@host.session.config.insecure_upstream?)
      unless engine
        @host.status(err || "cannot collect")
        return
      end
      view.begin_run
      view.job_id = @host.jobs.start(:sequence, view.summary, goto: goto_for(view))
      events = @seq_events
      spawn(name: "gori-sequencer") do
        engine.run do |ev|
          case ev
          when Sequencer::ProgressEvent
            select
            when events.send({view, ev})
            else
            end
          else
            events.send({view, ev}) # Sample/Done/Error — blocking, never dropped
          end
          engine.stop if view.stop_requested?
        end
      ensure
        view.finish_run
      end
      @host.status("collecting tokens in the background — watch the bottom bar / notifications")
    end

    # --- run controls ---
    def sequence_run : Nil
      return unless v = current_view
      if v.running?
        @host.status("already collecting — ^X to stop")
        return
      end
      drain_events
      start_run(v)
    end

    def sequence_stop : Nil
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
        next unless @sessions.any?(&.view.same?(v))
        apply_event(v, ev)
        applied = true
      end
      applied
    end

    private def nonblocking_event : {SequencerView, Sequencer::Event}?
      select
      when p = @seq_events.receive
        p
      else
        nil
      end
    end

    private def apply_event(v : SequencerView, ev : Sequencer::Event) : Nil
      case ev
      when Sequencer::SampleEvent then v.append_sample(ev.sample)
      when Sequencer::ProgressEvent
        v.apply_progress(ev.collected, ev.sent, ev.goal, ev.errors)
        denom = ev.goal <= 0 ? ev.collected : ev.goal
        @host.jobs.progress(v.job_id, ev.collected, denom, "#{ev.collected} tokens")
      when Sequencer::DoneEvent
        v.finish_run
        finish_job(v, ev)
      when Sequencer::ErrorEvent
        v.finish_run
        @host.jobs.finish(v.job_id, :error, ev.message)
        msg = "Sequencer: #{ev.message} on #{v.summary}"
        log_event(v, :error, msg)
        push_notification(v, :error, msg)
        @host.status("sequencer error: #{ev.message}") if v.config.notify.posts_notification?(0, error: true)
      end
    end

    private def finish_job(v : SequencerView, ev : Sequencer::DoneEvent) : Nil
      rep = v.report
      n = rep.usable_count
      @host.jobs.finish(v.job_id, :done, "#{n} · #{rep.rating.label.downcase}")
      msg = "Sequencer: #{n} token#{n == 1 ? "" : "s"} on #{v.summary} — #{rep.rating.label}#{ev.stopped ? " (stopped)" : ""}"
      level = rep.rating.value <= Sequencer::Stats::Rating::Weak.value ? :warning : :success
      log_event(v, level, msg)
      push_notification(v, level, msg, collected: n)
      @host.status(msg) if v.config.notify.posts_notification?(n)
    end

    private def push_notification(v : SequencerView, level : Symbol, msg : String, collected : Int32 = 0) : Nil
      return unless v.config.notify.posts_notification?(collected, error: level == :error)
      @host.notifications.push(level, msg, goto_for(v), source: "sequencer")
    end

    private def log_event(v : SequencerView, level : Symbol, msg : String) : Nil
      g = goto_for(v)
      @host.session.store.insert_event("sequencer", "job_done", level.to_s, msg,
        goto_tab: g.try(&.tab.to_s), goto_session_id: g.try(&.session_id))
    end

    private def goto_for(v : SequencerView) : Jobs::Goto?
      tab = @sessions.find(&.view.same?(v))
      (tab && (id = tab.db_id)) ? Jobs::Goto.new(:sequencer, id) : nil
    end

    # --- close / persist ---
    def request_close : Nil
      return unless tab = current_tab_obj
      @host.confirm("CLOSE SEQUENCER", "Close sequencing session \"#{tab.view.summary}\"?\nIts config and collected tokens are discarded.",
        confirm_label: "close", danger: true) { close_tab }
    end

    def close_tab : Nil
      return if @current_idx < 0 || @current_idx >= @sessions.size
      tab = @sessions[@current_idx]
      tab.view.request_stop
      @host.jobs.finish(tab.view.job_id, :stopped, "closed") if tab.view.running?
      if id = tab.db_id
        @host.session.store.delete_sequencer_session(id)
      end
      @sessions.delete_at(@current_idx)
      @current_idx = @sessions.empty? ? -1 : @current_idx.clamp(0, @sessions.size - 1)
      @host.status(@sessions.empty? ? "closed — none open" : "closed (#{@sessions.size} open)")
    end

    def save_current : Nil
      return unless tab = current_tab_obj
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      cfg = v.config_json
      @host.session.store.update_sequencer_session(id, v.target_origin, v.request_bytes, v.http2?, v.sni_override, cfg, v.name)
      v.mark_config_synced(cfg)
      v.clear_dirty
    end

    def reconcile : Nil
      rows = @host.session.store.sequencer_sessions
      by_id = rows.index_by(&.id)
      cur_db = current_tab_obj.try(&.db_id)
      cur_view = current_tab_obj.try(&.view)

      @sessions.each do |tab|
        next unless (id = tab.db_id) && (row = by_id[id]?)
        next if tab_locked?(tab)
        v = tab.view
        next if v.session_side_matches?(row)
        v.apply_peer_session(row)
      end

      local_ids = @sessions.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = SequencerView.new
        view.restore(row)
        @sessions << SequencerTab.new(view, row.flow_id, row.id)
      end

      @sessions.reject! do |tab|
        (id = tab.db_id) && !by_id.has_key?(id) && !tab_locked?(tab)
      end

      @sessions.sort_by! do |tab|
        if (id = tab.db_id) && (row = by_id[id]?)
          {row.position, id}
        else
          {Int32::MAX, Int64::MAX}
        end
      end

      @current_idx =
        if cur_db && (idx = @sessions.index { |t| t.db_id == cur_db })
          idx
        elsif (cv = cur_view) && (idx = @sessions.index { |t| t.view.same?(cv) })
          idx
        elsif @sessions.empty?
          -1
        else
          @current_idx.clamp(0, @sessions.size - 1)
        end
    end

    private def current_tab_obj : SequencerTab?
      return nil if @current_idx < 0 || @current_idx >= @sessions.size
      @sessions[@current_idx]
    end

    private def tab_locked?(tab : SequencerTab) : Bool
      v = tab.view
      v.running? || v.dirty?
    end
  end
end
