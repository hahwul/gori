module Gori
  module ShellEnv
    # Exported into every gori shell (`gori run shell`, the TUI's Open shell). A prompt or a
    # script tests the first; the second names the proxy the shell was pointed at, so gori
    # itself can recognise its own injection (see `injected_proxy?`).
    #
    # A leaf with no requires: `settings/upstream_rules` reads it on every environment-proxy
    # lookup, and must not pull in the bundle builder and the proxy it depends on.
    MARKER_VAR = "GORI_SHELL"
    PROXY_VAR  = "GORI_PROXY"

    # `GORI_SHELL_ORIG_<NAME>` holds what `<NAME>` was before the shell replaced or unset it —
    # a corporate `HTTPS_PROXY`, the `NO_PROXY` exceptions that went with it, a tool's own CA
    # bundle. A gori started inside the shell reaches its real upstream through these, and a
    # shell opened inside a shell starts from them rather than from the outer shell's values.
    ORIG_PREFIX = "GORI_SHELL_ORIG_"

    # Whether a proxy variable's `value` is the one a gori shell exported, i.e. it points back
    # at the gori that started this shell. gori reads `HTTPS_PROXY` and friends as its own
    # upstream fallback, so without this a gori started inside the shell (`gori run send`, a
    # second capture) would chain every request it makes through the parent and get it
    # captured twice. Only the exact value the shell wrote matches: a proxy the operator
    # exported on top of it is a decision, and stays one.
    def self.injected_proxy?(value : String, env = ENV) : Bool
      return false unless env[MARKER_VAR]? == "1"
      authority = env[PROXY_VAR]?.try(&.strip).presence
      return false unless authority
      v = value.strip.downcase.rchop('/')
      a = authority.downcase
      v == "http://#{a}" || v == a
    end

    # The proxy-environment variable `name` as the terminal had it before any gori shell: the
    # live value unless it is the shell's own injection, else — inside a gori shell — the value
    # the shell recorded as replaced. Outside a shell this is just the live value.
    def self.inherited_proxy(name : String, env = ENV) : String?
      live = env[name]?.try(&.strip).presence
      return live if live && !injected_proxy?(live, env)
      return nil unless env[MARKER_VAR]? == "1"
      env["#{ORIG_PREFIX}#{name}"]?.try(&.strip).presence
    end
  end
end
