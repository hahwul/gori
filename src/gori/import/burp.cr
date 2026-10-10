require "base64"
require "time"
require "./builder"
require "./raw"
require "./xml_text"

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
    # `--static` — packaging/docker/Dockerfile, the release workflow, flake.nix, Homebrew,
    # AUR, snap — for one import format. Burp's export is machine-generated with a fixed, flat shape, so
    # a scanner is sufficient and, as a side effect, has no XXE or entity-expansion surface
    # at all. The bound: this is NOT a general XML parser. Namespaced, re-ordered or
    # hand-edited variants (and Logger++/other third-party exports) are out of scope.
    module Burp
      # Tags read per item. Everything else Burp writes (`<status>`, `<responselength>`,
      # `<mimetype>`, `<comment>`, …) is a projection of the raw messages we already store,
      # so it is ignored rather than trusted — the wire bytes are the truth (P7).
      def self.parse_file(path : String, prov : Provenance = Provenance.none) : ParseResult
        # NOT scrubbed. A `base64="false"` item carries its message INLINE, so a scrub of the
        # file is a scrub of the wire bytes — and this importer's whole reason to exist is
        # that those bytes survive. It used to `raw = raw.scrub unless raw.valid_encoding?`
        # on the theory that scrubbing "keeps the scanner's ASCII needles working"; the
        # scanner never needed it. It works in BYTE offsets (`byte_index`, `byte_slice`), and
        # every needle is ASCII — a byte that can never sit inside a multibyte character — so
        # invalid UTF-8 around a tag cannot move one, and `byte_slice` copies the bytes between
        # tags exactly as they are.
        #
        # What the scrub actually did, measured through `gori run import --burp` into a real
        # store on a source body `a=1&bin=<ff fe 01 02>&b=2`:
        #
        #   stored request_body  61 3d 31 26 62 69 6e 3d ef bf bd ef bf bd 01 02 26 62 3d 32
        #
        # — 20 bytes under a stored head still declaring `Content-Length: 16`, reported as
        # `count: 1, skipped: 0`. The store IS the evidence, so that loss was permanent.
        #
        # Text elements (`<url>`, `<host>`, `<time>`) are scrubbed where they are READ, in
        # `text_of`: those really are text, and a byte that cannot be one has no meaning
        # there. `bytes_of` is the path that must stay exact, and it never calls `text_of`.
        raw = File.read(path)
        raise Gori::Error.new("not a Burp item export (no <items> root): #{path}") unless raw.includes?("<items")

        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        skipped = 0
        found = 0
        pos = 0
        while block = next_element(raw, "item", pos)
          inner, pos = block
          found += 1
          # One unparseable item (no URL, undecodable base64, a host that isn't a host) skips
          # rather than discarding the rest of the export — the contract every parser shares.
          begin
            pairs << item_to_flow(inner, now, prov)
          rescue
            skipped += 1
          end
        end
        raise Gori::Error.new("no <item> entries in #{path}") if found == 0
        ParseResult.new(pairs, skipped)
      end

      private def self.item_to_flow(item : String, now : Int64, prov : Provenance) : Builder::FlowPair
        request = bytes_of(item, "request")
        raise Gori::Error.new("item has no <request>") if request.nil? || request.empty?
        url = item_url(item)
        Raw.flow(created_at: started_at(item, now), url: url,
          raw_request: request, raw_response: bytes_of(item, "response"),
          source_surface: prov.surface, source_ref: prov.ref)
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
          rescue Time::Format::Error | ArgumentError
            java_date(s)
          end
        time && Builder.representable?(time) ? time.to_unix * 1_000_000 : now
      end

      private def self.java_date(s : String) : Time?
        m = JAVA_DATE.match(s)
        return nil unless m
        zone = m[2].upcase
        loc = zone.in?("UTC", "GMT", "Z") ? Time::Location::UTC : Time::Location.local
        Time.parse("#{m[1]} #{m[3]}", "%b %d %H:%M:%S %Y", loc)
      rescue Time::Format::Error | ArgumentError
        nil
      end

      # --- the scanner ---------------------------------------------------------

      # Every offset in the scanner is a BYTE offset, and one only ever goes back into these
      # helpers. It walked characters (`String#index(needle, pos)`, `src[a...b]`), and on a
      # string that is not pure ASCII each of those counts from byte 0 to find `pos` — once per
      # item, so a 16 MB export took 17 s (56 s with a single non-ASCII byte in it) where the
      # byte walk takes ~20 ms. The needles are ASCII, so a byte search finds exactly the tags
      # the char search did, and `byte_slice` copies what lies between them verbatim (P7).

      # The inner text of `<name …>…</name>` starting at `from`, plus the offset just past
      # the closing tag. nil when there is no further occurrence.
      private def self.next_element(src : String, name : String, from : Int32) : {String, Int32}?
        needle = "<#{name}"
        pos = from
        while open_at = src.byte_index(needle, pos)
          after = open_at + needle.bytesize
          # `<response` must not match `<responselength`: the next char has to end the name.
          unless name_ends_at?(src, after)
            pos = after
            next
          end
          gt = src.byte_index('>', after)
          return nil unless gt
          return {"", gt + 1} if src.to_unsafe[gt - 1] == '/'.ord # <response/>
          close = close_at(src, name, gt + 1)
          return nil unless close
          return {src.byte_slice(gt + 1, close - gt - 1), close + name.bytesize + 3}
        end
        nil
      end

      # `{attributes, inner}` for the first DIRECT child `<name>` of the item body `src`.
      # It walks child to child, stepping over each sibling's content (and any CDATA)
      # whole. A plain search for `<name` found the text in a sibling instead: a `<url>`
      # CDATA holding `?q=<response>x`, or an inline request body carrying
      # `<response>1</response>`, became the stored response head.
      private def self.element(src : String, name : String) : {String, String}?
        pos = 0
        while lt = src.byte_index('<', pos)
          tag, attrs, from, to, pos = child_at(src, lt) || return nil
          return {attrs, src.byte_slice(from, to - from)} if tag == name
        end
        nil
      end

      # The node opening at byte `lt`: `{tag, attributes, content start, content end, offset
      # past it}`. The tag is "" for a CDATA section, a stray closing tag, a comment or a
      # processing instruction, which are stepped over and never a child.
      private def self.child_at(src : String, lt : Int32) : {String, String, Int32, Int32, Int32}?
        if src.byte_slice?(lt, CDATA_OPEN.size) == "<![CDATA["
          cdata_end = src.byte_index("]]>", lt + CDATA_OPEN.size) || return nil
          return {"", "", 0, 0, cdata_end + 3}
        end
        gt = src.byte_index('>', lt + 1) || return nil
        return {"", "", 0, 0, gt + 1} if src.byte_at?(lt + 1).try(&.in?('/'.ord, '!'.ord, '?'.ord))
        after = lt + 1
        until after >= gt || name_ends_at?(src, after)
          after += 1
        end
        tag = src.byte_slice(lt + 1, after - lt - 1)
        attrs = src.byte_slice(after, gt - after)
        return {tag, attrs, 0, 0, gt + 1} if attrs.ends_with?('/') # <response/>
        close = close_at(src, tag, gt + 1) || return nil
        {tag, attrs, gt + 1, close, close + tag.bytesize + 3}
      end

      # The byte offset of the `</name>` closing an element whose content starts at `from`,
      # stepping over every `<![CDATA[…]]>` on the way: an inline (`base64="false"`) SOAP
      # request or RSS response carries `</request>` / `</item>` in its CDATA, and the first
      # literal match there cut the item short.
      private def self.close_at(src : String, name : String, from : Int32) : Int32?
        needle = "</#{name}>"
        pos = from
        while close = src.byte_index(needle, pos)
          # Bounded by the candidate close, so an export without CDATA never scans to EOF per item.
          cdata = AsciiBytes.index(src.to_slice[0, close], CDATA_OPEN, pos)
          return close unless cdata
          cdata_end = src.byte_index("]]>", cdata + CDATA_OPEN.size)
          return nil unless cdata_end
          pos = cdata_end + 3
        end
        nil
      end

      CDATA_OPEN = "<![CDATA[".to_slice

      # Whether the character at byte `at` ends a tag name: whitespace, `>` or `/`. Decoded as
      # a whole character, as the char-offset scanner did, so a non-ASCII space still counts.
      private def self.name_ends_at?(src : String, at : Int32) : Bool
        return false if at >= src.bytesize
        ch = Char::Reader.new(src, pos: at).current_char
        ch.whitespace? || ch == '>' || ch == '/'
      end

      # The TEXT elements — `<url>`, `<host>`, `<protocol>`, `<port>`, `<time>`. These become
      # a URL, a hostname and a timestamp, so a byte that is not valid UTF-8 has no meaning
      # in them and scrubbing is the right answer; this is the only place the file is
      # scrubbed at all, and `bytes_of` deliberately does not come through here.
      private def self.text_of(src : String, name : String) : String
        el = element(src, name)
        return "" unless el
        _, inner = el
        text = XmlText.cdata?(inner) ? XmlText.uncdata(inner) : XmlText.unescape(inner)
        text.valid_encoding? ? text : text.scrub
      end

      # The wire-byte path. `XmlText.unescape` is byte-wise for THIS caller's sake — see
      # the contract note in xml_text.cr.
      # `<request base64="true">` is the default; `base64="false"` means the message sits
      # inline as CDATA (Burp only does this for wholly-textual messages).
      private def self.bytes_of(src : String, name : String) : Bytes?
        el = element(src, name)
        return nil unless el
        attrs, inner = el
        return nil if inner.empty?
        if attrs.includes?(%(base64="true")) || attrs.includes?("base64='true'")
          # Burp wraps the base64 payload in CDATA too (`<request base64="true"><![CDATA[R0VU…
          # ]]></request>`). `Base64.decode` raises on the `<` of the wrapper, and the item
          # was then counted as skipped — so a real export imported next to nothing.
          Base64.decode((XmlText.cdata?(inner) ? XmlText.uncdata(inner) : inner).strip)
        else
          (XmlText.cdata?(inner) ? XmlText.uncdata(inner) : XmlText.unescape(inner)).to_slice
        end
      end
    end
  end
end
