require "./request_parts"
require "./escape"

module Gori
  module Export
    # A captured request as a runnable Go `net/http` program — the serializer behind the TUI's
    # "Copy as → Go" row and `gori run show <id> --format go`. Surface-neutral, same shape as
    # `Export::Curl`.
    module GoHttp
      # The program for one request, or nil when there is no resolvable URL.
      def self.text(wire : String, target : String) : String?
        parts = RequestParts.from_wire(wire, target)
        parts ? program(parts) : nil
      end

      def self.program(parts : RequestParts::Parts) : String
        s = RequestParts.sendable(parts)
        method = parts.method.empty? ? "GET" : parts.method
        has_body = !s.body.empty?
        binary = has_body && !s.body.valid_encoding?
        imports = ["fmt", "io", "net/http"]
        imports << (binary ? "bytes" : "strings") if has_body
        # `net/http` escapes `URL.Path` on its way to the request line but writes `RawQuery`
        # verbatim, so a captured `/\xed\x95\x9c?q=\xed\x95\x9c` went out half-encoded and half raw
        # — a request-target no other generated client sends. `percent_encode_non_ascii` says
        # which bytes to ask for once, and all five then agree (see `Export::Escape`).
        url = Escape.double_quoted_url(Escape.percent_encode_non_ascii(parts.url))
        String.build do |b|
          b << "package main\n\n"
          b << "import (\n"
          imports.each { |i| b << "\t" << gostr(i) << "\n" }
          b << ")\n\n"
          b << "func main() {\n"
          if has_body
            if binary
              b << "\tbody := bytes.NewReader([]byte{" << s.body.to_slice.map { |x| "0x#{x.to_s(16).rjust(2, '0')}" }.join(", ") << "})\n"
            else
              b << "\tbody := strings.NewReader(" << gostr(s.body) << ")\n"
            end
            b << "\treq, err := http.NewRequest(" << gostr(method) << ", " << url << ", body)\n"
          else
            b << "\treq, err := http.NewRequest(" << gostr(method) << ", " << url << ", nil)\n"
          end
          b << "\tif err != nil {\n\t\tpanic(err)\n\t}\n"
          s.headers.each do |(n, v)|
            # net/http ignores a "Host" entry in req.Header and sends req.Host — so a Host that
            # survived the sendable drop (one that disagrees with the URL) has to be set there,
            # or the program would silently send the URL's host instead of the captured one.
            if n.downcase == "host"
              b << "\treq.Host = " << gostr(v) << "\n"
            else
              # Add, not Set: a repeated header (two Cookie lines, multiple Accept) is preserved
              # rather than collapsed to the last value.
              b << "\treq.Header.Add(" << gostr(n) << ", " << gostr(v) << ")\n"
            end
          end
          b << "\tresp, err := http.DefaultClient.Do(req)\n"
          b << "\tif err != nil {\n\t\tpanic(err)\n\t}\n"
          b << "\tdefer resp.Body.Close()\n"
          b << "\tout, _ := io.ReadAll(resp.Body)\n"
          b << "\tfmt.Println(resp.Status)\n"
          b << "\tfmt.Println(string(out))\n"
          b << "}\n"
        end
      end

      # A Go interpreted (double-quoted) string literal, byte-safe with `\xNN` (`Export::Escape`).
      private def self.gostr(s : String) : String
        String.build do |b|
          b << '"'
          s.to_slice.each { |byte| Escape.double_quoted_byte(b, byte) }
          b << '"'
        end
      end
    end
  end
end
