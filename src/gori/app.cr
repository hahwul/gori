require "log"
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
require "./verbs/findings"
require "./verbs/comparer"
require "./tui"
require "./tui/runner"
require "./tui/project_picker"

module Gori
  # Top-level orchestrator. Owns the shared cert authority + verb registry and
  # process lifecycle. Each open project runs as a Session (its own store +
  # proxy). The TUI loops picker → session → shell; headless opens one default
  # session directly.
  class App
    getter config : Config
    getter ca : Proxy::Tls::CertAuthority
    getter registry : Verb::Registry

    def initialize(@config : Config)
      Paths.ensure_dirs
      @ca = Proxy::Tls::CertAuthority.load_or_create(@config.ca_dir)
      @registry = Verbs.registry
      @shutdown = Channel(Nil).new(1)
    end

    # Interactive TUI: pick a project, run its shell, return to the picker on
    # `q`, exit on quit. Logs go to a file (never STDOUT — that's the screen).
    def run_tui : Nil
      setup_logging(File.open(File.join(Paths.home_dir, "gori.log"), "a"))
      Tui::Theme.load_custom           # register user themes from <GORI_HOME>/themes/*.json
      Tui::Theme.apply(Settings.theme) # honour the persisted theme from the first frame (picker included)
      projects = ProjectRegistry.new(Paths.projects_dir)
      term = Termisu.new
      term.enable_enhanced_keyboard       # Kitty 17u (disambig + report_text) for better IME/Unicode; avoids report_all_keys(31u) which can split Hangul jamo. Committed text via raw UTF-8 bytes (IME composed syllables) + CSI for specials; Preedit via 0-code CSI if terminal provides.
      term.enable_mouse if Settings.mouse # SGR-1006 click + scroll-wheel nav; one enable covers both the picker and the runner (same term). Runner reconciles live on settings save; term.close disables on exit.

      begin
        loop do
          project = Tui::ProjectPicker.new(term, projects).run
          break unless project # nil => quit gori
          break if open_and_run(project, term) == :quit
        end
      ensure
        term.close # restore the terminal even on error
      end
    end

    # Legacy `--headless`: capture into a single default project at --db, text
    # output, runs until INT/TERM. A thin wrapper over the shared capture engine so
    # `gori run capture` and `--headless` can never drift.
    def run_headless : Nil
      run_capture(Project.new("default", @config.db_path), format: :text, max: nil, every: nil)
    end

    # Non-interactive capture into `project`. Binds the proxy (fatal on failure, as
    # capture is the whole point here), streams one line per completed/errored flow
    # (`:text` = the legacy format, `:json` = JSON-Lines), and runs until INT/TERM,
    # an optional wall-clock `every` duration, or an optional completed-flow `max`.
    def run_capture(project : Project, format : Symbol, max : Int32?, every : Time::Span?) : Nil
      setup_logging(STDERR)
      session = Session.open(@config, @ca, @registry, project)
      if err = session.bind_error
        STDERR.puts "gori: not capturing — #{err}"
        STDERR.puts "  another gori instance may hold this project or the port; close it or pass --port."
        session.close
        exit 1
      end
      print_banner(session)
      spawn { capture_printer(session, format, max) }
      install_signal_traps
      if span = every
        # Wall-clock terminator: nudge the same shutdown channel the signal traps use.
        spawn do
          sleep span
          @shutdown.send(nil) rescue nil
        end
      end
      @shutdown.receive
      session.close
    end

    private def open_and_run(project : Project, term : Termisu) : Symbol
      # Pick up any bind address changed via Settings since startup (the previous
      # session kept its bind; this one opens on the new one).
      @config.listen = Settings.bind_host
      @config.port = Settings.bind_port
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
        Tui::Runner.new(session, term).run
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
        # A streaming flow (WebSocket, HTTP/2, SSE) emits an :updated PER message /
        # frame on the SAME id. Print + count it ONCE (its first update), else it
        # prints duplicate rows and its own messages trip --max, tearing the live
        # connection down mid-stream.
        next if seen.includes?(event.id)
        if row = session.store.flow_row(event.id)
          seen << event.id
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

    private def print_banner(session : Session) : Nil
      proxy = session.proxy
      upstream = @config.insecure_upstream? ? "insecure-upstream" : "verify-upstream"
      STDERR.puts "gori #{VERSION} listening on #{proxy.host}:#{proxy.port} (#{upstream})"
      STDERR.puts "  root CA: #{@ca.ca_cert_path}"
      STDERR.puts "  trust the CA above, then point your client's HTTP+HTTPS proxy at #{proxy.host}:#{proxy.port}"
      STDERR.puts "  db: #{session.project.db_path}"
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
