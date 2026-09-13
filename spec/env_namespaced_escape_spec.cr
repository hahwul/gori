require "./spec_helper"

# The NAMESPACED escape: `$$ENV.X` and `$$BIND.X`, each consumed by the pass that owns that
# namespace, and a bare `$$` that is simply two bytes.
#
# A request is expanded TWICE — the env-var layer at plan-build, the binding layer at the send
# seam — with a String as the only channel between them, so the escape has to survive the pass
# that does NOT own it. That is what "a pass owns ONE namespace: its tokens AND its escapes"
# buys: the env pass copies `$$BIND.X` through byte-exact and the send seam consumes it, and
# vice versa. The bare grammar solved the same problem with `Escape::Preserve`/`Consume`, which
# is now a bare-mode knob only.

private class EscLayer < Gori::Env::Layer
  def initialize(@declared : Array(String), @values : Hash(String, String))
  end

  def declared : Array(String)
    @declared
  end

  def values : Hash(String, String)
    @values
  end

  def rev : UInt64
    1_u64
  end
end

private def with_esc(vars : Array({String, String}) = [] of {String, String},
                     declared : Array(String) = [] of String,
                     bound : Hash(String, String) = {} of String => String, &)
  prev_layer = Gori::Env.layer
  prev_vars = Gori::Settings.project_env_vars
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = vars
  Gori::Env.layer = (declared.empty? && bound.empty?) ? nil : EscLayer.new(declared, bound)
  with_env_syntax(Gori::Env::Syntax::Namespaced) do
    yield
  ensure
    Gori::Env.layer = prev_layer
    Gori::Settings.project_env_vars = prev_vars
    Gori::Settings.env_vars = [] of {String, String}
  end
end

private def env_pass(text : String) : String
  String.new(Gori::Env.expand_wire(text))
end

private def bind_pass(text : String) : String
  String.new(Gori::Env.expand_bindings(text.to_slice))
end

private def two_pass(text : String) : String
  bind_pass(env_pass(text))
end

describe "Gori::Env — the namespaced escape" do
  it "the ENV pass consumes $$ENV.X and resolves nothing behind it" do
    with_esc(vars: [{"X", "VALUE"}]) do
      env_pass("a=$$ENV.X").should eq("a=$ENV.X")
      # …and the SEND pass leaves the survivor alone: it is not its namespace.
      two_pass("a=$$ENV.X").should eq("a=$ENV.X")
    end
  end

  it "$$BIND.X survives the ENV pass byte-exact and is consumed by the send seam" do
    with_esc(declared: ["X"], bound: {"X" => "BOUND"}) do
      env_pass("a=$$BIND.X").should eq("a=$$BIND.X")
      two_pass("a=$$BIND.X").should eq("a=$BIND.X")
    end
  end

  it "consumes the escape whether or not the name behind it would resolve" do
    with_esc(vars: [{"SET", "V"}], declared: ["B"], bound: {"B" => "V"}) do
      two_pass("$$ENV.SET $$ENV.UNSET $$BIND.B $$BIND.NOPE")
        .should eq("$ENV.SET $ENV.UNSET $BIND.B $BIND.NOPE")
    end
  end

  it "a bare $$ is two literal bytes, with the second sigil re-examined" do
    with_esc(vars: [{"id", "ENVVAL"}, {"A", "V"}]) do
      # Nothing to escape FROM: `$id` is not a reference in this grammar.
      two_pass("q($$id) $$ $$1").should eq("q($$id) $$ $$1")
      # The second sigil IS re-examined, so `$$$ENV.A` is a literal `$` followed by the escape.
      env_pass("$$$ENV.A").should eq("$$ENV.A")
      two_pass("$$$ENV.A").should eq("$$ENV.A")
      # …while `$$ENV.A` alone is the escape, and `$ENV.A` alone resolves.
      two_pass("$ENV.A").should eq("V")
    end
  end

  it "reports an escape as neither unresolved nor a token" do
    with_esc(declared: ["X"], bound: {} of String => String) do
      Gori::Env.unresolved("$$ENV.NOPE $$BIND.X", deferred: nil).should be_empty
      Gori::Env.unbound("$$BIND.X").should be_empty
      Gori::Env.token_refs("$$ENV.NOPE $$BIND.X").should be_empty
      Gori::Env.regions("$$ENV.NOPE").should be_empty
    end
  end

  it "a GraphQL / Mongo / JSON Schema body round-trips both passes with NO escape at all" do
    body = %({"query":"mutation($input: I!){ set(input: $input) }",) +
           %("q":{"age":{"$ne":null}},"$ref":"#/x","$schema":"y"})
    with_esc(vars: [{"input", "E"}, {"ref", "R"}], declared: ["ne"], bound: {"ne" => "N"}) do
      two_pass(body).should eq(body)
    end
  end

  # The surface where ONE pass is the last pass (the TUI intercept forward). Under this grammar
  # there are two escapes to consume there and `Escape::Consume` can only name one, so the seam
  # asks in `Owns`.
  it "unescape: Owns::All consumes both escapes in a single pass" do
    with_esc(vars: [{"A", "V"}], declared: ["B"], bound: {"B" => "W"}) do
      String.new(Gori::Env.expand_wire("$$ENV.A $$BIND.B $ENV.A\n\n", unescape: Gori::Env::Owns::All))
        .should eq("$ENV.A $BIND.B V\r\n\r\n")
    end
  end

  it "expand's default pass consumes only the ENV escape" do
    with_esc do
      Gori::Env.expand("$$ENV.A $$BIND.B").should eq("$ENV.A $$BIND.B")
    end
  end
end
