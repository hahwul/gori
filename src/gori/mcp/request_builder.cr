require "json"
require "uri"

module Gori
  module MCP
    # Turns a `send_request` tool's structured arguments into the raw HTTP/1.1
    # request bytes the replay engines expect, plus the scheme/host/port they dial.
    # Two modes: structured ({method,url,headers,body}) or a verbatim `raw` request
    # string (still taking scheme/host/port from `url`, since the engines need a
    # target to dial). Byte-exactness is the engines' contract (P7), so we only add
    # Host/Content-Length when the caller omitted them.
    module RequestBuilder
      record Built, bytes : Bytes, scheme : String, host : String, port : Int32

      # `args` is the tool's `arguments` object (a parsed JSON hash).
      def self.build(args : Hash(String, JSON::Any)) : Built
        url = args["url"]?.try(&.as_s?)
        raise Gori::Error.new("'url' is required") if url.nil? || url.empty?

        uri = URI.parse(url)
        scheme = (uri.scheme || "http").downcase
        raise Gori::Error.new("unsupported scheme: #{scheme} (only http/https)") unless scheme.in?("http", "https")
        host = uri.host
        raise Gori::Error.new("url has no host: #{url}") if host.nil? || host.empty?
        port = uri.port || default_port(scheme)

        bytes =
          if (raw = args["raw"]?.try(&.as_s?)) && !raw.empty?
            normalize_crlf(raw).to_slice
          else
            build_from_parts(uri, scheme, host, port, args)
          end

        Built.new(bytes, scheme, host, port)
      end

      private def self.build_from_parts(uri : URI, scheme : String, host : String, port : Int32,
                                        args : Hash(String, JSON::Any)) : Bytes
        method = (args["method"]?.try(&.as_s?) || "GET").upcase
        body = args["body"]?.try(&.as_s?)

        path = uri.path
        path = "/" if path.empty?
        target = uri.query ? "#{path}?#{uri.query}" : path

        headers = [] of {String, String}
        if h = args["headers"]?.try(&.as_h?)
          h.each { |k, v| headers << {k, v.as_s? || v.to_s} }
        end

        unless headers.any? { |(k, _)| k.compare("host", case_insensitive: true) == 0 }
          hostline = port == default_port(scheme) ? host : "#{host}:#{port}"
          headers << {"Host", hostline}
        end
        if body && !headers.any? { |(k, _)| k.compare("content-length", case_insensitive: true) == 0 ||
           k.compare("transfer-encoding", case_insensitive: true) == 0 }
          headers << {"Content-Length", body.bytesize.to_s}
        end

        io = IO::Memory.new
        io << method << ' ' << target << " HTTP/1.1\r\n"
        headers.each { |(k, v)| io << k << ": " << v << "\r\n" }
        io << "\r\n"
        io << body if body
        io.to_slice
      end

      private def self.default_port(scheme : String) : Int32
        scheme == "https" ? 443 : 80
      end

      # Promote lone LFs to CRLF so a hand-typed `raw` request frames correctly
      # (already-CRLF input is untouched).
      private def self.normalize_crlf(raw : String) : String
        raw.gsub(/\r?\n/, "\r\n")
      end
    end
  end
end
