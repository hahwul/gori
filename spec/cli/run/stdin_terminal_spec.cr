require "../../spec_helper"

# The seam every stdin door in `gori run` shares (#1034): a road that reads operator bytes
# from stdin because a FLAG named it — `--request-stdin`, `--notes-stdin`, the four that spell
# stdin `-`, and a `--…-file` PATH that resolves to a terminal — reads a PIPE or a REDIRECT,
# and refuses a TERMINAL.
#
# It mirrors no single source file, so it lives beside the other cross-subcommand seams under
# spec/cli/run/ (`list_leftovers_spec.cr`, `fuzz_args_spec.cr`) rather than next to one door.
#
# What a terminal does that a pipe does not, and why none of it is survivable here:
#   * it ECHOES the bytes back, so a raw request's `Authorization`/`Cookie` lands in the
#     scrollback and, under a PTY-driven harness, in the captured transcript — the very
#     exposure `--request-stdin` exists to close for argv and shell history;
#   * `^D` FLUSHES the pending line rather than ending the read, so a request with no trailing
#     newline needs two and a driver that sends one hangs;
#   * `MAX_CANON` truncates a long header line before gori sees an octet.

# A real terminal file descriptor. Opening the pty multiplexer allocates a master, and
# `isatty(3)` is true for it on both Linux and Darwin — so the terminal arm is driven for
# real rather than stubbed behind an interface the production code does not use.
#
# nil where there is no usable one: `/dev/ptmx` can be absent, unopenable (a hardened image,
# or one at its pty limit) or present-but-not-a-pty (the node bind-mounted over, devpts not
# mounted). All three must reach `pending` rather than a red example blaming the guard — but
# `tty?` is checked HERE, not assumed from a successful open, or a `/dev/ptmx` that is really
# a regular file would run the terminal examples and fail them for being right.
private def terminal_io : File?
  io = File.open("/dev/ptmx", "r+")
  return io if io.tty?
  io.close
  nil
rescue
  nil
end

