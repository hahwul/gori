require "socket"
require "uri"
require "../../url"
require "./rule"
require "./secrets"

module Gori
  module Probe
    module Passive
      # One observed request carries a credential-bearing Referer to a different origin
      # (RFC 9700 §4.2). The finding stores only the receiver's origin and a type label.
      class RefererCredentials < Rule
        private MAX_REFERER_BYTES = 8 * 1024
        class_getter uri_characters : Regex { %r{\A(?:[A-Za-z0-9._~!$&'()*+,;=:@/?\[\]-]|%[0-9A-Fa-f]{2})+\z} }
        class_getter ipv6_authority : Regex { %r{\A\[[0-9A-Fa-f:.]+\](?::[0-9]+)?(?:[/?]|\z)} }
        class_getter joined_value : Regex { Utf8.tolerant(%r{,(?:[a-z][a-z0-9+.-]*:)?//}i) }
        class_getter registered_name : Regex { /\A[A-Za-z0-9._~-]+\z/ }
        private CREDENTIAL_NAMES = Set{"accesstoken", "refreshtoken", "idtoken", "authtoken", "sessiontoken",
                                       "privatetoken", "clientsecret", "apikey", "secretkey", "accesskey",
                                       "password", "passwd", "pwd", "jwt"}

        def info : RuleInfo
          RuleInfo.new("secret_in_referer", "Cross-origin Referer credential exposure",
            "Flags credentials in a Referer query sent to a different HTTP origin.",
            Category::INFOLEAK)
        end

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.row.state.complete?
          return unless uri = referer(ctx.req.headers)
          return unless query = uri.query
          return unless source = origin(uri.scheme, uri.host, uri.port)
          return unless destination = origin(ctx.scheme, ctx.host, ctx.row.port)
          return if source == destination
          return unless label = credential_label(query)

          scheme, host, port = destination
          url = Url.request_url(scheme, host, "/", port)
          acc << Detection.new("secret_in_referer", Category::INFOLEAK, host, url,
            "Credential exposed in a cross-origin Referer", Store::Severity::Medium, label, ctx.fid)
        end

        private def referer(headers : Proxy::Codec::HeaderList) : URI?
          value = nil
          headers.each do |header|
            next unless header.name.compare("Referer", case_insensitive: true) == 0
            return if value
            value = header.value
          end
          parse_referer(value) if value
        end

        private def parse_referer(value : String) : URI?
          return unless value.bytesize <= MAX_REFERER_BYTES && value.includes?('?')
          return unless Url.absolute_form?(value) && value.ascii_only? && RefererCredentials.uri_characters.matches?(value)
          uri = URI.parse(value)
          return if uri.user
          if uri.host.try(&.includes?(':'))
            # URI.parse decodes escapes in the host. On the wire an IPv6 authority needs brackets.
            authority = value.partition("://")[2]
            return unless RefererCredentials.ipv6_authority.matches?(authority)
          end
          uri
        rescue URI::Error | OverflowError
          nil
        end

        private def origin(scheme : String?, host : String?, port : Int32?) : {String, String, Int32}?
          return unless scheme && host
          scheme = scheme.downcase
          return unless scheme.in?("http", "https")
          port ||= scheme == "https" ? 443 : 80
          return unless Socket::IPAddress.valid_port?(port)
          return unless host = canonical_host(host)
          {scheme, host, port}
        end

        private def canonical_host(host : String) : String?
          if host.includes?(':')
            ip = host.lchop('[').rchop(']')
            return Socket::IPAddress.new(ip, 0).address if Socket::IPAddress.valid_v6?(ip)
          end
          host.downcase if host.ascii_only? && RefererCredentials.registered_name.matches?(host)
        end

        private def credential_label(query : String) : String?
          # URI::Params treats semicolons as delimiters, although they are part of a form value.
          URI::Params.parse(query.gsub(';', "%3B")) do |name, value|
            next if value.blank? || Secrets::PLACEHOLDER_VALUES.includes?(value.downcase)
            # An apparent coalesced URL is ambiguous in this value. Commas elsewhere in
            # the query can belong to legitimate lists and do not affect a separate pair.
            next if RefererCredentials.joined_value.matches?(value)
            return "Named credential parameter in Referer" if CREDENTIAL_NAMES.includes?(name.downcase.delete("-_"))
            return Secrets.jwt[1] if Secrets.jwt[0].matches?(value)
            if match = Secrets.patterns.find { |pattern, _| pattern.matches?(value) }
              return match[1]
            end
          end
          nil
        end
      end
    end
  end
end
