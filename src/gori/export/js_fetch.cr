require "./request_parts"
require "./escape"

module Gori
  module Export
    # A captured request as a runnable browser/Node `fetch()` call — the serializer behind the
    # TUI's "Copy as → fetch" row and `gori run show <id> --format fetch`. Surface-neutral, same
    # shape as `Export::Curl`.
    module JsFetch
      # The fetch call for one request, or nil when there is no resolvable URL.
      def self.text(wire : String, target : String) : String?
        parts = RequestParts.from_wire(wire, target)
        parts ? code(parts) : nil
      end

      def self.code(parts : RequestParts::Parts) : String
        s = RequestParts.sendable(parts)
        # A string body is UTF-8-encoded by fetch, so a body that is NOT valid UTF-8 cannot ride
        # as a string without a byte >0x7f re-encoding to two bytes. Those take the Uint8Array
        # path, which is exact.
        binary = !s.body.empty? && !s.body.valid_encoding?
        String.build do |b|
          b << "fetch(" << jsstr(Escape.percent_encode_non_ascii(parts.url)) << ", {\n"
          b << "  method: " << jsstr(parts.method.empty? ? "GET" : parts.method) << ",\n"
          unless s.headers.empty?
            # An object literal collapses a repeated header name to the last value. When the
            # capture has one, emit the array-of-pairs `headers` form instead — fetch accepts it
            # and it preserves every occurrence, so a duplicate is reproduced rather than lost.
            if RequestParts.duplicate_header_names(s.headers).empty?
              b << "  headers: {\n"
              s.headers.each { |(n, v)| b << "    " << jsstr(n) << ": " << jsstr(v) << ",\n" }
              b << "  },\n"
            else
              b << "  headers: [\n"
              s.headers.each { |(n, v)| b << "    [" << jsstr(n) << ", " << jsstr(v) << "],\n" }
              b << "  ],\n"
            end
          end
          unless s.body.empty?
            if binary
              b << "  // body is not valid UTF-8; sent as raw bytes so it is reproduced exactly.\n"
              b << "  body: new Uint8Array([" << s.body.to_slice.join(", ") << "]),\n"
            else
              b << "  body: " << jstext(s.body) << ",\n"
            end
          end
          b << "})\n"
          b << "  .then((r) => r.text())\n"
          b << "  .then(console.log);\n"
        end
      end

      # A JS double-quoted string, byte-safe with `\xNN` (a single code unit 0x00-0xFF). For the
      # HEADERS and the method, where that is exactly right: a `Headers` value is a byte sequence
      # and fetch puts each code unit on the wire as one byte. The URL and the body are TEXT the
      # engine re-encodes, and take `jstext` / `Escape.percent_encode_non_ascii` instead.
      private def self.jsstr(s : String) : String
        String.build do |b|
          b << '"'
          s.to_slice.each { |byte| Escape.double_quoted_byte(b, byte) }
          b << '"'
        end
      end

      # A JS double-quoted string for text fetch RE-ENCODES as UTF-8 — the body. Character-wise
      # (`Export::Escape.double_quoted_char`), because a `\xNN` per UTF-8 byte is one code unit
      # each and fetch encodes each of those to two bytes: a 6-byte Korean body went out as 12,
      # under a Content-Length of 12, so the endpoint received bytes the capture never sent. Only
      # reached for a body that is valid UTF-8; one that is not takes the Uint8Array path above.
      private def self.jstext(s : String) : String
        String.build do |b|
          b << '"'
          s.each_char { |ch| Escape.double_quoted_char(b, ch) }
          b << '"'
        end
      end
    end
  end
end
