require "./rule"

module Gori
  module Prism
    module Passive
      # Cleartext HTTP authentication (category "headers"): HTTP Basic sends the credentials as
      # Base64 — reversible, effectively plaintext — so over `http://` they are exposed to any
      # network observer. Two shapes are flagged, both HTTP-only (over TLS the transport protects
      # them, so HTTPS is never flagged):
      #   * request `Authorization: Basic …`  — the client already transmitted credentials in the
      #     clear (High: a live secret went over the wire).
      #   * response `WWW-Authenticate: Basic` — the server challenges for Basic over cleartext, so
      #     the browser will send credentials in the clear on the next request (Medium).
      # Digest/Bearer/Negotiate are out of scope: they don't ship the raw password like Basic does.
      class Auth < Rule
        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.scheme == "http" # over TLS the credentials are transport-protected

          if ctx.req.headers.get_all("Authorization").any? { |v| basic?(v) }
            # get_all, not get? (last-only): a duplicated Authorization header could hide the
            # real Basic credential behind a later Bearer, mirroring the response-side WWW-Auth check.
            acc << det(ctx, "HTTP Basic credentials sent over cleartext HTTP",
              Store::Severity::High, "request Authorization: Basic")
            return # one finding per flow is enough; the request side is the stronger signal
          end

          return unless resp = ctx.response
          if resp.headers.get_all("WWW-Authenticate").any? { |v| offers_basic?(v) }
            acc << det(ctx, "HTTP Basic authentication challenged over cleartext HTTP",
              Store::Severity::Medium, "WWW-Authenticate: Basic")
          end
        end

        # A WWW-Authenticate header may list several comma-separated challenges
        # ("Negotiate, Basic realm=…"); Basic counts if it is the scheme of ANY of them, not only
        # the first. (Auth-param values can also carry commas, but a real Basic challenge's scheme
        # token still opens one of the comma segments.)
        private def offers_basic?(value : String) : Bool
          split_challenges(value).any? { |seg| basic?(seg) }
        end

        # Split on TOP-LEVEL commas only — a comma inside a quoted auth-param value (e.g.
        # `Digest realm="a, basic mode off"`) must not spawn a bogus "basic …" challenge segment.
        private def split_challenges(value : String) : Array(String)
          segs = [] of String
          in_quote = false
          start = 0
          value.each_char_with_index do |c, i|
            if c == '"'
              in_quote = !in_quote
            elsif c == ',' && !in_quote
              segs << value[start...i]
              start = i + 1
            end
          end
          segs << value[start..]
          segs
        end

        # An auth header/challenge whose scheme token is `Basic` (case-insensitive, leading
        # whitespace tolerated). A bare "basic" prefix would false-match e.g. "BasicAuth", so the
        # scheme must be delimited by a space or end the value.
        private def basic?(value : String) : Bool
          v = value.lstrip.downcase
          v == "basic" || v.starts_with?("basic ")
        end

        private def det(ctx : Context, title : String, sev : Store::Severity, evidence : String) : Detection
          Detection.new("insecure_basic_auth", Category::HEADERS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
