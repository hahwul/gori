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
      rules.add(Gori::Store::RuleTarget::Request, "Host: acme.test", "Host: evil.test")
      rules.add(Gori::Store::RuleTarget::Response, "Server: nginx", "Server: gori")
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

  it "returns the same bytes when nothing matches (P7)" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, "absent", "x")
      head = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
      rules.rewrite_request(head).should eq(head)
    end
  end

  it "persists, toggles, and removes rules across reload" do
    with_store do |store|
      r1 = Gori::Rules.load(store)
      r1.add(Gori::Store::RuleTarget::Request, "A", "B")
      id = r1.rules.first.id

      r2 = Gori::Rules.load(store)
      r2.rules.size.should eq(1)
      r2.rules.first.enabled?.should be_true
      r2.rules.first.target.should eq(Gori::Store::RuleTarget::Request)

      r2.toggle(id)
      r2.active?.should be_false # disabled → lens inert
      head = "A".to_slice
      r2.rewrite_request(head).should eq(head)
      Gori::Rules.load(store).rules.first.enabled?.should be_false

      r2.remove(id)
      r2.rules.should be_empty
      Gori::Rules.load(store).rules.should be_empty
    end
  end
end
