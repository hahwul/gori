require "../../spec_helper"

# `gori run repeater create --request-stdin` (#1001): a generated or large raw request that
# reaches gori through a pipe instead of the argument vector, where it would sit in the
# process listing and count against the command-line length limit.
#
# `request_sources` / `request_source_error` / `request_content` are public so this file needs
# no test-only reopen of `Gori::CLI::Run` — the same reason `two_targets_error` is public.
describe "gori run repeater create — the request source" do
  what = "gori run repeater create"

  describe ".request_sources" do
    it "names nothing when the request is to come from --flow (or is missing)" do
      Gori::CLI::Run.request_sources(file: nil, raw: nil, stdin: false).should be_empty
    end

    it "names each source, in the parser's order" do
      Gori::CLI::Run.request_sources(file: "req.txt", raw: nil, stdin: false)
        .should eq(["--request-file"])
      Gori::CLI::Run.request_sources(file: nil, raw: "GET / HTTP/1.1", stdin: false)
        .should eq(["--request-raw"])
      Gori::CLI::Run.request_sources(file: nil, raw: nil, stdin: true)
        .should eq(["--request-stdin"])
      Gori::CLI::Run.request_sources(file: "req.txt", raw: "GET / HTTP/1.1", stdin: true)
        .should eq(["--request-file", "--request-raw", "--request-stdin"])
    end
  end

  describe ".request_source_error" do
    it "accepts exactly one source" do
      Gori::CLI::Run.request_source_error(["--request-file"], flow: false).should be_nil
      Gori::CLI::Run.request_source_error(["--request-raw"], flow: false).should be_nil
      Gori::CLI::Run.request_source_error(["--request-stdin"], flow: false).should be_nil
    end

    # `--flow` is provenance as well as a source, so it pairs with a hand-authored request
    # (`repeater.cr`: "an explicit request must NOT be silently overwritten by the flow's
    # bytes") and must not be counted as a conflict.
    it "accepts --flow alone, and --flow alongside any one source" do
      Gori::CLI::Run.request_source_error([] of String, flow: true).should be_nil
      Gori::CLI::Run.request_source_error(["--request-file"], flow: true).should be_nil
      Gori::CLI::Run.request_source_error(["--request-raw"], flow: true).should be_nil
      Gori::CLI::Run.request_source_error(["--request-stdin"], flow: true).should be_nil
    end

    it "requires a source when there is no --flow to clone" do
      Gori::CLI::Run.request_source_error([] of String, flow: false)
        .should eq("gori run repeater create: either --request-file, --request-raw, " \
                   "--request-stdin, or --flow is required")
    end

    # The branch that reads the request is an `if/elsif` chain, so a second source was
    # dropped by parser order and never mentioned — the file won over the string, and either
    # would have won over a pipe. Two sources cannot both be the request.
    it "refuses every pair, naming both" do
      Gori::CLI::Run.request_source_error(["--request-file", "--request-raw"], flow: false)
        .should eq("gori run repeater create: --request-file, --request-raw cannot be " \
                   "combined — pick one request source")
      Gori::CLI::Run.request_source_error(["--request-file", "--request-stdin"], flow: false)
        .should eq("gori run repeater create: --request-file, --request-stdin cannot be " \
                   "combined — pick one request source")
      Gori::CLI::Run.request_source_error(["--request-raw", "--request-stdin"], flow: false)
        .should eq("gori run repeater create: --request-raw, --request-stdin cannot be " \
                   "combined — pick one request source")
    end

    it "refuses all three, and a conflict outranks the --flow that would have been fine" do
      all = ["--request-file", "--request-raw", "--request-stdin"]
      msg = "gori run repeater create: --request-file, --request-raw, --request-stdin " \
            "cannot be combined — pick one request source"
      Gori::CLI::Run.request_source_error(all, flow: false).should eq(msg)
      Gori::CLI::Run.request_source_error(all, flow: true).should eq(msg)
    end
  end

  # The branch SELECTION, not just the predicates that guard it. An inline `if/elsif` inside
  # `cmd_repeater_create` cannot be reached by a spec — the command opens a store and ends in
  # `abort` — so deleting the `--request-stdin` arm from one is a silent behavior change.
  describe ".request_content" do
    it "hands back the bytes of whichever single source was given" do
      Gori::CLI::Run.request_content(file: nil, raw: "GET /r HTTP/1.1", stdin: false,
        io: IO::Memory.new, what: what).should eq("GET /r HTTP/1.1")
      Gori::CLI::Run.request_content(file: nil, raw: nil, stdin: true,
        io: IO::Memory.new("GET /s HTTP/1.1"), what: what).should eq("GET /s HTTP/1.1")
    end

    # Only reachable with `--flow`, whose capture seeds the request instead. Empty here is
    # what `cmd_repeater_create` reads as "nothing authored", so it must not come back for a
    # source that WAS given.
    it "is empty only when no source at all was named" do
      Gori::CLI::Run.request_content(file: nil, raw: nil, stdin: false,
        io: IO::Memory.new("ignored"), what: what).should eq("")
    end

    it "does not touch stdin unless --request-stdin was the source" do
      io = IO::Memory.new("PIPE")
      Gori::CLI::Run.request_content(file: nil, raw: "RAW", stdin: false, io: io, what: what)
        .should eq("RAW")
      io.pos.should eq(0) # never read
    end
  end

  # The issue's explicit requirement: "the input should preserve the raw HTTP request
  # bytes/line endings consistently with --request-file". Asserted against the SAME content
  # through the `--request-file` door, and on BYTES — a `String` comparison would pass on two
  # strings holding different octets that scrub to the same thing.
  describe ".read_request_stdin" do
    it "preserves CRLF line endings, the ones a raw HTTP request is framed with" do
      raw = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi"
      Gori::CLI::Run.read_request_stdin(IO::Memory.new(raw), what)
        .to_slice.should eq(raw.to_slice)
    end

    it "preserves a body that is not valid UTF-8 — a capture is the payload (P7)" do
      head = "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\n"
      bytes = head.to_slice + Bytes[0xff, 0xfe, 0x01, 0x02]
      read = Gori::CLI::Run.read_request_stdin(IO::Memory.new(bytes), what)
      # The bytes must survive as themselves, not as U+FFFD: a scrub would have rewritten each
      # of the two invalid octets to three, and `Plan.build` would then resync Content-Length
      # to the corruption.
      read.to_slice.should eq(bytes)
      read.to_slice.size.should eq(bytes.size)
    end

    it "reads byte-for-byte what --request-file reads from the same content" do
      raw = "PUT /x HTTP/1.1\r\nHost: h\r\n\r\n\u0000\r\nnot-a-header\r\r\n"
      path = File.tempname("gori-req", ".txt")
      begin
        File.write(path, raw)
        # Both through `request_content`, so this compares the two real doors rather than two
        # readers a spec picked.
        from_file = Gori::CLI::Run.request_content(file: path, raw: nil, stdin: false,
          io: IO::Memory.new, what: what)
        piped = Gori::CLI::Run.request_content(file: nil, raw: nil, stdin: true,
          io: IO::Memory.new(raw), what: what)
        piped.to_slice.should eq(from_file.to_slice)
        piped.to_slice.should eq(raw.to_slice)
      ensure
        File.delete?(path)
      end
    end

    it "keeps a trailing newline, and a request with no trailing newline at all" do
      Gori::CLI::Run.read_request_stdin(IO::Memory.new("GET / HTTP/1.1\r\n\r\n"), what)
        .should eq("GET / HTTP/1.1\r\n\r\n")
      Gori::CLI::Run.read_request_stdin(IO::Memory.new("GET / HTTP/1.1"), what)
        .should eq("GET / HTTP/1.1")
    end

    # A pipe that yielded ANY octets is a request — whether those octets frame one is not this
    # door's call (P7). Emptiness is the caller's to refuse, for every source at once.
    it "returns the empty string for an empty pipe, and the bytes of a whitespace-only one" do
      Gori::CLI::Run.read_request_stdin(IO::Memory.new(""), what).should eq("")
      Gori::CLI::Run.read_request_stdin(IO::Memory.new("\r\n"), what).should eq("\r\n")
    end
  end

  describe ".request_content_error" do
    it "refuses an empty request from whichever source produced it" do
      Gori::CLI::Run.request_content_error(["--request-stdin"], "")
        .should eq("gori run repeater create: the request must not be empty " \
                   "(--request-stdin gave no bytes)")
      Gori::CLI::Run.request_content_error(["--request-raw"], "")
        .should eq("gori run repeater create: the request must not be empty " \
                   "(--request-raw gave no bytes)")
      Gori::CLI::Run.request_content_error(["--request-file"], "")
        .should eq("gori run repeater create: the request must not be empty " \
                   "(--request-file gave no bytes)")
    end

    it "accepts any non-empty request, whitespace-only included (P7)" do
      Gori::CLI::Run.request_content_error(["--request-stdin"], "GET / HTTP/1.1").should be_nil
      Gori::CLI::Run.request_content_error(["--request-stdin"], "\r\n").should be_nil
    end

    # `--flow` seeds the request from the capture AFTER this check, so an empty content with
    # no source named is not yet a verdict — refusing here would refuse every `--flow` clone.
    it "stays silent when no source was named — that is the --flow road" do
      Gori::CLI::Run.request_content_error([] of String, "").should be_nil
    end
  end

  # The ordering constraint, asserted over the SOURCE — the house pattern for a decision whose
  # only home is a command that ends in `abort` (see `interrupt_exit_status_spec.cr`: "both
  # halves end in `exit` and neither can be exercised in-process", and `cli_spec.cr` pinning
  # `unknown_args`).
  #
  # `--request-stdin` BLOCKS until EOF, so every refusal knowable from argv alone has to be
  # reported before the read or the command drains the pipe first — and hangs outright on a
  # terminal — before saying something it knew all along. Both refusals were on the wrong side
  # of it: the source conflict by construction, `--target is required` for the whole life of
  # the command.
  describe "cmd_repeater_create: argv-only refusals sit above the blocking stdin read" do
    it "gates the source conflict and a missing --target before request_content" do
      src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run",
        "repeater.cr"))
      body = src[src.index!("def self.cmd_repeater_create")..]
      read_at = body.index!("request_content(")
      body.index!("request_source_error(").should be < read_at
      body.index!("--target is required").should be < read_at
      # Every decision function is WIRED IN, not merely defined and specced: each of these is
      # a `nil`-or-sentence helper whose `abort` lives at the call site, so dropping the call
      # leaves the helper green and the command permissive.
      body.should contain("request_content_error(")
      # …and the read itself stays above `open_store`, or a pipe that never ends holds the
      # project's shared `<db>.open.lock` while it waits.
      read_at.should be < body.index!("open_store(")
    end

    # The trap this flag could have shipped with. `--flow` doubles as provenance, so it pairs
    # with a hand-authored request — and the line that seeds the request FROM the capture used
    # to re-derive "was one authored?" as `request_file.nil? && request_raw.nil?`, three lines
    # under a comment warning that an explicit request must not be overwritten. A third source
    # added to that chain by hand is a `--flow N --request-stdin` whose piped request is
    # silently replaced by the flow's bytes.
    #
    # So: ONE `request_sources` call in the command, and the seeding guarded by the `authored`
    # it produced. Asserted over the source because reaching that line needs a store, a flow
    # and a command that ends in `abort`.
    it "seeds from the flow through the shared source list, not a re-derived chain" do
      src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run",
        "repeater.cr"))
      body = src[src.index!("def self.cmd_repeater_create")..]
      body = body[..body.index!("\n      private def self.")]
      seed = body.lines.find! &.includes?("String.new(built.bytes)")
      seed.should contain("authored")
      body.scan("request_sources(").size.should eq(1)
      # The re-derivation that was there, in any spelling.
      body.should_not contain("request_file.nil?")
      body.should_not contain("request_raw.nil?")
    end
  end
end
