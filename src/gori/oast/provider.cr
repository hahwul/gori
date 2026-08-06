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

    # The per-payload NONCE inside a payload this provider minted — the substring that comes
    # back in an `Interaction`'s `full_id` / `raw_request` and is unique to ONE
    # `generate_payload` call. It exists so a caller that planted a payload somewhere and
    # walked away (the probe out-of-band bridge) can later tie an arriving callback back to
    # the exact request it came from, without knowing which provider minted it.
    #
    # `correlation_id` is NOT enough: it is per-SESSION, so every payload from one listener
    # shares it and any callback would match every outstanding probe. Four of the five
    # providers append their nonce as the last path segment or the first host label, which is
    # what this default reads; CustomHttp puts it in a query parameter and overrides.
    #
    # Lower-cased because the wire is case-insensitive on both sides that carry it: DNS labels
    # are, and a resolver doing 0x20 case randomization will echo a payload host back in mixed
    # case that never matches the bytes we minted. Every comparison against this value must
    # lower-case its own side too.
    def payload_token(payload : String) : String
      s = payload.strip
      s = s[0...s.index('#')] if s.index('#')
      # Path first: `…/{corr}/{nonce}` (webhook.site, postbin). Then the leading host label:
      # `{corr}{nonce}.oast.host` (interactsh) / `{nonce}.{corr}.host` (BOAST).
      seg = s.split('/').reject(&.empty?).last? || s
      seg = seg.split('?').first
      seg.split('.').first.downcase
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
        # Scale-detect before constructing: `Time.unix` raises ArgumentError past
        # 315_537_897_599, and a millisecond epoch (~1.7e12) is three orders past that.
        # postb.in's `inserted` field is epoch MILLIseconds, so the shipped "Public
        # PostBin" preset raised on every callback — and Postbin#poll shifts
        # destructively, so the raise discarded interactions already consumed from the
        # bin. The String branch beside this one has always been rescue-guarded; this one
        # was the only unguarded field, because every other value routes through `field()`
        # and reaches that guarded path as a string.
        n = v.to_i64
        begin
          if n.abs >= 100_000_000_000_000 # microseconds
            Time.unix(n // 1_000_000)
          elsif n.abs >= 100_000_000_000 # milliseconds
            Time.unix_ms(n)
          else
            Time.unix(n)
          end
        rescue ArgumentError
          Time.utc
        end
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
