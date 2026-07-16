require "json"
require "uri"
require "base64"
require "mime/multipart"

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

    # A single-token JWT (header.payload[.signature]); the header is additionally
    # required to base64url-decode to a JSON object (see `try_jwt`) to avoid treating
    # an ordinary dotted word like "a.b.c" as a token.
    JWT_RE = /\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*)?\z/

    RAW_ELEMENTS  = {"script", "style", "pre", "textarea"}
    VOID_ELEMENTS = {"area", "base", "br", "col", "embed", "hr", "img",
                     "input", "link", "meta", "param", "source", "track", "wbr"}

    # Reflowed display bytes + a short note for the trailer. `kind` overrides the
    # highlighter's content-type-derived styling when the pretty output is no longer
    # the content-type's language (GraphQL/JWT/multipart → :text).
    record Result, bytes : Bytes, note : String, kind : Symbol? = nil

    # nil = leave the body raw (the only failure signal).
    def format(head : Bytes?, body : Bytes?) : Result?
      return nil if body.nil? || body.empty?
      return nil if body.size > MAX_PRETTY

      str = String.new(body)
      ct = media_type(head) # original case (boundary is case-sensitive), params kept
      ctl = ct.try(&.downcase)

      # Content sniffs FIRST — JWT/GraphQL masquerade under generic content-types.
      if r = try_jwt(str)
        return r
      end
      if ctl && ctl.includes?("json")
        return try_json_or_graphql(str)
      end
      return try_form(str) if ctl && ctl.includes?("x-www-form-urlencoded")
      return try_multipart(body, ct) if ctl && ct && ctl.starts_with?("multipart/")
      return try_xml(str) if ctl && ctl.includes?("xml")
      return try_html(str) if ctl && ctl.includes?("html")
      nil
    rescue
      nil # last-resort net: Pretty must never raise into the render path
    end

    # ---- content-type ------------------------------------------------------

    private def media_type(head : Bytes?) : String?
      return nil unless head
      String.new(head).each_line do |line|
        l = line.chomp    # drops a trailing \r\n / \n / \r
        break if l.empty? # end of the header block
        if l.size >= 13 && l[0, 13].downcase == "content-type:"
          return l[13..].strip
        end
      end
      nil
    end

    # ---- JSON --------------------------------------------------------------

    # A JSON body is EITHER a GraphQL envelope (operationName + query + variables) or plain
    # JSON to pretty-print. Both used to JSON.parse the SAME body independently (try_graphql
    # then try_json), so a non-GraphQL REST-JSON response — the dominant shape — built the
    # whole JSON tree TWICE per detail-view cache rebuild. Parse ONCE, sniff GraphQL off the
    # tree, else pretty-print the tree. Byte-identical to the old two-call dispatch on every
    # input: invalid/empty JSON → nil via the parse rescue (as both did); a GraphQL shape →
    # the graphql result; anything else → the pretty result (or nil for already-pretty/scalar).
    private def try_json_or_graphql(str : String) : Result?
      s = strip_bom(str).strip
      json = JSON.parse(s)
      # GraphQL sniff in its OWN rescue so a shape-check failure falls through to pretty-print
      # exactly as the old try_graphql(rescue→nil)-then-try_json path did.
      if r = (graphql_from(json) rescue nil)
        return r
      end
      pretty = json.to_pretty_json
      return nil if pretty == s # already pretty / scalar → no-op, show raw
      slice = pretty.to_slice
      return nil if slice.size > MAX_OUT_PRETTY
      Result.new(slice, "pretty: json")
    rescue
      nil # invalid JSON (both try_graphql and try_json returned nil here before)
    end

    # ---- GraphQL (operationName + un-escaped query + pretty variables) ------

    # GraphQL envelope over an ALREADY-PARSED body (no second parse). Same guards as the old
    # try_graphql minus the JSON.parse; nil for any non-GraphQL object/array/scalar so the
    # caller falls through to plain JSON pretty-printing.
    private def graphql_from(json : JSON::Any) : Result?
      h = json.as_h?
      return nil unless h
      q = h["query"]?.try(&.as_s?)
      return nil unless q
      # A GraphQL document always has a selection set, so the query string contains
      # a '{'. Requiring it avoids hijacking ordinary REST bodies that happen to have
      # a string "query" field (e.g. {"query":"shoes","page":2}) — which would hide
      # their other fields — and rejects an empty/whitespace query (blank output).
      return nil unless q.includes?('{')
      text = String.build do |io|
        if op = h["operationName"]?.try(&.as_s?)
          io << "# operationName: " << op << "\n\n"
        end
        io << q.strip
        if (vars = h["variables"]?) && !vars.raw.nil?
          io << "\n\n# variables\n" << vars.to_pretty_json
        end
      end
      ob = text.to_slice
      return nil if ob.size > MAX_OUT_PRETTY
      Result.new(ob, "pretty: graphql", :graphql)
    end

    # ---- JWT (reuses Decoder::Codecs.jwt_decode) ---------------------------

    private def try_jwt(str : String) : Result?
      t = str.strip
      return nil unless t =~ JWT_RE
      # Strong signal: a JWT header always base64url-decodes to a JSON object.
      header = Base64.decode(t.split('.').first)
      return nil unless JSON.parse(String.new(header)).as_h?
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

    private def downcase_byte(b : UInt8) : UInt8
      (0x41_u8 <= b <= 0x5A_u8) ? b + 0x20_u8 : b
    end

    private def strip_bom(s : String) : String
      s.lchop('﻿')
    end
  end
end
