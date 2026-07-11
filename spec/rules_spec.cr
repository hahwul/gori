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
      rules.rewrite_request(head).should eq(head)
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
      String.new(rules.rewrite_request(req)).should contain("Host: evil.test")

      # the request rule must not touch the response head
      resp = "HTTP/1.1 200 OK\r\nServer: nginx\r\nX-Echo: acme.test\r\n\r\n".to_slice
      out = String.new(rules.rewrite_response(resp))
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
      rules.rewrite_request(head).should eq(head)
      # ...and rewrites the entity body
      String.new(rules.rewrite_request_body("user=admin&password=x".to_slice)).should eq("user=admin&hunter2=x")
      String.new(rules.rewrite_response_body("the SECRET value".to_slice)).should eq("the REDACT value")

      # each side's body rule stays on its own side
      rules.rewrite_response_body("password".to_slice).should eq("password".to_slice)
    end
  end

  it "reports no body rewrite when only head rules exist" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "A", "B")
      rules.rewrites_request_body?.should be_false
      rules.rewrites_response_body?.should be_false
      body = "A body with A".to_slice
      rules.rewrite_request_body(body).should eq(body) # inert fast path
    end
  end

  it "returns the same bytes when nothing matches (P7)" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "absent", "x")
      head = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
      rules.rewrite_request(head).should eq(head)
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
      r2.rewrite_response_body(body).should eq(body)
      Gori::Rules.load(store).rules.first.enabled?.should be_false

      r2.remove(id)
      r2.rules.should be_empty
      Gori::Rules.load(store).rules.should be_empty
    end
  end
end
