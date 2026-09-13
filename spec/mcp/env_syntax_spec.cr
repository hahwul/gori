require "../spec_helper"
require "../support/mcp_harness"

# The refusal sentence is a private instance method — every tool that can refuse an unresolved
# token shares it — so it is exposed the way the CLI's sibling is.
class Gori::MCP::Tools
  def env_unresolved_error_for_spec(detail : String?) : String
    env_unresolved_error(detail)
  end
end

# `list_env` answers "which spelling do I write?" as well as "which keys exist?".
#
# An agent holding a key still has to MINT a token, and the grammar is per-install: `$ENV.KEY`
# where the namespaced syntax is on, `$KEY` on a legacy bare install, with a configurable sigil
# in both. Guessing wrong is silent in both directions — a reference shipped as literal bytes,
# or the app's own `$id` resolved into a secret — so the grammar rides on the result rather than
# on the caller's assumptions. Both modes are pinned here because the shape, not the value, is
# the contract: the spelling fields and generator catalog are always explicit.
private def env_result(store, args : String = "{}") : JSON::Any
  mcp_ok_json(tools_for(store), "list_env", args)
end

describe "MCP list_env grammar report" do
  it "reports the bare syntax, the sigil and a spelled example" do
    with_store_env do |store|
      with_env_syntax(Gori::Env::Syntax::Bare) do
        mcp_ok_json(tools_for(store), "set_env_var", %({"key":"TOKEN","value":"secret123"}))
        got = env_result(store)
        got["syntax"].as_s.should eq("bare")
        got["prefix"].as_s.should eq("$")
        got["example"].as_s.should eq("$KEY")
        got["vars"].as_a.map(&.["key"].as_s).should eq(["TOKEN"])
        got["vars"][0]["value"].as_s.should eq("[REDACTED]")
        got["generators"].as_a.should be_empty
      end
    end
  end

  it "reports the namespaced syntax and the $ENV. spelling" do
    with_store_env do |store|
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        mcp_ok_json(tools_for(store), "set_env_var", %({"key":"TOKEN","value":"secret123"}))
        got = env_result(store)
        got["syntax"].as_s.should eq("namespaced")
        got["prefix"].as_s.should eq("$")
        got["example"].as_s.should eq("$ENV.KEY")
        # The rows are unchanged by the grammar: `vars` is a table keyed by BARE name, and a
        # qualified key here would be a name no `set_env_var`/`delete_env_var` call accepts.
        got["vars"].as_a.map(&.["key"].as_s).should eq(["TOKEN"])
        generators = got["generators"].as_a
        generators.map(&.["name"].as_s).should eq(
          ["UUID", "RANDOM", "RANDOM_HEX", "TIMESTAMP", "TIMESTAMP_MS", "ISO8601"])
        generators.map(&.["token"].as_s).should contain("$GEN.UUID")
        generators.find! { |row| row["name"].as_s == "RANDOM_HEX" }["description"].as_s
          .should contain("128-bit hex")
      end
    end
  end

  it "reports a non-default sigil in prefix AND in the example" do
    with_store_env do |store|
      was = Gori::Settings.env_prefix
      begin
        Gori::Settings.env_prefix = "%"
        with_env_syntax(Gori::Env::Syntax::Namespaced) do
          got = env_result(store)
          got["prefix"].as_s.should eq("%")
          got["example"].as_s.should eq("%ENV.KEY")
          got["generators"].as_a[0]["token"].as_s.should eq("%GEN.UUID")
        end
      ensure
        Gori::Settings.env_prefix = was
      end
    end
  end

  it "reports the grammar on an EMPTY project, where there is no row to read it off" do
    with_store_env do |store|
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        got = env_result(store)
        got["vars"].as_a.should be_empty
        got["syntax"].as_s.should eq("namespaced")
        got["example"].as_s.should eq("$ENV.KEY")
      end
    end
  end

  it "still redacts nothing but the value when asked for the secret" do
    with_store_env do |store|
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        mcp_ok_json(tools_for(store), "set_env_var", %({"key":"AUTH","value":"Bearer eyJhbGciOiJ9"}))
        got = env_result(store, %({"include_sensitive":true}))
        row = got["vars"][0]
        row["value"].as_s.should eq("Bearer eyJhbGciOiJ9")
        row["scheme"].as_s.should eq("Bearer")
        row["length"].as_i.should eq(19)
      end
    end
  end

  # The refusal every tool shares when a token resolves to nothing has to name the remedy for THE
  # NAMESPACE it is about. `set_env_var` is the remedy for an env var; a BIND name has no setter at
  # all — it is bound at send time from a response — so telling an agent to `set_env_var` it made it
  # persist a live session credential into the project as a static var, stale by the next run.
  describe "the unresolved-token remedy" do
    it "names set_env_var for an $ENV. token and an extract rule for a $BIND. one" do
      with_store_env do |store|
        tools = tools_for(store)
        with_env_syntax(Gori::Env::Syntax::Namespaced) do
          env = tools.env_unresolved_error_for_spec("$ENV.TOKEN")
          env.should contain("unresolved env $ENV.TOKEN")
          env.should contain("set_env_var")
          env.should_not contain("create_extract_rule")

          bind = tools.env_unresolved_error_for_spec("$BIND.SESSION")
          bind.should contain("create_extract_rule")
          bind.should contain("bound at send time")
          bind.should_not contain("set_env_var")

          # Both in one list: both remedies, because both names are there.
          both = tools.env_unresolved_error_for_spec("$ENV.TOKEN, $BIND.SESSION")
          both.should contain("set_env_var")
          both.should contain("create_extract_rule")
          both.should end_with("or remove the token")
        end
      end
    end

    it "points an unknown generator at the advertised catalog" do
      with_store_env do |store|
        with_env_syntax(Gori::Env::Syntax::Namespaced) do
          msg = tools_for(store).env_unresolved_error_for_spec("$GEN.NOPE")
          msg.should contain("unresolved generator $GEN.NOPE")
          msg.should contain("list_env.generators")
          msg.should_not contain("set_env_var")
        end
      end
    end

    it "explains a registered generator refused where nothing mints" do
      with_store_env do |store|
        with_env_syntax(Gori::Env::Syntax::Namespaced) do
          msg = tools_for(store).env_unresolved_error_for_spec("$GEN.UUID")
          msg.should contain("is a generator")
          msg.should contain("before the request is framed")
          msg.should_not contain("list_env.generators")
        end
      end
    end

    it "names both remedies under the BARE grammar, where a name carries no namespace" do
      with_store_env do |store|
        tools = tools_for(store)
        with_env_syntax(Gori::Env::Syntax::Bare) do
          msg = tools.env_unresolved_error_for_spec("$SESSION")
          msg.should contain("set_env_var")
          msg.should contain("create_extract_rule")
        end
      end
    end

    it "reads a non-default sigil rather than matching \"$BIND.\" as text" do
      with_store_env do |store|
        tools = tools_for(store)
        was = Gori::Settings.env_prefix
        begin
          Gori::Settings.env_prefix = "%"
          with_env_syntax(Gori::Env::Syntax::Namespaced) do
            tools.env_unresolved_error_for_spec("%BIND.SESSION")
              .should contain("create_extract_rule")
          end
        ensure
          Gori::Settings.env_prefix = was
        end
      end
    end
  end

  # The SCHEMA is built once and handed to the model; it cannot follow a live setting, so it has
  # to name both grammars. The result's `syntax` says which one is in force.
  it "names both spellings in the tools/list description" do
    with_store_env do |store|
      listed = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/list"}))[0]
      desc = listed["result"]["tools"].as_a.find! { |t| t["name"].as_s == "list_env" }["description"].as_s
      desc.should contain("$ENV.KEY")
      desc.should contain("$BIND.NAME")
      desc.should contain("generators")
      desc.should contain("bare = $KEY")
      desc.should contain("{syntax, prefix, example, vars")
    end
  end
end
