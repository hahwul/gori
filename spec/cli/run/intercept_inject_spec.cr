require "../../spec_helper"

# `gori run intercept inject` (#1630) end to end in-process: the command's own flow and scope
# checks, the bridge round trip, and the capturing instance's side applied by
# `WS::Live.apply_command`, the call the TUI drain makes. MCP `ws_inject` sends through the
# same `Store#send_ws_inject`, so this is the cross-process path for both.

private UPGRADE = "GET /ws HTTP/1.1\r\nHost: echo.test\r\nUpgrade: websocket\r\n" \
                  "Connection: Upgrade\r\n\r\n"

private class BridgeSink < Gori::Proxy::FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

describe "gori run intercept inject" do
  it "reaches the capturing instance's socket and writes the frame there" do
    db = File.tempname("gori-ws-inject", ".db")
    store = Gori::Store.open(db)
    sink = BridgeSink.new
    to_client = IO::Memory.new
    begin
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "echo.test", port: 80, method: "GET",
        target: "/ws", http_version: "HTTP/1.1", head: UPGRADE.to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      store.set_intercept_bridge({"capturing" => true, "session_token" => "sess-cli",
                                  "heartbeat_ms" => Time.utc.to_unix_ms}.to_json)
      ctx = Gori::Proxy::WS::Context.new(host: "echo.test", port: 80, target: "/ws")
      entry = Gori::Proxy::WS::Live::Entry.new(sink, fid, ctx,
        Gori::Proxy::WS::Leg.new("out", IO::Memory.new, mask: true),
        Gori::Proxy::WS::Leg.new("in", to_client, mask: false))
      Gori::Proxy::WS::Live.register(entry)
      # The capturing instance's drain, reduced to the one command it is waiting for.
      spawn do
        400.times do
          if cmd = store.intercept_commands_after(0_i64, 10).find(&.verb.==(Gori::Store::WS_INJECT_VERB))
            Gori::Proxy::WS::Live.apply_command(store, sink, ungated_outbound, cmd) { |_| }
            break
          end
          sleep 5.milliseconds
        end
      end
      stdout_silenced do
        Gori::CLI::Run.dispatch(["intercept", "inject", fid.to_s, "--direction", "in",
                                 "--data", "pushed", "--db", db])
      end
      to_client.rewind
      h = Gori::Proxy::WS.read_header(to_client).not_nil!
      f = Gori::Proxy::WS.read_body(to_client, h).not_nil!
      {f.opcode, f.masked?, String.new(f.payload)}.should eq({Gori::Proxy::WS::OP_TEXT, false, "pushed"})
      cmd = store.intercept_commands_after(0_i64, 10).last
      store.command_status(cmd.id).should eq({"injected", "TEXT 6B server→client on flow ##{fid}"})
    ensure
      entry.try { |en| Gori::Proxy::WS::Live.unregister(en) }
      store.close
      delete_db_files(db)
    end
  end

  it "names the headless case when nothing is capturing" do
    Gori::CLI::Run.intercept_inject_refusal(Gori::Store::InterceptSendFailure::NotLive)
      .should contain("a headless `gori run capture` cannot inject")
    Gori::CLI::Run.intercept_inject_refusal(Gori::Store::InterceptSendFailure::NotConfirmed)
      .should contain("#{Gori::Store.ws_inject_ack_budget_ms}ms")
  end
end

describe "Gori::Store.parse_ws_inject_arg" do
  it "round-trips the bridge argument and refuses anything else" do
    Gori::Store.parse_ws_inject_arg(Gori::Store.ws_inject_arg("out", 9_u8)).should eq({"out", 9_u8})
    Gori::Store.parse_ws_inject_arg("sideways 1").should be_nil
    Gori::Store.parse_ws_inject_arg("in x").should be_nil
    Gori::Store.parse_ws_inject_arg(nil).should be_nil
  end
end
