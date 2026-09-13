require "./spec_helper"

# The QUERIES every surface reads, under the namespaced grammar: what is unresolved, which names
# a text references, what a slot ships literally, what must be masked — plus the formatter family
# those answers are printed through.
#
# The shape rule they enforce (a decision, not an accident): a list that is PRINTED carries
# QUALIFIED names (`"ENV.HOST"`, `"BIND.SESSION"`), and a list that INDEXES A TABLE carries bare
# names plus an explicit namespace. A name in both namespaces therefore never meets itself in one
# list, and `token_list` can spell any of them back in whichever grammar is in effect.

private class QueryLayer < Gori::Env::Layer
  def initialize(@declared : Array(String), @values : Hash(String, String),
                 @held : Hash(String, String)? = nil)
  end

  def declared : Array(String)
    @declared
  end

  def values : Hash(String, String)
    @values
  end

  def held_values : Hash(String, String)
    @held || @values
  end

  def rev : UInt64
    1_u64
  end
end

private def with_q(vars : Array({String, String}) = [] of {String, String},
                   declared : Array(String) = [] of String,
                   bound : Hash(String, String) = {} of String => String,
                   held : Hash(String, String)? = nil, &)
  prev_layer = Gori::Env.layer
  prev_vars = Gori::Settings.project_env_vars
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = vars
  Gori::Env.layer = QueryLayer.new(declared, bound, held)
  with_env_syntax(Gori::Env::Syntax::Namespaced) do
    yield
  ensure
    Gori::Env.layer = prev_layer
    Gori::Settings.project_env_vars = prev_vars
  end
end

