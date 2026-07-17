require "json"
require "./types"
require "./http"
require "./session"

module Gori::Oast
  # An OAST backend, bound to one configured endpoint (host + optional token). Four calls:
  #   register        — mint server-side state, return a fresh Session (once, at "listen").
  #   generate_payload — LOCAL, no network: a fresh unique payload URL from a Session.
  #   poll            — fetch + normalize new interactions.
  #   deregister      — best-effort release of server state (never raises).
  #
  # generate_payload staying local is a load-bearing invariant: it lets the TUI mint a
  # payload to insert into a Repeater/Fuzzer request on the main fiber without a socket.
  abstract class Provider
    getter kind : ProviderKind
    getter host : String # the configured server/base URL
    getter token : String?

    def initialize(@kind : ProviderKind, @host : String, @token : String? = nil)
    end

    abstract def register(http : Http) : Session
    abstract def generate_payload(session : Session) : String
    abstract def poll(http : Http, session : Session) : Array(Interaction)

    # Best-effort teardown. Default no-op; override where the server supports it. MUST NOT
    # raise (callers deregister during cleanup where an error is noise).
    def deregister(http : Http, session : Session) : Nil
    end

    # Build the right Provider for a configured (kind, host, token). The single dispatch
    # point shared by TUI/CLI/MCP.
    def self.build(kind : ProviderKind, host : String, token : String? = nil) : Provider
      case kind
      in .interactsh?   then Interactsh.new(host, token)
      in .custom_http?  then CustomHttp.new(host, token)
      in .webhook_site? then WebhookSite.new(host, token)
      in .boast?        then Boast.new(host, token)
      in .postbin?      then Postbin.new(host, token)
      end
    end

    # ---- shared helpers for the JSON providers ----

    # Parse a response body as JSON, or raise a clean engine error with a short snippet.
    protected def parse_json(body : String) : JSON::Any
      JSON.parse(body)
    rescue ex : JSON::ParseException
      raise Gori::Error.new("OAST #{kind.label}: bad JSON response (#{snippet(body)})")
    end

    # The configured host as a normalized base URL (scheme forced to https when absent,
    # trailing slash trimmed).
    protected def base_url : String
      h = @host.strip.rstrip('/')
      h.starts_with?("http") ? h : "https://#{h}"
    end

    protected def json_headers : Hash(String, String)
      h = {"Content-Type" => "application/json"}
      if (t = @token) && !t.empty?
        h["Authorization"] = t
      end
      h
    end

    protected def auth_headers : Hash(String, String)
      h = {} of String => String
      if (t = @token) && !t.empty?
        h["Authorization"] = t
      end
      h
    end

    protected def snippet(body : String) : String
      body.size > 120 ? "#{body[0, 120]}…" : body
    end

    # First present value among `keys` as a String (numbers stringified, nulls skipped).
    protected def field(j : JSON::Any, *keys : String) : String?
      keys.each do |k|
        v = j[k]?
        next unless v
        case r = v.raw
        when String then return r
        when Nil    then next
        else             return r.to_s
        end
      end
      nil
    end

    # A JSON body's item list: a bare array, or the first present of data/requests/events.
    protected def items_array(json : JSON::Any) : Array(JSON::Any)
      if arr = json.as_a?
        arr
      else
        {"data", "requests", "events"}.each do |k|
          if a = json[k]?.try(&.as_a?)
            return a
          end
        end
        [] of JSON::Any
      end
    end

    # A monotonic-ish timestamp parse, tolerant of RFC3339 / epoch / missing → now.
    protected def parse_time(raw : JSON::Any?) : Time
      case v = raw.try(&.raw)
      when String
        Time.parse_rfc3339(v) rescue (Time.parse_utc(v, "%Y-%m-%dT%H:%M:%S") rescue Time.utc)
      when Int64, Int32
        Time.unix(v.to_i64)
      else
        Time.utc
      end
    end
  end
end

require "./providers/interactsh"
require "./providers/custom_http"
require "./providers/webhook_site"
require "./providers/boast"
require "./providers/postbin"
