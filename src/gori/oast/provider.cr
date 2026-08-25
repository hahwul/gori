require "json"
require "./types"
require "./http"
require "./session"

module Gori::Oast
  # An OAST backend, bound to one configured endpoint (host + optional token). Five calls:
  #   register        — mint server-side state, return a fresh Session (once, at "listen").
  #   resume          — revive the server state of a Session restored from the store.
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

    # New interactions, OLDEST FIRST. The order is part of the contract, not an accident of
    # each server's API: every consumer treats a poll's result as chronological — the TUI
    # appends to a list it renders reversed, the store's rowid order IS the display order after
    # a reload, and `gori run oast` prints them as they come. A provider whose API answers
    # newest-first (webhook.site, which must ask for that page to see recent hits at all) flips
    # its batch back here rather than making three surfaces sort.
    #
    # A poll that CANNOT be answered raises. "Nothing came back" and "the server refused us"
    # are the two states an out-of-band listener must never conflate: a rotated token, an
    # expired webhook token or a rate limit would otherwise read exactly like a quiet target,
    # for as long as the operator left it running.
    abstract def poll(http : Http, session : Session) : Array(Interaction)

    # Re-arm a Session rebuilt from the store so its ALREADY-PLANTED payloads keep resolving.
    # This is what makes a delayed callback — the stored payload that only fires on a nightly
    # job, the back-office browser that opens the mail tomorrow — reachable at all: without it
    # a restart could only `register` a NEW correlation id, and every payload minted before it
    # was dead the moment the process exited.
    #
    # Default no-op, which is the honest answer for four of the five backends: webhook.site,
    # postbin, BOAST and custom-http keep (or never had) their state independently of us, so
    # polling the persisted correlation id is the whole of resuming. interactsh overrides —
    # ITS server drops a session on deregister or restart. Unlike `deregister`, this one MAY
    # raise: the operator asked for the session back, and a resume that quietly failed would
    # leave a listener that polls a correlation id the server has never heard of.
    def resume(http : Http, session : Session) : Nil
    end

    # Best-effort teardown. Default no-op; override where the server supports it. MUST NOT
    # raise (callers deregister during cleanup where an error is noise).
    #
    # A no-op here is not "the teardown succeeded" — it is "this build cannot tear this one
    # down", and `deregisters?` below is what tells the two apart. `Sessions.release` used to
    # read a silent return as success and answer `true`, so `gori run oast release` reported a
    # teardown that never left the process for four of the five backends.
    def deregister(http : Http, session : Session) : Nil
    end

    # Can this provider TELL its server to forget a session? False by default, so a backend
    # added without a teardown is honestly reported as one rather than inheriting a silent
    # success. Overridden true by the three that have a real delete API: interactsh
    # (`POST /deregister`), webhook.site (`DELETE /token/{uuid}`), postbin
    # (`DELETE /api/bin/{binId}`).
    #
    # BOAST is the one backend that registers server-side state and offers NO way to release
    # it: go-boast derives the id from the secret and keeps serving it. `release` says so
    # instead of pretending, because the operator's next move — rotate the BOAST secret, or
    # leave the engagement's listener collecting — depends entirely on knowing.
    def deregisters? : Bool
      false
    end

    # Did `register` create state on a THIRD-PARTY server at all? True for four of the five.
    #
    # CustomHttp is "bring your own OAST server": its register mints a local correlation id and
    # never dials anything, so there is nothing on any server to release and a `release` that
    # refused would be as wrong as one that claimed a teardown. It is the only member of the
    # third state, and it exists so the two honest answers ("released" / "cannot be released")
    # stay honest.
    def server_state? : Bool
      true
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
    rescue JSON::ParseException
      raise Gori::Error.new("OAST #{kind.label}: bad JSON response (#{snippet(body)})")
    end

    # The configured host as a normalized base URL (scheme forced to https when absent,
    # trailing slash trimmed).
    protected def base_url : String
      Provider.normalize_endpoint(@host)
    end

    # ONE home for that normalisation, because the TUI has to reproduce it exactly: a
    # session stores the normalised form ("https://oast.pro") while the provider row holds
    # whatever was typed ("oast.pro"), so the controller's "is this the same endpoint?"
    # comparison only works if both sides normalise identically. It had a byte-identical
    # copy whose comment already said it normalises "the way `Provider#base_url` does".
    #
    # `Url.absolute_form?`, not `starts_with?("http")`: schemes are case-insensitive
    # (RFC 3986 3.1), so a host typed `HTTPS://oast.pro` used to come back
    # `https://HTTPS://oast.pro`.
    def self.normalize_endpoint(url : String) : String
      h = url.strip.rstrip('/')
      Gori::Url.absolute_form?(h) ? h : "https://#{h}"
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
        return arr
      end
      # `JSON::Any#[]?` RAISES on anything that is neither a Hash nor Nil, so a self-hosted
      # endpoint answering `0` or `"ok"` with a 200 used to come out of `poll` as a stdlib
      # "Expected Hash for #[]?" rather than as "this body carries no interactions". Read the
      # object form only when there IS one — this is the deliberately tolerant provider.
      obj = json.as_h? || return [] of JSON::Any
      {"data", "requests", "events"}.each do |k|
        if a = obj[k]?.try(&.as_a?)
          return a
        end
      end
      [] of JSON::Any
    end

    # The named array of a JSON OBJECT body, or empty. Same hazard as `items_array`: a poll
    # body comes from a third-party server whose content this engine already treats as
    # adversarial, and a bare array (or a scalar) where an object was expected must read as
    # "no interactions", not as a crash the poller reports as a poll error.
    protected def array_field(json : JSON::Any, key : String) : Array(JSON::Any)
      json.as_h?.try(&.[key]?).try(&.as_a?) || [] of JSON::Any
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