# Method bodies, sliced from one `def self.` to the next — the same shape
# `unknown_args_sweep_spec.cr` uses, and kept file-private for the same reason. NOT a
# hard-coded `"\n      end"`: that terminator assumes today's nesting depth, so moving a door
# one level (or writing a 6-space-indented `end` inside it) would silently truncate the window
# and fail a correct door, or raise `NotFoundError` in place of a verdict.
private def method_body(src : String, name : String) : String
  lines = src.split("\n")
  starts = [] of Int32
  lines.each_with_index { |l, i| starts << i if l.matches?(/^ *(private )?def self\./) }
  at = starts.index { |i| lines[i].matches?(/^ *(private )?def self\.#{Regex.escape(name)}\b/) }
  raise "method #{name} not found" unless at
  lines[starts[at]...(starts[at + 1]? || lines.size)].join("\n")
end

private CLI_DIR = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli")

private def cli_source(*parts : String) : String
  File.read(File.join(CLI_DIR, *parts))
end

describe "gori run — stdin doors refuse a terminal" do
  hint = "Pipe it in, or pass a path."

  describe ".stdin_terminal_error" do
    # The road every script and CI job takes, driven as a REAL pipe rather than an in-memory
    # stand-in: `generator | gori run …` hands fd 0 an `IO::FileDescriptor`, so "not a
    # terminal" has to be decided by `tty?` and not by the IO's class.
    it "stays silent for a pipe" do
      reader, writer = IO.pipe
      begin
        writer.print "GET / HTTP/1.1\r\n\r\n"
        writer.close
        reader.should be_a(IO::FileDescriptor)
        Gori::CLI::Run.stdin_terminal_error(reader, what: "gori run repeater create",
          noun: "request", hint: hint).should be_nil
      ensure
        reader.close
        writer.close unless writer.closed?
      end
    end

    # `--request-stdin < req.http` is the second documented spelling, and a redirect hands the
    # process a REGULAR FILE on fd 0. Refusing it would break the road the refusal recommends.
    it "stays silent for a `< file` redirect" do
      path = File.tempname("gori-stdin", ".http")
      begin
        File.write(path, "GET / HTTP/1.1\r\n\r\n")
        File.open(path) do |f|
          Gori::CLI::Run.stdin_terminal_error(f, what: "gori run repeater create",
            noun: "request", hint: hint).should be_nil
        end
      ensure
        File.delete?(path)
      end
    end

    # …and for the `IO::Memory` the door specs drive, which is not a file descriptor at all.
    it "stays silent for an IO that has no file descriptor" do
      Gori::CLI::Run.stdin_terminal_error(IO::Memory.new("GET / HTTP/1.1\r\n\r\n"),
        what: "gori run repeater create", noun: "request", hint: hint).should be_nil
    end

    # BOTH terminal examples are registered on each arm of this gate, so a box without a pty
    # reports two pendings rather than one pending and one example that quietly vanished —
    # a regression in the `noun` wiring would otherwise ship with nothing on screen to miss.
    if terminal_io
      it "refuses a terminal, naming the command, the noun and the way out" do
        tty = terminal_io.not_nil!
        begin
          err = Gori::CLI::Run.stdin_terminal_error(tty, what: "gori run repeater create",
            noun: "request", hint: hint)
          err.should_not be_nil
          msg = err.not_nil!
          # The command prefix every `gori run` refusal carries, so the operator knows which
          # of a pipeline's stages spoke.
          msg.should start_with("gori run repeater create: ")
          msg.should contain("the request")
          # BOTH failure modes, because fixing only the one they hit sends them back for the
          # other: the echo is why it is unsafe, the ^D is why it looked hung.
          msg.should contain("echoes")
          msg.should contain("^D")
          # …and the caller's own way out, verbatim.
          msg.should contain(hint)
        ensure
          tty.close
        end
      end

      # The noun travels from the door, so `--notes-stdin` does not report a "request".
      it "names each door's own noun" do
        tty = terminal_io.not_nil!
        begin
          Gori::CLI::Run.stdin_terminal_error(tty, what: "gori run issues create",
            noun: "notes", hint: hint).not_nil!.should contain("the notes")
        ensure
          tty.close
        end
      end
    else
      pending "refuses a terminal, naming the command, the noun and the way out (no usable /dev/ptmx)"
      pending "names each door's own noun (no usable /dev/ptmx)"
    end
  end

  # The refusal is only useful if it ends with a command that works — and one that is the
  # command the operator was already running.
  describe ".stdin_pipe_hint" do
    it "names the pipe, the redirect and the file flag" do
      Gori::CLI::Run.stdin_pipe_hint("gori run repeater create", flag: "--request-stdin",
        file_flag: "--request-file", producer: "generator")
        .should eq("Pipe it in (`generator | gori run repeater create … --request-stdin`), " \
                   "redirect a file (`gori run repeater create … --request-stdin < FILE`), " \
                   "or pass --request-file=FILE.")
    end

    # A `-` door has no file-flag sibling: the path the `-` stands in for IS the alternative.
    it "offers the path itself where there is no file flag" do
      Gori::CLI::Run.stdin_pipe_hint("gori run authorize", flag: "--identities=-")
        .should eq("Pipe it in (`producer | gori run authorize … --identities=-`), " \
                   "redirect a file (`gori run authorize … --identities=- < FILE`), " \
                   "or pass the file's path instead of `-`.")
    end

    # The flag has to appear INSIDE both examples. A hint that hides it behind the `…` is
    # followable into a DIFFERENT command: `producer | gori run authorize 42` replays live
    # traffic under the project's saved identity set and reports success, and
    # `producer | gori run sequence` sends the token list as a request template.
    it "names the flag in every example it prints" do
      %w[--request-stdin --notes-stdin --identities=- --tokens=- --response-file=-].each do |flag|
        msg = Gori::CLI::Run.stdin_pipe_hint("gori run x", flag: flag)
        msg.scan(flag).size.should eq(2)
        msg.should contain("| gori run x … #{flag}`")
        msg.should contain("gori run x … #{flag} < FILE`")
      end
    end
  end

  # Every decision function here is a `nil`-or-sentence helper whose `abort` lives at the call
  # site, so a green helper next to an unwired door is exactly the failure this pins. The
  # doors end in `abort`/`exit` and cannot be driven in-process, which is why these are
  # assertions over the SOURCE — the house pattern (`interrupt_exit_status_spec.cr`).
  describe "every stdin door is WIRED to the guard, not merely next to it" do
    # Not just "the two names appear in this order": the verdict has to END the command.
    # Swapping the `abort` for a `STDERR.puts` leaves both substrings in place, in order,
    # and lets the read — and the echo — happen anyway.
    it "aborts with the verdict before the shared reader reads" do
      body = method_body(cli_source("run.cr"), "read_stdin_text")
      body.should match(/if err = stdin_terminal_error\([^\n]*\n\s*abort err\n\s*end/)
      body.index!("stdin_terminal_error(").should be < body.index!("gets_to_end")
    end

    # A PATH can name a terminal too (`--request-file /dev/stdin`), and that check rides on
    # the open `read_input_file` was already making — so it must sit inside the open, above
    # the read, and abort the same way.
    it "checks the opened file too, before reading it" do
      body = method_body(cli_source("run.cr"), "read_input_file")
      body.should match(/if err = stdin_terminal_error\([\s\S]*?\n\s*abort err\n\s*end/)
      body.index!("stdin_terminal_error(").should be < body.index!("gets_to_end")
      # `File.read` cannot be checked, and its `File::Error` rescue could not catch the bare
      # `IO::Error` that `read(2)` on a directory raises.
      body.should_not contain("File.read(path)")
      body.should contain("rescue ex : IO::Error")
    end

    # Each door hands the shared reader its own noun and its own way out. A door that passed
    # the wrong flag pair would refuse correctly and then send the operator to another
    # command's option.
    it "hands each named door its own noun and alternative" do
      door = method_body(cli_source("run", "repeater.cr"), "read_request_stdin")
      door.should contain("\"request\"")
      door.should contain("--request-stdin")
      door.should contain("--request-file")

      notes = method_body(cli_source("run", "issues.cr"), "notes_content")
      notes.should contain("\"notes\"")
      notes.should contain("--notes-stdin")
      notes.should contain("--notes-file")

      # The three `-` doors, each naming its own flag rather than a placeholder — and
      # `rewriter`'s saying `rewriter add`, the only subcommand that reaches it (bare
      # `gori run rewriter` dispatches to the LIST subcommand).
      stub = method_body(cli_source("run", "rewriter.cr"), "read_stub_response")
      stub.should contain("gori run rewriter add")
      stub.should contain("--response-file=-")
      cli_source("run", "sequence.cr").should contain("flag: \"--tokens=-\"")
      cli_source("run", "authorize.cr").should contain("flag: \"--identities=-\"")
    end

    # The IMPLICIT roads read through `read_stdin_fallback`, not a bare `io.gets_to_end`. They
    # take no terminal guard — a terminal there means "no source was given", and each command
    # answers that with its own usage line — but they do take the same `IO::Error` rescue, or
    # fd 0 closed by a cron/systemd unit (`gori run notes create 0<&-`) reaches the operator as
    # a Crystal backtrace while the five flag doors print a sentence.
    it "routes every implicit stdin road through the rescued fallback reader" do
      {
        {"notes.cr", "gori run notes"}, {"decoder.cr", "gori run decoder"},
        {"jwt.cr", "gori run jwt"}, {"cookie.cr", "gori run cookie"},
        {"mine.cr", "gori run mine"}, {"fuzz.cr", "gori run fuzz"},
        {"sequence.cr", "gori run sequence"},
      }.each do |file, what|
        src = cli_source("run", file)
        src.should contain("read_stdin_fallback(STDIN, \"#{what}\"")
        # …and no bare read left beside it.
        src.should_not contain("STDIN.gets_to_end")
      end
      method_body(cli_source("run.cr"), "read_stdin_fallback")
        .should contain("rescue ex : IO::Error")
    end

    # A PATH that names a terminal is refused by the three wordlist loaders too, each raising
    # what its own error funnel already catches — `Gori::Error` for fuzz, `IO::Error` for the
    # miner/discover pair, whose `PlanError::Reason::Wordlist` arm reports it as
    # `wordlist error: …`. The predicate itself has ONE home.
    it "refuses a terminal wordlist in all three loaders, through one predicate" do
      root = File.join(__DIR__, "..", "..", "..", "src", "gori")
      {
        {"fuzz/payload.cr", "Gori::Error.new"},
        {"miner/wordlist.cr", "IO::Error.new"},
        {"discover/wordlist.cr", "IO::Error.new"},
      }.each do |file, raises|
        src = File.read(File.join(root, file))
        src.should contain("Gori::TtyPath.terminal?")
        src.should contain("is a terminal, not a file")
        src.should contain(raises)
      end
      # No second copy of the predicate anywhere: the `character_device?` pre-check is what
      # keeps it from blocking on a FIFO, and a re-derivation next to a caller loses it.
      File.read(File.join(root, "tty_path.cr")).should contain("character_device?")
    end

    # The sweep, and the point of the whole file: a NEW stdin road cannot be added without
    # either the explicit guard or the implicit road's own `STDIN.tty?` fallback check. Both
    # spellings are legitimate — an implicit source treats a terminal as "no source was
    # given" — and a bare unguarded read is neither.
    #
    # Scoped to `src/gori/cli/`, and by ENCLOSING METHOD rather than by adjacent line: a
    # previous-line test both passes a read whose comment merely mentions `STDIN.tty?` and
    # fails a correctly guarded one the moment an explanatory line is written between the two
    # (house style here). The guard must also be NEGATIVE — `unless`/`!` — since a positive
    # `if STDIN.tty?` above a read is the #1034 bug itself.
    #
    # It cannot see an aliased handle (`io = STDIN` then `io.gets_to_end`), and it deliberately
    # does not reach `src/gori/mcp/server.cr`, whose stdio transport IS stdin by design.
    it "leaves no unguarded STDIN read anywhere under src/gori/cli" do
      read = /STDIN\.(gets|read|each_line|peek)|IO\.copy\(\s*STDIN|read_stdin_fallback\(\s*STDIN/
      negative_guard = /(unless\s+.*STDIN\.tty\?)|(!\s*STDIN\.tty\?)/
      unguarded = [] of String
      Dir.glob(File.join(CLI_DIR, "**", "*.cr")).sort.each do |path|
        lines = File.read_lines(path)
        # Method starts, so a read can be attributed to the body it sits in.
        starts = [] of Int32
        lines.each_with_index { |l, i| starts << i if l.matches?(/^ *(private )?def /) }
        lines.each_with_index do |line, i|
          next if line.lstrip.starts_with?("#") # a comment may point at a read; code may not
          next unless line.matches?(read)
          from = starts.reverse_each.find { |s| s <= i } || 0
          to = starts.find { |s| s > i } || lines.size
          guarded = lines[from...to].any? do |l|
            !l.lstrip.starts_with?("#") && l.matches?(negative_guard)
          end
          unguarded << "#{File.basename(path)}:#{i + 1}: #{line.strip}" unless guarded
        end
      end
      unguarded.should be_empty
    end
  end
end
