require "../../spec_helper"

# Test seam: `request_sources`, `request_source_error` and `read_request_stdin` are private
# module methods and `cmd_repeater_create` ends in `abort`, so this thin caller (it exists
# only in the test binary) is the only way to read the decision back without running the
# binary. Defaults mirror the parser's.
module Gori::CLI::Run
  def self.spec_request_sources(file : String? = nil, raw : String? = nil,
                                stdin : Bool = false) : Array(String)
    request_sources(file: file, raw: raw, stdin: stdin)
  end

  def self.spec_request_source_error(file : String? = nil, raw : String? = nil,
                                     stdin : Bool = false, flow : Bool = false) : String?
    request_source_error(file: file, raw: raw, stdin: stdin, flow: flow)
  end

  def self.spec_read_request_stdin(io : IO) : String?
    read_request_stdin(io)
  end

  # The other half of the byte-for-byte claim: what `--request-file` reads.
  def self.spec_read_input_file(path : String) : String
    read_input_file(path, "gori run repeater create")
  end
end

# `gori run repeater create --request-stdin` (#1001): a generated or large raw request that
# reaches gori through a pipe instead of the argument vector, where it would sit in the
# process listing and count against the command-line length limit.
describe "gori run repeater create — the request source" do
  describe ".request_sources" do
    it "names nothing when the request is to come from --flow (or is missing)" do
      Gori::CLI::Run.spec_request_sources.should be_empty
    end

    it "names each source, in the parser's order" do
      Gori::CLI::Run.spec_request_sources(file: "req.txt").should eq(["--request-file"])
      Gori::CLI::Run.spec_request_sources(raw: "GET / HTTP/1.1").should eq(["--request-raw"])
      Gori::CLI::Run.spec_request_sources(stdin: true).should eq(["--request-stdin"])
      Gori::CLI::Run.spec_request_sources(file: "req.txt", raw: "GET / HTTP/1.1", stdin: true)
        .should eq(["--request-file", "--request-raw", "--request-stdin"])
    end
  end

  describe ".request_source_error" do
    it "accepts exactly one source" do
      Gori::CLI::Run.spec_request_source_error(file: "req.txt").should be_nil
      Gori::CLI::Run.spec_request_source_error(raw: "GET / HTTP/1.1").should be_nil
      Gori::CLI::Run.spec_request_source_error(stdin: true).should be_nil
    end

    # `--flow` is provenance as well as a source, so it pairs with a hand-authored request
    # (`repeater.cr`: "an explicit request must NOT be silently overwritten by the flow's
    # bytes") and must not be counted as a conflict.
    it "accepts --flow alone, and --flow alongside any one source" do
      Gori::CLI::Run.spec_request_source_error(flow: true).should be_nil
      Gori::CLI::Run.spec_request_source_error(file: "req.txt", flow: true).should be_nil
      Gori::CLI::Run.spec_request_source_error(raw: "GET / HTTP/1.1", flow: true).should be_nil
      Gori::CLI::Run.spec_request_source_error(stdin: true, flow: true).should be_nil
    end

    it "requires a source when there is no --flow to clone" do
      Gori::CLI::Run.spec_request_source_error
        .should eq("gori run repeater create: either --request-file, --request-raw, " \
                   "--request-stdin, or --flow is required")
    end

    # The branch that reads the request is an `if/elsif` chain, so a second source was
    # dropped by parser order and never mentioned — the file won over the string, and either
    # would have won over a pipe. Two sources cannot both be the request.
    it "refuses every pair, naming both" do
      Gori::CLI::Run.spec_request_source_error(file: "req.txt", raw: "GET / HTTP/1.1")
        .should eq("gori run repeater create: --request-file, --request-raw cannot be " \
                   "combined — pick one request source")
      Gori::CLI::Run.spec_request_source_error(file: "req.txt", stdin: true)
        .should eq("gori run repeater create: --request-file, --request-stdin cannot be " \
                   "combined — pick one request source")
      Gori::CLI::Run.spec_request_source_error(raw: "GET / HTTP/1.1", stdin: true)
        .should eq("gori run repeater create: --request-raw, --request-stdin cannot be " \
                   "combined — pick one request source")
    end

    it "refuses all three, and a conflict outranks the --flow that would have been fine" do
      msg = "gori run repeater create: --request-file, --request-raw, --request-stdin " \
            "cannot be combined — pick one request source"
      Gori::CLI::Run.spec_request_source_error(file: "req.txt", raw: "GET /", stdin: true)
        .should eq(msg)
      Gori::CLI::Run.spec_request_source_error(file: "req.txt", raw: "GET /", stdin: true,
        flow: true).should eq(msg)
    end
  end

  # The issue's explicit requirement: "the input should preserve the raw HTTP request
  # bytes/line endings consistently with --request-file". Asserted against `read_input_file`
  # reading the SAME content out of a tempfile, and on BYTES — a `String` comparison would
  # pass on two strings holding different octets that scrub to the same thing.
  describe ".read_request_stdin" do
    it "preserves CRLF line endings, the ones a raw HTTP request is framed with" do
      raw = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi"
      read = Gori::CLI::Run.spec_read_request_stdin(IO::Memory.new(raw))
      read.should_not be_nil
      read.to_s.to_slice.should eq(raw.to_slice)
    end

    it "preserves a body that is not valid UTF-8 — a capture is the payload (P7)" do
      head = "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\n"
      bytes = head.to_slice + Bytes[0xff, 0xfe, 0x01, 0x02]
      read = Gori::CLI::Run.spec_read_request_stdin(IO::Memory.new(bytes))
      read.should_not be_nil
      read.to_s.to_slice.should eq(bytes)
      # The bytes must survive as themselves, not as U+FFFD: a scrub would have rewritten
      # each of the two invalid octets to three, and `--no-auto-cl` aside, `Plan.build` would
      # then resync Content-Length to the corruption.
      read.to_s.to_slice.size.should eq(bytes.size)
    end

    it "reads byte-for-byte what --request-file reads from the same content" do
      raw = "PUT /x HTTP/1.1\r\nHost: h\r\n\r\n\x00\r\nnot-a-header\r\r\n"
      path = File.tempname("gori-req", ".txt")
      begin
        File.write(path, raw)
        from_file = Gori::CLI::Run.spec_read_input_file(path)
        piped = Gori::CLI::Run.spec_read_request_stdin(IO::Memory.new(raw))
        piped.should_not be_nil
        piped.to_s.to_slice.should eq(from_file.to_slice)
      ensure
        File.delete?(path)
      end
    end

    it "keeps a trailing newline, and a request with no trailing newline at all" do
      Gori::CLI::Run.spec_read_request_stdin(IO::Memory.new("GET / HTTP/1.1\r\n\r\n"))
        .should eq("GET / HTTP/1.1\r\n\r\n")
      Gori::CLI::Run.spec_read_request_stdin(IO::Memory.new("GET / HTTP/1.1"))
        .should eq("GET / HTTP/1.1")
    end

    # The dead-generator case the caller `abort`s on. A pipe that yielded ANY octets is a
    # request — whether those octets frame one is not this door's call (P7), so a lone CRLF
    # comes back rather than being read as "nothing arrived".
    it "reports an empty pipe as nil, and a whitespace-only one as the bytes it got" do
      Gori::CLI::Run.spec_read_request_stdin(IO::Memory.new("")).should be_nil
      Gori::CLI::Run.spec_read_request_stdin(IO::Memory.new("\r\n")).should eq("\r\n")
    end
  end
end
