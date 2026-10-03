require "../spec_helper"

# The MCP half of the #123 live-intercept bridge client: the bridge read, the liveness gate,
# the held-item lookup and the enqueue-then-poll round trip, with the outcome each one maps
# to. `gori run intercept` drives the same bridge; this pins what an agent sees.

private def publish_bridge(store : Gori::Store, *, heartbeat_ms : Int64? = Time.utc.to_unix_ms,
                           capturing : Bool = true, token : String = "sess-1",
                           filter : String = "host:a.test") : Nil
  h = {
    "capturing" => JSON::Any.new(capturing), "enabled" => JSON::Any.new(true),
    "direction" => JSON::Any.new("request"), "filter" => JSON::Any.new(filter),
    "session_token" => JSON::Any.new(token),
  }
  heartbeat_ms.try { |hb| h["heartbeat_ms"] = JSON::Any.new(hb) }
  store.set_intercept_bridge(h.to_json)
end

private def hold(store : Gori::Store, item_id : Int64, token : String = "sess-1") : Nil
  store.publish_intercept_held(token, [
    Gori::Store::HeldRow.new(token, item_id, "request", "GET", "a.test", 80, "http", "/x",
      "GET /x HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, 0_i64),
  ])
end

# Answer the first queued command the way a capturing TUI would.
private def ack_first(store : Gori::Store, status : String, detail : String?) : Nil
  spawn do
    200.times do
      if row = store.intercept_commands_after(0_i64, 10).first?
        store.ack_intercept_command(row.id, status, detail)
        break
      end
      sleep 5.milliseconds
    end
  end
end

private def viewed_ms(store : Gori::Store, token : String = "sess-1") : Hash(Int64, Int64)
  store.intercept_viewed_ms(token)
end

describe "MCP intercept_list" do
  it "says no bridge is published rather than listing an empty queue" do
    with_store do |store|
      r = tools_for(store).call("intercept_list", JSON.parse("{}"))
      r.is_error.should be_false
      out = JSON.parse(r.text)
      out.as_h.keys.should eq(%w[available reason])
      out["available"].as_bool.should be_false
      out["reason"].as_s.should eq("no capturing gori instance is publishing intercept state (open the project's TUI to intercept)")
    end
  end

  it "reports the bridge state and the held items, in a fixed shape" do
    with_store do |store|
      publish_bridge(store)
      hold(store, 4_i64)
      out = JSON.parse(tools_for(store).call("intercept_list", JSON.parse("{}")).text)
      out.as_h.keys.should eq(%w[available capturing enabled direction filter heartbeat_age_seconds pending_count items])
      out["capturing"].as_bool.should be_true
      out["enabled"].as_bool.should be_true
      out["direction"].as_s.should eq("request")
      out["filter"].as_s.should eq("host:a.test")
      out["heartbeat_age_seconds"].as_i64.should be >= 0
      out["pending_count"].as_i.should eq(1)
      out["items"][0]["item_id"].as_i64.should eq(4)
    end
  end

  it "reads a stale heartbeat as not capturing, and a missing one as no age" do
    with_store do |store|
      publish_bridge(store, heartbeat_ms: Time.utc.to_unix_ms - 60_000)
      JSON.parse(tools_for(store).call("intercept_list", JSON.parse("{}")).text)["capturing"].as_bool.should be_false

      publish_bridge(store, heartbeat_ms: nil)
      out = JSON.parse(tools_for(store).call("intercept_list", JSON.parse("{}")).text)
      out["capturing"].as_bool.should be_false
      out["heartbeat_age_seconds"].raw.should be_nil
    end
  end

  it "stamps viewed_ms only when this server could act on the hold" do
    with_store do |store|
      publish_bridge(store)
      hold(store, 4_i64)
      tools_for(store, allow_actions: false).call("intercept_list", JSON.parse("{}"))
      viewed_ms(store)[4_i64].should eq(0)
      tools_for(store).call("intercept_list", JSON.parse("{}"))
      viewed_ms(store)[4_i64].should be > 0
    end
  end
end

describe "MCP intercept_get" do
  it "names a missing bridge and a released item as NOT_FOUND" do
    with_store do |store|
      r = tools_for(store).call("intercept_get", JSON.parse(%({"item_id":4})))
      r.error_code.should eq("NOT_FOUND")
      r.text.should eq("no capturing gori instance is publishing intercept state")

      publish_bridge(store)
      r = tools_for(store).call("intercept_get", JSON.parse(%({"item_id":4})))
      r.error_code.should eq("NOT_FOUND")
      r.text.should eq("held item 4 is not currently held (already forwarded/dropped, or never held)")
    end
  end

  it "returns the held item and stamps it" do
    with_store do |store|
      publish_bridge(store)
      hold(store, 4_i64)
      r = tools_for(store).call("intercept_get", JSON.parse(%({"item_id":4})))
      r.is_error.should be_false
      JSON.parse(r.text)["item_id"].as_i64.should eq(4)
      viewed_ms(store)[4_i64].should be > 0
    end
  end
end

describe "MCP intercept write verbs" do
  it "refuses up front when no live instance is draining commands" do
    with_store do |store|
      r = tools_for(store).call("intercept_forward", JSON.parse(%({"item_id":4})))
      r.error_code.should eq("PROJECT_BUSY")
      r.retryable.should be_true
      r.text.should eq("no live capturing gori instance is draining intercept commands (open the project's TUI with intercept on)")

      publish_bridge(store, heartbeat_ms: Time.utc.to_unix_ms - 60_000)
      tools_for(store).call("intercept_forward", JSON.parse(%({"item_id":4}))).error_code.should eq("PROJECT_BUSY")
      store.intercept_commands_after(0_i64, 10).should be_empty
    end
  end

  it "enqueues under the bridge's session token and reports the ack" do
    with_store do |store|
      publish_bridge(store)
      ack_first(store, "forwarded", "GET /x")
      r = tools_for(store).call("intercept_forward", JSON.parse(%({"item_id":4})))
      r.is_error.should be_false
      r.text.should eq(%({"status":"forwarded","detail":"GET /x"}))
      cmd = store.intercept_commands_after(0_i64, 10).first
      cmd.session_token.should eq("sess-1")
      cmd.verb.should eq("forward")
      cmd.item_id.should eq(4)
    end
  end

  it "maps each terminal ack to its own result" do
    {
      {"intercept_drop", %({"item_id":4}), "dropped", "d", nil, %({"status":"dropped","detail":"d"})},
      {"intercept_toggle", %({"enable":true}), "toggled", "on", nil, %({"status":"toggled","detail":"on"})},
      {"intercept_set_filter", %({"query":""}), "filter_set", nil, nil, %({"status":"filter_set","detail":null})},
      {"intercept_forward", %({"item_id":4}), "no_such_item", nil, "NOT_FOUND",
       "the held item is no longer held (already forwarded/dropped)"},
      {"intercept_forward", %({"item_id":4}), "stale", "old session", "SESSION_CHANGED", "old session"},
      {"intercept_forward", %({"item_id":4}), "error", "boom", "INTERNAL", "intercept command error: boom"},
    }.each do |(tool, args, status, detail, code, text)|
      with_store do |store|
        publish_bridge(store)
        ack_first(store, status, detail)
        r = tools_for(store).call(tool, JSON.parse(args))
        r.error_code.should eq(code)
        r.text.should eq(text)
      end
    end
  end

  # Not refused: the direction can change after the condition is set. The note rides beside the ack.
  it "notes a status: condition, or a requests-only direction under one, without refusing it" do
    with_store do |store|
      publish_bridge(store) # direction: request
      ack_first(store, "filter_set", "status:>=500")
      r = tools_for(store).call("intercept_set_filter", JSON.parse(%({"query":"status:>=500"})))
      r.is_error.should be_false
      json = JSON.parse(r.text)
      json["status"].should eq("filter_set")
      json["note"].as_s.should contain("`status:` only matches responses")
    end
    with_store do |store|
      publish_bridge(store, filter: "status:>=500")
      ack_first(store, "direction_set", "requestonly")
      r = tools_for(store).call("intercept_set_direction", JSON.parse(%({"direction":"request"})))
      JSON.parse(r.text)["note"].as_s.should contain("intercept_set_direction")
    end
    with_store do |store|
      publish_bridge(store, filter: "status:>=500")
      ack_first(store, "direction_set", "both")
      r = tools_for(store).call("intercept_set_direction", JSON.parse(%({"direction":"both"})))
      r.text.should eq(%({"status":"direction_set","detail":"both"}))
    end
  end

  it "gives up after the poll budget with a retryable NOT_CONFIRMED" do
    with_store do |store|
      publish_bridge(store)
      r = tools_for(store).call("intercept_forward", JSON.parse(%({"item_id":4})))
      r.error_code.should eq("NOT_CONFIRMED")
      r.retryable.should be_true
      r.text.should eq("intercept command not confirmed within 3000ms — the capturing instance may be busy; retry")
    end
  end
end
