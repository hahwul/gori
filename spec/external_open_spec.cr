require "./spec_helper"
require "file_utils"
require "compress/gzip"

# `ExternalOpen` is the pure half of "open response in browser": decode, name, write, prune.
# Nothing here spawns anything (that is the Runner's half), so every example is about the
# FILE — which is where the two properties that matter live:
#
#   * the bytes are DECODED, because a `file://` URL carries no `Content-Encoding` and a
#     browser handed gzip shows garbage; and
#   * the EXTENSION is ours. The desktop dispatches on it, so a hostile `Content-Type` must
#     never be able to pick it.
private def resp(content_type : String?, encoding : String? = nil) : Bytes
  String.build do |io|
    io << "HTTP/1.1 200 OK\r\n"
    io << "Content-Type: " << content_type << "\r\n" if content_type
    io << "Content-Encoding: " << encoding << "\r\n" if encoding
    io << "\r\n"
  end.to_slice
end

private def gzipped(text : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |gz| gz.print(text) }
  io.to_slice
end

# ~172 KB of seeded word soup: a truncated gzip prefix of a SMALL body decodes to nothing,
# which is a decode failure rather than the partial result the truncation examples pin.
private def soup : String
  words = %w[alpha beta gamma delta]
  rng = Random.new(5)
  String.build { |io| 30_000.times { io << words[rng.rand(4)] << ' ' } }
end

