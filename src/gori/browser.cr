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
    record LaunchSpec,
      proxy_host : String,
      proxy_port : Int32,
      ca_cert_path : String,
      spki_sha256 : String,
      profile_root : String

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

    # Launch `found` pre-trusted; returns a one-line status for the UI. Raises only
    # on a hard spawn failure. Creates the profile dir (and, for Firefox, writes
    # prefs + imports the CA) as a side effect.
    def self.launch(found : Found, spec : LaunchSpec) : String
      profile = File.join(spec.profile_root, found.id)
      Dir.mkdir_p(profile)
      case found.kind
      in Kind::Chromium
        spawn_detached(found.path, chromium_args(profile, spec))
        "opened #{found.name} — CA trusted, proxy → #{spec.proxy_host}:#{spec.proxy_port}"
      in Kind::Firefox
        note = setup_firefox_profile(profile, spec)
        spawn_detached(found.path, firefox_args(profile))
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
        "--proxy-server=http://#{spec.proxy_host}:#{spec.proxy_port}",
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
    def self.firefox_user_js(spec : LaunchSpec) : String
      String.build do |s|
        s << %(user_pref("network.proxy.type", 1);\n)
        s << %(user_pref("network.proxy.http", "#{spec.proxy_host}");\n)
        s << %(user_pref("network.proxy.http_port", #{spec.proxy_port});\n)
        s << %(user_pref("network.proxy.ssl", "#{spec.proxy_host}");\n)
        s << %(user_pref("network.proxy.ssl_port", #{spec.proxy_port});\n)
        s << %(user_pref("network.proxy.share_proxy_settings", true);\n)
        s << %(user_pref("network.proxy.no_proxies_on", "");\n)
        s << %(user_pref("browser.shell.checkDefaultBrowser", false);\n)
      end
    end

    # Writes proxy prefs and, when certutil exists, imports the CA into the
    # profile's NSS db (sql: creates cert9.db). Returns a status note.
    private def self.setup_firefox_profile(profile : String, spec : LaunchSpec) : String
      File.write(File.join(profile, "user.js"), firefox_user_js(spec))
      if certutil = Process.find_executable("certutil")
        import_firefox_ca(certutil, profile, spec.ca_cert_path) ? "CA imported, proxy set" : "proxy set (CA import failed)"
      else
        "proxy set — install certutil (nss) to auto-trust the CA"
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
    private def self.spawn_detached(path : String, args : Array(String)) : Nil
      process = Process.new(path, args,
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      spawn { process.wait rescue nil }
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
