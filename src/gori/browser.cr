require "./bind_address"

module Gori
  # Detect installed browsers and launch one pre-configured to trust gori's CA
  # and route through gori's proxy — the "open browser" feature Burp/Caido ship.
  #
  # Chromium-family browsers trust the CA without touching the system store: an
  # isolated `--user-data-dir` profile plus `--ignore-certificate-errors-spki-list`
  # pinned to the CA's SubjectPublicKeyInfo hash (so ONLY gori's CA is trusted for
  # that session, and the served chain now carries the root — see ContextFactory).
  # Firefox keeps its own trust store, so it gets a dedicated profile with proxy
  # prefs and, when `certutil` (NSS tools) is available, an import of the CA.
  module Browser
    enum Kind
      Chromium
      Firefox
    end

    # A browser found on this system, ready to launch.
    record Found, id : String, name : String, kind : Kind, path : String

    # Everything launch() needs, resolved by the caller from the live session.
    # `proxy_host` is the RAW bind, exactly as the session holds it — the resolution to
    # something a browser can dial happens here (see `dial_host`) so every launch path
    # gets it, rather than in each caller.
    record LaunchSpec,
      proxy_host : String,
      proxy_port : Int32,
      ca_cert_path : String,
      spki_sha256 : String,
      profile_root : String do
      # The proxy host to actually WRITE INTO the browser's config. Under a wildcard bind
      # the raw value is "0.0.0.0", and a browser pointed at http://0.0.0.0:port proxies
      # nothing — it opens, captures no traffic, and looks like gori is broken. Bare, so
      # Firefox's host-only pref gets no brackets.
      def dial_host : String
        BindAddress.dial_host(proxy_host)
      end

      # "host:port" for the places that need one string, with an IPv6 literal bracketed —
      # a `::1` bind interpolated bare yields the unparseable "::1:8070".
      def dial_authority : String
        BindAddress.authority(dial_host, proxy_port)
      end
    end

    # A candidate browser + where to look for it: absolute app binaries on macOS
    # (checked with File.exists?), bare command names on Linux (looked up on PATH).
    # A leading "~" expands to the home dir. First location that resolves wins.
    private record Candidate, id : String, name : String, kind : Kind, locations : Array(String)

    {% if flag?(:darwin) %}
      CANDIDATES = [
        Candidate.new("chrome", "Google Chrome", Kind::Chromium,
          ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
           "~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]),
        Candidate.new("chromium", "Chromium", Kind::Chromium,
          ["/Applications/Chromium.app/Contents/MacOS/Chromium",
           "~/Applications/Chromium.app/Contents/MacOS/Chromium"]),
        Candidate.new("brave", "Brave", Kind::Chromium,
          ["/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
           "~/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"]),
        Candidate.new("edge", "Microsoft Edge", Kind::Chromium,
          ["/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"]),
        Candidate.new("vivaldi", "Vivaldi", Kind::Chromium,
          ["/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"]),
        Candidate.new("firefox", "Firefox", Kind::Firefox,
          ["/Applications/Firefox.app/Contents/MacOS/firefox",
           "~/Applications/Firefox.app/Contents/MacOS/firefox"]),
      ]
    {% else %}
      CANDIDATES = [
        Candidate.new("chrome", "Google Chrome", Kind::Chromium, ["google-chrome", "google-chrome-stable"]),
        Candidate.new("chromium", "Chromium", Kind::Chromium, ["chromium", "chromium-browser"]),
        Candidate.new("brave", "Brave", Kind::Chromium, ["brave-browser", "brave"]),
        Candidate.new("edge", "Microsoft Edge", Kind::Chromium, ["microsoft-edge", "microsoft-edge-stable"]),
        Candidate.new("vivaldi", "Vivaldi", Kind::Chromium, ["vivaldi", "vivaldi-stable"]),
        Candidate.new("firefox", "Firefox", Kind::Firefox, ["firefox", "firefox-esr"]),
      ]
    {% end %}

    # Installed browsers, in preference order (empty when none are found).
    def self.detect : Array(Found)
      CANDIDATES.compact_map do |c|
        if path = c.locations.each.compact_map { |loc| resolve(loc) }.first?
          Found.new(c.id, c.name, c.kind, path)
        end
      end
    end

    # How long a freshly-spawned browser has to stay alive before the launch counts as
    # a success. `Process.new` only proves the *exec* worked; a browser that refuses to
    # start (a Chromium whose sandbox can't get a user namespace, a Windows .exe handed a
    # Linux `--user-data-dir`) exec's fine and is gone milliseconds later — every such
    # death lands well inside this window. Spent inside the key handler, so it is a
    # visible pause on the picker: deliberate, since a wrong "opened" costs the operator
    # a debugging session and this costs 0.4s.
    SPAWN_GRACE = 400.milliseconds

    # Cap on the browser's stderr we hold on to. Enough for the line that explains a
    # refusal, bounded because a LIVE Chromium narrates crashpad warnings for as long as
    # it runs and this buffer outlives the grace window.
    private STDERR_CAP = 4096

    # How long to wait for the dead browser's stderr to reach EOF before reporting what
    # was read by then. Only spent when a launch has already failed.
    private STDERR_SETTLE = 200.milliseconds

    # Launch `found` pre-trusted; returns a one-line status for the UI. Raises only
    # on a hard spawn failure. Creates the profile dir (and, for Firefox, writes
    # prefs + imports the CA) as a side effect.
    #
    # The status reports whether the browser is actually UP, not merely spawned: it used
    # to say "opened" the instant exec returned, so a browser that died on the spot was
    # announced as a success with its explanation discarded along with its stderr (#700).
    #
    # `grace` is injectable so specs need not race a deadline: a browser that really does
    # exit is reported the moment it does, whatever the window, so tests pass a generous
    # one and stay deterministic under any machine load.
    def self.launch(found : Found, spec : LaunchSpec, grace : Time::Span = SPAWN_GRACE) : String
      profile = File.join(spec.profile_root, found.id)
      Dir.mkdir_p(profile)
      # Firefox's profile has to be written BEFORE it is spawned — hence the setup call
      # sitting here, in the branch that also picks its args.
      args, note =
        case found.kind
        in Kind::Chromium then {chromium_args(profile, spec), "CA trusted, proxy → #{spec.dial_authority}"}
        in Kind::Firefox  then {firefox_args(profile), setup_firefox_profile(profile, spec)}
        end
      if failure = spawn_detached(found.path, args, grace)
        "#{found.name} #{failure}"
      else
        "opened #{found.name} — #{note}"
      end
    end

    # Chromium launch flags. Pinning the CA's SPKI trusts exactly gori's CA for the
    # session — safer than --ignore-certificate-errors, which trusts EVERY bad cert.
    # NOTE: recent Chrome added the spki-list flag to kBadFlags, so it now shows the
    # "unsupported command-line flag" infobar; --test-type is the only non-policy way
    # to suppress it (what Burp/Caido/Selenium use for an isolated MITM profile).
    # --disable-quic keeps traffic on the TCP CONNECT proxy (QUIC/UDP would bypass
    # it); the --disable-* trio + --no-pings cut Google background chatter that adds
    # latency and floods the flow list. "<-loopback>" un-bypasses loopback so
    # localhost targets are proxied too.
    def self.chromium_args(profile : String, spec : LaunchSpec) : Array(String)
      [
        "--user-data-dir=#{profile}",
        "--proxy-server=http://#{spec.dial_authority}",
        "--proxy-bypass-list=<-loopback>",
        "--ignore-certificate-errors-spki-list=#{spec.spki_sha256}",
        "--test-type",
        "--disable-quic",
        "--disable-component-update",
        "--disable-sync",
        "--disable-features=OptimizationHints,MediaRouter",
        "--no-pings",
        "--no-first-run",
        "--no-default-browser-check",
      ]
    end

    def self.firefox_args(profile : String) : Array(String)
      ["--no-remote", "--profile", profile]
    end

    # The proxy prefs Firefox reads from its profile's user.js (it ignores Chrome
    # flags). share_proxy_settings routes https through the same host:port.
    # These prefs take a BARE host (the port is its own pref), so they get `dial_host`
    # rather than `dial_authority` — brackets here would be parsed as part of the name.
    def self.firefox_user_js(spec : LaunchSpec) : String
      host = spec.dial_host
      String.build do |s|
        s << %(user_pref("network.proxy.type", 1);\n)
        s << %(user_pref("network.proxy.http", "#{host}");\n)
        s << %(user_pref("network.proxy.http_port", #{spec.proxy_port});\n)
        s << %(user_pref("network.proxy.ssl", "#{host}");\n)
        s << %(user_pref("network.proxy.ssl_port", #{spec.proxy_port});\n)
        s << %(user_pref("network.proxy.share_proxy_settings", true);\n)
        s << %(user_pref("network.proxy.no_proxies_on", "");\n)
        s << %(user_pref("browser.shell.checkDefaultBrowser", false);\n)
      end
    end

    # Whether Firefox's CA auto-import path is available on this system — exposed
    # so the picker can warn BEFORE launch rather than only via the post-launch
    # toast (which is easy to miss once focus jumps to the new browser window).
    def self.certutil_available? : Bool
      !Process.find_executable("certutil").nil?
    end

    # Writes proxy prefs and, when certutil exists, imports the CA into the
    # profile's NSS db (sql: creates cert9.db). Returns a status note.
    private def self.setup_firefox_profile(profile : String, spec : LaunchSpec) : String
      File.write(File.join(profile, "user.js"), firefox_user_js(spec))
      if certutil = Process.find_executable("certutil")
        import_firefox_ca(certutil, profile, spec.ca_cert_path) ? "CA imported, proxy set" : "proxy set (CA import failed)"
      else
        # No certutil → the CA can't be injected into Firefox's NSS store, so HTTPS sites
        # will show SEC_ERROR/cert warnings. Say so, not just "install certutil" — the
        # picker already warned before launch (see BrowserPicker), so repeat the concrete
        # fallback here too since that's the toast the user is actually looking at now.
        "proxy set — HTTPS will show cert errors; install certutil (nss), or in this Firefox window: about:preferences#privacy → View Certificates → Authorities → Import"
      end
    end

    private def self.import_firefox_ca(certutil : String, profile : String, ca_path : String) : Bool
      Process.run(certutil,
        ["-A", "-n", "gori Root CA", "-t", "C,,", "-i", ca_path, "-d", "sql:#{profile}"],
        output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    rescue
      false
    end

    # Start the browser without it touching gori's terminal, and reap it on a
    # detached fiber so a closed browser never becomes a zombie or blocks the UI.
    #
    # Returns nil once the browser is up, or the reason it isn't. stderr is piped rather
    # than closed: closing it threw away the browser's own account of why it quit, which
    # is the one thing that could explain a failed launch to the operator (#700).
    private def self.spawn_detached(path : String, args : Array(String), grace : Time::Span) : String?
      reader, writer = IO.pipe
      process =
        begin
          Process.new(path, args,
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: writer)
        rescue ex
          # `resolve` only proves the file EXISTS, so a non-executable browser binary
          # raises here. The caller turns that into a toast and the operator can pick the
          # same broken entry again — leak both ends and that is 2 fds per attempt.
          reader.close rescue nil
          writer.close rescue nil
          raise ex
        end
      writer.close # our copy; the child holds the only remaining one, so EOF means it died
      tail = StderrTail.new
      eof = Channel(Nil).new
      spawn { drain_stderr(reader, tail, eof) }
      # WAIT on the child rather than sample `terminated?` after a fixed sleep. That
      # predicate is `!exists?`, which only flips once Crystal has reaped the child, and
      # under load that hand-off outlasts the grace window — a browser that died in 1ms
      # was reported "opened" again, on exactly the slow machines #700 came from (five of
      # five failure-path specs flipped green-to-wrong under 8 CPU spinners). Waiting is
      # exact, and it returns the moment a browser refuses instead of always burning the
      # full window in the key handler. On timeout the wait fiber stays on to reap it.
      exited = Channel(Process::Status).new(1)
      spawn { exited.send(process.wait) rescue nil }
      status = select
      when s = exited.receive
        s
      when timeout(grace)
        nil
      end
      return nil if status.nil?
      # Exiting 0 inside the grace window is a LAUNCHER handing off, not a failure: the
      # `firefox` and packaged-Chrome entry points hand the URL to an already-running
      # instance and return. Only a non-zero exit is a browser that refused to start.
      return nil if status.success?
      # Wake on EOF rather than sleep a fixed settle: EOF means every writer is gone, so
      # `tail` holds everything the browser ever said. Bounded, because EOF may never come
      # — a Chromium zygote can outlive its parent still holding the write end.
      settled = select
      when eof.receive?
        true
      when timeout(STDERR_SETTLE)
        false
      end
      reason = failure_reason(tail.text, status)
      # Unblocks the drain fiber (its `read` raises) instead of stranding it and its fd.
      reader.close rescue nil
      # No EOF means something the browser left behind still holds its stderr, so we can
      # report what exited non-zero but not that nothing is running — a wrapper that
      # backgrounds the real browser and returns non-zero lands here too.
      settled ? "quit right after starting — #{reason}" : "may not have started — #{reason}"
    end

    # Read the child's stderr until it ends or the reader is closed under us. Draining is
    # not optional: stop reading and a chatty browser fills the pipe and blocks on its own
    # logging, so this runs for the browser's whole life on the success path.
    private def self.drain_stderr(reader : IO::FileDescriptor, tail : StderrTail, eof : Channel(Nil)) : Nil
      buf = Bytes.new(1024)
      while (n = reader.read(buf)) > 0
        tail << buf[0, n]
      end
    rescue
      # pipe torn down with the process, or closed by spawn_detached once it had enough
    ensure
      reader.close rescue nil
      eof.close # every writer is gone: `tail` is now the browser's complete account
    end

    # What the browser has written to stderr so far. Readable at any moment rather than
    # only at EOF: on the failure path EOF may never arrive, and what has been read by
    # then is the whole explanation the operator is ever going to get.
    private class StderrTail
      def initialize
        @buf = IO::Memory.new
        @mutex = Mutex.new
      end

      # Past the cap we keep reading and discard — a LIVE Chromium narrates crashpad
      # warnings for as long as it runs, and this buffer outlives the grace window.
      def <<(bytes : Bytes) : Nil
        @mutex.synchronize { @buf.write(bytes) if @buf.bytesize < STDERR_CAP }
      end

      def text : String
        @mutex.synchronize { @buf.to_s }
      end
    end

    # The toast for a browser that quit on the spot: its own first words if it left any,
    # and always how it died — which is what a bug report needs when stderr was silent.
    private def self.failure_reason(stderr : String, status : Process::Status) : String
      # `exit_code` RAISES on an abnormal exit, and this is exactly where those happen:
      # Chromium's sandbox refusal is a LOG(FATAL), i.e. an abort, so the browser dies on
      # a SIGNAL. Asking for its code there would trade the stderr line we came for
      # against a "browser launch failed: Abnormal exit has no exit code" toast (#700).
      how =
        if code = status.exit_code?
          "exit #{code}"
        elsif signal = status.exit_signal?
          "killed by #{signal}"
        else
          status.exit_reason.to_s
        end
      line = stderr.each_line.map { |l| toast_safe(l) }.find { |l| !l.empty? }
      line ? "#{line} (#{how})" : how
    end

    # Whole escape sequences, not just their ESC: dropping the ESC alone leaves a
    # colorized wrapper error reading "[31mred failure[0m" in the status row.
    private ANSI_SEQUENCE = /\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[@-Z\\-_]/

    # Browser stderr is arbitrary bytes headed for the TUI's status row: distro wrappers
    # colorize their errors, and a raw ESC written there corrupts the rest of the frame's
    # attributes. Drop invalid UTF-8 and control bytes, then cap it to a status-row length.
    private def self.toast_safe(line : String) : String
      # scrub first: gsub with a 1-byte needle over invalid UTF-8 corrupts the rest.
      cleaned = line.scrub("").gsub(ANSI_SEQUENCE, "").gsub { |c| c.control? ? "" : c }.strip
      cleaned.size > 160 ? "#{cleaned[0, 159]}…" : cleaned
    end

    # Resolve a candidate location to an existing executable path, or nil.
    private def self.resolve(loc : String) : String?
      if loc.starts_with?('/') || loc.starts_with?('~')
        path = loc.starts_with?('~') ? Path.home.join(loc[2..]).to_s : loc
        File.exists?(path) ? path : nil
      else
        Process.find_executable(loc)
      end
    end
  end
end
