# SSL_CTX_set_keylog_callback is OpenSSL 1.1.1+. LibreSSL exports a stub that never fires, so it
# is gated out with the old OpenSSLs: there `KeyLog.available?` is false and a set variable gets
# a notice instead of a compile error or a silent no-op.
{% if LibSSL::LIBRESSL_VERSION == "0.0.0" && compare_versions(LibSSL::OPENSSL_VERSION, "1.1.1") >= 0 %}
  lib LibSSL
    alias KeylogCallback = (SSL, LibC::Char*) ->
    fun ssl_ctx_set_keylog_callback = SSL_CTX_set_keylog_callback(ctx : SSLContext, cb : KeylogCallback)
    fun ssl_ctx_get_keylog_callback = SSL_CTX_get_keylog_callback(ctx : SSLContext) : KeylogCallback
  end
{% end %}

module Gori::Proxy::Tls
  # Opt-in NSS key log (#1593): with `GORI_SSLKEYLOGFILE` (or the `SSLKEYLOGFILE` curl, Firefox
  # and mitmproxy read) set, every handshake on both legs — browser ⇄ gori and gori ⇄ origin or
  # upstream proxy — appends its secrets, so Wireshark can decrypt a capture of either. It only
  # observes secrets; no byte on the wire changes (P7).
  #
  # The switch is the process environment, read once before any SSL_CTX exists and fixed for
  # the process lifetime: the callback is on every context or none, so the context caches in
  # `Upstream` need no key for it. Deliberately not a setting nor an MCP argument: an agent that
  # could turn it on could read every session.
  module KeyLog
    @@sink : IO? = nil

    # What `configure` said, for the TUI to show once it is up.
    class_getter notice : String? = nil

    def self.available? : Bool
      {{ LibSSL.has_method?(:ssl_ctx_set_keylog_callback) }}
    end

    def self.active? : Bool
      !@@sink.nil?
    end

    # Reads the variables and opens the sink. Returns the one-line notice each surface shows
    # once at startup (a file of secrets nobody remembers asking for is a liability), or nil
    # when neither variable is set. An empty `GORI_SSLKEYLOGFILE` keeps gori out of a file
    # `SSLKEYLOGFILE` names for a browser.
    def self.configure(env = ENV) : String?
      @@notice = open_sink(env)
    end

    private def self.open_sink(env) : String?
      return unless path = env.fetch("GORI_SSLKEYLOGFILE") { env["SSLKEYLOGFILE"]? }.presence
      return "TLS key log: #{path} requested, but this OpenSSL cannot log keys; nothing is written" unless available?
      # A FIFO or device would block the scheduler thread inside a handshake (P6).
      if (info = File.info?(path)) && !info.file?
        return "TLS key log: #{path} is not a regular file; not logging"
      end
      file = File.open(path, "a", perm: 0o600) # it holds secrets
      # `perm` only applies on create; a file curl or a browser made first is usually 0644.
      if file.info.permissions.value & 0o077 != 0
        file.chmod(0o600) rescue nil
      end
      {% unless flag?(:win32) %}
        # Another user's file (pre-created in a shared /tmp) refuses the chmod, and its owner can
        # read or re-open it at any time: never write secrets into it.
        info = file.info
        if info.owner_id != LibC.getuid.to_s || info.permissions.value & 0o077 != 0
          file.close
          return "TLS key log: #{path} is not private to you (owner or mode); not logging"
        end
      {% end %}
      file.sync = true
      @@sink = file
      "TLS key log: writing session secrets to #{path}"
    rescue ex : File::Error
      "TLS key log: cannot open #{path} (#{ex.message}); not logging"
    end

    # No-op when unconfigured: OpenSSL formats the line only when a callback is set, so off
    # costs nothing.
    def self.install(ctx : OpenSSL::SSL::Context) : Nil
      {% if LibSSL.has_method?(:ssl_ctx_set_keylog_callback) %}
        return unless @@sink
        LibSSL.ssl_ctx_set_keylog_callback(ctx.to_unsafe, ->(_ssl : LibSSL::SSL, line : LibC::Char*) {
          KeyLog.append(String.new(line))
        })
      {% end %}
    end

    # Runs inside SSL_do_handshake. One pre-joined write on a sync regular file: no Channel, Log
    # or STDERR (a fiber switch from inside a C frame, or a line drawn over the TUI), and
    # O_APPEND keeps lines whole when a browser shares the file. Nothing may unwind through
    # OpenSSL, so the first IO error closes the sink and logging stops for good.
    def self.append(line : String) : Nil
      return unless sink = @@sink
      sink.write("#{line}\n".to_slice)
    rescue
      @@sink = nil
      sink.try &.close rescue nil
    end

    # Spec hook: swap the sink (nil turns logging off). Contexts built while it was set keep
    # their callback, which then writes nowhere.
    def self.reset(io : IO? = nil) : Nil
      @@sink.try { |old| old.close unless old.same?(io) }
      @@sink = io
      @@notice = nil
    end
  end
end
