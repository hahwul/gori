# `gori run browser` — the TUI's Open browser from a script, with an opt-in DevTools port so a
# browser-automation MCP server can drive it while gori captures it (#1594).
#
# The launch is `Browser.start`'s; this file finds the gori to point it at (the resolver
# `gori run shell` uses) and stays in the foreground for as long as the browser runs, so a
# DevTools port never outlives the command that opened it.
module Gori
  module CLI
    module Run
      @[Subcommand("browser", help: [
        {"browser", "Open a browser through a live gori trusting only its CA (opt-in CDP port for automation)"},
      ])]
      private def self.cmd_browser(args : Array(String)) : Nil
        project_name : String? = nil
        db_path : String? = nil
        proxy : String? = nil
        ca_dir : String? = nil
        browser_id : String? = nil
        port_arg : String? = nil
        extra = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run browser [options]\n\n" \
                     "Open a browser routed through a live gori and trusting only its CA, the same profile\n" \
                     "the TUI's Open browser uses. It stays in the foreground until the browser exits;\n" \
                     "Ctrl-C closes it. The address comes from the gori capturing the project; nothing is\n" \
                     "live → it refuses, unless --proxy names one.\n\n" \
                     "  gori run browser\n" \
                     "  gori run browser --remote-debugging-port 9222   # then: --cdp-endpoint http://127.0.0.1:9222\n"
          p.on("--project=NAME", "Point at the gori capturing project NAME (#{DEFAULT_PROJECT_HELP})") { |v| project_name = v }
          p.on("--db=PATH", "Point at the gori capturing this SQLite db file") { |v| db_path = v }
          p.on("--proxy=HOST:PORT", "Use this proxy address instead of looking up a live capture") { |v| proxy = v }
          p.on("--ca-dir=DIR", "CA directory (default: the capturing gori's, else ~/.gori/ca)") { |v| ca_dir = v }
          p.on("--browser=ID", "Browser to open (default: the first detected)") { |v| browser_id = v }
          p.on("--remote-debugging-port=N", "Open a loopback DevTools (CDP) port; 0 lets the browser pick. Any local process can drive it") { |v| port_arg = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort CLI.unknown_option_message("gori run browser", f, p) }
          p.missing_option { |f| abort "gori run browser: missing value for #{f}" }
          p.unknown_args { |b, a| extra = b + a }
        end
        parser.parse(args)
        prefix = "gori run browser"
        abort "#{prefix}: unexpected argument #{extra.join(" ").inspect}" unless extra.empty?
        if msg = target_flags_error(prefix, proxy, project_name, db_path)
          abort msg
        end
        cdp = port_arg.try { |v| debugging_port(prefix, v) }
        found = browser_choice(Browser.detect, browser_id, cdp)
        abort "#{prefix}: #{found}" if found.is_a?(String)

        project = proxy ? nil : resolve_read_project(project_name, db_path)
        target = capture_target(project, proxy, ca_dir, "browser")
        abort target if target.is_a?(String)
        target.warnings.each { |w| STDERR.puts "#{prefix}: #{w}" }

        # Trapped before the launch, which can wait up to `Browser::ENDPOINT_WAIT`: a SIGTERM
        # landing then must still close the browser rather than orphan its DevTools port.
        running : Browser::Running? = nil
        interrupted = install_interrupt_trap("browser-interrupt", "closing #{found.name}…") do
          running.try { |r| r.process.terminate rescue nil }
        end
        started = start_browser(prefix, found, target, cdp)
        running = started.running
        # Interrupted while the launch was still waiting: the trap found nothing to close yet.
        running.try { |r| r.process.terminate rescue nil } if interrupted.call
        status = hold_browser(found, target, started)
        Run.report_interrupted(1, "browser", "closed") if interrupted.call
        exit(status.try(&.exit_code?) || 0)
      end

      private def self.debugging_port(prefix : String, value : String) : Int32
        value.to_i?.try { |n| n if n.in?(0..65_535) } ||
          abort "#{prefix}: --remote-debugging-port expects 0-65535, got #{value.inspect}"
      end

      # Launch `found` pinned to the target's CA (from the cert file alone, so it matches the pin
      # the TUI computes from the loaded CA), or abort with the reason it is not up.
      private def self.start_browser(prefix : String, found : Browser::Found, target : CaptureTarget,
                                     cdp : Int32?) : Browser::Started
        spki = Proxy::Tls::Cert.read_pem(target.ca_cert_path).spki_sha256_base64
        started = Browser.start(found, Browser::LaunchSpec.new(
          proxy_host: target.host, proxy_port: target.port, ca_cert_path: target.ca_cert_path,
          spki_sha256: spki, profile_root: Browser.default_profile_root, remote_debugging_port: cdp))
        abort "#{prefix}: #{started.status}" unless started.ok
        started
      rescue ex
        abort "#{prefix}: #{ex.message}"
      end

      # Stay in the foreground until the browser exits, closing it on Ctrl-C: a DevTools port
      # must not outlive the command that opened it, and the stderr pipe `Browser` drains must
      # not close under a live browser.
      private def self.hold_browser(found : Browser::Found, target : CaptureTarget,
                                    started : Browser::Started) : Process::Status?
        unless running = started.running
          # A launcher that handed off to an instance already open: that window is not ours to
          # wait on, and it keeps the proxy it was started with, which may not be this one.
          STDERR.puts "gori run browser: #{found.name} was already open on this profile and took the " \
                      "launch as a new window; it keeps the proxy it was started with, not necessarily " \
                      "#{target.authority} — close it and retry to be sure"
          return
        end
        STDERR.puts "gori browser · #{found.name} · #{target.label} · proxy #{target.authority}"
        if endpoint = started.endpoint
          STDERR.puts "  DevTools #{endpoint} — any local process can drive this browser"
          STDERR.puts "  Playwright MCP: --cdp-endpoint #{endpoint} · chrome-devtools-mcp: --browserUrl #{endpoint}"
        end
        STDERR.puts "  Ctrl-C closes it"
        running.exited.receive?
      end

      # The browser to open: `--browser ID` among the detected ones, else the first detected —
      # the first Chromium-based one when a DevTools port is wanted, since Firefox has none.
      # A String is the refusal.
      def self.browser_choice(detected : Array(Browser::Found), id : String?, cdp : Int32?) : Browser::Found | String
        return "no supported browser found (Chrome, Chromium, Brave, Edge, Vivaldi or Firefox)" if detected.empty?
        if id
          return detected.find { |b| b.id == id } ||
            "no browser #{id.inspect} found (detected: #{detected.join(", ", &.id)})"
        end
        (cdp ? detected.find(&.kind.chromium?) : detected.first?) ||
          "--remote-debugging-port needs a Chromium-based browser (detected: #{detected.join(", ", &.id)})"
      end
    end
  end
end
