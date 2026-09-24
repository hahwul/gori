# `gori run shell` — a terminal whose tools go through a live gori and trust its CA (#1238).
#
# The terminal counterpart of the TUI's Open browser: nothing global changes, the proxy and
# trust variables live in one shell (or one command). The environment itself is built by
# `ShellEnv`; this file only finds the gori to point it at and hands the result to a shell.
module Gori
  module CLI
    module Run
      @[Subcommand("shell", help: [
        {"shell", "Open $SHELL (or run -- CMD) proxied through a live gori and trusting its CA"},
        {"shell --print", "Print the export lines instead: eval \"$(gori run shell --print)\""},
      ])]
      private def self.cmd_shell(args : Array(String)) : Nil
        project_name : String? = nil
        db_path : String? = nil
        proxy : String? = nil
        ca_dir : String? = nil
        print = false
        syntax_name : String? = nil
        keep_no_proxy = false
        before = [] of String
        command = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run shell [options] [-- CMD [ARGS...]]\n\n" \
                     "Start $SHELL (or run CMD and exit with its status) with the proxy variables pointed at\n" \
                     "a live gori and a CA bundle that trusts gori's root, so curl, git, Python, Go, Node and\n" \
                     "friends are captured without touching OS settings. The address comes from the gori\n" \
                     "capturing the project; nothing is live → it refuses, unless --proxy names one.\n\n" \
                     "  gori run shell                          # interactive, `exit` to leave\n" \
                     "  gori run shell -- curl https://target/  # one command\n" \
                     "  eval \"$(gori run shell --print)\"        # the shell you are already in\n"
          p.on("--project=NAME", "Point at the gori capturing project NAME (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Point at the gori capturing this SQLite db file") { |v| db_path = v }
          p.on("--proxy=HOST:PORT", "Use this proxy address instead of looking up a live capture") { |v| proxy = v }
          p.on("--ca-dir=DIR", "CA directory (default: the capturing gori's, else ~/.gori/ca)") { |v| ca_dir = v }
          p.on("--print", "Print export lines for eval instead of starting a shell") { print = true }
          p.on("--shell=SYNTAX", "Syntax for --print: sh (default; bash, zsh) | fish") { |v| syntax_name = v }
          p.on("--keep-no-proxy", "Keep the inherited NO_PROXY instead of unsetting it") { keep_no_proxy = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run shell: unknown option: #{f} (put the command after --: gori run shell -- CMD)\n#{p}" }
          p.missing_option { |f| abort "gori run shell: missing value for #{f}" }
          p.unknown_args do |b, a|
            before = b
            command = a
          end
        end
        parser.parse(args)
        if msg = shell_usage_error(before, command, print, syntax_name, proxy, project_name, db_path)
          abort msg
        end
        syntax = syntax_name.try { |n| ShellEnv::Syntax.parse?(n) } || ShellEnv::Syntax::Posix

        project = proxy ? nil : resolve_read_project(project_name, db_path)
        target = shell_target(project, proxy, ca_dir)
        abort target if target.is_a?(String)

        result =
          begin
            ShellEnv.build(target.authority, target.ca_cert_path, keep_no_proxy: keep_no_proxy)
          rescue ex : ShellEnv::Error
            abort "gori run shell: #{ex.message}"
          end

        if print
          (target.warnings + result.notes).each { |w| STDERR.puts "gori run shell: #{w}" }
          STDOUT.print ShellEnv.render(result, syntax, header: shell_print_header(result, target))
          return
        end
        exec_shell(command, result, target)
      end

      # Where the shell points, resolved: the dialable proxy authority, the root CA the
      # capturing gori signs with, what to call it, and anything the operator should hear.
      record ShellTarget, authority : String, ca_cert_path : String, label : String,
        warnings : Array(String)

      # The flag combinations that cannot mean anything, as one sentence (nil when fine) — split
      # from the abort so a spec can pin it, like `two_targets_error`.
      def self.shell_usage_error(before : Array(String), command : Array(String), print : Bool,
                                 syntax_name : String?, proxy : String?, project_name : String?,
                                 db_path : String?) : String?
        prefix = "gori run shell"
        unless before.empty?
          return "#{prefix}: unexpected argument#{before.size == 1 ? "" : "s"} #{before.join(" ").inspect} " \
                 "— put the command after --: gori run shell -- #{before.join(" ")}"
        end
        return "#{prefix}: --print prints the environment; it does not run a command" if print && !command.empty?
        if name = syntax_name
          return "#{prefix}: --shell only applies to --print" unless print
          return "#{prefix}: unknown --shell #{name.inspect} (expected sh or fish)" unless ShellEnv::Syntax.parse?(name)
        end
        if proxy && (project_name.try(&.presence) || db_path.try(&.presence))
          return "#{prefix}: pass --proxy HOST:PORT or --project/--db, not both " \
                 "(--proxy names the address directly, so the project would be ignored)"
        end
        two_targets_error(project_name, db_path, prefix)
      end

      # The gori to point at: `--proxy` as given, else the one capturing `project`. A String
      # is the refusal. `CaptureStatus` is read only while the capture lock is held — the lock is
      # what makes the marker authoritative (capture_status.cr), and the LIVE port can differ from
      # the configured one when gori fell back to another.
      def self.shell_target(project : Project?, proxy : String?, ca_dir : String?) : ShellTarget | String
        prefix = "gori run shell"
        default_ca = File.join(ca_dir || Paths.default_ca_dir, Proxy::Tls::CertAuthority::CA_CERT_FILE)
        return shell_proxy_target(proxy, default_ca, ca_dir) if proxy
        return "#{prefix}: no project to point at — pass --project NAME, --db PATH or --proxy HOST:PORT" unless project

        held = begin
          CaptureLock.held_at?(project.capture_lock_path)
        rescue ex
          return "#{prefix}: cannot check whether #{project.name} is being captured: #{ex.message}"
        end
        return shell_not_live(project) unless held
        # The lock is taken before the marker is first written, so a gori still starting holds
        # one without the other; the refusal below says to retry.
        status = CaptureStatus.read_at(project.capture_status_path)
        unless status
          return "#{prefix}: a gori holds #{project.name}'s capture lock but has not published its " \
                 "address (it may still be starting, or be an older gori) — retry, or pass --proxy HOST:PORT"
        end
        warnings = [] of String
        unless status.listening
          warnings << "capture is paused in #{project.name}, so the proxy refuses connections until it " \
                      "resumes (press c in gori)"
        end
        ca = ca_dir ? default_ca : (status.ca_cert_path || default_ca)
        return shell_ca_refusal(ca, ca_dir) unless File.file?(ca)
        ShellTarget.new(ShellEnv.dial_authority(status.host, status.port), ca,
          "#{project.name} on #{CaptureStatus.format_endpoint(status.host, status.port)}", warnings)
      end

      # `--proxy` as given: no capture is looked up, so the CA is `--ca-dir`'s or the default.
      private def self.shell_proxy_target(raw : String, ca : String, ca_dir : String?) : ShellTarget | String
        authority = shell_proxy_authority(raw)
        return "gori run shell: --proxy expects HOST:PORT (e.g. 127.0.0.1:8070), got #{raw.inspect}" unless authority
        return shell_ca_refusal(ca, ca_dir) unless File.file?(ca)
        ShellTarget.new(authority, ca, authority, [] of String)
      end

      # `--proxy`'s value as a dialable authority, or nil. `http://` is tolerated because that is
      # how the address is usually copied out of a proxy variable; a path, a query or credentials
      # are not an address.
      def self.shell_proxy_authority(value : String) : String?
        raw = value.strip
        raw = raw[7..] if raw.downcase.starts_with?("http://")
        raw = raw.rchop('/')
        return nil if raw.empty? || raw.includes?('/') || raw.includes?('@') || raw.includes?('?') || raw.includes?('#')
        uri = URI.parse("http://#{raw}")
        host = uri.host.presence
        port = uri.port
        return nil unless host && port && port.in?(1..65_535)
        ShellEnv.dial_authority(host, port)
      rescue URI::Error | ArgumentError
        nil
      end

      private def self.shell_ca_refusal(path : String, ca_dir : String?) : String
        "gori run shell: no gori CA certificate at #{path} — " +
          (ca_dir ? "check --ca-dir" : "start gori once to create it, or pass --ca-dir DIR")
      end

      # Nothing captures `project`. Names the projects that ARE live, since the usual cause is a
      # gori open on a different project than the one the default picked.
      private def self.shell_not_live(project : Project) : String
        live = [] of String
        begin
          ProjectRegistry.new(Paths.projects_dir).list.each do |p|
            next if p.db_path == project.db_path
            live << p.name if (CaptureLock.held_at?(p.capture_lock_path) rescue false)
            break if live.size >= 3
          end
        rescue
          # a registry that cannot be listed just loses the hint
        end
        hint = live.empty? ? "" : " (capturing now: #{live.join(", ")} — pass --project NAME)"
        "gori run shell: no gori is capturing #{project.name} — start gori (or gori run capture) " \
        "first, or pass --proxy HOST:PORT#{hint}"
      end

      # `--print`'s comment header: what was set, how to apply it, and what it cannot reach.
      def self.shell_print_header(result : ShellEnv::Result, target : ShellTarget) : Array(String)
        lines = [
          "gori shell environment — #{ShellEnv.sanitize_comment(target.label)}",
          "proxy #{ShellEnv.sanitize_comment(result.proxy_url)} · CA bundle #{ShellEnv.sanitize_comment(result.bundle_path)}",
          %(apply: eval "$(gori run shell --print)"  ·  fish: gori run shell --print --shell fish | source),
          "not covered:",
        ]
        ShellEnv::CAVEATS.each { |c| lines << "  #{c}" }
        lines
      end

      # Replace this process with the shell (or the command), so its exit status, its signals
      # and its job control are simply its own — nothing of gori is left running to relay them.
      private def self.exec_shell(command : Array(String), result : ShellEnv::Result, target : ShellTarget) : NoReturn
        (target.warnings + result.notes).each { |w| STDERR.puts "gori run shell: #{w}" }
        program, argv =
          if command.empty?
            STDERR.puts "gori shell · #{target.label} · proxy #{result.proxy_url}"
            STDERR.puts "  CA bundle #{result.bundle_path} · $#{ShellEnv::MARKER_VAR} is set · `exit` to leave"
            {login_shell, [] of String}
          else
            {command[0], command[1..]}
          end
        # Crystal's runtime ignores SIGPIPE for itself, and an ignored signal survives exec:
        # without this the shell and everything it starts inherit it, and `yes | head` prints
        # "Broken pipe" instead of ending quietly. Nothing of ours writes after the exec.
        Signal::PIPE.reset
        Process.exec(program, argv, env: result.to_env)
      rescue File::NotFoundError
        STDERR.puts "gori run shell: #{program}: command not found"
        exit 127
      rescue ex : File::Error | IO::Error
        STDERR.puts "gori run shell: cannot run #{program}: #{ex.message}"
        exit 126
      end

      # `$SHELL` when it names something runnable, else /bin/sh.
      def self.login_shell(env = ENV) : String
        path = env["SHELL"]?.try(&.strip).presence
        path && File.file?(path) && File::Info.executable?(path) ? path : "/bin/sh"
      end
    end
  end
end
