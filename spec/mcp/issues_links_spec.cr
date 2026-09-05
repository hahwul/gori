require "../spec_helper"
require "../support/mcp_harness"

describe Gori::MCP::Server do
  describe "issues write tools" do
    it "creates then updates an issue (full mode)" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"SQLi in login","severity":"high","host":"app.test"}}})
        new_id = mcp_tool_payload(mcp_drive(store, create)[0])["id"].as_i64
        store.get_issue(new_id).not_nil!.severity.should eq(Gori::Store::Severity::High)

        update = %({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{new_id},"status":"confirmed","severity":"critical"}}})
        mcp_drive(store, update)[0]["result"]["isError"].as_bool.should be_false
        reloaded = store.get_issue(new_id).not_nil!
        reloaded.status.should eq(Gori::Store::Status::Confirmed)
        reloaded.severity.should eq(Gori::Store::Severity::Critical)
      end
    end

    it "creates and updates an issue with cvss auto-calculating severity" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"CVSS issue","cvss":"9.8"}}})
        new_id = mcp_tool_payload(mcp_drive(store, create)[0])["id"].as_i64
        issue = store.get_issue(new_id).not_nil!
        issue.severity.should eq(Gori::Store::Severity::Critical)
        issue.cvss.should eq("9.8")

        get_res = mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_issue","arguments":{"id":#{new_id}}}}))[0]
        get_payload = mcp_tool_payload(get_res)
        get_payload["cvss"].as_s.should eq("9.8")
        get_payload["cvss_score"].as_f.should eq(9.8)

        update = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{new_id},"cvss":"3.5"}}})
        mcp_drive(store, update)[0]["result"]["isError"].as_bool.should be_false
        reloaded = store.get_issue(new_id).not_nil!
        reloaded.severity.should eq(Gori::Store::Severity::Low)
        reloaded.cvss.should eq("3.5")

        clear = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{new_id},"cvss":""}}})
        mcp_drive(store, clear)[0]["result"]["isError"].as_bool.should be_false
        cleared = store.get_issue(new_id).not_nil!
        cleared.cvss.should be_nil

        # Can also set and clear via null
        reset_cvss = %({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{new_id},"cvss":"5.0"}}})
        mcp_drive(store, reset_cvss)[0]["result"]["isError"].as_bool.should be_false
        store.get_issue(new_id).not_nil!.cvss.should eq("5.0")

        clear_null = %({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{new_id},"cvss":null}}})
        mcp_drive(store, clear_null)[0]["result"]["isError"].as_bool.should be_false
        store.get_issue(new_id).not_nil!.cvss.should be_nil
      end
    end

    # A cvss nothing can score would land in a column the Issues list, `cvss:` queries and
    # every export read through a parser that answers nil for it — a written field the tool
    # reported success on. Refuse it at the boundary, like severity and status.
    it "refuses a cvss it cannot score, on create and on update" do
      with_store do |store|
        bad = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"nope","cvss":"very bad"}}})
        res = mcp_drive(store, bad)[0]["result"]
        res["isError"].as_bool.should be_true
        res["content"][0]["text"].as_s.should contain("invalid cvss")
        store.issues.should be_empty

        ok = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"real","cvss":9.8}}})
        id = mcp_tool_payload(mcp_drive(store, ok)[0])["id"].as_i64
        store.get_issue(id).not_nil!.cvss.should eq("9.8") # a JSON number is a score too

        worse = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{id},"cvss":"11"}}})
        upd = mcp_drive(store, worse)[0]["result"]
        upd["isError"].as_bool.should be_true
        store.get_issue(id).not_nil!.cvss.should eq("9.8") # untouched
      end
    end

    it "links a repeater on create and on a link-only update" do
      with_store do |store|
        repeater_a = store.insert_repeater("https://ex.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
        repeater_b = store.insert_repeater("https://ex.test", "GET /b HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 1)
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"linked","repeater_id":#{repeater_a}}}})
        issue_id = mcp_tool_payload(mcp_drive(store, create)[0])["id"].as_i64
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.map(&.ref_id).should contain(repeater_a)

        update = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{issue_id},"repeater_id":#{repeater_b}}}})
        mcp_drive(store, update)[0]["result"]["isError"].as_bool.should be_false
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.map(&.ref_id).should contain(repeater_b)
      end
    end

    it "rejects an unknown repeater_id without creating an issue" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x","repeater_id":999}}})
        resp = mcp_drive(store, create)[0]
        resp["result"]["isError"].as_bool.should be_true
        store.count_issues.should eq(0)
      end
    end

    it "rejects an invalid severity on create (not silently coerced to info)" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x","severity":"ultra"}}})
        resp = mcp_drive(store, create)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("invalid severity")
        store.count_issues.should eq(0)
      end
    end

    it "defaults an absent severity to info on create" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x"}}})
        new_id = mcp_tool_payload(mcp_drive(store, create)[0])["id"].as_i64
        store.get_issue(new_id).not_nil!.severity.should eq(Gori::Store::Severity::Info)
      end
    end

    it "rejects a present-but-invalid flow_id instead of silently unlinking" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x","flow_id":1.9}}})
        resp = mcp_drive(store, create)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("invalid 'flow_id'")
        store.count_issues.should eq(0)
      end
    end

    it "distinguishes a fractional id (invalid) from a missing id" do
      with_store do |store|
        bad = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":1.9}}})
        mcp_drive(store, bad)[0]["result"]["content"][0]["text"].as_s.should contain("invalid 'id'")
        missing = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{}}})
        mcp_drive(store, missing)[0]["result"]["content"][0]["text"].as_s.should contain("missing required 'id'")
      end
    end

    it "reports an error (not updated:true) when update_issue has no fields" do
      with_store do |store|
        store.insert_issue("f", Gori::Store::Severity::Info, nil, nil)
        store.flush
        id = store.issues.first.id
        upd = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{id}}}})
        resp = mcp_drive(store, upd)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("no fields to update")
      end
    end

    it "rejects write tools in read-only mode" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x"}}})
        resp = mcp_drive(store, create, allow_actions: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        store.count_issues.should eq(0)
      end
    end
  end

  describe "list_issues" do
    it "returns a paginated object (not a bare array)" do
      with_store do |store|
        store.insert_issue("a", Gori::Store::Severity::Info, nil, nil)
        store.insert_issue("b", Gori::Store::Severity::High, nil, nil)
        store.flush
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{"limit":1,"offset":1}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload.as_h.has_key?("issues").should be_true
        payload["returned"].as_i.should eq(1)
        payload["offset"].as_i.should eq(1)
        payload["total"].as_i.should eq(2)
      end
    end

    it "keeps the JSON-RPC response line valid UTF-8 when title/host/notes carry a raw invalid byte" do
      # Same captured-data-can-be-invalid-UTF-8 gap as Issues::Export.json (Serialize.issue
      # wrote these fields unscrubbed) — but here an unscrubbed byte breaks the WIRE response
      # line itself, a genuine JSON-RPC protocol violation a real client could choke on.
      # JSON.parse in Crystal does NOT validate embedded string bytes (confirmed separately),
      # so the meaningful assertion is `valid_encoding?` on the raw response, not just that
      # parsing succeeds.
      with_store do |store|
        id = store.insert_issue(String.new(Bytes[0x62, 0x61, 0x64, 0xff, 0x74]), # "bad\xFFt"
          Gori::Store::Severity::High, String.new(Bytes[0x68, 0xff, 0x6f]),      # "h\xFFo"
          nil        )
        store.update_issue(id, notes: String.new(Bytes[0x6e, 0x31, 0xff, 0x0a, 0x6e, 0x32])) # "n1\xFF\nn2"
        store.flush

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{}}})
        resp = mcp_drive(store, call)[0]
        # the literal wire value a real client reads: content[0].text (the nested JSON text)
        resp["result"]["content"][0]["text"].as_s.valid_encoding?.should be_true

        issue = mcp_tool_payload(resp)["issues"].as_a.first
        issue["title"].as_s.valid_encoding?.should be_true
        issue["host"].as_s.valid_encoding?.should be_true
        issue["notes"].as_s.valid_encoding?.should be_true
        issue["notes"].as_s.lines.size.should eq(2) # notes keeps its newline
      end
    end
  end

  describe "get_issue" do
    it "keeps the JSON-RPC response line valid UTF-8 when title/host/notes carry a raw invalid byte" do
      with_store do |store|
        id = store.insert_issue(String.new(Bytes[0x62, 0x61, 0x64, 0xff, 0x74]),
          Gori::Store::Severity::High, String.new(Bytes[0x68, 0xff, 0x6f]), nil)
        store.update_issue(id, notes: String.new(Bytes[0x6e, 0x31, 0xff, 0x0a, 0x6e, 0x32]))
        store.flush

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_issue","arguments":{"id":#{id}}}})
        resp = mcp_drive(store, call)[0]
        # the literal wire value a real client reads: content[0].text (the nested JSON text)
        resp["result"]["content"][0]["text"].as_s.valid_encoding?.should be_true

        issue = mcp_tool_payload(resp)
        issue["title"].as_s.valid_encoding?.should be_true
        issue["host"].as_s.valid_encoding?.should be_true
        issue["notes"].as_s.valid_encoding?.should be_true
      end
    end
  end
