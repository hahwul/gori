module Gori::Tui
  # Small URL display helpers shared across views (History list, Intercept queue …).
  module Url
    # The request target in origin-form for display. Plaintext forward-proxy requests
    # are captured ABSOLUTE-form (`http://host/path` — the wire truth, P7); strip the
    # scheme+authority so a path column / queue label reads like the HTTPS (origin-form)
    # rows instead of gluing the host onto a full URL ("example.comhttp://example.com/x").
    # Non-URL targets (e.g. a response's "405 Method Not Allowed") pass through unchanged.
    def self.origin_path(target : String) : String
      return target unless target.starts_with?("http://") || target.starts_with?("https://")
      scheme_end = target.index("://")
      return target unless scheme_end
      slash = target.index('/', scheme_end + 3)
      slash ? target[slash..] : "/"
    end
  end
end
