require "./discover/extract"
require "./discover/url"
require "./discover/headers"
require "./probe/passive/js_scan"
require "./proxy/codec/http1"
require "./param_inventory"
require "./sitemap"
require "./entity"
require "./utf8"
require "./scope"
require "./ql"
require "./store"

module Gori
  # Endpoints REFERENCED in captured JavaScript (#1243): the string literals in a bundle or an
  # inline `<script>` that name a path — `fetch("/api/v1/users")`, an SPA route table, an axios
  # base URL — kept with where they were read (the flow, the byte offset, the line). The Sitemap
  # draws the ones nobody has requested as their own dimmed nodes, which is the surface an SPA
  # hides from a tree built out of the routes someone happened to click.
  #
  # ZERO requests: the bytes are already in the store, so nothing here touches `Outbound` or
  # spends P4 budget — the operator decides later whether a reference is worth a send. The one
  # engine behind all three surfaces (TUI Sitemap, `gori run sitemap js`, MCP
  # `scan_js_endpoints` / `list_js_endpoints`), and like the parameter inventory it runs ON
  # DEMAND off the capture path (P6). Unlike the inventory it PERSISTS what it found (Store V34):
  # the tree reloads on every data_version tick, and re-lexing megabyte bundles per reload is
  # exactly the cost the inventory's on-demand read avoids by never being asked that often.
  #
  # A literal is PAGE-AUTHORED bytes (P7): it resolves through `Url.resolve` / `Url.parse`, so a
  # separator is percent-encoded where it merely breaks and a CR/LF that would frame is refused
  # (`Headers.safe_url?`), never repaired — the disposition every crawled href already gets.
  module JsRefs
    extend self

    # The extractor's version, recorded on every scan marker (`js_ref_scans.version`). Bump it
    # when extraction changes what a body yields: every flow scanned by an older version then
    # reads as unscanned, and the next scan redoes it.
    VERSION = 1

    # The same bounds the crawl puts on one body, for the same reasons (`Extract::MAX_SCAN`,
    # `Extract::MAX_LINKS`): a hostile or generated bundle must not buy unbounded work.
    MAX_SCAN = Discover::Extract::MAX_SCAN
    MAX_REFS = Discover::Extract::MAX_LINKS

    # Longest literal kept as evidence, in characters. A reference is shown, not replayed from
    # this text, so a 2 KiB absolute URL is clipped for the screen.
    LITERAL_CHARS = 200

    # A template literal is followed past `${…}` for at most this many path bytes in all, and an
    # interpolation is looked for within INTERP_MAX bytes of its `${`. The path branch of
    # `Extract::ENDPOINT` stops at 256 for the same reason.
    TEMPLATE_MAX = 256
    INTERP_MAX   = 128

    # The placeholder a template literal's `${…}` becomes: `/api/users/${id}` is stored as
    # `/api/users/{expr}`, never as the cut directory `/api/users/`, which is a DIFFERENT
    # endpoint the page never named.
    EXPR = "{expr}"

    # Resolutions between scheduler yields inside ONE body. `Url.resolve` + `Url.parse` per
    # literal, up to MAX_REFS of them, is otherwise a single synchronous stretch on the fiber the
    # proxy shares (P6).
    YIELD_EVERY = 256

    # Newest flows one scan reads by default. A scan reads each body whole, so this bounds a
    # run's work; `truncated` says unscanned flows remain and a second run continues with them.
    DEFAULT_MAX_FLOWS = 500

    FLAG_COMMENT   = 1
    FLAG_TEMPLATED = 2

    # How the base a literal was resolved against was chosen — the provenance a root-relative
    # reference needs, because a CDN-hosted bundle's `"/api/x"` targets the PAGE's origin.
    enum Base
      Absolute # written as a full URL (or `//host/…`): taken as written
      Page     # an inline script: the page's own URL, or its `<base href>`
      Referer  # an external script: the document its captured request's Referer names
      Guessed  # an external script with no usable Referer: the script's own origin

      def label : String
        to_s.downcase
      end

      def self.from_label?(s : String) : Base?
        values.find { |b| b.label == s }
      end
    end

    # Which bodies are scanned: a JS response, or an HTML page (its inline scripts).
    enum Kind
      Js
      Html
    end

    # A literal as it sits in the body, before resolution. `offset` is a byte offset into the
    # decoded body text, `line` 1-based.
    record Literal, text : String, offset : Int32, line : Int32, in_comment : Bool, templated : Bool

    # What one flow yielded. `body_capped` — the body was longer than MAX_SCAN (or its capture
    # was cut) and only the head was read; `refs_capped` — MAX_REFS stopped the literal pass;
    # `unsafe` — literals refused for a framing octet (P7).
    record FlowResult, refs : Array(Store::JsRef), body_capped : Bool, refs_capped : Bool, unsafe : Int32

    # --- which bodies -----------------------------------------------------------------

    # The body kind a flow's response is scanned as, or nil for one that is not scanned. A
    # declared JavaScript or HTML type decides; a `.js`/`.mjs` path decides only when the type is
    # missing or `text/plain` (a static host that never learnt the extension). `Context#js?` is
    # the Probe's content-type gate, and this is the same test on the stored column.
    def kind(content_type : String?, target : String) : Kind?
      low = content_type.try(&.downcase.presence)
      if low
        return Kind::Js if low.includes?("javascript") || low.includes?("ecmascript")
        return Kind::Html if low.includes?("text/html")
      end
      return Kind::Js if (low.nil? || low.starts_with?("text/plain")) && js_path?(target)
      nil
    end

    private def js_path?(target : String) : Bool
      path = Sitemap.path_part(Sitemap.normalize_path(target)).downcase
      path.ends_with?(".js") || path.ends_with?(".mjs")
    end

    # A SQL superset of `kind` on the stored columns — the scan's prefilter, so a page of
    # candidates is not mostly images. `kind` still decides per row; this only has to never
    # say no where `kind` says yes. LIKE folds ASCII case itself.
    CANDIDATE_SQL = "(content_type LIKE '%javascript%' OR content_type LIKE '%ecmascript%' " \
                    "OR content_type LIKE '%text/html%' " \
                    "OR ((content_type IS NULL OR content_type = '' OR content_type LIKE 'text/plain%') " \
                    "AND (target LIKE '%.js' OR target LIKE '%.mjs' OR target LIKE '%.js?%' " \
                    "OR target LIKE '%.mjs?%' OR target LIKE '%.js#%' OR target LIKE '%.mjs#%')))"

    # --- extraction (pure) --------------------------------------------------------------

    # The endpoint literals in one decoded body, deduplicated by their text, and whether
    # MAX_REFS stopped the pass. A literal seen both in a comment and in code is kept as the
    # CODE occurrence: the first spelling is not the stronger one when it is commented out.
    def literals(text : String, kind : Kind) : {Array(Literal), Bool}
      out = [] of Literal
      index = {} of String => Int32
      capped = false
      lines = LineCounter.new(text.to_slice)
      matches = 0
      Probe::Passive::JsScan.each_script(text, kind.html?, kind.js?) do |script, at|
        probe = CommentProbe.new(script, Probe::Passive::JsScan.strip_comments(script))
        # The lex and the pass are separate stretches on the scheduler (P6). The lex is the
        # longest one the scan holds — ~5.5 ms on a 2 MiB bundle in a release build, ~8 ms on a
        # non-ASCII one (bench/js_refs_bench.cr) — and cannot be split without a resumable copy
        # of the lexer; the pass yields every YIELD_EVERY matches.
        Fiber.yield
        Discover::Extract.each_endpoint(script) do |value, from, to|
          Fiber.yield if (matches += 1) % YIELD_EVERY == 0
          lit, templated = template_path(script, value, from, to)
          comment = probe.comment?(from)
          if i = index[lit]?
            if out[i].in_comment && !comment
              out[i] = Literal.new(lit, at + from, lines.at(at + from), false, templated)
            end
            next
          end
          if out.size >= MAX_REFS
            capped = true
            break
          end
          index[lit] = out.size
          out << Literal.new(lit, at + from, lines.at(at + from), comment, templated)
        end
        break if capped
      end
      {out, capped}
    end

    # A template literal followed past its interpolations: `` `/api/users/${id}/orders` ``
    # reads `/api/users/{expr}/orders`. Only when the literal really is a template — opened by a
    # backtick, where `${` interpolates; in a quoted string it is text. The path branch of
    # ENDPOINT stops right before `${`; the URL branch runs through it (its class admits `$` and
    # `{`), so there the cut is made inside the value.
    private def template_path(s : String, value : String, from : Int32, to : Int32) : {String, Bool}
      bytes = s.to_slice
      if bytes[from] == '`'.ord
        return {value, false} unless interp_at?(bytes, to)
        continue_template(bytes, value, to)
      elsif from > 0 && bytes[from - 1] == '`'.ord && (cut = value.byte_index("${"))
        continue_template(bytes, value.byte_slice(0, cut), from + cut)
      else
        {value, false}
      end
    end

    private def interp_at?(bytes : Bytes, pos : Int32) : Bool
      pos + 1 < bytes.size && bytes[pos] == '$'.ord && bytes[pos + 1] == '{'.ord
    end

    # From `pos` (at a `${`), alternate interpolation → path run until neither follows. An
    # interpolation with no closing brace inside INTERP_MAX still becomes EXPR — the literal
    # named SOMETHING there — and ends the walk.
    private def continue_template(bytes : Bytes, prefix : String, pos : Int32) : {String, Bool}
      path = String.build(TEMPLATE_MAX) do |io|
        io << prefix
        size = prefix.bytesize
        while interp_at?(bytes, pos) && size < TEMPLATE_MAX
          io << EXPR
          size += EXPR.bytesize
          close = closing_brace(bytes, pos + 2)
          break unless close
          pos = close + 1
          while pos < bytes.size && size < TEMPLATE_MAX && path_byte?(bytes[pos])
            io.write_byte(bytes[pos])
            size += 1
            pos += 1
          end
        end
      end
      {path, true}
    end

    # The index of the `}` that closes an interpolation whose body starts at `pos`, counting
    # nested braces, or nil when none does within INTERP_MAX bytes.
    private def closing_brace(bytes : Bytes, pos : Int32) : Int32?
      depth = 1
      limit = Math.min(bytes.size, pos + INTERP_MAX)
      i = pos
      while i < limit
        case bytes[i]
        when '{'.ord then depth += 1
        when '}'.ord
          depth -= 1
          return i if depth == 0
        end
        i += 1
      end
      nil
    end

    # ENDPOINT's path class — `[A-Za-z0-9_\-.~%\/]` — as a byte test.
    private def path_byte?(b : UInt8) : Bool
      (0x41_u8 <= b <= 0x5a_u8) || (0x61_u8 <= b <= 0x7a_u8) || (0x30_u8 <= b <= 0x39_u8) ||
        b == '_'.ord || b == '-'.ord || b == '.'.ord || b == '~'.ord || b == '%'.ord || b == '/'.ord
    end

    # Line numbers for ascending byte offsets, counted incrementally: one pass over the body in
    # all, however many literals it holds.
    private class LineCounter
      @pos = 0
      @line = 1

      def initialize(@bytes : Bytes)
      end

      def at(offset : Int32) : Int32
        limit = Math.min(offset, @bytes.size)
        while @pos < limit
          @line += 1 if @bytes.unsafe_fetch(@pos) == 0x0a_u8
          @pos += 1
        end
        @line
      end
    end

    # "Does the literal starting at this byte sit in a comment?", asked in ascending order.
    # `strip_comments` blanks a comment to spaces with CHAR offsets preserved, so a literal's
    # opening byte (a quote, or the `h` of a URL — never a space) reads as a space there exactly
    # when it was commented out. Byte offsets line up only while no multi-byte character was
    # blanked; past one, the two strings are walked in lockstep — one pass per script in all, not
    # a walk from the start per question.
    #
    # The walk is by lead BYTE, not `Char::Reader`: decoding every character of a 2 MiB bundle
    # twice cost ~9 ms (bench/js_refs_bench.cr), and the only question per character is whether
    # the stripped copy blanked it (one space byte for the whole character) or kept it (the same
    # bytes). The text is valid UTF-8 (`Utf8.text`), so a lead byte's width is exact.
    private class CommentProbe
      @op = 0 # byte position in the original script
      @kp = 0 # the same character's byte position in the stripped copy

      def initialize(@orig : String, @kept : String)
        @aligned = @orig.bytesize == @kept.bytesize
      end

      def comment?(byte_off : Int32) : Bool
        o = @orig.to_slice
        k = @kept.to_slice
        if @aligned
          return false if byte_off >= k.size
          return k[byte_off] == 0x20_u8 && o[byte_off] != 0x20_u8
        end
        while @op < byte_off && @op < o.size && @kp < k.size
          width = utf8_width(o[@op])
          @kp += blanked?(o, k) ? 1 : width
          @op += width
        end
        @op < o.size && @kp < k.size && blanked?(o, k)
      end

      private def blanked?(o : Bytes, k : Bytes) : Bool
        k[@kp] == 0x20_u8 && o[@op] != 0x20_u8
      end

      private def utf8_width(lead : UInt8) : Int32
        if lead < 0x80_u8
          1
        elsif lead < 0xe0_u8
          2
        elsif lead < 0xf0_u8
          3
        else
          4
        end
      end
    end

    # --- resolution --------------------------------------------------------------------

    # Why a literal did not become a reference.
    enum Drop
      Unresolvable # not an http(s) reference once resolved (a scheme gori does not follow, junk)
      Filtered     # a bare `/`, or a static asset (image, font, archive)
      Unsafe       # a framing octet (CR/LF) — refused, never repaired (P7)
    end

    # One literal resolved against `base` into a stored reference, or why it was not. Every
    # path goes through `Url.parse` (which percent-encodes a separator and refuses an unsafe
    # host) and `Headers.safe_url?` (which refuses CR/LF anywhere), so nothing reaches the store
    # raw that the crawl would not send.
    def resolve(lit : Literal, base : Discover::Url::Parts, base_kind : Base) : Store::JsRef | Drop
      url = Discover::Url.resolve(base, lit.text) || return Drop::Unresolvable
      parts = Discover::Url.parse(url) || return Drop::Unresolvable
      return Drop::Unsafe unless Discover::Headers.safe_url?(parts)
      path = Sitemap.path_part(Sitemap.node_path(parts.path))
      return Drop::Filtered if path == "/" || Discover::Url.binary_asset?(parts.path)
      target = (q = parts.query) ? "#{parts.path}?#{q}" : parts.path
      kind = absolute?(lit.text) ? Base::Absolute : base_kind
      flags = (lit.in_comment ? FLAG_COMMENT : 0) | (lit.templated ? FLAG_TEMPLATED : 0)
      Store::JsRef.new(parts.scheme, parts.host, parts.port, path, target, clip(lit.text),
        lit.offset, lit.line, flags, kind.label)
    end

    private def absolute?(text : String) : Bool
      text.starts_with?("//") || Gori::Url.absolute_form?(text)
    end

    private def clip(s : String) : String
      s.size > LITERAL_CHARS ? "#{s[0, LITERAL_CHARS]}…" : s
    end

    # The references in one captured flow, or nil when its response is not a scanned kind.
    # Reads the DECODED entity (a gzip bundle is text only after inflating) up to MAX_SCAN.
    def extract(detail : Store::FlowDetail) : FlowResult?
      row = detail.row
      kind = kind(row.content_type, row.target) || return nil
      page = Discover::Url.parse(row.url) || return FlowResult.new([] of Store::JsRef, false, false, 0)
      body = Entity.bytes(detail.response_head, detail.response_body, MAX_SCAN + 1)
      return FlowResult.new([] of Store::JsRef, false, false, 0) if body.nil? || body.empty?
      capped = detail.response_body_truncated? || body.size > MAX_SCAN
      text = Utf8.text(body.size > MAX_SCAN ? body[0, MAX_SCAN] : body)
      base, base_kind = kind.html? ? html_base(text, page) : script_base(detail.request_head, page)
      lits, refs_capped = literals(text, kind)
      refs, unsafe = resolve_all(lits, base, base_kind)
      FlowResult.new(refs, capped, refs_capped, unsafe)
    end

    # Resolve and deduplicate by (host, path) — the store's key — keeping the code occurrence
    # over a commented one, and yielding every YIELD_EVERY resolutions.
    private def resolve_all(lits : Array(Literal), base : Discover::Url::Parts,
                            base_kind : Base) : {Array(Store::JsRef), Int32}
      refs = [] of Store::JsRef
      index = {} of {String, String} => Int32
      unsafe = 0
      lits.each_with_index do |lit, n|
        Fiber.yield if n > 0 && n % YIELD_EVERY == 0
        ref = resolve(lit, base, base_kind)
        if ref.is_a?(Drop)
          unsafe += 1 if ref.unsafe?
          next
        end
        key = {ref.host, ref.path}
        if i = index[key]?
          refs[i] = ref if refs[i].flags & FLAG_COMMENT != 0 && ref.flags & FLAG_COMMENT == 0
        else
          index[key] = refs.size
          refs << ref
        end
      end
      {refs, unsafe}
    end

    # An inline script resolves against the page — or the `<base href>` it declares (RFC 3986
    # 5.1.1 ranks it above the document's URL). A declared base that cannot be framed is refused
    # like any other page-authored URL, and the page's own URL is then only a guess.
    private def html_base(text : String, page : Discover::Url::Parts) : {Discover::Url::Parts, Base}
      if href = Discover::Extract.base_href(text)
        url = Discover::Url.resolve(page, href)
        parts = url.try { |u| Discover::Url.parse(u) }
        return {parts, Base::Page} if parts && Discover::Headers.safe_url?(parts)
        return {page, Base::Guessed}
      end
      {page, Base::Page}
    end

    # An external script's root-relative literal targets the DOCUMENT that loaded it, not the
    # host that served the bundle — a CDN bundle's `"/api/cart"` is a call to the page's origin.
    # The captured request's Referer names that document when the browser sent one (a
    # cross-origin load sends at least the origin under the default policy); without it the
    # script's own origin is the only candidate, and the reference says it was guessed.
    private def script_base(request_head : Bytes, script : Discover::Url::Parts) : {Discover::Url::Parts, Base}
      if (ref = referer(request_head)) && (parts = Discover::Url.parse(ref)) && Discover::Headers.safe_url?(parts)
        return {parts, Base::Referer}
      end
      {script, Base::Guessed}
    end

    private def referer(head : Bytes) : String?
      Proxy::Codec::Http1.parse_request_head(head).headers.get?("Referer").try(&.strip.presence)
    rescue
      nil
    end

    # --- the store-backed scan ---------------------------------------------------------

    # `filter` narrows the candidate flows (the TUI passes the tree's own flow set). `rescan`
    # reads flows already scanned by this VERSION again.
    record ScanOptions, filter : QL::Filter = QL::EMPTY, max_flows : Int32 = DEFAULT_MAX_FLOWS,
      rescan : Bool = false

    # `refs` — references stored by this run; `new_endpoints` — distinct (host, path) the project
    # did not reference before it; `write_failures` — flows whose write rolled back (still
    # unscanned, retried by the next run); `truncated` — unscanned candidates remain.
    record ScanReport, flows_scanned : Int32, refs : Int32, new_endpoints : Int32,
      bodies_capped : Int32, refs_capped : Int32, unsafe : Int32, write_failures : Int32,
      truncated : Bool

    # Scan the not-yet-scanned JS/HTML flows matching `opts.filter`, newest first, and store what
    # they reference. `stop` is polled between flows (the TUI flips it on a project switch).
    # Nothing is sent: this reads the store and writes derived rows.
    def scan(store : Store, opts : ScanOptions = ScanOptions.new, stop : -> Bool = -> { false }) : ScanReport
      candidates = QL::Filter.new("state = ? AND #{CANDIDATE_SQL}", [Store::FlowState::Complete.value.to_i64] of DB::Any)
      filter = QL.and(opts.filter, candidates)
      filter = QL.and(filter, Store.js_unscanned_filter(VERSION)) unless opts.rescan
      before = store.js_ref_endpoint_count
      refs = capped_bodies = capped_refs = unsafe = failures = 0
      keep = ->(row : Store::FlowRow) { !kind(row.content_type, row.target).nil? }
      scanned, truncated = ParamInventory.each_flow(store, filter, opts.max_flows, keep, stop) do |row|
        next unless detail = store.get_flow(row.id)
        next unless res = extract(detail)
        if store.record_js_scan(row.id, res.refs, VERSION)
          refs += res.refs.size
        else
          failures += 1
        end
        capped_bodies += 1 if res.body_capped
        capped_refs += 1 if res.refs_capped
        unsafe += res.unsafe
      end
      after = store.js_ref_endpoint_count
      ScanReport.new(scanned, refs, Math.max(after - before, 0), capped_bodies, capped_refs,
        unsafe, failures, truncated)
    end

    # --- reading back ------------------------------------------------------------------

    # `include_requested` — also list references whose endpoint has captured traffic (the
    # default lists only the unrequested ones). `all_hosts` — also list references to hosts gori
    # never captured and no scope include names (see `visible_host?`). `in_scope` — only
    # references the project scope includes (the caller refuses an unconfigured scope).
    record ListOptions, host : String? = nil, path_prefix : String? = nil,
      include_requested : Bool = false, all_hosts : Bool = false, in_scope : Bool = false,
      include_comments : Bool = true

    # One referenced endpoint: every sighting of one (host, path), with the newest source as its
    # provenance. `requested` — captured traffic reaches this node (nil when the traffic read was
    # capped and could not say). `in_comment` — EVERY sighting was commented out.
    record Endpoint, scheme : String, host : String, port : Int32, path : String, target : String,
      flows : Int32, requested : Bool?, in_comment : Bool, templated : Bool, base : Base,
      flow_id : Int64, offset : Int32, line : Int32, literal : String, source_url : String? do
      def url : String
        Store::FlowRow.url_of(scheme, host, port, target)
      end
    end

    # `hidden_hosts` — references left out because their host is unknown to the project (the
    # `all_hosts` rule); `requested_unknown` — the traffic read hit `Store::SITEMAP_MAX`, so some
    # `requested` answers are nil; `scanned_flows` — flows carrying a current scan marker.
    record ListReport, endpoints : Array(Endpoint), hidden_hosts : Int32, requested_unknown : Bool,
      scanned_flows : Int32, capped : Bool

    # The stored references, one row per (host, path), filtered by `opts`. Reads the traffic's
    # endpoint set once to answer `requested` the way the Sitemap tree does: a reference is
    # requested when captured traffic lands on its query-less node path.
    def list(store : Store, opts : ListOptions = ListOptions.new, scope : Scope? = nil) : ListReport
      sightings = store.js_ref_sightings(host: opts.host.try(&.strip.presence), raise_on_error: true)
      capped = sightings.size >= Store::JS_REF_READ_MAX
      captured, hosts, unknown = captured_paths(store)
      shown = [] of Endpoint
      hidden = 0
      sightings.chunk_while { |a, b| a.host == b.host && a.path == b.path }.each do |group|
        ep = endpoint(group, captured, unknown)
        next if (prefix = opts.path_prefix.presence) && !ep.path.starts_with?(prefix)
        next if ep.requested == true && !opts.include_requested
        next if ep.in_comment && !opts.include_comments
        next if opts.in_scope && !(scope && scope.matches_url?(ep.url, ep.host))
        unless opts.all_hosts || visible_host?(ep.host, ep.url, hosts, scope)
          hidden += 1
          next
        end
        shown << ep
      end
      ListReport.new(shown, hidden, unknown, store.js_scanned_count(VERSION), capped)
    end

    # The host rule, shared with the tree (`Sitemap.attach_js_refs!` takes it as `new_host`): a
    # reference to a host the project already holds traffic for is shown; one to a host it has
    # never seen is shown only when a scope INCLUDE names it. A bundle names hosts nobody would
    # map — `www.w3.org` namespaces, framework docs, license URLs — and an operator who wants a
    # never-captured API host (`api.target.test`) in the picture says so by scoping it.
    def visible_host?(host : String, url : String, known : Set(String), scope : Scope?) : Bool
      known.includes?(host.downcase) || (scope ? scope.matches_url?(url, host) : false)
    end

    # Attach the stored references to a built Sitemap tree under the two rules both trees share
    # (the TUI's `SitemapView#apply_reload`, the CLI's `collect_sitemap`): `visible_host?`'s host
    # rule — a host the tree lacks is added only when a scope include names the reference, and
    # never when `new_hosts` is false (a `/` query narrowed the tree, and a host outside it would
    # read as a match) — and, with `lens` on, the scope lens itself: a reference is not a flow,
    # so the SQL filter the tree was built through never saw it.
    def attach!(hosts : Array(Sitemap::Node), nodes : Array(Store::JsRefNode), scope : Scope?, *,
                new_hosts : Bool, lens : Bool) : Nil
      if lens && scope
        nodes = nodes.select { |r| scope.in_scope_url?(node_url(r), r.host) }
      end
      Sitemap.attach_js_refs!(hosts, nodes) do |r|
        new_hosts && !scope.nil? && scope.matches_url?(node_url(r), r.host)
      end
    end

    # A tree reference's URL, for a scope question.
    def node_url(r : Store::JsRefNode) : String
      Store::FlowRow.url_of(r.scheme, r.host, r.port, r.path)
    end

    private def endpoint(group : Array(Store::JsRefSighting), captured : Set({String, String}),
                         unknown : Bool) : Endpoint
      first = group.find { |s| s.flags & FLAG_COMMENT == 0 } || group.first
      requested = captured.includes?({first.host, first.path}) ? true : (unknown ? nil : false)
      flows = group.map(&.flow_id).uniq.size
      Endpoint.new(first.scheme, first.host, first.port, first.path, first.target, flows, requested,
        group.all? { |s| s.flags & FLAG_COMMENT != 0 }, group.any? { |s| s.flags & FLAG_TEMPLATED != 0 },
        Base.from_label?(first.base) || Base::Guessed, first.flow_id, first.offset, first.line,
        first.literal, first.source_url)
    end

    # {(host, query-less node path) of every captured endpoint, every captured host, whether the
    # read was capped}, hosts lowercased — `Url.parse` lowercases a reference's host and a flow
    # keeps its host as captured.
    def captured_paths(store : Store) : {Set({String, String}), Set(String), Bool}
      entries = store.sitemap_entries(QL::EMPTY, Store::SITEMAP_MAX, raise_on_error: true)
      paths = Set({String, String}).new
      hosts = Set(String).new
      entries.each do |(host, _, target)|
        h = host.downcase
        hosts << h
        paths << {h, Sitemap.path_part(Sitemap.node_path(target))}
      end
      {paths, hosts, entries.size >= Store::SITEMAP_MAX}
    end
  end
end
