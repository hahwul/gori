require "json"
require "./raw_json"
require "./json_unicode"
require "uri"
require "base64"
require "mime/multipart"
require "./graphql"
require "./media_type"
require "./binary_document"
require "./msgpack"
require "./cbor"
require "./decoder/serialized"
require "./jwt/jwe"

module Gori
  # Display-only body pretty-printer. Sits BETWEEN the transform layer
  # (`Proxy::Codec::ContentDecode`, which decompresses/de-chunks) and the overlay
  # layer (`Tui::Highlight`, a pure 1:1 colour overlay that never re-flows). Pretty
  # therefore emits already-reflowed bytes for the highlighter to colour per line.
  #
  # P7 (raw wire bytes are the truth): the input slice is NEVER mutated; `format`
  # returns a fresh slice or `nil`. Every failure path — malformed, binary, oversize,
  # unsupported type, tag imbalance — collapses to `nil` ("leave the body raw"), so a
  # caller has exactly one fallback branch and Pretty structurally cannot corrupt a
  # render. Only the human request/response views wire it in; machine consumers
  # (fuzz matcher, MCP serialize, CLI, repeater diff) keep reading faithful bytes.
  module Pretty
    extend self

    MAX_PRETTY     = 1024 * 1024     # skip bodies larger than this (parse cost) → raw windowed
    MAX_OUT_PRETTY = 8 * 1024 * 1024 # cap reflowed output; larger → nil
    MAX_DEPTH      = 256             # indent-depth clamp (markup)
    MAX_PARTS      = 256             # multipart parts shown
    PART_BODY_MAX  = 64 * 1024       # inline a multipart part body only if small + UTF-8

    # A single-token JWS (header.payload[.signature]); the header is additionally
    # required to base64url-decode to a JSON object (see `try_jwt`) to avoid treating
    # an ordinary dotted word like "a.b.c" as a token. The five-part JWE shape is a
    # separate predicate (`Jwt::Jwe::JWE_RE`), tried first in `try_jwt`.
    JWT_RE = /\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*)?\z/

    RAW_ELEMENTS  = {"script", "style", "pre", "textarea"}
    VOID_ELEMENTS = {"area", "base", "br", "col", "embed", "hr", "img",
                     "input", "link", "meta", "param", "source", "track", "wbr"}

    # Reflowed display bytes + a short note for the trailer. `kind` overrides the
    # highlighter's content-type-derived styling when the pretty output is no longer
    # the content-type's language (GraphQL/JWT/multipart → :text).
    alias DecodedRange = JsonUnicode::DecodedRange

    record Result, bytes : Bytes, note : String, kind : Symbol? = nil,
      decoded_ranges : Array(DecodedRange) = [] of DecodedRange,
      protected_linefeeds : Array(Int32) = [] of Int32,
      unicode_escape_count : Int32 = 0,
      reflowed : Bool = true

    # nil = leave the body raw (the only failure signal).
    def format(head : Bytes?, body : Bytes?, *, decode_unicode : Bool = false) : Result?
      return nil if body.nil? || body.empty?
      return nil if body.size > MAX_PRETTY

      str = String.new(body)
      ct = MediaType.of(head) # original case (boundary is case-sensitive), params kept
      ctl = ct.try(&.downcase)

      # A binary DOCUMENT first, and before the text sniffs: its bytes are not text, so every
      # sniff below would be reading a String built out of arbitrary octets to no purpose. The
      # content-type has to say so — this is a dispatch, not a guess (`MediaType.binary_document?`).
      return try_binary_doc(body, ct) if MediaType.binary_document?(ct)

      # Content sniffs FIRST — a native-serialization blob and a JWT both masquerade under
      # generic content-types (and the four serialization formats have no content-type at all).
      if r = sniffed(body, str)
        return r
      end
      return try_json(str, decode_unicode) if MediaType.json?(ct)
      # A urlencoded body can be a GraphQL request (`query=…&variables=…`, the form
      # express-graphql and Yoga accept beside JSON). Rendering it as an anonymous field list
      # loses the document; ask the GraphQL parser first and fall back to the field list.
      return try_graphql_body(body, ct) || try_form(str) if MediaType.form_urlencoded?(ct)
      return try_multipart(body, ct) if ct && MediaType.multipart?(ct)
      markup_or_graphql(body, str, ct, ctl)
    rescue
      nil # last-resort net: Pretty must never raise into the render path
    end

    # Decode escaped Unicode in a JSON body without changing its original whitespace. This is
    # the `u` layer when the operator has turned pretty reflow off; the decoded text remains a
    # display projection and is never used by the request write-back path.
    def decode_unicode_json(head : Bytes?, body : Bytes?) : Result?
      return nil if body.nil? || body.empty? || body.size > MAX_PRETTY
      return nil unless MediaType.json?(MediaType.of(head))
      raw = String.new(body)
      return nil unless RawJson.valid?(raw)
      unicode = JsonUnicode.decode(raw)
      return nil if unicode.count == 0
      Result.new(unicode.text.to_slice, "json · \\u decoded (#{unicode.count} escapes)",
        decoded_ranges: unicode.ranges, protected_linefeeds: unicode.protected_linefeeds,
        unicode_escape_count: unicode.count, reflowed: false)
    rescue
      nil
    end

    # Escape count for a plain JSON pane when pretty reflow is disabled. Keeps the `u` chip
    # discoverable without changing the pane's bytes or allocating a decoded projection.
    def unicode_escape_count(head : Bytes?, body : Bytes?) : Int32
      return 0 if body.nil? || body.empty? || body.size > MAX_PRETTY
      return 0 unless MediaType.json?(MediaType.of(head))
      raw = String.new(body)
      RawJson.valid?(raw) ? JsonUnicode.escape_count(raw) : 0
    rescue
      0
    end

    # The HEAD of `format`'s chain: the two sniffs that run before any content-type is
    # consulted, in the order they have to run in. A serialized object graph is dispatched on
    # its own marker (`try_serialized`) because none of those four formats has a content type;
    # a JWT is a body shape that appears under every generic type there is.
    private def sniffed(body : Bytes, str : String) : Result?
      try_serialized(body) || try_jwt(str)
    end

    # The TAIL of `format`'s chain, split out so the whole dispatch is not one method past
    # every complexity metric. The ORDER is the contract and is unchanged — a markup type
    # first, then the GraphQL byte sniff that runs when no content-type described the body.
    private def markup_or_graphql(body : Bytes, str : String, ct : String?, ctl : String?) : Result?
      return try_xml(str) if ctl && ctl.includes?("xml")
      return try_html(str) if ctl && ctl.includes?("html")
      # Last: a GraphQL body under a content-type that does not describe it — `text/plain`,
      # none at all (both of which servers accept and both of which are the standard
      # JSON-content-type filter bypass), or the raw `application/graphql` document. Gated on
      # a cheap byte sniff so an ordinary unknown-type body still costs one regex, not a
      # 1 MiB JSON parse.
      return try_graphql_body(body, ct) if graphql_sniffable?(body, ct)
      nil
    end

    # ---- binary documents (MessagePack / CBOR) -----------------------------

    # A body somebody serialized rather than wrote. Rendered as the JSON projection its reader
    # produces — types JSON cannot hold come back NAMED, so nothing is folded away — and styled
    # as JSON, because that is what the pane is now showing (`kind`, the same override GraphQL
    # and JWT use).
    #
    # `BinaryDocument.render` is nil for a body whose bytes are not the document its header
    # claims, and that nil is the whole point: the caller then falls through to the ordinary
    # binary placeholder and the hex view. A reader with no schema makes SOMETHING of any
    # bytes, so without that test a PNG labelled `application/msgpack` rendered as a
    # plausible-looking map with the hex pointer suppressed.
    #
    # The reader's text is used VERBATIM, indented as it is built. Re-parsing it to pretty-print
    # (`JSON.parse(json).to_pretty_json`) merged duplicate members — so a document carrying the
    # same key twice, which is a fact about the body and often the point of it, lost one of them
    # on the one surface an operator looks at, while the headless projection kept both.
    private def try_binary_doc(body : Bytes, ct : String?) : Result?
      format, r = BinaryDocument.render(body, ct, indent: "  ") || return nil
      return nil if r.json.bytesize > MAX_OUT_PRETTY
      note = String.build do |io|
        io << "decoded: " << format
        io << " (partial — the document ends mid-value)" unless r.complete
      end
      Result.new(r.json.to_slice, note, kind: :json)
    rescue
      nil # last-resort net, the same one `format` carries: never raise into the render path
    end

    # ---- native serialization (Java / ViewState / PHP / pickle) ------------

    # A body somebody's RUNTIME wrote — a Java `ObjectOutputStream` stream, an ASP.NET
    # ViewState, a PHP `serialize()` value, a Python pickle. Same projection and same `kind`
    # override as `try_binary_doc`, and nil for a body whose bytes are not what their marker
    # claims, so the caller falls through to the hex view.
    #
    # A MARKER and not a content-type, which is the one thing that differs from the sibling
    # above: none of these four formats has a content-type of its own. A Java stream comes
    # back as `application/octet-stream`, a serialized PHP value as `text/plain`. Each marker
    # is structural rather than a keyword (`Decoder::Serialized.sniff`), which is what keeps
    # this from firing on an ordinary body.
    #
    # A ViewState is the one that will rarely reach here, and that is expected rather than a
    # gap: it lives in an `<input value=…>` inside an HTML body, not as the body. The converter
    # (`dotnet-viewstate`) is where an operator reads one, and the Decoder tab is where they
    # paste it.
    private def try_serialized(body : Bytes) : Result?
      format, r = Decoder::Serialized.sniff(body, indent: "  ") || return nil
      return nil if r.json.bytesize > MAX_OUT_PRETTY
      note = String.build do |io|
        io << "decoded: " << format
        io << " (partial — the document ends mid-value)" unless r.complete
      end
      Result.new(r.json.to_slice, note, kind: :json)
    rescue
      nil # last-resort net, the same one `format` carries: never raise into the render path
    end

    # ---- content-type ------------------------------------------------------

    # Worth handing to the GraphQL parser despite a content-type that claims nothing: the raw
    # document type, or a body that OPENS as the envelope (`Graphql.envelope_head?`, the same
    # anchored first-256-bytes test the decoded pane uses to report a mangled envelope).
    private def graphql_sniffable?(body : Bytes, ct : String?) : Bool
      MediaType.essence(ct) == "application/graphql" || Graphql.envelope_head?(body)
    end

    # ---- JSON --------------------------------------------------------------

    # A JSON content-type stays on its wire grammar in the default pane. Pretty changes only
    # inter-token whitespace so escapes and duplicate keys remain visible to the operator.
    private def try_json(str : String, decode_unicode : Bool = false) : Result?
      s = strip_bom(str).strip
      pretty = RawJson.reindent(s, "  ", MAX_OUT_PRETTY) || return nil
      pretty_json(pretty, s, decode_unicode)
    rescue
      nil # invalid JSON remains an ordinary raw-body view
    end

    private def pretty_json(pretty : String, s : String, decode_unicode : Bool = false) : Result?
      displayed = pretty
      ranges = [] of DecodedRange
      protected_linefeeds = [] of Int32
      count = JsonUnicode.escape_count(pretty)
      if decode_unicode && count > 0
        unicode = JsonUnicode.decode(pretty)
        displayed = unicode.text
        ranges = unicode.ranges
        protected_linefeeds = unicode.protected_linefeeds
        count = unicode.count
      end
      return nil if displayed == s && count == 0 # already pretty / scalar → no-op
      slice = displayed.to_slice
      return nil if slice.size > MAX_OUT_PRETTY
      note = "pretty: json"
      if decode_unicode && count > 0
        note += " · \\u decoded (#{count} escapes)"
      end
      Result.new(slice, note, decoded_ranges: ranges, protected_linefeeds: protected_linefeeds,
        unicode_escape_count: count, reflowed: pretty != s)
    end

    # ---- GraphQL (operationName + un-escaped query + pretty variables) ------

    # The same, for a body Pretty has NOT already parsed — a urlencoded `query=…`, a raw
    # `application/graphql` document, or an envelope under a content-type that hides it.
    private def try_graphql_body(body : Bytes, ct : String?) : Result?
      result_for(Graphql.from_body(body, ct), String.new(body))
    end

    private def result_for(op : Graphql::Op?, original : String? = nil) : Result?
      return nil unless op
      text = Graphql.display(op)
      return nil if text.empty? || text == original # nothing was reflowed → show raw
      ob = text.to_slice
      return nil if ob.size > MAX_OUT_PRETTY
      Result.new(ob, "pretty: graphql (#{op.form.to_s.downcase})", :graphql)
    end

    # ---- JWT (reuses Decoder::Codecs.jwt_decode) ---------------------------

    private def try_jwt(str : String) : Result?
      t = str.strip
      # A JWE first: it is five segments, so JWT_RE would reject it and the body would render
      # as an opaque dotted string with nothing to read. The rendered form is header-only —
      # the claims stay encrypted, and the label says so rather than implying a decode.
      if jwe = Jwt::Jwe.parse(t)
        slice = Jwt::Jwe.render(jwe).to_slice
        return nil if slice.size > MAX_OUT_PRETTY
        return Result.new(slice, "pretty: jwe (encrypted · protected header only)", :json)
      end
      return nil unless t =~ JWT_RE
      # Strong signal: a JWT header always base64url-decodes to a JSON object.
      header = Base64.decode(t.split('.').first)
      return nil unless RawJson.members(String.new(header)) # an object, numbers of any size
      decoded = Decoder::Codecs.jwt_decode(t.to_slice)
      slice = decoded.to_slice
      return nil if slice.size > MAX_OUT_PRETTY
      # The decoded form is JSONC (`// header` / `// payload` markers + JSON segments);
      # the JSON tokenizer styles the `//` markers as comments (see Highlight.json_line).
      Result.new(slice, "pretty: jwt (decoded · signature not verified)", :json)
    rescue
      nil
    end

    # ---- form-urlencoded ---------------------------------------------------

    private def try_form(str : String) : Result?
      return nil if str.empty?
      pairs = str.split('&').reject(&.empty?) # tolerate trailing/duplicate '&' (no spurious blank rows)
      return nil if pairs.empty?
      text = String.build do |io|
        pairs.each_with_index do |p, idx|
          io << '\n' if idx > 0
          k, sep, v = p.partition('=')
          key = (URI.decode_www_form(k) rescue k)
          if sep.empty?
            io << key << " ="
          else
            io << key << " = " << (URI.decode_www_form(v) rescue v)
          end
        end
      end
      return nil if text == str # single bare token, nothing to reflow
      ob = text.to_slice
      return nil if ob.size > MAX_OUT_PRETTY
      Result.new(ob, "pretty: form (#{pairs.size} field#{pairs.size == 1 ? "" : "s"})", :form)
    rescue
      nil
    end

    # ---- multipart/form-data ----------------------------------------------

    private def try_multipart(body : Bytes, ct : String) : Result?
      boundary = MIME::Multipart.parse_boundary(ct)
      return nil unless boundary && !boundary.empty?
      parts = [] of String
      count = 0
      MIME::Multipart.parse(IO::Memory.new(body), boundary) do |headers, io|
        count += 1
        next if count > MAX_PARTS
        pbody = io.gets_to_end
        parts << String.build do |s|
          s << "── part " << count << " ──\n"
          headers.each { |k, vs| vs.each { |v| s << k << ": " << v << "\n" } }
          s << "\n"
          if pbody.valid_encoding? && pbody.bytesize <= PART_BODY_MAX
            s << pbody
          else
            s << "(binary, " << pbody.bytesize << " bytes)"
          end
        end
      end
      return nil if parts.empty?
      parts << "… #{count - MAX_PARTS} more part(s)" if count > MAX_PARTS
      text = parts.join("\n\n")
      ob = text.to_slice
      return nil if ob.size > MAX_OUT_PRETTY
      Result.new(ob, "pretty: multipart (#{count} part#{count == 1 ? "" : "s"})", :text)
    rescue
      nil
    end

    # ---- XML / SOAP / SAML (strict reflow; balance-checked) ----------------

    private def try_xml(str : String) : Result?
      return nil unless str.valid_encoding?
      res = indent_xml(str)
      return nil unless res && res != str
      ob = res.to_slice
      return nil if ob.size > MAX_OUT_PRETTY
      Result.new(ob, "pretty: xml")
    rescue
      nil
    end

    # Full reflow: one node per line, indented by element depth. Whitespace-only
    # text between tags is dropped; element text is trimmed. ANY imbalance (a stray
    # close, leftover open depth, or an unterminated `<`) aborts to nil so the caller
    # falls back to the raw bytes rather than showing a mangled tree.
    private def indent_xml(str : String) : String?
      src = str.to_slice
      n = src.size
      depth = 0
      lines = [] of String
      i = 0
      while i < n
        if src[i] == 0x3C # '<'
          tend = tag_end(src, i)
          return nil if tend < 0
          tok = String.new(src[i, tend - i])
          case classify(tok)
          when :close
            depth -= 1
            return nil if depth < 0
            lines << indent(depth) + tok
          when :open
            lines << indent(depth) + tok
            depth += 1
          else # selfclose / comment / cdata / decl / doctype
            lines << indent(depth) + tok
          end
          i = tend
        else
          start = i
          while i < n && src[i] != 0x3C
            i += 1
          end
          text = String.new(src[start, i - start]).strip
          lines << indent(depth) + text unless text.empty?
        end
      end
      return nil if depth != 0 || lines.empty?
      lines.join('\n')
    end

    # ---- HTML (additive, insert-only — never drops/alters a byte) ----------

    private def try_html(str : String) : Result?
      return nil unless str.valid_encoding?
      res = indent_html(str)
      return nil unless res && res != str
      ob = res.to_slice
      return nil if ob.size > MAX_OUT_PRETTY
      Result.new(ob, "pretty: html")
    rescue
      nil
    end

    # Insert-only indenter: copies every byte verbatim and only inserts a newline +
    # indent at a `><` tag seam (a tag immediately following another tag). Text
    # between tags stays inline, so no data is ever lost — tolerant of HTML's
    # optional-close tags (depth is clamped, never asserted). `<pre>/<script>/<style>/
    # <textarea>` bodies pass through verbatim (a JS `a<b` is not mistaken for a tag).
    private def indent_html(str : String) : String?
      src = str.to_slice
      n = src.size
      buf = String::Builder.new
      depth = 0
      prev_was_tag = false
      i = 0
      while i < n
        if src[i] == 0x3C # '<'
          tend = tag_end(src, i)
          return nil if tend < 0
          tok = String.new(src[i, tend - i])
          kind = classify(tok)
          name = tag_name(tok)
          if kind == :open && RAW_ELEMENTS.includes?(name)
            close = find_close_tag(src, tend, name)
            block_end = close < 0 ? n : close
            emit_tag(buf, depth, String.new(src[i, block_end - i]), prev_was_tag)
            prev_was_tag = true
            i = block_end
            next
          end
          case kind
          when :close
            depth -= 1 if depth > 0
            emit_tag(buf, depth, tok, prev_was_tag)
          when :open
            emit_tag(buf, depth, tok, prev_was_tag)
            depth += 1 unless VOID_ELEMENTS.includes?(name)
          else # selfclose / comment / cdata / decl / doctype
            emit_tag(buf, depth, tok, prev_was_tag)
          end
          prev_was_tag = true
          i = tend
        else
          start = i
          while i < n && src[i] != 0x3C
            i += 1
          end
          buf << String.new(src[start, i - start])
          prev_was_tag = false
        end
      end
      buf.to_s
    end

    private def emit_tag(buf : String::Builder, depth : Int32, tok : String, prev_was_tag : Bool) : Nil
      buf << '\n' << indent(depth) if prev_was_tag
      buf << tok
    end

    # ---- shared markup helpers --------------------------------------------

    private def indent(depth : Int32) : String
      "  " * (depth < MAX_DEPTH ? depth : MAX_DEPTH)
    end

    # Classify a `<...>` token by its opening bytes.
    private def classify(tok : String) : Symbol
      return :standalone if tok.starts_with?("<!--") || tok.starts_with?("<![CDATA[") ||
                            tok.starts_with?("<?") || tok.starts_with?("<!")
      return :close if tok.starts_with?("</")
      inner = tok.lchop('<').rchop('>')
      return :standalone if inner.rstrip.ends_with?('/') # self-closing
      :open
    end

    # Lower-cased element name of an open/close tag ("" for comments/decls).
    private def tag_name(tok : String) : String
      s = tok.lchop('<').lstrip
      s = s.lchop('/')
      stop = s.size
      s.each_char_with_index do |c, idx|
        if c.whitespace? || c == '>' || c == '/'
          stop = idx
          break
        end
      end
      s[0, stop].downcase
    end

    # Index just past a tag's terminator, or -1 if unterminated. Quote-aware for
    # generic tags (`<a title="x>y">`), special-casing comments and CDATA.
    private def tag_end(src : Bytes, i : Int32) : Int32
      n = src.size
      if starts_seq(src, i, "<!--")
        j = find_seq(src, i + 4, "-->")
        return j < 0 ? -1 : j + 3
      end
      if starts_seq(src, i, "<![CDATA[")
        j = find_seq(src, i + 9, "]]>")
        return j < 0 ? -1 : j + 3
      end
      j = i + 1
      quote = 0_u8
      while j < n
        c = src[j]
        if quote != 0_u8
          quote = 0_u8 if c == quote
        elsif c == 0x22_u8 || c == 0x27_u8 # " or '
          quote = c
        elsif c == 0x3E_u8 # >
          return j + 1
        end
        j += 1
      end
      -1
    end

    # Index just past the matching `</name>` (case-insensitive), or -1. Skips
    # false-prefix matches (e.g. `</scriptlet>` is NOT a close of `<script>`): the
    # byte after the name must end the tag name (`>` or whitespace), else keep scanning.
    private def find_close_tag(src : Bytes, from : Int32, name : String) : Int32
      needle = "</#{name}"
      pos = from
      loop do
        j = find_seq_ci(src, pos, needle)
        return -1 if j < 0
        after = j + needle.size
        if after < src.size && tag_name_boundary?(src[after])
          k = after
          while k < src.size && src[k] != 0x3E_u8
            k += 1
          end
          return -1 if k >= src.size
          return k + 1
        end
        pos = after # false prefix (</scriptlet…) — advance past it and keep looking
      end
    end

    private def tag_name_boundary?(b : UInt8) : Bool
      b == 0x3E_u8 || b == 0x20_u8 || b == 0x09_u8 || b == 0x0A_u8 || b == 0x0D_u8 # > or whitespace
    end

    private def starts_seq(src : Bytes, at : Int32, seq : String) : Bool
      sb = seq.to_slice
      return false if at + sb.size > src.size
      sb.each_with_index { |b, k| return false if src[at + k] != b }
      true
    end

    private def find_seq(src : Bytes, from : Int32, seq : String) : Int32
      sb = seq.to_slice
      last = src.size - sb.size
      i = from
      while i <= last
        return i if starts_seq(src, i, seq)
        i += 1
      end
      -1
    end

    private def find_seq_ci(src : Bytes, from : Int32, seq : String) : Int32
      sb = seq.downcase.to_slice
      last = src.size - sb.size
      i = from
      while i <= last
        match = true
        sb.each_with_index do |b, k|
          if downcase_byte(src[i + k]) != b
            match = false
            break
          end
        end
        return i if match
        i += 1
      end
      -1
    end

    # Pretty-prints a raw HTTP request body in-place, preserving any §...§ markers.
    # Returns the formatted body string on success, or nil on failure.
    def format_request(head : String, body : String) : String?
      # NOT for a binary document. This method's result REPLACES the operator's editor buffer
      # (`RepeaterView#format_body` → `@editor.set_text`), and the msgpack/CBOR rendering is a
      # PROJECTION: `{"$bin": …}` is a description of bytes, not bytes, and nothing re-encodes
      # it. Formatting one here would overwrite a request the operator is about to send with
      # something that cannot become it again — the operator's own bytes, destroyed by a
      # display feature (P7). The reader is still one `p` away in the response pane and in the
      # Decoder tab, where nothing is replaced.
      return nil if MediaType.binary_document?(MediaType.of(head.to_slice))

      return format_json_request(body) if MediaType.json?(MediaType.of(head.to_slice))
      format_other_request(head, body)
    end

    private def format_other_request(head : String, body : String) : String?
      markers = [] of String

      # 1. Extract and replace all markers with unique safe numeric strings.
      temp_body = String.build do |io|
        chars = body.chars
        n = chars.size
        i = 0
        while i < n
          if chars[i] == '§'
            if chars[i + 1]? == '§' # escaped §
              io << "§§"
              i += 2
            else
              start = i
              i += 1
              while i < n
                if chars[i] == '§'
                  if chars[i + 1]? == '§'
                    i += 2
                  else
                    break
                  end
                else
                  i += 1
                end
              end
              if i < n && chars[i] == '§'
                markers << chars[start..i].join
                io << "876543210987600#{markers.size - 1}"
                i += 1
              else
                io << chars[start...i].join
              end
            end
          else
            io << chars[i]
            i += 1
          end
        end
      end

      # 2. Format using the standard formatter
      res = format(head.to_slice, temp_body.to_slice)
      return nil unless res
      # The module header's display-only contract: this is the ONE write-back consumer of
      # `format`, so it may only take a rendering that is still the body's own grammar. A
      # non-nil `kind` marks a display listing (graphql/jwt/form/multipart) whose bytes do
      # not re-parse as the request body — writing one back replaces a sendable body with
      # something un-sendable, irreversibly (`TextArea#set_text` clears undo).
      return nil unless res.kind.nil?

      formatted = String.new(res.bytes)

      # 3. Restore the markers — HIGHEST index first. Placeholders share the
      # "876543210987600" prefix, so e.g. idx 1's "…6001" is a substring-prefix of idx
      # 10's "…60010". A proper digit-prefix always has fewer digits (⇒ smaller value),
      # so its collision partner always carries a larger index; replacing high→low
      # consumes the longer placeholder before its prefix and avoids corrupting markers.
      (markers.size - 1).downto(0) do |idx|
        formatted = formatted.gsub("876543210987600#{idx}", markers[idx])
      end

      formatted
    end

    # Reindent JSON without parsing and rebuilding its values. Template markers are replaced
    # byte-wise before the temporary document is validated, then restored after whitespace-only
    # formatting so the editor's write-back keeps the operator's payload (P7).
    private def format_json_request(body : String) : String?
      return nil if body.bytesize > MAX_PRETTY
      marker_prefix = json_marker_prefix(body.to_slice)
      temp_body, markers = extract_json_markers(body, marker_prefix)
      formatted = RawJson.reindent(temp_body, "  ", MAX_OUT_PRETTY) || return nil
      formatted = restore_json_markers(formatted, marker_prefix, markers)
      formatted == body ? nil : formatted
    end

    # Replace §...§ template markers using their UTF-8 bytes. String#chars would scrub malformed
    # bytes from an otherwise valid operator JSON string before write-back, violating P7.
    private def extract_json_markers(body : String, marker_prefix : String) : {String, Array(String)}
      source = body.to_slice
      output = IO::Memory.new
      markers = [] of String
      i = 0

      while i < source.size
        unless json_marker_at?(source, i)
          output.write_byte(source[i])
          i += 1
          next
        end

        if json_marker_at?(source, i + 2)
          output.write(source[i, 4]) # doubled § is an escaped literal marker
          i += 4
          next
        end

        start = i
        i += 2
        while i < source.size
          unless json_marker_at?(source, i)
            i += 1
            next
          end
          if json_marker_at?(source, i + 2)
            i += 4
          else
            break
          end
        end

        if json_marker_at?(source, i)
          markers << String.new(source[start, i + 2 - start])
          output << json_marker_placeholder(marker_prefix, markers.size - 1)
          i += 2
        else
          output.write(source[start, source.size - start])
          i = source.size
        end
      end

      {String.new(output.to_slice), markers}
    end

    private def restore_json_markers(formatted : String, marker_prefix : String,
                                     markers : Array(String)) : String
      return formatted if markers.empty?

      source = formatted.to_slice
      prefix = marker_prefix.to_slice
      prefix_byte = prefix[0]
      output = IO::Memory.new
      copied_until = 0
      pos = 0
      while at = source.index(prefix_byte, pos)
        if json_bytes_at?(source, at, prefix)
          index_start = at + prefix.size
          marker_index = 0
          8.times do |offset|
            digit = source[index_start + offset] - 0x30_u8
            marker_index = marker_index * 10 + digit
          end
          output.write(source[copied_until, at - copied_until]) if at > copied_until
          output.write(markers[marker_index].to_slice)
          copied_until = index_start + 8
          pos = copied_until
        else
          pos = at + 1
        end
      end
      output.write(source[copied_until, source.size - copied_until]) if copied_until < source.size
      String.new(output.to_slice)
    end

    # Share an absent numeric prefix across every marker so lookup/restoration stays linear in
    # the document size rather than rescanning the whole body for each marker. A source body
    # can contain arbitrary number lexemes, so choose and verify the prefix against its bytes.
    private def json_marker_prefix(source : Bytes) : String
      seed = "87654321098765432109876543210987654321"
      attempt = 0
      loop do
        suffix = attempt.to_s.rjust(8, '0')
        candidate = seed[0, seed.size - suffix.size] + suffix
        return candidate unless json_bytes_include?(source, candidate.to_slice)
        attempt += 1
      end
    end

    private def json_marker_placeholder(prefix : String, index : Int32) : String
      "#{prefix}#{index.to_s.rjust(8, '0')}"
    end

    private def json_bytes_include?(source : Bytes, needle : Bytes) : Bool
      pos = 0
      while at = source.index(needle[0], pos)
        return true if json_bytes_at?(source, at, needle)
        pos = at + 1
      end
      false
    end

    private def json_marker_at?(source : Bytes, at : Int32) : Bool
      at + 1 < source.size && source[at] == 0xc2_u8 && source[at + 1] == 0xa7_u8
    end

    private def json_bytes_at?(source : Bytes, at : Int32, needle : Bytes) : Bool
      return false if at + needle.size > source.size
      needle.each_with_index { |byte, offset| return false if source[at + offset] != byte }
      true
    end

    private def downcase_byte(b : UInt8) : UInt8
      (0x41_u8 <= b <= 0x5A_u8) ? b + 0x20_u8 : b
    end

    private def strip_bom(s : String) : String
      s.lchop('﻿')
    end
  end
end
