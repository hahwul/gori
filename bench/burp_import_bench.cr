# Import::Burp.parse_file over a large "Save items" export — the whole-file scan, not the store.
#
# The scanner walked CHARACTER offsets (`String#index(needle, pos)`, `src[a...b]`), so on any
# export that is not pure ASCII each item's lookups counted from byte 0: quadratic in the file.
# It now walks byte offsets. The rows cover the three shapes that behaved differently: plain
# ASCII, a single non-ASCII byte in the file (enough to lose String's ASCII fast path), and an
# export whose inline messages are full of Korean text.
#
# Build: crystal build bench/burp_import_bench.cr -o bin/burp_import_bench --release
# Run:   bin/burp_import_bench [items]   (default 2000 items of ~4 KiB each, ~16 MB per file)
require "benchmark"
require "base64"

module Gori
  class Error < Exception; end
end

require "../src/gori"

ITEMS = (ARGV[0]? || "2000").to_i

def export(items : Int32, mode : Symbol) : String
  String.build do |io|
    io << %(<?xml version="1.0"?>\n<items burpVersion="2024.1" exportTime="Tue Mar 05 12:34:56 GMT 2024">\n)
    items.times do |i|
      body = mode == :korean ? "본문 " * 700 : "B" * 4096
      req = "GET /p#{i} HTTP/1.1\r\nHost: bench.test\r\n\r\n"
      resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n#{body}"
      io << "<item><time>Tue Mar 05 12:34:56 UTC 2024</time><url><![CDATA[https://bench.test/p#{i}]]></url>"
      io << %(<host ip="1.2.3.4">bench.test</host><port>443</port><protocol>https</protocol>)
      io << %(<request base64="true">) << Base64.strict_encode(req) << "</request>"
      io << "<status>200</status><responselength>" << resp.bytesize << "</responselength>"
      if mode == :korean
        io << %(<response base64="false"><![CDATA[) << resp << "]]></response>"
      else
        io << %(<response base64="true">) << Base64.strict_encode(resp) << "</response>"
      end
      io << "<comment>" << (mode == :one_byte && i == 0 ? "é" : "") << "</comment></item>\n"
    end
    io << "</items>\n"
  end
end

puts "Import::Burp.parse_file, #{ITEMS} items per export:"
{ {:ascii, "ASCII export          "}, {:one_byte, "one non-ASCII byte    "}, {:korean, "Korean inline messages"} }.each do |(mode, label)|
  path = File.tempname("gori-burp-bench", ".xml")
  File.write(path, export(ITEMS, mode))
  begin
    size = File.size(path)
    result = nil
    t = Benchmark.realtime { result = Gori::Import::Burp.parse_file(path) }
    flows = result.try(&.flows.size) || 0
    puts "  #{label} #{(size / 1_048_576).round(1)} MB: #{t.total_milliseconds.round(1)} ms (#{flows} flows)"
  ensure
    File.delete?(path)
  end
end
