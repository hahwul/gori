require "./spec_helper"

# `$ENV.KEY` / `$BIND.NAME` — the NAMESPACED grammar.
#
# The whole point of the namespace is that an app-grammar `$` is not a reference any more: a
# GraphQL `$id`, a Mongo `$ne`, an OData `$filter` and a JSON Schema `$ref` are ordinary bytes
# under this syntax and need no escape at all. So most of this file is a table of things that
# must NOT be tokens, asserted through `expand` (the one place a wrong answer reaches a socket)
# and through `token_refs`/`regions` (the queries every surface reads).
#
# The bare grammar keeps its own ~45 spec files; the suite pins `env_syntax_when_absent` to bare
# (see spec_helper) and every example here opts in with `with_env_syntax`.

private class NsLayer < Gori::Env::Layer
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

private def with_ns(vars : Array({String, String}) = [] of {String, String},
                    declared : Array(String) = [] of String,
                    bound : Hash(String, String) = {} of String => String,
                    prefix : String = "$", &)
  prev_layer = Gori::Env.layer
  prev_prefix = Gori::Settings.env_prefix
  prev_global = Gori::Settings.env_vars
  prev_project = Gori::Settings.project_env_vars
  Gori::Settings.env_prefix = prefix
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = vars
  Gori::Env.layer = (declared.empty? && bound.empty?) ? nil : NsLayer.new(declared, bound)
  with_env_syntax(Gori::Env::Syntax::Namespaced) do
    yield
  ensure
    Gori::Env.layer = prev_layer
    Gori::Settings.env_prefix = prev_prefix
    Gori::Settings.env_vars = prev_global
    Gori::Settings.project_env_vars = prev_project
  end
end

# The two passes a Repeater/Fuzzer/Miner send runs, in order: env vars at plan-build, bindings
# at the send seam.
private def two_pass(text : String) : String
  String.new(Gori::Env.expand_bindings(Gori::Env.expand_wire(text)))
end

