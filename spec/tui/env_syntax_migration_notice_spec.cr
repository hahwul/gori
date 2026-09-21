require "../spec_helper"

# The open-time token-grammar re-spelling, as the OPERATOR hears about it (#env.syntax).
#
# Nothing asks: a project whose stored tokens are spelled in the grammar this install has left is
# re-spelled the first time it opens, and every surface then REPORTS it. The wording is one builder
# (`EnvMigration::StoreReport#line`) so the three surfaces cannot drift into describing the same
# event differently, and the wirings that carry it are pinned by grep — a `Runner` is not
# constructible from a spec, which is exactly how a dead announcement would ship.
private def notice_src(*parts : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", *parts)).lines
    .reject(&.lstrip.starts_with?('#')).join('\n')
end

private def store_report(tokens : Int32 = 3, rows : Int32 = 2, left : Int32 = 0,
                         backup : String? = "/h/projects/acme/gori.db.pre-namespaced-20260913-101500",
                         to : Gori::Env::Syntax = Gori::Env::Syntax::Namespaced,
                         global_hint : String? = nil,
                         error : String? = nil) : Gori::EnvMigration::StoreReport
  from = to.bare? ? Gori::Env::Syntax::Namespaced : Gori::Env::Syntax::Bare
  Gori::EnvMigration::StoreReport.new("acme", from, to, tokens, rows, left, backup,
    global_hint: global_hint, error: error)
end

describe "env.syntax migration notice" do
  it "names the project, the count, the new spelling and the way back" do
    line = store_report.line
    line.should eq("project acme: 3 tokens re-spelled to $ENV.KEY/$BIND.NAME in 2 rows — " \
                   "backup at /h/projects/acme/gori.db.pre-namespaced-20260913-101500")
  end

  it "spells the TARGET grammar, so the opt-out direction reads correctly too" do
    store_report(to: Gori::Env::Syntax::Bare, backup: nil).line
      .should eq("project acme: 3 tokens re-spelled to $KEY/$NAME in 2 rows")
  end

  # A row whose bytes have no equivalent spelling is LEFT and said out loud. Silence there would be
  # the one outcome an operator cannot act on: a draft that still sends what it always sent, under a
  # grammar that no longer reads it that way.
  it "names the rows it could not move without changing the wire" do
    store_report(left: 1).line.should contain("1 row left as authored (no namespaced spelling sends the same bytes)")
  end

  # A fresh project has nothing to re-spell: it takes the marker and says NOTHING, because a line
  # about zero tokens is the kind of notice that teaches operators to ignore notices.
  it "is silent when nothing moved" do
    quiet = store_report(tokens: 0, rows: 0, backup: nil)
    quiet.quiet?.should be_true
    quiet.notices.should be_empty
  end

  # The global rewrite rules are the half a project open can only NAME: they live in settings.json,
  # and nothing records which grammar they are spelled in, so re-spelling them from a project open
  # would not be idempotent. The line rides along with the project's.
  it "carries the global-rule hint as part of the same event" do
    lines = store_report(global_hint: "global rewrite rules: 1 rule (stamp) still spell a token").notices
    lines.size.should eq(2)
    lines[1].should contain("still spell a token")
  end

  # …and a project with nothing to re-spell still says the hint, because the rule is broken whether
  # or not this database had a token in it.
  it "says the hint even when no row moved" do
    quiet = store_report(tokens: 0, rows: 0, backup: nil, global_hint: "global rewrite rules: …")
    quiet.quiet?.should be_false
    quiet.notices.should eq(["global rewrite rules: …"])
  end

  # A failure must not be silent either: until it succeeds, the operator's drafts are spelled in a
  # grammar this install does not read, and their next send goes out as literal text.
  it "says what a failed re-spelling leaves behind" do
    line = store_report(error: "database is locked").line
    line.should contain("could not re-spell")
    line.should contain("database is locked")
    line.should contain("literal text")
  end

  # ── the wirings ───────────────────────────────────────────────────────────

  it "reconciles at the project open of every surface, before anything reads a token" do
    # ONE seam per surface, and each one runs BEFORE the rule sets / slots / binding table / project
    # env layer are read out of the store: those objects are what the session SENDS with, so a
    # re-spelling after they loaded would leave a live session on the old spelling.
    session = notice_src("gori", "session.cr")
    session.should contain("EnvMigration.reconcile(store, project.db_path, project.name)")
    session.index("EnvMigration.reconcile").not_nil!
      .should be < session.index("Env.load_project(store)").not_nil!
    session.should contain("session.env_syntax_migration = syntax_migration")

    # The headless CLI: every `gori run` subcommand funnels through `open_store`, read-only ones
    # included — the re-spelling writes through its own connection.
    run = notice_src("gori", "cli", "run.cr")
    # Scoped to `open_store`'s own body: the file has a second `Store.open` and a bare
    # `busy_timeout_ms:` anywhere in it satisfied the old whole-file `contain`. The reconcile
    # must ride the SAME budget the open beside it was given — a one-shot open with a
    # five-second re-spelling would wait longer on the migration than on the project.
    open_store = run[/private def self\.open_store\(.*?\n      rescue ex/m].not_nil!
    open_store.should contain("report_env_syntax_migration(EnvMigration.reconcile(store, project.db_path, project.name,")
    open_store.scan(/busy_timeout_ms: busy_ms\b/).size.should eq(2)

    # MCP binds a project at TWO sites — the constructor and `bind_project` (switch_project, an
    # auto-binding create_project) — so both ask, through one helper.
    tools = notice_src("gori", "mcp", "tools.cr")
    tools.should contain("reconcile_env_syntax(s)")
    tools[/def reconcile_env_syntax.*?\n      end/m].not_nil!.should contain("Log.info")
    notice_src("gori", "mcp", "tools", "projects.cr").should contain("reconcile_env_syntax(new_store)")
  end

  it "announces it in the TUI on the ring AND the toast, at :warn" do
    # `:info` takes neither the bell nor the toast (`Notifications#push`), and the bytes in this
    # operator's Repeater tabs just changed. The toast yields to a bind failure already on screen —
    # capture being off is the more urgent of the two — but the ring keeps both.
    runner = notice_src("gori", "tui", "runner.cr")
    runner.should contain("announce_env_syntax_migration")
    body = runner[/def announce_env_syntax_migration.*?\n    end/m].not_nil!
    body.should contain("@session.env_syntax_migration")
    body.should contain("take_env_syntax_global_migration")
    body.should contain("@notifications.push(:warn")
    body.should contain("@toast ||=")
  end

  it "says the same thing on the headless capture, which has no ring" do
    # One builder, two emitters: `gori run capture` binds logging to STDERR, so the same sentence
    # reaches the operator there instead of a hand-written copy that could drift.
    app = notice_src("gori", "app.cr")
    app.should contain("session.env_syntax_migration.try(&.notices.each { |line| Log.info { line } })")
    app.should contain("Settings.take_env_syntax_global_migration")
  end

  it "writes the ACTIVITY row at the migration itself, on its OWN connection" do
    # "What happened to this project" is the feed's question, and the answer must not depend on
    # which surface opened it — the CLI has no ring to push to at all. Written on the migration's
    # own connection, inside the same transaction: the caller's handle is read-only on every
    # read-only `gori run`, and an event written through THAT is dropped without a word.
    store = notice_src("gori", "env_migration", "store.cr")
    store.should contain("log_migration(conn, report) unless report.quiet?")
    store[/def self.log_migration.*?\n    end/m].not_nil!.should contain("INSERT INTO events")
  end
end
