require "./spec_helper"

# The SEND seams under the namespaced grammar: `expand_bindings` (bytes), `_as` (one identity
# per slot), `_frame` (a WebSocket payload), and the gates in front of all three.
#
# Everything these pin is behaviour the bare grammar already had — the head/body split, the
# Content-Length delta, the CL.CL and chunked refusals, the verbatim payload spans — re-asserted
# for `$BIND.NAME`, because the namespace changed WHICH tokens a pass claims and nothing else.
# The one genuinely new property is the gate: a body carrying only `$id` now costs one scan
# instead of a full expansion of head and body.

private class SendLayer < Gori::Env::Layer
  def initialize(@declared : Array(String), @values : Hash(String, String),
                 @per_slot : Hash(String, Hash(String, String)) = {} of String => Hash(String, String))
  end

  def declared : Array(String)
    @declared
  end

  def values : Hash(String, String)
    @values
  end

  def slot_values(slot : String) : Hash(String, String)
    @per_slot[slot]? || @values
  end

  def rev : UInt64
    1_u64
  end
end

private def with_send_env(declared : Array(String) = [] of String,
                          bound : Hash(String, String) = {} of String => String,
                          per_slot : Hash(String, Hash(String, String)) = {} of String => Hash(String, String),
                          vars : Array({String, String}) = [] of {String, String}, &)
  prev_layer = Gori::Env.layer
  prev_vars = Gori::Settings.project_env_vars
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = vars
  Gori::Env.layer = SendLayer.new(declared, bound, per_slot)
  with_env_syntax(Gori::Env::Syntax::Namespaced) do
    begin
      yield
    ensure
      Gori::Env.layer = prev_layer
      Gori::Settings.project_env_vars = prev_vars
    end
  end
end

private def bind(wire : String) : String
  String.new(Gori::Env.expand_bindings(wire.to_slice))
end

