require "uri"
require "../proxy/codec/http1"

module Gori::Discover
  # URL parsing, normalization, and the TWO keys that make trap prevention work:
  #   * visit_key    — exact identity (query values KEPT): the `seen` set → cycle prevention.
  #   * template_key — folded shape (numeric/uuid/hex segments → placeholders, query reduced
  #                    to its sorted key set): the explosion counter → /user/1,2,3… collapse.
  module Url
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    HEX  = /\A[0-9a-f]{12,}\z/i # long hash/hex (md5/sha/git oid)
    NUM  = /\A\d+\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    record Parts, scheme : String, host : String, port : Int32, path : String, query : String?

    # Parse an absolute http(s) URL into normalized Parts (host lowercased, path defaulted
    # to "/"), or nil for a non-http / hostless / unparseable URL — or for one whose HOST
    # carries an octet that cannot be framed (`Codec::Http1.request_token_safe?`).
    def self.parse(url : String) : Parts?
      uri = URI.parse(url) rescue return nil
      host = uri.host
      return nil unless host && !host.empty?
      # A host with a request-line breaker in it is refused rather than repaired: percent
      # encoding is defined for a path, not for a reg-name, and `Import::Builder::HOST_VALID`
      # already states the rule that a real host never carries one (userinfo, port and the
      # `://` all sit outside `uri.host`). `URI.parse` copies such a host in verbatim —
      # `http://a b/x` yields `"a b"` — so this is the only line that can refuse it, and nil
      # is the exit every unparseable URL already takes.
      #
      # It is also the only line that can protect the CONNECT line: with an upstream proxy
      # configured, `Upstream.dial` writes `CONNECT #{host}:#{port} HTTP/1.1` out of this
      # host, and that line is synthesized far below any Discover gate.
      return nil unless Proxy::Codec::Http1.request_token_safe?(host)
      scheme = (uri.scheme || "http").downcase
      return nil unless scheme == "http" || scheme == "https"
      port = uri.port || (scheme == "https" ? 443 : 80)
      Parts.new(scheme, host.downcase, port, parse_path(uri.path), parse_query(uri.query))
    end

    private def self.parse_path(path : String?) : String
      return "/" if path.nil? || path.empty?
      # Collapse dot-segments so /a/../b and /b share one visit_key (avoids a re-crawl of the
      # same resource reached via an absolute href, which resolve() returns un-normalized).
      #
      # `ends_with?("/.")` catches a TRAILING bare dot, which the other three tests miss:
      # `/a/..` and `/a/./` both trip them, `/a/.` trips none, so it came back un-normalized
      # and `/a/.` and `/a/` were two visit_keys for one resource. That mattered little until
      # `bruteforce_root` (#395) started deriving the brute-force base from the seed's path:
      # a seed of `/api/.` produced the confine `/api/.`, which NOTHING can satisfy, since
      # every derived URL comes back through here normalized. The run then brute-forced
      # nothing — the exact shape #395 exists to remove.
      if path.includes?("..") || path.includes?("./") || path.includes?("//") || path.ends_with?("/.")
        path = normalize_path(path)
      end
      encode_unsafe(path)
    end

    private def self.parse_query(query : String?) : String?
      q = query.presence
      q ? encode_unsafe(q) : nil
    end

    PCT_HEX = "0123456789ABCDEF"

    # Percent-encode the request-line breakers that a PATH or QUERY may legitimately carry.
    #
    # The class is `Codec::Http1.request_token_safe?`'s and is not restated here: every octet
    # <= 0x20 or 0x7F, because `Sender#build_get` writes `GET #{target} HTTP/1.1` and those
    # octets are unrepresentable in a request-line token. That predicate is the rule's one
    # home (#397); this method is the only thing Discover adds to it — a REPAIR for the half
    # of the class that has one.
    #
    # The two halves get different remedies because they do different things to the wire:
    #
    #   * CR and LF FRAME. They do not corrupt one request line, they end it and start a
    #     second message (#390). No author writes them into an `<a href>`, so they are left
    #     RAW here on purpose — `Headers.safe_url?` drops such a URL at every enqueue and
    #     `Sender#fetch` refuses it at the wire, which is the disposition #390 settled.
    #     Encoding them instead would turn a splice attempt into a real request for a URL
    #     nobody authored.
    #   * Everything else (SP, TAB, DEL, the remaining C0) SEPARATES fields. `<a href="/my
    #     file.pdf">` is ordinary handwritten HTML — a browser percent-encodes it and fetches
    #     the file — so refusing it would silently shrink a crawl's coverage, and a 400 from
    #     a strict origin diverges from the soft-404 baseline (`Calibrate.hit?` scores
    #     `status_div` at +0.50), making it a false-POSITIVE source too. It is repaired.
    #
    # Applied at PARSE rather than in `build_get`, because a URL must have exactly ONE
    # spelling: the same string feeds `visit_key`, `template_key`, the Layer-2 gate question,
    # the Finding, and the Sitemap row `Persist` writes. Encoding only at the wire would
    # leave the raw octet in all five — the gate would judge a different URL than the one
    # sent, and a byte-exact Repeater re-send of a stored finding would reproduce the
    # corruption. It also makes discover ask the gate the already-encoded form every other
    # Layer-2 consumer sees, since those targets arrive off the wire from a real client.
    #
    # Idempotent, which `#{bl.dir}#{cand}` and any re-crawled link rely on: `%` is not in the
    # class, so an already-encoded path re-parses unchanged and never becomes `%2520`.
    private def self.encode_unsafe(s : String) : String
      return s unless needs_encoding?(s)
      String.build(s.bytesize + 8) do |io|
        s.each_byte do |b|
          if encodable?(b)
            io << '%' << PCT_HEX[b >> 4] << PCT_HEX[b & 0x0f]
          else
            io.write_byte(b)
          end
        end
      end
    end

    # Membership in the repairable half, per octet. The string-level rule lives in the codec
    # and must not be restated — but the encoder needs a per-BYTE test, and calling the
    # codec's predicate once per octet would allocate a String per byte on a path that runs
    # for every considered link and every brute-force candidate. So this is the one place the
    # class is written twice, and `url_spec` pins the two against each other over all 256
    # octets: `encodable?(b) == !request_token_safe?(b) && b is not CR/LF`, for every b.
    private def self.encodable?(b : UInt8) : Bool
      (b <= 0x20_u8 || b == 0x7f_u8) && b != 0x0d_u8 && b != 0x0a_u8
    end

    # `s` itself is returned for every clean URL (the overwhelming majority, and this runs
    # once per considered link and once per brute-force candidate), so scan before building.
    private def self.needs_encoding?(s : String) : Bool
      s.each_byte { |b| return true if encodable?(b) }
      false
    end

    def self.default_port?(scheme : String, port : Int32) : Bool
      (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    end

    def self.origin(p : Parts) : String
      default_port?(p.scheme, p.port) ? "#{p.scheme}://#{p.host}" : "#{p.scheme}://#{p.host}:#{p.port}"
    end

    # The full absolute URL (origin + path + optional query), used as the seed/finding url.
    def self.normalize(p : Parts) : String
      q = p.query
      q ? "#{origin(p)}#{p.path}?#{q}" : "#{origin(p)}#{p.path}"
    end

    # The string the SCOPE is asked about — deliberately NOT `normalize`.
    #
    # gori's scope model has no port dimension: `Scope.request_url` is
    # `"#{scheme}://#{host}#{target}"` and the proxy splits host from port before asking
    # (`client_conn.cr`), so every other Layer-2 consumer judges a port-LESS URL. `normalize`
    # appends `:port` whenever it is not 80/443, so on a non-default port discover was asking
    # about `http://acme.test:8080/logout` while a rule was written against
    # `http://acme.test/logout` — and a host-qualified `string` or `regex` EXCLUDE therefore
    # never matched. That is the exact rule the brute-forcer is supposed to obey, silently
    # failing open on any `:8080`/`:8443` target.
    #
    # Kept as its own function rather than folded into `normalize` because the two answers
    # must differ: the crawl, the findings and the Sitemap rows all need the port (it is part
    # of the resource's identity), and only the gate question drops it.
    def self.gate_url(p : Parts) : String
      q = p.query
      base = "#{p.scheme}://#{p.host}#{p.path}"
      q ? "#{base}?#{q}" : base
    end

    # EXACT identity — lowercase host, drop default port + fragment, sort query pairs, KEEP
    # values (?page=1 ≠ ?page=2). Populates `seen`.
    def self.visit_key(p : Parts) : String
      q = canonical_query(p.query, fold: false)
      base = "#{origin(p)}#{p.path}"
      q.empty? ? base : "#{base}?#{q}"
    end

    # FOLDED template — path segments folded to placeholders, query reduced to its SORTED
    # KEY SET (values dropped). /user/1?tab=a and /user/2?tab=b both → ".../user/{n}?tab".
    def self.template_key(p : Parts) : String
      folded = p.path.split('/').map { |seg| seg.empty? ? seg : fold_segment(seg) }.join("/")
      q = canonical_query(p.query, fold: true)
      base = "#{origin(p)}#{folded}"
      q.empty? ? base : "#{base}?#{q}"
    end

    UUID_LEN = 36
    DATE_LEN = 10
    HEX_MIN  = 12

    # NOTE the literal branch returns the DOWNCASED segment — callers rely on template_key being
    # case-folded, so this is not display text.
    #
    # Gated the way Sitemap.template_class already gates the same three patterns: an ordinary
    # segment ("api", "users", "index.html") is the overwhelming majority and now reaches no
    # regex at all. All four patterns are ASCII-only, so a non-ASCII segment can never match and
    # is rejected before PCRE2 sees it. Sizes are exact for UUID/DATE and a floor for HEX.
    #
    # ORDER IS LOAD-BEARING: HEX also matches a long run of digits, so NUM must be tested first
    # or every long numeric id would fold to {hex}.
    def self.fold_segment(seg : String) : String
      d = ascii_downcase(seg)
      return d unless d.ascii_only?
      sz = d.bytesize
      return "{uuid}" if sz == UUID_LEN && UUID.matches?(d)
      return "{date}" if sz == DATE_LEN && DATE.matches?(d)
      return "{n}" if all_digits?(d)
      return "{hex}" if sz >= HEX_MIN && HEX.matches?(d)
      d
    end

    # `seg` itself when it holds no ASCII uppercase (the common case — String#downcase builds a
    # fresh String even when nothing changes), else a downcased copy.
    private def self.ascii_downcase(seg : String) : String
      seg.each_byte { |b| return seg.downcase if 0x41_u8 <= b <= 0x5a_u8 }
      seg
    end

    # Allocation- and PCRE-free stand-in for NUM (`\A\d+\z`).
    private def self.all_digits?(s : String) : Bool
      return false if s.empty?
      s.each_byte { |b| return false unless 0x30_u8 <= b <= 0x39_u8 }
      true
    end

    private def self.canonical_query(query : String?, *, fold : Bool) : String
      return "" unless query && !query.empty?
      pairs = query.split('&').reject(&.empty?).map do |pair|
        k, _, v = pair.partition('=')
        fold ? k : "#{k}=#{v}"
      end
      pairs.sort!
      pairs.uniq! if fold
      pairs.join("&")
    end

    # One brute-force candidate resolved against its directory: the Parts the gates ask about,
    # and the ONE string that is simultaneously the frontier entry (`normalize`) and the
    # `seen` key (`visit_key`) — those two are the same string whenever the query is nil,
    # which on this path it always is.
    record Probe, parts : Parts, url : String

    # `#{dir_url}#{cand}` without the `URI.parse`.
    #
    # `enqueue_probes` runs in the ORCHESTRATOR fiber — the single fiber that also dispatches
    # every job to every worker — once per calibrated directory, over the whole wordlist: 315
    # built-in words times (1 + extensions) times directories. Each candidate used to cost a
    # full `URI.parse` plus three more separately built strings (`visit_key`, `gate_url`,
    # `normalize`) to produce one frontier entry, and adding coverage anywhere upstream
    # multiplies that by more directories.
    #
    # Returns nil for any candidate whose fast derivation could differ from `parse`'s by even
    # one byte; the caller then falls back to `parse`, so this can only ever be an
    # optimization and never a second opinion. The conditions mirror `parse_path` exactly:
    #
    #   * nothing `encode_unsafe` would rewrite and no CR/LF (`plain_bytes?`), so the path
    #     goes through verbatim;
    #   * no `?` or `#`, so `URI.parse` would split off neither a query nor a fragment;
    #   * none of the four dot/slash shapes `parse_path` reacts to, so `normalize_path` would
    #     have been a no-op.
    #
    # The host, scheme and port are the directory's own — `dir_url` is required to be
    # `normalize(dir)`, and `Engine#enqueue_probes` checks that once per directory rather
    # than trusting it. That is what makes `origin(dir) + dir.path + cand` and
    # `dir_url + cand` provably the same bytes.
    def self.probe(dir : Parts, dir_url : String, cand : String) : Probe?
      return nil if cand.empty?
      return nil unless plain_bytes?(cand)
      path = dir.path + cand
      return nil if path.includes?("..") || path.includes?("./") ||
                    path.includes?("//") || path.ends_with?("/.")
      Probe.new(Parts.new(dir.scheme, dir.host, dir.port, path, nil), dir_url + cand)
    end

    # A candidate that reaches the request line as itself: no octet `encode_unsafe` repairs or
    # `Headers.safe_url?` refuses (both are the `<= 0x20 || 0x7F` class), neither of the two
    # delimiters `URI.parse` acts on, and nothing outside ASCII. A wordlist entry outside this
    # set — a query, a traversal, an IIS trailing-space bypass, a non-ASCII name — is not
    # rejected, it just takes `parse`.
    #
    # ASCII is a deliberate condition, not tidiness. `URI.parse` RSTRIPS its path with
    # `Char#whitespace?`, which is Unicode-aware and reaches well past this method's byte class:
    # a candidate ending in U+00A0, U+3000 or U+2028 comes back from `parse` with the character
    # GONE while the concatenation here keeps it — one wordlist entry, two different URLs, and
    # `probe` is documented as an optimization that may never be a second opinion. Copy-pasted
    # and HTML-scraped wordlists carry trailing NBSP routinely. A per-byte test cannot answer a
    # per-CHARACTER Unicode predicate that the stdlib is free to widen, so the guard is drawn
    # where the two derivations are provably identical instead: the whole built-in wordlist is
    # ASCII and keeps the fast path, and a non-ASCII entry pays one `URI.parse` it was always
    # paying before this optimization existed.
    private def self.plain_bytes?(s : String) : Bool
      s.each_byte do |b|
        return false if b <= 0x20_u8 || b >= 0x7f_u8
        return false if b == 0x3f_u8 || b == 0x23_u8 # '?' '#'
      end
      true
    end

    # The directory a URL lives in — everything up to and including the last '/'. Query and
    # fragment are dropped. Used to seed the brute-forcer per directory.
    def self.dir_of(p : Parts) : String
      "#{origin(p)}#{dir_path(p.path)}"
    end

    def self.dir_path(path : String) : String
      idx = path.rindex('/')
      idx ? path[0, idx + 1] : "/"
    end

    # Resolve `href` (from a page at `base`) into an absolute http(s) URL, or nil for
    # non-http / fragment-only / unparseable. Handles absolute, scheme-relative (//h/p),
    # absolute-path (/p), and relative (p, ../p) forms with dot-segment normalization.
    def self.resolve(base : Parts, href : String) : String?
      h = href.strip
      return nil if h.empty?
      # drop fragment
      if fi = h.index('#')
        h = h[0, fi]
      end
      return nil if h.empty? || h.starts_with?('#')
      lower = h.downcase
      return nil if lower.starts_with?("mailto:") || lower.starts_with?("tel:") ||
                    lower.starts_with?("javascript:") || lower.starts_with?("data:") ||
                    lower.starts_with?("about:") || lower.starts_with?("blob:")

      if lower.starts_with?("http://") || lower.starts_with?("https://")
        return h
      elsif h.starts_with?("//")
        return "#{base.scheme}:#{h}"
      end

      # split off href's own query before path resolution
      hq = nil
      if qi = h.index('?')
        hq = h[(qi + 1)..]
        h = h[0, qi]
      end

      # normalize_path ONCE. The relative branch used to normalize and then be normalized again
      # by the unconditional call that followed — running the whole split/Array-of-segments/join
      # chain twice for an identical result, on the commonest href shape there is.
      abs_path =
        if h.starts_with?('/')
          normalize_path(h)
        elsif scheme_prefixed?(lower)
          return nil # some other scheme (ftp:, ws:, …)
        else
          normalize_path(dir_path(base.path) + h)
        end
      url = "#{origin(base)}#{abs_path}"
      hq ? "#{url}?#{hq}" : url
    end

    # Allocation- and PCRE-free stand-in for `\A[a-z][a-z0-9+.-]*:`, gated for the same reason
    # `fold_segment` gates its four patterns behind `ascii_only?`: a Regex on invalid UTF-8
    # raises ArgumentError out of PCRE2. `resolve` is the one link entry point that sees
    # REMOTE-chosen bytes — a 3xx `Location` reaches it straight off the wire, unscrubbed,
    # while every page-derived href came through `Extract`, which scrubs — and `downcase`
    # keeps a lone Latin-1 octet intact, so `caf\xE9/x` used to raise here. That raise lands on
    # discover's orchestrator fiber, which ends the whole run instead of dropping one link.
    # The scheme class is pure ASCII, so the byte scan is exact.
    private def self.scheme_prefixed?(s : String) : Bool
      bytes = s.to_slice
      return false if bytes.empty?
      return false unless 0x61_u8 <= bytes[0] <= 0x7a_u8
      i = 1
      while i < bytes.size
        b = bytes[i]
        return true if b == 0x3a_u8 # ':'
        return false unless (0x61_u8 <= b <= 0x7a_u8) || (0x30_u8 <= b <= 0x39_u8) ||
                            b == 0x2b_u8 || b == 0x2e_u8 || b == 0x2d_u8 # '+' '.' '-'
        i += 1
      end
      false
    end

    # Collapse "." and ".." segments (RFC 3986 §5.2.4, simplified). Preserves a leading and
    # trailing slash. Input is always an absolute path here.
    def self.normalize_path(path : String) : String
      trailing = path.ends_with?('/')
      out = [] of String
      path.split('/').each do |seg|
        case seg
        when "", "." then next
        when ".."    then out.pop?
        else              out << seg
        end
      end
      result = "/" + out.join("/")
      result += "/" if trailing && !result.ends_with?('/')
      result
    end
  end
end