end

describe "MCP delete_issue" do
  it "removes the issue and its entity links" do
    with_store do |store|
      rid = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      id = store.insert_issue("boom", Gori::Store::Severity::High, "acme.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, id, Gori::Store::LinkRefKind::Repeater, rid)
      tools = tools_for(store)

      mcp_ok_json(tools, "delete_issue", %({"id":#{id}}))["deleted"].as_bool.should be_true
      store.get_issue(id).should be_nil
      store.list_links(Gori::Store::LinkOwnerKind::Issue, id).empty?.should be_true

      tools.call("delete_issue", JSON.parse(%({"id":#{id}}))).is_error.should be_true # already gone
    end
  end
end

describe "MCP entity links" do
  it "lists an issue's evidence resolved to labels, and round-trips add/remove" do
    with_store do |store|
      fid = mcp_seed_flow(store, "/evidence")
      rid = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      iid = store.insert_issue("boom", Gori::Store::Severity::High, "acme.test", nil)
      tools = tools_for(store)

      mcp_ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(0)

      res = mcp_ok_json(tools, "add_link",
        %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))
      res["already_linked"].as_bool.should be_false
      mcp_ok_json(tools, "add_link",
        %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"repeater","ref_id":#{rid}}))

      listed = mcp_ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))
      listed["total"].as_i.should eq(2)
      kinds = listed["links"].as_a.map { |l| l["ref_kind"].as_s }
      kinds.should contain("flow")
      kinds.should contain("repeater")
      listed["links"].as_a.each { |l| l["label"].as_s.empty?.should be_false }

      mcp_ok_json(tools, "remove_link",
        %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))["removed"].as_bool.should be_true
      mcp_ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(1)
    end
  end

  it "reports a re-link as already_linked rather than duplicating" do
    with_store do |store|
      fid = mcp_seed_flow(store)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      tools = tools_for(store)
      args = %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}})

      mcp_ok_json(tools, "add_link", args)["already_linked"].as_bool.should be_false
      mcp_ok_json(tools, "add_link", args)["already_linked"].as_bool.should be_true
      store.list_links(Gori::Store::LinkOwnerKind::Issue, iid).size.should eq(1)
    end
  end

  # This example used to pin the OPPOSITE — that deleting a repeater leaves the link dangling,
  # "because gone is not the same as never there". That reading only holds where the id cannot
  # come back, which is true of flows and false of repeaters: `repeaters.id` has no
  # AUTOINCREMENT and closing the NEWEST tab deletes at the top of the id space, so the
  # counter resets and the very next tab takes the dead id. The link then resolved
  # `stale: false` to an unrelated request — an issue's evidence pointer naming a different
  # URL. A pointer that starts lying is worse than either honest answer, so this one cascades.
  it "drops a repeater link when the repeater is deleted, because its id can be reused" do
    with_store do |store|
      rid = store.insert_repeater("https://victim.test/a", "GET /a HTTP/1.1\r\nHost: victim.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      tools = tools_for(store)
      mcp_ok_json(tools, "add_link", %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"repeater","ref_id":#{rid}}))

      store.delete_repeater(rid)
      mcp_ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(0)

      # The id comes straight back — which is exactly why the link could not be left behind.
      again = store.insert_repeater("https://unrelated.test/z", "GET /z HTTP/1.1\r\nHost: unrelated.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      again.should eq(rid)
      mcp_ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(0)
    end
  end

  it "drops a flow link when the flow itself is deleted (delete_flow cascades entity_links)" do
    with_store do |store|
      fid = mcp_seed_flow(store)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      tools = tools_for(store)
      mcp_ok_json(tools, "add_link", %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))

      mcp_ok_json(tools, "delete_flow", %({"id":#{fid}}))
      mcp_ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(0)
    end
  end

  it "refuses to link either end to a row that does not exist" do
    with_store do |store|
      fid = mcp_seed_flow(store)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      tools = tools_for(store)

      tools.call("add_link", JSON.parse(%({"owner_kind":"issue","owner_id":9999,"ref_kind":"flow","ref_id":#{fid}}))).is_error.should be_true
      tools.call("add_link", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":9999}))).is_error.should be_true
      tools.call("add_link", JSON.parse(%({"owner_kind":"bogus","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))).is_error.should be_true
      tools.call("add_link", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"bogus","ref_id":#{fid}}))).is_error.should be_true
      store.list_links(Gori::Store::LinkOwnerKind::Issue, iid).empty?.should be_true
    end
  end

  it "refuses mutation under --read-only but still lists" do
    with_store do |store|
      fid = mcp_seed_flow(store)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, iid, Gori::Store::LinkRefKind::Flow, fid)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)

      ro.call("add_link", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))).is_error.should be_true
      ro.call("remove_link", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))).is_error.should be_true
      mcp_ok_json(ro, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(1)
    end
  end
end

describe "MCP create_issue evidence" do
  it "refuses a flow_id that names no flow" do
    with_store do |store|
      r = tools_for(store).call("create_issue", JSON.parse(%({"title":"boom","flow_id":9999})))
      r.error_code.should eq "NOT_FOUND"
      # ...and nothing was persisted.
      store.issues.should be_empty
    end
  end

  it "still accepts a real flow_id" do
    with_store do |store|
      id = mcp_seed_flow(store, "/a")
      mcp_ok_json(tools_for(store), "create_issue", %({"title":"boom","flow_id":#{id}}))["id"].as_i64.should be > 0
    end
  end
end
