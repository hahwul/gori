require "json"
require "uri"
require "base64"
require "./js_refs"
require "./entity"
require "./discover/url"
require "./discover/headers"
require "./probe/passive/sourcemap"
require "./proxy/codec/http1"
require "./repeater/sender"
require "./outbound"
require "./store"

module Gori
  # The ACTIVE follow-up to the passive `sourcemap` detector (#1932). The passive rule only
  # FLAGS a `//# sourceMappingURL=…` reference — "verify the .map is reachable" — because
  # passive analysis must not fetch (DESIGN.md P4; the rule's own comment says so). This module
  # is the opt-in step that does fetch it: it resolves the referenced `.map`, pulls its
  # `sourcesContent` (the ORIGINAL, pre-minification sources a build left in the map), and runs
  # them back through the EXISTING endpoint extractor (`JsRefs`), so the paths and endpoints a
  # minified bundle hid surface as ordinary JS references.
  #
  # One engine, three thin adapters (DESIGN.md §2): MCP `unpack_sourcemap`, `gori run sitemap
  # js --unpack`, and the TUI History verb all call `unpack`. The map FETCH is a
  # gori-originated request, so it goes out through `Repeater::Sender` over the `Outbound`
  # chokepoint — the same scope gate every active send answers to (refused out-of-scope unless
  # the surface waived Layer 1 with allow_unscoped). An INLINE `data:` map is already in the
  # captured bytes, so it is parsed in place and sends nothing.
  #
  # The map is attacker-shaped JSON, so the parse is bounded three ways: the fetched body is
  # decoded only up to `MAX_MAP_BYTES`, at most `MAX_SOURCES` recovered sources are read, and at
  # most `MAX_REFS` references are kept overall. `JSON::Any#[]?` raises on a non-Hash, so the
  # root is narrowed with `as_h?` first (AGENTS.md traps).
  module Sourcemap
    extend self

    # Decode ceiling on the fetched `.map` body — a map can be large but a hostile one must not
    # buy unbounded decode/parse work (P6). Matches the passive rule's tail-decode cap.
    MAX_MAP_BYTES = 8 * 1024 * 1024

    # Most `sourcesContent` entries one unpack reads. A map can name thousands of modules; this
    # bounds the per-source lex/scan work, which is the same ceiling `JsRefs::DEFAULT_MAX_FLOWS`
    # puts on a body scan.
    MAX_SOURCES = 2000

    # Overall ceiling on references one unpack keeps, across every recovered source. A single
    # body is bounded by `JsRefs::MAX_REFS`; a whole map is bounded here.
    MAX_REFS = 20_000

    # How the map was obtained.
    enum Origin
      Inline  # a `data:` URI embedded in the bundle — nothing was fetched
      Fetched # the `.map` was fetched over the network through the Outbound gate
    end

    # What one unpack produced. `refs` — the recovered references (also persisted against the
    # source flow when `persist`); `reference` — the `sourceMappingURL` as found, clipped;
    # `origin` — how the map was obtained (nil when there was no reference to act on);
    # `sources` — `sourcesContent` entries read; `sources_capped` / `refs_capped` — a bound cut
    # the work short; `stored` — the references were written to the store; `error` — a refusal,
    # a fetch failure, or a parse failure (`refs` is then empty).
    record Report, refs : Array(Store::JsRef), reference : String?, origin : Origin?,
      sources : Int32, sources_capped : Bool, refs_capped : Bool, stored : Bool, error : String? do
      def self.empty(reference : String? = nil, origin : Origin? = nil, error : String? = nil) : Report
        new([] of Store::JsRef, reference, origin, 0, false, false, false, error)
      end

      def ok? : Bool
        @error.nil?
      end
    end

    # The source-map reference a response points at: the `SourceMap` / `X-SourceMap` response
    # header, else the `//# sourceMappingURL=…` comment in the (decoded) body. nil when the
    # response names none. The SAME markers the passive detector reads, so the active step
    # follows up exactly what the passive one flagged.
    def reference(detail : Store::FlowDetail) : String?
      if head = detail.response_head
        resp = Proxy::Codec::Http1.parse_response_head(head)
        if hdr = resp.headers.get?("SourceMap") || resp.headers.get?("X-SourceMap")
          stripped = hdr.strip
          return stripped unless stripped.empty?
        end
      end
      body = Entity.bytes(detail.response_head, detail.response_body, MAX_MAP_BYTES)
      return nil if body.nil? || body.empty?
      text = JsRefs.offset_text(body)
      return nil unless Probe::Passive::SourceMap.needle.matches?(text)
      Probe::Passive::SourceMap.marker.match(text).try(&.[1])
    end

    # Resolve and unpack a flow's source map. Reads the flow's `sourceMappingURL`, fetches (or
    # inline-parses) the `.map`, extracts the endpoints its `sourcesContent` reveals through
    # `JsRefs`, and — when `persist` — appends them to the flow's stored references so they
    # surface in the Sitemap and `list_js_endpoints` beside the ones the body scan found.
    def unpack(store : Store, detail : Store::FlowDetail, outbound : Gori::Outbound, *,
               verify : Bool = true, overrides : Gori::HostOverrides? = nil,
               timeout : Time::Span? = nil, persist : Bool = true) : Report
      ref = reference(detail)
      return Report.empty(error: "no source map reference in this response") unless ref
      base_pair = JsRefs.flow_script_base(detail)
      return Report.empty(clip(ref), error: "could not resolve the source's base URL") unless base_pair
      base, base_kind = base_pair

      text, origin =
        if inline = inline_json(ref)
          {inline, Origin::Inline}
        else
          fetched = fetch(detail, ref, outbound, verify, overrides, timeout)
          return fetched if fetched.is_a?(Report)
          {fetched, Origin::Fetched}
        end

      refs, sources, sources_capped, refs_capped = endpoints(text, base, base_kind)
      stored = persist && !refs.empty? ? store.add_js_refs(detail.row.id, refs) : false
      Report.new(refs, clip(ref), origin, sources, sources_capped, refs_capped, stored, nil)
    end

    # Fetch the `.map` the reference names, resolved against the bundle's URL, through the
    # Outbound gate. A scope refusal or a network failure comes back as an error Report.
    private def fetch(detail : Store::FlowDetail, ref : String, outbound : Gori::Outbound,
                      verify : Bool, overrides : Gori::HostOverrides?, timeout : Time::Span?) : String | Report
      page = Discover::Url.parse(detail.row.url) ||
             return Report.empty(clip(ref), error: "the bundle's URL could not be parsed")
      map_url = Discover::Url.resolve(page, ref) ||
                return Report.empty(clip(ref), error: "the source map reference did not resolve to an http(s) URL")
      parts = Discover::Url.parse(map_url) ||
              return Report.empty(clip(ref), error: "the source map URL could not be parsed")
      # Page-authored bytes (P7): the reference is refused where it would FRAME, never repaired.
      return Report.empty(clip(ref), error: "the source map URL carries a framing character") unless Discover::Headers.safe_url?(parts)

      sender = Repeater::Sender.new(outbound, scheme: parts.scheme, host: host_of(parts),
        port: parts.port, verify: verify, overrides: overrides, timeout: timeout)
      result = sender.send(build_get(parts))
      if err = result.error
        return Report.empty(clip(ref), origin: Origin::Fetched, error: err)
      end
      body = Entity.bytes(result.head, result.body, MAX_MAP_BYTES)
      return Report.empty(clip(ref), origin: Origin::Fetched, error: "the source map response was empty") if body.nil? || body.empty?
      JsRefs.offset_text(body)
    end

    # `Discover::Url.parse` brackets an IPv6 literal; a dial wants it bare.
    private def host_of(parts : Discover::Url::Parts) : String
      parts.host.starts_with?('[') ? parts.host[1...-1] : parts.host
    end

    # A minimal GET for the resolved map URL. `Headers.safe_url?` has already refused any CR/LF,
    # so the request line and Host cannot be framed by the reference.
    private def build_get(parts : Discover::Url::Parts) : Bytes
      target = parts.query ? "#{parts.path}?#{parts.query}" : parts.path
      target = "/" if target.empty?
      default = parts.scheme == "https" ? 443 : 80
      hostline = parts.port == default ? parts.host : "#{parts.host}:#{parts.port}"
      String.build do |io|
        io << "GET " << target << " HTTP/1.1\r\n"
        io << "Host: " << hostline << "\r\n"
        io << "Accept: */*\r\n"
        io << "Accept-Encoding: gzip, deflate\r\n"
        io << "Connection: close\r\n\r\n"
      end.to_slice
    end

    # The endpoints hidden in a map's recovered sources, deduplicated by (host, path, scheme,
    # port) — the store's key. Returns {refs, sources read, sources capped, refs capped}. Pure:
    # the whole parse-and-extract path, so a surface or a spec can run it on a fixture map with
    # no network.
    def endpoints(map_json : String, base : Discover::Url::Parts,
                  base_kind : JsRefs::Base) : {Array(Store::JsRef), Int32, Bool, Bool}
      parsed = sources_content(map_json)
      return {[] of Store::JsRef, 0, false, false} unless parsed
      contents, sources_capped = parsed
      refs = [] of Store::JsRef
      seen = Set({String, String, String, Int32}).new
      refs_capped = false
      contents.each do |src|
        lits, body_capped = JsRefs.literals(src, JsRefs::Kind::Js)
        refs_capped ||= body_capped
        lits.each do |lit|
          if refs.size >= MAX_REFS
            refs_capped = true
            break
          end
          ref = JsRefs.resolve(lit, base, base_kind)
          next if ref.is_a?(JsRefs::Drop)
          key = {ref.host, ref.path, ref.scheme, ref.port}
          refs << ref if seen.add?(key)
        end
        break if refs.size >= MAX_REFS
      end
      {refs, contents.size, sources_capped, refs_capped}
    end

    # The `sourcesContent` strings of a source map, bounded to `MAX_SOURCES` and with nil
    # entries (a module whose content the map omitted) dropped. nil when the text is not a JSON
    # object — the map is malformed and there is nothing to recover. The root is narrowed with
    # `as_h?` BEFORE indexing, since `JSON::Any#[]?` raises on a non-Hash (AGENTS.md traps).
    private def sources_content(text : String) : {Array(String), Bool}?
      root = JSON.parse(text).as_h? || return nil
      arr = root["sourcesContent"]?.try(&.as_a?)
      return {[] of String, false} unless arr
      out = [] of String
      capped = false
      arr.each do |v|
        if out.size >= MAX_SOURCES
          capped = true
          break
        end
        if s = v.as_s?
          out << s
        end
      end
      {out, capped}
    rescue JSON::ParseException
      nil
    end

    # An inline `data:` map's JSON text, or nil when the reference is an ordinary URL. Only the
    # bytes already in the captured bundle — no fetch, no scope decision. Base64 and
    # percent-encoded/plain payloads both decode; anything that does not is treated as an
    # unresolvable map (nil here, so the caller reports a parse failure, not a bogus fetch).
    private def inline_json(ref : String) : String?
      r = ref.lstrip
      return nil unless r.starts_with?("data:")
      comma = r.index(',') || return nil
      meta = r[5...comma]
      payload = r[(comma + 1)..]
      bytes =
        if meta.split(';').any? { |t| t.strip.downcase == "base64" }
          begin
            Base64.decode(payload)
          rescue
            return nil
          end
        else
          URI.decode(payload).to_slice
        end
      return nil if bytes.size > MAX_MAP_BYTES
      JsRefs.offset_text(bytes)
    end

    # The reference as evidence: clipped like a stored literal and stripped of non-printable
    # bytes, since it is server-controlled text landing in a result and the TUI.
    private def clip(ref : String) : String
      cleaned = ref.scrub.gsub(/[^\x20-\x7e]/, "")
      cleaned = cleaned[0, JsRefs::LITERAL_CHARS] if cleaned.size > JsRefs::LITERAL_CHARS
      cleaned.empty? ? "sourceMappingURL" : cleaned
    end
  end
end
