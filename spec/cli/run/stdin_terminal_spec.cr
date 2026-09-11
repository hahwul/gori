require "../../spec_helper"

# The seam every stdin door in `gori run` shares (#1034): a flag that reads operator bytes
# from stdin — `--request-stdin`, `--notes-stdin`, and the three flags that spell stdin `-` —
# reads a PIPE or a REDIRECT, and refuses a TERMINAL.
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
# nil where there is no usable one: `/dev/ptmx` is absent or unopenable in a container built
# without `devpts`, and a spec that cannot get a terminal should say so rather than fail as if
# the guard were broken.
private def terminal_io : File?
  File.open("/dev/ptmx", "r+")
rescue
  nil
end

private def with_terminal_io(&)
  io = terminal_io.not_nil!
  begin
    yield io
  ensure
    io.close
  end
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

    # …and for the `IO::Memory` the door specs drive, which is not a file descriptor at all.
    it "stays silent for an IO that has no file descriptor" do
      Gori::CLI::Run.stdin_terminal_error(IO::Memory.new("GET / HTTP/1.1\r\n\r\n"),
        what: "gori run repeater create", noun: "request", hint: hint).should be_nil
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

    probe = terminal_io
    if probe
      probe.close
      it "refuses a terminal, naming the command, the noun and the way out" do
        with_terminal_io do |tty|
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
        end
      end

      # The noun travels from the door, so `--notes-stdin` does not report a "request".
      it "names each door's own noun" do
        with_terminal_io do |tty|
          Gori::CLI::Run.stdin_terminal_error(tty, what: "gori run issues create",
            noun: "notes", hint: hint).not_nil!.should contain("the notes")
        end
      end
    else
      pending "refuses a terminal (no usable /dev/ptmx on this box)"
    end
  end

  # The refusal is only useful if it ends with a command that works. All three roads are
  # named, because an operator who is told two of them reasonably concludes the third is gone.
  describe ".stdin_pipe_hint" do
    it "names the pipe, the redirect and the file flag" do
      Gori::CLI::Run.stdin_pipe_hint("gori run repeater create", flag: "--request-stdin",
        file_flag: "--request-file", producer: "generator")
        .should eq("Pipe it in (`generator | gori run repeater create … --request-stdin`), " \
                   "redirect a file (`gori run repeater create … --request-stdin < FILE`), " \
                   "or pass --request-file=FILE.")
    end

    it "carries each door's own flags" do
      msg = Gori::CLI::Run.stdin_pipe_hint("gori run issues update 7", flag: "--notes-stdin",
        file_flag: "--notes-file", producer: "report-generator")
      msg.should contain("report-generator | gori run issues update 7 … --notes-stdin")
      msg.should contain("--notes-file=FILE")
    end
  end

  # Every decision function here is a `nil`-or-sentence helper whose `abort` lives at the call
  # site, so a green helper next to an unwired door is exactly the failure this pins. The
  # doors end in `abort`/`exit` and cannot be driven in-process, which is why these are
  # assertions over the SOURCE — the house pattern (`interrupt_exit_status_spec.cr`).
  describe "every stdin door is WIRED to the guard, not merely next to it" do
    cli_dir = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli")

    it "routes the shared reader through stdin_terminal_error before it reads" do
      src = File.read(File.join(cli_dir, "run.cr"))
      body = src[src.index!("def self.read_stdin_text")..]
      body = body[..body.index!("\n      end")]
      body.index!("stdin_terminal_error(").should be < body.index!("gets_to_end")
    end

    # The two doors an operator names, each handing the shared reader its own noun and its own
    # way out. A door that passed the wrong flag pair would refuse correctly and then send the
    # operator to another command's option.
    it "hands each named door its own noun and file-flag alternative" do
      repeater = File.read(File.join(cli_dir, "run", "repeater.cr"))
      door = repeater[repeater.index!("def self.read_request_stdin")..]
      door = door[..door.index!("\n      end")]
      door.should contain("\"request\"")
      door.should contain("--request-stdin")
      door.should contain("--request-file")

      issues = File.read(File.join(cli_dir, "run", "issues.cr"))
      notes = issues[issues.index!("def self.notes_content(")..]
      notes = notes[..notes.index!("\n      end")]
      notes.should contain("\"notes\"")
      notes.should contain("--notes-stdin")
      notes.should contain("--notes-file")
    end

    # The sweep, and the point of the whole file: a NEW stdin road cannot be added without
    # either the explicit guard or the implicit road's own `STDIN.tty?` fallback check. Both
    # spellings are legitimate — an implicit source treats a terminal as "no source was
    # given" — and a bare unguarded read is neither.
    it "leaves no unguarded STDIN read anywhere under src/gori/cli" do
      unguarded = [] of String
      Dir.glob(File.join(cli_dir, "**", "*.cr")).sort.each do |path|
        lines = File.read_lines(path)
        lines.each_with_index do |line, i|
          next unless line.includes?("STDIN.gets_to_end")
          next if line.lstrip.starts_with?("#") # a comment may point at the read; code may not
          # The implicit roads guard on the same line (`unless STDIN.tty?`) or on the `elsif`
          # above it; the explicit ones do not mention STDIN here at all, because they hand
          # the fd to `read_stdin_text`.
          guarded = line.includes?("STDIN.tty?") || (i > 0 && lines[i - 1].includes?("STDIN.tty?"))
          unguarded << "#{File.basename(path)}:#{i + 1}: #{line.strip}" unless guarded
        end
      end
      unguarded.should be_empty
    end
  end
end
