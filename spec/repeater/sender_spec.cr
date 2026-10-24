require "../spec_helper"

# Answers the first request on each connection, then closes it: a pipeline's second member
# fails and every member after it is skipped, never written.
private def answer_once_origin : {TCPServer, Int32}
  srv = TCPServer.new("127.0.0.1", 0)
  spawn do
    while conn = srv.accept?
      c = conn
      spawn do
        if Gori::Proxy::Codec::Http1.read_head(c)
          c << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
          c.flush
        end
      rescue
      ensure
        c.close rescue nil
      end
    end
  end
  {srv, srv.local_address.port}
end

private def budget_plan(store : Gori::Store, requests : Array(Bytes), port : Int32) : Gori::Repeater::Plan
  store.set_settings([{Gori::Settings::PROJECT_OUTBOUND_MAX_REQUESTS_KEY, "10"}] of {String, String?})
  Gori::Repeater::Plan.build(
    Gori::Repeater::PlanOptions.new(requests, target: "http://127.0.0.1:#{port}/", expand_request: false),
    Gori::Outbound.agent(Gori::Scope.load(store), true))
end

private def spent(store : Gori::Store) : String?
  Gori::Outbound::Budget.release(store)
  store.setting(Gori::Store::OUTBOUND_BUDGET_SPENT_KEY)
end

private REQ = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice

# A group takes one project-budget slot per member up front; a member that never went out
# hands its slot back.
describe "Repeater::Sender group sends and the project budget" do
  it "refunds the pipeline members skipped after the connection died" do
    with_store do |store|
      srv, port = answer_once_origin
      results = budget_plan(store, [REQ, REQ, REQ, REQ], port).send_group
      srv.close
      results.count(&.error.== Gori::Repeater::Engine::PIPELINE_SKIPPED).should eq(2)
      spent(store).should eq("2") # was 4
    end
  end

  it "refunds the race members withdrawn for too few live connections" do
    with_store do |store|
      srv, port = answer_once_origin
      # The short member cannot hold back a byte, so only one connection is live.
      results = budget_plan(store, [REQ, "X".to_slice], port).send_race
      srv.close
      results[0].error.to_s.should start_with(Gori::Repeater::Engine::RACE_UNDERFILLED)
      spent(store).should eq("1") # was 2
    end
  end
end
