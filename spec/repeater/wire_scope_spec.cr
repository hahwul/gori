require "../spec_helper"

private class WireScopeBindings < Gori::Env::Layer
  def declared : Array(String)
    ["PATH"]
  end

  def values : Hash(String, String)
    {"PATH" => "admin"}
  end

  def rev : UInt64
    1_u64
  end
end

# An include written for the authored `$BIND.PATH` text must not admit the path the binding
# resolves to: Layer 1 is asked about the request-target the socket gets.
private def wire_scope_plan(store : Gori::Store, requests : Array(Bytes)) : Gori::Repeater::Plan
  Gori::Env.layer = WireScopeBindings.new
  scope = Gori::Scope.load(store)
  scope.add("include", "string", "/$BIND.PATH")
  Gori::Repeater::Plan.build(
    Gori::Repeater::PlanOptions.new(requests, target: "http://127.0.0.1:1/", expand_request: false),
    Gori::Outbound.agent(scope, false))
end

describe "Repeater scope checks at the final wire seam" do
  it "predicts the bound target for the up-front gate without wiring" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      with_store_env do |store|
        plan = wire_scope_plan(store, ["GET /$BIND.PATH HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice])
        String.new(plan.scope_requests.first).should start_with("GET /admin HTTP/1.1")
        plan.refusal.should be_nil # Layer 2 is unaffected: no sandbox, no exclude
      end
    end
  end

  it "refuses a bound path outside scope before dialing" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      with_store_env do |store|
        plan = wire_scope_plan(store, ["GET /$BIND.PATH HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice])
        wire = plan.wire_bytes
        String.new(wire).should start_with("GET /admin HTTP/1.1")
        plan.send_wire(wire).error.to_s.should start_with(Gori::Repeater::Sender::SCOPE_REFUSAL_PREFIX)
      end
    end
  end

  it "refuses every member of a race when one final target is outside scope" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      with_store_env do |store|
        plan = wire_scope_plan(store, [
          "GET /$BIND.PATH HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
          "GET /$BIND.PATH?second=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
        ])
        results = plan.send_race
        results.size.should eq(2)
        results.each { |r| r.error.to_s.should start_with(Gori::Repeater::Sender::SCOPE_REFUSAL_PREFIX) }
      end
    end
  end
end
