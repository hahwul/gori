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
      env_names(store), bind_names(store), enabled_bind_names(store), Settings.env_prefix)
    scan(store, plan)
    # A second surface (a TUI beside an MCP server) commits the same migration while this one was
    # still scanning. Only the marker is written here; what matters is that the apply refuses.
    store.set_setting(MARKER_KEY, Settings.env_syntax.to_s.downcase)
    store.flush
    apply(plan, db_path)
  end
end

private ENV_NAMES  = ["id", "API", "both"]
private BIND_NAMES = ["token", "both"]

private def rewrite(text : String | Bytes, from : Gori::Env::Syntax, to : Gori::Env::Syntax,
                    kind : Gori::EnvMigration::Kind = Gori::EnvMigration::Kind::Request,
                    prefix : String = "$", hints : Array(String)? = nil,
                    enabled : Array(String)? = nil)
  bytes = text.is_a?(String) ? text.to_slice : text
  after, changes = Gori::EnvMigration.rewrite(bytes, from: from, to: to,
    env_names: ENV_NAMES, bind_names: BIND_NAMES, enabled_bind_names: enabled, kind: kind,
    prefix: prefix, hints: hints)
  {after, changes}
end

# One case: the rewrite, and — for request text — the proof that the wire did not move.
private def expect_rewrite(text : String, from : Gori::Env::Syntax, to : Gori::Env::Syntax,
                           want : String,
                           kind : Gori::EnvMigration::Kind = Gori::EnvMigration::Kind::Request,
                           prefix : String = "$", wire_safe : Bool = true)
  after, _ = rewrite(text, from, to, kind, prefix)
  String.new(after).should eq(want)
  return unless kind.has_wire?
  Gori::EnvMigration.safe?(text.to_slice, after, from: from, to: to,
    env_names: ENV_NAMES, bind_names: BIND_NAMES, kind: kind, prefix: prefix).should eq(wire_safe)
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

    # The bare grammar resolved a name by SHAPE, and the consumers of those bytes did not run the
    # same passes in the same order. So "which namespace did this `$NAME` mean?" is the CONSUMER's
    # question, and a house rule ("ENV first") answered it wrong for two of the four kinds: the
    # failure is silent, because both spellings look right and only the wire carries the other
    # value.
    it "routes a name held in BOTH tables by the CONSUMER, not by a house rule" do
      {
        # a request: the ENV pass runs at plan-build, the binding pass at the seam — ENV ran first
        Gori::EnvMigration::Kind::Request => "$ENV.both",
        # display text: nothing expands it, so it follows the request spelling for consistency
        Gori::EnvMigration::Kind::Display => "$ENV.both",
        # a rule replacement: `Rules#substitute` resolves against `Env.display_vars`, which layers
        # the BINDING values OVER the env vars — so the binding is what a bare rule injected
        Gori::EnvMigration::Kind::Rule => "$BIND.both",
        # a slot header value: `Env.expand_bindings_as` and nothing else, so BIND is all there is
        Gori::EnvMigration::Kind::Slot => "$BIND.both",
        # a dial tuple: one `Env.expand` with `resolve: Owns::Env`, so ENV is all there is
        Gori::EnvMigration::Kind::Dial => "$ENV.both",
      }.each do |kind, want|
        after, changes = rewrite("$both", BARE, NS, kind)
        String.new(after).should eq(want)
        changes.size.should eq(1)
        # The AMBIGUITY only exists where two readings did: a slot and a dial resolve one table.
        changes[0].ambiguous.should eq(!(kind.slot? || kind.dial?))
      end
    end

    # The other half of the same fact, and the one an operator can actually be hurt by: a name the
    # consumer's own pass would NOT have resolved is not a token at all. Re-spelling it minted a
    # reference that looks live and resolves in no pass those bytes ever see.
    it "leaves a name the consumer's own pass never resolved as a bare literal" do
      # `$id` is an env var. A slot header is resolved by the binding seam alone, so it shipped as
      # four literal bytes before the switch and must ship the same four after.
      after, changes = rewrite("$id", BARE, NS, Gori::EnvMigration::Kind::Slot)
      changes.should be_empty
      String.new(after).should eq("$id")
      # …and a declared binding in the same header IS a token.
      expect_rewrite("$token", BARE, NS, "$BIND.token", Gori::EnvMigration::Kind::Slot)
      # A dial tuple is the mirror: `$token` resolves in no pass a target sees.
      after, changes = rewrite("$token", BARE, NS, Gori::EnvMigration::Kind::Dial)
      changes.should be_empty
      String.new(after).should eq("$token")
      expect_rewrite("https://$API/p", BARE, NS, "https://$ENV.API/p", Gori::EnvMigration::Kind::Dial)
    end

    # A DISABLED extract rule declares nothing and resolves nothing — both halves of the live
    # binding table filter on `enabled?`. So its name in a rule replacement was never a binding
    # reference, and routing it to BIND turned a rule that injected an ENV value into one that
    # injects its own spelling into live traffic, forever, with no refusal in front of it.
    it "routes a rule replacement by what bare's table actually held, disabled rules excluded" do
      # `both` is an env var AND an extract rule, but only `token` is ENABLED.
      after, changes = rewrite("X-K: $both", BARE, NS, Gori::EnvMigration::Kind::Rule,
        enabled: ["token"])
      String.new(after).should eq("X-K: $ENV.both")
      changes[0].ref.try(&.ns).should eq(Gori::Env::Namespace::Env)
      # …and no ambiguity to report: a disabled rule never offered the second reading.
      changes[0].ambiguous.should be_false
      # With the rule ENABLED it is the binding, exactly as `Env.display_vars` layered it.
      after, _ = rewrite("X-K: $both", BARE, NS, Gori::EnvMigration::Kind::Rule,
        enabled: ["token", "both"])
      String.new(after).should eq("X-K: $BIND.both")
    end

    # And a name that is ONLY a disabled binding is left UNSPELLED: bare shipped the literal too
    # (no value, not declared), so the wire is identical — and when the operator switches the rule
    # back on, `Rules#substitute`'s `BareSpelling` refusal names the re-spelling instead of
    # injecting the text.
    it "leaves a name that is only a DISABLED binding unspelled in a rule replacement" do
      after, changes = rewrite("Authorization: $token", BARE, NS,
        Gori::EnvMigration::Kind::Rule, enabled: [] of String)
      changes.should be_empty
      String.new(after).should eq("Authorization: $token")
    end

    # `safe?` now runs for a rule replacement, against `Rules#substitute`'s own grammar rather
    # than a borrowed pass list — which is what makes the routing above checkable at all.
    it "judges a rule replacement's wire against the rule grammar" do
      # `$$` is one sigil in BOTH syntaxes here, and `$1` is a backref on both sides.
      Gori::EnvMigration::Kind::Rule.has_wire?.should be_true
      expect_rewrite("$$x-$1-$both", BARE, NS, "$$x-$1-$BIND.both",
        Gori::EnvMigration::Kind::Rule)
      # Display text still has no wire to judge.
      Gori::EnvMigration::Kind::Display.has_wire?.should be_false
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

    # Only a grammar that CONSUMES an escape can spell one. Doubling the sigil in one that does not
    # just adds a byte — and for DISPLAY text that byte is visible: an issue title reading
    # `leaked $id` became `leaked $$id`, and a `$$` an operator typed became `$$$`.
    it "never escapes display text, which is expanded by nothing" do
      expect_rewrite("leaked $id", NS, BARE, "leaked $id", Gori::EnvMigration::Kind::Display)
      expect_rewrite("$$id", NS, BARE, "$$id", Gori::EnvMigration::Kind::Display)
      expect_rewrite("$$", NS, BARE, "$$", Gori::EnvMigration::Kind::Display)
      # The TOKEN still follows the grammar: `mask_secrets` put it there, and the redaction stops
      # reading as one if its spelling does not move.
      expect_rewrite("leaked $ENV.id", NS, BARE, "leaked $id", Gori::EnvMigration::Kind::Display)
    end

    # A DIAL tuple is expanded — once, by the env pass, with `Escape::Preserve` — and nothing ever
    # unescapes it. So `$$id` in a target reaches the resolver as `$$id`: there is no escaped
    # spelling to write, and writing one shipped a host nobody asked for.
    it "re-spells a dial tuple and NAMES the literal it cannot escape" do
      hints = [] of String
      after, changes = rewrite("https://$id/p", NS, BARE, Gori::EnvMigration::Kind::Dial,
        hints: hints)
      String.new(after).should eq("https://$id/p") # the bytes are left exactly as authored
      changes.should be_empty
      hints.should eq(["$id"]) # …and the operator is told they will now be substituted
      # A token re-spells as usual, and earns no hint: it resolved before and resolves after.
      hints.clear
      expect_rewrite("https://$ENV.API", NS, BARE, "https://$API", Gori::EnvMigration::Kind::Dial)
      rewrite("https://$ENV.API", NS, BARE, Gori::EnvMigration::Kind::Dial, hints: hints)
      hints.should be_empty
      # And a `$$` stays two bytes, because that is what it already was in both grammars.
      expect_rewrite("https://$$API", NS, BARE, "https://$$API", Gori::EnvMigration::Kind::Dial)
    end

    # A slot header value resolves BIND alone, in both grammars. So the escape is owed to a declared
    # binding and to nothing else: an env-only name was literal text before and after.
    it "escapes only a BINDING in a slot header value" do
      expect_rewrite("Bearer $BIND.token", NS, BARE, "Bearer $token", Gori::EnvMigration::Kind::Slot)
      expect_rewrite("Bearer $token", NS, BARE, "Bearer $$token", Gori::EnvMigration::Kind::Slot)
      expect_rewrite("$id", NS, BARE, "$id", Gori::EnvMigration::Kind::Slot)
    end

    # The round trip the two rules above buy: text that is not expanded, and a target whose escape
    # cannot move, come back byte-for-byte.
    it "round-trips display text and a target namespaced → bare → namespaced" do
      {
        Gori::EnvMigration::Kind::Display => "leaked $ENV.id / $BIND.token / $$id / $$ / $nope",
        Gori::EnvMigration::Kind::Dial    => "https://$ENV.API:8443/$$API",
      }.each do |kind, original|
        down, _ = rewrite(original, NS, BARE, kind)
        up, _ = rewrite(down, BARE, NS, kind)
        String.new(up).should eq(original)
      end
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
        # `Kind::Slot`: `Env.expand_bindings_as` is the ONLY pass over a slot header value and it
        # resolves BIND alone, so the declared binding is re-spelled and the env var name is NOT —
        # it shipped as literal text before the switch and it ships the same literal text after.
        slots[0].set_headers.should eq([{"Authorization", "Bearer $BIND.token"}, {"X-Key", "$API"}])
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

  # The store half of the disabled-binding routing. A rule replacement naming a DISABLED extract
  # rule that is also an env var used to come out `$BIND.id` — a spelling that resolves in no table,
  # so the rule stopped injecting the env value and started injecting those bytes into live traffic.
  it "re-spells a rule replacement against the ENABLED bindings only" do
    with_migration_home do |db_path|
      store = Gori::Store.open(db_path)
      begin
        store.set_setting(Gori::Env::PROJECT_VARS_KEY,
          Gori::Env.serialize_vars([{"id", "v"}, {"only", "w"}]))
        # `id` is BOTH an env var and an extract rule — switched OFF. `only` is an env var whose
        # name no rule carries.
        rid = store.insert_extract_rule("id", "", Gori::ExtractKind::Header, "set-cookie")
        store.set_extract_rule_enabled(rid, false)
        store.insert_extract_rule("live", "", Gori::ExtractKind::Header, "set-cookie")
        both = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "X-K", "$id/$only/$live", name: "r")
        store.flush
        Gori::EnvMigration.enabled_bind_names(store).should eq(Set{"live"})
        Gori::EnvMigration.bind_names(store).should eq(Set{"id", "live"})
      ensure
        store.close
      end
      Gori::Settings.env_syntax = NS
      with_open_store(db_path) { |st| Gori::EnvMigration.reconcile(st, db_path, "demo") }
      with_open_store(db_path) do |st|
        # `$id` → ENV (the value bare's merged table actually held), `$only` → ENV, `$live` → BIND.
        st.match_rules[0].replacement.should eq("$ENV.id/$ENV.only/$BIND.live")
      end
    end
  end

  # And a name that is ONLY a disabled binding is left exactly as authored — the literal bare
  # shipped for it too.
  it "leaves a rule replacement naming only a DISABLED binding as authored" do
    with_migration_home do |db_path|
      store = Gori::Store.open(db_path)
      begin
        rid = store.insert_extract_rule("off", "", Gori::ExtractKind::Header, "set-cookie")
        store.set_extract_rule_enabled(rid, false)
        store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "Authorization", "Bearer $off", name: "r")
        store.flush
      ensure
        store.close
      end
      Gori::Settings.env_syntax = NS
      with_open_store(db_path) { |st| Gori::EnvMigration.reconcile(st, db_path, "demo") }
      with_open_store(db_path) do |st|
        st.match_rules[0].replacement.should eq("Bearer $off")
        # A SLOT header, by contrast, counts the declared name whether or not its rule is on: it is
        # a reference by construction, and `$BIND.off` keeps working when the rule comes back.
        Gori::EnvMigration.stored_syntax(st).should eq(NS)
      end
    end
  end

  # The commonest first open of all is a READ-ONLY one (`gori run history list`, `repeater list`).
  # The re-spelling writes through its own connection, so it happens there too — and so does the
  # feed row, which used to be written through the caller's handle and silently dropped.
  it "migrates through a read-only handle, feed row included" do
    with_migration_home do |db_path|
      seed_migration_project(db_path)
      Gori::Settings.env_syntax = NS
      ro = Gori::Store.open(db_path, read_only: true, background_index: false)
      begin
        ro.read_only?.should be_true
        Gori::EnvMigration.reconcile(ro, db_path, "demo").not_nil!.tokens.should be > 0
      ensure
        ro.close
      end
      with_open_store(db_path) do |store|
        String.new(store.repeaters.find { |r| r.flow_id.nil? }.not_nil!.request)
          .should contain("X-A: $ENV.id\r\n")
        store.setting(Gori::Env::PROJECT_SYNTAX_KEY).should eq("namespaced")
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

  # A brand-new project is born SPEAKING this install's grammar and says so, so its first open has
  # nothing to compare and nothing to scan. Only on a genuine create: `create_or_reopen` also
  # reopens, and a bare-era database must not be stamped with a grammar its bytes are not in.
  it "stamps the marker when a project is created, and not when one is reopened" do
    with_migration_home do |db_path|
      Gori::Settings.env_syntax = NS
      registry = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
      proj, created = registry.create_or_reopen("fresh")
      created.should be_true
      with_open_store(proj.db_path) do |fresh|
        fresh.setting(Gori::Env::PROJECT_SYNTAX_KEY).should eq("namespaced")
        Gori::EnvMigration.reconcile(fresh, proj.db_path, "fresh").should be_nil
      end

      # …and the bare-era project seeded beside it, REOPENED under the same namespaced install,
      # keeps its absent marker — so the reconcile still has the migration to run.
      seed_migration_project(db_path)
      reopened, created2 = registry.create_or_reopen("demo")
      created2.should be_false
      with_open_store(reopened.db_path) do |old|
        old.setting(Gori::Env::PROJECT_SYNTAX_KEY).should be_nil
      end
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

  # The `VACUUM INTO` backup is taken ONLY when the scan found a row to change. A database full of
  # rows that hold no token gets the marker, no copy of itself, and nothing to say — otherwise every
  # grammar switch would drop a second copy of every project beside it.
  it "backs nothing up when a database has rows but no token in any of them" do
    with_migration_home do |db_path|
      with_open_store(db_path) do |store|
        store.insert_repeater("https://api.example.com",
          "GET /?$ne HTTP/1.1\r\nHost: api.example.com\r\n\r\n".to_slice, false, true, nil, 0)
        store.insert_issue("nothing to see", Gori::Store::Severity::Low, nil, nil, notes: "plain")
        store.flush
      end
      Gori::Settings.env_syntax = NS
      report = with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo")
      end.not_nil!
      report.quiet?.should be_true
      report.backup.should be_nil
      Dir.glob("#{db_path}.pre-*").should be_empty
      with_open_store(db_path) do |store|
        store.setting(Gori::Env::PROJECT_SYNTAX_KEY).should eq("namespaced")
        # `$ne` is a Mongo operator in both grammars, and it is still `$ne`.
        String.new(store.repeaters[0].request).should contain("GET /?$ne ")
      end
    end
  end

  # The one thing the opt-out can neither fix nor ignore: a dial tuple is expanded once with
  # `Escape::Preserve` and never unescaped, so a LITERAL `$id` in a target has no escaped spelling.
  # Going to bare it starts resolving, and the bytes are left as authored with the name said out loud.
  it "names a target literal that the bare grammar will start resolving" do
    with_migration_home do |db_path|
      # The seeding process has to SPEAK namespaced while it writes a namespaced-marked database:
      # the write guard (`store/env_write_guard.cr`) re-spells text a stale-grammar process is about
      # to store, which is exactly what it is for — and would turn this fixture's literal into a
      # token before the reconcile ever saw it.
      Gori::Settings.env_syntax = NS
      with_open_store(db_path) do |store|
        store.set_setting(Gori::Env::PROJECT_VARS_KEY,
          Gori::Env.serialize_vars([{"id", "evil.example.com"}]))
        store.set_setting(Gori::Env::PROJECT_SYNTAX_KEY, "namespaced")
        store.insert_repeater("https://$id.example.com",
          "GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_slice, false, true, nil, 0)
        store.flush
      end
      Gori::Settings.env_syntax = BARE
      report = with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo")
      end.not_nil!
      report.bare_hints.should eq(["$id"])
      report.quiet?.should be_false
      hint = report.notices.find(&.includes?("target or SNI")).not_nil!
      hint.should contain("1 literal")
      hint.should contain("$id")
      hint.should contain("will be substituted on the next dial")
      # The BYTES are exactly as the operator authored them — the hint is the whole remedy.
      with_open_store(db_path) do |store|
        store.repeaters[0].target.should eq("https://$id.example.com")
      end
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

        # DISPLAY text gets no escape, because nothing expands it — the sigil doubling that used to
        # happen here was visible in the issue list.
        issue = store.issues[0]
        issue.title.should eq("leaked $id")
        issue.notes.should eq("the body carried $id")
        # …and a dial tuple gets none either: it is expanded, but nothing unescapes it.
        store.repeaters.find { |r| r.flow_id.nil? }.not_nil!.target.should eq("https://$API")
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

  # The GLOBAL rewrite rules are NAMED at a project open and never rewritten there. `Settings.load`
  # re-spells what it can (the global env vars); a rule that names a PROJECT var or an extract rule
  # is only recognisable once a project is open — and rewriting it from there would not be
  # idempotent, because nothing records which grammar the RULES are in.
  it "names a global rule that still spells a token the old way, and leaves it alone" do
    with_migration_home do |db_path|
      seed_migration_project(db_path)
      Gori::Settings.env_syntax = NS
      Gori::Settings.rewriter_rules = [Gori::Settings::RewriterRule.new(
        1_i64, true, "stamp", "request", "head", "X-Env", "Bearer $token",
        "add_header", "literal", "", "")]
      report = with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo")
      end.not_nil!
      hint = report.global_hint.not_nil!
      hint.should contain("global rewrite rules: 1 rule (stamp)")
      hint.should contain("still spell a token the bare way")
      hint.should contain("settings.json")
      report.notices.size.should eq(2) # the project line, then the hint
      # NOT rewritten, and no second backup of settings.json: the rule is the operator's to fix.
      Gori::Settings.rewriter_rules[0].replacement.should eq("Bearer $token")
      Dir.glob("#{File.dirname(Gori::Settings.path)}/settings.json.pre-*").should be_empty
    ensure
      Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    end
  end

  # A rule already spelled the target's way holds nothing to fix. Its only "change" is the escape a
  # re-spelling would add, and a hint there would fire on every project of every install that has
  # ever switched — the noise that teaches operators to skip the line that matters.
  it "stays quiet about a global rule that is already spelled the target's way" do
    with_migration_home do |db_path|
      seed_migration_project(db_path)
      Gori::Settings.env_syntax = NS
      Gori::Settings.rewriter_rules = [Gori::Settings::RewriterRule.new(
        1_i64, true, "stamp", "request", "head", "X-Env", "Bearer $ENV.API",
        "add_header", "literal", "", "")]
      with_open_store(db_path) do |store|
        Gori::EnvMigration.reconcile(store, db_path, "demo").not_nil!.global_hint.should be_nil
      end
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
