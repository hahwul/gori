require "base64"
require "time"
require "./builder"
require "./raw"

module Gori
  module Import
    # Burp Suite's "Save items" XML export (Proxy history / Site map / Repeater tabs →
    # right-click → Save items). Each `<item>` carries the full raw request and response as
    # base64, which is why this is the only import source that reproduces a captured flow
    # byte-for-byte instead of rebuilding one from parts (see `Import::Raw`).
    #
    # Deliberately parsed with a string scanner rather than `require "xml"`. libxml2 is not
    # currently linked into gori, and pulling it in would mean adding `libxml2-dev` +
    # `libxml2-static` (and its transitive static deps) to every packaging path that builds
    # `--static` — docker/Dockerfile, the release workflow, flake.nix, Homebrew, AUR, snap —
    # for one import format. Burp's export is machine-generated with a fixed, flat shape, so
    # a scanner is sufficient and, as a side effect, has no XXE or entity-expansion surface
    # at all. The bound: this is NOT a general XML parser. Namespaced, re-ordered or
    # hand-edited variants (and Logger++/other third-party exports) are out of scope.
    module Burp
      # Tags read per item. Everything else Burp writes (`<status>`, `<responselength>`,
      # `<mimetype>`, `<comment>`, …) is a projection of the raw messages we already store,
      # so it is ignored rather than trusted — the wire bytes are the truth (P7).
      def self.parse_file(path : String) : ParseResult
        raw = File.read(path)
        # A non-base64 `<request>`/`<response>` may carry raw bytes that are not valid UTF-8.
        # Burp writes base64="true" for both by default, so this only guards the odd export;
        # scrubbing keeps the scanner's ASCII needles working instead of raising mid-file.
        raw = raw.scrub unless raw.valid_encoding?
        raise Gori::Error.new("not a Burp item export (no <items> root): #{path}") unless raw.includes?("<items")

        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        skipped = 0
        found = 0
        pos = 0
        while (block = next_element(raw, "item", pos))
          inner, pos = block
          found += 1
          # One unparseable item (no URL, undecodable base64, a host that isn't a host) skips
          # rather than discarding the rest of the export — the contract every parser shares.
          begin
            pairs << item_to_flow(inner, now)
          rescue
            skipped += 1
          end
        end
        raise Gori::Error.new("no <item> entries in #{path}") if found == 0
        ParseResult.new(pairs, skipped)
      end

      private def self.item_to_flow(item : String, now : Int64) : Builder::FlowPair
        request = bytes_of(item, "request")
        raise Gori::Error.new("item has no <request>") if request.nil? || request.empty?
        url = item_url(item)
        Raw.flow(created_at: started_at(item, now), url: url,
          raw_request: request, raw_response: bytes_of(item, "response"))
      end

      # `<url>` is the authoritative origin; fall back to composing one from
      # `<protocol>`/`<host>`/`<port>` for exports that omit it (some Site-map saves do).
      private def self.item_url(item : String) : String
        if url = text_of(item, "url").presence
          return url
        end
        host = text_of(item, "host").presence || raise Gori::Error.new("item has no <url> or <host>")
        proto = text_of(item, "protocol").presence || "https"
        port = text_of(item, "port").presence
        port && !port.empty? ? "#{proto}://#{host}:#{port}" : "#{proto}://#{host}"
      end

      # Burp writes Java's `Date.toString()` — `Tue Mar 05 12:34:56 KST 2024` — NOT RFC 3339,
      # and Crystal cannot parse a zone ABBREVIATION (`%Z` wants a loadable location name).
      # Drop the abbreviation and read the rest in UTC when it names UTC/GMT, else in the
      # local zone: a Burp export is almost always opened on a machine in the same timezone
      # it was captured in, which makes local the least-wrong reading of an ambiguous stamp.
      # As in `har.cr#parse_started`, an unparseable stamp falls back to "now" — a timestamp
      # surprise must never drop the item.
      JAVA_DATE = /\A\w{3}\s+(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+(\S+)\s+(\d{4})\z/

      private def self.started_at(item : String, now : Int64) : Int64
        s = text_of(item, "time").strip
        return now if s.empty?
        time =
          begin
            Time.parse_rfc3339(s)
          rescue Time::Format::Error
            java_date(s)
          end
        time ? time.to_unix * 1_000_000 : now
      end

      private def self.java_date(s : String) : Time?
        m = JAVA_DATE.match(s)
        return nil unless m
        zone = m[2].upcase
        loc = zone.in?("UTC", "GMT", "Z") ? Time::Location::UTC : Time::Location.local
        Time.parse("#{m[1]} #{m[3]}", "%b %d %H:%M:%S %Y", loc)
      rescue Time::Format::Error
        nil
      end

      # --- the scanner ---------------------------------------------------------

      # The inner text of `<name …>…</name>` starting at `from`, plus the offset just past
      # the closing tag. nil when there is no further occurrence.
      private def self.next_element(src : String, name : String, from : Int32) : {String, Int32}?
        needle = "<#{name}"
        pos = from
        while (open_at = src.index(needle, pos))
          after = open_at + needle.size
          ch = src[after]?
          # `<response` must not match `<responselength`: the next char has to end the name.
          unless ch && (ch.whitespace? || ch == '>' || ch == '/')
            pos = after
            next
          end
          gt = src.index('>', after)
          return nil unless gt
          return {"", gt + 1} if src[gt - 1] == '/' # <response/>
          close = src.index("</#{name}>", gt + 1)
          return nil unless close
          return {src[(gt + 1)...close], close + name.size + 3}
        end
        nil
      end

      # `{attributes, inner}` for the first `<name>` in `src`.
      private def self.element(src : String, name : String) : {String, String}?
        needle = "<#{name}"
        pos = 0
        while (open_at = src.index(needle, pos))
          after = open_at + needle.size
          ch = src[after]?
          unless ch && (ch.whitespace? || ch == '>' || ch == '/')
            pos = after
            next
          end
          gt = src.index('>', after)
          return nil unless gt
          attrs = src[after...gt]
          return {attrs, ""} if attrs.ends_with?('/')
          close = src.index("</#{name}>", gt + 1)
          return nil unless close
          return {attrs, src[(gt + 1)...close]}
        end
        nil
      end

      private def self.text_of(src : String, name : String) : String
        el = element(src, name)
        return "" unless el
        _, inner = el
        cdata?(inner) ? uncdata(inner) : unescape(inner)
      end

      # `<request base64="true">` is the default; `base64="false"` means the message sits
      # inline as CDATA (Burp only does this for wholly-textual messages).
      private def self.bytes_of(src : String, name : String) : Bytes?
        el = element(src, name)
        return nil unless el
        attrs, inner = el
        return nil if inner.empty?
        if attrs.includes?(%(base64="true")) || attrs.includes?("base64='true'")
          Base64.decode(inner.strip)
        else
          (cdata?(inner) ? uncdata(inner) : unescape(inner)).to_slice
        end
      end

      private def self.cdata?(inner : String) : Bool
        inner.lstrip.starts_with?("<![CDATA[")
      end

      # CDATA content is literal by definition — never entity-decoded.
      private def self.uncdata(inner : String) : String
        s = inner.strip
        s = s[9..] if s.starts_with?("<![CDATA[")
        s = s[0...-3] if s.ends_with?("]]>")
        s
      end

      ENTITY = /&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/

      private def self.unescape(text : String) : String
        return text unless text.includes?('&')
        text.gsub(ENTITY) do |full, m|
          e = m[1]
          case e
          when "amp"  then "&"
          when "lt"   then "<"
          when "gt"   then ">"
          when "quot" then "\""
          when "apos" then "'"
          else
            if e.starts_with?("#x") || e.starts_with?("#X")
              e[2..].to_i?(16).try { |cp| safe_chr(cp) } || full
            elsif e.starts_with?('#')
              e[1..].to_i?.try { |cp| safe_chr(cp) } || full
            else
              full # an unknown named entity stays verbatim rather than vanishing
            end
          end
        end
      end

      private def self.safe_chr(codepoint : Int32) : String?
        return nil unless 0 <= codepoint <= Char::MAX_CODEPOINT
        return nil if 0xD800 <= codepoint <= 0xDFFF # lone surrogate — not a Char
        codepoint.unsafe_chr.to_s
      end
    end
  end
end
