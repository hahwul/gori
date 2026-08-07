require "../../spec_helper"

# Round 4 / F5. With extract rule #1 disabled (one keystroke in the TUI Rewriter tab), a
# template's `Authorization: Bearer $TOKEN` was refused on all four headless engines with
#
#   gori run fuzz: unresolved env $TOKEN — set it with `gori run project env set KEY value`,
#                  or remove the token
#
# and `--bind-from` never ran. Following that advice PERSISTS a live session token into the
# project DB — the precise outcome `bindings.cr` documents itself as preventing ("The rule
# persists; the value never does") — and the stored value is stale on the next run.
#
# Two causes, both fixed here:
#   1. `Bindings#declared` filters on `enabled?` (deliberately), so a switched-off rule's name
#      reached `env_unresolved_error` indistinguishable from a typo. `disabled_rule_ids` is the
#      other half, so the refusal can name the real gate.
#   2. `Plan.build` runs BEFORE `seed_bindings`, so its unresolved-env refusal fired on exactly
#      the template `--bind-from` was passed for. The no-rules abort is now hoisted ahead of it.

private def with_store(&)
  path = File.tempname("gori-binddisabled", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def with_layer(bindings : Gori::Bindings?, &)
  previous = Gori::Env.layer
  Gori::Env.layer = bindings
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

# The CLI's refusal wording lives behind `private def self.` (nothing outside `gori run` may
# phrase it), so it is reached through a shim in the same module — the pattern
# `verb_token_for_spec` / `emit_fuzz_result_for_spec` in spec/cli_run_spec.cr already use.
module Gori::CLI::Run
  def self.env_unresolved_error_for_spec(detail : String?) : String
    env_unresolved_error(detail)
  end

  def self.bind_from_blocker_for_spec(b : Gori::Bindings?) : String?
    bind_from_blocker(b)
  end
end

describe Gori::Bindings do
  describe "#disabled_rule_ids" do
    it "is the complement of #declared, and carries the id the remedy has to name" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("TOKEN", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        b.add("CSRF", "", Gori::ExtractKind::Cookie, "csrf").should be_nil
        b.declared.sort.should eq(["CSRF", "TOKEN"])
        b.disabled_rule_ids.should be_empty

        id = b.rules.find!(&.name.==("TOKEN")).id
        b.toggle(id).should be_true
        # `declared` drops it — that is what makes plan-build refuse — and this is what says
        # WHY it was dropped.
        b.declared.should eq(["CSRF"])
        b.disabled_rule_ids.should eq({"TOKEN" => id})
      end
    end
  end
end

describe "gori run — a token declared by a DISABLED extract rule" do
  it "names the rule and its enable command, and does NOT prescribe `project env set`" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("TOKEN", "", Gori::ExtractKind::Cookie, "sid")
      id = b.rules.first.id
      b.toggle(id)
      with_layer(b) do
        msg = Gori::CLI::Run.env_unresolved_error_for_spec("$TOKEN")
        msg.should contain("$TOKEN (extract rule ##{id})")
        msg.should contain("DISABLED")
        msg.should contain("gori run rewriter extract enable #{id}")
        msg.should contain("--bind-from")
        # The remedy that writes a live token to disk must not be the one offered.
        msg.should_not contain("set it with `gori run project env set KEY value`")
      end
    end
  end

  it "keeps the env sentence when the rule is ENABLED but the token is simply unknown" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("TOKEN", "", Gori::ExtractKind::Cookie, "sid")
      with_layer(b) do
        # An enabled rule is deferred, never refused, so anything that reaches this sentence
        # really is an unknown env key.
        Gori::CLI::Run.env_unresolved_error_for_spec("$NOPE")
          .should eq("unresolved env $NOPE — set it with `gori run project env set KEY value`, " \
                     "or remove the token")
      end
    end
  end

  it "keeps the env sentence when the project has NO extract rules at all" do
    with_store do |store|
      with_layer(Gori::Bindings.load(store)) do
        Gori::CLI::Run.env_unresolved_error_for_spec("$TOKEN")
          .should contain("gori run project env set KEY value")
      end
    end
    # …and with no binding layer installed at all (--request/stdin with no project).
    with_layer(nil) do
      Gori::CLI::Run.env_unresolved_error_for_spec("$TOKEN")
        .should contain("gori run project env set KEY value")
    end
  end

  it "says both things when one refused token is a disabled rule and another is not" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("TOKEN", "", Gori::ExtractKind::Cookie, "sid")
      b.toggle(b.rules.first.id)
      with_layer(b) do
        msg = Gori::CLI::Run.env_unresolved_error_for_spec("$TOKEN, $HOST")
        msg.should contain("extract rule #")
        msg.should contain("$HOST is not declared by any rule")
        msg.should contain("gori run project env set KEY value")
      end
    end
  end
end

describe "gori run --bind-from — the pre-plan refusal" do
  it "refuses a project with no extract rules" do
    with_store do |store|
      Gori::CLI::Run.bind_from_blocker_for_spec(Gori::Bindings.load(store))
        .should eq(Gori::CLI::Run::BIND_FROM_NO_RULES)
    end
    # A nil layer keeps the no-rules answer HERE, and only here: this blocker is also what
    # `seed_bindings` reaches, AFTER its own `open_store`, where nil means the load failed rather
    # than "no project was named". The preflight caller no longer shares that answer — it routes
    # through `preflight_bind_from_blocker`, which returns BIND_FROM_NO_PROJECT instead, because a
    # nil layer there means `--request`/stdin was run with no --project/--db and telling that
    # operator their project "declares no extract rules" was measurably false. Do not merge the two
    # back together; see spec/cli_run_spec.cr's "no project vs no rules".
    Gori::CLI::Run.bind_from_blocker_for_spec(nil).should eq(Gori::CLI::Run::BIND_FROM_NO_RULES)
  end

  it "refuses an ALL-DISABLED project with the enable command, not 'add one'" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("TOKEN", "", Gori::ExtractKind::Cookie, "sid")
      id = b.rules.first.id
      b.toggle(id)
      msg = Gori::CLI::Run.bind_from_blocker_for_spec(b).should_not be_nil
      msg.should contain("every extract rule in this project is disabled")
      msg.should contain("gori run rewriter extract enable #{id}")
      msg.should_not contain("declares no extract rules")
    end
  end

  it "allows a project with at least one ENABLED rule" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("TOKEN", "", Gori::ExtractKind::Cookie, "sid")
      b.add("CSRF", "", Gori::ExtractKind::Cookie, "csrf")
      b.toggle(b.rules.find!(&.name.==("TOKEN")).id)
      Gori::CLI::Run.bind_from_blocker_for_spec(b).should be_nil
    end
  end
end
