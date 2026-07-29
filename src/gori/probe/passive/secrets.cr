module Gori
  module Probe
    module Passive
      # High-confidence credential shapes shared by body and WebSocket payload rules.
      # Evidence is always the credential TYPE label — NEVER the matched value.
      # {pattern, label}.
      #
      # Membership here means one thing: seeing this shape in a client-visible payload is a real
      # disclosure, because the shape is NEVER legitimately handed to a browser. That is what
      # earns the High severity. A shape an app routinely and correctly ships to its own client
      # does not belong in this list however secret-looking it is — see JWT below.
      module Secrets
        PATTERNS = [
          {/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, "AWS access key id"},
          {/\bAIza[0-9A-Za-z_\-]{35}\b/, "Google API key"},
          {/\bgh[pousr]_[0-9A-Za-z]{36}\b/, "GitHub token"},
          {/\bgithub_pat_[0-9A-Za-z_]{22,}\b/, "GitHub fine-grained token"},
          {/\bglpat-[0-9A-Za-z_\-]{20}\b/, "GitLab token"},
          {/\bxox[baprs]-[0-9A-Za-z\-]{10,}/, "Slack token"},
          # Stripe LIVE keys only (test keys aren't sensitive); the prefix is distinctive.
          {/\b(?:sk|rk)_live_[0-9A-Za-z]{20,}\b/, "Stripe secret key"},
          {/\bSG\.[\w\-]{16,}\.[\w\-]{16,}\b/, "SendGrid API key"},
          {/\bnpm_[0-9A-Za-z]{36}\b/, "npm access token"},
          {/-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----/, "private key block"},
          # Client-side shapes — these routinely ship hard-coded in HTML/JS bundles.
          {/\b\d{6,}-[0-9a-z]{32}\.apps\.googleusercontent\.com\b/, "Google OAuth client id"},
          {/\b(?:pk|sk)\.eyJ[\w\-]{20,}\.[\w\-]{20,}\b/, "Mapbox token"},
          {/\bhttps:\/\/hooks\.slack\.com\/services\/T[0-9A-Za-z]+\/B[0-9A-Za-z]+\/[0-9A-Za-z]{16,}/, "Slack webhook url"},
          {/\bSK[0-9a-f]{32}\b/, "Twilio api key"},
        ]

        # A JSON Web Token, held OUT of PATTERNS on purpose.
        #
        # Every shape above is one a server has no business sending to a browser, so finding one
        # is a disclosure. A JWT is the opposite: handing the client a token IS the design. A
        # login response, a refresh call, an RSC payload, a WebSocket auth frame — all deliver a
        # JWT over TLS to exactly the party it was minted for. Scoring that alongside a leaked AWS
        # key meant the High tier fired on essentially every authenticated app, and a High that
        # fires everywhere is a High nobody reads.
        #
        # It is still worth surfacing WHERE tokens flow, so the body/WebSocket rules report it as
        # its own Info-severity code (`jwt_in_body` / `jwt_in_ws`) rather than dropping it. That
        # also keeps it independently dismissible: muting routine token traffic on a host no
        # longer mutes a genuine key leak on the same host.
        #
        # Each segment ≥10 chars keeps random dotted tokens out; "eyJ" (base64url for `{"`) is the
        # distinctive first-byte anchor. Token weaknesses themselves (alg:none, missing exp, …)
        # are the separate `jwt` rule, which decodes the tokens a flow AUTHENTICATES with.
        JWT = {/\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b/, "JSON Web Token"}
      end
    end
  end
end
