require "./types"
require "./engine"
require "../outbound"
require "../scope"
require "../import/builder"
require "../flow_mapper"
require "../proxy/codec/http1"

# Surface-side adapters that bridge the pure Discover engine to the project's Scope and
# Store. Kept OUT of the discover.cr umbrella so the engine itself stays Store-free; the
# CLI / TUI / MCP require this file explicitly.
module Gori::Discover
  # ScopePolicy over the project's Gori::Scope: excludes + sandbox deny in every mode; the
  # include allowlist is the boundary for scope-aware containment.
  class StoreScope < ScopePolicy
    @last_reload : Time::Instant
    @configured : Bool

    def initialize(@scope : Gori::Scope)
      @last_reload = Time.instant
      @configured = @scope.configured?
    end

    # Layer 2, and therefore the line that owes DESIGN.md §7's "one reload semantic for the
    # active-traffic scope gate" (#354). Discover's Layer 2 runs through THIS object and not
    # through `Outbound#sweep_block`, because the engine is deliberately Store-free — which is
    # exactly why `Outbound#refresh` was never reached: `cli/run/discover.cr` and
    # `mcp/tools/discover.cr` both use their `Outbound` for `Plan.build` plus the up-front
    # Layer-1 guard, and then hand the engine a policy that never calls back into it. So
    # `gori run project scope add exclude string logout` in a second terminal stopped an
    # in-flight fuzz/mine/sequence within a second while an in-flight discover — potentially
    # thousands of probes — kept going against a start-time snapshot (#396). Only the TUI was
    # exempt, and by accident: it shares its live `Scope` object, which its own data_version
    # poll reloads.
    # `url` is the port-FREE spelling every url-level INCLUDE was written for (#407);
    # `exclude_url` is the same url WITH its port and is asked of the EXCLUDE side ONLY, and
    # only when there is a distinct one (a default port has none). Before it, an
    # `exclude string ":8443"` held on the proxy and not here, so one scope described two
    # different sets depending on which tool was asking (#884). The sandbox test stays on the
    # port-free url: it is `sandbox && !allowlisted?`, and the allowlist is the include side.
    def allowed?(url : String, host : String, exclude_url : String?) : Bool
      refresh
      return false if @scope.sandbox_blocks?(url, host) || @scope.excluded?(url, host)
      !(exclude_url && @scope.excluded?(exclude_url, host))
    end

    # Layer 1, whose only caller (`Engine#bounded_url`) asks it immediately after `allowed?`,
    # so it already reads whatever that call refreshed.
    def boundary?(url : String, host : String) : Bool
      @scope.matches_url?(url, host)
    end

    # Layer 1, and SNAPSHOT at construction on purpose — the one thing the #396 reload must
    # not make mutable.
    #
    # This answers "does a scope exist to bound the crawl", which is what switches
    # `Containment::ScopeAware` between the same-origin fallback and `boundary?`. Delegating
    # it live would let the reload rewrite the containment mode mid-run, and the direction it
    # rewrites in is catastrophic: on a project with NO rules, an operator adding the single
    # canonical `exclude string logout` flips `configured?` false→true, and `matches_url?`
    # requires at least one INCLUDE (`Scope#allowlisted_unlocked?` — an excludes-only scope is
    # deliberately not an allowed range), so `boundary?` becomes false for EVERY url. The
    # operator asked to skip one path and the whole crawl would stop, silently.
    #
    # DESIGN.md §3 and the #354 entry already draw this line: Layer 1's strictness is settled
    # per surface before the first byte, Layer 2 is the layer that is identical everywhere and
    # applied continuously. #396 asked for the second, not the first.
    def configured? : Bool
      @configured
    end

    # `Outbound#refresh`, mirrored rather than re-decided — including the interval constant, so
    # the two can never name different numbers. Re-read the scope from its store before a
    # Layer-2 check, at most once per `Outbound::RELOAD_INTERVAL`; advance the clock BEFORE the
    # blocking reload so a burst of concurrent worker fibers cannot stampede the store (the
    # check-then-set is a non-yielding critical section on the single-threaded scheduler); and
    # swallow a failure so the last-known rules stay in force, degrading to the old snapshot
    # rather than breaking the run or failing open.
    private def refresh : Nil
      now = Time.instant
      return if now - @last_reload < Gori::Outbound::RELOAD_INTERVAL
      @last_reload = now
      @scope.reload
    rescue
      # keep the last-known scope on a reload failure
    end
  end

  # StoreScope for a run that passed --allow-unscoped on an OUT-OF-SCOPE seed: the hard
  # sandbox/exclude gate (allowed?) still applies, but configured? reports false so
  # scope-aware containment falls back to same-origin (bounding the crawl to the seed the
  # operator explicitly named). Without this, StoreScope#boundary? blocked every hop the
  # seed's own include rules don't match — so --allow-unscoped fetched only the seed +
  # robots/sitemap, brute-force never started, and the spider was stuck at depth 0, silently
  # contradicting the flag. (The include boundary is exactly what --allow-unscoped waives.)
  class UnscopedStoreScope < StoreScope
    def configured? : Bool
      false
    end
  end

  # Persist a discovered endpoint as a normal flow row so it surfaces in the Sitemap (which
  # groups by host/method/target) and can be OPENED — request and response, the bytes the run
  # actually exchanged — everywhere a captured flow can be. A finding with no status (rare)
  # becomes a Pending flow.
  #
  # Given the run's `Exchange` this stores the WIRE TRUTH (P7): the request head the Sender
  # framed and the response head + raw body the origin answered with, mapped through the same
  # `FlowMapper` live capture and the Burp raw-item import use. Without one — a status-less
  # finding, or a backend that frames no bytes — it falls back to the synthesized stub below,
  # which describes the finding rather than reproducing it. The two are deliberately NOT
  # blended: a synthesized head must never be presented as bytes someone sent, so the stub
  # keeps its `X-Gori-Discover` provenance marker and the captured pair carries no header
  # gori invented.
  module Persist
    # `surface` says which of gori's three faces ran the crawl; it is required, because every
    # caller is a surface-specific controller that knows the answer and a defaulted one would
    # let a fourth file itself under a third's name. `source_ref` points at the run when the
    # surface has a handle an operator can use later (MCP's job id) and is nil when it does not.
    def self.flow_pair(f : Finding, created_at : Int64,
                       exchange : Exchange? = nil, *,
                       surface : FlowSource::Surface,
                       source_ref : String? = nil) : Import::Builder::FlowPair
      return captured_pair(f, created_at, exchange, surface, source_ref) if exchange
      if status = f.status
        resp_headers = Import::Builder::Headers.new
        resp_headers << {"Content-Type", f.content_type.not_nil!} if f.content_type
        resp_headers << {"Content-Length", f.length.to_s}
        resp_headers << {"X-Gori-Discover", f.source.label}
        Import::Builder.complete_flow(
          created_at, f.url, f.method,
          Import::Builder::Headers.new, nil, "HTTP/1.1",
          status, reason_for(status), resp_headers, nil, f.content_type, nil,
          source: FlowSource::Kind::Discover, source_surface: surface, source_ref: source_ref)
      else
        Import::Builder.pending_request(created_at, f.url, f.method,
          source: FlowSource::Kind::Discover, source_surface: surface, source_ref: source_ref)
      end
    end

    # The captured half: raw head bytes in, storage projections out. `Import::Builder` is a
    # SERIALIZER and would re-emit the head from parsed parts (see `Import::Raw`'s note on why
    # that destroys wire truth), so only its URL split and its body cap are reused here.
    private def self.captured_pair(f : Finding, created_at : Int64, ex : Exchange,
                                   surface : FlowSource::Surface,
                                   source_ref : String?) : Import::Builder::FlowPair
      scheme, host, port, _ = Import::Builder.endpoint(f.url)
      req = Proxy::Codec::Http1.parse_request_head(ex.request_head)
      request = FlowMapper.request(req, scheme: scheme, host: host, port: port,
        created_at: created_at, sni: ex.sni,
        source: FlowSource::Kind::Discover, source_surface: surface, source_ref: source_ref)
      stored, trunc, size = Import::Builder.capped(ex.body, ex.body_size)
      # `incomplete` is the OTHER way a stored body is short of what the origin framed (it cut
      # the response off); `capped` only knows about the ceiling gori applied. Either one means
      # a reader must not treat these bytes as the whole response.
      response = FlowMapper.response(ex.response, flow_id: 0, body: stored,
        duration_us: ex.duration_us,
        body_truncated: trunc || ex.incomplete, body_size: size)
      Import::Builder::FlowPair.new(request, response)
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
