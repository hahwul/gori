require "./spec_helper"
require "file_utils"

# `EnvMigration` — the re-spelling every project gets the first time it is opened after this
# install's token grammar moved.
#
# Two halves. The PURE one asserts WIRE EQUIVALENCE, not "the tokens look right": every REQUEST case
# is checked with `safe?`, which runs both texts through the two passes a real send takes (env vars
# at plan-build, bindings at the send seam) with a sentinel per name. A case that re-spells
# beautifully and ships different bytes is the failure this file exists to catch.
#
# The STORE one asserts the open-time path: the per-project marker, the backup, the one-line report,
# the columns it claims, the ones it must not touch — and that a second opener finds the work done
# rather than doing it again.
module Gori::EnvMigration
  # The inner marker re-check needs the two halves of `reconcile` apart, so a peer's commit can be
  # made to land between them. Private methods are callable from inside their own module, which is
  # what this wrapper is for.
  def self.apply_after_peer_for_spec(store : Store, db_path : String,
                                     project : String) : StoreReport?
    plan = Plan.new(project, stored_syntax(store), Settings.env_syntax,
      env_names(store), bind_names(store), Settings.env_prefix)
    scan(store, plan)
    # A second surface (a TUI beside an MCP server) commits the same migration while this one was
    # still scanning. Only the marker is written here; what matters is that the apply refuses.
    store.set_setting(MARKER_KEY, Settings.env_syntax.to_s.downcase)
    store.flush
    apply(plan, store, db_path)
  end
end

private ENV_NAMES  = ["id", "API", "both"]
private BIND_NAMES = ["token", "both"]

private def rewrite(text : String | Bytes, from : Gori::Env::Syntax, to : Gori::Env::Syntax,
                    kind : Gori::EnvMigration::Kind = Gori::EnvMigration::Kind::Request,
                    prefix : String = "$")
  bytes = text.is_a?(String) ? text.to_slice : text
  after, changes = Gori::EnvMigration.rewrite(bytes, from: from, to: to,
    env_names: ENV_NAMES, bind_names: BIND_NAMES, kind: kind, prefix: prefix)
  {after, changes}
end

# One case: the rewrite, and — for request text — the proof that the wire did not move.
private def expect_rewrite(text : String, from : Gori::Env::Syntax, to : Gori::Env::Syntax,
                           want : String,
                           kind : Gori::EnvMigration::Kind = Gori::EnvMigration::Kind::Request,
                           prefix : String = "$", wire_safe : Bool = true)
  after, _ = rewrite(text, from, to, kind, prefix)
  String.new(after).should eq(want)
  return unless kind.request?
  Gori::EnvMigration.safe?(text.to_slice, after, from: from, to: to,
    env_names: ENV_NAMES, bind_names: BIND_NAMES, prefix: prefix).should eq(wire_safe)
end

private BARE = Gori::Env::Syntax::Bare
private NS   = Gori::Env::Syntax::Namespaced

private def with_migration_home(&)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  dir = File.tempname("gori-env-migration")
  Dir.mkdir_p(File.join(dir, "projects", "demo"))
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    Gori::Settings.load
    yield File.join(dir, "projects", "demo", "gori.db")
  ensure
    Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    Gori::Settings.path_override = nil
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    Gori::Settings.load
    FileUtils.rm_rf(dir)
  end
end

# The project the store-level example migrates: one draft, one capture-backed tab, and every other
# column the migration claims. Returns the ids it has to assert against.
private def seed_migration_project(db_path : String) : {Int64, Int64, Int64, Int64}
  store = Gori::Store.open(db_path)
  begin
    store.set_setting(Gori::Env::PROJECT_VARS_KEY,
      Gori::Env.serialize_vars([{"id", "sekrit-value"}, {"API", "api.example.com"}]))
    store.insert_extract_rule("token", "", Gori::ExtractKind::Header, "set-cookie")
    store.set_setting(Gori::Store::SESSION_SLOTS_KEY,
      Gori::SessionSlot.serialize([Gori::SessionSlot.new("admin",
        [{"Authorization", "Bearer $token"}, {"X-Key", "$API"}], [] of String, false, ["token"])]))
    draft = "POST /q HTTP/1.1\r\nHost: $API\r\nX-A: $id\r\nX-B: $token\r\nX-C: $$id\r\n\r\n" \
            "{\"q\":\"$id $ne\"}"
    draft_id = store.insert_repeater("https://$API", draft.to_slice, false, true, nil, 0)
    evidence_id = store.insert_repeater("https://api.example.com",
      "GET /?$id HTTP/1.1\r\nHost: api.example.com\r\n\r\n".to_slice, false, true, 7_i64, 1)
    rule_id = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
      "Authorization", "Bearer $token-$1", name: "auth")
    issue_id = store.insert_issue("leaked $id", Gori::Store::Severity::High, nil, nil,
      notes: "the body carried $id")
    store.flush
    {draft_id, evidence_id, rule_id, issue_id}
  ensure
    store.close
  end
