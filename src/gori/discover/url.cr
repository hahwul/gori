require "uri"

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
    # to "/"), or nil for a non-http / hostless / unparseable URL.
    def self.parse(url : String) : Parts?
      uri = URI.parse(url) rescue return nil
      host = uri.host
      return nil unless host && !host.empty?
      scheme = (uri.scheme || "http").downcase
      return nil unless scheme == "http" || scheme == "https"
      port = uri.port || (scheme == "https" ? 443 : 80)
      path = uri.path
      path = "/" if path.nil? || path.empty?
      # Collapse dot-segments so /a/../b and /b share one visit_key (avoids a re-crawl of the
      # same resource reached via an absolute href, which resolve() returns un-normalized).
      path = normalize_path(path) if path.includes?("..") || path.includes?("./") || path.includes?("//")
      Parts.new(scheme, host.downcase, port, path, uri.query.presence)
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

    def self.fold_segment(seg : String) : String
      d = seg.downcase
      case
      when UUID.matches?(d) then "{uuid}"
      when DATE.matches?(d) then "{date}"
      when NUM.matches?(d)  then "{n}"
      when HEX.matches?(d)  then "{hex}"
      else                       d
      end
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

      if h.starts_with?("http://") || h.starts_with?("https://")
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

      abs_path =
        if h.starts_with?('/')
          h
        elsif lower.matches?(/\A[a-z][a-z0-9+.-]*:/)
          return nil # some other scheme (ftp:, ws:, …)
        else
          normalize_path(dir_path(base.path) + h)
        end
      abs_path = normalize_path(abs_path)
      url = "#{origin(base)}#{abs_path}"
      hq ? "#{url}?#{hq}" : url
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
