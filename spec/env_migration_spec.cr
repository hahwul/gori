require "./spec_helper"
require "file_utils"

# `EnvMigration` — the pure re-spelling behind `gori settings env-syntax … --migrate`.
#
# The contract asserted here is WIRE EQUIVALENCE, not "the tokens look right": every REQUEST case
# is checked with `safe?`, which runs both texts through the two passes a real send takes (env vars
# at plan-build, bindings at the send seam) with a sentinel per name. A case that re-spells
# beautifully and ships different bytes is the failure this file exists to catch.
module Gori::CLI
  # The store-level half needs the orchestration, whose guards end in `abort`; these are the
  # drivable pieces. Named apart from spec/cli/settings_env_syntax_spec.cr's wrappers so neither
  # file depends on the other's load order.
  def self.migrate_env_syntax_for_migration_spec(to : Gori::Env::Syntax, *, dry : Bool,
                                                 db_path : String, io : IO) : Bool
    migrate_env_syntax(to, dry: dry, project_name: nil, db_path: db_path, all: false,
      io: io, warn_io: nil)
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

  # ── the store half ────────────────────────────────────────────────────────
  #
  # One project, every column the migration claims, and the two it must not touch.
  it "migrates a project database and leaves evidence alone" do
    with_migration_home do |db_path|
      draft_id = 0_i64
      evidence_id = 0_i64
      rule_id = 0_i64
      issue_id = 0_i64
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
      ensure
        store.close
      end

      io = IO::Memory.new
      Gori::CLI.migrate_env_syntax_for_migration_spec(NS, dry: true, db_path: db_path, io: io).should be_false
      dry = io.to_s
      dry.should contain("would re-spell")
      dry.should contain("$id → $ENV.id")
      dry.should contain("$token → $BIND.token")
      dry.should contain("--dry-run wrote nothing")
      # The evidence row is named, not rewritten.
      dry.should contain("evidence (flow 7)")

      # …and the dry run wrote nothing.
      store = Gori::Store.open(db_path)
      begin
        String.new(store.get_repeater(draft_id).not_nil!.request).should contain("X-A: $id\r\n")
      ensure
        store.close
      end

      io = IO::Memory.new
      Gori::CLI.migrate_env_syntax_for_migration_spec(NS, dry: false, db_path: db_path, io: io).should be_true
      real = io.to_s
      real.should contain("re-spelled")
      real.should contain("backup at ")

      backups = Dir.glob("#{db_path}.pre-namespaced-*")
      backups.size.should eq(1)
      File.size(backups[0]).should be > 0

      store = Gori::Store.open(db_path)
      begin
        rec = store.get_repeater(draft_id).not_nil!
        wire = String.new(rec.request)
        wire.should contain("Host: $ENV.API\r\n")
        wire.should contain("X-A: $ENV.id\r\n")
        wire.should contain("X-B: $BIND.token\r\n")
        wire.should contain("X-C: $id\r\n")            # the bare escape lost its second sigil
        wire.should contain("{\"q\":\"$ENV.id $ne\"}") # and `$ne` is still `$ne`
        rec.target.should eq("https://$ENV.API")

        # EVIDENCE: byte-identical.
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
      ensure
        store.close
      end

      # The grammar itself is the VERB's job (the migration runs first, then the switch), so the
      # spec drives that half the way the verb does.
      Gori::Settings.env_syntax = NS
      Gori::Settings.save.should be_true
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(NS)
    end
  end
end
