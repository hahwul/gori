require "../spec_helper"
require "../support/mcp_harness"

# Frozen issue evidence over MCP (#1038). An agent that confirms a finding and then retests
# the fix is the workflow the copy exists for, so the write has to be reachable from here —
# and the read has to hand back the bytes the way get_flow does, redacted by default.

private def sent_repeater(store, body = "stack") : Int64
  rid = store.insert_repeater("https://acme.test", "GET /v1 HTTP/1.1\r\nHost: acme.test\r\nAuthorization: Bearer s3cret\r\n\r\n".to_slice,
    false, true, nil, 0)
  store.update_repeater_response(rid, "HTTP/1.1 500 Boom\r\nContent-Type: text/plain\r\n\r\n".to_slice, body.to_slice, nil, 9_i64)
  rid
end

describe "MCP frozen evidence" do
  it "freezes a flow's exchange with its link, lists it, and hands the bytes back redacted" do
    with_store do |store|
      fid = mcp_seed_flow(store, "acme.test", "POST", "/login", 200, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n", "welcome".to_slice)
      iid = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", nil)
      tools = tools_for(store)

      res = mcp_ok_json(tools, "freeze_evidence", %({"issue_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))
      res["frozen"].as_bool.should be_true
      res["linked"].as_bool.should be_true
      ev = res["evidence"]
      eid = ev["id"].as_i64
      ev["source_kind"].as_s.should eq("flow")
      ev["source_id"].as_i64.should eq(fid)
      ev["status"].as_i.should eq(200)
      ev["url"].as_s.should eq("https://acme.test/login")
      ev["request_sha256"].as_s.size.should eq(64)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, iid).map(&.ref_id).should eq([fid])

      listed = mcp_ok_json(tools, "list_evidence", %({"issue_id":#{iid}}))
      listed["total"].as_i.should eq(1)
      listed["evidence"][0]["id"].as_i64.should eq(eid)
      listed["bytes"].as_i64.should eq(ev["bytes"].as_i64)

      # get_issue carries the same provenance, so an agent reading the issue sees the copy.
      mcp_ok_json(tools, "get_issue", %({"id":#{iid}}))["evidence"][0]["id"].as_i64.should eq(eid)

      full = mcp_ok_json(tools, "get_evidence", %({"id":#{eid}}))
      full["request_head"].as_s.should start_with("POST /login HTTP/1.1")
      full["response_head"].as_s.should contain("Set-Cookie: [REDACTED]")
      full["response_body"]["text"].as_s.should eq("welcome")
      raw = mcp_ok_json(tools, "get_evidence", %({"id":#{eid},"include_sensitive":true,"body_mode":"none"}))
      raw["response_head"].as_s.should contain("Set-Cookie: sid=abc")
      raw["response_body"]["omitted"].as_bool.should be_true # body_mode:none — shape only, like get_flow
      raw["response_body"]["text"]?.should be_nil
    end
  end

  it "freezes a Repeater's current response, which its next send then cannot change" do
    with_store do |store|
      rid = sent_repeater(store)
      iid = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      tools = tools_for(store)
      eid = mcp_ok_json(tools, "freeze_evidence",
        %({"issue_id":#{iid},"ref_kind":"repeater","ref_id":#{rid},"link":false}))["evidence"]["id"].as_i64
      store.list_links(Gori::Store::LinkOwnerKind::Issue, iid).should be_empty
      store.update_repeater_response(rid, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "fixed".to_slice, nil, 5_i64)

      full = mcp_ok_json(tools, "get_evidence", %({"id":#{eid}}))
      full["status"].as_i.should eq(500)
      full["response_body"]["text"].as_s.should eq("stack")
      full["request_head"].as_s.should contain("Authorization: [REDACTED]")
    end
  end

  it "refuses a never-sent tab, a fuzz ref, an unknown issue, and the quota — writing nothing" do
    with_store do |store|
      never = store.insert_repeater("https://acme.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      iid = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      tools = tools_for(store)

      r = tools.call("freeze_evidence", JSON.parse(%({"issue_id":#{iid},"ref_kind":"repeater","ref_id":#{never}})))
      r.is_error.should be_true
      r.text.should contain("never been sent")

      r = tools.call("freeze_evidence", JSON.parse(%({"issue_id":#{iid},"ref_kind":"fuzz","ref_id":1})))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")

      fid = mcp_seed_flow(store)
      r = tools.call("freeze_evidence", JSON.parse(%({"issue_id":999,"ref_kind":"flow","ref_id":#{fid}})))
      r.error_code.should eq("NOT_FOUND")
      store.count_evidence.should eq(0)
    end
  end

  it "deletes one copy, and only that one" do
    with_store do |store|
      rid = sent_repeater(store)
      iid = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      tools = tools_for(store)
      a = mcp_ok_json(tools, "freeze_evidence", %({"issue_id":#{iid},"ref_kind":"repeater","ref_id":#{rid}}))["evidence"]["id"].as_i64
      b = mcp_ok_json(tools, "freeze_evidence", %({"issue_id":#{iid},"ref_kind":"repeater","ref_id":#{rid}}))["evidence"]["id"].as_i64
      mcp_ok_json(tools, "delete_evidence", %({"id":#{a}}))["deleted"].as_bool.should be_true
      mcp_ok_json(tools, "list_evidence", %({"issue_id":#{iid}}))["evidence"].as_a.map(&.["id"].as_i64).should eq([b])
      tools.call("delete_evidence", JSON.parse(%({"id":#{a}}))).error_code.should eq("NOT_FOUND")
    end
  end

  it "gates the two writes under --read-only and leaves the two reads open" do
    with_store do |store|
      iid = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      fid = mcp_seed_flow(store)
      ro = tools_for(store, allow_actions: false)
      ro.call("freeze_evidence", JSON.parse(%({"issue_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))).error_code.should eq("TOOL_DISABLED")
      ro.call("delete_evidence", JSON.parse(%({"id":1}))).error_code.should eq("TOOL_DISABLED")
      mcp_ok_json(ro, "list_evidence", %({"issue_id":#{iid}}))["total"].as_i.should eq(0)
      store.count_evidence.should eq(0)
    end
  end
end
