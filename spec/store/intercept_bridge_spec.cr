require "../spec_helper"

# The client half of the #123 live-intercept bridge — what `gori run intercept` and MCP's
# intercept_* tools both drive (#1463 moved it here from the two surfaces).

private def held_row(item_id : Int64, token : String = "tok") : Gori::Store::HeldRow
  Gori::Store::HeldRow.new(token, item_id, "request", "GET", "a.test", 80, "http", "/x",
    "GET /x HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, 0_i64)
end

describe "Gori::Store#intercept_bridge_state" do
  it "returns nil when no bridge has ever been published" do
    with_store do |store|
      store.intercept_bridge_state.should be_nil
    end
  end

  it "returns nil for a blob that is not a JSON object" do
    with_store do |store|
      store.set_intercept_bridge("not json")
      store.intercept_bridge_state.should be_nil
      store.set_intercept_bridge("[1,2]")
      store.intercept_bridge_state.should be_nil
    end
  end

  it "parses a published bridge and reports live for a fresh heartbeat" do
    with_store do |store|
      now = Time.utc.to_unix_ms
      store.set_intercept_bridge(%({"capturing":true,"enabled":true,"direction":"request","filter":"host:a","session_token":"tok","heartbeat_ms":#{now}}))
      bridge = store.intercept_bridge_state.not_nil!
      bridge.live?.should be_true
      bridge.enabled?.should be_true
      bridge.direction.should eq("request")
      bridge.filter.should eq("host:a")
      bridge.session_token.should eq("tok")
      bridge.heartbeat_age_seconds(now + 2_500).should eq(2)
    end
  end

  it "treats a stale heartbeat, or a blob not capturing, as not live" do
    with_store do |store|
      stale = Time.utc.to_unix_ms - 60_000
      store.set_intercept_bridge(%({"capturing":true,"session_token":"tok","heartbeat_ms":#{stale}}))
      store.intercept_bridge_state.not_nil!.live?.should be_false

      store.set_intercept_bridge(%({"capturing":false,"heartbeat_ms":#{Time.utc.to_unix_ms}}))
      store.intercept_bridge_state.not_nil!.live?.should be_false
    end
  end

  it "reads a missing or mistyped field as its default" do
    with_store do |store|
      store.set_intercept_bridge(%({"enabled":"yes","direction":7,"session_token":3}))
      bridge = store.intercept_bridge_state.not_nil!
      bridge.enabled?.should be_false
      bridge.direction.should eq("both")
      bridge.filter.should eq("")
      bridge.session_token.should be_nil
      bridge.token.should eq("")
      bridge.heartbeat_age_seconds(Time.utc.to_unix_ms).should be_nil
      bridge.live?.should be_false
    end
  end
end

describe "Gori::Store#intercept_held_items / #intercept_held_item" do
  it "reads the bridge session's held rows" do
    with_store do |store|
      store.set_intercept_bridge(%({"session_token":"tok"}))
      store.publish_intercept_held("tok", [held_row(3_i64), held_row(5_i64)])
      bridge = store.intercept_bridge_state.not_nil!
      store.intercept_held_items(bridge).map(&.item_id).should eq([3_i64, 5_i64])
      store.intercept_held_item(bridge, 5_i64).not_nil!.item_id.should eq(5)
      store.intercept_held_item(bridge, 4_i64).should be_nil
    end
  end

  it "holds nothing for a bridge that published no token" do
    with_store do |store|
      store.publish_intercept_held("", [held_row(3_i64, "")])
      store.set_intercept_bridge(%({"capturing":true}))
      bridge = store.intercept_bridge_state.not_nil!
      store.intercept_held_items(bridge).should be_empty
      store.intercept_held_item(bridge, 3_i64).should be_nil
    end
  end
end

describe "Gori::Store#send_intercept_command" do
  it "refuses without enqueuing when nothing live would drain the command" do
    with_store do |store|
      store.send_intercept_command("forward", item_id: 1_i64).should eq(Gori::Store::InterceptSendFailure::NotLive)
      store.set_intercept_bridge(%({"capturing":true,"session_token":"tok","heartbeat_ms":#{Time.utc.to_unix_ms - 60_000}}))
      store.send_intercept_command("forward", item_id: 1_i64).should eq(Gori::Store::InterceptSendFailure::NotLive)
      store.intercept_commands_after(0_i64, 10).should be_empty
    end
  end

  it "enqueues under the bridge's token and returns the terminal ack" do
    with_store do |store|
      store.set_intercept_bridge(%({"capturing":true,"session_token":"tok","heartbeat_ms":#{Time.utc.to_unix_ms}}))
      spawn do
        200.times do
          if row = store.intercept_commands_after(0_i64, 10).first?
            store.ack_intercept_command(row.id, "dropped", "GET /x")
            break
          end
          sleep 5.milliseconds
        end
      end
      outcome = store.send_intercept_command("drop", item_id: 7_i64, arg: "a")
      outcome.should eq(Gori::Store::InterceptAck.new("dropped", "GET /x"))
      cmd = store.intercept_commands_after(0_i64, 10).first
      cmd.session_token.should eq("tok")
      cmd.verb.should eq("drop")
      cmd.item_id.should eq(7)
      cmd.arg.should eq("a")
    end
  end

  it "reports a command still pending after the poll budget as unconfirmed" do
    with_store do |store|
      store.set_intercept_bridge(%({"capturing":true,"session_token":"tok","heartbeat_ms":#{Time.utc.to_unix_ms}}))
      store.send_intercept_command("forward", item_id: 1_i64, polls: 1)
        .should eq(Gori::Store::InterceptSendFailure::NotConfirmed)
      store.intercept_commands_after(0_i64, 10).size.should eq(1)
    end
  end

  it "budgets the ack wait at 3000ms" do
    Gori::Store.intercept_ack_budget_ms.should eq(3000)
  end
end
