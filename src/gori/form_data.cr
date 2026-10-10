require "uri"
require "mime/multipart"
require "./media_type"
require "./entity"
require "./ascii_bytes"

module Gori
  # Decodes a request's form parameters — an `application/x-www-form-urlencoded` or
  # `multipart/form-data` body, plus any URL query string — into a flat, url-decoded
  # key=value list. A DISPLAY-time projection (no table). Pretty reflows a form body
  # under the `p` toggle; this drives an always-on PARAMS pane that also folds in the
  # query string and summarises multipart file parts.
  module FormData
    extend self

    MAX_BODY   = 8 * 1024 * 1024
    MAX_FIELDS = 500
    MAX_PARTS  = 256
    PART_MAX   = 64 * 1024 # inline a multipart text part up to this; larger → noted size

    # `source` distinguishes a query param from a body field in the pane; `note`
    # carries a multipart file/binary summary in place of an inline value.
    record Field,
      name : String,
      value : String,
      source : Symbol, # :query | :body
      note : String? = nil

    # The request's form fields, or nil when it carries none.
    def from_flow(target : String, req_head : Bytes?, req_body : Bytes?, max_body : Int32 = MAX_BODY) : Array(Field)?
      fields = [] of Field
      query_fields(target).each { |f| fields << f }
      ct = MediaType.of(req_head)
      is_form = MediaType.form_urlencoded?(ct)
      is_multipart = ct && MediaType.multipart?(ct)
      # The ENTITY, not the wire body. A chunked form POST did not merely go missing here, it
      # came back WRONG: `dechunk` never ran, so the chunk-size line fused onto the first key
      # and `a=1&b=22` was listed as a field named `9\r\na`. This pane re-encodes nothing, so
      # the decode is unconditional.
      if (is_form || is_multipart) && (b = Entity.bytes(req_head, req_body, max_body)) && !b.empty? && b.size <= max_body
        if is_form
          urlencoded(String.new(b), :body).each { |f| fields << f }
        elsif ct
          multipart(b, ct).each { |f| fields << f }
        end
      end
      fields.empty? ? nil : fields.first(MAX_FIELDS)
    end

    # --- internals ----------------------------------------------------------

    private def query_fields(target : String) : Array(Field)
      idx = target.index('?') || return [] of Field
      q = target[(idx + 1)..]
      q.empty? ? [] of Field : urlencoded(q, :query)
    end

    private def urlencoded(body : String, source : Symbol) : Array(Field)
      body.split('&').reject(&.empty?).map do |pair|
        k, sep, v = pair.partition('=')
        name = (URI.decode_www_form(k) rescue k)
        value = sep.empty? ? "" : (URI.decode_www_form(v) rescue v)
        Field.new(name, value, source)
      end
    end

    # The `key=` parameter of a Content-Disposition (`key` lowercase, ending in `=`): quoted
    # (`"…"` / `'…'`) or a bare token up to `;`/whitespace, at the start or after `;`/whitespace
    # — so `name=` never matches inside `filename=`. Scanned as BYTES: a Latin-1
    # `filename="r\xE9sum\xE9.pdf"` made the old regex raise on the invalid UTF-8, and the value
    # comes back unscrubbed (a surface scrubs where it prints).
    private def extract_param(cd : String, key : String) : String?
      b = cd.to_slice
      i = 0
      while i + key.bytesize <= b.size
        if (i == 0 || param_sep?(b[i - 1])) && AsciiBytes.range_eq_ci?(b, i, i + key.bytesize, key.to_slice)
          v = i + key.bytesize
          if v < b.size && (b[v] == 0x22_u8 || b[v] == 0x27_u8) && (close = b.index(b[v], v + 1))
            return String.new(b[v + 1, close - v - 1])
          end
          e = v
          while e < b.size && !param_sep?(b[e])
            e += 1
          end
          return String.new(b[v, e - v]) if e > v
        end
        i += 1
      end
      nil
    end

    # `;` or ASCII whitespace — the old regex's `[;\s]`.
    private def param_sep?(byte : UInt8) : Bool
      byte == 0x3b_u8 || byte.unsafe_chr.ascii_whitespace?
    end

    private def multipart(body : Bytes, ct : String) : Array(Field)
      fields = [] of Field
      boundary = MIME::Multipart.parse_boundary(ct)
      return fields if boundary.nil? || boundary.empty?
      count = 0
      begin
        MIME::Multipart.parse(IO::Memory.new(body), boundary) do |headers, io|
          count += 1
          break if count > MAX_PARTS
          # Per part: one that will not read must not take the parts around it with it.
          fields << (part_field(headers, io.gets_to_end) rescue next)
        end
      rescue
        # tolerant: keep whatever parsed before a malformed part
      end
      fields
    end

    private def part_field(headers : HTTP::Headers, content : String) : Field
      cd = headers["Content-Disposition"]? || ""
      name = extract_param(cd, "name=") || "(unnamed)"
      if (filename = extract_param(cd, "filename=")) && !filename.empty?
        Field.new(name, "", :body, "file: #{filename} (#{content.bytesize} bytes)")
      elsif content.valid_encoding? && content.bytesize <= PART_MAX
        Field.new(name, content, :body)
      else
        Field.new(name, "", :body, "binary, #{content.bytesize} bytes")
      end
    end
  end
end
