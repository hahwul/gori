require "../../spec_helper"

# `gori run issues create/update --notes/--notes-file/--notes-stdin` (#1019): a security
# write-up that reaches gori through a file or a pipe instead of the argument vector, where it
# sits in the process listing and the shell history, and where `create` then `update` was the
# only way to file a complete issue at all.
#
# `notes_sources` / `notes_source_error` / `notes_content` are public so this file needs no
# test-only reopen of `Gori::CLI::Run` — the same reason `request_sources` is.
describe "gori run issues — the notes source" do
  create = "gori run issues create"
  update = "gori run issues update"

  describe ".notes_sources" do
    it "names nothing when no notes source was given" do
      Gori::CLI::Run.notes_sources(notes: nil, file: nil, stdin: false).should be_empty
    end

    it "names each source, in the parser's order" do
      Gori::CLI::Run.notes_sources(notes: "verified", file: nil, stdin: false)
        .should eq(["--notes"])
      Gori::CLI::Run.notes_sources(notes: nil, file: "report.md", stdin: false)
        .should eq(["--notes-file"])
      Gori::CLI::Run.notes_sources(notes: nil, file: nil, stdin: true)
        .should eq(["--notes-stdin"])
      Gori::CLI::Run.notes_sources(notes: "verified", file: "report.md", stdin: true)
        .should eq(["--notes", "--notes-file", "--notes-stdin"])
    end

    # An EMPTY `--notes ''` is the operator asking to clear the notes, not the absence of a
    # source: counted as absent it would pair silently with `--notes-file`, and the file would
    # win over the clear that was typed second.
    it "counts an empty --notes as the source it is" do
      Gori::CLI::Run.notes_sources(notes: "", file: nil, stdin: false).should eq(["--notes"])
    end
  end

  describe ".notes_source_error" do
    it "accepts no source at all — notes are optional on both subcommands" do
      Gori::CLI::Run.notes_source_error([] of String, create).should be_nil
      Gori::CLI::Run.notes_source_error([] of String, update).should be_nil
    end

    it "accepts exactly one source" do
      Gori::CLI::Run.notes_source_error(["--notes"], create).should be_nil
      Gori::CLI::Run.notes_source_error(["--notes-file"], create).should be_nil
      Gori::CLI::Run.notes_source_error(["--notes-stdin"], create).should be_nil
    end

    # `notes_content` is an `if/elsif` chain, so a second source is dropped by parser order and
    # never mentioned — `--notes-file report.md --notes-stdin` would store the file and not even
    # drain the pipe. Two sources cannot both be the body.
    it "refuses every pair, naming both, in the subcommand that was run" do
      Gori::CLI::Run.notes_source_error(["--notes", "--notes-file"], create)
        .should eq("gori run issues create: --notes, --notes-file cannot be combined — " \
                   "pick one notes source")
      Gori::CLI::Run.notes_source_error(["--notes", "--notes-stdin"], update)
        .should eq("gori run issues update: --notes, --notes-stdin cannot be combined — " \
                   "pick one notes source")
      Gori::CLI::Run.notes_source_error(["--notes-file", "--notes-stdin"], update)
        .should eq("gori run issues update: --notes-file, --notes-stdin cannot be combined — " \
                   "pick one notes source")
    end

    it "refuses all three" do
      Gori::CLI::Run.notes_source_error(["--notes", "--notes-file", "--notes-stdin"], create)
        .should eq("gori run issues create: --notes, --notes-file, --notes-stdin cannot be " \
                   "combined — pick one notes source")
    end
  end

  # The branch SELECTION, not just the predicate that guards it. An inline `if/elsif` inside
  # `cmd_issues_create` cannot be reached by a spec — the command opens a store and ends in
  # `abort` — so deleting the `--notes-stdin` arm from one is a silent behavior change.
  describe ".notes_content" do
    it "hands back the bytes of whichever single source was given" do
      Gori::CLI::Run.notes_content(notes: "seen on staging", file: nil, stdin: false,
        io: IO::Memory.new, what: create).should eq("seen on staging")
      Gori::CLI::Run.notes_content(notes: nil, file: nil, stdin: true,
        io: IO::Memory.new("piped write-up"), what: create).should eq("piped write-up")
    end

    # nil, NOT "": both callers read nil as "leave the notes alone" and "" as "clear them", and
    # collapsing the two would have every `issues update 7 --status confirmed` wipe the body it
    # was never asked about.
    it "is nil — not empty — when no source at all was named" do
      Gori::CLI::Run.notes_content(notes: nil, file: nil, stdin: false,
        io: IO::Memory.new("ignored"), what: update).should be_nil
    end

    it "hands back an empty body as itself — the gate below, not the reader, judges it" do
      Gori::CLI::Run.notes_content(notes: "", file: nil, stdin: false,
        io: IO::Memory.new, what: update).should eq("")
      Gori::CLI::Run.notes_content(notes: nil, file: nil, stdin: true,
        io: IO::Memory.new(""), what: update).should eq("")
    end

    it "does not touch stdin unless --notes-stdin was the source" do
      io = IO::Memory.new("PIPE")
      Gori::CLI::Run.notes_content(notes: "TYPED", file: nil, stdin: false, io: io, what: create)
        .should eq("TYPED")
      io.pos.should eq(0) # never read
    end
  end

  # `notes = ''` is a DESTRUCTIVE write on `update`, and a pipeline exits with gori's status, so
  # `report-generator | gori run issues update 7 --notes-stdin` with a generator that died
  # printed "updated successfully", exited 0, and left the issue's write-up erased.
  describe ".notes_content_error" do
    it "says nothing when no notes source was given" do
      Gori::CLI::Run.notes_content_error([] of String, nil, update).should be_nil
      # …and never mistakes "no source" for "an empty one" just because the body came back nil.
      Gori::CLI::Run.notes_content_error([] of String, "", update).should be_nil
    end

    it "accepts a body with bytes in it, from any source" do
      Gori::CLI::Run.notes_content_error(["--notes"], "typed", create).should be_nil
      Gori::CLI::Run.notes_content_error(["--notes-file"], "from a file", create).should be_nil
      Gori::CLI::Run.notes_content_error(["--notes-stdin"], "piped", update).should be_nil
    end

    # `--notes ''` is the operator typing the clear — the one spelling that has always meant it,
    # and the one the refusal below points at.
    it "lets an empty --notes through as the explicit clear it is" do
      Gori::CLI::Run.notes_content_error(["--notes"], "", update).should be_nil
    end

    it "refuses an empty file or pipe, naming the source and how to clear on purpose" do
      Gori::CLI::Run.notes_content_error(["--notes-file"], "", create)
        .should eq("gori run issues create: --notes-file gave no bytes — " \
                   "pass --notes '' to clear the notes")
      Gori::CLI::Run.notes_content_error(["--notes-stdin"], "", update)
        .should eq("gori run issues update: --notes-stdin gave no bytes — " \
                   "pass --notes '' to clear the notes")
    end

    # A body of one newline is a body: only a source that produced NOTHING is refused, so
    # `printf '\n' | … --notes-stdin` still writes.
    it "accepts whitespace — emptiness here is zero bytes, not blankness" do
      Gori::CLI::Run.notes_content_error(["--notes-stdin"], "\n", update).should be_nil
      Gori::CLI::Run.notes_content_error(["--notes-file"], " ", create).should be_nil
    end
  end

  # The issue's explicit requirement: "preserve multiline UTF-8 text byte-for-byte". Asserted
  # against the SAME content through the `--notes-file` door, and on BYTES — a `String`
  # comparison would pass on two strings holding different octets that scrub to the same thing.
  describe "byte fidelity" do
    it "preserves multiline UTF-8 through both the pipe and the file, identically" do
      body = "## 재현\n\n1. `/search?q=<svg onload=alert(1)>` 로 요청 — 반사됨\n2. 세션 쿠키 탈취\n\n— 끝 —\n"
      path = File.tempname("gori-notes", ".md")
      begin
        File.write(path, body)
        from_file = Gori::CLI::Run.notes_content(notes: nil, file: path, stdin: false,
          io: IO::Memory.new, what: create)
        piped = Gori::CLI::Run.notes_content(notes: nil, file: nil, stdin: true,
          io: IO::Memory.new(body), what: create)
        piped.not_nil!.to_slice.should eq(from_file.not_nil!.to_slice)
        piped.not_nil!.to_slice.should eq(body.to_slice)
      ensure
        File.delete?(path)
      end
    end

    it "preserves CRLF and a trailing blank line rather than trimming them" do
      body = "line one\r\nline two\r\n\r\n"
      Gori::CLI::Run.notes_content(notes: nil, file: nil, stdin: true,
        io: IO::Memory.new(body), what: create).not_nil!.to_slice.should eq(body.to_slice)
    end

    # Evidence pasted out of a capture is not always well-formed text (a latin-1 field, a byte
    # from a binary body). A scrub would rewrite each invalid octet to three, and the stored
    # note would no longer be what the operator saw.
    it "preserves bytes that are not valid UTF-8 — evidence is the payload (P7)" do
      bytes = "before ".to_slice + Bytes[0xff, 0xfe] + " after".to_slice
      read = Gori::CLI::Run.notes_content(notes: nil, file: nil, stdin: true,
        io: IO::Memory.new(bytes), what: create)
      read.not_nil!.to_slice.should eq(bytes)
      read.not_nil!.to_slice.size.should eq(bytes.size)
    end
  end

  # The point of the whole change: a create that lands the title AND the body in one write.
  # `insert_issue` wrote a literal `''` into the notes column, so a scripted create had to
  # follow with an update, and a peer reading between the two saw a bodiless issue.
  describe "Store#insert_issue notes" do
    it "files the notes with the issue, in the same insert" do
      with_store do |store|
        body = "## Impact\n\nSession takeover.\n"
        id = store.insert_issue("Reflected XSS", Gori::Store::Severity::High, "acme.test", nil,
          notes: body)
        id.should_not eq(0)
        store.get_issue(id).not_nil!.notes.should eq(body)
      end
    end

    it "still writes an empty body when no notes were given — the column's old default" do
      with_store do |store|
        id = store.insert_issue("No body", Gori::Store::Severity::Low, "acme.test", nil)
        store.get_issue(id).not_nil!.notes.should eq("")
      end
    end
  end
end
