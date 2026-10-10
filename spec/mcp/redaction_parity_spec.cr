require "../spec_helper"
require "../support/mcp_harness"

# One flow, every read tool: a value `get_flow` withholds must not come back in clear from a
# sibling that reads the same bytes — a decoded projection, a History column, a diff, a frozen
# copy or the exact-byte pager.

private JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhbGljZSJ9.c2lnbmF0dXJlLWJ5dGVz"

private def authed_flow(store, token : String, cookie : String = "sid=s1", secret : String = token) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
    method: "GET", target: "/me", http_version: "HTTP/1.1",
    head: "GET /me HTTP/1.1\r\nHost: h.test\r\nAuthorization: Bearer #{token}\r\nCookie: #{cookie}\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
    body: %({"token":"body-secret-#{secret}"}).to_slice, content_type: "application/json"))
  id
end

private def with_redacting_project(&)
  with_store do |store|
    before = Gori::Redact.salt
    Gori::Redact.salt = "spec-salt"
    Gori::Redact::Policy.write_project_scope(store,
      Gori::Redact::Policy::ProjectScope.new(default: true))
    begin
      yield store
    ensure
      Gori::Redact.salt = before
    end
  end
end

describe "MCP read tools redact what get_flow redacts" do
  it "keeps a header-sourced JWT out of get_flow's decoded projection" do
    with_store do |store|
      id = authed_flow(store, JWT, secret: "x")
      payload = mcp_ok_json(tools_for(store), "get_flow", %({"id":#{id}}))
      payload.to_json.should_not contain(JWT)
      payload["request_head"].as_s.should contain("Authorization: [REDACTED]")
      opened = mcp_ok_json(tools_for(store), "get_flow", %({"id":#{id},"include_sensitive":true}))
      opened["jwt"].as_a.map(&.["token"].as_s).should contain(JWT)
    end
  end

  it "masks a sensitive list_history column unless include_sensitive" do
    with_store do |store|
      authed_flow(store, "tok-1")
      args = %({"columns":["req:header:authorization","req:cookie:sid","res:header:content-type"]})
      row = mcp_ok_json(tools_for(store), "list_history", args)["flows"][0]
      row["columns"]["authorization"].as_s.should eq("[REDACTED]")
      row["columns"]["sid"].as_s.should eq("[REDACTED]")
      row["columns"]["content-type"].as_s.should eq("application/json")
      open = %({"columns":["req:header:authorization"],"include_sensitive":true})
      mcp_ok_json(tools_for(store), "list_history", open)["flows"][0]["columns"]["authorization"].as_s
        .should eq("Bearer tok-1")
    end
  end

  it "masks the columns of an ids listing too" do
    with_store do |store|
      id = authed_flow(store, "tok-1")
      args = %({"ids":[#{id}],"columns":["req:header:authorization"]})
      mcp_ok_json(tools_for(store), "list_history", args)["flows"][0]["columns"]["authorization"].as_s
        .should eq("[REDACTED]")
    end
  end

  it "reads list_history body columns from the redacted copy unless include_sensitive" do
    with_redacting_project do |store|
      id = authed_flow(store, "A")
      tools = tools_for(store)
      args = %({"ids":[#{id}],"columns":["jsonpath:token","res:regex:(body-secret-[A-Z]+)"]})
      mcp_ok_json(tools, "list_history", args).to_json.should_not contain("body-secret-A")
      mcp_ok_json(tools, "list_history", %({"columns":["jsonpath:token"]})).to_json.should_not contain("body-secret-A")
      open = %({"ids":[#{id}],"columns":["jsonpath:token"],"include_sensitive":true})
      mcp_ok_json(tools, "list_history", open)["flows"][0]["columns"]["token"].as_s.should eq("body-secret-A")
    end
  end

  it "decides compare_flows' verdict on the captured credentials, not the redacted copy" do
    with_store do |store|
      a = authed_flow(store, "ALICE", "sid=alice")
      b = authed_flow(store, "BOB", "sid=bob")
      res = mcp_ok_json(tools_for(store), "compare_flows", %({"flow_id_a":#{a},"flow_id_b":#{b},"pane":"request"}))
      res["identical"].as_bool.should be_false
      res["changed_lines"].as_i.should eq(4)
      text = res["diff"].as_a.map { |d| d["text"]?.try(&.as_s) || "" }
      text.join("\n").should_not contain("ALICE")
      text.join("\n").should_not contain("bob")
      res["diff"].as_a.count { |d| d["kind"].as_s == "del" }.should eq(2)
      res["diff"].as_a.select { |d| d["kind"].as_s == "add" }.map(&.["text"].as_s)
        .should contain("Authorization: [REDACTED]")
    end
  end

  it "applies the project's body redaction to compare_flows and get_evidence" do
    with_redacting_project do |store|
      a = authed_flow(store, "A")
      b = authed_flow(store, "B")
      tools = tools_for(store)
      mcp_ok_json(tools, "get_flow", %({"id":#{a}})).to_json.should_not contain("body-secret-A")
      cmp = mcp_ok_json(tools, "compare_flows", %({"flow_id_a":#{a},"flow_id_b":#{b}}))
      cmp.to_json.should_not contain("body-secret-")
      cmp["body_redaction"]?.should_not be_nil
      cmp["diff_of_redacted_copies"].as_bool.should be_true
      # Two different secrets are still two different lines.
      cmp["identical"].as_bool.should be_false
      iid = store.insert_issue("x", Gori::Store::Severity::Low, "h.test", nil)
      eid = mcp_ok_json(tools, "freeze_evidence", %({"issue_id":#{iid},"ref_kind":"flow","ref_id":#{a}}))["evidence"]["id"].as_i64
      ev = mcp_ok_json(tools, "get_evidence", %({"id":#{eid}}))
      ev.to_json.should_not contain("body-secret-A")
      ev["body_redaction"]?.should_not be_nil
    end
  end

  it "stops get_response_body_chunk's raw page before a sensitive trailer" do
    with_store do |store|
      body = "3\r\nabc\r\n0\r\nSet-Cookie: sid=TRAILERSECRET\r\n\r\n"
      id = mcp_seed_flow(store, "h.test", "GET", "/t", 200,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", body.to_slice)
      tools = tools_for(store)
      page = mcp_ok_json(tools, "get_response_body_chunk", %({"flow_id":#{id},"raw":true}))
      page["text"].as_s.should eq("3\r\nabc\r\n0\r\n")
      page["trailers_omitted"].as_bool.should be_true
      open = mcp_ok_json(tools, "get_response_body_chunk", %({"flow_id":#{id},"raw":true,"include_sensitive":true}))
      open["text"].as_s.should eq(body)
      decoded = mcp_ok_json(tools, "get_response_body_chunk", %({"flow_id":#{id}}))
      decoded["text"].as_s.should eq("abc")
      decoded["trailers_omitted"]?.should be_nil
    end
  end

  it "pages a trailer that carries nothing sensitive" do
    with_store do |store|
      body = "3\r\nabc\r\n0\r\nX-Checksum: 1\r\n\r\n"
      id = mcp_seed_flow(store, "h.test", "GET", "/t", 200,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", body.to_slice)
      page = mcp_ok_json(tools_for(store), "get_response_body_chunk", %({"flow_id":#{id},"raw":true}))
      page["text"].as_s.should eq(body)
      page["trailers_omitted"]?.should be_nil
    end
  end
end