# Every write goes to `Paths.home_dir/preview`, so the examples run under a GORI_HOME of
# their own and put the real one back.
private def with_preview_home(&)
  prev = ENV["GORI_HOME"]?
  root = File.tempname("gori-external-open")
  Dir.mkdir_p(root)
  ENV["GORI_HOME"] = root
  begin
    yield root
  ensure
    prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe Gori::ExternalOpen do
  describe ".suffix_for" do
    it "maps a known media type through the allowlist" do
      Gori::ExternalOpen.suffix_for(resp("text/html"), "<h1>hi</h1>".to_slice).should eq(".html")
      Gori::ExternalOpen.suffix_for(resp("application/json"), "{}".to_slice).should eq(".json")
      Gori::ExternalOpen.suffix_for(resp("image/png"), Bytes[0x89, 0x50]).should eq(".png")
      Gori::ExternalOpen.suffix_for(resp("application/pdf"), Bytes[0x25, 0x50]).should eq(".pdf")
    end

    it "ignores the charset parameter (essence, not the raw value)" do
      Gori::ExternalOpen.suffix_for(resp("text/html; charset=utf-8"), "x".to_slice).should eq(".html")
    end

    it "folds case, as HTTP does for a media type" do
      Gori::ExternalOpen.suffix_for(resp("TEXT/HTML"), "x".to_slice).should eq(".html")
    end

    it "resolves the +json / +xml families a vendor type uses" do
      Gori::ExternalOpen.suffix_for(resp("application/vnd.api+json"), "{}".to_slice).should eq(".json")
      Gori::ExternalOpen.suffix_for(resp("application/atom+xml"), "<f/>".to_slice).should eq(".xml")
    end

    it "keeps SVG on .svg rather than collapsing it into the +xml family" do
      # The exact table is consulted before the structured-suffix fallbacks; a `.xml` here
      # would stop a browser rendering the image.
      Gori::ExternalOpen.suffix_for(resp("image/svg+xml"), "<svg/>".to_slice).should eq(".svg")
    end

    it "gives an unknown text/* type .txt" do
      Gori::ExternalOpen.suffix_for(resp("text/vnd.made-up"), "hello".to_slice).should eq(".txt")
    end

    # The security property: an extension the desktop dispatches on can only ever come from
    # gori's own table.
    it "never lets an unrecognised type pick its own extension" do
      # Single-line values only: a CRLF inside the stored value is not a hostile TYPE, it is
      # two headers, and which one wins is the head codec's question rather than this table's.
      {"application/x-msdownload", "application/x-sh", "application/octet-stream",
       "x-thing/../../evil.html", "application/x-httpd-php", "text/html.exe"}.each do |ct|
        suffix = Gori::ExternalOpen.suffix_for(resp(ct), Bytes[0x4D, 0x5A, 0x00, 0x00])
        {".txt", ".bin"}.should contain(suffix)
      end
    end

    it "falls back on the body's shape when there is no Content-Type at all" do
      Gori::ExternalOpen.suffix_for(resp(nil), "plain text".to_slice).should eq(".txt")
      Gori::ExternalOpen.suffix_for(resp(nil), Bytes[0x00, 0x01, 0x02]).should eq(".bin")
    end
  end

  describe ".write" do
    it "refuses a flow with no response body, rather than opening an empty window" do
      with_preview_home do
        expect_raises(Gori::Error, /no response body/) do
          Gori::ExternalOpen.write("flow-1", resp("text/html"), nil)
        end
        expect_raises(Gori::Error, /no response body/) do
          Gori::ExternalOpen.write("flow-1", resp("text/html"), Bytes.empty)
        end
      end
    end

    it "writes the body verbatim when there is nothing to decode" do
      with_preview_home do
        r = Gori::ExternalOpen.write("flow-7", resp("text/html"), "<h1>hi</h1>".to_slice)
        File.read(r.path).should eq("<h1>hi</h1>")
        r.media.should eq("text/html")
        r.bytes.should eq(11)
        r.truncated.should be_false
      end
    end

    # The reason the head is passed in at all. gori stores the WIRE form (P7), so most real
    # response bodies on disk are compressed; a browser handed those renders garbage.
    it "inflates a compressed body, so the file holds what the page actually said" do
      with_preview_home do
        body = gzipped("<h1>decoded</h1>")
        r = Gori::ExternalOpen.write("flow-8", resp("text/html", "gzip"), body)
        File.read(r.path).should eq("<h1>decoded</h1>")
        r.bytes.should eq(16)
      end
    end

    # The last-resort text/binary test has to read the bytes that are WRITTEN, not the wire
    # ones: a gzip stream's header carries NULs, so judging the compressed body scored a
    # perfectly readable inflated document as binary and opened it as `.bin`.
    it "judges an unlabelled body by its DECODED shape, not its compressed one" do
      with_preview_home do
        r = Gori::ExternalOpen.write("flow-9", resp(nil, "gzip"), gzipped("plain readable text"))
        File.extname(r.path).should eq(".txt")
        File.read(r.path).should eq("plain readable text")
      end
    end

    it "still calls a genuinely binary decoded body .bin" do
      with_preview_home do
        r = Gori::ExternalOpen.write("flow-10", resp(nil), Bytes[0x00, 0x01, 0x02, 0x03])
        File.extname(r.path).should eq(".bin")
      end
    end

    it "names the file from the stem and lands it in the preview dir" do
      with_preview_home do |root|
        r = Gori::ExternalOpen.write("flow-42", resp("application/json"), "{}".to_slice)
        File.dirname(r.path).should eq(File.join(root, "preview"))
        File.basename(r.path).should start_with("flow-42-")
        File.extname(r.path).should eq(".json")
      end
    end

    it "never lets a stem escape the preview dir" do
      with_preview_home do |root|
        r = Gori::ExternalOpen.write("../../etc/passwd", resp("text/plain"), "x".to_slice)
        File.dirname(r.path).should eq(File.join(root, "preview"))
        File.basename(r.path).should_not contain("/")
        File.basename(r.path).should_not start_with(".")
      end
    end

    # `ContentDecode` hands back the still-COMPRESSED entity for a coding it cannot undo (its
    # display contract: the note beside the bytes says what happened), so `decoded || body`
    # wrote the wire bytes out, named them from the response's own `Content-Type`, and reported
    # a successful open. The operator got a `.html` file byte-identical to the compressed
    # stream — while the History detail pane one key away rendered the reason in yellow.
    it "refuses an encoding it cannot undo instead of writing the compressed wire bytes" do
      with_preview_home do |root|
        wire = "\x00\x01compressed wire bytes that are not a document".to_slice
        expect_raises(Gori::Error, /unsupported/) do
          Gori::ExternalOpen.write("flow-11", resp("text/html", "compress"), wire)
        end
        dir = File.join(root, "preview")
        (Dir.exists?(dir) ? Dir.children(dir) : [] of String).should be_empty
      end
    end

    # The entry guard tests the STORED bytes; a body that decodes to nothing got past it and a
    # 0-byte file was written and announced as an open document.
    it "refuses a body that decodes to nothing rather than opening an empty file" do
      with_preview_home do
        expect_raises(Gori::Error, /decode|nothing/) do
          Gori::ExternalOpen.write("flow-12", resp("text/html", "gzip"), "not gzip at all".to_slice)
        end
      end
    end

    # `decode` discarded both the note and `decode_full`'s end-of-stream flag, so a stream cut
    # mid-way was written as a partial document and the status line said "opened … 48.7KB"
    # with no "(truncated)" — the operator reads the tail as the document's end.
    it "marks a preview truncated when the stream never reached end-of-stream" do
      with_preview_home do
        full = gzipped(soup)
        r = Gori::ExternalOpen.write("flow-13", resp("text/html", "gzip"), full[0, full.size // 2])
        r.bytes.should be > 0
        r.bytes.should be < soup.bytesize
        r.truncated.should be_true
      end
    end

    # The capture cap defaults to 2 MiB (`DEFAULT_CAPTURE_MAX_MIB`), so a stored body over that
    # size IS a prefix — not an edge case. Every other surface reads the flag (`gori history`
    # prints `[response body truncated]`, MCP and the HAR export carry it); this path had no
    # way to be told, so it opened the prefix and called it the document.
    it "carries the source's own truncation verdict into the result" do
      with_preview_home do
        r = Gori::ExternalOpen.write("flow-14", resp("text/html"), "<h1>cut</h1>".to_slice, true)
        r.truncated.should be_true
        File.read(r.path).should eq("<h1>cut</h1>") # still written — a prefix renders
      end
    end

    # A preview holds a WHOLE response body — session tokens, PII — under GORI_HOME rather than
    # a project directory, and it outlives the project. Every other gori file that holds
    # captured data is 0600 (store, settings, project registry, CA key); a bare `File.write`
    # made these 0644, readable by every account on the box.
    it "writes the preview 0600, like every other file that holds captured data" do
      with_preview_home do
        r = Gori::ExternalOpen.write("flow-15", resp("text/html"), "<h1>secret</h1>".to_slice)
        (File.info(r.path).permissions.value & 0o777).should eq(0o600)
      end
    end

    it "gives two writes of the same stem two files, so a re-send is never a stale render" do
      with_preview_home do
        a = Gori::ExternalOpen.write("repeater-1", resp("text/html"), "<p>first</p>".to_slice)
        b = Gori::ExternalOpen.write("repeater-1", resp("text/html"), "<p>second</p>".to_slice)
        a.path.should_not eq(b.path)
        File.read(a.path).should eq("<p>first</p>")
        File.read(b.path).should eq("<p>second</p>")
      end
    end
  end

  describe ".prune" do
    it "keeps the newest N and deletes the rest" do
      with_preview_home do |root|
        dir = File.join(root, "preview")
        Dir.mkdir_p(dir)
        10.times do |i|
          p = File.join(dir, "p#{i}.txt")
          File.write(p, "x")
          File.touch(p, Time.utc + i.seconds)
        end
        Gori::ExternalOpen.prune(dir, keep: 3)
        left = Dir.children(dir).sort
        left.size.should eq(3)
        left.should eq(["p7.txt", "p8.txt", "p9.txt"])
      end
    end

    it "is a no-op below the ceiling" do
      with_preview_home do |root|
        dir = File.join(root, "preview")
        Dir.mkdir_p(dir)
        2.times { |i| File.write(File.join(dir, "p#{i}.txt"), "x") }
        Gori::ExternalOpen.prune(dir, keep: 3)
        Dir.children(dir).size.should eq(2)
      end
    end

    it "swallows a missing directory rather than failing the write that called it" do
      Gori::ExternalOpen.prune(File.join(File.tempname("gori-no-such"), "preview"))
    end

    # gori writes files; the DESKTOP writes back. Hand macOS a `.zip` preview and `open` passes
    # it to Archive Utility, which unpacks the tree IN here. A `File.file?` filter dropped those
    # directories out of the sweep entirely — never counted against `keep`, never deleted, one
    # per archive preview, accumulating under GORI_HOME forever.
    it "sweeps directories a desktop opener unpacked here, not only the files it wrote" do
      with_preview_home do |root|
        dir = File.join(root, "preview")
        Dir.mkdir_p(dir)
        unpacked = File.join(dir, "flow-1-unpacked")
        Dir.mkdir_p(File.join(unpacked, "nested"))
        File.write(File.join(unpacked, "nested", "index.html"), "<p>x</p>")
        File.touch(unpacked, Time.utc)
        3.times do |i|
          p = File.join(dir, "newer#{i}.txt")
          File.write(p, "x")
          File.touch(p, Time.utc + (i + 1).seconds)
        end
        Gori::ExternalOpen.prune(dir, keep: 3)
        Dir.children(dir).sort.should eq(["newer0.txt", "newer1.txt", "newer2.txt"])
        Dir.exists?(unpacked).should be_false # the whole tree, not just its top entry
      end
    end
  end

  describe ".executes?" do
    it "flags the documents a browser runs code out of" do
      with_preview_home do
        {"text/html" => true, "application/xhtml+xml" => true, "image/svg+xml" => true,
         "application/json" => false, "text/plain" => false, "image/png" => false}.each do |ct, expected|
          r = Gori::ExternalOpen.write("flow-1", resp(ct), "x".to_slice)
          Gori::ExternalOpen.executes?(r).should eq(expected)
        end
      end
    end
  end

  describe ".opener" do
    it "names a command on the platforms gori knows, and nil elsewhere" do
      cmd = Gori::ExternalOpen.opener("/tmp/x.html")
      {% if flag?(:darwin) %}
        cmd.should eq({"open", ["/tmp/x.html"]})
      {% elsif flag?(:linux) %}
        cmd.should eq({"xdg-open", ["/tmp/x.html"]})
      {% else %}
        cmd.should be_nil
      {% end %}
    end
  end
end
