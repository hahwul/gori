require "./spec_helper"

# `$$` — the ONE escape (round 7, owner policy), and the "no value ⇒ literal, never a
# refusal" half that goes with it.
#
# WHY the escape had to exist at all: `Env`'s token shape is `$` + `[A-Za-z_]` +
# `[A-Za-z0-9_]*`, and the scan runs over the whole message INCLUDING the body. That grammar
# is byte-identical to a GraphQL variable reference (`$id`, `$input`, `$userId` — required in
# any parameterised query), a MongoDB operator (`$ne`, `$gt`, `$where`) and a JSON Schema
# keyword (`$ref`, `$schema`). Before this, an operator holding an env var or an extract rule
# named `id` could not send a GraphQL query using `$id` from ANY gori surface, and had no way
# to say "this `$` is mine": `$$id` and `\$id` both still expanded (verified on the wire).
#
# The two-pass problem these pin: a request is expanded TWICE — the ENV-VAR layer at
# plan-build (`expand_wire`) and the BINDING layer at send (`expand_bindings`) — and a String
# is the only channel between them. So the escape is PRESERVED by the env pass and CONSUMED
# by the send pass, and `$$id` survives both as `$id` exactly once.

private class EscapeLayer < Gori::Env::Layer
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

private def with_env(vars : Array({String, String}) = [] of {String, String},
                     declared : Array(String) = [] of String,
                     bound : Hash(String, String) = {} of String => String, &)
  prev_layer = Gori::Env.layer
  prev_prefix = Gori::Settings.env_prefix
  prev_global = Gori::Settings.env_vars
  prev_project = Gori::Settings.project_env_vars
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = vars
  Gori::Env.layer = (declared.empty? && bound.empty?) ? nil : EscapeLayer.new(declared, bound)
  begin
    yield
  ensure
    Gori::Env.layer = prev_layer
    Gori::Settings.env_prefix = prev_prefix
    Gori::Settings.env_vars = prev_global
    Gori::Settings.project_env_vars = prev_project
  end
end

# The exact two passes a Repeater/Fuzzer/Miner send runs, in order.
private def two_pass(text : String) : String
  String.new(Gori::Env.expand_bindings(Gori::Env.expand_wire(text)))
end

describe "Gori::Env — $NAME with no value is a literal string" do
  # Policy half 1: "ENV가 있는 경우에는 ENV를 따르고" — a value present is followed.
  it "expands a name that HAS a value, env var or binding" do
    with_env(vars: [{"id", "ENVVAL"}]) do
      two_pass("q($id)").should eq("q(ENVVAL)")
    end
    with_env(declared: ["id"], bound: {"id" => "BOUNDVAL"}) do
      two_pass("q($id)").should eq("q(BOUNDVAL)")
    end
  end

  # Policy half 2: "아닌 경운엔 문자열로 처리" — no value, literal. Including a name an
  # extract rule DECLARES but nothing has bound, which used to refuse the send outright.
  it "leaves a DECLARED-but-unbound name literal rather than refusing" do
    with_env(declared: ["id"], bound: {} of String => String) do
      body = %({"query":"query GetUser($id: ID!) { user(id: $id) { name } }"})
      two_pass(body).should eq(body)
      # …and it is still REPORTED, because `Rules#report_refused` explains a rewrite rule
      # that did not apply. A report is not a gate.
      Gori::Env.unbound(body).should eq(["id"])
    end
  end

  # Complement: a name that is neither declared nor set was ALWAYS literal in a body. Pinned
  # so the policy change cannot be read as having introduced it.
  it "leaves a name that is neither declared nor set literal (unchanged)" do
    with_env do
      body = %({"filter":{"age":{"$ne":null}},"$ref":"#/defs/x"})
      two_pass(body).should eq(body)
      Gori::Env.unbound(body).should be_empty
    end
  end

  # The whole point of the change, in the shape the hunter reproduced: an ordinary extract
  # rule named `id` must not make a captured GraphQL/Mongo body unsendable.
  it "does not let one extract rule named `id` change a captured body's bytes" do
    captured = %({"query":"query GetUser($id: ID!) { user(id: $id) { name } }",) +
               %("variables":{"id":"42"},"filter":{"age":{"$ne":null}}})
    with_env(declared: ["id"], bound: {} of String => String) do
      String.new(Gori::Env.expand_bindings(captured.to_slice)).should eq(captured)
    end
  end

  # The HEAD half, added when the owner extended the policy past the send seams (#519's
  # plan-build refusal). Until then an unset `$KEY` was literal in a BODY and a REFUSAL in
  # the HEAD, which meant a GraphQL query in a query string, a Mongo `$where` header and a
  # JSON Schema `$ref` header could not be sent at all.
  it "leaves an unset name in the HEAD literal — request line and header alike" do
    with_env do
      head = "GET /graphql?query=query%20G($id)&f=$ne HTTP/1.1\r\nHost: h\r\nX-Ref: $ref\r\n\r\n"
      String.new(Gori::Env.expand_wire(head)).should eq(head)
      # `unresolved` is still the QUERY behind the DIAL-TUPLE refusal, so it must still
      # report — it simply no longer gates a request.
      Gori::Env.unresolved(head).should eq(["id", "ne", "ref"])
    end
  end

  it "expands a HEAD name that HAS a value (the complement)" do
    with_env(vars: [{"ref", "REFVALUE"}]) do
      String.new(Gori::Env.expand_wire("GET /a HTTP/1.1\r\nX-Ref: $ref\r\n\r\n"))
        .should eq("GET /a HTTP/1.1\r\nX-Ref: REFVALUE\r\n\r\n")
    end
  end

  it "leaves a head with no $ byte-identical" do
    with_env(vars: [{"ref", "REFVALUE"}]) do
      head = "GET /a?q=1 HTTP/1.1\r\nHost: h\r\nX-Plain: nodollar\r\n\r\nbody"
      String.new(Gori::Env.expand_wire(head)).should eq(head)
    end
  end
