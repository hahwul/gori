require "../tab_controller"
require "../traffic_empty_state"
require "../fuzzer_view"
require "../clipboard"
require "../../store"
require "../../fuzz"
require "../../hotkeys"
require "../../probe"

module Gori::Tui
  # One open Fuzzer session (a sub-tab under the Fuzzer tab). `flow_id` is the source
  # History flow (⇧I), or nil for a hand-authored session (^N). `db_id` is the
  # persisted `fuzz_sessions` row id (nil only if the store was closing).
  record FuzzerTab, view : FuzzerView, flow_id : Int64?, db_id : Int64?

  # The Fuzzer tab: a workbench of independent fuzz/intruder sessions (sub-tabs).
  # Mirrors RepeaterController (multi-session, sub-tab strip, save-on-leave, async drain),
  # but a run streams MANY results (blocking Result/Done sends — never dropped; only
  # Progress is droppable). The session (template+config) persists across reopen; the
  # results stay in-memory per session and the latest successfully saved snapshot is restored
  # asynchronously when a persisted session is first activated.
  class FuzzerController < TabController
    CONFIRM_THRESHOLD = 1000 # confirm before a run larger than this (or unknown size)
    DRAIN_CAP         =  512 # bounded per-tick drain so a fast run can't starve render

    # How long a close gesture may hold the RENDER fiber waiting for a worker to leave.
    # A worker can sit inside an in-flight request whose own timeout outlives any close, so
    # an open-ended wait here is a frozen TUI — no repaint, no input, not even ^C. Past the
    # deadline we let go: the view is already detached, the per-tick `drain_events` keeps
    # unblocking a producer parked on a send, `end_worker` still reclaims it, and the spool's
    # directory teardown is what actually reclaims the bytes.
    QUIESCE_DEADLINE = 2.seconds

    # Store work happens on fibers, but view/Jobs/toast mutations stay on the Runner fiber.
    # Carry view identity + generation so a completion cannot land on a later run.
    record SaveDone, view : FuzzerView, generation : Int64, job_id : Int32,
      run_id : Int64, written : Int64, error : String?
    # `window`, not its rows: `FuzzerResultWindow` carries which rows it projected to
    # metrics-only, and that bit does not survive being re-appended into another window.
    record LoadDone, view : FuzzerView, generation : Int64, job_id : Int32,
      session_id : Int64, automatic : Bool, run : Store::FuzzRunRecord?,
      window : FuzzerResultWindow, error : String?
    # The run fiber's one report that the temporary archive stopped accepting rows. Sent at
    # the FIRST rejection, not at the end: a rejected append makes the whole run unsaveable,
    # and learning that after a 100k-request sweep is learning it too late to act on.
    record SpoolLost, view : FuzzerView, generation : Int64, reason : String
    alias IoEvent = SaveDone | LoadDone | SpoolLost

    private class ResultIoCancelled < Exception
    end

    private class ResultCopyStopped < Exception
    end

    def initialize(host : Host)
      super(host)
      @fuzzers = [] of FuzzerTab
      # Bigger than Repeater's 8 — a run emits one event per request plus progress.
      @fuzz_events = Channel({FuzzerView, Fuzz::Event}).new(256)
      @fuzz_io_events = Channel(IoEvent).new(256)
      @auto_load_considered = Set(Int64).new
      @spool = Fuzz::Spool.new
      @spool_runs = {} of FuzzerView => Fuzz::Spool::Run
      @workers = Hash(FuzzerView, Int32).new(0)
      @cancelled_views = Set(FuzzerView).new
      # Views whose close outran QUIESCE_DEADLINE. They stay cancelled until their last
      # worker leaves, and `end_worker` drops both references then — holding one for the
      # project's lifetime would pin that view's whole 64 MiB result window.
      @release_pending = Set(FuzzerView).new
      @closing = false
      @host.session.store.fuzz_sessions.each do |rec|
        view = FuzzerView.new
        view.restore(rec)
        @fuzzers << FuzzerTab.new(view, rec.flow_id, rec.id)
      end
      @current_idx = @fuzzers.empty? ? -1 : 0
      auto_load_current_saved_run
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

    # Cross-tab "Insert OAST payload": drop the URL at the template caret.
    def insert_oast_payload(url : String) : Bool
      (v = current_view) ? v.insert_oast_payload(url) : false
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

    # --- sub-tab filter (issue #121) ---
    def subtab_filter_enabled? : Bool
      true
    end

    def filter_fields : Array(String)
      %w[name host method] # fuzz sessions carry an HTTP template (target + method)
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @fuzzers.map do |t|
        v = t.view
        Repeater::SubtabFilter::Subject.new(v.name, v.summary(200), v.target, v.request_method, [] of String)
      end
    end

    # The ⌕ picker also searches each session's TEMPLATE (base hook, capped): a fuzz
    # session is findable by a header or §marker§ the operator remembers, not just the
    # request line its summary shows.
    def subtab_search_extras : Array(String)
      @fuzzers.map { |t| search_extra(t.view.template_text) }
    end

    def view_at(idx : Int32) : FuzzerView?
      (0 <= idx < @fuzzers.size) ? @fuzzers[idx].view : nil
    end

    # ^G/^F name the focused pane — the TEMPLATE editor and the RESULT detail, the tab's two
    # multi-line surfaces. TARGET is one line, CONFIG is a form and RESULTS is a table the
    # tab filters with its own `matched-only` + sort rather than a text find, so none of the
    # three has a line to jump to.
    #
    # The CHAIN sub-pane sits on top of the TEMPLATE column and takes its keys when active
    # (`chain_pane_active?`), so it is excluded for the same reason the Decoder's chain is:
    # the find prompt would search a document the pane is not editing.
    def goto_symbol : Symbol?
      return nil unless v = current_view
      return :fuzz_detail if v.focus == :detail
      :fuzz_template if v.focus == :template && !v.chain_pane_active?
    end

    def body_badge : Symbol
      v = current_view
      return :body unless v
      v.pane_insert?(v.focus) ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      v = current_view
      return I18n.ui("↹/esc tabs · ^N new") unless v
      reg = @host.session.registry
      y = Hotkeys.binding_label(reg, "fuzzer.copy", "y")
      run = Hotkeys.binding_label(reg, "fuzz.run", "^R")
      stop = Hotkeys.binding_label(reg, "fuzz.stop", "^X")
      save_key = Hotkeys.binding_label(reg, "fuzz.save-results", "⇧S")
      # One phrasing for the marker trio, shared with the Repeater's request footer. This
      # used to name `^A` in both modes and `^K` in INSERT only, and `^T` nowhere.
      params = Hotkeys.binding_label(reg, "fuzz.automark", "^A")
      word = Hotkeys.binding_label(reg, "fuzz.mark-word", "^K")
      point = Hotkeys.binding_label(reg, "fuzz.insert-marker", "^T")
      marks = I18n.ui("%{params} params · %{word} word · %{point} point", params: params, word: word, point: point)
      read_common = I18n.ui("⇧arrows select · %{y} copy · space cmds", y: y)
      sni = Hotkeys.binding_label(reg, "fuzz.toggle-sni", "^S")
      case v.focus
      when :target
        if v.editing_sni?
          I18n.ui("type SNI · %{sni}/↵/esc URL · %{run} run", sni: sni, run: run)
        elsif v.target_insert?
          I18n.ui("type URL · %{sni} SNI · ↵/↓ template · %{run} run · ↹ pane · esc read", sni: sni, run: run)
        else
          I18n.ui("i/↵ edit · %{common} · %{sni} SNI · %{run} run · ↹ pane · esc tabs", common: read_common, sni: sni, run: run)
        end
      when :template
        if v.template_insert?
          # `↹ text` and not `↹ pane`: Tab types a TAB here (a header value may hold one), the
          # same thing it does in the Repeater's request editor. The old wording promised a
          # focus move Tab has never made from an editor in INSERT.
          #
          # `^Y copy` sits right after the select token it completes: this footer already told
          # you a band could be built here and then named no key that copies one. In INSERT the
          # `y` the READ footer advertises is a literal character — and typing it over the band
          # REPLACES it, which is the whole reason `fuzzer.copy` carries a ctrl chord.
          I18n.ui("type · ⇧arrows select · ^Y copy · ^Z undo · %{marks} · ^O config · %{run} run · esc read · ↹ text", marks: marks, run: run)
        else
          I18n.ui("i/↵ edit · %{common} · %{marks} · ^F find · ^O config · %{run} run · ↹ pane · esc tabs", common: read_common, marks: marks, run: run)
        end
      when :config then config_hint(v, run)
      when :results
        # ⇧S only while the verb would actually fire. `fuzz.save-results` is gated on
        # `fuzzer_results_saveable?` (verbs/history.cr), which is false while a run is going,
        # while a save/load is in flight, with no results, and once the run has been saved or
        # restored — and an unavailable verb is never dispatched, so the key did NOTHING and
        # said nothing while this line kept promising it. That also made the controller's own
        # "fuzz results already saved as run #N" refusal unreachable through the binding.
        # Named off the same predicate the gate reads, not a second copy of its conditions.
        save = v.results_saveable? ? I18n.ui(" · %{save} save", save: save_key) : ""
        I18n.ui("↑/↓ select · ↵ detail · o sort · m matched · v dist%{save} · %{run} run · %{stop} stop · space cmds · ↹ pane",
          save: save, run: run, stop: stop)
      when :detail then I18n.ui("↑/↓ move · %{common} · ←/→ pane · ^F find · esc back", common: read_common)
      else              I18n.ui("↹/esc tabs")
      end
    end

    private def config_hint(v : FuzzerView, run : String) : String
      case v.config_row
      when :set  then I18n.ui("↑/↓ row · ↵ edit set · Del remove · %{run} run · ↹ pane", run: run)
      when :add  then I18n.ui("↵ add a payload set · ^L quick List · ↑/↓ row · %{run} run · ↹ pane", run: run)
      when :mode then I18n.ui("←/→ mode · ↵ open editor · ↑/↓ row · %{run} run · ↹ pane", run: run)
      else            I18n.ui("↵ open Advanced · ↑/↓ row · %{run} run · ↹ pane", run: run)
      end
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: !current_view.nil?)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @current_idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_shown?, find_lit: @host.subtab_find_focused?) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          if v = current_view
            v.render(screen, body, focused: body_focused)
          else
            TrafficEmptyState.render(screen, body, variant: :fuzzer)
          end
        end
      end
    end

    # --- input ---
    # Returns false when the key should fall through to the shell keymap (rebindable
    # verbs + Global breath). READ panes own structure; command letters defer.
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
      # ⌥/⌃ + ←/→/Home/End/⌫ are EDITOR motion (word step, buffer jump, word delete), not
      # command chords — see `RepeaterController#handle_body_key` for why routing them past
      # the defer cannot shadow a binding (no bindable chord is an arrow).
      return handle_pane_key(ev, v) if editing_motion?(ev) && v.focus == :template
      # An unconsumed ctrl/alt chord (^R run, ^X stop, ^A automark, …) defers to the
      # central keymap so it's rebindable.
      return false if (ev.ctrl? || ev.alt?) && !ev.key.escape?
      return true.tap { handle_escape(v) } if ev.key.escape?
      handle_pane_key(ev, v)
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    def supports_drag? : Bool
      !current_view.nil?
    end

    # Motion with the button held — the two TEXT panes only. The RESULTS list selects rows, and
    # a drag across rows would just be a fast repeated select. No save/focus side effects: the
    # press that began the drag already did those.
    #
    # The RESULT detail is that second text pane: it has a caret, a painted selection band, a
    # ⇧arrow grow and a `y`, and both arms here used to bail unless the TEMPLATE was focused —
    # so the pointer was the one route into it that did nothing.
    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless v = current_view
      body = body_rect_below_filter(rect)
      case v.focus
      when :template then v.template_drag_to_cursor(body, mx, my)
      when :detail   then v.detail_click_to_cursor(body, mx, my, selecting: true)
        # The TARGET row is the third text pane: a single-line READ field with a caret, an
        # anchor and a painted band (LineFieldRead). It had ⇧←/→ and no pointer route at all.
      when :target then v.target_drag_to_cursor(body, mx, my)
      end
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless v = current_view
      body = body_rect_below_filter(rect)
      case v.focus
      when :template
        return false if v.template_chrome_hit(body, mx, my) # a border badge is a button, not text
        v.template_select_word(body, mx, my)
      when :detail
        return false if v.detail_chip_at(body, mx, my) # a pane chip is a button, not text
        v.detail_select_word(body, mx, my)
      when :target
        v.target_select_word
      else false
      end
    end

    # --- bracketed paste, in bulk (see TabController#accepts_bulk_paste?) ---
    # The TEMPLATE editor in INSERT mode only; the content-level refusal (a `§`/`¦` in the
    # clipboard, whose per-character marker guard a bulk splice cannot express) is
    # `FuzzerView#template_paste`'s, and the Runner replays the paste when it fires.
    def accepts_bulk_paste? : Bool
      v = current_view
      return false unless v
      v.template_text_editing? && !v.chain_pane_active?
    end

    def paste_text(text : String) : Bool
      return false unless accepts_bulk_paste?
      current_view.try(&.template_paste(text)) || false
    end

    # Run the action a chord mapped to; false when it was not a chord (fall through).
    private def dispatch_chord(action : Symbol?, v : FuzzerView, c : Char?) : Bool
      case action
      when :palette then save_current; @host.open_palette
      when :close   then request_close
      when :undo
        # Only the TEMPLATE pane has a text buffer; anywhere else ^Z is not ours, so it falls
        # through to the keymap rather than being silently swallowed.
        return false unless v.focus == :template
        v.template_undo
      when :config then v.focus_config
      when :switch then switch_subtab(c)
      else              return false
      end
      true
    end

    # The ctrl-chord (or digit sub-tab switch) this key maps to, else nil. run/stop/automark
    # are NOT here — they're keymap-driven verbs (rebindable) and fall through. Neither are
    # ^K/^T any more: claiming them here meant the two most-used marker actions never reached
    # the registry, so they were absent from the space menu and could not be rebound, while
    # their four siblings were `fuzz.*` verbs. See `fuzz.mark-word` / `fuzz.insert-marker`.
    private def chord_action(ev : Termisu::Event::Key, c : Char?) : Symbol?
      return nil unless ev.ctrl?
      key = ev.key
      case
      when key.lower_p?         then :palette
      when key.lower_w?         then :close
      when key.lower_o?         then :config
      when key.lower_z?         then :undo
      when c && '1' <= c <= '9' then :switch
      end
    end

    private def handle_escape(v : FuzzerView) : Nil
      return v.discard_chain_pane if v.chain_pane_active? # esc in the CHAIN pane → cancel + back (^Q again saves)
      if v.focus == :template && v.template_insert?
        v.exit_template_insert!
      elsif v.focus == :target && v.editing_sni?
        v.exit_sni_field # leave the SNI field, back to the URL (value kept)
      elsif v.focus == :target && v.target_insert?
        v.exit_target_insert!
      elsif v.focus == :detail
        v.focus_pane(:results)
      else
        @host.request_focus(:subtabs)
      end
    end

    # ^Q: focus the CHAIN pane for the marker under the template cursor (again = save + back).
    def fuzz_focus_chain_pane : Nil
      return unless view = current_view
      if view.chain_pane_active?
        view.commit_chain_pane
        save_current
        @host.status("chain saved")
      else
        msg = view.focus_chain_pane
        @host.status(msg || "type the chain · Tab completes · ↵ saves · esc cancels")
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

    # ^S on the TARGET pane: edit the TLS SNI the whole sweep presents, leaving the dialed
    # host alone. Same chord, same focus rule and same status wording as the Repeater's — a
    # fuzz session seeded from History (⇧I) could otherwise never set one, so an https vhost
    # sweep always presented the dialed IP.
    def fuzz_toggle_sni : Nil
      if (view = current_view) && view.focus == :target
        view.toggle_sni_field
        @host.status(view.editing_sni? ? "SNI override: type a domain · ^S/↵/esc back to URL" : "editing target URL")
      else
        @host.status("SNI override (^S) applies to the TARGET pane — ↹ to it")
      end
    end

    # Flip the run between HTTP/1.1 and HTTP/2, overriding the seed flow's protocol so the
    # next run dials the other engine (Engine vs H2Engine).
    def fuzz_toggle_http2 : Nil
      return unless view = current_view
      h2 = view.toggle_http2
      @host.status(h2 ? "transport: HTTP/2 (h2)" : "transport: HTTP/1.1")
    end

    # Strip every §…§ marker (and its chain) from the template. Space-menu only —
    # `^U` now pretty-prints (matching Repeater); clearing lives in the space menu here too.
    def fuzz_clear_marks : Nil
      return unless view = current_view
      @host.status(view.clear_marks)
    end

    # The Runner calls these when an overlay applies (esc / ↵-on-last-field).
    def apply_fuzz_set(edit_index : Int32?, spec : SetSpec?) : Nil
      return unless v = current_view
      v.apply_set(edit_index, spec)
      Settings.record_recent_wordlist(spec.value) if spec && spec.kind == :file
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
        select_subtab(idx)
      end
    end

    private def printable(ev : Termisu::Event::Key) : Char?
      return nil if ev.ctrl? || ev.alt?
      ev.char || ev.key.to_char
    end

    private def handle_pane_key(ev : Termisu::Event::Key, v : FuzzerView) : Bool
      case v.focus
      when :target   then edit_target(ev, v)
      when :template then edit_template(ev, v)
      when :config   then edit_config(ev, v)
      when :results  then handle_results(ev, v)
      when :detail   then handle_detail(ev, v)
      else                true
      end
    end

    private def edit_target(ev : Termisu::Event::Key, v : FuzzerView) : Bool
      if v.editing_sni?
        edit_sni(ev, v)
        return true
      end
      return handle_target_read(ev, v) unless v.target_insert?
      key = ev.key
      case
      when key.enter?, key.down? then v.pane_advance(1)
      when key.up?               then @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      else                            edit_target_common(ev, v)
      end
      true
    end

    # The SNI override sub-field: same single-line editing (the view's target mutators
    # self-route to it while editing_sni?), but ↵/↑ return to the URL row rather than
    # advancing panes, and ↓ still drops into the TEMPLATE pane below. Mirrors
    # `RepeaterController#edit_repeater_sni`.
    private def edit_sni(ev : Termisu::Event::Key, v : FuzzerView) : Nil
      key = ev.key
      case
      when key.enter?, key.up? then v.exit_sni_field
      when key.down?           then v.pane_advance(1)
      else                          edit_target_common(ev, v)
      end
    end

    private def handle_target_read(ev : Termisu::Event::Key, v : FuzzerView) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
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
      when key.home?  then v.target_home(selecting)
      when key.end?   then v.target_end(selecting)
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # x select-line, y copy, Global breath → keymap
      end
      true
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

    private def edit_template(ev : Termisu::Event::Key, v : FuzzerView) : Bool
      if v.chain_pane_active?
        v.handle_chain_pane_key(ev)
        return true
      end
      return handle_template_read(ev, v) unless v.template_insert?
      key = ev.key
      # ⇧arrow extends the INSERT selection, a plain arrow collapses it — parity with the
      # Repeater's request editor, which routes the identical `selecting:` flag into the same
      # `TextArea#move`. ⇧↑ deliberately skips the `template_at_top?` pane-pop for the reason
      # the Repeater's does: leaving the pane mid-extend abandons a selection still being built.
      case
      when key.enter?       then v.template_newline
      when word_delete?(ev) then template_word_delete(v)
      when key.backspace?   then template_delete_key(v, backward: true)
      when word_step?(ev)   then v.template_word_move(key.left? ? -1 : 1, selecting: ev.shift?)
      when key.up?          then ev.shift? ? v.template_move(-1, 0, selecting: true) : template_up(v)
      when key.down?        then v.template_move(1, 0, selecting: ev.shift?)
      when key.left?        then v.template_move(0, -1, selecting: ev.shift?)
      when key.right?       then v.template_move(0, 1, selecting: ev.shift?)
      when key.page_up?     then v.template_page(-1, selecting: ev.shift?)
      when key.page_down?   then v.template_page(1, selecting: ev.shift?)
      when key.home?        then buffer_jump?(ev) ? v.template_buffer_start(ev.shift?) : v.template_home(ev.shift?)
      when key.end?         then buffer_jump?(ev) ? v.template_buffer_end(ev.shift?) : v.template_end(ev.shift?)
      when key.delete?      then template_delete_key(v, backward: false)
      else
        printable(ev).try do |ch|
          v.template_insert(ch)
          report_replaced(v.template_last_replaced) # a printable over a selection REPLACES it
        end
      end
      true
    end

    # ⌫ / Del in the TEMPLATE editor. A SELECTION outranks the marker-delimiter confirm, the
    # order `RepeaterController#edit_repeater_delete` argues at length: the guard inspects the
    # ONE character beside the caret, so a caret parked past a closing `§` raises "remove
    # marker §N" for a marker the selection need not touch — and the confirm SKIPS the delete,
    # leaving the selected text in place while an unrelated marker is stripped on accept.
    private def template_delete_key(v : FuzzerView, backward : Bool) : Nil
      unless v.template_insert_selection?
        span = backward ? v.marker_break_on_backspace : v.marker_break_on_delete
        return if guard_marker_delete(v, span)
      end
      backward ? v.template_backspace : v.template_delete
    end

    # ⌥⌫ / ⌃⌫ — delete the word behind the caret. Mirrors the Repeater's, marker guard and
    # all (a word delete can swallow a `§` delimiter just as a single ⌫ can).
    private def template_word_delete(v : FuzzerView) : Nil
      unless v.template_insert_selection?
        return if guard_marker_delete(v, v.marker_break_on_backspace)
      end
      v.template_delete_word
    end

    # A modified ←/→ is a WORD step; a modified Home/End jumps the BUFFER. ⌥ is the macOS
    # spelling and ⌃ the one everywhere else — accept both, as the Repeater does.
    private def word_step?(ev : Termisu::Event::Key) : Bool
      (ev.ctrl? || ev.alt?) && (ev.key.left? || ev.key.right?)
    end

    private def buffer_jump?(ev : Termisu::Event::Key) : Bool
      ev.ctrl? || ev.alt?
    end

    # A modified ⌫ — delete a WORD. See `RepeaterController#word_delete?` for why the `char`
    # half is load-bearing (⌥⌫ arrives as ESC + 0x7F, i.e. `Key::Unknown` + Alt).
    private def word_delete?(ev : Termisu::Event::Key) : Bool
      return false unless ev.ctrl? || ev.alt?
      return true if ev.key.backspace?
      c = ev.char
      !!c && (c == '\u{7F}' || c == '\b')
    end

    # Every modified key the TEMPLATE editor owns rather than the keymap — see `handle_body_key`.

    # A backspace/forward-delete of a marker delimiter (§/¦) would unbalance the marker and
    # expose its concealed ¦chain. Confirm first; on accept, strip the WHOLE marker down to
    # its raw value. Returns true when it intercepted (a confirm was raised), so the caller
    # skips the plain edit; false to let the edit through.
    private def guard_marker_delete(v : FuzzerView, span : {Int32, Int32}?) : Bool
      return false unless span
      n = v.marker_ordinal(span)
      @host.confirm(I18n.ui("REMOVE MARKER"),
        I18n.sys("Deleting this character breaks marker §%{n}.\nRemove the whole marker and keep only its value?", n: n),
        confirm_label: I18n.ui("remove marker"), danger: true) do
        v.strip_marker_span(span)
      end
      true
    end

    private def handle_template_read(ev : Termisu::Event::Key, v : FuzzerView) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      c = ev.char || key.to_char
      selecting = ev.shift?
      case
      when key.enter?     then v.enter_template_insert!
      when c == 'i'       then v.enter_template_insert!
      when key.up?        then template_up(v, selecting)
      when key.down?      then v.template_read_move(1, 0, selecting: selecting)
      when key.left?      then v.template_read_move(0, -1, selecting: selecting)
      when key.right?     then v.template_read_move(0, 1, selecting: selecting)
      when key.page_up?   then v.template_read_page(-1, selecting: selecting)
      when key.page_down? then v.template_read_page(1, selecting: selecting)
      when key.home?      then v.template_home(selecting)
      when key.end?       then v.template_end(selecting)
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # x/y + Global breath → keymap
      end
      true
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
    private def edit_config(ev : Termisu::Event::Key, v : FuzzerView) : Bool
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
      when (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
        return false # Shift-S save and other Fuzzer keymap verbs
      end
      true
    end

    # ↵ on a config row: drill into the Set / Advanced overlay, or cycle Mode. (Run is no
    # longer a config row — it's the TEMPLATE border's ^R:RUN badge / the rebindable ^R verb.)
    private def activate_config_row(v : FuzzerView) : Nil
      case v.config_row
      when :set      then @host.open_fuzz_set_editor(v.current_set_index)
      when :add      then @host.open_fuzz_set_editor(nil)
      when :mode     then v.cycle_mode_forward
      when :advanced then @host.open_fuzz_advanced_editor
      end
    end

    private def config_up(v : FuzzerView) : Nil
      v.config_at_top? ? v.pane_advance(-1) : v.form_move(-1)
    end

    private def handle_results(ev : Termisu::Event::Key, v : FuzzerView) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      case
      when key.enter?              then v.open_detail
      when key.up?, key.lower_k?   then v.results_at_top? ? v.pane_advance(-1) : v.results_move(-1)
      when key.down?, key.lower_j? then v.results_move(1)
      when key.lower_o?            then @host.status(v.cycle_sort)
      when key.lower_m?            then @host.status(v.toggle_matched_only)
      when key.lower_v?            then @host.status(v.toggle_dist)
      when (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
        return false # Global breath
      end
      true
    end

    # ⇧←/→ used to H-SCROLL this pane. It soft-wraps now, so there is nothing off to the side to
    # pan to, and the chord goes to the CHARACTER selection instead — which this pane had no way
    # to make at all, plain ←/→ being spoken for by the pane chain. ⇧↑/⇧↓ already selected.
    private def handle_detail(ev : Termisu::Event::Key, v : FuzzerView) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      selecting = ev.shift?
      # Home / End / PgUp / PgDn, ⇧ extending. Must come BEFORE the printable-char
      # fall-through below, and cannot be left to the Runner: this tab has no `body_scroll`
      # override, so `page_nav_delta` → `body_scroll` returns false and the trailing `true`
      # here simply swallowed all four keys.
      return true if v.detail_motion_key(ev)
      case
      when key.up?, key.lower_k?
        v.detail_cursor_at_top? ? v.focus_pane(:results) : v.detail_move(-1, 0, selecting: selecting)
      when key.down?, key.lower_j? then v.detail_move(1, 0, selecting: selecting)
      when key.left?               then selecting ? v.detail_move(0, -1, selecting: true) : v.detail_step_pane(-1)
      when key.right?              then selecting ? v.detail_move(0, 1, selecting: true) : v.detail_step_pane(1)
      when (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
        return false # x/y + Global breath → keymap
      end
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = body_rect_below_filter(rect)
      return true unless v = current_view
      # The RESULTS gauge on the card hairline — `results_row_at` requires the pane rect,
      # which excludes that column.
      if row = v.results_gauge_row(body, mx, my)
        save_current
        @host.focus_body
        v.focus_pane(:results)
        v.select_result_row(row)
        return true
      end
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
      # TEMPLATE border chrome (^R:RUN / PRETTY / NOR·INS) and TARGET NOR/INS.
      if chip = v.template_chrome_hit(body, mx, my)
        save_current
        @host.focus_body
        v.focus_pane(:template)
        case chip
        when :run    then fuzz_run
        when :pretty then fuzz_pretty_template
        when :mode
          if v.template_insert?
            v.exit_template_insert!
          else
            v.enter_template_insert!
          end
        end
        return true
      end
      if v.target_chrome_hit(body, mx, my) == :mode
        save_current
        @host.focus_body
        v.focus_pane(:target)
        if v.target_insert?
          v.exit_target_insert!
        else
          v.enter_target_insert!
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
        when :detail
          # The chip strip on the card's top border first (it selects a section, it does not
          # place a caret) — then the text, which had no click arm here at all.
          if chip = v.detail_chip_at(body, mx, my)
            v.show_detail_pane(chip)
          else
            v.detail_click_to_cursor(body, mx, my)
          end
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
      @host.status("copied #{written}b to clipboard#{Clipboard.note(written, text)}")
    end

    # The focused pane's selection (or current line) text without copying — for the
    # "Send selection to" flow.
    def fuzzer_selection_text : String
      (v = current_view) ? v.pane_copy_text : ""
    end

    def fuzzer_copy_all : Nil
      v = current_view
      return unless v
      text = v.pane_copy_all_text
      return if text.empty?
      written = Clipboard.copy(text)
      @host.status("copied all (#{written}b)#{Clipboard.note(written, text)}")
    end

    def fuzzer_read_mode? : Bool
      v = current_view
      return false unless v
      case v.focus
      when :template then !v.pane_insert?(:template)
      when :target   then !v.pane_insert?(:target)
      when :detail   then true
      when :results  then true
      else                false
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
      v.running? || v.saving_results? || v.loading_results? || v.dirty? || v.pane_insert?(:template) || v.pane_insert?(:target) ||
        (@host.active_tab == :fuzzer && @host.focus == :body)
    end

    # --- editor $ENV autocomplete + tab-as-text (template pane in insert mode) ---
    # The CHAIN sub-pane owns Tab while it's focused (like a text editor), so ↹ accepts its
    # converter suggestion (parity with ↵) instead of the focus ring stealing Tab to switch
    # panes. Its own converter popup handles ↑/↓/↵/Esc via handle_chain_pane_key already.
    def editor_completing? : Bool
      v = current_view
      return false unless v
      return false if v.chain_pane_active? # CHAIN popup is routed via editor_captures_tab?/handle_editor_tab
      v.template_env_completing?
    end

    def handle_editor_complete_key(ev : Termisu::Event::Key) : Bool
      current_view.try(&.handle_template_env_complete_key(ev)) || false
    end

    def editor_captures_tab? : Bool
      v = current_view
      return false unless v
      v.chain_pane_active? || v.template_text_editing?
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      v = current_view
      return false unless v
      if v.chain_pane_active?
        v.handle_chain_pane_key(ev) # popup open → accept the suggestion (like ↵); closed → commit + leave
        return true
      end
      return false unless v.template_text_editing?
      v.template_tab_insert
      true
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

    # --- sub-tab nav (filter-aware: ←/→ skip hidden chips; ^1-9 escapes the filter) ---
    private def select_subtab(idx : Int32, *, save : Bool = true) : Nil
      return unless 0 <= idx < @fuzzers.size
      save_current if save
      @current_idx = idx
      auto_load_current_saved_run
    end

    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@current_idx, dir)
        select_subtab(t)
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @fuzzers.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      return if idx == @current_idx
      select_subtab(idx)
    end

    # --- rename (the shell's orthogonal rename prompt drives this by VIEW identity) ---
    # Apply the typed name to the captured tab + persist it on its own (set_fuzz_session_name,
    # separate from save_current so the rename lands even when the session is otherwise clean).
    # Re-find by VIEW identity so a closed/reordered tab is a no-op, never a neighbour. Blank
    # clears the custom label (the chip reverts to the template-derived summary).
    def apply_rename(view : FuzzerView, name : String) : Nil
      return unless tab = @fuzzers.find(&.view.same?(view))
      clean = name.strip
      view.name = clean.empty? ? nil : clean
      if id = tab.db_id
        # The store answers whether the UPDATE committed. The chip above already reads the new
        # name, so a rolled-back batch (another instance holding the project's writer) is
        # otherwise a SILENT no-op: nothing on screen changes back until the session reloads,
        # and the operator concludes the rename took. Mirrors close_tab's orphaned refusal
        # below and RepeaterController#apply_rename.
        unless @host.session.store.set_fuzz_session_name(id, view.name)
          @host.status("rename NOT saved (project busy) — the chip reads the new name until the session reloads")
        end
      end
    end

    # --- async (run loop) ---
    def drain_events : Bool
      applied = false
      n = 0
      while n < DRAIN_CAP
        # Save/load completion is rare and operator-visible; take it before another burst of
        # result rows so a fast run cannot starve a finished database operation indefinitely.
        if io_event = nonblocking_io_event
          n += 1
          apply_io_event(io_event)
          applied = true
        elsif pair = nonblocking_event
          n += 1
          v, ev = pair
          next unless @fuzzers.any?(&.view.same?(v)) # session closed mid-run → drop
          apply_event(v, ev)
          applied = true
        else
          break
        end
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

    private def nonblocking_io_event : IoEvent?
      select
      when event = @fuzz_io_events.receive
        event
      else
        nil
      end
    end

    private def apply_io_event(event : IoEvent) : Nil
      case event
      when SaveDone  then apply_save_done(event)
      when LoadDone  then apply_load_done(event)
      when SpoolLost then apply_spool_lost(event)
      end
    end

    # The archive died mid-sweep. The run itself is untouched — this only says ⇧S is gone,
    # while it can still be acted on rather than only mourned.
    private def apply_spool_lost(event : SpoolLost) : Nil
      return unless @fuzzers.any?(&.view.same?(event.view))
      return unless event.view.run_generation == event.generation
      @host.status("complete fuzz archive unavailable — #{event.reason}")
    end

    private def apply_save_done(event : SaveDone) : Nil
      ok = event.error.nil?
      @host.jobs.finish(event.job_id, ok ? :done : :error,
        ok ? "saved run ##{event.run_id}" : (event.error || "save failed"))
      return unless @fuzzers.any?(&.view.same?(event.view))
      return unless event.view.run_generation == event.generation

      failed_id = !ok && event.run_id > 0 ? event.run_id : nil
      event.view.finish_results_save(ok ? event.run_id : nil, failed_id)
      if ok
        if spool_run = @spool_runs.delete(event.view)
          @spool.delete(spool_run)
        end
        @host.status("saved #{event.written} fuzz results as run ##{event.run_id}")
      else
        @host.status("fuzz results NOT saved: #{event.error || "project write failed"}")
      end
    end

    private def apply_load_done(event : LoadDone) : Nil
      ok = event.error.nil? && !event.run.nil?
      @host.jobs.finish(event.job_id, ok ? :done : :error,
        ok ? "#{event.window.rows.size} results" : (event.error || "load failed"))
      # A failed automatic read is retryable on the next navigation. The id stays claimed
      # while work is in flight, so repeated navigation cannot launch duplicate readers.
      @auto_load_considered.delete(event.session_id) if event.automatic && !ok
      return unless @fuzzers.any?(&.view.same?(event.view))
      return unless event.view.run_generation == event.generation
      if run = event.run
        if old = @spool_runs.delete(event.view)
          @spool.delete(old)
        end
        event.view.load_saved_run(run, event.window)
        # Off the VIEW, not the handover window: this sentence claims what the pane is
        # showing, so it has to be counted where the pane reads.
        shown_rows = event.view.retained_result_count
        shown = shown_rows.to_i64 < run.sent ? " · showing #{shown_rows}" : ""
        @host.status("loaded fuzz run ##{run.id} · #{run.status} · #{run.mode} · " \
                     "#{run.sent} results#{shown} · #{run.target}")
      else
        event.view.fail_result_load
        @host.status(event.error || "could not load saved fuzz run")
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
      when Fuzz::ResultEvent
        v.append_result(ev.result)
        probe_scan_fuzz_result(ev.result, v)
      when Fuzz::DoneEvent
        # The terminal progress is the only one carrying the run's FINAL wire count, and
        # ProgressEvent is droppable (latest wins) — so without this the header could keep
        # rendering a mid-run snapshot forever. See `Fuzz::Progress#requests`.
        v.apply_progress(ev.progress)
        # A setup ErrorEvent is followed by Done. Do not overwrite its durable status with
        # `done`; finish_job already applies the same errored-job guard to notifications.
        terminal = @host.jobs.errored?(v.job_id) ? "error" : v.terminal_status(ev.progress, ev.stopped)
        spool_run = @spool_runs[v]?
        archive_ready = !!spool_run && !spool_run.failed? && spool_run.finished?
        v.finish_run(terminal, archive_ready: archive_ready)
        finish_job(v, ev, terminal)
      when Fuzz::ErrorEvent
        # Generation/worker errors can be followed by many queued Result events and then Done.
        # Keep the view running (and therefore unsaveable) until that terminal event drains.
        # The failure persists in the jobs center (survives the next keystroke) and shows
        # in the bottom bar. It is deliberately NOT pushed to the notification center: a
        # job error is an operational failure, not a result the human wants surfaced there
        # (and it already had two other surfaces) — see #127. It IS logged to the #124 event
        # feed (the AI firehose logs freely; only the human center suppresses it).
        @host.jobs.finish(v.job_id, :error, ev.message)
        log_event(v, :error, "Fuzzer: #{ev.message} on #{v.summary}")
        @host.status("fuzzer error: #{ev.message}", :error)
      end
    end

    # Passive-scan a fuzz result into Probe (mode-gated by the analyzer) — mirrors
    # RepeaterController#probe_scan_repeater so URLs only ever visited through the
    # Fuzzer still surface header/tech findings. Only fires when this result's
    # head/body/request were retained (the run's keep_bodies policy — :all, or
    # :matched plus this one matched); a :none run has nothing to scan, same limit
    # the Repeater path doesn't face.
    private def probe_scan_fuzz_result(result : Fuzz::Result, v : FuzzerView) : Nil
      return unless result.matched?
      return unless head = result.head
      return if head.empty?
      rec = Store::RepeaterRecord.new(
        0_i64, v.result_target_origin, result.request || Bytes.empty, v.result_http2?, false,
        nil, 0, head, result.body, nil, result.duration_us, nil, nil)
      return unless detail = Probe.detail_from_repeater(rec)
      @host.session.probe.scan_detail(detail)
    rescue
      # Probe must never break the Fuzzer UX
    end

    private def finish_job(v : FuzzerView, ev : Fuzz::DoneEvent, terminal : String) : Nil
      return if @host.jobs.errored?(v.job_id) # an ErrorEvent already finalized this run — the
      #                                         engine's trailing DoneEvent must not log/notify success
      n = v.matched_count
      summary = terminal == "budget_exhausted" ? "#{n} hit · budget exhausted" : "#{n} hit"
      @host.jobs.finish(v.job_id, :done, summary)
      level = n > 0 ? :success : :info
      # `requests` only when it DIFFERS from the payload count — retries and redirect hops
      # are the two things that make them diverge, and a run with neither should not grow a
      # second number saying the same thing twice. This is what the CLI's done line does,
      # and the number a tester inside an agreed request budget actually needs: a 3-payload
      # sweep down a redirect chain put 18 requests on the target and said "3 sent".
      p = ev.progress
      wire = p.requests > p.sent ? " / #{p.requests} requests" : ""
      ending =
        case terminal
        when "stopped"          then " (stopped)"
        when "budget_exhausted" then " (request budget exhausted — partial run)"
        else                         ""
        end
      msg = "Fuzzer: #{n} hit#{n == 1 ? "" : "s"} / #{v.result_count} sent#{wire} on #{v.summary}#{ending}"
      log_event(v, level, msg)
      @host.notifications.push(level, msg, goto_for(v), source: "fuzzer")
      @host.status(msg, :done) if Settings.notify_toast?
    end

    # #124: append every fuzz completion/error to the store event feed UNCONDITIONALLY
    # (the AI firehose — see the ErrorEvent note above re: #127).
    private def log_event(v : FuzzerView, level : Symbol, msg : String) : Nil
      g = goto_for(v)
      @host.session.store.insert_event("fuzzer", "job_done", level.to_s, msg,
        goto_tab: g.try(&.tab.to_s), goto_session_id: g.try(&.session_id))
    end

    private def goto_for(v : FuzzerView) : Jobs::Goto?
      tab = @fuzzers.find(&.view.same?(v))
      (tab && (id = tab.db_id)) ? Jobs::Goto.new(:fuzzer, id) : nil
    end

    private def begin_worker(view : FuzzerView) : Nil
      @workers[view] += 1
    end

    private def end_worker(view : FuzzerView) : Nil
      remaining = @workers[view] - 1
      if remaining > 0
        @workers[view] = remaining
      else
        @workers.delete(view)
        # A close that gave up waiting left this view cancelled on purpose, so the worker
        # now leaving would keep reading its own cancellation. It has left; drop it.
        @cancelled_views.delete(view) if @release_pending.delete(view)
      end
    end

    # Keep draining while a producer may be blocked on a terminal/result send, so the Store
    # and temp spool are closed only after every captured fiber has left its ensure block —
    # but only until QUIESCE_DEADLINE. False means a worker outlived it and the caller must
    # NOT treat this view as reclaimed.
    private def quiesce_view(view : FuzzerView) : Bool
      deadline = Time.instant + QUIESCE_DEADLINE
      while @workers[view] > 0
        return false if Time.instant >= deadline
        drain_events
        sleep 1.millisecond
      end
      while drain_events
      end
      true
    end

    # One ownership exit for explicit close and peer reconciliation. Cancellation remains in
    # the set only while a worker can observe it; retaining a closed view here would retain its
    # entire 64 MiB result window for the rest of the project lifetime.
    private def release_view_resources(view : FuzzerView, cancel : Bool) : Nil
      drained = true
      if cancel
        @cancelled_views.add(view)
        view.request_stop
        drained = quiesce_view(view)
      end
      if spool_run = @spool_runs.delete(view)
        @spool.delete(spool_run)
      end
    ensure
      # Only when nothing of this view is still running. A worker past the deadline still
      # decrements @workers and still reads @cancelled_views on its way out, so clearing
      # either here would put a live fiber back on the uncancelled path; `end_worker`
      # finishes the job instead.
      if drained
        @workers.delete(view)
        @cancelled_views.delete(view)
      else
        @release_pending.add(view)
        @host.status("fuzz session closed — a worker is still winding down in the background")
      end
    end

    # Focus a fuzz sub-tab by persisted id (notification "jump to result").
    def reveal_session(id : Int64) : Nil
      if idx = @fuzzers.index { |t| t.db_id == id }
        select_subtab(idx, save: false)
        @host.focus_body
      end
    end

    # --- run lifecycle ---
    def fuzz_run : Nil
      return unless v = current_view
      return @host.status("project is closing") if @closing
      if v.saving_results? || v.loading_results?
        @host.status(v.loading_results? ? "loading results — wait" : "saving results — wait for the database commit")
        return
      end
      if v.running?
        @host.status("fuzz running — ^X to stop", :busy)
        return
      end
      # Flush any trailing Done/Error from a just-finished run before we rebind
      # job_id below. The engine sends its terminal event onto @fuzz_events BEFORE
      # the fiber's `ensure` flips running? false, so a ^R landing in that window
      # would otherwise apply the stale event to the NEW run's job (premature/wrong
      # "done", orphaned bottom-bar spinner). Draining now settles the old job first.
      drain_events
      engine, err = v.build_engine(!@host.session.config.insecure_upstream?,
        @host.session.scope, @host.session.host_overrides)
      unless engine
        @host.status(err || "can't run")
        return
      end
      total = begin
        engine.total
      rescue ex
        @host.status("fuzz: #{ex.message}", :error)
        return
      end
      if total.nil? || total > CONFIRM_THRESHOLD
        e = engine
        @host.confirm(I18n.ui("RUN FUZZ"), I18n.sys("Send %{count} requests to %{origin}?\nEvery result is privately spooled; the pane keeps at most 5,000 rows / 64 MiB.", count: total ? total.to_s : I18n.sys("an unknown number of"), origin: v.target_origin),
          confirm_label: I18n.ui("run"), danger: false) { start_run(v, e, total) }
      else
        start_run(v, engine, total)
      end
    end

    private def start_run(v : FuzzerView, engine : Fuzz::Engine, total : Int64?) : Nil
      # A peer may have closed this session (reconcile evicted the tab) while its RUN FUZZ
      # confirm dialog was pending — don't launch an unstoppable engine fiber + orphaned job
      # into a detached view whose events drain_events would then drop forever.
      unless tab = @fuzzers.find(&.view.same?(v))
        @host.status("fuzz session no longer open — run cancelled")
        return
      end
      save_current
      if old = @spool_runs.delete(v)
        @spool.delete(old)
      end
      @cancelled_views.delete(v)
      # Hand the engine over BEFORE anything can be sent, so ^X reaches it even during
      # calibration — which runs outside `engine.run` and so outside the in-loop stop check.
      v.engine = engine
      v.begin_run(total)
      spool_run = begin
        @spool.start(v.saved_run_meta(tab.db_id))
      rescue ex
        @host.status("temporary fuzz archive unavailable: #{ex.message} — run continues with a bounded view")
        nil
      end
      @spool_runs[v] = spool_run if spool_run
      v.job_id = @host.jobs.start(:fuzz, v.summary, goto: goto_for(v))
      events = @fuzz_events
      io_events = @fuzz_io_events
      generation = v.run_generation
      calibrate = v.config.auto_calibrate?
      done_sent = false
      error_sent = false
      spool_lost = false
      begin_worker(v)
      spawn(name: "gori-fuzz") do
        engine.calibrate_baseline if calibrate
        engine.run do |ev|
          case ev
          when Fuzz::ProgressEvent
            select
            when events.send({v, ev})
            else
            end
          when Fuzz::ResultEvent
            # Temp persistence is non-blocking. A saturated/full spool becomes unavailable,
            # but the authorized sweep and bounded display continue (P6). Say so at the FIRST
            # rejection: from here the run can no longer be saved whole, and the operator who
            # only learns that from "complete archive unavailable" at the end has already
            # spent the sweep. Reported through the IO channel because the status line, like
            # every view mutation, belongs to the Runner fiber.
            if (run = spool_run) && !spool_lost && !run.append(ev.result)
              spool_lost = true
              io_events.send(SpoolLost.new(v, generation,
                run.error || "the temporary archive stopped accepting results"))
            end
            events.send({v, ev})
          when Fuzz::ErrorEvent
            error_sent = true
            events.send({v, ev})
          when Fuzz::DoneEvent
            terminal = v.terminal_status(ev.progress, ev.stopped, error_sent)
            spool_run.try(&.finish(ev.progress.sent, ev.progress.matched,
              ev.progress.errors, terminal))
            events.send({v, ev})
            done_sent = true
          end
          engine.stop if v.stop_requested?
        end
      rescue ex
        ::Log.error(exception: ex) { "fuzz run fiber died" }
        unless done_sent
          engine.stop
          unless error_sent
            events.send({v, Fuzz::ErrorEvent.new("#{ex.class}: #{ex.message}")})
          end
          spool_run.try(&.abort(reason: "fuzz run failed before spool completion"))
          events.send({v, Fuzz::DoneEvent.new(Fuzz::Progress.new(0_i64, total, 0_i64, 1_i64), true)})
        end
      ensure
        end_worker(v)
      end
      archive = spool_run ? "" : " · complete archive unavailable"
      @host.status("fuzzing #{v.target_origin} — ^X stop#{archive}#{framing_note(v)}", :busy)
    end

    # How this run frames its body, for the run-start line — the way `gori run fuzz` prints it
    # on stderr before the first send: once, up front, naming the switch that decides it.
    #
    # At most ONE of the two, and they are mutually exclusive by construction: a rewrite needs a
    # declared Content-Length and an unframed body needs none. The warning is checked first
    # because it is the one that costs the whole run — the origin reads no body at all, so every
    # row is a status for a request the payload never reached. The rewrite note is the quieter
    # half but bites the same way: they typed `Content-Length: 5`, the pane still says 5, and
    # the wire carried 37.
    private def framing_note(v : FuzzerView) : String
      if v.unframed_body?
        " · warning: #{FuzzerView::UNFRAMED_BODY_NOTE}"
      elsif v.rewrites_content_length?
        " · note: #{FuzzerView::CL_REWRITE_NOTE}"
      else
        ""
      end
    end

    def fuzz_stop : Nil
      return unless (v = current_view) && v.running?
      v.request_stop
      @host.status("stopping…", :busy)
    end

    def results_saveable? : Bool
      current_view.try(&.results_saveable?) == true
    end

    # Shift-S copies the complete private spool into the project. The bounded pane is only a
    # display window and is never the persistence source.
    def fuzz_save_results : Nil
      return unless tab = current_tab_obj
      view = tab.view
      if id = view.saved_run_id
        @host.status("fuzz results already saved as run ##{id}")
        return
      end
      return @host.status("finish a fuzz run before saving its results") unless view.results_saveable?
      session_id = tab.db_id
      return @host.status("fuzz session is not persisted — save unavailable") unless session_id

      spool_run = @spool_runs[view]?
      return @host.status("complete fuzz archive unavailable for this run") unless spool_run && !spool_run.failed?
      count = spool_run.written
      bytes = spool_run.accepted_bytes
      @host.confirm(I18n.ui("SAVE FUZZ RESULTS"),
        I18n.sys_n(count, "Permanently save %{n} result (%{size}) in this project?", "Permanently save %{n} results (%{size}) in this project?", n: count, size: Fmt.size(bytes)),
        confirm_label: I18n.ui("save"), danger: false) do
        start_results_save(view, session_id)
      end
    end

    private def start_results_save(view : FuzzerView, session_id : Int64) : Nil
      return unless view.results_saveable?
      spool_run = @spool_runs[view]? || return
      meta = view.saved_run_meta(session_id)
      sent, matched, errors, status = view.saved_run_counters
      generation = view.run_generation
      failed_run_id = view.failed_save_run_id
      view.begin_results_save
      job = @host.jobs.start(:fuzz_save, "save #{spool_run.written} fuzz results", goto: goto_for(view))
      store = @host.session.store
      completions = @fuzz_io_events
      begin_worker(view)
      spawn(name: "gori-fuzz-save") do
        persisted = nil.as(Fuzz::Persistence?)
        begin
          # This ID belongs to a local save fiber that has already stopped. A terminal-update
          # failure can leave it `saving`, so its explicit stale allowance is safe and is never
          # applied to an arbitrary history row.
          if failed = failed_run_id
            deleted = store.delete_fuzz_run_result(failed, allow_active: true)
            unless deleted.status.in?(Store::FuzzRunDeleteStatus::Deleted,
                     Store::FuzzRunDeleteStatus::NotFound)
              completions.send(SaveDone.new(view, generation, job, failed, 0_i64,
                "could not remove failed run ##{failed} before retry (project busy)"))
              next
            end
          end

          persisted = Fuzz::Persistence.new(store, meta, initial_status: "saving")
          cancelled = false
          begin
            spool_run.each_result(batch_size: 32) do |record|
              raise ResultIoCancelled.new if @closing || @cancelled_views.includes?(view)
              raise ResultCopyStopped.new unless persisted.append(record)
            end
          rescue ResultIoCancelled
            cancelled = true
          rescue ResultCopyStopped
            # Persistence already carries the concrete database/queue error.
          end
          if cancelled
            persisted.abort(sent, matched, errors, reason: "project closed during fuzz save")
            completions.send(SaveDone.new(view, generation, job, persisted.run_id,
              persisted.written, "save cancelled while project closed"))
          else
            ok = persisted.finish(sent, matched, errors, status)
            ok = false unless persisted.written == spool_run.written
            completions.send(SaveDone.new(view, generation, job, persisted.run_id,
              persisted.written, ok ? nil : (persisted.error || "project write failed")))
          end
        rescue ex
          persisted.try(&.abort(sent, matched, errors, reason: "fuzz save crashed"))
          completions.send(SaveDone.new(view, generation, job,
            persisted.try(&.run_id) || 0_i64, persisted.try(&.written) || 0_i64,
            ex.message || "save failed"))
        ensure
          end_worker(view)
        end
      end
    end

    def saved_runs : Array(Store::FuzzRunRecord)
      tab = current_tab_obj
      id = tab.try(&.db_id)
      id ? @host.session.store.fuzz_runs(id) : [] of Store::FuzzRunRecord
    end

    # One automatic restore decision per persisted session for this project-open lifetime.
    # The initial tab calls this from initialize; other tabs call it only when selected.
    private def auto_load_current_saved_run : Nil
      return unless tab = current_tab_obj
      session_id = tab.db_id || return
      return if @auto_load_considered.includes?(session_id)
      @auto_load_considered.add(session_id)
      view = tab.view
      return if view.running? || view.saving_results? || view.loading_results? || view.result_count > 0
      begin
        return unless run = @host.session.store.latest_saved_fuzz_run(session_id)
        start_saved_run_load(tab, run, automatic: true)
      rescue ex
        # A transient read failure is not a decision that this session has no history.
        @auto_load_considered.delete(session_id)
        @host.status("could not restore latest fuzz run: #{ex.message}")
      end
    end

    def load_saved_run(id : Int64, replace_unsaved : Bool = false) : Nil
      return unless tab = current_tab_obj
      session_id = tab.db_id || return
      view = tab.view
      return @host.status("finish the current fuzz run before loading history") if view.running?
      return @host.status("result I/O in progress — wait before loading history") if view.saving_results? || view.loading_results?
      if view.results_saveable? && !replace_unsaved
        @host.confirm(I18n.ui("REPLACE UNSAVED RESULTS"),
          I18n.sys("Load saved run #%{id}?\nThe current %{rows}-row run has not been saved and will be replaced.", id: id, rows: view.result_count),
          confirm_label: I18n.ui("load"), danger: true) { load_saved_run(id, true) }
        return
      end
      run = @host.session.store.get_fuzz_run(id)
      return @host.status("saved fuzz run ##{id} is gone") unless run && run.session_id == session_id
      return @host.status("legacy fuzz run ##{id} has incomplete transport context — inspect it with `gori run fuzz show`") if run.legacy_snapshot?
      return @host.status("saved fuzz run ##{id} is still #{run.status}") if run.status.in?("running", "saving")
      @auto_load_considered.add(session_id)
      start_saved_run_load(tab, run)
    end

    private def start_saved_run_load(tab : FuzzerTab, run : Store::FuzzRunRecord,
                                     automatic : Bool = false) : Nil
      session_id = tab.db_id || return
      id = run.id
      view = tab.view
      generation = view.reserve_result_load
      job = @host.jobs.start(:fuzz_load, "load saved fuzz run ##{id}", goto: goto_for(view))
      store = @host.session.store
      completions = @fuzz_io_events
      begin_worker(view)
      spawn(name: "gori-fuzz-load") do
        total = store.fuzz_result_count(id)
        offset = {total - FuzzerResultWindow::ROW_CAP, 0_i64}.max
        window = FuzzerResultWindow.new
        seen = 0
        cancelled = false
        begin
          store.each_fuzz_result_page(id, FuzzerResultWindow::ROW_CAP, offset) do |record|
            raise ResultIoCancelled.new if @closing || @cancelled_views.includes?(view)
            window.append(Fuzz::Persistence.result(record))
            seen += 1
            Fiber.yield if seen % 64 == 0
          end
        rescue ResultIoCancelled
          cancelled = true
        end
        fresh = store.get_fuzz_run(id)
        if !cancelled && fresh && fresh.session_id == session_id
          completions.send(LoadDone.new(view, generation, job, session_id, automatic,
            fresh, window, nil))
        else
          message = cancelled ? "saved-run load cancelled" : "saved fuzz run ##{id} was deleted while it loaded"
          completions.send(LoadDone.new(view, generation, job, session_id, automatic,
            nil, FuzzerResultWindow.new, message))
        end
      rescue ex
        completions.send(LoadDone.new(view, generation, job, session_id, automatic, nil,
          FuzzerResultWindow.new, "could not load fuzz run ##{id}: #{ex.message}"))
      ensure
        end_worker(view)
      end
    end

    def delete_saved_run(id : Int64) : Nil
      run = @host.session.store.get_fuzz_run(id)
      return @host.status("saved fuzz run ##{id} is gone") unless run
      count = @host.session.store.fuzz_result_count(id)
      @host.confirm(I18n.ui("DELETE FUZZ RUN"), I18n.sys("Delete saved run #%{id} and %{count} results?", id: id, count: count),
        confirm_label: I18n.ui("delete"), danger: true) do
        deleted = @host.session.store.delete_fuzz_run_result(id)
        if deleted.deleted?
          current_view.try(&.forget_saved_run(id))
          @host.status("deleted saved fuzz run ##{id} and #{deleted.deleted_results} results")
        else
          @host.status("saved run NOT deleted (#{deleted.status.to_s.underscore})")
        end
      end
    end

    # --- new / close / cross-tab seeds ---
    def fuzz_new : Nil
      view = FuzzerView.new
      view.load_blank
      open_session(view, nil)
      # `i/↵`, not "type": `load_blank` opens the TARGET field in READ, so bare typing edits
      # nothing — and a digit in a URL fires the global `nav.posN` tab jump instead, which
      # walks the operator off the session they just made. `repeater_new` says "edit" for the
      # same reason; this line named the mode it does not open in.
      @host.status("new fuzz session — i/↵ edits the target URL · ^A mark params · ^O config · ^R run")
    end

    # Content-only clone of the active fuzz session (template + config; no results/links).
    def fuzz_duplicate : Nil
      return @host.status("no fuzz session open to duplicate") unless src = current_view
      view = FuzzerView.new
      view.duplicate_from(src)
      open_session(view, nil)
      @host.status("duplicated fuzz session (#{@fuzzers.size} open)")
    end

    # Seed handed to RepeaterController for "Send to Repeater" (a fuzz result row → the
    # request that produced it). Same shape as MinerController::RepeaterSeed.
    record RepeaterSeed,
      target : String,
      request_text : String,
      http2 : Bool,
      sni : String?,
      tls_preset : String?,
      label : String,      # sub-tab chip + toast ("#index payload")
      note : String? = nil # provenance when request_text is NOT the retained wire bytes

    # True when the focused session has a result row under the cursor (gates space →
    # Send to Repeater): no run yet, or a filter that hides every row, means no request
    # to hand over.
    def result_selected? : Bool
      return false unless view = current_view
      return false unless result = view.selected_result
      !view.result_display_truncated?(result)
    end

    # The selected result as a Repeater-ready request; nil when nothing is selected.
    def selected_repeater_seed : RepeaterSeed?
      return nil unless v = current_view
      return nil unless r = v.selected_result
      return nil if v.result_display_truncated?(r)
      FuzzerController.repeater_seed_for(v, r)
    end

    # The selected result as ONE side of a Comparer diff; nil when nothing is selected.
    #
    # A fuzz row is exactly the comparison the Comparer is for — "this payload got a 500,
    # the baseline got a 200, what is different about the body" — and it had no way there:
    # a fuzz send is not a captured flow. `head`/`body` are nil on a run without `keep
    # bodies`, so the response half comes up empty there while the request half (the same
    # reconstruction `fuzz.repeater` seeds with) and the measured meta still work.
    def comparer_slot : ComparerSlot?
      return nil unless v = current_view
      return nil unless r = v.selected_result
      return nil if v.result_display_truncated?(r)
      FuzzerController.comparer_slot_for(v, r)
    end

    # The slot for one {session, result} pair. A class method for the same reason
    # `repeater_seed_for` is one: `comparer_slot` above only picks the pair, so a spec can
    # drive the real byte handling without standing up a Host.
    def self.comparer_slot_for(v : FuzzerView, r : Fuzz::Result) : ComparerSlot
      payload = r.payloads.join(", ")
      payload = "#{payload[0, 23]}…" if payload.size > 24
      req = v.result_request(r).bytes
      ComparerSlot.from_exchange(
        # The source chip says "rebuilt" when the row kept no request bytes and this is a
        # reconstruction — the same caveat `fuzz.repeater` carries in its label, and it has
        # to survive into the Comparer header where the two sides are read against each other.
        v.result_request_note(r) ? "fuzz·rebuilt" : "fuzz",
        ComparerSlot.method_of(req), v.result_target_origin,
        req, nil, r.head, r.body,
        status: r.status, duration_us: r.duration_us, error: r.error, size: r.length,
        label: "##{r.index} #{payload}".rstrip)
    end

    # The seed for one {session, result} pair. A class method because it reads no shell
    # state: `selected_repeater_seed` above only picks the pair, so a spec can drive the
    # REAL byte handling below without standing up a Host.
    def self.repeater_seed_for(v : FuzzerView, r : Fuzz::Result) : RepeaterSeed
      req = v.result_request(r)
      # `String.new`, NOT `.scrub`, and NO CRLF→LF collapse. Both used to be justified by
      # "Repeater editors store LF text", which the @eols work made false — `TextArea#set_text`
      # now round-trips each line's own terminator and the send path reads `wire_text`, so
      # collapsing here is exactly the loss F1 fixed one tab over. `.scrub` was worse than
      # cosmetic: a payload byte that is not valid UTF-8 (a hex/binary set, a decoder chain
      # emitting raw bytes) became U+FFFD in bytes this record calls the request that was sent.
      # `String.new(Bytes)` copies them through verbatim.
      text = String.new(req.bytes)
      payload = r.payloads.join(", ")
      payload = "#{payload[0, 23]}…" if payload.size > 24
      label = "##{r.index} #{payload}".rstrip
      note = v.result_request_note(r)
      # The chip/toast label carries the caveat too, not just `note`: the label is the only
      # field that reaches the operator through every consumer of this seed, and a tab holding
      # a reconstruction should keep saying so after the toast has gone.
      label = "#{label} · reconstructed" if note
      RepeaterSeed.new(v.result_target_origin, text, v.result_http2?, v.result_sni,
        v.result_tls_preset, label, note)
    end

    # ⇧I from History (or Issues evidence): open a captured flow as a fuzz session.
    def fuzz_flow(id : Int64) : Nil
      return unless detail = @host.session.store.get_flow(id)
      view = FuzzerView.new
      view.load(detail)
      open_session(view, id)
      @host.status("fuzzer: #{view.summary} — ^A auto-mark · ^K word · ^O config · ^R run")
    end

    # Turn a Repeater request (or any reconstructed request) into a fuzz session.
    def fuzz_from_request(target : String, request_text : String, http2 : Bool, sni : String?) : Nil
      view = FuzzerView.new
      view.load_request(target, request_text, http2, sni || "")
      open_session(view, nil)
      @host.status("fuzzer ← request — ^A auto-mark · ^O config · ^R run")
    end

    private def open_session(view : FuzzerView, flow_id : Int64?) : Nil
      tab = FuzzerTab.new(view, flow_id, persist_new(view, flow_id))
      @fuzzers << tab
      # A session created in this controller lifetime has no prior saved run to restore.
      if id = tab.db_id
        @auto_load_considered.add(id)
      end
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
      if tab.view.saving_results? || tab.view.loading_results?
        @host.status("result I/O in progress — wait before closing this fuzz session")
        return
      end
      if (session_id = tab.db_id) &&
         (active = @host.session.store.fuzz_runs(session_id).find(&.status.in?("running", "saving")))
        @host.status("saved run ##{active.id} is still #{active.status} in another writer — " \
                     "wait before closing (or remove a crashed row with CLI --force-stale)")
        return
      end
      @host.confirm(I18n.ui("CLOSE FUZZER"), I18n.sys("Close fuzz session “%{name}”?\nIts template/config, private temporary spool, and every saved run are deleted.", name: tab.view.summary),
        confirm_label: I18n.ui("close"), danger: true) { close_tab }
    end

    def close_tab : Nil
      return if @current_idx < 0 || @current_idx >= @fuzzers.size
      tab = @fuzzers[@current_idx]
      if (session_id = tab.db_id) &&
         @host.session.store.fuzz_runs(session_id).any?(&.status.in?("running", "saving"))
        @host.status("fuzz session NOT closed — a saved run started writing; wait for it to finish")
        return
      end
      was_running = tab.view.running?
      release_view_resources(tab.view, cancel: true)
      # Finish the job NOW: once the view leaves @fuzzers, no later event may own its spinner.
      @host.jobs.finish(tab.view.job_id, :stopped, "closed") if was_running
      # The store reports whether the DELETE committed. The tab leaves the list either way —
      # the operator asked to close it — but a rolled-back batch leaves the saved session on
      # disk, so it reappears on the next project open. Saying so is the difference between a
      # transient failure and one that looks like the close simply did not work.
      orphaned = (id = tab.db_id) ? !@host.session.store.delete_fuzz_session(id) : false
      @fuzzers.delete_at(@current_idx)
      @current_idx = @fuzzers.empty? ? -1 : @current_idx.clamp(0, @fuzzers.size - 1)
      auto_load_current_saved_run
      @host.status(TabClose.message(@fuzzers.empty? ? "closed — none open (^N new · ⇧I from History)" : "closed (#{@fuzzers.size} open)", orphaned))
    end

    # Halt EVERY running sweep, not just the current tab's — the project-level exits
    # (leave project / quit) close the whole Runner, so they need per-tab close's
    # `request_stop` + `jobs.finish` pair applied to all of them. Without it the run
    # fibers keep their own sockets and keep hitting the target after the operator is
    # back at the picker. Same order as close_tab: stop first, then finish the job, since
    # once the Runner unwinds `drain_events` never runs again to see the Done event.
    def stop_all : Nil
      return if @closing && @workers.empty?
      @closing = true
      @fuzzers.each do |tab|
        @cancelled_views.add(tab.view)
        if tab.view.running?
          tab.view.request_stop
          @host.jobs.finish(tab.view.job_id, :stopped, "project closed")
        end
      end
      # Bounded for the same reason quiesce_view is: this runs on the Runner fiber as the
      # project closes, and a sweep parked in an in-flight request must not hold the whole
      # TUI. What is left after the deadline is torn down by the spool's own directory
      # teardown, and by `reap_stale_directories` on the next start if this process dies.
      deadline = Time.instant + QUIESCE_DEADLINE
      until @workers.empty? || Time.instant >= deadline
        drain_events
        sleep 1.millisecond
      end
      while drain_events
      end
      @spool_runs.clear
      @cancelled_views.clear
      @release_pending.clear
      @workers.clear
      @spool.close
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

      removed = [] of FuzzerTab
      @fuzzers.reject! do |tab|
        drop = if id = tab.db_id
                 !by_id.has_key?(id) && !fuzz_tab_locked?(tab)
               else
                 false
               end
        removed << tab if drop
        drop
      end
      removed.each do |tab|
        release_view_resources(tab.view, cancel: false)
        if id = tab.db_id
          @auto_load_considered.delete(id)
        end
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
        elsif (cv = cur_view) && (idx = @fuzzers.index(&.view.same?(cv)))
          idx
        elsif @fuzzers.empty?
          -1
        else
          @current_idx.clamp(0, @fuzzers.size - 1)
        end
      auto_load_current_saved_run
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

    # Don't clobber a tab mid-edit or mid-run (mirrors Repeater).
    private def fuzz_tab_locked?(tab : FuzzerTab) : Bool
      v = tab.view
      v.running? || v.saving_results? || v.loading_results? || v.dirty? || v.pane_insert?(:template) || v.pane_insert?(:target)
    end
  end
end
