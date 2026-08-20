require "../spec_helper"

# `send_request{record_history:true}` must record THE REQUEST THAT WENT OUT.
#
# The tool's own comment states the invariant ("before the scope gate + History write so the
# recorded/effective request == the wire"), and it held for everything the plan builder does.
# It did not hold for the SEND SEAM — `Sender#send`'s `$NAME` binding pass and the ACTIVE
# SESSION SLOT's header overlay ran inside `plan.send`, out of sight of the recorder, which
# wrote `plan.bytes`: the draft the seam started from.
#
# So a send made as slot `admin` reached the origin with `Authorization: Bearer …` and was
# recorded without it. That flow is then the agent's evidence — the id it hands to
# `get_flow`, `compare_flows`, `probe_scan`, or a fuzz seed — and every one of them was
# reading a request nobody sent, missing exactly the identity that produced the response
# beside it.
#
# The origin here keeps the bytes it actually received, so the assertion is the invariant
# itself rather than a restatement of the fix: recorded head == received head.

private def with_store(&)
  path = File.tempname("gori-rechist", ".db")
  store = Gori::Store.open(path)
  prev_layer = Gori::Env.layer
  begin
    yield store
  ensure
    Gori::Env.layer = prev_layer
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# An origin that answers 200 and hands back every request head it read.
private def with_recording_origin(&)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = [] of String
  spawn do
    while conn = server.accept?
      if head = Gori::Proxy::Codec::Http1.read_head(conn)
        seen << String.new(head)
      end
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
      conn.flush rescue nil
      conn.close rescue nil
    end
  end
  begin
    yield port, seen
  ensure
    server.close
  end
end

private def drive(store, *lines) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

private def tool_payload(resp : JSON::Any) : JSON::Any
  JSON.parse(resp["result"]["content"][0]["text"].as_s)
end

private def call(tool : String, args : String, id : Int32 = 1) : String
  %({"jsonrpc":"2.0","id":#{id},"method":"tools/call","params":{"name":"#{tool}","arguments":#{args}}})
end

describe "MCP send_request(record_history) records the wire" do
  it "keeps the active session slot's header in the recorded flow" do
    with_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.save([Gori::SessionSlot.new("admin",
        set_headers: [{"Authorization", "Bearer ADMIN-TOKEN"}])])
      with_recording_origin do |port, seen|
        res = drive(store,
          call("set_active_session_slot", %({"name":"admin"}), 1),
          call("send_request",
            %({"url":"http://127.0.0.1:#{port}/me","method":"GET",) +
            %("record_history":true,"allow_unscoped":true}), 2))
        payload = tool_payload(res[1])
        flow_id = payload["recorded_flow_id"].as_i64
        detail = store.get_flow(flow_id).not_nil!
        head = String.new(detail.request_head)

        seen.size.should eq(1)
        head.should contain("Authorization: Bearer ADMIN-TOKEN")
        # The invariant, not just the symptom: what History holds is what the origin read.
        head.should eq(seen[0])
      end
    end
  end
end
