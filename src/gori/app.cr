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
    # still works.
    def run_tui(open_db_path : String? = nil) : Nil
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
        # enable_* run INSIDE the begin so `ensure term.close` restores the tty if either
        # raises after open_terminal already switched it into raw mode (else the user's shell
        # is left in raw/no-echo).
        term.enable_enhanced_keyboard       # Kitty 17u (disambig + report_text) for better IME/Unicode; avoids report_all_keys(31u) which can split Hangul jamo. Committed text via raw UTF-8 bytes (IME composed syllables) + CSI for specials; Preedit via 0-code CSI if terminal provides.
        term.enable_mouse if Settings.mouse # SGR-1006 click + scroll-wheel nav; one enable covers both the picker and the runner (same term). Runner reconciles live on settings save; term.close disables on exit.
        # First-run onboarding: no settings.json yet → walk the user through bind /
        # theme setup once. Inside `begin` so the `ensure term.close` restores
        # the terminal if it raises. The wizard persists settings.json (even on skip),
        # so it never auto-launches again.
        Tui::SetupWizard.new(term).run unless File.exists?(Settings.path)
        if open_db_path
          return if open_and_run(project_for_db_path(open_db_path), term) == :quit
        end
        loop do
          project = Tui::ProjectPicker.new(term, projects).run
          break unless project # nil => quit gori
          break if open_and_run(project, term) == :quit
        end
      ensure
        term.close # restore the terminal even on error
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

    private def open_and_run(project : Project, term : Termisu) : Symbol
      # Pick up any bind address / verify-upstream toggle changed via Settings since startup
      # (the previous session kept its values; this one opens on the new ones).
      @config.listen = Settings.bind_host
      @config.port = Settings.bind_port
      @config.insecure_upstream = !Settings.verify_upstream?
      session =
        begin
          # Interactive: auto-fall-back to a free port if the configured one is
          # taken (a 2nd gori instance), so capture just works on a new port.
          Session.open(@config, @ca, @registry, project, bind_fallback: true)
        rescue ex
          # A failed open (e.g. the proxy port is already in use) must not crash the
          # TUI with a backtrace into the alt-screen — log it and fall back to the
          # picker. Session.open already cleaned up any partially-opened resources.
          Log.error(exception: ex) { "failed to open session for project '#{project.name}'" }
          return :back
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
        runner.run
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

    private def install_signal_traps : Nil
      Signal::INT.trap { @shutdown.send(nil) rescue nil }
      Signal::TERM.trap { @shutdown.send(nil) rescue nil }
    end

    private def setup_logging(io : IO) : Nil
      Log.setup(:info, Log::IOBackend.new(io))
    end
  end
end
