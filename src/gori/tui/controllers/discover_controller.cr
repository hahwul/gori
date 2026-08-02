require "../tab_controller"
require "../discover_view"
require "../../discover"
require "../../discover/adapters"
require "../../discover/plan"
require "../../outbound"
require "../../store"

module Gori::Tui
  # The Discover sub-tab (under the Target parent tab). Spider + directory brute-force runs
  # are BACKGROUND jobs — starting one from a Sitemap/History space menu does NOT block;
  # progress shows on the bottom bar and completion posts a notification. Discovered
  # endpoints are persisted to the Store so they surface in the Sitemap. Modeled on
  # MinerController (start_run / drain_events / apply_event + the drain-before-rebind race
  # fix). Composed by TargetController, so it exposes frameless render_content /
  # handle_click_content seams instead of owning the tab frame.
  #
  # The body is two panes (RUNS list ↹ FINDINGS table): every launched run keeps a row, and
  # ^R/^X/p act on the SELECTED row, so a crawl started before the current one is still
  # reachable — see DiscoverView's note on what the single-card version cost.
  class DiscoverController < TabController
    DRAIN_CAP = 512

    def initialize(host : Host)
      super(host)
      @view = DiscoverView.new
      @discover_events = Channel({DiscoverRun, Discover::Event}).new(256)
      @persist_buf = [] of {Store::CapturedRequest, Store::CapturedResponse?}
      @persist_base = Time.utc.to_unix * 1_000_000
      @persist_seq = 0_i64
      @run_seq = 0
    end

    def view : DiscoverView
      @view
    end

    def tab : Symbol
      :discover
    end

    def command_scope : Verb::Scope
      Verb::Scope::Discover
    end

    def body_badge : Symbol
      :body
    end

    def body_hint(focus : Symbol) : String
      return "start from Sitemap/History (space → \"Discover here\")" if @view.empty?
      if @view.focus == :runs
        "↑/↓ runs · tab findings · ^R run · ^X stop · p pause · d dismiss · space cmds · esc tabs"
      else
        "↑/↓ nav · tab runs · [ / ] runs · ^R run · ^X stop · p pause · d dismiss · esc tabs"
      end
    end

    # --- rendering (frameless seam for TargetController) ---
    def render_content(screen : Screen, rect : Rect, focus : Symbol) : Nil
      @view.render(screen, rect, focus == :body)
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      BodyChrome.framed(screen, rect, focus == :body) { |inner| render_content(screen, inner, focus) }
    end

    def handle_click_content(content : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      @view.click(content, mx, my)
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      handle_click_content(rect.inset(1, 1), mx, my)
    end

    # --- input ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return handle_empty_key(ev) if @view.empty?
      if ev.key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      return false if (ev.ctrl? || ev.alt?) && !ev.key.escape? # ^R/^X/^P fall through to the verb keymap
      return true if handle_pane_chord(ev)
      @view.focus == :runs ? handle_runs_key(ev) : handle_findings_key(ev)
    end

    private def handle_empty_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      return false unless key.escape? || key.up? || key.lower_k?
      @host.request_focus(:subtabs) # pop to Target's Sitemap|Discover strip (self-downgrades to :menu with no strip)
      true
    end

    # Keys that mean the same thing in either pane.
    private def handle_pane_chord(ev : Termisu::Event::Key) : Bool
      c = ev.char || ev.key.to_char
      case
      when ev.key.escape? then @host.request_focus(:subtabs)
      when c == '['       then @view.move_run(-1) # cycling still works from either pane
      when c == ']'       then @view.move_run(1)
      when c == 'p'       then discover_toggle_pause
      else                     return false
      end
      true
    end

    # RUNS list: ↑/↓ walk the runs (which is what ^R/^X/p then act on), stepping off the
    # bottom into the findings table and off the top to the Sitemap|Discover strip.
    private def handle_runs_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.up?, key.lower_k?   then @view.runs_at_top? ? @host.request_focus(:subtabs) : @view.move_run(-1)
      when key.down?, key.lower_j? then @view.runs_at_bottom? ? @view.focus_pane(:findings) : @view.move_run(1)
      else                              return false
      end
      true
    end

    private def handle_findings_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.up?, key.lower_k?   then @view.findings_at_top? ? @view.focus_pane(:runs) : @view.move(-1)
      when key.down?, key.lower_j? then @view.move(1)
      else                              return false
      end
      true
    end

    def body_scroll(delta : Int32) : Bool
      handle_wheel(delta)
    end

    def handle_wheel(step : Int32) : Bool
      @view.focus == :runs ? @view.move_run(step) : @view.move(step)
      true
    end

    # --- focus ring ---
    def pane_advance(dir : Int32) : Bool
      @view.empty? ? false : @view.pane_advance(dir)
    end

    def focus_first : Nil
      @view.focus_first
    end

    def focus_last : Nil
      @view.focus_last
    end

    # --- verbs (delegated by the Runner's ExecContext) ---
    def discover_run : Nil
      run = @view.current
      unless run
        @host.status("no run selected — start from Sitemap/History (space → \"Discover here\")")
        return
      end
      if run.running?
        @host.status("already running — ^X to stop")
        return
      end
      drain_events # flush a just-finished run's trailing Done before start_run rebinds job_id
      start_run(run)
    end

    # Stops the SELECTED run, not "the" run — with several crawls in flight the operator has
    # to be told which row ^X landed on, and told when it landed on a finished one instead of
    # silently doing nothing while another run keeps sending.
    def discover_stop : Nil
      run = @view.current
      unless run && run.running?
        @host.status(@view.any_running? ? "selected run is not running — ↑/↓ to the running row, then ^X" : "no run to stop")
        return
      end
      run.request_stop
      @host.status("stopping #{run.label(40)}…")
    end

    # Remove the selected run's row — the manual half of retention, since the list is append-
    # only for the session (a long dogfood run otherwise scrolls through dozens of finished
    # crawls). Refused while it is running or paused: the engine fiber outlives the row and
    # `drain_events` drops events for a run that left the list, so this would orphan a crawl
    # that is still sending. Findings already reached the Sitemap via the persist batch, so the
    # row is the only thing lost.
    def discover_dismiss : Nil
      run = @view.current
      unless run
        @host.status("no run selected")
        return
      end
      label = run.label(40)
      unless @view.dismiss(run)
        @host.status("#{label} is still going — ^X to stop it first")
        return
      end
      @host.status(@view.empty? ? "dismissed #{label} — no runs left" : "dismissed #{label}")
    end

    # Halt EVERY live crawl (running OR paused) on a project-level exit — leave project /
    # quit close the whole Runner, and a crawl's engine fiber is referenced by nothing they
    # unwind, so without this it keeps its own sockets and runs the frontier to completion
    # against the target while the operator is back at the project picker with no bottom
    # bar, no run list and no key that could stop it.
    #
    # Same order and the same pair every tab-level close already uses: `request_stop` so
    # the engine unwinds, then `jobs.finish` NOW, because once the Runner exits
    # `drain_events` never runs again to see the Done event. A PAUSED run is included
    # deliberately — `running?` covers :paused, and a paused crawl still holds its
    # connections and would resume nothing but still never be reachable again.
    def stop_all : Nil
      @view.runs.each do |run|
        next unless run.running?
        run.request_stop
        @host.jobs.finish(run.job_id, :stopped, "project closed") if run.job_id != 0
      end
    end

    def discover_toggle_pause : Nil
      return unless run = @view.current
      if run.paused?
        run.resume
        @host.status("resumed #{run.label(40)}")
      elsif run.running?
        run.pause
        @host.status("paused #{run.label(40)} — p to resume")
      else
        @host.status("selected run is #{run.status} — nothing to pause")
      end
    end

    # --- cross-surface entry: launch a run from a seed (called by the Runner after the
    #     config overlay confirms). Runs in the background; the caller may switch here. ---
    def start_session(target : String, config : Discover::Config) : DiscoverRun
      @run_seq += 1
      run = DiscoverRun.new(target, config)
      run.id = @run_seq
      @view.add(run)
      start_run(run)
      run
    end

    def select_run(id : Int32) : Nil
      @view.select_run_by_id(id)
    end

    def reveal_session(id : Int64) : Nil
      @view.select_run_by_id(id.to_i)
      @host.focus_body
    end

    # --- run lifecycle ---
    private def start_run(run : DiscoverRun) : Nil
      engine, err = build_engine(run)
      unless engine
        @host.status(err || "cannot start discovery")
        return
      end
      run.engine = engine
      run.begin_run
      run.job_id = @host.jobs.start(:discover, run.label(40), goto: Jobs::Goto.new(:target, run.id.to_i64))
      events = @discover_events
      spawn(name: "gori-discover") do
        engine.run do |ev|
          case ev
          when Discover::ProgressEvent
            select
            when events.send({run, ev})
            else
            end
          else
            events.send({run, ev}) # Finding/Baseline/Done/Error — blocking, never dropped
          end
        end
      end
      @host.status("discovering #{run.target} in the background — watch the bottom bar / notifications")
    end

    # View state → Discover::PlanOptions → the ONE builder every surface shares. The run's
    # `config` is passed by REFERENCE on purpose: the discover config overlay edits that same
    # instance while the row is selected, so a ^R re-run must read it, not a snapshot.
    #
    # `Outbound.interactive` is the TUI's Layer-1 policy (no up-front gate — the operator
    # chose this target from the Sitemap/History; Sandbox and EXCLUDE still bound the crawl
    # through the ScopePolicy the builder derives from it). The session's LIVE HostOverrides
    # instance is handed over rather than a fresh `HostOverrides.load`, so an override the
    # operator adds in the Project tab mid-session applies to the next run (issue #367) — the
    # Fuzzer/Miner/Sequencer/Repeater tabs used to drop this argument entirely and silently
    # dial the real DNS answer while `gori run discover` pinned it.
    private def build_engine(run : DiscoverRun) : {Discover::Engine?, String?}
      session = @host.session
      # The realistic half of the header check, and the one the overlay cannot make: the
      # line the operator typed is fine and the ENV VAR is not (`Authorization: Bearer
      # $TOKEN` where TOKEN was read from a file and kept its trailing newline). It has to
      # run HERE — after the project's env is hydrated, before any traffic — because
      # `Headers.expand`'s send-time backstop drops the header on every probe without a
      # word, and by then the crawl is already running. `Headers.unsafe_expanded` had
      # exactly one caller in the tree (`gori run discover`); this is the second.
      if unsafe = Discover::Headers.unsafe_expanded(run.config.headers).first?
        return {nil, "header #{unsafe.inspect} rejected — its value contains CR or LF after " \
                     "$VAR expansion, which would splice extra headers into every probe"}
      end
      options = Discover::PlanOptions.new(run.target, config: run.config,
        verify: !session.config.insecure_upstream?, overrides: session.host_overrides)
      {Discover::Plan.build(options, Gori::Outbound.interactive(session.scope)).engine, nil}
    rescue ex : Discover::PlanError
      {nil, discover_plan_error(ex)}
    rescue ex
      {nil, "config error: #{ex.message}"}
    end

    # The Discover tab's wording for a plan the run can't produce. The builder reports the
    # machine-readable `reason`; naming the tab's own hotkeys and panes is ours.
    private def discover_plan_error(ex : Discover::PlanError) : String
      case ex.reason
      in Discover::PlanError::Reason::NoTarget
        "no target — start from Sitemap/History (space → \"Discover here\")"
      in Discover::PlanError::Reason::BadTarget
        "invalid target — use scheme://host[:port][/path]"
      in Discover::PlanError::Reason::NoTechnique
        "enable spider or brute-force in the run config first"
      in Discover::PlanError::Reason::Wordlist
        "wordlist error: #{ex.detail}"
      in Discover::PlanError::Reason::UnresolvedEnv
        "unresolved env #{ex.detail} — add it in the Project tab's ENV pane"
      end
    end

    # --- async drain (run-loop tick) ---
    def drain_events : Bool
      applied = false
      n = 0
      while n < DRAIN_CAP && (pair = nonblocking_event)
        n += 1
        run, ev = pair
        next unless @view.runs.any?(&.same?(run)) # run gone → drop
        apply_event(run, ev)
        applied = true
      end
      flush_persist if applied
      applied
    end

    private def nonblocking_event : {DiscoverRun, Discover::Event}?
      select
      when p = @discover_events.receive
        p
      else
        nil
      end
    end

    private def apply_event(run : DiscoverRun, ev : Discover::Event) : Nil
      case ev
      when Discover::FindingEvent
        run.findings << ev.finding
        run.found = run.findings.size
        queue_persist(ev.finding)
      when Discover::ProgressEvent
        p = ev.progress
        run.sent = p.sent
        run.found = p.found
        run.errors = p.errors
        run.queued = p.queued
        @host.jobs.progress(run.job_id, p.found, nil, "#{p.found} found · #{p.sent} sent")
      when Discover::BaselineEvent
        # per-directory soft-404 calibration — no UI row (surfaced via stats)
      when Discover::DoneEvent
        run.sent = ev.progress.sent
        run.found = ev.progress.found
        run.errors = ev.progress.errors
        run.queued = ev.progress.queued
        run.stats = ev.stats
        # A sweep that stopped on its BUDGET is not the same sweep as one that finished, and
        # `:done` over an unfinished crawl reads as "that is the whole surface". The engine
        # already says which (`Discover::DoneEvent#budget_exhausted` — discover has no stable
        # denominator a consumer could derive it from); this was the one consumer ignoring it.
        run.status = if ev.stopped
                       :stopped
                     elsif ev.budget_exhausted
                       :budget_exhausted
                     else
                       :done
                     end
        finish_job(run, ev)
      when Discover::ErrorEvent
        run.status = :error
        run.error_msg = ev.message
        @host.jobs.finish(run.job_id, :error, ev.message)
        msg = "Discover: #{ev.message} on #{run.target}"
        log_event(run, :error, msg)
        push_notification(run, :error, msg)
        @host.status("discover error: #{ev.message}")
      end
    end

    private def finish_job(run : DiscoverRun, ev : Discover::DoneEvent) : Nil
      n = run.findings.size
      @host.jobs.finish(run.job_id, :done, "#{n} found")
      tail = if ev.stopped
               " (stopped)"
             elsif ev.budget_exhausted
               " — budget exhausted, #{ev.progress.queued} queued unexplored (raise max requests to finish)"
             else
               ""
             end
      msg = "Discover: #{n} endpoint#{n == 1 ? "" : "s"} on #{run.target}#{tail}"
      level = n > 0 ? :success : :info
      log_event(run, level, msg)
      push_notification(run, level, msg)
      @host.status(msg) if Settings.notify_toast?
    end

    private def push_notification(run : DiscoverRun, level : Symbol, msg : String) : Nil
      @host.notifications.push(level, msg, Jobs::Goto.new(:target, run.id.to_i64), source: "discover")
    end

    private def log_event(run : DiscoverRun, level : Symbol, msg : String) : Nil
      @host.session.store.insert_event("discover", "job_done", level.to_s, msg,
        goto_tab: "target", goto_session_id: run.id.to_i64)
    end

    # --- persistence: discovered endpoints → Store → Sitemap ---
    private def queue_persist(f : Discover::Finding) : Nil
      @persist_seq += 1
      pair = Discover::Persist.flow_pair(f, @persist_base + @persist_seq)
      @persist_buf << {pair.request, pair.response}
    end

    private def flush_persist : Nil
      return if @persist_buf.empty?
      @host.session.store.insert_import_batch(@persist_buf)
      @persist_buf.clear
    rescue
      @persist_buf.clear # a store write failure must not wedge the drain
    end
  end
end
