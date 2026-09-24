module Gori
  # What counts as a STATIC ASSET — the images, fonts and audio/video a browsed app pulls in by
  # the dozen beside every API call (#1239). One classifier behind the QL `static:` field, and
  # through it behind the TUI's hide-static lens, `gori run history|sitemap --hide-static` and
  # MCP `hide_static`: every surface compiles the same `gori_static_asset` SQL call, so there is
  # no second list to drift.
  #
  # Deliberately narrow, and in the same direction Discover's `BINARY_EXT` is: a flow is hidden
  # only when it cannot plausibly be where the finding is. Everything that can carry an endpoint,
  # a secret or script stays visible:
  #
  #   · SVG — XML, and it can carry `<script>` and `href`s.
  #   · JS and source maps — endpoints, keys, the app's own source.
  #   · CSS — `url(…)` names endpoints, and it is the target of CSS injection.
  #   · JSON, PDF, archives, `wasm`, `octet-stream` — an exposed `backup.zip` IS the finding.
  #
  # And an ERROR is never static: a 403/404/500 on `/logo.png` is worth a look, because an error
  # on a path that should be a plain file says something about what is serving it.
  module StaticAsset
    # Image, font and audio/video extensions. The fallback for a row with no Content-Type (a 304
    # usually carries none, and a pending row has no response yet), and the media half of
    # `Discover::Url::BINARY_EXT`, which reads it from here rather than keeping a copy.
    MEDIA_EXT = Set{
      "jpg", "jpeg", "png", "gif", "bmp", "ico", "cur", "webp", "avif", "tif", "tiff", "heic",
      "psd", "woff", "woff2", "ttf", "otf", "eot",
      "mp3", "m4a", "oga", "wav", "flac", "aac", "opus",
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

    # The project-DB key that remembers whether History and the Sitemap hide static assets.
    # Beside `scope_enabled` and `history_view`, for their reason: what the operator is looking
    # at is a property of the engagement, not of the install.
    SETTING_HIDE = "hide_static"

    # Is this flow a static asset? `content_type` is the RESPONSE Content-Type as stored
    # (verbatim, parameters and case included), `target` the request target, `status` nil while
    # the response is pending.
    def self.static?(content_type : String?, target : String, status : Int32?) : Bool
      static?(content_type.try(&.to_slice), target.to_slice, status)
    end

    # The same rule over raw bytes, which is what the `gori_static_asset` SQL function calls:
    # it runs once per scanned row on a list that reloads during live capture, and reading the
    # columns as Strings allocated two of them per row — 9.6 MB over 100k rows in
    # `bench/history_filter_bench.cr`, for a test that only ever looks at a prefix and a suffix.
    # Every name compared here is ASCII, so folding case byte by byte is exact.
    def self.static?(content_type : Bytes?, target : Bytes, status : Int32?) : Bool
      return false if status && status >= 400
      mime = mime_of(content_type)
      mime.empty? ? media_path?(target) : media_mime?(mime)
    end

    # The MIME type alone — parameters and surrounding space dropped, case kept (the compares
    # fold). Empty for a missing or blank header, which sends a row to the extension fallback.
    private def self.mime_of(content_type : Bytes?) : Bytes
      return Bytes.empty unless ct = content_type
      stop = ct.index(';'.ord.to_u8) || ct.size
      from = 0
      while from < stop && ascii_space?(ct[from])
        from += 1
      end
      while stop > from && ascii_space?(ct[stop - 1])
        stop -= 1
      end
      ct[from, stop - from]
    end

    private def self.media_mime?(mime : Bytes) : Bool
      return !ci_equal?(mime, "image/svg+xml") if ci_prefix?(mime, "image/")
      ci_prefix?(mime, "font/") || ci_prefix?(mime, "audio/") || ci_prefix?(mime, "video/") ||
        ci_equal?(mime, FONT_MIME_EXACT) || FONT_MIME_PREFIXES.any? { |p| ci_prefix?(mime, p) }
    end

    # Does the target's PATH end in a `MEDIA_EXT`? The query and fragment are cut first, so
    # `/app.js?v=logo.png` is not an image and `/logo.png?v=3` is.
    private def self.media_path?(target : Bytes) : Bool
      stop = target.size
      target.each_with_index do |b, i|
        if b == '?'.ord || b == '#'.ord
          stop = i
          break
        end
      end
      dot = -1
      i = stop - 1
      while i >= 0
        b = target[i]
        break if b == '/'.ord
        if b == '.'.ord
          dot = i
          break
        end
        i -= 1
      end
      # A name before the dot (`/.png` is a dotfile) and an extension after it.
      return false unless dot > 0 && target[dot - 1] != '/'.ord && dot < stop - 1
      ext = target[dot + 1, stop - dot - 1]
      MEDIA_EXT.any? { |e| ci_equal?(ext, e) }
    end

    private def self.ascii_space?(b : UInt8) : Bool
      b == ' '.ord || b == '\t'.ord
    end

    private def self.ci_prefix?(bytes : Bytes, prefix : String) : Bool
      bytes.size >= prefix.bytesize && ci_equal?(bytes[0, prefix.bytesize], prefix)
    end

    # `word` is lowercase ASCII; `bytes` is folded to it one byte at a time.
    private def self.ci_equal?(bytes : Bytes, word : String) : Bool
      return false unless bytes.size == word.bytesize
      word.to_slice.each_with_index do |w, i|
        b = bytes[i]
        b += 32 if b >= 'A'.ord && b <= 'Z'.ord
        return false unless b == w
      end
      true
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
