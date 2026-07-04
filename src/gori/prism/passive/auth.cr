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

          if (a = ctx.req.headers.get?("Authorization")) && basic?(a)
            acc << det(ctx, "HTTP Basic credentials sent over cleartext HTTP",
              Store::Severity::High, "request Authorization: Basic")
            return # one finding per flow is enough; the request side is the stronger signal
          end

          return unless resp = ctx.response
          if resp.headers.get_all("WWW-Authenticate").any? { |v| basic?(v) }
            acc << det(ctx, "HTTP Basic authentication challenged over cleartext HTTP",
              Store::Severity::Medium, "WWW-Authenticate: Basic")
          end
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
