module Gori
  module Redact
    # Header names whose VALUES carry credentials or session material — the ONE list behind
    # every header `[REDACTED]` in the tree: MCP's read tools, `gori run history --format
    # json`, `gori run evidence show` and the SARIF issues export (#1191). Kept here rather
    # than in `MCP::Serialize`, which re-exports it, so a core exporter can ask without
    # depending on a surface.
    #
    # A different axis from the body `Profile`s in redact.cr: those are operator-configured
    # and match structure; this is fixed and matches a field NAME.
    SENSITIVE_HEADERS = {"authorization", "proxy-authorization", "cookie", "set-cookie",
                         "x-api-key", "api-key", "x-auth-token"}

    def self.sensitive_header?(name : String) : Bool
      SENSITIVE_HEADERS.includes?(name.strip.downcase)
    end
  end
end