describe "Gori::Env — namespaced grammar" do
  it "resolves $ENV.NAME from the env vars and $BIND.NAME from the binding table" do
    with_ns(vars: [{"HOST", "api.test"}], declared: ["SESSION"], bound: {"SESSION" => "s3cr3t"}) do
      two_pass("GET http://$ENV.HOST/ HTTP/1.1\nCookie: sid=$BIND.SESSION\n\n")
        .should eq("GET http://api.test/ HTTP/1.1\r\nCookie: sid=s3cr3t\r\n\r\n")
    end
  end

  it "does not resolve across namespaces — one name, two tables" do
    with_ns(vars: [{"TOKEN", "ENVVAL"}], declared: ["TOKEN"], bound: {"TOKEN" => "BINDVAL"}) do
      two_pass("a=$ENV.TOKEN b=$BIND.TOKEN").should eq("a=ENVVAL b=BINDVAL")
    end
  end

  # The collision the syntax exists to remove. An env var named `id` and a binding named `ne`
  # are both set, and a captured GraphQL/Mongo body still goes out byte-exact.
  it "leaves an app-grammar $id / $ne / $ref / $filter alone with NO escape" do
    body = %({"query":"query G($id: ID!){user(id:$id){name}}",) +
           %("filter":{"age":{"$ne":null}},"$ref":"#/defs/x","$where":"1"})
    with_ns(vars: [{"id", "ENVVAL"}, {"ref", "R"}, {"filter", "F"}],
      declared: ["ne", "where"], bound: {"ne" => "N", "where" => "W"}) do
      two_pass(body).should eq(body)
      Gori::Env.token_refs(body).should be_empty
      Gori::Env.unresolved(body).should be_empty
      Gori::Env.unbound(body).should be_empty
    end
  end

  it "is case-sensitive and requires the dot: $env.X, $ENVX, $ENV., $ENV.1x, $FOO.bar are not tokens" do
    with_ns(vars: [{"X", "V"}, {"bar", "B"}]) do
      %w[$env.X $Env.X $ENVX $ENV. $ENV.1x $FOO.bar $BINDX $bind.X].each do |text|
        two_pass(text).should eq(text)
        Gori::Env.token_refs(text).should be_empty
      end
    end
  end

  it "reads two adjacent tokens, and stops a name at the second dot" do
    with_ns(vars: [{"A", "1"}], declared: ["B"], bound: {"B" => "2"}) do
      two_pass("$ENV.A$BIND.B").should eq("12")
      # `$BIND.A.B` is Token(Bind, "A") followed by the literal bytes `.B` — the dot is
      # structural, never part of a name.
      two_pass("$BIND.B.C").should eq("2.C")
    end
  end

  it "leaves an unresolvable token LITERAL, whole — never half of it" do
    with_ns(vars: [{"HOST", "h"}]) do
      two_pass("x=$ENV.NOPE y=$BIND.NOPE z=$ENV.HOST").should eq("x=$ENV.NOPE y=$BIND.NOPE z=h")
    end
  end

  it "spells and reads tokens under a non-$ prefix" do
    with_ns(vars: [{"HOST", "h"}], prefix: "%") do
      Gori::Env.spell("HOST", Gori::Env::Namespace::Env).should eq("%ENV.HOST")
      two_pass("http://%ENV.HOST/ and $ENV.HOST").should eq("http://h/ and $ENV.HOST")
      Gori::Env.token_refs("%ENV.HOST").map(&.qualified).should eq(["ENV.HOST"])
    end
  end

  # Byte-level, same reason `expand` has always been: a captured body is routinely not valid
  # UTF-8, and a char-based scan would rewrite every invalid sequence to U+FFFD.
  it "copies invalid UTF-8 through byte-exact while resolving a token beside it" do
    bad = Bytes[0x7B, 0x22, 0x62, 0x22, 0x3A, 0x22, 0xFF, 0xFE, 0x22, 0x2C, 0x24, 0x45, 0x4E,
      0x56, 0x2E, 0x41, 0x2C, 0x24, 0x69, 0x64, 0x7D] # {"b":"\xff\xfe",$ENV.A,$id}
    with_ns(vars: [{"A", "V"}]) do
      out = Gori::Env.expand(String.new(bad)).to_slice
      expected = Bytes[0x7B, 0x22, 0x62, 0x22, 0x3A, 0x22, 0xFF, 0xFE, 0x22, 0x2C, 0x56, 0x2C,
        0x24, 0x69, 0x64, 0x7D]
      out.should eq(expected)
    end
  end

  it "regions carry the namespace, the name and per-namespace knownness" do
    with_ns(vars: [{"HOST", "h"}], declared: ["SESSION"], bound: {"SESSION" => "s"}) do
      regions = Gori::Env.regions("a $ENV.HOST b $BIND.SESSION c $ENV.NOPE d $id")
      regions.map(&.name).should eq(["HOST", "SESSION", "NOPE"])
      regions.map(&.ns).should eq([Gori::Env::Namespace::Env, Gori::Env::Namespace::Bind,
                                   Gori::Env::Namespace::Env])
      regions.map(&.known).should eq([true, true, false])
      regions[0].start.should eq(2)
      regions[0].stop.should eq(11)
      # The 3-tuple projection its oldest consumers read.
      Gori::Env.token_regions("a $ENV.HOST").should eq([{2, 11, true}])
    end
  end

  it "regions are CHAR offsets, so multi-byte text stays aligned" do
    with_ns(vars: [{"A", "v"}]) do
      r = Gori::Env.regions("한글 $ENV.A")
      r.size.should eq(1)
      r[0].start.should eq(3)
      r[0].stop.should eq(9)
    end
  end

  it "token_refs reports every reference in order, duplicates included" do
    with_ns do
      Gori::Env.token_refs("$ENV.A $BIND.B $ENV.A").map(&.qualified)
        .should eq(["ENV.A", "BIND.B", "ENV.A"])
    end
  end

  it "may_contain_tokens? rejects a body that only carries app-grammar dollars" do
    with_ns do
      Gori::Env.may_contain_tokens?(%({"age":{"$ne":1},"$ref":"x"})).should be_false
      Gori::Env.may_contain_tokens?("$ENV.A").should be_true
      Gori::Env.may_contain_tokens?("$ENV.A", Gori::Env::Owns::Bind).should be_false
      Gori::Env.may_contain_tokens?("$BIND.A", Gori::Env::Owns::Bind).should be_true
      # The escape still needs the pass that owns it — that pass is what consumes it.
      Gori::Env.may_contain_tokens?("$$BIND.A", Gori::Env::Owns::Bind).should be_true
    end
  end

  it "read_token_at answers the same grammar over bytes and over chars" do
    with_ns do
      text = "x $ENV.HOST"
      b = Gori::Env.read_token_at(text.to_slice, 2, text.bytesize).not_nil!
      c = Gori::Env.read_token_at(text.chars, 2, text.size).not_nil!
      b.kind.should eq(Gori::Env::Kind::Token)
      b.ns.should eq(Gori::Env::Namespace::Env)
      b.name.should eq("HOST")
      b.width.should eq(9)
      {c.kind, c.ns, c.name, c.width}.should eq({b.kind, b.ns, b.name, b.width})
      Gori::Env.read_token_at(text.to_slice, 0, text.bytesize).should be_nil
    end
  end

  # `limit` is the verbatim-span cap: a token may not read INTO a fuzz payload.
  it "read_token_at will not read a name past `limit`" do
    with_ns do
      text = "$ENV.HOST"
      Gori::Env.read_token_at(text.to_slice, 0, 3).not_nil!.kind
        .should eq(Gori::Env::Kind::Literal)
      cut = Gori::Env.read_token_at(text.to_slice, 0, 7).not_nil!
      cut.kind.should eq(Gori::Env::Kind::Token)
      cut.name.should eq("HO")
    end
  end
end
