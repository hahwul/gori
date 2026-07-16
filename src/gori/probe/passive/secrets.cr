module Gori
  module Probe
    module Passive
      # High-confidence credential shapes shared by body and WebSocket payload rules.
      # Evidence is always the credential TYPE label — NEVER the matched value.
      # {pattern, label}.
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
          # A JSON Web Token embedded in a body. Each segment ≥10 chars keeps random dotted
          # tokens out; the "eyJ" header prefix is the distinctive first-byte anchor.
          {/\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b/, "JSON Web Token"},
        ]
      end
    end
  end
end