describe "Gori::Env — namespaced queries" do
  it "unresolved names BOTH namespaces, qualified, and still defers a declared binding" do
    with_q(vars: [{"HOST", "h"}], declared: ["SESSION"], bound: {} of String => String) do
      text = "http://$ENV.HOST/$ENV.NOPE?s=$BIND.SESSION&t=$BIND.OTHER&x=$id"
      # A DECLARED binding is not unresolved — it resolves later, at send.
      Gori::Env.unresolved(text).should eq(["ENV.NOPE", "BIND.OTHER"])
      Gori::Env.unresolved(text, deferred: nil)
        .should eq(["ENV.NOPE", "BIND.SESSION", "BIND.OTHER"])
      Gori::Env.token_list(Gori::Env.unresolved(text)).should eq("$ENV.NOPE, $BIND.OTHER")
    end
  end

  it "defers only a BIND name — an $ENV.X of the same name is a genuine env miss" do
    with_q(declared: ["SESSION"], bound: {} of String => String) do
      Gori::Env.unresolved("a=$ENV.SESSION b=$BIND.SESSION").should eq(["ENV.SESSION"])
    end
  end

  it "token_names answers qualified by default and BARE inside one namespace" do
    with_q do
      text = "$ENV.A $BIND.B $ENV.A $id"
      Gori::Env.token_names(text).should eq(["ENV.A", "BIND.B"])
      Gori::Env.token_names(text, ns: Gori::Env::Namespace::Env).should eq(["A"])
      Gori::Env.token_names(text, ns: Gori::Env::Namespace::Bind).should eq(["B"])
    end
  end

  it "literal_keys carries both spellings, so a mid-session syntax toggle keeps matching" do
    with_q do
      Gori::Env.literal_keys("$ENV.A $BIND.B").should eq(Set{"A", "ENV.A", "B", "BIND.B"})
    end
  end

  it "unbound_in_slot reports a slot's own literal $BIND.NAME, and the hint offers the escape" do
    with_q(declared: ["SESSION"], bound: {} of String => String) do
      slot = Gori::SessionSlot.new("admin",
        set_headers: [{"Authorization", "Bearer $BIND.SESSION"}, {"X-Env", "$ENV.HOST"}],
        rules: ["SESSION"])
      Gori::Env.unbound_in_slot(slot).should eq(["SESSION"])
      Gori::Env.spell_escaped("SESSION", Gori::Env::Namespace::Bind).should eq("$$BIND.SESSION")
      # Bound ⇒ nothing to report.
      Gori::Env.layer = QueryLayer.new(["SESSION"], {"SESSION" => "tok"})
      Gori::Env.unbound_in_slot(slot).should be_empty
    end
  end

  it "mask_secrets masks each namespace back to ITS OWN spelling, ENV first on a tie" do
    with_q(vars: [{"SECRET", "AAAABBBBCCCC"}], declared: ["TOKEN"],
      bound: {"TOKEN" => "DDDDEEEEFFFF"}) do
      Gori::Env.mask_secrets("a=AAAABBBBCCCC b=DDDDEEEEFFFF")
        .should eq("a=$ENV.SECRET b=$BIND.TOKEN")
      # Same VALUE in both namespaces: ENV wins, deterministically, rather than whichever the
      # sort happened to leave first.
      Gori::Env.layer = QueryLayer.new(["SECRET"], {"SECRET" => "AAAABBBBCCCC"})
      Gori::Env.mask_secrets("x=AAAABBBBCCCC").should eq("x=$ENV.SECRET")
      # Longest value still wins at a position.
      Gori::Settings.project_env_vars = [{"LONG", "secret_value"}, {"SHORT", "secret"}]
      Gori::Env.mask_secrets("x=secret_value").should eq("x=$ENV.LONG")
    end
  end

  it "mask_secrets keeps masking a value whose extract rule was disabled" do
    # `held_values` is wider than `values` on purpose: those bytes came off a real response and
    # are still in memory, so a redaction must not stop when a rule is toggled off.
    with_q(declared: [] of String, bound: {} of String => String,
      held: {"TOKEN" => "GGGGHHHHIIII"}) do
      Gori::Env.mask_secrets("a=GGGGHHHHIIII").should eq("a=$BIND.TOKEN")
    end
  end

  it "spell / spell_escaped / input_hint / strip_spelling / parse_ref? round-trip" do
    env = Gori::Env::Namespace::Env
    bind = Gori::Env::Namespace::Bind
    with_q do
      Gori::Env.spell("HOST", env).should eq("$ENV.HOST")
      Gori::Env.spell("SESSION", bind).should eq("$BIND.SESSION")
      # An already-qualified name carries its own namespace and `ns` is ignored.
      Gori::Env.spell("BIND.SESSION", env).should eq("$BIND.SESSION")
      Gori::Env.spell(Gori::Env::Ref.new(bind, "SESSION")).should eq("$BIND.SESSION")
      Gori::Env.input_hint(bind).should eq("$BIND.")
      Gori::Env.input_hint(env).should eq("$ENV.")
      %w[$BIND.SESSION BIND.SESSION $SESSION SESSION].each do |raw|
        Gori::Env.strip_spelling(raw, bind).should eq("SESSION")
      end
      Gori::Env.parse_ref?("$BIND.SESSION").should eq(Gori::Env::Ref.new(bind, "SESSION"))
      Gori::Env.parse_ref?("$SESSION", default_ns: bind)
        .should eq(Gori::Env::Ref.new(bind, "SESSION"))
      Gori::Env.parse_ref?("$ENV.HOST", default_ns: bind)
        .should eq(Gori::Env::Ref.new(env, "HOST"))
      Gori::Env.parse_ref?("$1").should be_nil
      Gori::Env.parse_ref?("").should be_nil
      Gori::Env.parse_ref?("$ENV.").should be_nil
      # `qualify` / `split_qualified` are the key shape, never a lookup key.
      Gori::Env.qualify(bind, "SESSION").should eq("BIND.SESSION")
      Gori::Env.split_qualified("BIND.SESSION").should eq({bind, "SESSION"})
      Gori::Env.split_qualified("SESSION").should eq({nil, "SESSION"})
      Gori::Env.split_qualified("a.b").should eq({nil, "a.b"})
    end
  end

  it "the same formatters spell the BARE grammar, so no caller has to branch" do
    env = Gori::Env::Namespace::Env
    bind = Gori::Env::Namespace::Bind
    with_env_syntax(Gori::Env::Syntax::Bare) do
      Gori::Env.spell("HOST", env).should eq("$HOST")
      Gori::Env.spell("SESSION", bind).should eq("$SESSION")
      Gori::Env.spell("BIND.SESSION", env).should eq("$SESSION")
      Gori::Env.spell_escaped("SESSION", bind).should eq("$$SESSION")
      Gori::Env.input_hint(bind).should eq("$")
      Gori::Env.strip_spelling("$SESSION", bind).should eq("SESSION")
      Gori::Env.token_list(["A", "B"]).should eq("$A, $B")
      Gori::Env.token_list(["A"], ns: bind).should eq("$A")
    end
  end

  it "token_list qualifies bare names when told which namespace they came from" do
    with_q do
      Gori::Env.token_list(["A", "B"], ns: Gori::Env::Namespace::Bind)
        .should eq("$BIND.A, $BIND.B")
      # …and leaves an already-qualified list alone.
      Gori::Env.token_list(["ENV.A", "BIND.B"]).should eq("$ENV.A, $BIND.B")
    end
  end

  it "vars_for / masking_for / masking_table map a namespace to its table" do
    with_q(vars: [{"HOST", "h"}], declared: ["S"], bound: {"S" => "v"},
      held: {"S" => "v", "OLD" => "gone"}) do
      Gori::Env.vars_for(Gori::Env::Namespace::Env).should eq({"HOST" => "h"})
      Gori::Env.vars_for(Gori::Env::Namespace::Bind).should eq({"S" => "v"})
      Gori::Env.masking_for(Gori::Env::Namespace::Bind).should eq({"S" => "v", "OLD" => "gone"})
      Gori::Env.masking_table.map { |(ref, _)| ref.qualified }
        .should eq(["ENV.HOST", "BIND.S", "BIND.OLD"])
    end
  end

  it "Namespace carries its own label, description and masking policy" do
    Gori::Env::Namespace::Env.label.should eq("ENV")
    Gori::Env::Namespace::Bind.label.should eq("BIND")
    Gori::Env::Namespace.parse?("ENV").should eq(Gori::Env::Namespace::Env)
    Gori::Env::Namespace.parse?("env").should be_nil # case-SENSITIVE
    Gori::Env::Namespace.parse?("RAND").should be_nil
    Gori::Env::Namespace::Bind.secret?.should be_true
    Gori::Env::Namespace::Env.secret?.should be_false
    # ≤ 24 cells: the completer prints it beside the label inside a dropdown that must fit a
    # 60-column pane.
    Gori::Env::Namespace.values.max_of(&.description.size).should be <= 24
  end
end
