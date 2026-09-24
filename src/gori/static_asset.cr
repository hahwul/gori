module Gori
  # What counts as a STATIC ASSET — the images, fonts and audio/video a browsed app pulls in by
  # the dozen beside every API call (#1239). One classifier behind the QL `static:` field, and
  # through it behind the TUI's hide-static lens, `gori run history|sitemap --hide-static` and
  # MCP `hide_static`. It runs ONCE per flow, when the flow is written, into the `static_asset`
  # column (schema V30) every surface then reads, so there is no second list to drift and no
  # per-row function call on a list that reloads during live capture.
  #
  # Deliberately narrow, and in the same direction Discover's `BINARY_EXT` is: a flow is hidden
  # only when it cannot plausibly be where the finding is. Everything that can carry an endpoint,
  # a secret or script stays visible:
  #
  #   · SVG — XML, and it can carry `<script>` and `href`s.
  #   · JS and source maps — endpoints, keys, the app's own source.
  #   · CSS — `url(…)` names endpoints, and it is the target of CSS injection.
  #   · JSON, PDF, archives, `wasm`, `octet-stream` — an exposed `backup.zip` IS the finding.
  #   · HLS/M3U playlists (`audio/mpegurl`) — a list of URLs under a media type.
  #   · An image fetched THROUGH a URL parameter (`/_next/image?url=…`) — an image proxy is a
  #     server-side fetch, the classic SSRF surface, however ordinary its response looks.
  #
  # And only a SUCCESSFUL fetch is static. An error on a path that should be a plain file says
  # something about what is serving it, a redirect on one is as telling, and `status = 0` is
  # gori's own "no response" (an aborted intercept, an upstream failure) — hiding one of those
  # would hide the one row the operator acted on.
  module StaticAsset
    # Image, font and audio/video extensions. The fallback for a row with no Content-Type (a 304
    # usually carries none, and a pending row has no response yet), and the media half of
    # `Discover::Url::BINARY_EXT`, which reads it from here rather than keeping a copy.
    MEDIA_EXT = Set{
      "jpg", "jpeg", "png", "gif", "bmp", "ico", "cur", "webp", "avif", "tif", "tiff", "heic",
      "psd", "woff", "woff2", "ttf", "otf", "eot",
      "mp3", "m4a", "oga", "ogg", "wav", "flac", "aac", "opus",
      "mp4", "m4v", "webm", "ogv", "avi", "mov", "mkv", "flv", "wmv",
    }

    # Archives. NOT static — an archive a server hands out is a finding — but Discover's crawl
    # skips them for the same reason it skips media (a body it downloads and cannot read a link
    # out of), so the set lives beside `MEDIA_EXT` for `BINARY_EXT` to join.
    ARCHIVE_EXT = Set{
      "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "jar", "war", "iso", "dmg",
    }

    # Font MIME types that do not live under `font/`: the pre-RFC 8081 spellings servers still
    # send, and the one EOT has always had.
    FONT_MIME_PREFIXES = {"application/font-", "application/x-font-"}
    FONT_MIME_EXACT    = "application/vnd.ms-fontobject"

    # Query-string fragments that mean the request NAMES another URL (see the header).
    URL_PARAM_MARKERS = {"url=", "://", "%3a%2f%2f"}

    # The project-DB key that remembers whether History and the Sitemap hide static assets.
    # Beside `scope_enabled` and `history_view`, for their reason: what the operator is looking
    # at is a property of the engagement, not of the install.
    SETTING_HIDE = "hide_static"

    # Is this flow a static asset? `content_type` is the RESPONSE Content-Type as stored
    # (verbatim, parameters and case included), `target` the request target, `status` nil while
    # the response is pending.
    def self.static?(content_type : String?, target : String, status : Int32?) : Bool
      return false unless status.nil? || (200..299).includes?(status) || status == 304
      return false if names_a_url?(target)
      mime = mime_of(content_type)
      mime.empty? ? MEDIA_EXT.includes?(extension(target) || "") : media_mime?(mime)
    end

    # The lowercased extension of the target's PATH — the query and fragment cut first, so
    # `/app.js?v=logo.png` is `js` — or nil when the last segment has none (`/dir/`, a dotfile
    # like `/.png`). Discover's `binary_asset?` asks the same question of a link it has not
    # fetched yet, through this one parser.
    def self.extension(target : String) : String?
      stop = {target.index('?') || target.size, target.index('#') || target.size}.min
      return nil if stop < 3 # too short to hold a name, a dot and an extension
      slash = target.rindex('/', stop - 1) || -1
      dot = target.rindex('.', stop - 1)
      return nil unless dot && dot > slash + 1 && dot < stop - 1
      target[(dot + 1)...stop].downcase
    end

    # The MIME type alone — lowercased, parameters and surrounding space dropped. "" for a
    # missing or blank header, which is what sends a row to the extension fallback.
    private def self.mime_of(content_type : String?) : String
      return "" unless content_type
      cut = content_type.index(';')
      (cut ? content_type[0, cut] : content_type).strip.downcase
    end

    private def self.media_mime?(mime : String) : Bool
      return mime != "image/svg+xml" if mime.starts_with?("image/")
      return !mime.includes?("mpegurl") if mime.starts_with?("audio/")
      mime.starts_with?("font/") || mime.starts_with?("video/") ||
        mime == FONT_MIME_EXACT || FONT_MIME_PREFIXES.any? { |p| mime.starts_with?(p) }
    end

    private def self.names_a_url?(target : String) : Bool
      return false unless q = target.index('?')
      query = target[(q + 1)..].downcase
      URL_PARAM_MARKERS.any? { |m| query.includes?(m) }
    end

    # Whether this project hides static assets. Absent means off: on a security proxy the safe
    # direction is to hide nothing until the operator asks.
    def self.hidden?(store : Store) : Bool
      store.setting(SETTING_HIDE) == "1"
    end

    # Persist the choice. Returns whether the write committed — the caller must not apply a
    # lens the next restart would forget.
    def self.set_hidden(store : Store, hidden : Bool) : Bool
      store.set_setting(SETTING_HIDE, hidden ? "1" : "0")
    end
  end
end
