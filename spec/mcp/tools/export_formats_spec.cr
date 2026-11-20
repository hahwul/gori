require "../../spec_helper"
require "compress/gzip"

private def export_flow(store, *, body = "name=hello", content_type = "application/x-www-form-urlencoded",
                        truncated = false, socket = false, extra_headers = "", response_head : String? = nil,
                        response_body = %({"token":"response-body-secret"})) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "export.test", port: 443,
    method: "POST", target: "/submit", http_version: "HTTP/1.1",
    head: "POST /submit HTTP/1.1\r\nHost: export.test\r\nContent-Type: #{content_type}\r\n#{socket ? "Upgrade: websocket\r\n" : ""}#{extra_headers}Authorization: Bearer header-secret\r\n folded-secret\r\nCookie: sid=cookie-secret\r\nX-Api-Key: api-secret\r\n\r\n".to_slice,
    body: body.to_slice, body_truncated: truncated, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: socket ? 101 : 200,
    head: (response_head || "HTTP/1.1 200 OK\r\nSet-Cookie: sid=response-secret; HttpOnly\r\nContent-Type: application/json\r\n\r\n").to_slice,
    body: response_body.to_slice))
  id
end

private def exported(tools, tool : String, args : String) : JSON::Any
  result = tools.call(tool, JSON.parse(args))
  result.is_error.should be_false, result.text
  JSON.parse(result.text)
end

private def expected_code(format, wire, target) : String?
  case format
  when "curl"   then Gori::Export::Curl.text(wire, target)
  when "python" then Gori::Export::PythonRequests.text(wire, target)
  when "fetch"  then Gori::Export::JsFetch.text(wire, target)
  when "go"     then Gori::Export::GoHttp.text(wire, target)
  when "httpie" then Gori::Export::Httpie.text(wire, target)
  when "csrf"   then Gori::Export::CsrfPoc.text(wire, target)
  end
end

