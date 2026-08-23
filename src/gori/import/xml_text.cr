module Gori
  module Import
    # Text-level XML decoding shared by the two importers that read XML without libxml2:
    # `Import::Burp`'s flat item scanner and `Import::XmlMini`'s tree parser.
    #
    # MOVED OUT OF `burp.cr` UNCHANGED, bodies and comments both. `unescape` sits on the
    # path that produces byte-exact wire bytes for a `base64="false"` `<request>`, so its
    # byte-wise scan and its exact strictness — uppercase `&#X41;` never matched, an unknown
    # `&foo;` stays verbatim, a lone surrogate stays verbatim — are a CONTRACT, not an
    # implementation detail. Do not "tidy" them.
    #
    # `NAMED_ENTITIES` holding only the five XML predefined entities is deliberate and is
    # the whole anti-XXE story for `XmlMini`: gori resolves no other entity, so entity
    # expansion is O(1) in the input by construction rather than by a counter someone has
    # to remember to check.
    module XmlText
      def self.cdata?(inner : String) : Bool
        inner.lstrip.starts_with?("<![CDATA[")
      end

      # CDATA content is literal by definition — never entity-decoded.
      def self.uncdata(inner : String) : String
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
      # Regexp gsub walks its subject as chars — `Burp.bytes_of` calls this for a non-base64
      # `<request>` that is not CDATA-wrapped, i.e. on wire bytes. The grammar is entirely
      # ASCII, so a byte scan reads exactly what that pattern did and copies everything else
      # through untouched.
      def self.unescape(text : String) : String
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
