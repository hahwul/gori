require "log"
require "./config"
require "./paths"
require "./settings"
require "./project"
require "./project_registry"
require "./session"
require "./store"
require "./proxy/tls/cert_authority"
require "./verb"
require "./verbs/core"
require "./verbs/history"
require "./verbs/sitemap"
require "./verbs/findings"
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
      setup_logging(File.open(File.join(Paths.data_dir, "gori.log"), "a"))
      projects = ProjectRegistry.new(Paths.projects_dir)
      term = Termisu.new
      term.enable_enhanced_keyboard # Kitty 17u (disambig + report_text) for better IME/Unicode; avoids report_all_keys(31u) which can split Hangul jamo. Committed text via raw UTF-8 bytes (IME composed syllables) + CSI for specials; Preedit via 0-code CSI if terminal provides.

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

    # Headless capture into a single default project at --db (no picker).
    def run_headless : Nil
      setup_logging(STDERR)
      project = Project.new("default", @config.db_path)
      session = Session.open(@config, @ca, @registry, project)
      # Headless exists to capture, so a bind failure is fatal HERE (unlike the
      # TUI, which opens capture-off) — exit cleanly instead of running uselessly.
      if err = session.bind_error
        STDERR.puts "gori: cannot bind #{@config.listen}:#{@config.port} — #{err}"
        STDERR.puts "  another gori instance may be using this port; pass --port to choose another."
        session.close
        exit 1
      end
      print_banner(session)
      spawn { headless_printer(session) }
      install_signal_traps
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
          Session.open(@config, @ca, @registry, project)
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

    private def headless_printer(session : Session) : Nil
      loop do
        event = session.flow_events.receive
        next unless event.kind == :updated # one line per completed/errored flow
        if row = session.store.flow_row(event.id)
          puts format_row(row)
        end
      end
    rescue Channel::ClosedError
    end

    private def format_row(row : Store::FlowRow) : String
      status = row.status.try(&.to_s) || "---"
      "##{row.id} #{row.scheme} #{row.method} #{row.host} #{row.target} -> #{status} (#{row.size}b) [#{row.state}]"
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
