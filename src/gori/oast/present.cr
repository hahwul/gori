require "json"
require "./types"

module Gori::Oast
  # The SINGLE JSON shape for an interaction, shared by `gori run oast --format json` and
  # the MCP oast_* tools so the two surfaces can never drift (mirrors jwt/present.cr).
  module Present
    extend self

    def interaction(i : Interaction, provider : String)
      {
        unique_id:    i.unique_id,
        protocol:     i.protocol,
        method:       i.method,
        source:       i.source_ip,
        destination:  i.full_id,
        provider:     provider,
        timestamp:    i.at.to_rfc3339,
        raw_request:  i.raw_request,
        raw_response: i.raw_response,
      }
    end

    def payload(url : String, session_id : Int64, provider : String)
      {payload_url: url, session_id: session_id, provider: provider}
    end
  end
end
