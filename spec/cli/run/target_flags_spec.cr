require "../../spec_helper"
require "file_utils"

# Which database a `gori run` command actually opens, when the argv answers that twice.
#
# `--db PATH` and `--project NAME` are the same question — WHICH project — and `--db` used to
# win in silence. So `gori run history --db "$DB" --project "$PROJ"` read `$DB` and exited 0
# with a `$PROJ` that need not have existed at all: never resolved, never checked, never
# mentioned. On a read that only misleads. `history delete -q … --yes`, `history clear --yes`
# and `project delete` take the SAME pair, and there the invisible winner decides which
# project gets emptied.
#
# The sentence is asserted rather than the abort, for the reason `colormarker_rule_row` and
# `view_row` are public: `refuse_two_targets` ends in `abort`, and a spec cannot drive a call
# that exits the process.
describe "gori run — --db and --project are one question, not two" do
  it "refuses the pair rather than picking a winner" do
    msg = Gori::CLI::Run.two_targets_error("acme", "/tmp/x.db")
    msg.should_not be_nil
    msg.not_nil!.should contain("not both")
    # It names the flag that would have LOST, because that is the one the operator will be
    # surprised about — the whole defect is that --project went unread.
    msg.not_nil!.should contain(%("acme"))
  end

  it "carries the subcommand's own prefix, so capture's error reads like capture's" do
    Gori::CLI::Run.two_targets_error("acme", "/tmp/x.db", "gori run capture")
      .not_nil!.should start_with("gori run capture:")
  end

  it "stays out of the way when only one names the target" do
    Gori::CLI::Run.two_targets_error("acme", nil).should be_nil
    Gori::CLI::Run.two_targets_error(nil, "/tmp/x.db").should be_nil
    Gori::CLI::Run.two_targets_error(nil, nil).should be_nil
  end

  # `--project=` / `--db=` with nothing after the `=` reach the resolvers as "". An empty
  # string is not a second answer to the question, so it must not start being refused as one:
  # `presence` here leaves the pre-existing precedence (--db first) to handle the pair exactly
  # as it always did, rather than turning a combination that worked into an abort.
  it "treats an empty flag value as unset, so no working argv starts failing" do
    Gori::CLI::Run.two_targets_error("", "/tmp/x.db").should be_nil
    Gori::CLI::Run.two_targets_error("acme", "").should be_nil
  end
end

