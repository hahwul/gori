require "../tab_controller"
require "../miner_view"
require "../mine_config_overlay"
require "./seeded_tool_tabs"
require "../../store"
require "../../miner"
require "../../env"
require "../../param_inventory"
require "../../plural"

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
    include SeededToolTabs

    def initialize(host : Host)
      super(host)
      @sessions = [] of MinerTab
      session_rows.each { |rec| @sessions << restore_tab(rec) }
      @current_idx = @sessions.empty? ? -1 : 0
      @mine_events = Channel({MinerView, Miner::Event}).new(256)
      @seed_names = Channel({Int64, MineConfigOverlay, Hash(Int64, Array(String))?}).new(1)
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

    def current_view : MinerView?
      current_tab_obj.try(&.view)
    end

    def view_at(idx : Int32) : MinerView?
      (0 <= idx < @sessions.size) ? @sessions[idx].view : nil
    end

    def body_badge : Symbol
      querying? ? :editor : :body # read-only display + a navigable findings table; the `/` bar is the one text field
    end

    def body_hint(focus : Symbol) : String
      v = current_view
      return Hotkeys.expand_menu_paths(@host.session.registry, "↹/esc tabs · mine from History/Repeater ({space:history.mine})") unless v
      return v.filter.hint if v.filter.editing?
      # `esc sub-tabs`, not `esc tabs`: `handle_escape` below goes to the strip whenever one
      # is shown, and `subtab_strip_shown?` is `!@sessions.empty?` — every branch under this
      # point has a `current_view`, so the strip is always up and escape never reaches the
      # tab bar from here. Same correction as the Repeater's and the Fuzzer's.
      #
      # RUN or STOP, never both and never the wrong one. `{mine.stop}` was named
      # unconditionally, so an idle session's footer advertised the one key that does nothing
      # there and hid `^R` — the key that starts the mine — behind the card badge alone.
      # Sequencer's footer names its run key in the same slot; this is that line, made
      # honest about which half of the pair is live.
      go = v.running? ? "{mine.stop} stop" : "{mine.run} run"
      case v.focus
      when :results then keys("↑/↓ select · ↵ detail · {mine.filter} filter · #{go} · space cmds · ↹ pane · esc sub-tabs")
      when :detail  then "↑/↓ scroll · esc back"
      else               keys("↓ findings · #{go} · space cmds · ↹ pane · esc sub-tabs")
      end
    end

    # --- input ---
    # The RESULTS `/` filter bar.
    def body_takes_text? : Bool
      querying?
    end

    # --- the FINDINGS `/` filter (a text sub-mode the shell claims ahead of the focus ring) ---
    def querying? : Bool
      current_view.try(&.filter.editing?) || false
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      current_view.try(&.handle_filter_key(ev)) || false
    end

    def set_preedit(text : String) : Bool
      current_view.try(&.filter.set_preedit(text)) || false
    end

    # `/` — narrow the FINDINGS table by parameter / location / evidence. Refused with no
    # session; lands on the RESULTS pane (closing an open detail) so the rows are on screen.
    def mine_filter : Nil
      return @host.status(Hotkeys.expand_menu_paths(@host.session.registry, "no miner session — mine from History/Repeater ({space:history.mine})")) unless v = current_view
      v.filter_start
    end

    private def navigable_pane?(pane : Symbol) : Bool
      pane == :summary || pane == :results
    end

    # A bare key past SeededToolTabs#handle_body_key. Only a key a pane took is consumed. This
    # used to answer true for EVERY bare key, so `/` (the filter), `x`/`y` in the detail and the
    # Global breath keys never reached the keymap from here.
    private def session_key(ev : Termisu::Event::Key, v : MinerView, c : Char?) : Bool
      if ev.key.escape?
        handle_escape(v)
        return true
      end
      handle_pane_key(ev, v)
    end

    private def handle_pane_key(ev : Termisu::Event::Key, v : MinerView) : Bool
      case v.focus
      when :summary then handle_summary(ev, v)
      when :results then handle_results(ev, v)
      when :detail  then handle_detail(ev, v)
      else               false
      end
    end

    private def handle_summary(ev : Termisu::Event::Key, v : MinerView) : Bool
      key = ev.key
      if key.down? || key.lower_j?
        v.focus_pane(:results)
      elsif key.up? || key.lower_k?
        @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      else
        return false
      end
      true
    end

    private def handle_results(ev : Termisu::Event::Key, v : MinerView) : Bool
      key = ev.key
      case
      when key.enter?              then v.open_detail
      when key.down?, key.lower_j? then v.results_move(1)
      when key.up?, key.lower_k?   then v.results_at_top? ? v.focus_pane(:summary) : v.results_move(-1)
      else                              return false
      end
      true
    end

    private def handle_detail(ev : Termisu::Event::Key, v : MinerView) : Bool
      key = ev.key
      if key.up? || key.lower_k?
        v.detail_move(-1, ev.shift?)
      elsif key.down? || key.lower_j?
        v.detail_move(1, ev.shift?)
      else
        return v.detail_motion_key(ev) # Home / End / PgUp / PgDn, ⇧ extending
      end
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = body_rect_below_filter(rect)
      return true unless v = current_view
      # The MINER card's run control, before the pane it rides.
      if v.summary_chrome_hit(body, mx, my)
        @host.focus_body
        v.focus_pane(:summary)
        v.running? ? mine_stop : mine_run
        return true
      end
      # The FINDINGS gauge on the card hairline, which `pane_at`'s rects exclude.
      if row = v.results_gauge_row(body, mx, my)
        @host.focus_body
        v.focus_pane(:results)
        v.select_result_row(row)
        return true
      end
      if pane = v.pane_at(body, mx, my)
        @host.focus_body
        # FINDINGS defers its own `focus_pane` into `click_results` — the select-then-open
        # test reads `v.focus`, so focusing first would make "already focused" always true
        # and a first click on row 0 of an unfocused pane would open the detail outright.
        # (The Fuzzer orders it this way for the same reason.)
        if pane == :detail
          v.detail_click(body, mx, my) # the FINDING pane takes a row cursor from the pointer
        elsif pane == :results
          click_results(v, body, mx, my)
        else
          v.focus_pane(pane)
        end
      end
      true
    end

    # A double-click on a FINDINGS row runs ↵ on it (#969's contract): select, then open the
    # detail, whichever pane held focus before. False off the list, so the plain click stands.
    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = body_rect_below_filter(rect)
      return false unless v = current_view
      return false unless v.pane_at(body, mx, my) == :results
      return false unless row = v.results_row_at(body, mx, my)
      @host.focus_body
      v.focus_pane(:results)
      v.select_result_row(row)
      v.open_detail
      true
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # The FINDING pane only. Its rows are two columns, so there is no word to double-click.
    def supports_drag? : Bool
      current_view.try(&.focus) == :detail
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless v = current_view
      return unless v.focus == :detail
      v.detail_click(body_rect_below_filter(rect), mx, my, selecting: true)
    end

    # --- READ-pane delegators (the FINDING read verbs + the Runner's read_* ladders) ---
    def miner_detail_readable? : Bool
      current_view.try { |v| v.focus == :detail } || false
    end

    def miner_results_readable? : Bool
      current_view.try { |v| v.focus == :results && !v.selected_finding.nil? } || false
    end

    def selection_active? : Bool
      current_view.try(&.detail_selection?) || false
    end

    def selection_text : String
      current_view.try(&.detail_copy_text) || ""
    end

    def select_line : Nil
      current_view.try(&.detail_select_line)
    end

    def clear_selection : Nil
      current_view.try(&.detail_clear_selection)
    end

    # `y`: the selected field rows, or the whole finding when nothing is selected. A mined
    # parameter's evidence is what goes into a report, and it had no copy at all.
    def miner_copy : Nil
      v = current_view
      # The FINDINGS list: the finding as one line — name, where it was found, the evidence.
      if v && v.focus == :results
        f = v.selected_finding || return
        return copy_text("#{f.name} · #{f.location.label} · #{f.evidence.label}", "finding")
      end
      return unless v && v.focus == :detail
      sel = v.detail_selection?
      text = sel ? v.detail_copy_text : v.detail_copy_all
      return if text.empty?
      copy_text(text, sel ? nil : "all")
    end

    # PgUp/PgDn/Home/End over FINDINGS: `handle_results` declines them, and `results_move`
    # clamps the Runner's ±JUMP_ROWS over the filtered list. SUMMARY has no list, and DETAIL
    # claims the keys in `handle_detail` (#1443).
    def body_scroll(delta : Int32) : Bool
      v = current_view
      return false unless v && v.focus == :results
      v.results_move(delta)
      true
    end

    def page_rows : Int32?
      v = current_view
      v.results_page_rows if v && v.focus == :results
    end

    private def wheel_pane(v : MinerView, pane : Symbol, step : Int32) : Nil
      case pane
      when :results then v.results_move(step)
      when :detail  then v.detail_wheel(step) # viewport only — ↑/↓ are the cursor
      end
    end

    def current_session_db_id : Int64?
      return nil if @current_idx < 0 || @current_idx >= @sessions.size
      @sessions[@current_idx].db_id
    end

    def db_id_at(idx : Int32) : Int64?
      @sessions[idx]?.try(&.db_id)
    end

    # --- cross-tab seeds (build the config-overlay seed) ---
    def build_seed_from_flow(id : Int64) : MineSeed?
      return nil unless detail = @host.session.store.get_flow(id)
      built = Repeater::FlowRequest.build(detail)
      appl = Miner::Plan.applicable_locations(built.bytes)
      summary = SeededSession.request_summary(built.bytes)
      MineSeed.new(built.target, built.bytes, built.http2, nil, id, summary, appl.applicable, appl.default)
    end

    # Bumped by every `scan_seed_names` and by `cancel_seed_scan`: a scan whose generation
    # moved stops walking, and `drain_seed_names` drops what it sends.
    getter seed_generation : Int64 = 0_i64

    # A History mine's seed names (#1231): the parameter inventory's neighbour names for each
    # flow `ov` seeds, read on a WORKER fiber — the scan walks flows, and on the one
    # cooperative scheduler a synchronous walk would freeze the popup it is filling (P6). They
    # land through `drain_seed_names`. The scan is superseded, never stopped by what is on
    # screen: a confirm dialog that covers the popup for a moment must not cut it short.
    # Dismissing the popup (esc, a click outside) does stop it, through its `on_close`, which a
    # covering child modal does not run.
    def scan_seed_names(ov : MineConfigOverlay) : Nil
      ids = ([ov.seed] + ov.extra_seeds).compact_map(&.flow_id)
      return if ids.empty?
      gen = (@seed_generation += 1)
      ov.begin_seeding
      prior = ov.on_close
      me = self
      ov.on_close = -> {
        me.cancel_seed_scan(gen)
        prior.try(&.call)
        nil
      }
      store = @host.session.store
      results = @seed_names
      spawn(name: "gori-mine-seed-names") do
        # nil = the scan raised; the popup then says seeding failed instead of spinning on.
        by_flow = begin
          ParamInventory.seed_names(store, store.flow_rows(ids), stop: -> { me.seed_generation != gen })
        rescue ex
          ::Log.warn(exception: ex) { "mine seed-name scan failed" }
          nil
        end
        results.send({gen, ov, by_flow})
      end
    end

    # The popup started its mine (or went away): its scan has nothing left to feed. With
    # `gen`, only while that scan is still the current one, so a popup closing late cannot
    # cancel a newer popup's scan.
    def cancel_seed_scan(gen : Int64? = nil) : Nil
      @seed_generation += 1 if gen.nil? || gen == @seed_generation
    end

    # Each run-loop tick: land the current seed-name scan on its popup. True when it landed
    # (→ a frame); a superseded or cancelled scan's answer is dropped.
    def drain_seed_names : Bool
      select
      when landed = @seed_names.receive
        gen, ov, by_flow = landed
        return false unless gen == @seed_generation
        ov.land_seed_names(by_flow)
        true
      else
        false
      end
    end

    # Editor text to CRLF line endings (h2 reframing and the injection boundary scan expect
    # them); captured flows are already CRLF. `$VAR` tokens are left alone: Miner::Plan expands
    # the request at build time. In BYTE space, never `gsub(/\r?\n/, "\r\n")`: the Repeater
    # buffer is routinely raw captured bytes, PCRE2 raises on a non-UTF-8 subject, and these
    # bytes go on the wire as they are (P7).
    def build_seed_from_request(target : String, request_text : String, http2 : Bool, sni : String?) : MineSeed
      bytes = Env.normalize_crlf(request_text.to_slice)
      appl = Miner::Plan.applicable_locations(bytes)
      MineSeed.new(target, bytes, http2, sni, nil, SeededSession.request_summary(bytes), appl.applicable, appl.default)
    end

    # --- start a session (called by the Runner after the config overlay confirms) ---
    def start_session(seed : MineSeed, config : Miner::Config) : Nil
      view = MinerView.new
      # `flow_id != nil` IS the provenance test: `build_seed_from_flow` is the only
      # constructor that sets it, and its bytes come straight from `FlowRequest.build`.
      # `build_seed_from_request` (the Repeater path) leaves it nil and its bytes are
      # editor text. Same one-line test `gori run mine` makes on `--flow`.
      view.load(seed.target, seed.request, seed.http2, seed.sni, config,
        evidence: !seed.flow_id.nil?)
      open_session(view, seed.flow_id) # NB: NO goto_tab — the job runs in the background
      start_run(view)
    end

    private def open_session(view : MinerView, flow_id : Int64?) : Nil
      @sessions << MinerTab.new(view, flow_id, persist_new(view, flow_id))
      @current_idx = @sessions.size - 1
      reveal_active_subtab
    end

    # Content-only clone of the active miner session (request + config; no findings/links).
    # Duplicates the MARKED sub-tabs when the strip carries marks, the active one otherwise
    # (`target_subtab_indices` — the one target rule).
    def miner_duplicate : Nil
      if refs = batch_subtab_refs
        msg = duplicate_marked_subtabs(refs, "miner session") { |i| duplicate_at(i) }
        return unless msg
        @host.goto_tab(:miner)
        @host.status("#{msg} (#{@sessions.size} open)")
        return
      end
      return @host.status("no miner session open to duplicate") unless current_view
      duplicate_at(@current_idx)
      @host.goto_tab(:miner)
      @host.status("duplicated miner session (#{@sessions.size} open)")
    end

    # Clone sub-tab `idx` into a new session at the end of the strip. Toast-free, so the
    # single and batch arms above can each own their sentence.
    private def duplicate_at(idx : Int32) : Nil
      return unless src = view_at(idx)
      view = MinerView.new
      view.duplicate_from(src)
      open_session(view, nil)
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
      MinerController.repeater_seed_for(v, f)
    end

    # The seed for one {session, finding} pair. A class method because it reads no shell
    # state — `selected_repeater_seed` above only picks the pair — so a spec can drive the
    # REAL byte handling below without standing up a Host. Same shape as
    # `FuzzerController.repeater_seed_for`, and for the same reason.
    def self.repeater_seed_for(view : MinerView, f : Miner::Finding) : RepeaterSeed
      # `String.new`, NOT `.scrub`, and NO CRLF→LF collapse — the sibling rule
      # `FuzzerController.repeater_seed_for` already spells out one tab over.
      #
      # These are the bytes the MINER put on the wire (`Miner::Inject.apply` over the
      # session request, which for a flow-seeded session is a CAPTURE), so they may
      # legitimately not be valid UTF-8: a latin-1 form field, a protobuf/gRPC frame, a
      # gzip'd POST. `.scrub` rewrote each such byte to the three bytes of U+FFFD in a
      # request the tab then presents as "the one that found this" — measured on a live
      # mine of `q=hi&bin=<ff fe 01 02>&z=1` against a reflecting origin:
      #
      #   sent  71 3d 68 69 26 62 69 6e 3d ff fe 01 02 26 7a 3d 31 26 64 65 62 75 67 3d …
      #   seed  71 3d 68 69 26 62 69 6e 3d ef bf bd ef bf bd 01 02 26 7a 3d 31 26 …
      #
      # …+4 bytes under the `Content-Length: 34` the seed still carried, so ^R re-sent a
      # request the miner never made and gori had no way left to notice.
      #
      # The CRLF→LF collapse was justified by "Repeater editors store LF text", which the
      # @eols work made false: `TextArea#set_text` round-trips each line's own terminator
      # and the send path reads `wire_text`, so collapsing here flattened a body's own
      # CRLFs to bare LFs on the way in — exactly the loss the Fuzzer's seed stopped taking.
      text = String.new(view.request_with_finding(f))
      RepeaterSeed.new(view.target, text, view.http2?, view.sni_override,
        "#{f.name} (#{f.location.label})")
    end

    private def persist_new(view : MinerView, flow_id : Int64?) : Int64?
      id = @host.session.store.insert_miner_session(view.target_origin, view.request_bytes, view.http2?,
        view.sni_override, view.config_json, flow_id, @sessions.size, view.name)
      id == 0 ? nil : id
    end

    private def start_run(view : MinerView) : Nil
      # The session's LIVE HostOverrides instance, not a fresh HostOverrides.load(store):
      # the proxy reads that one and the Project tab edits it (Mutex-guarded), so a second
      # copy would freeze this run's pins at whatever they were when the tab opened (#367).
      engine, err = view.build_engine(!@host.session.config.insecure_upstream?,
        @host.session.scope, @host.session.host_overrides, @host.session.store)
      unless engine
        @host.status(err || "can't mine")
        return
      end
      # Hand the engine over BEFORE anything can be sent, so ^X reaches it even during the
      # baseline calibration `orchestrate` runs ahead of the first event.
      view.engine = engine
      view.begin_run
      view.job_id = @host.jobs.start(:miner, view.summary, goto: goto_for(view))
      events = @mine_events
      terminal_sent = false
      spawn(name: "gori-miner") do
        engine.run do |ev|
          case ev
          when Miner::ProgressEvent
            select
            when events.send({view, ev})
            else
            end
          else
            # Done/Error is the run's VERDICT. Once one is on the channel the rescue below
            # must not send a second: `apply_event`'s ErrorEvent arm re-finishes the run,
            # so a raise on the way out of a COMPLETED run would relabel it :error and fire
            # an error notification for work that succeeded. (`jobs.finish` keeps the first
            # terminal state, so the job itself was already safe — nothing else was.)
            terminal_sent = true if ev.is_a?(Miner::DoneEvent) || ev.is_a?(Miner::ErrorEvent)
            events.send({view, ev}) # Baseline/Finding/Done/Error — blocking, never dropped
          end
          engine.stop if view.stop_requested?
        end
      rescue ex
        # An unrescued raise in a `spawn` block kills only this fiber and prints to STDERR,
        # which under the TUI is the alternate screen (#411). The `ensure` below clears the
        # view's running flag, so the pane merely looked finished — but `jobs.finish` is only
        # ever reached from `apply_event`'s Done/Error arms, so with no terminal event the
        # bottom-bar job spun for the rest of the session and the exit prompt kept counting a
        # mine that had already died. Worse, a mine that stops with no verdict reads as one
        # that found nothing. Hand the failure back the way the engine reports its own.
        ::Log.error(exception: ex) { "mine run fiber died" }
        # Cleared BEFORE the send, not only in the `ensure`: `events` is bounded and this send
        # blocks, so with the drain gone the `ensure` would be reached late or not at all — and
        # un-wedging the pane is the one thing that must not wait on a reader.
        view.finish_run
        # `ex.class` too: "Nil assertion failed" alone is what the operator gets in the job's
        # error text, the notification AND the persisted event log, and it names nothing.
        events.send({view, Miner::ErrorEvent.new("#{ex.class}: #{ex.message}")}) unless terminal_sent
      ensure
        view.finish_run # backstop — the drain's Done also clears it
      end
      # The request-time macro, when the run has one (#1350): said up front, because a per-request
      # macro serialises the mine and an operator otherwise learns that from the stopwatch.
      macro_line = (info = view.macro_info) ? " · #{info.line}" : ""
      @host.status("mining #{view.target_origin} in the background — watch the bottom bar / notifications#{macro_line}")
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
      @host.status("stopping…", :busy)
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
        @host.status("miner error: #{ev.message}", :error) if v.config.notify.posts_notification?(0, error: true)
      end
    end

    private def finish_job(v : MinerView, ev : Miner::DoneEvent) : Nil
      return if @host.jobs.errored?(v.job_id) # an ErrorEvent already finalized this run — the
      #                                         engine's trailing DoneEvent must not log/notify success
      n = v.found_count
      @host.jobs.finish(v.job_id, :done, "#{n} found")
      tail = if ev.stopped
               " (stopped)"
             elsif v.budget_exhausted?
               " — #{v.budget_note}"
             else
               ""
             end
      found = n > 0 ? "#{Gori.plural(n, "param")} found" : "done — nothing found"
      msg = "Miner: #{found} on #{v.summary}#{tail}#{macro_failure_note(ev.progress)}"
      level = n > 0 ? :success : :info
      log_event(v, level, msg)
      push_mine_notification(v, level, msg, found: n)
      # The status line answers the start toast's "watch the bottom bar", so an empty run under
      # the default "when found" still ends with a line there (#1379). NotifyMode gates the
      # notification CENTER; only Off silences the bar too.
      @host.status(msg) unless v.config.notify.off?
    end

    # A macro that FAILED is the reason some probes are errors rather than answers, and the
    # completion line is where an operator who was not watching looks.
    private def macro_failure_note(p : Miner::Progress) : String
      (t = p.request_macro) && t.failed > 0 ? " · macro: #{t.summary}" : ""
    end

    private def push_mine_notification(v : MinerView, level : Symbol, msg : String, found : Int32 = 0) : Nil
      return unless v.config.notify.posts_notification?(found, error: level == :error)
      @host.notifications.push(level, msg, goto_for(v), source: "miner")
    end

    # #124: append every mine completion/error to the store event feed UNCONDITIONALLY —
    # independent of the human NotifyMode gate above ("log freely, interrupt deliberately").
    private def log_event(v : MinerView, level : Symbol, msg : String) : Nil
      g = goto_for(v)
      @host.session.store.insert_event("miner", "job_done", level, msg,
        goto_tab: g.try(&.tab.to_s), goto_session_id: g.try(&.session_id))
    end

    private def goto_for(v : MinerView) : Jobs::Goto?
      tab = @sessions.find(&.view.same?(v))
      (tab && (id = tab.db_id)) ? Jobs::Goto.new(:miner, id) : nil
    end

    private def delete_session_row(id : Int64) : Bool
      @host.session.store.delete_miner_session(id)
    end

    # --- SeededToolTabs hooks ---
    private def session_rows
      @host.session.store.miner_sessions
    end

    private def restore_tab(row) : MinerTab
      view = MinerView.new
      view.restore(row)
      MinerTab.new(view, row.flow_id, row.id)
    end

    private def save_session_name(id : Int64, name : String?) : Bool
      @host.session.store.set_miner_session_name(id, name)
    end

    private def session_events
      @mine_events
    end

    private def close_wording : {String, String, String}
      {"MINER", "mining", "results"}
    end

    def save_current : Nil
      return unless tab = current_tab_obj
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      cfg = v.config_json
      unless @host.session.store.update_miner_session(id, v.target_origin, v.request_bytes, v.http2?, v.sni_override, cfg, v.name)
        return @host.status("session NOT saved (project busy) — leaving the tab dirty so the next save retries")
      end
      v.mark_config_synced(cfg)
      v.clear_dirty
    end
  end
end
