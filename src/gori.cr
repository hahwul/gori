# gori — free/open-source TUI web proxy (MITM).
#
# This is the library entrypoint. The executable's behaviour lives in
# `Gori::CLI.run` (added in a later build step); for now this file only
# establishes the module, version, and the single base error type.
module Gori
  VERSION = "0.1.0"

  # Single base error for the whole project. Subtype only when a `rescue`
  # actually needs to discriminate (P0 — don't build a hierarchy speculatively).
  class Error < Exception
  end
end

require "./gori/proxy/codec/message"
require "./gori/proxy/codec/http1"
require "./gori/proxy/codec/body"
require "./gori/proxy/codec/content_decode"
require "./gori/proxy/h2/frame"
require "./gori/proxy/h2/hpack"
require "./gori/proxy/h2/grpc"
require "./gori/proxy/h2/assembler"
require "./gori/proxy/h2/relay"
require "./gori/proxy/prefix_io"
require "./gori/store"
require "./gori/rules"
require "./gori/scope"
require "./gori/interceptor"
require "./gori/flow_mapper"
require "./gori/proxy/server"
require "./gori/replay/engine"
require "./gori/replay/h2_engine"
require "./gori/replay/diff"
require "./gori/fuzz"
require "./gori/mcp"
require "./gori/proxy/tls/cert_authority"
require "./gori/proxy/tls/tunnel"
require "./gori/verb"
require "./gori/verbs/core"
require "./gori/verbs/history"
require "./gori/verbs/sitemap"
require "./gori/verbs/findings"
require "./gori/fuzzy"
require "./gori/paths"
require "./gori/settings"
require "./gori/browser"
require "./gori/config"
require "./gori/convert"
require "./gori/tui"
require "./gori/app"
require "./gori/cli"
