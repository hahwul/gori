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
        # NOT scrubbed. A `base64="false"` item carries its message INLINE, so a scrub of the
        # file is a scrub of the wire bytes — and this importer's whole reason to exist is
        # that those bytes survive. It used to `raw = raw.scrub unless raw.valid_encoding?`
        # on the theory that scrubbing "keeps the scanner's ASCII needles working"; the
        # scanner never needed it. `String#index` and `String#[]` agree on char boundaries
        # even over invalid UTF-8, and `String#[](a, n)` COPIES the bytes of those chars
        # rather than re-encoding them, so every needle below still lands where it did.
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

      # The TEXT elements — `<url>`, `<host>`, `<protocol>`, `<port>`, `<time>`. These become
      # a URL, a hostname and a timestamp, so a byte that is not valid UTF-8 has no meaning
      # in them and scrubbing is the right answer; this is the only place the file is
      # scrubbed at all, and `bytes_of` deliberately does not come through here.
      private def self.text_of(src : String, name : String) : String
        el = element(src, name)
        return "" unless el
        _, inner = el
        text = cdata?(inner) ? uncdata(inner) : unescape(inner)
        text.valid_encoding? ? text : text.scrub
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

      AMP       = 0x26_u8 # '&'
      HASH      = 0x23_u8 # '#'
      LOWER_X   = 0x78_u8 # 'x'
      SEMICOLON = 0x3B_u8 # ';'

      # `&name;` / `&#123;` / `&#x1f;` decoding, done BYTE-wise.
      #
      # This was `text.gsub(ENTITY) { … }` over `/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/`, and a
      # Regexp gsub walks its subject as chars — `bytes_of` calls this for a non-base64
      # `<request>` that is not CDATA-wrapped, i.e. on wire bytes (see `parse_file`). The
      # grammar is entirely ASCII, so a byte scan reads exactly what that pattern did and
      # copies everything else through untouched.
      private def self.unescape(text : String) : String
        raw = text.to_slice
        return text unless raw.includes?(AMP)
        io = IO::Memory.new(raw.size)
        i = 0
        while i < raw.size
          if raw[i] == AMP && (hit = entity_at(raw, i))
            replacement, width = hit
            io << replacement
            i += width
          else
            io.write_byte(raw[i])
            i += 1
          end
        end
        String.new(io.to_slice)
      end

      # {replacement text, bytes consumed} for the entity starting at `raw[at] == '&'`, or
      # nil when what follows is not one — in which case the caller copies the `&` through,
      # which is what the old pattern's "no match" did. Deliberately as strict as that
      # pattern was, uppercase `&#X41;` included: it never matched `#x[0-9a-fA-F]+`, so it
      # stayed verbatim then and stays verbatim now.
      private def self.entity_at(raw : Bytes, at : Int32) : {String, Int32}?
        j = at + 1
        return nil if j >= raw.size
        numeric = raw[j] == HASH
        j += 1 if numeric
        hex = numeric && j < raw.size && raw[j] == LOWER_X
        j += 1 if hex
        stop = entity_body_end(raw, j, numeric, hex)
        return nil unless stop
        name = String.new(raw[j, stop - j])
        text = numeric ? numeric_entity(name, hex) : NAMED_ENTITIES[name]?
        text ? {text, stop + 1 - at} : nil
      end

      # Index of the `;` closing an entity body that starts at `from`, or nil when what sits
      # there is not one: an empty body, a byte outside the branch's class, or no `;` at all.
      private def self.entity_body_end(raw : Bytes, from : Int32, numeric : Bool, hex : Bool) : Int32?
        j = from
        while j < raw.size && entity_body_byte?(raw[j], numeric, hex)
          j += 1
        end
        return nil if j == from || j >= raw.size || raw[j] != SEMICOLON
        j
      end

      # An unknown named entity resolves to nil, i.e. stays verbatim rather than vanishing.
      NAMED_ENTITIES = {"amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'"}

      # `&#123;` / `&#x1f;`. nil for a codepoint that is not a `Char` (out of range, or a
      # lone surrogate) and for one too large to parse — both stay verbatim, as they did.
      private def self.numeric_entity(digits : String, hex : Bool) : String?
        (hex ? digits.to_i?(16) : digits.to_i?).try { |cp| safe_chr(cp) }
      end

      # `[0-9a-fA-F]` / `[0-9]` / `[a-zA-Z]`, per the branch the `&` opened.
      private def self.entity_body_byte?(b : UInt8, numeric : Bool, hex : Bool) : Bool
        digit = 0x30_u8 <= b <= 0x39_u8
        return digit || (0x61_u8 <= b <= 0x66_u8) || (0x41_u8 <= b <= 0x46_u8) if hex
        return digit if numeric
        (0x61_u8 <= b <= 0x7A_u8) || (0x41_u8 <= b <= 0x5A_u8)
      end

      private def self.safe_chr(codepoint : Int32) : String?
        return nil unless 0 <= codepoint <= Char::MAX_CODEPOINT
        return nil if 0xD800 <= codepoint <= 0xDFFF # lone surrogate — not a Char
        codepoint.unsafe_chr.to_s
      end
    end
  end
end
