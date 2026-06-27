require "../tab_controller"
require "../fuzzer_view"
require "../../store"
require "../../fuzz"

module Gori::Tui
  # One open Fuzzer session (a sub-tab under the Fuzzer tab). `flow_id` is the source
  # History flow (⇧I), or nil for a hand-authored session (^N). `db_id` is the
  # persisted `fuzz_sessions` row id (nil only if the store was closing).
  record FuzzerTab, view : FuzzerView, flow_id : Int64?, db_id : Int64?

  # The Fuzzer tab: a workbench of independent fuzz/intruder sessions (sub-tabs).
  # Mirrors ReplayController (multi-session, sub-tab strip, save-on-leave, async drain),
  # but a run streams MANY results (blocking Result/Done sends — never dropped; only
  # Progress is droppable). The session (template+config) persists across reopen; the
  # results stay in-memory per session (like Replay responses before V11).
  class FuzzerController < TabController
    CONFIRM_THRESHOLD = 1000 # confirm before a run larger than this (or unknown size)
    DRAIN_CAP         =  512 # bounded per-tick drain so a fast run can't starve render

    def initialize(host : Host)
      super(host)
      @fuzzers = [] of FuzzerTab
      @host.session.store.fuzz_sessions.each do |rec|
        view = FuzzerView.new
        view.restore(rec)
        @fuzzers << FuzzerTab.new(view, rec.flow_id, rec.id)
      end
      @current_idx = @fuzzers.empty? ? -1 : 0
      # Bigger than Replay's 8 — a run emits one event per request plus progress.
      @fuzz_events = Channel({FuzzerView, Fuzz::Event}).new(256)
    end

    def tab : Symbol
      :fuzzer
    end

    def command_scope : Verb::Scope
      Verb::Scope::Fuzzer
    end

    # --- shell-facing accessors ---
    def count : Int32
      @fuzzers.size
    end

    def empty? : Bool
      @fuzzers.empty?
    end

    def current_idx : Int32
      @current_idx
    end

    def current_view : FuzzerView?
      current_tab_obj.try(&.view)
    end

    def subtab_labels : Array(String)
      @fuzzers.map_with_index { |t, i| "#{i + 1}:#{t.view.label(18)}" }
    end

    def subtab_index : Int32
      @current_idx
    end

    def view_at(idx : Int32) : FuzzerView?
      (0 <= idx < @fuzzers.size) ? @fuzzers[idx].view : nil
    end

    def body_badge : Symbol
      v = current_view
      return :body unless v
      (v.focus == :template || v.focus == :target || v.focus == :config) ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      v = current_view
      return "↹/esc tabs · ^N new" unless v
      case v.focus
      when :target   then "type URL · ↵/↓ template · ^R run · ↹ pane · esc tabs"
      when :template then "type · ^A params · ^K word · ^T point · ^U clear · ^O config · ^R run · ↹ pane"
      when :config   then "↑/↓ field · ←/→ change·type-tab · type edit · ⏎ add · Del rm · ↹ pane"
      when :results  then "↑/↓ select · ↵ detail · o sort · m matched · ^R run · ^X stop · space cmds · ↹ pane"
      when :detail   then "↑/↓ scroll · ←/→ req/resp · esc back"
      else                "↹/esc tabs"
      end
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      body_rect = rect
      if @fuzzers.size >= 2
        sub_rect, body_rect = BodyChrome.carve_subtab_row(rect)
        BodyChrome.render_subtab_strip(screen, sub_rect, subtab_labels, @current_idx, focus == :subtabs)
      end
      if v = current_view
        v.render(screen, body_rect, focused: body_focused)
      else
        BodyChrome.framed(screen, body_rect, body_focused) do |inner|
          screen.text(inner.x + 1, inner.y, "no fuzz sessions — ⇧I from History/Replay · ^N new", Theme.muted)
        end
      end
    end

    # --- input ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      v = current_view
      return true if v.nil?
      # space opens the action menu in the navigable results pane; the editor panes
      # (target/template/config) take it as a literal char, so gate on :results.
      if v.focus == :results && ev.key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      c = ev.char || ev.key.to_char
      unless dispatch_chord(chord_action(ev, c), v, c)
        ev.key.escape? ? handle_escape(v) : handle_pane_key(ev, v)
      end
      true
    end

    # Run the action a chord mapped to; false when it was not a chord (fall through).
    private def dispatch_chord(action : Symbol?, v : FuzzerView, c : Char?) : Bool
      case action
      when :palette   then save_current; @host.open_palette
      when :run       then fuzz_run
      when :stop      then fuzz_stop
      when :close     then request_close
      when :automark  then @host.status(v.auto_mark)
      when :markword  then @host.status(v.mark_word)
      when :markpoint then @host.status(v.insert_marker)
      when :clear     then @host.status(v.clear_marks)
      when :config    then v.focus_config
      when :switch    then switch_subtab(c)
      else                 return false
      end
      true
    end

    # The ctrl-chord (or digit sub-tab switch) this key maps to, else nil.
    private def chord_action(ev : Termisu::Event::Key, c : Char?) : Symbol?
      return nil unless ev.ctrl?
      key = ev.key
      case
      when key.lower_p?         then :palette
      when key.lower_r?         then :run
      when key.lower_x?         then :stop
      when key.lower_w?         then :close
      when key.lower_a?         then :automark
      when key.lower_k?         then :markword
      when key.lower_t?         then :markpoint
      when key.lower_u?         then :clear
      when key.lower_o?         then :config
      when c && '1' <= c <= '9' then :switch
      end
    end

    private def handle_escape(v : FuzzerView) : Nil
      v.focus == :detail ? v.focus_pane(:results) : @host.request_focus(:menu)
    end

    private def switch_subtab(c : Char?) : Nil
      return unless c
      idx = c.to_i - 1
      if idx < @fuzzers.size
        save_current
        @current_idx = idx
      end
    end

    private def printable(ev : Termisu::Event::Key) : Char?
      return nil if ev.ctrl? || ev.alt?
      ev.char || ev.key.to_char
    end

    private def handle_pane_key(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      case v.focus
      when :target   then edit_target(ev, v)
      when :template then edit_template(ev, v)
      when :config   then edit_config(ev, v)
      when :results  then handle_results(ev, v)
      when :detail   then handle_detail(ev, v)
      end
    end

    private def edit_target(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      key = ev.key
      case
      when key.enter?, key.down? then v.pane_advance(1)
      when key.up?               then @host.request_focus(@fuzzers.size >= 2 ? :subtabs : :menu)
      when key.backspace?        then v.target_backspace
      when key.left?             then v.target_move(-1)
      when key.right?            then v.target_move(1)
      else
        printable(ev).try { |ch| v.target_insert(ch) }
      end
    end

    private def edit_template(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      key = ev.key
      case
      when key.enter?     then v.template_newline
      when key.backspace? then v.template_backspace
      when key.up?        then template_up(v)
      when key.down?      then v.template_move(1, 0)
      when key.left?      then v.template_move(0, -1)
      when key.right?     then v.template_move(0, 1)
      else
        printable(ev).try { |ch| v.template_insert(ch) }
      end
    end

    private def template_up(v : FuzzerView) : Nil
      v.at_top? ? @host.request_focus(@fuzzers.size >= 2 ? :subtabs : :menu) : v.template_move(-1, 0)
    end

    private def edit_config(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      key = ev.key
      case
      when key.up?        then config_up(v)
      when key.down?      then v.form_move(1)
      when key.left?      then v.form_adjust(-1)
      when key.right?     then v.form_adjust(1)
      when key.enter?     then v.form_enter
      when key.delete?    then v.form_delete
      when key.backspace? then v.form_backspace
      else
        printable(ev).try { |ch| v.form_type(ch) }
      end
    end

    private def config_up(v : FuzzerView) : Nil
      v.at_top? ? @host.request_focus(@fuzzers.size >= 2 ? :subtabs : :menu) : v.form_move(-1)
    end

    private def handle_results(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      key = ev.key
      case
      when key.enter?   then v.open_detail
      when key.up?      then v.at_top? ? @host.request_focus(@fuzzers.size >= 2 ? :subtabs : :menu) : v.results_move(-1)
      when key.down?    then v.results_move(1)
      when key.lower_o? then @host.status(v.cycle_sort)
      when key.lower_m? then @host.status(v.toggle_matched_only)
      end
    end

    private def handle_detail(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      key = ev.key
      case
      when key.up?               then v.detail_scroll(-1)
      when key.down?             then v.detail_scroll(1)
      when key.left?, key.right? then v.detail_toggle_pane
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = @fuzzers.size >= 2 ? BodyChrome.carve_subtab_row(rect)[1] : rect
      return true unless v = current_view
      if pane = v.pane_at(body, mx, my)
        save_current
        v.focus_pane(pane)
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

    def set_preedit(text : String) : Bool
      current_view.try(&.set_preedit(text))
      true
    end

    def commit : Nil
      save_current
    end

    def locked? : Bool
      return false unless v = current_view
      v.running? || v.dirty? || (@host.active_tab == :fuzzer && @host.focus == :body)
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

    # --- sub-tab nav ---
    def move_subtab(dir : Int32) : Nil
      return unless @fuzzers.size >= 2
      nidx = (@current_idx + dir).clamp(0, @fuzzers.size - 1)
      return if nidx == @current_idx
      save_current
      @current_idx = nidx
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @fuzzers.size
      return if idx == @current_idx
      save_current
      @current_idx = idx
    end

    # --- rename (the shell's orthogonal rename prompt drives this by VIEW identity) ---
    # Apply the typed name to the captured tab + persist it on its own (set_fuzz_session_name,
    # separate from save_current so the rename lands even when the session is otherwise clean).
    # Re-find by VIEW identity so a closed/reordered tab is a no-op, never a neighbour. Blank
    # clears the custom label (the chip reverts to the template-derived summary).
    def apply_rename(view : FuzzerView, name : String) : Nil
      return unless tab = @fuzzers.find { |t| t.view.same?(view) }
      clean = name.strip
      view.name = clean.empty? ? nil : clean
      if id = tab.db_id
        @host.session.store.set_fuzz_session_name(id, view.name)
      end
    end

    # --- async (run loop) ---
    def drain_events : Bool
      applied = false
      n = 0
      while n < DRAIN_CAP && (pair = nonblocking_event)
        n += 1
        v, ev = pair
        next unless @fuzzers.any?(&.view.same?(v)) # session closed mid-run → drop
        apply_event(v, ev)
        applied = true
      end
      applied
    end

    private def nonblocking_event : {FuzzerView, Fuzz::Event}?
      select
      when p = @fuzz_events.receive
        p
      else
        nil
      end
    end

    private def apply_event(v : FuzzerView, ev : Fuzz::Event) : Nil
      case ev
      when Fuzz::ProgressEvent then v.apply_progress(ev.progress)
      when Fuzz::ResultEvent   then v.append_result(ev.result)
      when Fuzz::DoneEvent
        v.finish_run
        @host.status("fuzz done · #{v.matched_count}/#{v.result_count} matched#{ev.stopped ? " (stopped)" : ""}")
      when Fuzz::ErrorEvent
        v.finish_run
        @host.status("fuzz error: #{ev.message}")
      end
    end

    # --- run lifecycle ---
    def fuzz_run : Nil
      return unless v = current_view
      if v.running?
        @host.status("fuzz running — ^X to stop")
        return
      end
      engine, err = v.build_engine(!@host.session.config.insecure_upstream?)
      unless engine
        @host.status(err || "cannot run")
        return
      end
      total = begin
        engine.total
      rescue ex
        @host.status("fuzz: #{ex.message}")
        return
      end
      if total.nil? || total > CONFIRM_THRESHOLD
        e = engine
        @host.confirm("RUN FUZZ", "Send #{total ? total.to_s : "an unknown number of"} requests to #{v.target_origin}?",
          confirm_label: "run", danger: false) { start_run(v, e, total) }
      else
        start_run(v, engine, total)
      end
    end

    private def start_run(v : FuzzerView, engine : Fuzz::Engine, total : Int64?) : Nil
      save_current
      v.begin_run(total)
      events = @fuzz_events
      calibrate = v.config.auto_calibrate?
      spawn(name: "gori-fuzz") do
        engine.calibrate_baseline if calibrate
        engine.run do |ev|
          case ev
          when Fuzz::ProgressEvent
            select
            when events.send({v, ev})
            else
            end
          else
            events.send({v, ev}) # Result/Done/Error — blocking, never dropped
          end
          engine.stop if v.stop_requested?
        end
      ensure
        v.finish_run # backstop — the drain's Done also clears it + shows the summary
      end
      @host.status("fuzzing #{v.target_origin} — ^X stop")
    end

    def fuzz_stop : Nil
      return unless (v = current_view) && v.running?
      v.request_stop
      @host.status("stopping…")
    end

    # --- new / close / cross-tab seeds ---
    def fuzz_new : Nil
      view = FuzzerView.new
      view.load_request("https://example.com", "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", false, "")
      open_session(view, nil)
      @host.status("new fuzz session — ^A mark params · ^O config · ^R run")
    end

    # ⇧I from History (or Findings evidence): open a captured flow as a fuzz session.
    def fuzz_flow(id : Int64) : Nil
      return unless detail = @host.session.store.get_flow(id)
      view = FuzzerView.new
      view.load(detail)
      open_session(view, id)
      @host.status("fuzzer: #{view.summary} — ^A auto-mark · ^K word · ^O config · ^R run")
    end

    # Turn a Replay request (or any reconstructed request) into a fuzz session.
    def fuzz_from_request(target : String, request_text : String, http2 : Bool, sni : String?) : Nil
      view = FuzzerView.new
      view.load_request(target, request_text, http2, sni || "")
      open_session(view, nil)
      @host.status("fuzzer ← request — ^A auto-mark · ^O config · ^R run")
    end

    private def open_session(view : FuzzerView, flow_id : Int64?) : Nil
      @fuzzers << FuzzerTab.new(view, flow_id, persist_new(view, flow_id))
      @current_idx = @fuzzers.size - 1
      @host.goto_tab(:fuzzer)
    end

    private def persist_new(view : FuzzerView, flow_id : Int64?) : Int64?
      id = @host.session.store.insert_fuzz_session(view.target, view.template_text, view.http2?,
        view.sni_override, view.config_json, flow_id, @fuzzers.size, view.name)
      id == 0 ? nil : id
    end

    def request_close : Nil
      return unless tab = current_tab_obj
      @host.confirm("CLOSE FUZZER", "Close fuzz session \"#{tab.view.summary}\"?\nIts template/config and results are discarded.",
        confirm_label: "close", danger: true) { close_tab }
    end

    def close_tab : Nil
      return if @current_idx < 0 || @current_idx >= @fuzzers.size
      tab = @fuzzers[@current_idx]
      tab.view.request_stop # halt a running sweep before detaching its view (the run fiber polls this)
      if id = tab.db_id
        @host.session.store.delete_fuzz_session(id)
      end
      @fuzzers.delete_at(@current_idx)
      @current_idx = @fuzzers.empty? ? -1 : @current_idx.clamp(0, @fuzzers.size - 1)
      @host.status(@fuzzers.empty? ? "closed — none open (^N new · ⇧I from History)" : "closed (#{@fuzzers.size} open)")
    end

    # --- persistence ---
    def save_current : Nil
      return unless tab = current_tab_obj
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      @host.session.store.update_fuzz_session(id, v.target, v.template_text, v.http2?, v.sni_override, v.config_json, v.name)
      v.clear_dirty
    end

    private def current_tab_obj : FuzzerTab?
      return nil if @current_idx < 0 || @current_idx >= @fuzzers.size
      @fuzzers[@current_idx]
    end
  end
end
