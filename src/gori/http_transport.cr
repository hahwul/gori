require "http/client"
require "openssl"
require "uri"
require "./proxy/upstream"

module Gori
  # One-shot HTTP clients for gori's own service traffic (the updater and OAST providers).
  # The security-testing send engines keep their byte-exact codecs; this seam exists only so
  # stdlib HTTP::Client cannot quietly open a direct socket beside Proxy::Upstream.
  module HttpTransport
    # A failed dial, worded by the STAGE that broke. `kind` is the dialer's own verdict
    # (`Proxy::Upstream::DialErrorKind`) when there is one, so a caller can add advice this
    # module has no business knowing — `gori run oast listen` points at another public preset
    # when the name never resolved, and says nothing of the sort when the certificate was
    # rejected. nil only for a failure raised past the dial itself.
    class Error < Gori::Error
      getter kind : Proxy::Upstream::DialErrorKind?
      # The caller's `deadline` (see `client`), not the dial's own bounds, ended the attempt.
      getter? expired : Bool

      def initialize(message : String, @kind : Proxy::Upstream::DialErrorKind? = nil,
                     *, @expired : Bool = false)
        super(message)
      end
    end

    # A client created over an existing IO cannot reconnect. Crystal's retry path otherwise
    # mistakes that already-open first connection for a reused one, closes it after EOF/a
    # response-block exception, and then raises "cannot be reconnected". More importantly, a
    # future reconnect implementation must not be allowed to bypass the routed dial. One routed
    # socket means one attempt; callers that want another request create another routed client.
    #
    # `deadline` bounds the exchange in wall clock. The read timeout is per read, so a peer
    # that drips its head or body, each byte inside it, otherwise holds the call for as long
    # as it likes. At the deadline the transport socket beneath any TLS is closed, which wakes
    # the blocked read with an error; `close` joins the watcher. `expired?` says it fired, so
    # a response whose last byte beat the deadline is never mistaken for a cut one.
    private class RoutedClient < HTTP::Client
      @watch : Proxy::Upstream::CancelWatch?
      @expired = false

      def initialize(io : IO, host : String, port : Int32, deadline : Time::Instant?)
        super(io, host, port)
        if deadline
          @watch = Proxy::Upstream::CancelWatch.new(Proxy::SocketTuning.underlying_socket(io) || io,
            nil, deadline)
        end
      end

      def close : Nil
        if watch = @watch
          @watch = nil
          watch.stop
          @expired = watch.expired?
        end
        super
      end

      def expired? : Bool
        @expired || @watch.try(&.expired?) || false
      end

      private def should_retry_request?(request, exception, reusing_connection) : Bool
        false
      end
    end

    # `deadline` covers the TLS handshake as well as the exchange: it caps the handshake's own
    # ceiling, and a handshake it ends raises an `Error` that is `expired?`.
    def self.client(uri : URI, *, verify_tls : Bool = true,
                    connect_timeout : Time::Span = Settings.connect_timeout,
                    read_timeout : Time::Span = Settings.io_timeout,
                    deadline : Time::Instant? = nil) : HTTP::Client
      host, tls, port = endpoint(uri)
      io = routed_io(host, port, tls, verify_tls, connect_timeout, read_timeout, deadline)
      build_client(io, host, port, tls, connect_timeout, read_timeout, deadline)
    rescue ex : Error
      raise ex
    rescue ex
      io.try(&.close) rescue nil
      raise Error.new("HTTP connection to #{host || "unknown host"} failed: #{ex.message.presence || ex.class}")
    end

    # Whether `client`'s deadline fired, closing its socket under the exchange. False for a
    # client built without one.
    def self.expired?(client : HTTP::Client) : Bool
      client.as?(RoutedClient).try(&.expired?) || false
    end

    private def self.endpoint(uri : URI) : {String, Bool, Int32}
      scheme = uri.scheme.try(&.downcase)
      unless scheme == "http" || scheme == "https"
        raise Error.new("unsupported HTTP URL scheme #{scheme.inspect}")
      end
      host = uri.host
      raise Error.new("HTTP URL needs a host") unless host
      host = bare_host(host)
      tls = scheme == "https"
      port = uri.port || (tls ? 443 : 80)
      {host, tls, port}
    end

    private def self.routed_io(host : String, port : Int32, tls : Bool, verify_tls : Bool,
                               connect_timeout : Time::Span, read_timeout : Time::Span,
                               deadline : Time::Instant?) : IO
      tcp, dial_error = Proxy::Upstream.dial_result(host, port, connect_timeout, read_timeout,
        apply_host_overrides: false, origin_scheme: tls ? "https" : "http")
      raise dial_failure(host, port, dial_error) unless tcp

      tls ? wrap_tls(tcp, host, port, verify_tls, read_timeout, deadline) : tcp
    end

    # The pre-TLS legs. `dial_result` already knows WHICH one failed; this used to print only
    # `detail` — nil for a direct dial — so a name that never resolved and a port that refused
    # both read as the same "host:port is unreachable" line, with the resolver's own words
    # parenthesised after it as the only clue (#1020). A stage the dialer identified is stated
    # as a stage.
    private def self.dial_failure(host : String, port : Int32,
                                  err : Proxy::Upstream::DialError?) : Error
      return Error.new("#{host}:#{port} is unreachable") unless err
      message =
        case err.kind
        when .dns?
          "DNS lookup for #{host} failed — the name never resolved, so nothing was dialed; " \
          "a restricted or split-horizon resolver is the usual cause"
        when .connect?
          err.detail || "TCP connect to #{host}:#{port} failed — refused, filtered, or timed out"
        else
          err.detail || "#{host}:#{port} is unreachable"
        end
      Error.new("#{message}#{err.because}", err.kind)
    end

    private def self.build_client(io : IO, host : String, port : Int32, tls : Bool,
                                  connect_timeout : Time::Span,
                                  read_timeout : Time::Span,
                                  deadline : Time::Instant?) : HTTP::Client
      client = RoutedClient.new(io, host, port, deadline)
      client.connect_timeout = connect_timeout
      client.read_timeout = read_timeout
      # Existing-IO clients do not know that `io` is TLS, so stdlib would render :443 in Host.
      # Set the URI authority after its defaults and keep redirects/new origins independent.
      authority = authority(host, port, tls)
      client.before_request { |request| request.headers["Host"] = authority }
      client
    end

    # `IO`, not `TCPSocket`: an `http+tls://` upstream proxy hands back a TLS socket to the
    # proxy, and the origin's own TLS is then nested inside it (see Proxy::Upstream).
    #
    # `apply_system_trust` runs unconditionally here, unlike `Upstream.client_context` which
    # skips it when SSL_CERT_FILE / SSL_CERT_DIR is set. That divergence is deliberate and this
    # module's error text depends on it: the remedy `tls_failure` prints for a rejected chain is
    # "point SSL_CERT_FILE at your CA bundle", and the store must stay ADDITIVE for that to be
    # safe advice — an enterprise bundle holding only the inspecting proxy's root would
    # otherwise stop gori's own updater and OAST traffic from trusting the public roots it also
    # needs. Target traffic keeps the replace-the-store semantics operators expect of the
    # variable; gori's service traffic trusts the system roots plus whatever you name.
    private def self.wrap_tls(tcp : IO, host : String, port : Int32, verify : Bool,
                              io_timeout : Time::Span,
                              deadline : Time::Instant?) : OpenSSL::SSL::Socket::Client
      context = OpenSSL::SSL::Context::Client.new
      {% if OpenSSL.has_constant?(:KTLS) %}
        context.remove_options(OpenSSL::SSL::Options::ENABLE_KTLS) # see Proxy::Tls::ContextFactory.lean_server
      {% end %}
      if verify
        Proxy::Upstream.apply_system_trust(context)
      else
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end
      # Under the target dialer's wall-clock ceiling: the per-read timeout alone let a
      # collector or updater host that drips its handshake hold the call for hours.
      handshake_io = Proxy::SocketTuning.underlying_socket(tcp) || tcp
      Proxy::Upstream.bounded_handshake(handshake_io, nil, io_timeout, deadline) do
        OpenSSL::SSL::Socket::Client.new(tcp, context: context, sync_close: true, hostname: host)
      end
    rescue ex
      tcp.close rescue nil
      raise tls_failure(host, port, ex, io_timeout)
    end

    # The TLS leg, split the way `Proxy::Upstream` splits it for target traffic — and named
    # with the remedy that fits THAT verdict. Verification failing is the one case where a CA
    # bundle is the answer; a handshake that never got to a certificate, or a port that
    # accepted and then went silent, must not be offered the same advice.
    private def self.tls_failure(host : String, port : Int32, ex : Exception,
                                 io_timeout : Time::Span) : Error
      err = Proxy::Upstream.tls_dial_error(ex, io_timeout, host, port)
      message =
        case err.kind
        when .tls_verify?
          "TLS certificate verification for #{host} failed — the chain was rejected by the " \
          "trust store, so no request was ever sent. If this host is reached through a " \
          "TLS-inspecting proxy or is signed by a private CA, trust that CA by running with " \
          "SSL_CERT_FILE=/path/to/ca-bundle.crt (or SSL_CERT_DIR=/path/to/certs)"
        when .timeout?
          if ex.is_a?(Proxy::Upstream::HandshakeTimeout)
            "TLS handshake with #{host} did not complete — the port accepted the connection " \
            "and then answered too slowly"
          else
            "TLS handshake with #{host} did not complete — the port accepted the connection " \
            "and then said nothing"
          end
        else
          "TLS handshake with #{host} failed before any certificate was judged, so " \
          "SSL_CERT_FILE cannot help here"
        end
      Error.new("#{message}#{err.because}#{err.proxy_note}", err.kind,
        expired: ex.is_a?(Proxy::Upstream::HandshakeTimeout) && ex.caller_deadline?)
    end

    private def self.bare_host(host : String) : String
      host.starts_with?('[') && host.ends_with?(']') ? host[1...-1] : host
    end

    private def self.authority(host : String, port : Int32, tls : Bool) : String
      rendered = host.includes?(':') ? "[#{host}]" : host
      port == (tls ? 443 : 80) ? rendered : "#{rendered}:#{port}"
    end
  end
end
