require "../tab_controller"
require "../traffic_empty_state"
require "../fuzzer_view"
require "../clipboard"
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

    # The space menu's CONTEXT section: whichever pane the active session is focused
    # on (:target/:template/:config/:results/:detail). :common with no session open.
    def command_section : Symbol
      current_view.try(&.focus) || :common
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

    # Show the strip from the FIRST fuzzer (not ≥2): a single session still labels its
    # chip and exposes the strip's space-menu. Empty → no strip.
    def subtab_strip_shown? : Bool
      !@fuzzers.empty?
    end

    def view_at(idx : Int32) : FuzzerView?
      (0 <= idx < @fuzzers.size) ? @fuzzers[idx].view : nil
    end

    def body_badge : Symbol
      v = current_view
      return :body unless v
      v.pane_insert?(v.focus) ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      v = current_view
      return "↹/esc tabs · ^N new" unless v
      read_common = "⇧arrows select · y copy · space cmds"
      case v.focus
      when :target
        if v.target_insert?
          "type URL · ↵/↓ template · ^R run · ↹ pane · esc read"
        else
          "i/↵ edit · #{read_common} · ^R run · ↹ pane · esc tabs"
        end
      when :template
        if v.template_insert?
          "type · ^A params · ^K word · ^T point · ^O config · ^R run · esc read · ↹ pane"
        else
          "i/↵ edit · #{read_common} · ^A params · ^O config · ^R run · ↹ pane · esc tabs"
        end
      when :config   then config_hint(v)
      when :results  then "↑/↓ select · ↵ detail · o sort · m matched · v dist · ^R run · ^X stop · space cmds · ↹ pane"
      when :detail   then "↑/↓ move · #{read_common} · ←/→ pane · ⇧←/→ h-scroll · esc back"
      else                "↹/esc tabs"
      end
    end

    private def config_hint(v : FuzzerView) : String
      case v.config_row
      when :set  then "↑/↓ row · ↵ edit set · Del remove · ^R run · ↹ pane"
      when :add  then "↵ add a payload set · ^L quick List · ↑/↓ row · ^R run · ↹ pane"
      when :mode then "←/→ mode · ↵ open editor · ↑/↓ row · ^R run · ↹ pane"
      when :run  then "↵ run · ↑/↓ row · ^O sets · ↹ pane"
      else            "↵ open Advanced · ↑/↓ row · ^R run · ↹ pane"
      end
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: !current_view.nil?)
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, labels, @current_idx, @subtab_start) do |content|
        if v = current_view
          v.render(screen, content, focused: body_focused)
        else
          TrafficEmptyState.render(screen, content, variant: :fuzzer)
        end
      end
    end

    # --- input ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      v = current_view
      if v.nil?
        key = ev.key
        if key.up? || key.lower_k?
          @host.request_focus(:menu)
          return true
        end
        # No session yet: defer other keys to the central handler (^P palette, esc, …).
        return false
      end
      c = ev.char || ev.key.to_char
      return true if dispatch_chord(chord_action(ev, c), v, c)
      # An unconsumed ctrl/alt chord (^R run, ^X stop, ^A automark, …) defers to the
      # central keymap so it's rebindable; escape + plain keys stay with the pane editor.
      return false if (ev.ctrl? || ev.alt?) && !ev.key.escape?
      ev.key.escape? ? handle_escape(v) : handle_pane_key(ev, v)
      true
    end

    # Run the action a chord mapped to; false when it was not a chord (fall through).
    private def dispatch_chord(action : Symbol?, v : FuzzerView, c : Char?) : Bool
      case action
      when :palette   then save_current; @host.open_palette
      when :close     then request_close
      when :markword  then @host.status(v.mark_word)
      when :markpoint then @host.status(v.insert_marker)
      when :config    then v.focus_config
      when :switch    then switch_subtab(c)
      else                 return false
      end
      true
    end

    # The ctrl-chord (or digit sub-tab switch) this key maps to, else nil. run/stop/
    # automark are NOT here — they're keymap-driven verbs (rebindable) and fall through.
    private def chord_action(ev : Termisu::Event::Key, c : Char?) : Symbol?
      return nil unless ev.ctrl?
      key = ev.key
      case
      when key.lower_p?         then :palette
      when key.lower_w?         then :close
      when key.lower_k?         then :markword
      when key.lower_t?         then :markpoint
      when key.lower_o?         then :config
      when c && '1' <= c <= '9' then :switch
      end
    end

    private def handle_escape(v : FuzzerView) : Nil
      return v.commit_chain_pane if v.chain_pane_active? # esc in the CHAIN pane → save + back
      if v.focus == :template && v.template_insert?
        v.exit_template_insert!
      elsif v.focus == :target && v.target_insert?
        v.exit_target_insert!
      elsif v.focus == :detail
        v.focus_pane(:results)
      else
        @host.request_focus(:subtabs)
      end
    end

    # ^Y: focus the CHAIN pane for the marker under the template cursor (again = save + back).
    def fuzz_focus_chain_pane : Nil
      return unless view = current_view
      if view.chain_pane_active?
        view.commit_chain_pane
        save_current
        @host.status("chain saved")
      else
        msg = view.focus_chain_pane
        @host.status(msg || "type the chain · Tab completes · ↵/esc saves")
      end
    end

    # ^L / "Add a List payload set": open the Set overlay pre-seeded to the List type,
    # a newline-native editor (one value per line, paste splits automatically).
    def fuzz_list_paste : Nil
      return unless current_view
      @host.open_fuzz_set_editor(nil)
    end

    def fuzz_pretty_template : Nil
      return unless view = current_view
      if err = view.pretty_print_template
        @host.status(err)
      else
        @host.status("pretty-printed template request body")
      end
    end

    # Strip every §…§ marker (and its chain) from the template. Space-menu only —
    # `^U` now pretty-prints (matching Replay); clearing lives in the space menu here too.
    def fuzz_clear_marks : Nil
      return unless view = current_view
      @host.status(view.clear_marks)
    end

    # The Runner calls these when an overlay applies (esc / ↵-on-last-field).
    def apply_fuzz_set(edit_index : Int32?, spec : SetSpec?) : Nil
      return unless v = current_view
      v.apply_set(edit_index, spec)
      save_current
    end

    def apply_fuzz_advanced(snap : AdvancedSnapshot) : Nil
      return unless v = current_view
      v.apply_advanced(snap)
      save_current
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
      return handle_target_read(ev, v) unless v.target_insert?
      key = ev.key
      case
      when key.enter?, key.down? then v.pane_advance(1)
      when key.up?               then @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      else                          edit_target_common(ev, v)
      end
    end

    private def handle_target_read(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      return @host.open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      c = ev.char || key.to_char
      selecting = ev.shift?
      case
      when key.enter? then v.enter_target_insert!
      when c == 'i'   then v.enter_target_insert!
      when key.up?    then @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      when key.down?  then v.pane_advance(1)
      when key.left?  then v.target_read_move(-1, selecting: selecting)
      when key.right? then v.target_read_move(1, selecting: selecting)
      when key.home?  then v.target_home
      when key.end?   then v.target_end
      when c == 'x'   then v.pane_select_line
      when c == 'y'   then fuzzer_copy
      end
    end

    private def edit_target_common(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      key = ev.key
      case
      when key.backspace? then v.target_backspace
      when key.left?      then v.target_move(-1)
      when key.right?     then v.target_move(1)
      when key.home?      then v.target_home
      when key.end?       then v.target_end
      else
        printable(ev).try { |ch| v.target_insert(ch) }
      end
    end

    private def edit_template(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      return v.handle_chain_pane_key(ev) if v.chain_pane_active? # CHAIN sub-pane owns typing
      return handle_template_read(ev, v) unless v.template_insert?
      key = ev.key
      case
      when key.enter?     then v.template_newline
      when key.backspace? then v.template_backspace
      when key.up?        then template_up(v)
      when key.down?      then v.template_move(1, 0)
      when key.left?      then v.template_move(0, -1)
      when key.right?     then v.template_move(0, 1)
      when key.home?      then v.template_home
      when key.end?       then v.template_end
      when key.delete?    then v.template_delete
      else
        printable(ev).try { |ch| v.template_insert(ch) }
      end
    end

    private def handle_template_read(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      return @host.open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      c = ev.char || key.to_char
      selecting = ev.shift?
      case
      when key.enter? then v.enter_template_insert!
      when c == 'i'   then v.enter_template_insert!
      when key.up?    then template_up(v, selecting)
      when key.down?  then v.template_read_move(1, 0, selecting: selecting)
      when key.left?  then v.template_read_move(0, -1, selecting: selecting)
      when key.right? then v.template_read_move(0, 1, selecting: selecting)
      when key.home?  then v.template_home
      when key.end?   then v.template_end
      when c == 'x'   then v.pane_select_line
      when c == 'y'   then fuzzer_copy
      end
    end

    private def template_up(v : FuzzerView, selecting : Bool = false) : Nil
      if v.template_at_top?
        v.pane_advance(-1)
      elsif v.template_insert?
        v.template_move(-1, 0)
      else
        v.template_read_move(-1, 0, selecting: selecting)
      end
    end

    # The CONFIG summary is a calm single-axis row list — no text entry (that drills into
    # the Set / Advanced overlays). TEMPLATE sits directly to CONFIG's left, so LEFT
    # focuses it (mirrors Shift-Tab) rather than adjusting a row — RIGHT still cycles
    # Mode forward, and Enter (activate_config_row) reaches every row's editor,
    # including a forward-only re-cycle of Mode (cycle_mode_forward): with only 4
    # modes, forward-only cycling still reaches every value, it just costs up to 3
    # extra presses instead of a reverse step.
    private def edit_config(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      key = ev.key
      case
      # CONFIG is a row list, not a text field, so j/k navigate here (like RESULTS and
      # the Miner summary) — without this, `k` off the RESULTS top dead-ends in CONFIG.
      when key.up?, key.lower_k?       then config_up(v)
      when key.down?, key.lower_j?     then v.form_move(1)
      when key.left?                   then v.focus_pane(:template)
      when key.right?                  then v.form_adjust(1)
      when key.enter?                  then activate_config_row(v)
      when key.delete?, key.backspace? then v.form_delete
      end
    end

    # ↵ on a config row: drill into the Set / Advanced overlay, cycle Mode, or run.
    private def activate_config_row(v : FuzzerView) : Nil
      case v.config_row
      when :set      then @host.open_fuzz_set_editor(v.current_set_index)
      when :add      then @host.open_fuzz_set_editor(nil)
      when :mode     then v.cycle_mode_forward
      when :advanced then @host.open_fuzz_advanced_editor
      when :run      then fuzz_run
      end
    end

    private def config_up(v : FuzzerView) : Nil
      v.config_at_top? ? v.pane_advance(-1) : v.form_move(-1)
    end

    private def handle_results(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      return @host.open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      case
      when key.enter?              then v.open_detail
      when key.up?, key.lower_k?   then v.results_at_top? ? v.pane_advance(-1) : v.results_move(-1)
      when key.down?, key.lower_j? then v.results_move(1)
      when key.lower_o?            then @host.status(v.cycle_sort)
      when key.lower_m?            then @host.status(v.toggle_matched_only)
      when key.lower_v?            then @host.status(v.toggle_dist)
      end
    end

    private def handle_detail(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      return @host.open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt?
      return if handle_detail_hscroll(ev, v)
      key = ev.key
      selecting = ev.shift?
      case
      when key.up?, key.lower_k?
        v.detail_cursor_at_top? ? v.focus_pane(:results) : v.detail_move(-1, 0, selecting: selecting)
      when key.down?, key.lower_j? then v.detail_move(1, 0, selecting: selecting)
      when key.left?               then v.detail_step_pane(-1)
      when key.right?              then v.detail_step_pane(1)
      when ev.char == 'x'          then v.pane_select_line
      when ev.char == 'y'          then fuzzer_copy
      end
    end

    private def handle_detail_hscroll(ev : Termisu::Event::Key, v : FuzzerView) : Bool
      key = ev.key
      if key.left? && ev.shift?
        v.hscroll_detail(-1)
        true
      elsif key.right? && ev.shift?
        v.hscroll_detail(1)
        true
      else
        false
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = BodyChrome.content_rect(rect, strip: subtab_strip_shown?)
      return true unless v = current_view
      # RESULTS border badges (DIST / MATCH / sort) before row select.
      if chip = v.results_chrome_hit(body, mx, my)
        save_current
        @host.focus_body
        v.focus_pane(:results)
        case chip
        when :dist  then @host.status(v.toggle_dist)
        when :match then @host.status(v.toggle_matched_only)
        when :sort  then @host.status(v.cycle_sort)
        end
        return true
      end
      return true unless pane = v.pane_at(body, mx, my)
      save_current
      @host.focus_body
      if pane == :results
        click_results(v, body, mx, my)
      else
        v.focus_pane(pane)
        case pane
        when :template
          v.template_click_to_cursor(body, mx, my)
        when :target
          v.target_click_to_cursor(body, mx, my)
        end
      end
      true
    end

    # A click in the RESULTS pane: select the row under the cursor (grabbing focus
    # from another pane on the first click), or — a second click on the already-
    # selected row while the pane already holds focus — open its detail, so mouse
    # matches ↵ (mirrors History's select-then-open).
    private def click_results(v : FuzzerView, body : Rect, mx : Int32, my : Int32) : Nil
      already = v.focus == :results
      row = v.results_row_at(body, mx, my)
      if row && already && row == v.results_selected_index
        v.open_detail
      else
        v.focus_pane(:results)
        v.select_result_row(row) if row
      end
    end

    def handle_wheel(step : Int32) : Bool
      if v = current_view
        case v.focus
        when :results  then v.results_move(step)
        when :detail   then v.detail_scroll_view(step)
        when :template then v.template_scroll_view(step)
        end
      end
      true
    end

    def set_preedit(text : String) : Bool
      current_view.try do |v|
        next unless v.pane_insert?(v.focus)
        v.set_preedit(text)
      end
      true
    end

    def fuzzer_copy : Nil
      v = current_view
      return unless v
      text = v.pane_copy_text
      return if text.empty?
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard")
    end

    def fuzzer_copy_all : Nil
      v = current_view
      return unless v
      text = v.pane_copy_all_text
      return if text.empty?
      written = Clipboard.copy(text)
      msg = "copied all (#{written}b)"
      msg += " — clipped from #{text.bytesize}b (64KB cap)" if written < text.bytesize
      @host.status(msg)
    end

    def fuzzer_read_mode? : Bool
      v = current_view
      return false unless v
      case v.focus
      when :template then !v.pane_insert?(:template)
      when :target   then !v.pane_insert?(:target)
      when :detail   then true
      when :results  then true
      else               false
      end
    end

    def fuzzer_selection_active? : Bool
      current_view.try(&.pane_selection?) == true
    end

    def fuzzer_select_line : Nil
      current_view.try(&.pane_select_line)
    end

    def fuzzer_clear_selection : Nil
      current_view.try(&.pane_clear_selection)
    end

    def commit : Nil
      save_current
    end

    def locked? : Bool
      return false unless v = current_view
      v.running? || v.dirty? || v.pane_insert?(:template) || v.pane_insert?(:target) ||
        (@host.active_tab == :fuzzer && @host.focus == :body)
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
      when Fuzz::ProgressEvent
        v.apply_progress(ev.progress)
        # Fuzz totals are Int64 and can exceed Int32::MAX (cluster-bomb / brute / huge
        # ranges); Jobs.progress takes Int32, and Int64#to_i is checked (raises
        # OverflowError on the run-loop fiber). Clamp to the Int32 ceiling for display.
        @host.jobs.progress(v.job_id,
          ev.progress.sent.clamp(0_i64, Int32::MAX.to_i64).to_i32,
          ev.progress.total.try(&.clamp(0_i64, Int32::MAX.to_i64).to_i32),
          "#{ev.progress.matched} hit")
      when Fuzz::ResultEvent then v.append_result(ev.result)
      when Fuzz::DoneEvent
        v.finish_run
        finish_job(v, ev)
      when Fuzz::ErrorEvent
        v.finish_run
        # Persist the failure in the bottom bar + notification center so it survives the
        # next keystroke (a transient toast alone is cleared on the very next key).
        @host.jobs.finish(v.job_id, :error, ev.message)
        @host.notifications.push(:error, "Fuzzer: #{ev.message} on #{v.summary}", goto_for(v))
        @host.status("fuzz error: #{ev.message}")
      end
    end

    private def finish_job(v : FuzzerView, ev : Fuzz::DoneEvent) : Nil
      n = v.matched_count
      @host.jobs.finish(v.job_id, :done, "#{n} hit")
      level = n > 0 ? :success : :info
      msg = "Fuzzer: #{n} hit#{n == 1 ? "" : "s"} / #{v.result_count} sent on #{v.summary}#{ev.stopped ? " (stopped)" : ""}"
      @host.notifications.push(level, msg, goto_for(v))
      @host.status(msg)
    end

    private def goto_for(v : FuzzerView) : Jobs::Goto?
      tab = @fuzzers.find(&.view.same?(v))
      (tab && (id = tab.db_id)) ? Jobs::Goto.new(:fuzzer, id) : nil
    end

    # Focus a fuzz sub-tab by persisted id (notification "jump to result").
    def reveal_session(id : Int64) : Nil
      if idx = @fuzzers.index { |t| t.db_id == id }
        @current_idx = idx
        @host.focus_body
      end
    end

    # --- run lifecycle ---
    def fuzz_run : Nil
      return unless v = current_view
      if v.running?
        @host.status("fuzz running — ^X to stop")
        return
      end
      # Flush any trailing Done/Error from a just-finished run before we rebind
      # job_id below. The engine sends its terminal event onto @fuzz_events BEFORE
      # the fiber's `ensure` flips running? false, so a ^R landing in that window
      # would otherwise apply the stale event to the NEW run's job (premature/wrong
      # "done", orphaned bottom-bar spinner). Draining now settles the old job first.
      drain_events
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
      v.job_id = @host.jobs.start(:fuzz, v.summary, goto: goto_for(v))
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
      view.load_blank
      open_session(view, nil)
      @host.status("new fuzz session — type the target URL · ^A mark params · ^O config · ^R run")
    end

    # Content-only clone of the active fuzz session (template + config; no results/links).
    def fuzz_duplicate : Nil
      return @host.status("no fuzz session open to duplicate") unless src = current_view
      view = FuzzerView.new
      view.duplicate_from(src)
      open_session(view, nil)
      @host.status("duplicated fuzz session (#{@fuzzers.size} open)")
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
      # Finish the job NOW: once the view leaves @fuzzers, drain_events drops its remaining
      # events (incl. Done), so jobs.finish would never run and the bottom-bar spinner would
      # animate forever (mirrors MinerController#close_tab).
      @host.jobs.finish(tab.view.job_id, :stopped, "closed") if tab.view.running?
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
      cfg = v.config_json
      @host.session.store.update_fuzz_session(id, v.target, v.template_text, v.http2?, v.sni_override, cfg, v.name)
      v.mark_config_synced(cfg)
      v.clear_dirty
    end

    # Live converge with fuzz_sessions after a data_version bump (own save or peer).
    # Soft-sync request side only — never full restore() (would wipe results + force
    # focus=:template).
    def reconcile : Nil
      rows = @host.session.store.fuzz_sessions
      by_id = rows.index_by(&.id)
      cur_db = current_tab_obj.try(&.db_id)
      cur_view = current_tab_obj.try(&.view)

      @fuzzers.each do |tab|
        next unless (id = tab.db_id) && (row = by_id[id]?)
        next if fuzz_tab_locked?(tab)
        v = tab.view
        next if v.session_side_matches?(row)
        v.apply_peer_session(row)
      end

      local_ids = @fuzzers.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = FuzzerView.new
        view.restore(row)
        @fuzzers << FuzzerTab.new(view, row.flow_id, row.id)
      end

      @fuzzers.reject! do |tab|
        (id = tab.db_id) && !by_id.has_key?(id) && !fuzz_tab_locked?(tab)
      end

      @fuzzers.sort_by! do |tab|
        if (id = tab.db_id) && (row = by_id[id]?)
          {row.position, id}
        else
          {Int32::MAX, Int64::MAX}
        end
      end

      @current_idx =
        if cur_db && (idx = @fuzzers.index { |t| t.db_id == cur_db })
          idx
        elsif (cv = cur_view) && (idx = @fuzzers.index { |t| t.view.same?(cv) })
          idx
        elsif @fuzzers.empty?
          -1
        else
          @current_idx.clamp(0, @fuzzers.size - 1)
        end
    end

    def current_session_db_id : Int64?
      current_tab_obj.try(&.db_id)
    end

    def index_for_db_id(id : Int64) : Int32?
      @fuzzers.index { |t| t.db_id == id }
    end

    def db_id_at(idx : Int32) : Int64?
      @fuzzers[idx]?.try(&.db_id)
    end

    private def current_tab_obj : FuzzerTab?
      return nil if @current_idx < 0 || @current_idx >= @fuzzers.size
      @fuzzers[@current_idx]
    end

    # Don't clobber a tab mid-edit or mid-run (mirrors Replay).
    private def fuzz_tab_locked?(tab : FuzzerTab) : Bool
      v = tab.view
      v.running? || v.dirty? || v.pane_insert?(:template) || v.pane_insert?(:target)
    end
  end
end
