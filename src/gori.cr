# gori — free/open-source TUI web proxy (MITM).
#
# This is the library entrypoint. The executable's behaviour lives in
# `Gori::CLI.run` (added in a later build step); for now this file only
# establishes the module, version, and the single base error type.
module Gori
  VERSION = "0.1.0"

  # Canonical project home — surfaced in the TUI Help → About page (and reusable
  # by the CLI/about screens). Kept beside VERSION as the project's identity.
  REPOSITORY_URL = "https://github.com/hahwul/gori"

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
require "./gori/links"
require "./gori/rules"
require "./gori/scope"
require "./gori/interceptor"
require "./gori/flow_mapper"
require "./gori/proxy/server"
require "./gori/replay/engine"
require "./gori/replay/h2_engine"
require "./gori/replay/ws_engine"
require "./gori/replay/diff"
require "./gori/fuzz"
require "./gori/miner"
require "./gori/prism"
require "./gori/mcp"
require "./gori/proxy/tls/cert_authority"
require "./gori/proxy/tls/tunnel"
require "./gori/verb"
require "./gori/verbs/core"
require "./gori/verbs/import"
require "./gori/verbs/history"
require "./gori/import"
require "./gori/verbs/sitemap"
require "./gori/verbs/findings"
require "./gori/verbs/prism"
require "./gori/prism_query"
require "./gori/fuzzy"
require "./gori/paths"
require "./gori/settings"
require "./gori/env"
require "./gori/hotkeys"
require "./gori/browser"
require "./gori/config"
require "./gori/update"
require "./gori/convert"
require "./gori/pretty"
require "./gori/sse"
require "./gori/saml"
require "./gori/jwt"
require "./gori/graphql"
require "./gori/form_data"
require "./gori/decoded_view"
require "./gori/sitemap"
require "./gori/tui"
require "./gori/app"
require "./gori/cli"
