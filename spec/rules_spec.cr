require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-rules", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Rules do
  it "is inactive (and byte-identical) until an enabled rule exists" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.active?.should be_false
      head = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
      rules.rewrite_request(head, "").should eq(head)
    end
  end

  it "rewrites only the targeted side, and only enabled rules" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "Host: acme.test", "Host: evil.test")
      rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Head, "Server: nginx", "Server: gori")
      rules.active?.should be_true
      rules.enabled_count.should eq(2)

      req = "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
      String.new(rules.rewrite_request(req, "acme.test")).should contain("Host: evil.test")

      # the request rule must not touch the response head
      resp = "HTTP/1.1 200 OK\r\nServer: nginx\r\nX-Echo: acme.test\r\n\r\n".to_slice
      out = String.new(rules.rewrite_response(resp, "acme.test"))
      out.should contain("Server: gori")
      out.should contain("X-Echo: acme.test")
    end
  end

  it "keeps head and body rules on separate seams" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body, "password", "hunter2")
      rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body, "SECRET", "REDACT")

      rules.rewrites_request_body?.should be_true
      rules.rewrites_response_body?.should be_true

      # a body rule never touches the head seam...
      head = "POST / HTTP/1.1\r\nX-Note: password\r\n\r\n".to_slice
      rules.rewrite_request(head, "").should eq(head)
      # ...and rewrites the entity body
      String.new(rules.rewrite_request_body("user=admin&password=x".to_slice, "")).should eq("user=admin&hunter2=x")
      String.new(rules.rewrite_response_body("the SECRET value".to_slice, "")).should eq("the REDACT value")

      # each side's body rule stays on its own side
      rules.rewrite_response_body("password".to_slice, "").should eq("password".to_slice)
    end
  end

  it "reports no body rewrite when only head rules exist" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "A", "B")
      rules.rewrites_request_body?.should be_false
      rules.rewrites_response_body?.should be_false
      body = "A body with A".to_slice
      rules.rewrite_request_body(body, "").should eq(body) # inert fast path
    end
  end

  it "returns the same bytes when nothing matches (P7)" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "absent", "x")
      head = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
      rules.rewrite_request(head, "").should eq(head)
    end
  end

  it "persists, toggles, and removes rules across reload" do
    with_store do |store|
      r1 = Gori::Rules.load(store)
      r1.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body, "A", "B")
      id = r1.rules.first.id

      r2 = Gori::Rules.load(store)
      r2.rules.size.should eq(1)
      r2.rules.first.enabled?.should be_true
      r2.rules.first.target.should eq(Gori::Store::RuleTarget::Response)
      r2.rules.first.part.should eq(Gori::Store::RulePart::Body)
      r2.rewrites_response_body?.should be_true

      r2.toggle(id)
      r2.active?.should be_false # disabled → lens inert
      r2.rewrites_response_body?.should be_false
      body = "A".to_slice
      r2.rewrite_response_body(body, "").should eq(body)
      Gori::Rules.load(store).rules.first.enabled?.should be_false

      r2.remove(id)
      r2.rules.should be_empty
      Gori::Rules.load(store).rules.should be_empty
    end
  end

  it "replaces with a regex and $1 capture-group interpolation" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Head,
        "Server: (\\S+)", "Server: gori-$1", match_kind: Gori::Store::MatchKind::Regex)
      resp = "HTTP/1.1 200 OK\r\nServer: nginx\r\n\r\n".to_slice
      String.new(rules.rewrite_response(resp, "")).should contain("Server: gori-nginx")
    end
  end

  it "adds, sets, and removes headers by name" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "X-Trace", "on", op: Gori::Store::RuleOp::AddHeader)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "user-agent", "gori", op: Gori::Store::RuleOp::SetHeader)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "Cookie", "", op: Gori::Store::RuleOp::RemoveHeader)

      req = "GET / HTTP/1.1\r\nHost: a\r\nUser-Agent: curl/8\r\nCookie: sid=1\r\n\r\n".to_slice
      out = String.new(rules.rewrite_request(req, ""))
      out.should contain("X-Trace: on")      # added before the blank line
      out.should contain("User-Agent: gori") # value replaced, original name casing kept
      out.should_not contain("Cookie:")      # removed
      out.should contain("Host: a")          # untouched
    end
  end

  it "reorders rules in apply order" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "A", "1")
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "B", "2")
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "C", "3")
      rules.rules.map(&.pattern).should eq(%w[A B C])

      last = rules.rules.last.id
      rules.move(last, -1) # C moves up one
      rules.rules.map(&.pattern).should eq(%w[A C B])
      # order survives a reload
      Gori::Rules.load(store).rules.map(&.pattern).should eq(%w[A C B])
    end
  end

  it "scopes a rule to a matching host glob" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "X-Env", "prod", op: Gori::Store::RuleOp::AddHeader, host: "*.example.com")
      req = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
      String.new(rules.rewrite_request(req, "api.example.com")).should contain("X-Env: prod")
      # a non-matching host is byte-identical (same slice returned)
      rules.rewrite_request(req, "other.test").should eq(req)
    end
  end

  it "reload picks up an external edit on the SAME live instance (TUI 'r' key / headless capture's periodic reload)" do
    with_store do |store|
      # `live` stands in for the Rules object a Session hands to the proxy pipeline —
      # held for a while, never re-`load`ed. `editor` stands in for a separate `gori run
      # rewriter add` process (or the TUI's own editor) writing to the SAME store.
      live = Gori::Rules.load(store)
      live.active?.should be_false

      editor = Gori::Rules.load(store)
      editor.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Head, "Server: nginx", "Server: gori")

      resp = "HTTP/1.1 200 OK\r\nServer: nginx\r\n\r\n".to_slice
      # the external add is invisible to `live` until it reloads
      live.active?.should be_false
      live.rewrite_response(resp, "").should eq(resp)

      live.reload
      live.active?.should be_true
      String.new(live.rewrite_response(resp, "")).should contain("Server: gori")

      # disabling externally is picked up the same way
      id = live.rules.first.id
      editor.toggle(id)
      live.active?.should be_true # still stale
      live.reload
      live.active?.should be_false
      live.rewrite_response(resp, "").should eq(resp)
    end
  end

  it "transforms a full HTTP message for the live preview (head + body seams)" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "Host: example.com", "Host: evil.test")
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body,
        "hello", "hola")
      sample = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\nhello world"
      out = rules.transform_message(sample, Gori::Store::RuleTarget::Request, "example.com")
      out.should contain("Host: evil.test")
      out.should contain("hola world")
      out.should_not contain("hello world")
      # disabled rules are skipped
      id = rules.rules.find(&.part.body?).not_nil!.id
      rules.toggle(id)
      out2 = rules.transform_message(sample, Gori::Store::RuleTarget::Request, "example.com")
      out2.should contain("hello world")
      # response rules do not touch a request preview
      rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body, "hello", "nope")
      out3 = rules.transform_message(sample, Gori::Store::RuleTarget::Request, "example.com")
      out3.should contain("hello world")
      out3.should_not contain("nope")
    end
  end
end
