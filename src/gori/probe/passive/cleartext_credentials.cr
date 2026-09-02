require "uri"
require "./rule"

module Gori
  module Probe
    module Passive
      # Credentials over cleartext `http://` (category "headers"), the two shapes `Auth` does not
      # cover. `Auth` speaks for the `Authorization: Basic` / `WWW-Authenticate: Basic` header pair;
      # this rule speaks for the ordinary login form, which is how nearly every application actually
      # transmits a password:
      #   * a REQUEST over http:// whose body carries a password-shaped parameter with a real value
      #     — the password has already crossed the network in the clear (High); and
      #   * a RESPONSE over http:// that renders a `<input type="password">` — the credentials have
      #     not been sent yet, but the form that will send them was itself delivered over a channel
      #     an attacker can rewrite, so neither the field nor its `action` can be trusted (Medium).
      #     This is the condition every current browser marks "Not secure" in the address bar.
      #
      # Not overlapping its neighbours by construction: a password in the QUERY string is
      # `secret_in_url` (which flags it on any scheme, because a URL leaks to logs and Referer
      # regardless of TLS), so only the request BODY is read here; and a form on an HTTPS page
      # POSTing to an `http://` action is `insecure_form_action`, which is the mirror case — a
      # secure page with an insecure destination, rather than an insecure page.
      class CleartextCredentials < Rule
        def info : RuleInfo
          RuleInfo.new("cleartext_credentials", "Cleartext credential submission",
            "Flags a password submitted in a request body over http://, and a password input served over http://.",
            Category::HEADERS)
        end

        # Password-shaped parameter names after normalisation (see `password_name?`), plus the
        # OAuth client secret, which is a credential by any other name. Kept to names whose ONLY
        # reading is a credential: `pin`, `otp` and `code` are left out because each has a common
        # non-credential meaning (a postcode field, a promo code) and this rule reports High.
        CREDENTIAL_NAMES = Set{
          "password", "passwd", "pwd", "pass", "passphrase",
          "clientsecret", "secret", "apikey", "apisecret",
        }

        # Values that are a password field's NAME rather than its value — `showPassword=false`,
        # `remember_pwd=on`. A real password is none of these, and a form that ships UI state under
        # a password-ish name is otherwise a guaranteed High.
        NON_SECRET_VALUES = Set{"true", "false", "0", "1", "on", "off", "yes", "no", "null", "undefined"}

        # A JSON member whose NAME ends in a password token, capturing the name and its non-empty
        # STRING value. An unquoted boolean (`"showPassword": false`) never matches the `"…"`
        # value; a value that IS a quoted boolean-ish token (`"false"`, `"off"` — a boolean a JS
        # serialiser wrote as a string) is screened by `NON_SECRET_VALUES` in `json_password`, the
        # same UI-state screen the form-encoded path applies to its value.
        JSON_PASSWORD = /"([A-Za-z0-9_.\[\]-]*(?:password|passwd|pwd))"\s*:\s*"((?:[^"\\]|\\.)+)"/i

        # `<input … type=password>`. The negative lookbehind is the same one the neighbouring HTML
        # scans use: without it a `data-type="password"` attribute matches, because `\b` treats the
        # hyphen as a boundary.
        PASSWORD_INPUT = /<input\b[^>]*(?<![-\w])type\s*=\s*["']?password\b/i
        # Cheap necessary-condition gate for it, a REGEX for the reason `body_leaks` documents at
        # length: PCRE2 memchr-skips a literal where `String#includes?` walks every offset, and
        # PASSWORD_INPUT itself opens on `<input`, which a form-heavy page carries everywhere.
        PASSWORD_GATE = /password/i

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.scheme == "http"
          # A loopback origin is "potentially trustworthy" to every browser (W3C Secure Contexts):
          # nothing leaves the machine, so there is no cleartext channel to observe. Flagging a
          # developer's own `http://localhost:3000` login form is pure noise, and the same
          # reasoning already excluded 127.0.0.1 from `body_leaks`' private-IP scan.
          return if loopback?(ctx.host)
          check_request(ctx, acc)
          check_response(ctx, acc)
        end

        # The password already went over the wire. High: this is a live secret an observer has,
        # not a hardening gap.
        private def check_request(ctx : Context, acc : Array(Detection)) : Nil
          body = ctx.request_body_text
          return if body.nil? || body.empty?
          ct = ctx.req.headers.get?("Content-Type").try(&.downcase) || ""
          # multipart/form-data is deliberately not parsed: locating a part's VALUE means walking
          # the boundary structure, and a name-only match would report an empty login form as a
          # transmitted password. A multipart login page is still caught by the response side.
          return if ct.includes?("multipart/")
          name = ct.includes?("json") ? json_password(body) : form_password(body)
          return if name.nil?
          acc << det(ctx, "cleartext_credentials",
            "Password submitted in a request body over cleartext HTTP",
            Store::Severity::High, name)
        end

        # The login page itself arrived over cleartext, so an on-path attacker can rewrite the form
        # before the user ever types into it. Medium: nothing has leaked yet.
        private def check_response(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          return unless ctx.html?
          text = ctx.client_body_text
          return if text.nil? || !PASSWORD_GATE.matches?(text)
          return unless PASSWORD_INPUT.matches?(text)
          acc << det(ctx, "cleartext_password_form",
            "Password field served over cleartext HTTP", Store::Severity::Medium,
            "<input type=password>")
        end

        # The first form-encoded pair whose name is credential-shaped and whose value is a real
        # one; nil when there is none. Parsed by hand rather than through `URI::Params` so a
        # malformed body (a stray `&&`, a pair with no `=`) is skipped rather than raising — the
        # request body is operator/target bytes, not something to be trusted into a parser.
        private def form_password(body : String) : String?
          body.split('&').each do |pair|
            next if pair.empty?
            eq = pair.index('=')
            next if eq.nil? || eq == 0
            name = decode(pair[0...eq])
            next unless password_name?(name)
            value = decode(pair[(eq + 1)..])
            next if value.empty? || NON_SECRET_VALUES.includes?(value.downcase)
            return safe_name(name)
          end
          nil
        end

        private def json_password(body : String) : String?
          m = JSON_PASSWORD.match(body) || return nil
          # A quoted boolean-ish value (`"showPassword":"false"`) is UI state, not a transmitted
          # secret — the same screen `form_password` applies to its value. The evidence is the
          # member NAME (capture 1), never the value.
          return nil if NON_SECRET_VALUES.includes?(m[2].downcase)
          safe_name(m[1])
        end

        # A parameter name reads as a credential once punctuation and case are dropped, so
        # `user[password]`, `login-password` and `newPassword` all normalise onto the same set.
        # The suffix arm carries the open-ended forms (`confirm_password`, `old_pwd`) the set
        # cannot enumerate; a `password_hint` / `password_strength` field does NOT end in a
        # password token and so stays out.
        private def password_name?(name : String) : Bool
          norm = name.downcase.gsub(/[^a-z0-9]/, "")
          return false if norm.empty?
          return true if CREDENTIAL_NAMES.includes?(norm)
          norm.ends_with?("password") || norm.ends_with?("passwd") || norm.ends_with?("pwd")
        end

        private def decode(s : String) : String
          URI.decode_www_form(s).scrub
        rescue
          s.scrub
        end

        # The name lands in stored evidence and in the TUI: keep it printable and short. It is a
        # parameter name, so nothing real is lost — and it is the NAME, never the password.
        private def safe_name(name : String) : String
          cleaned = name.scrub.gsub(/[^\x20-\x7e]/, "")
          cleaned = cleaned[0, 48] if cleaned.size > 48
          cleaned.empty? ? "password" : cleaned
        end

        private def loopback?(host : String) : Bool
          h = host.downcase
          h == "localhost" || h == "::1" || h == "[::1]" ||
            h.ends_with?(".localhost") || h.starts_with?("127.")
        end

        private def det(ctx : Context, code : String, title : String,
                        sev : Store::Severity, evidence : String) : Detection
          Detection.new(code, Category::HEADERS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
