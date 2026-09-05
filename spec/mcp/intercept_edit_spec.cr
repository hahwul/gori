require "../spec_helper"
require "../support/mcp_harness"

# Publish the bridge blob a capturing TUI would, so the intercept write verbs enqueue for
# real, and auto-ack the first queued command so the tool returns without its 3s poll.
private def with_live_intercept(store, &)
  store.set_intercept_bridge({
    "capturing" => true, "enabled" => true, "direction" => "both", "filter" => "",
    "session_token" => "sess-1", "heartbeat_ms" => Time.utc.to_unix_ms,
  }.to_json)
  spawn do
    120.times do
      if row = store.intercept_commands_after(0_i64, 10).first?
        store.ack_intercept_command(row.id, "edited", "ok")
        break
      end
      sleep 5.milliseconds
    end
  end
  yield
end

# The bytes actually handed to the capturing instance — the only thing that matters here.
private def queued_intercept_bytes(store) : Bytes
  store.intercept_commands_after(0_i64, 10).first.bytes.not_nil!
end

# Seeds a real intercept_held row (session_token "sess-1", matching `with_live_intercept`'s
# bridge) so `intercept_forward_edit` can actually see the item's `kind`/`binary` BEFORE it
# picks a normalization rule — the thing round 9's F1 found missing entirely.
private def seed_held_ws(store, item_id : Int64 = 1_i64, *, raw : Bytes, binary : Bool = false,
                         kind : String = "wsout") : Nil
  store.publish_intercept_held("sess-1", [
    Gori::Store::HeldRow.new("sess-1", item_id, kind, "GET", "127.0.0.1", 20602, "http",
      "http://127.0.0.1:20602/chat", raw, 0_i64, binary: binary),
  ])
end

describe "MCP intercept_forward_edit" do
  it "forwards a binary body from raw_base64 byte-for-byte" do
    with_store do |store|
      # A PNG-ish body holding a bare LF and a non-UTF-8 octet: neither survives a JSON
      # string, and the old whole-message CRLF gsub rewrote the 0x0A into 0x0D 0x0A.
      body = Bytes[0x89, 0x50, 0x4e, 0x47, 0x0a, 0xff]
      wire = IO::Memory.new
      wire.print "POST /upload HTTP/1.1\r\nHost: acme.test\r\nContent-Length: #{body.size}\r\n\r\n"
      wire.write body

      with_live_intercept(store) do
        r = tools_for(store).call("intercept_forward_edit",
          JSON.parse(%({"item_id":1,"raw_base64":"#{Base64.strict_encode(wire.to_slice)}"})))
        r.is_error.should be_false
      end

      queued = queued_intercept_bytes(store)
      # `Env.head_body_separator` — the one scanner. The `+ 4` this used to hard-code beside
      # a CRLFCRLF-only scan is the bug `head_and_body` carried; take the width from the
      # scanner so the assertion holds whichever spelling terminates the head.
      offset, width = Gori::Env.head_body_separator(queued).not_nil!
      queued[(offset + width)..].should eq body # untouched, 0x0A and 0xFF included
    end
  end

  it "normalizes CRLF in raw's HEADER block but never in its body" do
    with_store do |store|
      with_live_intercept(store) do
        # Hand-typed LF-only head (must still frame) with an LF-separated text body (must not
        # grow — rewriting it is what desyncs a Content-Length and corrupts non-text bodies).
        raw = "POST /a HTTP/1.1\\nHost: acme.test\\n\\nline1\\nline2"
        tools_for(store).call("intercept_forward_edit",
          JSON.parse(%({"item_id":1,"raw":"#{raw}"}))).is_error.should be_false
      end

      String.new(queued_intercept_bytes(store))
        .should eq "POST /a HTTP/1.1\r\nHost: acme.test\r\nContent-Length: 11\r\n\r\nline1\nline2"
    end
  end

  it "rejects raw and raw_base64 together instead of silently picking one" do
    with_store do |store|
      r = tools_for(store).call("intercept_forward_edit",
        JSON.parse(%({"item_id":1,"raw":"GET / HTTP/1.1\\r\\n\\r\\n","raw_base64":"R0VUIC8gSFRUUC8xLjENCg0K"})))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.text.should contain "only one"
    end
  end

  it "rejects invalid base64 with an actionable message" do
    with_store do |store|
      r = tools_for(store).call("intercept_forward_edit", JSON.parse(%({"item_id":1,"raw_base64":"!!!not base64!!!"})))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.field.should eq "raw_base64"
    end
  end

  it "still requires one of the two" do
    with_store do |store|
      r = tools_for(store).call("intercept_forward_edit", JSON.parse(%({"item_id":1})))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.field.should eq "raw"
    end
  end
end