end

describe Gori::EnvMigration do
  describe "bare → namespaced" do
    it "routes a name by which table holds it, and leaves the rest as bytes" do
      # {text, expected} — one row per grammar fact, so a regression names the fact.
      {
        "X-A: $id"              => "X-A: $ENV.id",               # an env var
        "Authorization: $token" => "Authorization: $BIND.token", # a declared binding
        "$nope"                 => "$nope",                      # in neither table: a literal in both
        "{\"q\":\"$id $ne\"}"   => "{\"q\":\"$ENV.id $ne\"}",    # a Mongo operator beside a real token
        "$id$token"             => "$ENV.id$BIND.token",         # adjacency: two tokens, no separator
        "$A$id"                 => "$A$ENV.id",                  # an unknown name immediately before one
        "$idx"                  => "$idx",                       # a LONGER name is a different name
        "$id."                  => "$ENV.id.",                   # a dot right after the name
      }.each do |text, want|
        expect_rewrite(text, BARE, NS, want)
      end
    end

    it "routes a name held in BOTH tables to ENV, and says so" do
      after, changes = rewrite("$both", BARE, NS)
      String.new(after).should eq("$ENV.both")
      changes.size.should eq(1)
      changes[0].ambiguous.should be_true
      changes[0].ref.try(&.ns).should eq(Gori::Env::Namespace::Env)
    end

    it "drops the bare escape's second sigil, because the namespaced grammar does not consume it" do
      # bare `$$id` SHIPPED `$id`; namespaced `$$` is two literal bytes, so the same wire needs one.
      expect_rewrite("$$id", BARE, NS, "$id")
      expect_rewrite("$$", BARE, NS, "$")
      expect_rewrite("a$$b", BARE, NS, "a$b")
    end

    it "leaves a bare escape that is ALREADY the namespaced escape for the same bytes" do
      after, changes = rewrite("$$ENV.id", BARE, NS)
      String.new(after).should eq("$$ENV.id")
      changes.should be_empty
      # Both grammars ship `$ENV.id` from those bytes — which is the whole reason to leave them.
      Gori::EnvMigration.safe?("$$ENV.id".to_slice, after, from: BARE, to: NS,
        env_names: ENV_NAMES, bind_names: BIND_NAMES).should be_true
    end

    it "refuses to claim a wire it cannot spell" do
      # bare `$$$id` is a literal `$` followed by an INTERPRETED `$id`, and the namespaced grammar
      # has no spelling for a `$` directly in front of a token (`$$ENV.id` IS the escape). The
      # rewrite is reported as unsafe so the caller skips the row instead of shipping other bytes.
      expect_rewrite("$$$id", BARE, NS, "$$ENV.id", wire_safe: false)
    end

    it "keeps `$$` and `$1..$9` in a rule replacement, where the rule grammar owns them" do
      expect_rewrite("$token-$1", BARE, NS, "$BIND.token-$1", Gori::EnvMigration::Kind::Rule)
      expect_rewrite("$$1", BARE, NS, "$$1", Gori::EnvMigration::Kind::Rule)
      expect_rewrite("$$", BARE, NS, "$$", Gori::EnvMigration::Kind::Rule)
      expect_rewrite("$$id", BARE, NS, "$$id", Gori::EnvMigration::Kind::Rule)
      expect_rewrite("$id/$1", BARE, NS, "$ENV.id/$1", Gori::EnvMigration::Kind::Rule)
    end

    it "re-spells display text and leaves its `$$` alone — nothing expands it" do
      expect_rewrite("token was $id", BARE, NS, "token was $ENV.id", Gori::EnvMigration::Kind::Display)
      expect_rewrite("$$id", BARE, NS, "$$id", Gori::EnvMigration::Kind::Display)
    end

    it "follows a non-default sigil" do
      expect_rewrite("%id", BARE, NS, "%ENV.id", prefix: "%")
      expect_rewrite("%%id", BARE, NS, "%id", prefix: "%")
      expect_rewrite("$id", BARE, NS, "$id", prefix: "%")
    end

    it "preserves bytes that are not valid UTF-8" do
      raw = Bytes[0x24, 0x69, 0x64, 0xff, 0xfe, 0x24, 0x74, 0x6f, 0x6b, 0x65, 0x6e] # $id \xff\xfe $token
      after, changes = rewrite(raw, BARE, NS)
      changes.size.should eq(2)
      after.should eq(Bytes[0x24, 0x45, 0x4e, 0x56, 0x2e, 0x69, 0x64, 0xff, 0xfe,
        0x24, 0x42, 0x49, 0x4e, 0x44, 0x2e, 0x74, 0x6f, 0x6b, 0x65, 0x6e])
    end

    it "returns the same slice when there is nothing to re-spell" do
      raw = "GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_slice
      after, changes = rewrite(raw, BARE, NS)
      changes.should be_empty
      after.should be(raw)
    end

    it "reports each change with its offset and spelling" do
      _, changes = rewrite("a $id b $token", BARE, NS)
      changes.map { |c| {c.at, c.before, c.after} }.should eq([
        {2, "$id", "$ENV.id"}, {8, "$token", "$BIND.token"},
      ])
    end
  end

  describe "namespaced → bare" do
    it "strips the namespace from both tables" do
      expect_rewrite("$ENV.id", NS, BARE, "$id")
      expect_rewrite("$BIND.token", NS, BARE, "$token")
      expect_rewrite("$ENV.id$BIND.token", NS, BARE, "$id$token")
    end

    it "escapes a literal the bare grammar WOULD resolve" do
      # The lossy direction's one obligation: these bytes were inert, and bare would substitute.
      expect_rewrite("$id", NS, BARE, "$$id")
      expect_rewrite("$token", NS, BARE, "$$token")
      expect_rewrite("$nope", NS, BARE, "$nope") # bare would not resolve it either
      expect_rewrite("{\"q\":\"$id\"}", NS, BARE, "{\"q\":\"$$id\"}")
    end

    it "doubles a sigil that bare would pair into an escape" do
      expect_rewrite("$$id", NS, BARE, "$$$$id")
      expect_rewrite("$$", NS, BARE, "$$$")
    end

    it "leaves a namespaced escape alone — bare ships the same bytes from it" do
      expect_rewrite("$$ENV.id", NS, BARE, "$$ENV.id")
      expect_rewrite("$$BIND.token", NS, BARE, "$$BIND.token")
    end

    it "escapes a resolvable name in a rule replacement, and never a backref" do
      expect_rewrite("$BIND.token-$1", NS, BARE, "$token-$1", Gori::EnvMigration::Kind::Rule)
      expect_rewrite("$id-$1", NS, BARE, "$$id-$1", Gori::EnvMigration::Kind::Rule)
      expect_rewrite("$1$2", NS, BARE, "$1$2", Gori::EnvMigration::Kind::Rule)
    end
  end

  it "does nothing when the two grammars are the same" do
    after, changes = rewrite("$id", BARE, BARE)
    changes.should be_empty
    after.should eq("$id".to_slice)
  end

  # ── the store half: the open-time reconcile ───────────────────────────────
  #
  # One project, every column the migration claims, and the two it must not touch.
  it "re-spells a bare-era database on open, marks it, backs it up, and leaves evidence alone" do
    with_migration_home do |db_path|
      draft_id, evidence_id, rule_id, issue_id = seed_migration_project(db_path)
      # This install reads namespaced; the database carries no marker, which is exactly true of its
      # bytes — it was written before namespaces existed.
      Gori::Settings.env_syntax = NS

      report = with_open_store(db_path) do |store|
        Gori::EnvMigration.stored_syntax(store).should eq(BARE)
        Gori::EnvMigration.reconcile(store, db_path, "demo")
      end.not_nil!

      report.from.should eq(BARE)
      report.to.should eq(NS)
      report.tokens.should be > 0
      line = report.line
      line.should start_with("project demo: ")
      line.should contain("re-spelled to $ENV.KEY/$BIND.NAME")
      line.should contain("backup at ")

      backups = Dir.glob("#{db_path}.pre-namespaced-*")
      backups.size.should eq(1)
      File.size(backups[0]).should be > 0
      report.backup.should eq(backups[0])

      with_open_store(db_path) do |store|
        rec = store.get_repeater(draft_id).not_nil!
        wire = String.new(rec.request)
        wire.should contain("Host: $ENV.API\r\n")
        wire.should contain("X-A: $ENV.id\r\n")
        wire.should contain("X-B: $BIND.token\r\n")
        wire.should contain("X-C: $id\r\n")            # the bare escape lost its second sigil
        wire.should contain("{\"q\":\"$ENV.id $ne\"}") # and `$ne` is still `$ne`
        rec.target.should eq("https://$ENV.API")

        # EVIDENCE: byte-identical. A capture expands nothing, so its `$id` is a byte the origin
        # sent and re-spelling it would edit the record to no effect on any wire.
        String.new(store.get_repeater(evidence_id).not_nil!.request).should contain("GET /?$id ")

        store.match_rules.find { |r| r.id == rule_id }.not_nil!
          .replacement.should eq("Bearer $BIND.token-$1")

        slots = Gori::SessionSlot.parse_json(store.setting(Gori::Store::SESSION_SLOTS_KEY))
        slots[0].set_headers.should eq([{"Authorization", "Bearer $BIND.token"}, {"X-Key", "$ENV.API"}])
        slots[0].rules.should eq(["token"]) # a claimed rule NAME is a table key, not a token

        issue = store.issues.find { |i| i.id == issue_id }.not_nil!
        issue.title.should eq("leaked $ENV.id")
        issue.notes.should eq("the body carried $ENV.id")

        # The var NAMES are keys, not tokens — untouched, or the table stops matching.
        Gori::Env.parse_vars_json(store.setting(Gori::Env::PROJECT_VARS_KEY))
          .should eq([{"id", "sekrit-value"}, {"API", "api.example.com"}])
        store.extract_rules.map(&.name).should eq(["token"])

        # THE MARKER, in the project's own settings KV beside `env.vars`. This is what makes the
        # next open a no-op — and what a `bare` opt-out later reads to know which way to go.
        store.setting(Gori::Env::PROJECT_SYNTAX_KEY).should eq("namespaced")
        Gori::EnvMigration.stored_syntax(store).should eq(NS)

        # …and the ACTIVITY feed carries it, because "what happened to this project" is the question
        # that feed exists to answer.
        store.events_recent(20).rows.map(&.message).any?(&.includes?("re-spelled")).should be_true
      end
    end
  end

  it "is a no-op on the next open: no second backup, no second line" do
    with_migration_home do |db_path|
      seed_migration_project(db_path)
      Gori::Settings.env_syntax = NS
      with_open_store(db_path) { |store| Gori::EnvMigration.reconcile(store, db_path, "demo") }
      before = with_open_store(db_path) { |store| String.new(store.repeaters[0].request) }

      with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo").should be_nil
      end
      Dir.glob("#{db_path}.pre-namespaced-*").size.should eq(1)
      with_open_store(db_path) { |store| String.new(store.repeaters[0].request) }.should eq(before)
    end
  end

  # Two surfaces open one project all the time (a TUI beside a `gori mcp` server). The marker is
  # re-read INSIDE the write transaction, so the loser of that race writes nothing — and deletes the
  # backup it had already taken, which describes a state nobody changed.
  it "refuses to apply when a peer opener committed the same migration first" do
    with_migration_home do |db_path|
      seed_migration_project(db_path)
      Gori::Settings.env_syntax = NS
      with_open_store(db_path) do |store|
        Gori::EnvMigration.apply_after_peer_for_spec(store, db_path, "demo").should be_nil
      end
      Dir.glob("#{db_path}.pre-namespaced-*").should be_empty
    end
  end

  # A FRESH database has nothing to re-spell. It still gets the marker — so the next grammar move
  # knows which way to go — and no backup, because no row changed.
  it "marks an empty database without backing anything up" do
    with_migration_home do |db_path|
      with_open_store(db_path, &.flush)
      Gori::Settings.env_syntax = NS
      report = with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo")
      end.not_nil!
      report.quiet?.should be_true
      report.notices.should be_empty # nothing to say, so no surface says anything
      report.backup.should be_nil
      Dir.glob("#{db_path}.pre-*").should be_empty
      with_open_store(db_path) { |s| s.setting(Gori::Env::PROJECT_SYNTAX_KEY) }.should eq("namespaced")
    end
  end

  # The opt-out direction, and the reason it is the lossy one: bare resolves a name by SHAPE, so a
  # `$id` that was inert under the namespaced grammar starts resolving. Every one gori can see gets
  # its escape.
  it "reverses on a bare opt-out, escaping a literal that would start resolving" do
    with_migration_home do |db_path|
      seed_migration_project(db_path)
      Gori::Settings.env_syntax = NS
      with_open_store(db_path) { |store| Gori::EnvMigration.reconcile(store, db_path, "demo") }

      # The operator opts out. The next open reads the marker (namespaced) against the install
      # (bare) and goes the other way.
      Gori::Settings.env_syntax = BARE
      report = with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo")
      end.not_nil!
      report.from.should eq(NS)
      report.to.should eq(BARE)
      report.line.should contain("re-spelled to $KEY/$NAME")

      with_open_store(db_path) do |store|
        wire = String.new(store.repeaters.find { |r| r.flow_id.nil? }.not_nil!.request)
        wire.should contain("X-A: $id\r\n")
        wire.should contain("X-B: $token\r\n")
        # The `$id` the forward pass left as one sigil is a REFERENCE to bare, so it has to be
        # escaped back or those four bytes stop being the payload.
        wire.should contain("X-C: $$id\r\n")
        store.setting(Gori::Env::PROJECT_SYNTAX_KEY).should eq("bare")
      end
      Dir.glob("#{db_path}.pre-bare-*").size.should eq(1)
    end
  end

  # A grammar gori had to GUESS may not rewrite anything: an unreadable settings.json, a
  # half-applied one, a typo where the value should be. The alternative is a permissions problem
  # re-spelling an operator's drafts.
  it "re-spells nothing when this install's grammar was not stated" do
    with_migration_home do |db_path|
      seed_migration_project(db_path)
      File.write(Gori::Settings.path, %({"env":{"syntax":"NAMESPACED!"}}))
      Gori::Settings.reset_load_warning_guard
      Gori::Settings.load
      Gori::Settings.env_syntax_stated?.should be_false
      with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo").should be_nil
        String.new(store.repeaters[0].request).should contain("X-A: $id\r\n")
        store.setting(Gori::Env::PROJECT_SYNTAX_KEY).should be_nil
      end
    end
  end

  # The GLOBAL rewrite rules travel with the project open, not just with the settings load: a global
  # rule can name an EXTRACT RULE, and no settings load knows those names — only an open project
  # does.
  it "re-spells a global rule against the project's own binding names" do
    with_migration_home do |db_path|
      seed_migration_project(db_path)
      Gori::Settings.env_syntax = NS
      Gori::Settings.rewriter_rules = [Gori::Settings::RewriterRule.new(
        1_i64, true, "auth", "request", "head", "Authorization", "Bearer $token",
        "replace", "literal", "", "")]
      report = with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo")
      end.not_nil!
      global = report.global.not_nil!
      global.tokens.should eq(1)
      Gori::Settings.rewriter_rules[0].replacement.should eq("Bearer $BIND.token")
      report.notices.size.should eq(2) # the project line, then the global one
      report.notices[1].should contain("global rewrite rules: 1 token re-spelled")
    ensure
      Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    end
  end
end

# One handle, closed exactly once — `Store#close` is not idempotent.
private def with_open_store(db_path : String, &)
  store = Gori::Store.open(db_path)
  begin
    yield store
  ensure
    store.close
  end
end
