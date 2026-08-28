require "http/client"
require "openssl"
require "uri"
require "./proxy/upstream"

module Gori
  # One-shot HTTP clients for gori's own service traffic (the updater and OAST providers).
  # The security-testing send engines keep their byte-exact codecs; this seam exists only so
  # stdlib HTTP::Client cannot quietly open a direct socket beside Proxy::Upstream.
  module HttpTransport
    class Error < Gori::Error
    end

    # A client created over an existing IO cannot reconnect. Crystal's retry path otherwise
    # mistakes that already-open first connection for a reused one, closes it after EOF/a
    # response-block exception, and then raises "cannot be reconnected". More importantly, a
    # future reconnect implementation must not be allowed to bypass the routed dial. One routed
    # socket means one attempt; callers that want another request create another routed client.
    private class RoutedClient < HTTP::Client
      private def should_retry_request?(request, exception, reusing_connection) : Bool
        false
      end
    end

    def self.client(uri : URI, *, verify_tls : Bool = true,
                    connect_timeout : Time::Span = Settings.connect_timeout,
                    read_timeout : Time::Span = Settings.io_timeout) : HTTP::Client
      host, tls, port = endpoint(uri)
      io = routed_io(host, port, tls, verify_tls, connect_timeout, read_timeout)
      build_client(io, host, port, tls, connect_timeout, read_timeout)
    rescue ex : Error
      raise ex
    rescue ex
      io.try(&.close) rescue nil
      raise Error.new("HTTP connection to #{host || "unknown host"} failed: #{ex.message.presence || ex.class}")
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
                               connect_timeout : Time::Span, read_timeout : Time::Span) : IO
      tcp, dial_error = Proxy::Upstream.dial_result(host, port, connect_timeout, read_timeout,
        apply_host_overrides: false)
      unless tcp
        detail = dial_error.try(&.detail) || "#{host}:#{port} is unreachable"
        raise Error.new("#{detail}#{dial_error.try(&.because) || ""}")
      end

      tls ? wrap_tls(tcp, host, verify_tls) : tcp.as(IO)
    end

    private def self.build_client(io : IO, host : String, port : Int32, tls : Bool,
                                  connect_timeout : Time::Span,
                                  read_timeout : Time::Span) : HTTP::Client
      client = RoutedClient.new(io, host, port)
      client.connect_timeout = connect_timeout
      client.read_timeout = read_timeout
      # Existing-IO clients do not know that `io` is TLS, so stdlib would render :443 in Host.
      # Set the URI authority after its defaults and keep redirects/new origins independent.
      authority = authority(host, port, tls)
      client.before_request { |request| request.headers["Host"] = authority }
      client
    end

    private def self.wrap_tls(tcp : TCPSocket, host : String,
                              verify : Bool) : OpenSSL::SSL::Socket::Client
      context = OpenSSL::SSL::Context::Client.new
      if verify
        Proxy::Upstream.apply_system_trust(context)
      else
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end
      OpenSSL::SSL::Socket::Client.new(tcp, context: context, sync_close: true, hostname: host)
    rescue ex
      tcp.close rescue nil
      raise ex
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
