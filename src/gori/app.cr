require "log"
require "./bind_address"
require "./config"
require "./paths"
require "./settings"
require "./project"
require "./project_registry"
require "./session"
require "./store"
require "./proxy/tls/cert_authority"
require "./cli/output"
require "./verb"
require "./verbs/core"
require "./verbs/history"
require "./verbs/sitemap"
require "./verbs/issues"
require "./verbs/comparer"
require "./verbs/decoder"
require "./verbs/jwt"
require "./verbs/rewriter"
require "./verbs/colormarker"
require "./verbs/authorize"
require "./verbs/notes"
require "./verbs/host_overrides"
require "./verbs/env"
require "./tui"
require "./tui/runner"
require "./tui/project_picker"
require "./tui/setup_wizard"

module Gori
  # Top-level orchestrator. Owns the shared cert authority + verb registry and
  # process lifecycle. Each open project runs as a Session (its own store +
  # proxy). The TUI loops picker → session → shell; headless opens one default
  # session directly.
  class App
    getter config : Config
    getter ca : Proxy::Tls::CertAuthority
    getter registry : Verb::Registry

    # How often headless `gori run capture` re-reads Rewriter rules AND Scope from the
    # store, so `gori run rewriter add/rm/enable/disable` / `gori run project scope
    # add/rm` against the SAME running project take effect without a restart
    # (docs/content/guide/proxy.md promises "no restart" for Rewriter; Scope has the
    # same expectation — its Sandbox gate is enforced off this SAME live object). The TUI
    # gets Rewriter on demand via the `r` key (Rewriter::rewriter_reload) and Scope via its
    # own store data_version poll (Runner#apply_external_change); headless has neither a
    # keyboard nor that poll, so it re-reads both on a timer instead. A couple of seconds
    # keeps external edits feeling live without hammering the store — matching the OAST
    # poller's interval scale.
    RELOAD_POLL_INTERVAL = 2.seconds

    # Signals headless `gori run capture` winds down on, rather than dying from.
    CAPTURE_SIGNALS = [Signal::INT, Signal::TERM]

    # Signals the interactive TUI must not be killed by outright. A superset of
    # CAPTURE_SIGNALS by construction — every signal headless capture handles is handled
    # here too, and HUP is the one the TUI adds. HUP is TUI-only because only this path
    # leaves a terminal's line discipline altered: an SSH drop delivers HUP to a gori whose
    # tmux/screen session OUTLIVES it, so the pane is handed back in raw mode with the
    # alternate screen and SGR-1006 mouse reporting still on and only `reset` recovers it.
    # `gori run capture` never touched the tty, so its exit-on-HUP costs at most a partial
    # line — and trapping it there would silently turn a documented 129 into a 0.
    TUI_SIGNALS = CAPTURE_SIGNALS + [Signal::HUP]

    # Restores the terminal when a DELIVERED signal would otherwise kill the TUI outright.
    #
    # Why NOT run_capture's orderly `@shutdown` channel: that works there because capture's
    # MAIN fiber is already parked on `@shutdown.receive`, so the send wakes the very fiber
    # that owns the teardown. The TUI's main fiber is inside Runner's event loop, which App
    # holds no channel into, and a `Signal.trap` body runs on its OWN fiber — it cannot
    # unwind someone else's stack, so it can never reach `run_tui`'s `ensure term.close`.
    # An orderly handler here would therefore restore nothing AND not exit. So the handler
    # does the teardown itself and then dies FROM the signal under the default disposition,
    # which keeps the exit status the conventional 128+signo (143 TERM / 130 INT / 129 HUP)
    # that `pkill`, a wrapper script or a supervisor reads.
    #
    # Nothing else is torn down, deliberately. The store is SQLite in WAL mode (crash-safe —
    # the next open recovers) and the capture lock is a BSD flock the kernel frees when the
    # process dies (capture_lock.cr: "freed by the kernel on close / exit"), so neither needs
    # a store call from the signal fiber while the main fiber may be mid-write. A hang here
    # would be strictly worse than the bug: it turns "killed with a wrecked terminal" into
    # "not killed at all".
    #
    # `arm` and `die` are injected because both are process-global and unspeccable for real:
    # a trap installed by an example leaks into every later one, and the real `die` takes the
    # suite down with it. Production `arm` installs a ONE-SHOT trap — it resets the signal to
    # its default disposition BEFORE running the handler, so if `restore` ever hangs a second
    # `pkill` still kills us instead of finding gori unkillable short of SIGKILL.
    class SignalGuard
      REAL_ARM = ->(sig : Signal, handler : Proc(Nil)) do
        sig.trap do
          sig.reset
          handler.call
        end
      end

      # Never returns: a signal sent to self under the default disposition terminates the
      # process inside the `kill` syscall, before any further fiber can be scheduled.
      REAL_DIE = ->(sig : Signal) { Process.signal(sig, Process.pid) }

      def initialize(@restore : Proc(Nil),
                     @signals : Array(Signal) = TUI_SIGNALS,
                     @arm : Proc(Signal, Proc(Nil), Nil) = REAL_ARM,
                     @die : Proc(Signal, Nil) = REAL_DIE)
      end

      def install : Nil
        # One handler per signal, each closing over its OWN `sig`, so the process dies from
        # the signal it actually received and the exit status matches.
        @signals.each { |sig| @arm.call(sig, -> { fire(sig) }) }
      end

      private def fire(sig : Signal) : Nil
        begin
          @restore.call
        rescue
          # Best effort. The tty is already in the state this exists to prevent and there is
          # nowhere on a half-torn-down screen to report the failure — but exiting with the
          # right status still matters, so fall through to `die` rather than propagating
          # into the signal fiber.
        end
        @die.call(sig)
      end
    end

    def initialize(@config : Config)
      Paths.ensure_dirs
      @ca = Proxy::Tls::CertAuthority.load_or_create(@config.ca_dir)
      @registry = Verbs.registry
      @shutdown = Channel(Nil).new(1)
    end

    # Interactive TUI: pick a project, run its shell, return to the picker on
    # `q`, exit on quit. Logs go to a file (never STDOUT — that's the screen).
    #
    # `open_db_path`, when given (CLI `--db=PATH`), opens that database directly —
    # skipping the picker — before ever showing it; `q` from that session still
    # falls through to the normal picker below, so navigating elsewhere afterward
    # still works. `settings_warning` is anything Settings.load has to say about the
    # file it loaded: it was written to STDERR, which the alt screen is about to wipe.
    def run_tui(open_db_path : String? = nil, settings_warning : String? = nil) : Nil
      log_io = File.open(File.join(Paths.home_dir, "gori.log"), "a")
      setup_logging(log_io)
      Tui::Theme.load_custom           # register user themes from <GORI_HOME>/themes/*.json
      Tui::Theme.apply(Settings.theme) # honour the persisted theme from the first frame (picker included)
      projects = ProjectRegistry.new(Paths.projects_dir)
      # /dev/tty guard at the shared construction point: covers both this TUI and the
      # first-run wizard auto-launched below, so a no-tty run (CI/detached) gets a clean
      # message instead of a raw backtrace.
      term = Tui.open_terminal("run it directly, not under CI or a detached/background job, or use 'gori run capture' for non-interactive capture")
      # Termisu.new (just above) unconditionally runs its OWN `Log.setup("*", ...)`, aimed at
      # TERMISU_LOG_FILE (default /tmp/termisu.log, a shared, unbounded, non-project-scoped
      # file). Crystal's `Log.setup` always fully reconfigures the root logger (clears prior
      # bindings first), so whichever call runs LAST wins process-wide — Termisu's call would
      # otherwise silently swallow every subsequent `Log.*` call gori itself makes, including
      # the "failed to open session" error this TUI depends on landing in gori.log. Re-assert
      # gori's binding now that Termisu has had its say, so it's the one left standing
      # regardless of what Termisu does internally (same io — no new fd, no duplicate lines).
      setup_logging(log_io)

      begin
        # Armed FIRST, before anything else in this block: `open_terminal` above has ALREADY
        # switched the tty into raw mode and entered the alternate screen, so from here on the
        # terminal is only recoverable through `term.close` — and a DELIVERED signal never
        # reaches the `ensure` below, because the default disposition kills the process with
        # no stack unwind. Without this, `pkill gori` (or an SSH drop's SIGHUP) handed the
        # operator's pane back with ECHO/ICANON/ISIG/OPOST off, the alternate screen up and
        # mouse reporting on; only `reset` recovered it. See SignalGuard for why this restores
        # and re-raises instead of nudging a shutdown channel the way run_capture does.
        SignalGuard.new(-> { term.close; nil }).install
        # enable_* run INSIDE the begin so `ensure term.close` restores the tty if either
        # raises after open_terminal already switched it into raw mode (else the user's shell
        # is left in raw/no-echo).
        term.enable_enhanced_keyboard # Kitty 17u (disambig + report_text) for better IME/Unicode; avoids report_all_keys(31u) which can split Hangul jamo. Committed text via raw UTF-8 bytes (IME composed syllables) + CSI for specials; Preedit via 0-code CSI if terminal provides.
        if Settings.mouse
          term.enable_mouse     # SGR-1006 click + scroll-wheel nav; one enable covers both the picker and the runner (same term). Runner reconciles live on settings save; term.close disables on exit.
          Tui::MouseDrag.enable # mode 1002 on top: motion while a button is held, i.e. drag-to-select. Ours because termisu writes 1000+1006 only — see MouseDrag.
        end
        # DEC 2004. Unconditional and not a setting: without it a paste is indistinguishable
        # from typing, and on a terminal that maps the LF of a pasted CRLF to a second CR one
        # pasted line break arrives as CR CR — two Enters, a blank line after every pasted
        # line, and in the Repeater editor a head that ends right after the request line (no
        # Host → the origin answers 400). With it the terminal sends the clipboard bytes
        # verbatim between \e[200~ and \e[201~, which `Tui::PasteNewline` swallows. Terminals
        # that don't implement 2004 ignore the sequence and fall back to PasteNewline's pair
        # rule, so enabling it can only help. term.close disables it on exit.
        term.enable_bracketed_paste
        # First-run onboarding: no settings.json yet → walk the user through bind /
        # theme setup once. Inside `begin` so the `ensure term.close` restores
        # the terminal if it raises. The wizard persists settings.json (even on skip),
        # so it never auto-launches again.
        #
        # It stages `Settings.bind_host`/`bind_port` — the PERSISTED global, which a `-l`/`-p`
        # flag deliberately no longer touches (Settings.cli_bind_host). That separation is what
        # keeps the wizard from writing a one-run override into settings.json as the permanent
        # default, while this session still binds where the flag said.
        wizard_error = File.exists?(Settings.path) ? nil : Tui::SetupWizard.new(term).run
        # `notice` is the picker's one-line "here is why you are looking at this screen".
        # A failed open used to fall through to the picker in SILENCE, its reason reachable
        # only by knowing to read ~/.gori/gori.log, so an operator who typo'd `--db` saw
        # "no projects yet" and read it as "my capture is gone". Every `gori run` surface
        # already names this failure; the interactive one was the only one that did not.
        #
        # A corrupt settings.json starts on the row and a failed --db open then displaces
        # it, being the more immediate explanation of what is on screen. Neither is lost:
        # the settings warning also went to STDERR and names the `.corrupt` copy it kept.
        #
        # A failed wizard persist outranks both, and unlike the others it never touched STDERR —
        # the wizard hands it back precisely because its own screen was about to be wiped. It is
        # specifically the SKIP path's failure: a failed `finish` keeps the user on REVIEW to
        # retry, so what reaches here is "settings.json could not be materialised at all", whose
        # only other symptom is the wizard silently re-opening on every launch.
        notice = wizard_error.try { |e| "setup wizard: #{e}" } || settings_warning
        if open_db_path
          outcome, db_error = open_and_run(project_for_db_path(open_db_path), term)
          return if outcome == :quit
          notice = db_error || notice
        end
        loop do
          project = Tui::ProjectPicker.new(term, projects, notice: notice).run
          break unless project # nil => quit gori
          # Reassigned every pass: a picker-chosen project that won't open reports it the
          # same way, and a successful open clears the previous failure's notice.
          outcome, notice = open_and_run(project, term)
          break if outcome == :quit
        end
      ensure
        term.close # restore the terminal even on error
        # Disarm AFTER the close, not before: until `term.close` has actually run, the guard is
        # still the only thing standing between a delivered signal and a wrecked tty. Ordered
        # the other way there'd be a window where a signal mid-teardown left the terminal half
        # restored. What this closes is the window on the far side — the traps outliving the
        # terminal they capture, so a signal arriving during process teardown would re-close an
        # already-closed Termisu (harmless, the guard swallows it) and exit 143 instead of 0.
        TUI_SIGNALS.each(&.reset)
      end
    end

    # Wraps an explicit `--db` path as a one-off Project, bypassing the registry
    # entirely. Never ephemeral — Project#cleanup deletes ephemeral projects' dirs
    # on close, which must never happen to a file the user pointed us at directly.
    # Named after the containing directory for the conventional `gori.db` filename
    # (mirrors how registry projects are named after their dir), else after the
    # file's own basename.
    private def project_for_db_path(db_path : String) : Project
      base = File.basename(db_path)
      name = base == Project::DB_FILE ? File.basename(File.dirname(db_path)) : File.basename(db_path, File.extname(db_path))
      Project.new(name.presence || db_path, db_path)
    end

    # Non-interactive capture into `project`. Binds the proxy (fatal on failure, as
    # capture is the whole point here), streams one line per completed/errored flow
    # (`:text` = the legacy format, `:json` = JSON-Lines), and runs until INT/TERM,
    # an optional wall-clock `every` duration, or an optional completed-flow `max`.
    def run_capture(project : Project, format : Symbol, max : Int32?, every : Time::Span?) : Nil
      setup_logging(STDERR)
      session =
        begin
          Session.open(@config, @ca, @registry, project)
        rescue ex : DB::Error | SQLite3::Exception
          # Mirror the read-side commands: a --db that isn't a SQLite database (or is
          # unreadable) gets a clean error, not a raw DB::ConnectionRefused backtrace.
          abort "gori run capture: cannot open database #{project.db_path}: #{ex.message.presence || "not a valid SQLite database (or unreadable)"}"
        end
      if err = session.bind_error
        STDERR.puts "gori: not capturing — #{err}"
        STDERR.puts "  another gori instance may hold this project or the port; close it or pass --port."
        session.close
        exit 1
      end
      print_banner(session)
      spawn { capture_printer(session, format, max) }
      reload_stop = spawn_reload_loop(session)
      install_signal_traps
      if span = every
        # Wall-clock terminator: nudge the same shutdown channel the signal traps use.
        spawn do
          sleep span
          @shutdown.send(nil) rescue nil
        end
      end
      @shutdown.receive
      # Unbuffered: this rendezvous only completes once the reload fiber is parked back
      # at `select` (never mid-reload), so by the time it returns the fiber is guaranteed
      # to make no further store calls — safe to close the store right after.
      reload_stop.send(nil) rescue nil
      session.close
    end

    # `{outcome, error}`. `outcome` is :quit (leave gori) or :back (return to the picker);
    # `error` is a one-line reason and is non-nil ONLY when the session never opened, so the
    # caller can tell "the user pressed q" apart from "this project never opened" — both of
    # which are :back, and only one of which is worth putting on screen.
    private def open_and_run(project : Project, term : Termisu) : {Symbol, String?}
      # Pick up any bind address / verify-upstream toggle changed via Settings since startup
      # (the previous session kept its values; this one opens on the new ones). `startup_*`,
      # not the bare globals: a `-l`/`-p` flag lives in its own layer now, and dropping it here
      # would silently un-apply the override on the second project opened in a session.
      # Session.open then layers the project's own pin on top (effective_bind_*).
      @config.listen = Settings.startup_bind_host
      @config.port = Settings.startup_bind_port
      @config.insecure_upstream = !Settings.verify_upstream?
      session =
        begin
          # Interactive: auto-fall-back to a free port if the configured one is
          # taken (a 2nd gori instance), so capture just works on a new port.
          Session.open(@config, @ca, @registry, project, bind_fallback: true)
        rescue ex
          # A failed open must not crash the TUI with a backtrace into the alt-screen — log
          # it and fall back to the picker, WITH the reason (a silent fall-back reads as
          # "the project is empty"). Session.open already cleaned up any partially-opened
          # resources. Note this is not the port-taken path: the interactive open passes
          # bind_fallback and Session treats a failed bind as non-fatal (capture-off +
          # a toast), so what lands here is a store that could not be opened at all.
          Log.error(exception: ex) { "failed to open session for project '#{project.name}'" }
          return {:back, project.open_failure_reason(ex)}
        end
      begin
        runner = Tui::Runner.new(session, term)
        # Verify on but no CA trust store resolvable (e.g. a static musl build on a host
        # without a standard CA bundle): every HTTPS flow would fail upstream verification
        # (#323). Surface it once at startup — the per-flow error (#332) explains each failure,
        # this explains WHY up front.
        if Settings.verify_upstream? && (warning = Proxy::Upstream.trust_store_warning)
          runner.notifications.push(:warn, warning)
        end
        {runner.run, nil}
      ensure
        session.close
      end
    end

    private def capture_printer(session : Session, format : Symbol, max : Int32?) : Nil
      printed = 0
      seen = Set(Int64).new
      loop do
        event = session.flow_events.receive
        next unless event.kind == :updated # one line per completed/errored flow
        # A WebSocket flow (status 101) emits an :updated PER message on the SAME id;
        # print + count it ONCE (its first update), else it prints duplicate rows and
        # its own messages trip --max, tearing the live connection down mid-stream.
        next if seen.includes?(event.id)
        if row = session.store.flow_row(event.id)
          # Only WS re-emits :updated, so only WS ids need de-dup tracking — keeping
          # `seen` bounded by concurrent WS flows instead of growing per HTTP flow for
          # the lifetime of a long `gori run capture` session.
          seen << event.id if row.status == 101
          # Stream the SAME row rendering `gori run history` prints, so capture and
          # history output never drift (text = human-readable; json = stable contract).
          puts(format == :json ? CLI::Output.flow_row_json(row) : CLI::Output.flow_row_text(row))
          STDOUT.flush # stream each flow promptly even when piped (block-buffered)
          printed += 1
          if max && printed >= max
            @shutdown.send(nil) rescue nil # hit --max: ask the main fiber to wind down
            break
          end
        end
      end
    rescue Channel::ClosedError
      # events channel closed on shutdown — stop printing
    rescue DB::Error | SQLite3::Exception
      # Session#close closes the store BEFORE the events channel (writer-drain
      # order), so a buffered event can race in and query a now-closed DB. That's
      # a clean shutdown, not an error — stop quietly instead of crashing the fiber
      # (which would drop the final lines).
    rescue IO::Error
      # STDOUT pipe closed (e.g. `gori run capture | head`): the consumer is gone,
      # so there's nothing left to stream — wind the session down gracefully
      # instead of letting the unhandled error take down the whole process.
      @shutdown.send(nil) rescue nil
    end

    # Periodically re-reads Rewriter rules AND Scope from the store for the lifetime of a
    # headless capture session. Rewriter mirrors the TUI's manual `r` key (Rules#reload /
    # rewriter_controller#rewriter_reload); Scope mirrors the TUI's own data_version poll
    # (Runner#apply_external_change → Scope#reload) — headless has neither a keypress nor
    # that poll, so both ride the SAME timer/fiber here instead. One fiber, one stop
    # channel, both reloads per tick — no need to duplicate the fiber-management
    # boilerplate per object. Returns an unbuffered stop channel: sending to it blocks
    # until the loop is parked back at `select` (i.e. not mid-reload), so the caller can
    # safely close the session right after — no fiber left querying a closed store handle.
    private def spawn_reload_loop(session : Session) : Channel(Nil)
      stop = Channel(Nil).new
      spawn(name: "gori-capture-reload") do
        loop do
          select
          when stop.receive
            break
          when timeout(RELOAD_POLL_INTERVAL)
            # Each reload is guarded independently so a transient store hiccup on one
            # (or a bad regex/glob resurfacing as an exception) can't skip the other —
            # log and try both again next tick.
            begin
              session.rules.reload
            rescue ex
              Log.error(exception: ex) { "rewriter rule reload failed" }
            end
            begin
              session.scope.reload
            rescue ex
              Log.error(exception: ex) { "scope rule reload failed" }
            end
            begin
              # The per-project /etc/hosts is read on the SAME dial path as the two above and
              # is edited by the same external surfaces (`gori run project host-override`,
              # MCP add/update/delete_host_override), so it goes stale the same way.
              session.host_overrides.reload
            rescue ex
              Log.error(exception: ex) { "host override reload failed" }
            end
            # `session.colormarker` is DELIBERATELY absent from this loop, and adding it to
            # "complete the set" would be a regression. The three above each have a headless
            # consumer — rules rewrites bytes on the proxy path, scope gates the sandbox and
            # Probe, host_overrides steers the dial — while colour rules are read only by
            # History's renderer, and `gori run capture` draws no rows. Polling them here
            # would cost a settings read, a table read and N FilterAst parses every tick for a
            # value nothing in this process reads. The TUI reloads them in
            # `Runner#apply_external_change`; the CLI and MCP are one-shot processes that call
            # `Colormarker.merged(store)` statically and never build the engine at all.
          end
        end
      end
      stop
    end

    private def print_banner(session : Session) : Nil
      proxy = session.proxy
      upstream = @config.insecure_upstream? ? "insecure-upstream" : "verify-upstream"
      # The bind is what we CALL the listener; `addr` is what the user can actually type
      # into a client. Under a wildcard bind those differ — telling someone to point their
      # proxy at "0.0.0.0:8070" hands them a string no client can connect to.
      addr = BindAddress.display(proxy.host, proxy.port)
      STDERR.puts "gori #{VERSION} listening on #{addr} (#{upstream})"
      STDERR.puts "  root CA: #{@ca.ca_cert_path}"
      STDERR.puts "  trust the CA above, then point your client's HTTP+HTTPS proxy at #{addr}"
      STDERR.puts "  db: #{session.project.db_path}"
      # Upstream verification is on but no CA trust store resolved (e.g. a static musl build
      # on a host without a standard CA bundle) — every HTTPS flow would fail to verify (#323).
      if !@config.insecure_upstream? && (warning = Proxy::Upstream.trust_store_warning)
        STDERR.puts "  ⚠ #{warning}"
      end
      STDERR.puts "  press Ctrl-C to stop"
    end

    # Headless capture's orderly stop: the main fiber is parked on `@shutdown.receive`, so a
    # buffered send from the signal fiber wakes it and the normal teardown (reload fiber stop,
    # then session.close) runs on the real stack. The interactive TUI cannot use this shape —
    # see SignalGuard.
    private def install_signal_traps : Nil
      CAPTURE_SIGNALS.each { |sig| sig.trap { @shutdown.send(nil) rescue nil } }
    end

    private def setup_logging(io : IO) : Nil
      Log.setup(:info, Log::IOBackend.new(io))
    end
  end
end