# R9/F1 — `intercept_forward_edit`'s `raw` channel ran EVERY held item through
# `RequestBuilder.normalize_raw`, a rule written for an HTTP head (find the first blank line,
# CRLF-promote bare LF before it). A WebSocket message has no such boundary at all, so with none
# found the WHOLE payload was treated as "header" and every bare LF promoted — an unedited
# 17-byte round trip reached the origin as 19 bytes. Control run at 838f55a3 (before this fix):
# `Gori::MCP::RequestBuilder.normalize_raw("line1\nline2\nline3")` produces
# `"line1\r\nline2\r\nline3"` (19 bytes) for the exact input this spec pins byte-exact at 17.
describe "MCP intercept_forward_edit — WebSocket byte provenance (R9/F1)" do
  it "takes a WS text edit's 'raw' LITERALLY — no CRLF promotion, even with bare LF and no boundary" do
    with_store do |store|
      payload = "line1\nline2\nline3"
      seed_held_ws(store, raw: payload.to_slice)
      with_live_intercept(store) do
        r = tools_for(store).call("intercept_forward_edit", JSON.parse({"item_id" => 1, "raw" => payload}.to_json))
        r.is_error.should be_false
      end
      String.new(queued_intercept_bytes(store)).should eq(payload) # bare LF preserved, 17 bytes
    end
  end

  it "is unchanged when the WS edit has no LF at all (the complement)" do
    with_store do |store|
      payload = "no-newlines-here"
      seed_held_ws(store, raw: payload.to_slice)
      with_live_intercept(store) do
        tools_for(store).call("intercept_forward_edit",
          JSON.parse({"item_id" => 1, "raw" => payload}.to_json)).is_error.should be_false
      end
      String.new(queued_intercept_bytes(store)).should eq(payload)
    end
  end

  it "never resyncs Content-Length for a WS item, even when the payload contains a literal blank line" do
    with_store do |store|
      payload = "part1\n\npart2" # looks like it has an HTTP boundary — must not matter for WS
      seed_held_ws(store, raw: payload.to_slice)
      with_live_intercept(store) do
        r = tools_for(store).call("intercept_forward_edit", JSON.parse({"item_id" => 1, "raw" => payload}.to_json))
        r.is_error.should be_false
        JSON.parse(r.text)["content_length_synced"].as_bool.should be_false
      end
      String.new(queued_intercept_bytes(store)).should eq(payload)
    end
  end

  it "still CRLF-normalizes an ordinary HTTP head's raw edit — the WS branch must not leak" do
    with_store do |store|
      seed_held_ws(store, raw: "GET / HTTP/1.1\r\n\r\n".to_slice, kind: "request")
      with_live_intercept(store) do
        raw = "POST /a HTTP/1.1\nHost: acme.test\n\nline1\nline2"
        tools_for(store).call("intercept_forward_edit",
          JSON.parse({"item_id" => 1, "raw" => raw}.to_json)).is_error.should be_false
      end
      String.new(queued_intercept_bytes(store))
        .should eq "POST /a HTTP/1.1\r\nHost: acme.test\r\nContent-Length: 11\r\n\r\nline1\nline2"
    end
  end

  it "refuses 'raw' for a WS BINARY frame, pointing at raw_base64, and never touches the queue" do
    with_store do |store|
      seed_held_ws(store, raw: Bytes[0xFF, 0xFE, 0x01, 0x02], binary: true)
      # The refusal is decided from the held row's `binary?` flag alone — it fires before `raw`
      # is even inspected, so a plain ASCII edit is enough to prove the gate is there. Needs the
      # bridge published so `held_row_for_edit` can find the row at all — without it, the item
      # is invisible and this would fail for the WRONG reason (PROJECT_BUSY, no live capturing
      # instance) rather than the refusal under test. No `with_live_intercept` here: nothing is
      # ever enqueued on this path, so its auto-ack fiber would just poll past this block.
      store.set_intercept_bridge({
        "capturing" => true, "enabled" => true, "direction" => "both", "filter" => "",
        "session_token" => "sess-1", "heartbeat_ms" => Time.utc.to_unix_ms,
      }.to_json)
      r = tools_for(store).call("intercept_forward_edit", JSON.parse({"item_id" => 1, "raw" => "anything"}.to_json))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.text.should contain "raw_base64"
      store.intercept_commands_after(0_i64, 10).should be_empty # never enqueued
    end
  end

  it "still allows raw_base64 byte-exact on a WS BINARY frame" do
    with_store do |store|
      body = Bytes[0xFF, 0xFE, 0x01, 0x02]
      seed_held_ws(store, raw: body, binary: true)
      with_live_intercept(store) do
        r = tools_for(store).call("intercept_forward_edit",
          JSON.parse({"item_id" => 1, "raw_base64" => Base64.strict_encode(body)}.to_json))
        r.is_error.should be_false
      end
      queued_intercept_bytes(store).should eq(body)
    end
  end
end
