require "./request_parts"
require "./escape"

module Gori
  module Export
    # A captured request as a runnable Python `requests` script — the serializer behind the
    # TUI's "Copy as → Python" row and `gori run show <id> --format python`. Surface-neutral, the
    # same shape as `Export::Curl`: pure request→text, delegating the parse and the header-drop
    # decision to `Export::RequestParts`.
    module PythonRequests
      # The script for one request, or nil when there is no resolvable URL (`RequestParts`).
      def self.text(wire : String, target : String) : String?
        parts = RequestParts.from_wire(wire, target)
        parts ? script(parts) : nil
      end

      def self.script(parts : RequestParts::Parts) : String
        s = RequestParts.sendable(parts)
        String.build do |b|
          b << "import requests\n\n"
          # The URL is TEXT to requests, which percent-encodes the str's UTF-8 — see
          # `Escape.percent_encode_non_ascii`. The headers below stay byte-wise: requests encodes
          # a header str latin-1, so a `\xNN` escape is one byte on the wire.
          b << "url = " << pystr(Escape.percent_encode_non_ascii(parts.url)) << "\n"
          unless s.headers.empty?
            # requests takes headers as a dict, which cannot hold a repeated name — the last
            # value wins. curl (`-H` twice) and Go (`Header.Add`) reproduce both; a dict cannot,
            # so say so rather than silently send a request short a header the capture carried.
            dups = RequestParts.duplicate_header_names(s.headers)
            unless dups.empty?
              b << "# note: #{dups.join(", ")} appeared more than once; a requests dict keeps only the\n"
              b << "# last value of each. To send the repeated header, build the request with urllib3\n"
              b << "# or see --format curl. --format raw has the exact bytes.\n"
            end
            b << "headers = {\n"
            s.headers.each { |(n, v)| b << "    " << pystr(n) << ": " << pystr(v) << ",\n" }
            b << "}\n"
          end
          # The body is a bytes literal, not a str: requests sends `data=<bytes>` verbatim, so a
          # binary body (protobuf, a raw upload) is reproduced exactly, and the kept Content-Type
          # header tells the server how to read it.
          b << "data = " << pybytes(s.body) << "\n" unless s.body.empty?
          b << "resp = requests.request(" << pystr(parts.method.empty? ? "GET" : parts.method) << ", url"
          b << ", headers=headers" unless s.headers.empty?
          b << ", data=data" unless s.body.empty?
          b << ")\n"
          b << "print(resp.status_code)\n"
          b << "print(resp.text)\n"
        end
      end

      # A Python double-quoted str, byte-safe. Header/URL text; requests encodes a str latin-1
      # on the wire, so a `\xNN` escape round-trips a single byte.
      private def self.pystr(s : String) : String
        String.build do |b|
          b << '"'
          s.to_slice.each { |byte| Escape.double_quoted_byte(b, byte) }
          b << '"'
        end
      end

      # A Python bytes literal (`b"…"`) — lossless for a body of arbitrary bytes. Python's `b"…"`
      # and `"…"` share the same escape table (`Export::Escape`).
      private def self.pybytes(s : String) : String
        String.build do |b|
          b << "b\""
          s.to_slice.each { |byte| Escape.double_quoted_byte(b, byte) }
          b << '"'
        end
      end
    end
  end
end