describe "MCP report and request-code formats" do
  it "serves all six code exporters unchanged under read-only, with credential redaction" do
    with_store do |store|
      id = export_flow(store)
      tools = tools_for(store, allow_actions: false)
      detail = store.get_flow(id).not_nil!
      wire = String.new(Gori::Repeater::FlowRequest.export_head(detail)) + String.new(detail.request_body.not_nil!)
      clean = Gori::MCP::Serialize.redact_head(wire, false)
      %w[curl python fetch go httpie csrf].each do |format|
        payload = exported(tools, "get_flow", %({"id":#{id},"format":"#{format}"}))
        payload["document"].as_s.should eq(expected_code(format, clean, "https://export.test"))
        payload["document"].as_s.should_not be_empty
        %w[header-secret folded-secret cookie-secret api-secret].each { |secret| payload.to_json.should_not contain(secret) }
        payload["truncated"].should be_false
        raw = exported(tools, "get_flow", %({"id":#{id},"format":"#{format}","include_sensitive":true}))
        raw["document"].as_s.should eq(expected_code(format, wire, "https://export.test"))
      end
      # Exporting is a projection, including the default head redaction.
      String.new(store.get_flow(id).not_nil!.request_head).should contain("header-secret")
      exported(tools, "get_flow", %({"id":#{id}}))["request_head"].as_s.should_not contain("header-secret")
    end
  end

  it "redacts malformed heads before SARIF can reinterpret credentials as public fields" do
    with_store do |store|
      id = export_flow(store, extra_headers: "X-Public: harmless\r\n Authorization: Bearer indented-secret\r\n",
        response_head: "Authorization: Bearer first-line-secret\r\n\r\n")
      store.insert_issue("Malformed headers", Gori::Store::Severity::High, "export.test", id)
      tools = tools_for(store, allow_actions: false)
      %w[json curl python fetch go httpie csrf markdown sarif].each do |format|
        report = format.in?("markdown", "sarif")
        args = report ? %({"format":"#{format}"}) : %({"id":#{id},"format":"#{format}"})
        payload = exported(tools, report ? "list_issues" : "get_flow", args)
        %w[indented-secret first-line-secret].each { |secret| payload.to_json.should_not contain(secret) }
      end
      raw = exported(tools, "list_issues", %({"format":"sarif","include_sensitive":true}))
      %w[indented-secret first-line-secret].each { |secret| raw["document"].as_s.should contain(secret) }
    end
  end

  it "bounds report evidence reads even when binary bodies produce a small document" do
    with_store do |store|
      id = export_flow(store, body: "\xff" * 100_000)
      store.insert_issue("Binary evidence", Gori::Store::Severity::High, "export.test", id)
      tools = tools_for(store, allow_actions: false)
      %w[markdown sarif].each do |format|
        payload = exported(tools, "list_issues", %({"format":"#{format}"}))
        payload["document"].as_s.bytesize.should be < Gori::MCP::Serialize::MAX_TEXT
        payload["document"].as_s.should contain("Binary evidence")
        payload["evidence_truncated"].should be_true
      end
    end
  end

  it "bounds body reads across a maximum-sized candidate report page" do
    with_store do |store|
      500.times do |n|
        id = export_flow(store, body: "\xff" * 60_000)
        store.insert_issue("Finding #{n}", Gori::Store::Severity::High, "export.test", id)
      end
      payload = exported(tools_for(store, allow_actions: false), "list_issues", %({"format":"markdown","limit":500}))
      payload["returned"].as_i.should be > 0
      payload["returned"].as_i.should be < 500
      payload["document"].as_s.bytesize.should be < Gori::MCP::Serialize::MAX_TEXT
      payload["evidence_truncated"].should be_true
    end
  end

  it "withholds incomplete structural-profile inputs, including amplified gzip bodies" do
    with_store do |store|
      profile = Gori::Redact::Profile.new("pointer", json_pointers: ["/private/value"])
      Gori::Redact::Policy.write_project_scope(store,
        Gori::Redact::Policy::ProjectScope.new(active: "pointer", default: true, profiles: [profile]))
      big = %({"private":{"value":"pointer-secret"},"pad":"#{"p" * 100_000}"})
      compressed = IO::Memory.new
      Compress::Gzip::Writer.open(compressed, &.print(big))
      [export_flow(store, body: big, content_type: "application/json"),
       export_flow(store, body: compressed.to_s, content_type: "application/json", extra_headers: "Content-Encoding: gzip\r\n")].each do |id|
        store.insert_issue("Pointer finding", Gori::Store::Severity::High, "export.test", id)
        exported(tools_for(store), "get_flow", %({"id":#{id}})).to_json.should_not contain("pointer-secret")
      end
      tools = tools_for(store, allow_actions: false)
      %w[markdown sarif].each do |format|
        payload = exported(tools, "list_issues", %({"format":"#{format}"}))
        payload.to_json.should_not contain("pointer-secret")
        payload["evidence_truncated"].should be_true
        payload["document"].as_s.bytesize.should be < Gori::MCP::Serialize::MAX_TEXT
        # Opting out of the profile still leaves decoding bounded.
        raw = exported(tools, "list_issues", %({"format":"#{format}","include_sensitive":true}))
        raw["evidence_truncated"].should be_true
      end
    end
  end

  it "exports the queried issue page through the Markdown and SARIF exporters in read-only mode" do
    with_store do |store|
      id = export_flow(store)
      issue = store.insert_issue("Selected finding", Gori::Store::Severity::High, "export.test", id)
      store.insert_issue("Excluded finding", Gori::Store::Severity::Info, "other.test", nil)
      tools = Gori::MCP::Tools.new(store, false, false, project_name: "test-project")
      selected = [store.get_issue(issue).not_nil!]
      %w[markdown sarif].each do |format|
        payload = exported(tools, "list_issues", %({"format":"#{format}","query":"sev:high"}))
        {payload["total"].as_i, payload["returned"].as_i}.should eq({1, 1})
        payload["truncated"]?.should be_nil
        payload["document"].as_s.should contain("Selected finding")
        payload["document"].as_s.should_not contain("Excluded finding")
        %w[header-secret folded-secret cookie-secret api-secret response-secret].each do |secret|
          payload.to_json.should_not contain(secret)
        end
        sensitive = exported(tools, "list_issues", %({"format":"#{format}","query":"sev:high","include_sensitive":true}))
        expected = format == "sarif" ? Gori::Issues::Export.sarif(selected, store, "test-project", true) : Gori::Issues::Export.markdown(selected, store, "test-project")
        sensitive["document"].as_s.should eq(expected)
        sensitive["document"].as_s.should contain("header-secret")
        sensitive["document"].as_s.should contain("response-secret")
        if format == "sarif"
          JSON.parse(payload["document"].as_s).should eq(JSON.parse(Gori::Issues::Export.sarif(selected, store, "test-project")))
        end
        empty = exported(tools, "list_issues", %({"format":"#{format}","query":"host:absent.test"}))
        empty["total"].should eq(0)
        empty["document"].as_s.should_not be_empty
        empty["truncated"]?.should be_nil
      end
      exported(tools, "list_issues", "{}")["issues"].as_a.size.should eq(2)
    end
  end

  it "applies get_flow's default body profile to every export and opts out with include_sensitive" do
    with_store do |store|
      Gori::Redact::Policy.write_project_scope(store, Gori::Redact::Policy::ProjectScope.new(default: true))
      id = export_flow(store, body: %({"password":"request-body-secret"}), content_type: "application/json")
      store.insert_issue("Body finding", Gori::Store::Severity::High, "export.test", id)
      tools = tools_for(store, allow_actions: false)
      %w[curl python fetch go httpie csrf markdown sarif].each do |format|
        report = format.in?("markdown", "sarif")
        tool = report ? "list_issues" : "get_flow"
        args = report ? %({"format":"#{format}"}) : %({"id":#{id},"format":"#{format}"})
        payload = exported(tools, tool, args)
        payload.to_json.should_not contain("request-body-secret")
        payload.to_json.should_not contain("response-body-secret")
        raw = exported(tools, tool, args.rchop('}') + %(,"include_sensitive":true}))
        raw["document"].as_s.should contain("request-body-secret")
        raw["document"].as_s.should contain("response-body-secret") if report
      end
    end
  end

  it "cuts oversized code on UTF-8 boundaries and flags captured prefixes" do
    with_store do |store|
      id = export_flow(store, body: "값" * 40_000)
      tools = tools_for(store, allow_actions: false)
      %w[curl python fetch go httpie csrf].each do |format|
        payload = exported(tools, "get_flow", %({"id":#{id},"format":"#{format}"}))
        payload["truncated"].should be_true
        doc = payload["document"].as_s
        doc.bytesize.should be <= Gori::MCP::Serialize::MAX_TEXT
        doc.valid_encoding?.should be_true
        doc.should_not be_empty
      end
      cut_id = export_flow(store, truncated: true)
      exported(tools, "get_flow", %({"id":#{cut_id},"format":"curl"}))["truncated"].should be_true
    end
  end

  it "fits whole report issues and walks byte-limited pages exactly once" do
    with_store do |store|
      ids = Array.new(40) do |n|
        flow = export_flow(store, body: "값" * 40_000)
        store.insert_issue("Large finding #{n}", Gori::Store::Severity::High, "export.test", flow)
      end
      tools = tools_for(store, allow_actions: false)
      %w[markdown sarif].each do |format|
        offset = 0
        visited = [] of Int64
        loop do
          payload = exported(tools, "list_issues", %({"format":"#{format}","offset":#{offset}}))
          doc = payload["document"].as_s
          doc.bytesize.should be <= Gori::MCP::Serialize::MAX_TEXT
          doc.valid_encoding?.should be_true
          payload["truncated"]?.should be_nil
          payload["evidence_truncated"].should be_true
          doc.should contain("body truncated")
          returned = payload["returned"].as_i
          returned.should be > 0
          actual = if format == "sarif"
                     JSON.parse(doc)["runs"][0]["results"].as_a.map(&.["properties"].["gori/issueId"].as_i64)
                   else
                     doc.scan(/## \[high\] Large finding (\d+)/).map { |m| ids[m[1].to_i] }
                   end
          actual.size.should eq(returned)
          visited.concat(actual)
          break unless payload["has_more"].as_bool
          payload["cut_by"].should eq("bytes")
          payload["next_offset"].should eq(offset + returned)
          offset = payload["next_offset"].as_i
        end
        visited.should eq(store.issues.map(&.id))
        visited.uniq.size.should eq(ids.size)
      end
    end
  end

  it "keeps a single large exchange well-formed and distinguishes evidence cuts from more pages" do
    with_store do |store|
      id = export_flow(store, body: "x" * 200_000, response_body: "\"\\\n" * 100_000)
      issue = store.insert_issue("Large body", Gori::Store::Severity::High, "export.test", id)
      store.insert_issue("Next finding", Gori::Store::Severity::Info, "export.test", nil)
      tools = tools_for(store, allow_actions: false)
      %w[markdown sarif].each do |format|
        page = exported(tools, "list_issues", %({"format":"#{format}","limit":1}))
        page["returned"].should eq(1)
        page["has_more"].should be_true
        page["next_offset"].should eq(1)
        page["truncated"]?.should be_nil
        page["evidence_truncated"].should be_true
        page["document"].as_s.should contain("body truncated")
        if format == "sarif"
          results = JSON.parse(page["document"].as_s)["runs"][0]["results"].as_a
          results.size.should eq(1)
          results[0]["properties"]["gori/issueId"].should eq(issue)
        end
        next_page = exported(tools, "list_issues", %({"format":"#{format}","offset":1}))
        next_page["evidence_truncated"].should be_false
        next_page["truncated"]?.should be_nil
      end
    end
  end

  it "does not flag cuts belonging only to issues beyond the fitted page" do
    with_store do |store|
      id = export_flow(store, body: "x" * 100_000)
      store.insert_issue("First", Gori::Store::Severity::High, nil, nil, notes: "a" * 20_000)
      store.insert_issue("Second", Gori::Store::Severity::Info, nil, id, notes: "b" * 40_000)
      payload = exported(tools_for(store), "list_issues", %({"format":"sarif"}))
      payload["returned"].should eq(1)
      payload["has_more"].should be_true
      payload["evidence_truncated"].should be_false
      payload["truncated"]?.should be_nil
      JSON.parse(payload["document"].as_s)["runs"][0]["results"].as_a.size.should eq(1)
    end
  end

  it "refuses a single issue whose metadata alone exceeds the report cap" do
    with_store do |store|
      store.insert_issue("Huge notes", Gori::Store::Severity::High, nil, nil, notes: "값" * 40_000)
      %w[markdown sarif].each do |format|
        result = tools_for(store).call("list_issues", JSON.parse(%({"format":"#{format}"})))
        result.is_error.should be_true
        result.text.should contain("64 KiB")
      end
    end
  end

  it "names the WebSocket handshake boundary, and rejects missing flows, invalid formats and conflicting options" do
    with_store do |store|
      id = export_flow(store, socket: true)
      tools = tools_for(store, allow_actions: false)
      payload = exported(tools, "get_flow", %({"id":#{id},"format":"curl"}))
      payload["note"].as_s.should contain("no message transcript")
      {"get_flow" => %({"id":999999,"format":"curl"}), "list_issues" => %({"format":"xml"})}.each do |tool, args|
        tools.call(tool, JSON.parse(args)).is_error.should be_true
      end
      [%({"id":#{id},"format":"xml"}), %({"id":#{id},"format":"curl","body_mode":"none"})].each do |args|
        tools.call("get_flow", JSON.parse(args)).error_code.should eq("INVALID_ARGUMENT")
      end
      tools.call("list_issues", JSON.parse(%({"format":"sarif","query":"stauts:open"}))).is_error.should be_true
      tools.call("list_issues", JSON.parse(%({"include_sensitive":true}))).is_error.should be_true
      catalogue = JSON.parse(Gori::MCP::Tools.catalogue_json(nil, false)).as_a
      %w[get_flow list_issues].each do |name|
        catalogue.find { |t| t["name"] == name }.not_nil!["annotations"]["readOnlyHint"].should be_true
      end
    end
  end
end
