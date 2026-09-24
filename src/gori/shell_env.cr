require "digest/sha256"
require "./bind_address"
require "./durable_file"
require "./paths"
require "./shell_env/marker"
require "./proxy/upstream"

module Gori
  # The environment of a terminal whose tools go through gori's proxy and trust its CA — the
  # terminal counterpart of `Browser` (#1238). Nothing global changes: the variables live in
  # one shell (or one command), and the only file written is a CA bundle under
  # `Paths.shell_dir`.
  #
  # Most of the trust variables REPLACE a tool's trust store rather than add to it, so pointing
  # them at gori's root alone would break every host gori does not intercept (a passthrough
  # host, anything with NO_PROXY). They get a combined bundle instead: the store the terminal
  # already trusted, plus gori's root. Only `NODE_EXTRA_CA_CERTS` is additive.
  #
  # Which tool reads which variable comes from each tool's own documentation, re-checked for
  # #1238; `CAVEATS` is what the variables cannot reach.
  module ShellEnv
    class Error < Gori::Error
    end

    # curl reads only the lowercase `http_proxy` (httpoxy); Go, requests and most others read
    # the uppercase pair. `ALL_PROXY` is left alone: every tool here prefers the scheme
    # variables, and curl would send its non-HTTP schemes to an HTTP proxy through it.
    PROXY_VARS = %w[http_proxy https_proxy HTTP_PROXY HTTPS_PROXY]

    # Unset by default, the way the browser launch un-bypasses loopback: a shell pointed at
    # gori should capture the local app under test too.
    NO_PROXY_VARS = %w[NO_PROXY no_proxy]

    # Each of these REPLACES the reading tool's trust store, so each gets the combined bundle:
    # SSL_CERT_FILE (OpenSSL-linked tools, Ruby, Python `ssl`, Go), CURL_CA_BUNDLE (curl,
    # requests), REQUESTS_CA_BUNDLE (requests, pip), GIT_SSL_CAINFO (git), AWS_CA_BUNDLE (AWS
    # CLI/SDKs), PIP_CERT (pip), CARGO_HTTP_CAINFO (cargo), DENO_CERT (deno — additive there,
    # so the bundle is merely redundant).
    BUNDLE_VARS = %w[SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE GIT_SSL_CAINFO AWS_CA_BUNDLE
      PIP_CERT CARGO_HTTP_CAINFO DENO_CERT]

    # Node APPENDS these to its bundled roots, so gori's root alone is enough — unless the
    # terminal already set it, in which case the two are combined (Node reads only one file).
    NODE_EXTRA_VAR = "NODE_EXTRA_CA_CERTS"

    # Node honours HTTP(S)_PROXY only with this set (stable in v22.21 and v24.10). Harmless to a
    # Node that predates it.
    NODE_PROXY_VAR = "NODE_USE_ENV_PROXY"

    # Go 1.27 honours SSL_CERT_FILE on macOS and Windows too, but only for a module whose go.mod
    # says `go 1.27` or later: an older `go` line keeps the platform verifier by default, and a
    # program built by today's toolchain from yesterday's go.mod ignores the bundle. Measured on
    # macOS with Go 1.27.1: `go 1.22` → "certificate signed by unknown authority", the same
    # binary with this setting → 200. Merged into an inherited GODEBUG, never over an explicit
    # choice of the same key. Unknown to an older Go, which ignores it, and inert on Linux.
    GODEBUG_VAR     = "GODEBUG"
    GODEBUG_SETTING = "x509sslcertoverrideplatform"

    # What the variables cannot do, stated rather than engineered around. Printed as the
    # `--print` header and in the docs.
    CAVEATS = [
      "Go on macOS built with a toolchain before 1.27 verifies through the keychain and ignores SSL_CERT_FILE.",
      "Go never proxies localhost or loopback addresses, whatever NO_PROXY says.",
      "Node uses the proxy only in releases that support NODE_USE_ENV_PROXY (stable in v22.21 and v24.10).",
      "Java needs a truststore via JAVA_TOOL_OPTIONS, which is not set here.",
      "Tools that pin their own trust store (certifi-only libraries, pinned SDKs) are not covered.",
    ]

    enum Syntax
      Posix
      Fish

      # The `--shell` spellings. Every POSIX-family name maps to one syntax: they all read
      # `export NAME='value'` / `unset NAME` the same way.
      def self.parse?(name : String) : Syntax?
        case name.strip.downcase
        when "sh", "posix", "bash", "zsh", "ksh", "dash" then Posix
        when "fish"                                      then Fish
        end
      end

      # The syntax for a `$SHELL` path, for a surface with no flag to ask (the TUI's copy).
      def self.for_shell(path : String?) : Syntax
        File.basename(path.to_s) == "fish" ? Fish : Posix
      end
    end

    # The variables in apply order — a value to export, or nil to unset — plus what the header
    # and a banner name. `notes` are the non-fatal things the build worked around.
    record Result,
      vars : Array({String, String?}),
      proxy_url : String,
      bundle_path : String,
      notes : Array(String) do
      # The `env:` argument for `Process.exec` / `Process.run`, where nil unsets.
      def to_env : Hash(String, String?)
        vars.to_h
      end
    end

    # The authority a client on this machine dials to reach a proxy bound to `host` — the
    # wildcard-to-loopback resolution `Browser::LaunchSpec#dial_authority` makes, for the same
    # reason: `http_proxy=http://0.0.0.0:8070` proxies nothing.
    def self.dial_authority(host : String, port : Int32) : String
      BindAddress.authority(BindAddress.dial_host(host), port)
    end

    # Why `ca_cert_path` cannot anchor a shell's trust, or nil. `build` refuses on it; a caller
    # that hands the build to another process (the TUI's Open shell) asks it first, so the
    # refusal is a message it can show rather than one printed to a screen about to repaint.
    def self.ca_problem(ca_cert_path : String) : String?
      root = load_root(ca_cert_path)
      root.is_a?(String) ? root : nil
    end

    # gori's root as `{pem, body}` (see `cert_body`), or why it cannot be used.
    private def self.load_root(ca_cert_path : String) : {String, String} | String
      path = File.expand_path(ca_cert_path)
      pem = read_pem?(path)
      return "cannot read gori's CA certificate at #{path}" unless pem
      body = cert_body(pem)
      return "no PEM certificate in #{path}" unless body
      {pem, body}
    end

    # Resolve the environment for a proxy at `authority` (already dialable, see
    # `dial_authority`) and the gori root at `ca_cert_path`. Pure apart from writing the
    # bundle(s) under `dir`. Raises `Error` when the CA cannot be read.
    #
    # `env` is the environment being inherited. What it had set before any gori shell decides
    # each bundle's base (an enterprise `SSL_CERT_FILE`, a tool's own CA variable), whether
    # `NODE_EXTRA_CA_CERTS` needs combining, and the `GORI_SHELL_ORIG_*` record.
    def self.build(authority : String, ca_cert_path : String, *,
                   env : Hash(String, String) = ENV.to_h,
                   keep_no_proxy : Bool = false,
                   dir : String = Paths.shell_dir,
                   system_source : {String?, String?} = Proxy::Upstream.resolve_ca_source) : Result
      root = load_root(ca_cert_path)
      raise Error.new(root) if root.is_a?(String)
      root_pem, root_body = root
      root_path = File.expand_path(ca_cert_path)

      notes = [] of String
      ssl_pre = trust_pre_shell("SSL_CERT_FILE", env)
      base_path, base_text = trust_base(ssl_pre, system_source, notes)
      bundle = trust_file(base_path, base_text, root_pem, root_body, "ca-bundle", dir)
      # A variable the terminal set on its own — a company CA handed to requests or git alone —
      # keeps what it named: it gets its own base plus gori's root rather than the shared bundle,
      # which would silently drop it.
      bundles = {} of String => String
      BUNDLE_VARS.each do |name|
        pre = trust_pre_shell(name, env)
        bundles[name] =
          if pre.nil? || pre == ssl_pre
            bundle
          elsif text = read_pem?(pre)
            trust_file(pre, text, root_pem, root_body, "ca-bundle", dir)
          else
            notes << "$#{name} (#{pre}) is unreadable, so it gets the shared bundle"
            bundle
          end
      end

      node_extra = root_path
      if inherited = trust_pre_shell(NODE_EXTRA_VAR, env)
        if text = read_pem?(inherited)
          node_extra = trust_file(inherited, text, root_pem, root_body, "node-extra", dir)
        else
          notes << "$#{NODE_EXTRA_VAR} (#{inherited}) is unreadable, so Node gets gori's root alone"
        end
      end

      proxy = "http://#{authority}"
      vars = [{MARKER_VAR, "1"}, {PROXY_VAR, authority}] of {String, String?}
      PROXY_VARS.each { |name| vars << {name, proxy} }
      if keep_no_proxy
        if env[MARKER_VAR]? == "1"
          NO_PROXY_VARS.each do |name|
            if val = env["#{ORIG_PREFIX}#{name}"]?.try(&.strip).presence || env[name]?.try(&.strip).presence
              vars << {name, val}
            end
          end
        end
      else
        NO_PROXY_VARS.each { |name| vars << {name, nil} }
      end
      vars << {NODE_PROXY_VAR, "1"}
      BUNDLE_VARS.each { |name| vars << {name, bundles[name]} }
      vars << {NODE_EXTRA_VAR, node_extra}
      if godebug = godebug_value(env[GODEBUG_VAR]?)
        vars << {GODEBUG_VAR, godebug}
      end
      vars.concat(originals(env, keep_no_proxy))
      Result.new(vars, proxy, bundle, notes)
    end

    # `GORI_SHELL_ORIG_<NAME>` for every variable the shell replaces or unsets that the terminal
    # had set (see `ORIG_PREFIX`). Inside a gori shell these are re-exported as they were, so the
    # record always describes the terminal before the FIRST shell.
    private def self.originals(env : Hash(String, String), keep_no_proxy : Bool) : Array({String, String?})
      found = [] of {String, String?}
      in_shell = env[MARKER_VAR]? == "1"
      PROXY_VARS.each do |name|
        if value = inherited_proxy(name, env)
          found << {"#{ORIG_PREFIX}#{name}", value}
        end
      end
      NO_PROXY_VARS.each do |name|
        if in_shell
          if value = env["#{ORIG_PREFIX}#{name}"]?.try(&.strip).presence
            found << {"#{ORIG_PREFIX}#{name}", value}
          end
        elsif !keep_no_proxy
          if value = inherited_proxy(name, env)
            found << {"#{ORIG_PREFIX}#{name}", value}
          end
        end
      end
      (BUNDLE_VARS + [NODE_EXTRA_VAR]).each do |name|
        if value = trust_pre_shell(name, env)
          found << {"#{ORIG_PREFIX}#{name}", value}
        end
      end
      found
    end

    # A trust variable as the terminal had it before any gori shell. Inside one, the live value
    # is the outer shell's bundle — starting from it would keep trusting the OUTER gori's root
    # too, one more MITM root per nesting — so the recorded original is the answer, and none
    # means the terminal never set it.
    private def self.trust_pre_shell(name : String, env : Hash(String, String)) : String?
      key = env[MARKER_VAR]? == "1" ? "#{ORIG_PREFIX}#{name}" : name
      env[key]?.try(&.strip).presence
    end

    # The GODEBUG to export, or nil to leave the inherited one untouched (it already decides
    # this key).
    private def self.godebug_value(inherited : String?) : String?
      setting = "#{GODEBUG_SETTING}=1"
      current = inherited.try(&.strip).presence
      return setting unless current
      return nil if current.split(',').any?(&.strip.starts_with?("#{GODEBUG_SETTING}="))
      "#{current},#{setting}"
    end

    # Control characters (ASCII < 0x20 and 0x7f) are replaced with a space so that
    # text interpolated into shell comments cannot break out of `#` or emit terminal escapes.
    def self.sanitize_comment(text : String) : String
      text.gsub(/[\x00-\x1f\x7f]/, " ")
    end

    # `result` as lines a shell evaluates: `eval "$(…)"` for POSIX shells, `… | source` for
    # fish. `header` prefixes the caveats as comments — off for text that is PASTED, since an
    # interactive zsh without INTERACTIVE_COMMENTS runs `#` as a command.
    def self.render(result : Result, syntax : Syntax, *, header : Array(String) = [] of String) : String
      String.build do |s|
        header.each { |line| s << "# " << sanitize_comment(line) << '\n' }
        result.vars.each do |name, value|
          case syntax
          in Syntax::Posix
            value ? (s << "export " << name << '=' << posix_quote(value)) : (s << "unset " << name)
          in Syntax::Fish
            value ? (s << "set -gx " << name << ' ' << fish_quote(value)) : (s << "set -e " << name)
          end
          s << '\n'
        end
      end
    end

    # Single quotes take everything literally in a POSIX shell; a quote inside is closed,
    # escaped and reopened.
    def self.posix_quote(value : String) : String
      "'#{value.gsub("'", %('\\''))}'"
    end

    # fish single quotes honour exactly two escapes: `\'` and `\\`.
    def self.fish_quote(value : String) : String
      "'#{value.gsub('\\', "\\\\").gsub('\'', "\\'")}'"
    end

    # The store this terminal trusted before gori: the operator's own `SSL_CERT_FILE` (as it was
    # before any gori shell) when it names a readable bundle (an enterprise one), otherwise the OS roots. `{path, text}`, with
    # path nil when the text was assembled from a directory.
    private def self.trust_base(inherited : String?, system_source : {String?, String?},
                                notes : Array(String)) : {String?, String}
      if inherited
        if text = read_pem?(inherited)
          return {inherited, text}
        end
        notes << "$SSL_CERT_FILE (#{inherited}) is unreadable, so the bundle starts from the system roots"
      end
      file, cert_dir = system_source
      if file && (text = read_pem?(file))
        return {file, text}
      end
      if cert_dir && (text = dir_bundle(cert_dir))
        return {nil, text}
      end
      notes << "no system CA bundle found, so this shell trusts only gori's CA — a host gori does not " \
               "intercept fails TLS verification"
      {nil, ""}
    end

    # The file to point a variable at: `base_path` itself when it already trusts gori's root (a
    # system store the CA was installed into), else a new bundle of `base_text` plus the root.
    #
    # Named by the hash of its CONTENT, so a `gori ca regenerate`/`import`, an updated system
    # store or a different enterprise bundle each produce a new file rather than silently
    # reusing a stale one, which would fail verification without saying why. Written once:
    # the same inputs find the same file.
    private def self.trust_file(base_path : String?, base_text : String, root_pem : String,
                                root_body : String, prefix : String, dir : String) : String
      return base_path if base_path && squash(base_text).includes?(root_body)
      content = String.build do |s|
        s << base_text
        s << '\n' unless base_text.empty? || base_text.ends_with?('\n')
        s << "# gori root CA\n" << root_pem.strip << '\n'
      end
      path = File.join(dir, "#{prefix}-#{Digest::SHA256.hexdigest(content)[0, 16]}.pem")
      return path if (File.read(path) rescue nil) == content
      Paths.ensure_dir(dir)
      # 0644: public certificates, read by whatever the operator runs in the shell.
      DurableFile.write(path, content, perm: File::Permissions.new(0o644))
      path
    rescue ex : File::Error | IO::Error
      raise Error.new("cannot write the CA bundle under #{dir}: #{ex.message}")
    end

    PEM_BEGIN = "-----BEGIN CERTIFICATE-----"
    PEM_END   = "-----END CERTIFICATE-----"

    # A readable file that holds at least one certificate, or nil. Suffix match, so an OpenSSL
    # `TRUSTED CERTIFICATE` block counts too.
    private def self.read_pem?(path : String) : String?
      return nil unless File.file?(path)
      text = File.read(path)
      text.includes?("CERTIFICATE-----") ? text : nil
    rescue
      nil
    end

    # The base64 body of the first certificate in `pem`, whitespace removed — the form it is
    # searched for in a bundle whose line wrapping may differ.
    private def self.cert_body(pem : String) : String?
      start = pem.index(PEM_BEGIN)
      return nil unless start
      stop = pem.index(PEM_END, start)
      return nil unless stop
      squash(pem[(start + PEM_BEGIN.size)...stop]).presence
    end

    private def self.squash(text : String) : String
      text.delete(" \t\r\n")
    end

    # Cap on one file read out of a hashed-certificate directory: a root is a few KB, and a
    # stray large file there is not a certificate worth stalling on.
    private DIR_FILE_CAP = 1 << 20

    # The hashed-symlink fallback (`SYSTEM_CA_DIRS`) for a system that ships no bundle file:
    # every certificate file in it, each once (the `<hash>.0` links and the files they point
    # at are the same certificate).
    private def self.dir_bundle(cert_dir : String) : String?
      seen = Set(String).new
      String.build do |s|
        Dir.children(cert_dir).sort!.each do |name|
          path = File.join(cert_dir, name)
          next unless (File.file?(path) && File.size(path) <= DIR_FILE_CAP rescue false)
          real = (File.realpath(path) rescue nil)
          next unless real && seen.add?(real)
          next unless text = read_pem?(path)
          s << text
          s << '\n' unless text.ends_with?('\n')
        end
      end.presence
    rescue
      nil
    end
  end
end