describe "Gori::Env — namespaced send seams" do
  it "resolves $BIND.NAME in the head and the body, and shifts the Content-Length" do
    with_send_env(declared: ["T"], bound: {"T" => "0123456789"}) do
      out = bind("POST /a HTTP/1.1\r\nX-A: $BIND.T\r\nContent-Length: 2\r\n\r\nq=$BIND.T")
      out.should contain("X-A: 0123456789")
      out.split("\r\n\r\n", 2)[1].should eq("q=0123456789")
      # 2 + (12 - 8) … the body went from `q=$BIND.T` (9) to `q=0123456789` (12): +3.
      out.should contain("Content-Length: 5")
    end
  end

  it "shifts the Content-Length DOWN when the value is shorter than the token" do
    with_send_env(declared: ["T"], bound: {"T" => "x"}) do
      out = bind("POST /a HTTP/1.1\r\nContent-Length: 9\r\n\r\n$BIND.T")
      out.split("\r\n\r\n", 2)[1].should eq("x")
      out.should contain("Content-Length: 3") # 9 + (1 - 7)
    end
  end

  it "refuses to shift a CL.CL pair or a chunked head, and still substitutes the body" do
    with_send_env(declared: ["T"], bound: {"T" => "0123456789"}) do
      clcl = bind("POST /a HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 99\r\n\r\n$BIND.T")
      clcl.should contain("Content-Length: 2\r\nContent-Length: 99\r\n")
      clcl.should end_with("0123456789")
      chunked = bind("POST /a HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n$BIND.T\r\n0\r\n\r\n")
      chunked.should contain("Content-Length: 2\r\n")
      chunked.should contain("2\r\n0123456789\r\n")
    end
  end

  # A binding value is the ORIGIN'S. In a HEAD a `abc\r\nX-Admin: true` forges a header line;
  # in a BODY it forges nothing and multi-line values are the designed case. Split by POSITION.
  it "withholds a boundary-forging value from the HEAD and substitutes it in the BODY" do
    with_send_env(declared: ["T"], bound: {"T" => "abc\r\nX-Admin: true"}) do
      out = bind("POST /a HTTP/1.1\r\nX-A: $BIND.T\r\n\r\n$BIND.T")
      out.should contain("X-A: $BIND.T\r\n") # literal, whole — never half a token
      out.split("\r\n\r\n", 2)[1].should eq("abc\r\nX-Admin: true")
    end
  end

  # `verbatim` names the fuzz payload's own span: the operator authored `$BIND.TOKEN` there as
  # the thing under test, so substituting the live credential would both send a request nobody
  # wrote and put a real token in an arbitrary position of it.
  it "copies a verbatim payload span through, and caps a token that would read into one" do
    with_send_env(declared: ["TOKEN"], bound: {"TOKEN" => "LIVE"}) do
      wire = "POST /a HTTP/1.1\r\n\r\np=$BIND.TOKEN&q=$BIND.TOKEN"
      payload = wire.index("p=").not_nil! + 2
      spans = [{payload, payload + 11}] # exactly `$BIND.TOKEN`
      out = String.new(Gori::Env.expand_bindings(wire.to_slice, spans))
      out.should eq("POST /a HTTP/1.1\r\n\r\np=$BIND.TOKEN&q=LIVE")
      # A sigil whose token would reach INTO the span opens nothing…
      cut = "POST /a HTTP/1.1\r\n\r\n$BIND.TOKEN"
      at = cut.index("$BIND").not_nil!
      String.new(Gori::Env.expand_bindings(cut.to_slice, [{at + 3, cut.bytesize}]))
        .should eq(cut)
      # …and a NAME cut mid-way is truncated rather than reaching past the cap.
      String.new(Gori::Env.expand_bindings(cut.to_slice, [{at + 9, cut.bytesize}]))
        .should eq(cut)
    end
  end

  it "expand_bindings_as resolves out of the slot named, not the active table" do
    with_send_env(declared: ["SESSION"], bound: {"SESSION" => "ACTIVE"},
      per_slot: {"admin" => {"SESSION" => "ADMINTOK"}, "user" => {"SESSION" => "USERTOK"}}) do
      Gori::Env.expand_bindings_as("Authorization: Bearer $BIND.SESSION", "admin")
        .should eq("Authorization: Bearer ADMINTOK")
      Gori::Env.expand_bindings_as("Authorization: Bearer $BIND.SESSION", "user")
        .should eq("Authorization: Bearer USERTOK")
      # An unregistered identity resolves out of the global table — the honest answer for an
      # identity with no private one.
      Gori::Env.expand_bindings_as("Bearer $BIND.SESSION", "nobody").should eq("Bearer ACTIVE")
    end
  end

  it "expand_bindings_frame substitutes a whole WS payload and honours its verbatim span" do
    with_send_env(declared: ["T"], bound: {"T" => "V"}) do
      # All body: no head/body split, no Content-Length, no boundary withholding.
      String.new(Gori::Env.expand_bindings_frame(%({"a":"$BIND.T","b":"x\ny"}).to_slice))
        .should eq(%({"a":"V","b":"x\ny"}))
      payload = %($BIND.T $BIND.T)
      String.new(Gori::Env.expand_bindings_frame(payload.to_slice, [{0, 7}]))
        .should eq("$BIND.T V")
    end
  end

  # The gate. Nothing this pass owns ⇒ the SAME slice comes back, with no scan of the body at all.
  it "returns the identical slice when the message carries no BIND opener" do
    with_send_env(declared: ["id"], bound: {"id" => "LIVE"}) do
      body = %({"query":"query G($id){u(id:$id)}","f":{"$ne":1},"e":"$ENV.HOST"}).to_slice
      Gori::Env.expand_bindings(body).should be(body)
      frame = %({"$ne":1}).to_slice
      Gori::Env.expand_bindings_frame(frame).should be(frame)
      plain = "Cookie: sid=$id"
      Gori::Env.expand_bindings(plain).should be(plain)
    end
  end

  # …but an empty binding table is NOT on its own a reason to skip: this seam is also the one
  # that consumes `$$BIND.X`.
  it "still runs with an empty table when there is an escape to consume" do
    with_send_env(declared: [] of String, bound: {} of String => String) do
      bind("X: $$BIND.T\r\n\r\n").should eq("X: $BIND.T\r\n\r\n")
      # and leaves the OTHER namespace's escape for its own pass
      bind("X: $$ENV.T\r\n\r\n").should eq("X: $$ENV.T\r\n\r\n")
    end
  end

  it "unbound reports a declared-but-unbound BIND name only, in bare-name form" do
    with_send_env(declared: ["SESSION", "CSRF"], bound: {"CSRF" => "c"}, vars: [{"HOST", "h"}]) do
      Gori::Env.unbound("Cookie: sid=$BIND.SESSION; c=$BIND.CSRF; h=$ENV.SESSION")
        .should eq(["SESSION"])
      Gori::Env.token_list(Gori::Env.unbound("sid=$BIND.SESSION"), ns: Gori::Env::Namespace::Bind)
        .should eq("$BIND.SESSION")
    end
  end
end