# What a failed `open_store` says, when the failure is not what the wrapper implies.
#
# A write subcommand opens for write and `Store.open` migrates, so a peer holding the write
# lock (a TUI, a `gori run capture`, an MCP server) fails the open after `busy_timeout=5000`
# with SQLite's bare "database is locked" — printed under "cannot open database <path>".
# That reads as a corrupt or unreadable FILE, and it is the opposite: the file is fine and the
# condition clears on its own. Reproduced against a peer holding `BEGIN IMMEDIATE`.
describe "gori run — what a refused open blames" do
  it "names a peer's write lock as transient, not the file as bad" do
    hint = Gori::CLI::Run.open_failure_hint(Exception.new("database is locked"))
    hint.should contain("another gori")
    hint.should contain("retry")
  end

  it "covers the table-lock spelling SQLite also uses" do
    Gori::CLI::Run.open_failure_hint(Exception.new("database table is locked"))
      .should contain("another gori")
  end

  it "tells a read-only file from a broken one, when SQLite says so" do
    hint = Gori::CLI::Run.open_failure_hint(Exception.new("attempt to write a readonly database"))
    hint.should contain("not writable")
    hint.should_not contain("another gori")
  end

  # …and when it does NOT say so, which is the case that actually reaches an operator.
  # crystal-sqlite3 rescues everything `sqlite3_open_v2` and the pragmas raise and re-raises a
  # bare `DB::ConnectionRefused` — no message, no cause — so a write against a read-only file
  # arrived here as an empty message and was told "not a valid SQLite database (or unreadable)"
  # about a database it could still read perfectly well. Reproduced on the binary with mode
  # 0444; the message-matching branch above can never fire on that path.
  it "asks the filesystem when the driver threw the reason away" do
    next unless permissions_enforced?
    with_tempdir do |dir|
      db = File.join(dir, "gori.db")
      File.write(db, "x")
      File.chmod(db, 0o444)
      Gori::CLI::Run.open_failure_hint(DB::ConnectionRefused.new, db, false)
        .should contain("not writable")
    end
  end

  # SQLite writes `-wal` and `-shm` BESIDE the file, so a writable database in a read-only
  # directory fails exactly the same way and has to be named the same way.
  it "counts the directory, because WAL needs it" do
    next unless permissions_enforced?
    with_tempdir do |dir|
      db = File.join(dir, "gori.db")
      File.write(db, "x")
      File.chmod(dir, 0o555)
      begin
        Gori::CLI::Run.open_failure_hint(DB::ConnectionRefused.new, db, false)
          .should contain("not writable")
      ensure
        File.chmod(dir, 0o755)
      end
    end
  end

  # A read-only open is ALLOWED to be on a non-writable FILE — that is the whole point of
  # `read_only: true`, and #752 is why the read commands use it. Verified on the binary: a
  # 0444 database in a writable directory lists its flows fine. So a failure there is not
  # about permissions and must not be blamed on them.
  it "does not blame the file's own mode for a read-only open" do
    with_tempdir do |dir|
      db = File.join(dir, "gori.db")
      File.write(db, "x")
      File.chmod(db, 0o444)
      Gori::CLI::Run.open_failure_hint(DB::ConnectionRefused.new, db, true).should eq("")
    end
  end

  # …but a read-only DIRECTORY defeats a read too, and that is the case an operator actually
  # meets: an archived engagement, or a colleague's project on a read-only mount. WAL keeps
  # `-shm`/`-wal` beside the file, so SQLite must create them there even to read. `gori run
  # history --db …` on one answered "not a valid SQLite database (or unreadable)" about a
  # database that is both — the single most misleading thing this surface could say.
  it "names the directory when even a READ needs it" do
    next unless permissions_enforced?
    with_tempdir do |dir|
      db = File.join(dir, "gori.db")
      File.write(db, "x")
      File.chmod(dir, 0o555)
      begin
        hint = Gori::CLI::Run.open_failure_hint(DB::ConnectionRefused.new, db, true)
        hint.should contain("DIRECTORY")
        hint.should contain("READ")
      ensure
        File.chmod(dir, 0o755)
      end
    end
  end

  # Everything else keeps the wording it had — a genuinely unreadable or non-SQLite file must
  # still land on "not a valid SQLite database", with nothing appended to soften it.
  it "adds nothing to a failure it cannot explain" do
    with_tempdir do |dir|
      db = File.join(dir, "gori.db")
      File.write(db, "not a database")
      Gori::CLI::Run.open_failure_hint(Exception.new("file is not a database"), db, false).should eq("")
      Gori::CLI::Run.open_failure_hint(Exception.new(nil), db, false).should eq("")
    end
    # …including when there is no path to interrogate at all.
    Gori::CLI::Run.open_failure_hint(Exception.new(nil)).should eq("")
    Gori::CLI::Run.open_failure_hint(Exception.new(nil), "/nonexistent/gori.db", false).should eq("")
  end
end

# `File::Info.writable?` is `access(2)` against the REAL uid, and uid 0 gets W_OK on a 0444
# file and a 0555 directory. So under root — any plain `docker run … crystal spec`, which is
# how this repo's release container builds — the four permission examples below would fail on
# a hint that is behaving exactly as designed. Ask the filesystem instead of guessing the uid:
# it also covers a mount that ignores modes. (The same blindness means the hint never fires for
# a root operator in production, which is a limitation of `access(2)`, not of the branch.)
private def permissions_enforced? : Bool
  dir = File.tempname("gori-permcheck")
  Dir.mkdir_p(dir)
  begin
    probe = File.join(dir, "probe")
    File.write(probe, "x")
    File.chmod(probe, 0o444)
    !File::Info.writable?(probe)
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def with_tempdir(&)
  dir = File.tempname("gori-openhint")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    File.chmod(dir, 0o755) rescue nil
    FileUtils.rm_rf(dir)
  end
end