end

describe "Gori::Env — the $$ escape" do
  it "consumes $$ into one literal $, once, across BOTH expansion passes" do
    # The name resolves in each layer in turn — the case where the escape is the only way out.
    with_env(vars: [{"id", "ENVVAL"}]) do
      two_pass("q($$id)").should eq("q($id)")
    end
    with_env(declared: ["id"], bound: {"id" => "BOUNDVAL"}) do
      two_pass("q($$id)").should eq("q($id)")
    end
    # Both layers holding the SAME name: still exactly one `$` out.
    with_env(vars: [{"id", "ENVVAL"}], declared: ["id"], bound: {"id" => "BOUNDVAL"}) do
      two_pass("q($$id)").should eq("q($id)")
    end
  end

  it "escapes even when the name resolves to nothing (one rule, not two)" do
    with_env do
      two_pass("q($$id)").should eq("q($id)")
    end
    with_env(declared: ["id"], bound: {} of String => String) do
      two_pass("q($$id)").should eq("q($id)")
    end
  end

  # Escapes pair left to right, one `$` out per `$$` in.
  it "pairs left to right: $$$$ → $$ and $$$NAME → $ + the interpreted $NAME" do
    with_env(vars: [{"id", "ENVVAL"}]) do
      two_pass("a$$$$b").should eq("a$$b")
      two_pass("$$$id").should eq("$ENVVAL")
      # …and with nothing to resolve, the trailing token stays literal.
    end
    with_env do
      two_pass("$$$id").should eq("$$id")
    end
  end

  it "escapes a GraphQL document end to end, on the send seam's own bytes" do
    with_env(vars: [{"id", "EVIL"}], declared: ["userId"], bound: {"userId" => "LIVETOKEN"}) do
      body = %({"query":"query G($$id: ID!, $$userId: ID) { user(id: $$id) { n } }"})
      out = two_pass(body)
      out.should eq(%({"query":"query G($id: ID!, $userId: ID) { user(id: $id) { n } }"}))
      out.should_not contain("EVIL")
      out.should_not contain("LIVETOKEN")
    end
  end

  # The escape must not fabricate an "unresolved env" name for the DIAL-TUPLE refusal that
  # `unresolved` still backs. `scan_unresolved` mirrors `expand`'s scan positions, so it has
  # to walk the escape with the same advance.
  it "is not reported as an unresolved env name" do
    with_env do
      Gori::Env.unresolved("Host: $$id.example").should be_empty
      Gori::Env.unresolved("http://$$host.example/a", deferred: nil).should be_empty
      # Complement: a REAL unresolved name is still reported, which is what keeps the dial
      # tuple's refusal working.
      Gori::Env.unresolved("http://$host.example/a", deferred: nil).should eq(["host"])
    end
  end

  # The invariant the two-mode design rests on, re-checked now that the HEAD no longer
  # refuses: a `$$` in the head has to survive `expand_wire` to reach `expand_bindings`,
  # which is the only consumer. Before the head half was opened this path never ran — the
  # refusal fired first — so this is genuinely new ground.
  it "survives the HEAD's two passes, in a request line and a header" do
    with_env(vars: [{"id", "ENVVAL"}], declared: ["sess"], bound: {"sess" => "LIVE"}) do
      head = "GET /graphql?query=q($$id)&s=$$sess HTTP/1.1\r\nHost: h\r\nX-E: $$id\r\nX-R: $id\r\n\r\n"
      two_pass(head).should eq(
        "GET /graphql?query=q($id)&s=$sess HTTP/1.1\r\nHost: h\r\nX-E: $id\r\nX-R: ENVVAL\r\n\r\n")
    end
  end

  # The TUI paints `$KEY` tokens; painting the `$id` inside `$$id` as resolvable would tell
  # the operator the opposite of what the wire will carry.
  it "is not painted as a token" do
    with_env(vars: [{"id", "ENVVAL"}]) do
      Gori::Env.token_regions("$$id").should be_empty
      Gori::Env.token_regions("$id").should eq([{0, 3, true}])
    end
  end

  # Framing: consuming an escape SHORTENS the body, and a head that declares a
  # Content-Length has to follow or the send desyncs the connection.
  it "shifts Content-Length when the escape shortens the body" do
    with_env(declared: ["id"], bound: {"id" => "V"}) do
      body = "$$id"
      wire = "POST /g HTTP/1.1\r\nHost: h\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      out = String.new(Gori::Env.expand_bindings(wire.to_slice))
      out.should end_with("\r\n\r\n$id")
      out.should contain("Content-Length: 3")
    end
  end

  # An EVIDENCE path interprets nothing, so it unescapes nothing: a `$$` in captured bytes is
  # two bytes the origin sent, not an escape the operator typed.
  it "is left alone on an evidence path, which expands nothing at all" do
    with_env(vars: [{"id", "ENVVAL"}]) do
      captured = "GET /a?q=$$id HTTP/1.1\r\nHost: h\r\n\r\n"
      String.new(Gori::Env.normalize_wire(captured)).should eq(captured)
    end
  end

  # A WebSocket frame is ALL payload — `Repeater::Sender#expand_messages` takes the String
  # overload with `guard_boundary: false`, and its env pass is `Env.expand` at the three
  # surfaces that build frames. Same two passes, same one escape.
  it "survives the WebSocket frame's two passes (the String overload)" do
    with_env(vars: [{"id", "ENVVAL"}], declared: ["sess"], bound: {"sess" => "LIVE"}) do
      frame = Gori::Env.expand(%({"op":"$$id","t":"$$sess","real":"$id"}))
      Gori::Env.expand_bindings(frame, guard_boundary: false)
        .should eq(%({"op":"$id","t":"$sess","real":"ENVVAL"}))
    end
  end

  # The TUI intercept editor FORWARDS straight to the origin — there is no send-seam
  # `expand_bindings` after it — so its `expand_wire` is the last pass and asks for
  # `Escape::Consume`. Pinned here because getting it wrong ships `$$` to a live target.
  it "is consumed by a terminal expand_wire (the intercept editor's mode)" do
    with_env(vars: [{"id", "ENVVAL"}]) do
      text = "GET /a?q=$$id&r=$id HTTP/1.1\nHost: h\n\n"
      String.new(Gori::Env.expand_wire(text, escape: Gori::Env::Escape::Consume))
        .should eq("GET /a?q=$id&r=ENVVAL HTTP/1.1\r\nHost: h\r\n\r\n")
      # …and the default (the plan-build pass) preserves it for the send seam.
      String.new(Gori::Env.expand_wire(text))
        .should eq("GET /a?q=$$id&r=ENVVAL HTTP/1.1\r\nHost: h\r\n\r\n")
    end
  end
end
