require "./types"
require "./engine"
require "../scope"
require "../import/builder"

# Surface-side adapters that bridge the pure Discover engine to the project's Scope and
# Store. Kept OUT of the discover.cr umbrella so the engine itself stays Store-free; the
# CLI / TUI / MCP require this file explicitly.
module Gori::Discover
  # ScopePolicy over the project's Gori::Scope: excludes + sandbox deny in every mode; the
  # include allowlist is the boundary for scope-aware containment.
  class StoreScope < ScopePolicy
    def initialize(@scope : Gori::Scope)
    end

    def allowed?(url : String, host : String) : Bool
      !@scope.sandbox_blocks?(url, host) && !@scope.excluded?(url, host)
    end

    def boundary?(url : String, host : String) : Bool
      @scope.matches_url?(url, host)
    end

    def configured? : Bool
      @scope.configured?
    end
  end

  # Persist a discovered endpoint as a normal flow row so it surfaces in the Sitemap (which
  # groups by host/method/target). No response body is stored — the Sitemap needs only
  # method/target/status; re-send via Repeater for the live body. A finding with no status
  # (rare) becomes a Pending flow.
  module Persist
    def self.flow_pair(f : Finding, created_at : Int64) : Import::Builder::FlowPair
      if status = f.status
        resp_headers = Import::Builder::Headers.new
        resp_headers << {"Content-Type", f.content_type.not_nil!} if f.content_type
        resp_headers << {"Content-Length", f.length.to_s}
        resp_headers << {"X-Gori-Discover", f.source.label}
        Import::Builder.complete_flow(
          created_at, f.url, f.method,
          Import::Builder::Headers.new, nil, "HTTP/1.1",
          status, reason_for(status), resp_headers, nil, f.content_type, nil)
      else
        Import::Builder.pending_request(created_at, f.url, f.method)
      end
    end

    private def self.reason_for(status : Int32) : String
      case status
      when 200 then "OK"
      when 201 then "Created"
      when 204 then "No Content"
      when 301 then "Moved Permanently"
      when 302 then "Found"
      when 401 then "Unauthorized"
      when 403 then "Forbidden"
      else          ""
      end
    end
  end
end
