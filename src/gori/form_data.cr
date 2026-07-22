require "uri"
require "mime/multipart"

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
    def from_flow(target : String, req_head : Bytes?, req_body : Bytes?) : Array(Field)?
      fields = [] of Field
      query_fields(target).each { |f| fields << f }
      if (b = req_body) && !b.empty? && b.size <= MAX_BODY
        ct = content_type(req_head)
        if ct && ct.downcase.includes?("x-www-form-urlencoded")
          urlencoded(String.new(b), :body).each { |f| fields << f }
        elsif ct && ct.lstrip.downcase.starts_with?("multipart/")
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

    NAME_RE     = /name="([^"]*)"/
    FILENAME_RE = /filename="([^"]*)"/

    private def multipart(body : Bytes, ct : String) : Array(Field)
      fields = [] of Field
      boundary = MIME::Multipart.parse_boundary(ct)
      return fields if boundary.nil? || boundary.empty?
      count = 0
      begin
        MIME::Multipart.parse(IO::Memory.new(body), boundary) do |headers, io|
          count += 1
          break if count > MAX_PARTS
          fields << part_field(headers, io.gets_to_end)
        end
      rescue
        # tolerant: keep whatever parsed before a malformed part
      end
      fields
    end

    private def part_field(headers : HTTP::Headers, content : String) : Field
      cd = headers["Content-Disposition"]? || ""
      name = NAME_RE.match(cd).try(&.[1]) || "(unnamed)"
      if (filename = FILENAME_RE.match(cd).try(&.[1])) && !filename.empty?
        Field.new(name, "", :body, "file: #{filename} (#{content.bytesize} bytes)")
      elsif content.valid_encoding? && content.bytesize <= PART_MAX
        Field.new(name, content, :body)
      else
        Field.new(name, "", :body, "binary, #{content.bytesize} bytes")
      end
    end

    private def content_type(head : Bytes?) : String?
      return nil unless head
      String.new(head).each_line do |line|
        l = line.chomp
        break if l.empty?
        return l[13..].strip if l.size >= 13 && l[0, 13].downcase == "content-type:"
      end
      nil
    end
  end
end
