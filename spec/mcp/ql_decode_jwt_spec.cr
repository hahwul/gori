require "../spec_helper"
require "../support/mcp_harness"

describe Gori::MCP::Server do
  describe "ql_reference" do
    it "returns the QL syntax reference" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ql_reference","arguments":{}}})
        ref = mcp_tool_payload(mcp_drive(store, call)[0])["reference"].as_s
        ref.should contain("host:example.com")
        ref.should contain("status:>=500")
      end
    end
  end

  describe "QL strict mode + ql_explain" do
    it "strict:true rejects a query with a silently-dropped term" do
      with_store do |store|
        mcp_seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"host:ex.test status:>=foo","strict":true}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("QUERY_SYNTAX")
      end
    end

    it "lenient (default) drops the bad term and still runs the good one" do
      with_store do |store|
        mcp_seed_flow(store, "ex.test", "GET", "/", 200)
        mcp_seed_flow(store, "other.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"host:ex.test status:>=foo"}}})
        rows = mcp_tool_payload(mcp_drive(store, call)[0]).as_a
        rows.size.should eq(1) # host:ex.test applied, bad status term dropped
      end
    end

    it "ql_explain reports applied vs ignored terms without running" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ql_explain","arguments":{"query":"host:ex.test status:>=foo"}}})
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p["applied_terms"].as_a.map(&.as_s).should contain("host:ex.test")
        p["ignored_terms"].as_a.map(&.as_s).should contain("status:>=foo")
        p["warnings"].as_a.size.should be > 0
      end
    end

    # A condition the hold gate REFUSES (`InterceptFilter::UNSUPPORTED_FIELDS`) compiles to a
    # never-match: `scope:in` holds nothing and `-scope:in` holds EVERY in-flight message until
    # each is forwarded by hand. An agent has no note row to read, so the tool refuses it.
    it "intercept_set_filter refuses a field the hold gate cannot answer" do
      with_store do |store|
        %w[scope:in -scope:in scope~in].each do |q|
          resp = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"intercept_set_filter","arguments":{"query":#{q.to_json}}}}))[0]["result"]
          resp["isError"].as_bool.should be_true, "#{q} should be refused"
          resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
          resp["structuredContent"]["field"].as_s.should eq("query")
        end
      end
    end

    # A `scope:` term on a project with no scope rules compiles to a never-match and the query
    # runs CLEAN — so an agent sees zero rows and cannot tell that from "no flow matched". This
    # is the surface that has to say which it is (#754).
    it "ql_explain names an unconfigured scope, and stops warning once rules exist" do
      with_store do |store|
        mcp_seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ql_explain","arguments":{"query":"scope:in"}}})
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p["scope_rules_configured"].as_bool.should be_false
        p["applied_terms"].as_a.map(&.as_s).should eq(["scope:in"]) # applied, not dropped
        p["ignored_terms"].as_a.should be_empty
        p["warnings"].as_a.map(&.as_s).join(" ").should contain("no scope rules are configured")

        Gori::Scope.load(store).add("include", "host", "ex.test")
        p2 = mcp_tool_payload(mcp_drive(store, call)[0])
        p2["scope_rules_configured"].as_bool.should be_true
        p2["warnings"].as_a.should be_empty
        p2["sql"].as_s.should_not eq("(0)")
      end
    end

    # An extract rule PERSISTS, so a `when:` condition naming a refused field is refused at the
    # write — and the error names the argument it is about, or an agent that edits the field it is
    # told about rewrites `name` and resubmits the same condition.
    it "create/update_extract_rule refuse a when: condition and name the `when` argument" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_extract_rule","arguments":{"name":"SESSION","when":"scope:in","kind":"cookie","selector":"sid"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["field"].as_s.should eq("when")
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        store.extract_rules.should be_empty

        ok = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_extract_rule","arguments":{"name":"SESSION","when":"path:/login","kind":"cookie","selector":"sid"}}})
        mcp_drive(store, ok)[0]["result"]["isError"].as_bool.should be_false
        id = store.extract_rules.first.id
        upd = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_extract_rule","arguments":{"id":#{id},"when":"-scope:out"}}})
        bad = mcp_drive(store, upd)[0]["result"]
        bad["isError"].as_bool.should be_true
        bad["structuredContent"]["field"].as_s.should eq("when")
        store.extract_rules.first.match_filter.should eq("path:/login")
      end
    end

    # The term has to reach the query itself, or `scope:in` would be dropped and the listing
    # would be BROADER than asked while reporting nothing.
    it "list_history applies scope:in/scope:out from the query" do
      with_store do |store|
        mcp_seed_flow(store, "ex.test", "GET", "/", 200)
        mcp_seed_flow(store, "other.test", "GET", "/", 200)
        Gori::Scope.load(store).add("include", "host", "ex.test")
        %w[in out].each do |side|
          call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"scope:#{side}","strict":true}}})
          rows = mcp_tool_payload(mcp_drive(store, call)[0]).as_a
          rows.map(&.["host"].as_s).should eq([side == "in" ? "ex.test" : "other.test"])
        end
      end
    end
  end

  describe "decoder" do
    it "runs a converter chain and returns the decoded output" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decode","arguments":{"input":"aGVsbG8=","spec":"base64-decode"}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["output"].as_s.should eq("hello")
        payload["output_encoding"].as_s.should eq("text")
        payload["steps"].as_a.size.should eq(1)
      end
    end

    it "reports an unknown converter as an error and enumerates the registry" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decode","arguments":{"input":"x","spec":"nope-bogus"}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        text = resp["result"]["content"][0]["text"].as_s
        text.should contain("unknown converter")
        text.should contain("base64-decode")
      end
    end

    it "is available in read-only mode (pure transform, no gating)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decode","arguments":{"input":"hi","spec":"sha256"}}})
        resp = mcp_drive(store, call, allow_actions: false)[0]
        resp["result"]["isError"]?.should_not be_true
        mcp_tool_payload(resp)["output"].as_s.size.should eq(64)
      end
    end

    it "rejects a separator-only spec instead of echoing the input as a phantom success" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decode","arguments":{"input":"hello","spec":">"}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("no converter tokens")
      end
    end
  end

  describe "jwt tools" do
    # header {"alg":"HS256","typ":"JWT"}, payload {"sub":"1","admin":false}, key "secret".
    jwt = begin
      h = Base64.urlsafe_encode(%({"alg":"HS256","typ":"JWT"}), padding: false)
      p = Base64.urlsafe_encode(%({"sub":"1","admin":false}), padding: false)
      sig = Base64.urlsafe_encode(OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "secret", "#{h}.#{p}"), padding: false)
      "#{h}.#{p}.#{sig}"
    end

    it "jwt_decode returns header/payload/signature (read-only, no gating)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_decode","arguments":{"token":"#{jwt}"}}})
        resp = mcp_drive(store, call, allow_actions: false)[0]
        resp["result"]["isError"]?.should_not be_true
        payload = mcp_tool_payload(resp)
        payload["alg"].as_s.should eq("HS256")
        payload["header"]["typ"].as_s.should eq("JWT")
        payload["payload"]["sub"].as_s.should eq("1")
        payload["signed"].as_bool.should be_true
      end
    end

    it "jwt_encode re-signs and the signature verifies with the given secret" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_encode","arguments":{"token":"#{jwt}","alg":"HS256","secret":"hunter2"}}})
        token = mcp_tool_payload(mcp_drive(store, call)[0])["token"].as_s
        header, body, sig = token.split('.')
        Gori::Jwt.sign("#{header}.#{body}", "HS256", "hunter2").should eq(sig)
      end
    end

    it "jwt_encode signs a payload-only request (no token/header) instead of erroring" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_encode","arguments":{"payload":"{\\"user\\":\\"admin\\"}","secret":"test"}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"]?.try(&.as_bool).should_not be_true # was a misleading "invalid header JSON"
        token = mcp_tool_payload(resp)["token"].as_s
        header, body, sig = token.split('.')
        # a well-formed, verifiable token was produced from the defaulted ({}) header
        Gori::Jwt.sign("#{header}.#{body}", "HS256", "test").should eq(sig)
      end
    end

    it "jwt_encode still rejects a call with no token, header, or payload" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_encode","arguments":{"secret":"test"}}})
        mcp_drive(store, call)[0]["result"]["isError"].as_bool.should be_true
      end
    end

    it "jwt_encode patches a claim with set= before signing" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_encode","arguments":{"token":"#{jwt}","set":["role=admin","admin=true"],"secret":"k"}}})
        token = mcp_tool_payload(mcp_drive(store, call)[0])["token"].as_s
        header, body, sig = token.split('.')
        payload = JSON.parse(String.new(Base64.decode(body)))
        payload["role"].as_s.should eq("admin")
        payload["admin"].as_bool.should be_true # a bare true keeps its JSON type
        Gori::Jwt.sign("#{header}.#{body}", "HS256", "k").should eq(sig)
      end
    end

    it "jwt_encode refuses payload and set together" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_encode","arguments":{"payload":"{}","set":["role=admin"],"secret":"k"}}})
        mcp_drive(store, call)[0]["result"]["isError"].as_bool.should be_true
      end
    end

    it "jwt_attacks lists none/weak-secret/header-inject payloads" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_attacks","arguments":{"token":"#{jwt}"}}})
        cats = mcp_tool_payload(mcp_drive(store, call, allow_actions: false)[0]).as_a.map(&.["category"].as_s).uniq!
        cats.should contain("none")
        cats.should contain("weak-secret")
        cats.should contain("header-inject")
      end
    end

    it "all three jwt tools are listed even in read-only mode" do
      with_store do |store|
        names = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/list"}), allow_actions: false)[0]["result"]["tools"].as_a.map(&.["name"].as_s)
        names.should contain("jwt_decode")
        names.should contain("jwt_encode")
        names.should contain("jwt_attacks")
      end
    end

    it "jwt_decode errors cleanly on a non-JWT" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_decode","arguments":{"token":"plainstring"}}})
        mcp_drive(store, call)[0]["result"]["isError"].as_bool.should be_true
      end
    end
  end
end
