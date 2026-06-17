require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-ic", ".db")
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

private def req(ic, raw)
  Gori::Interceptor::Decision
  ic.hold_request(raw.to_slice, method: "GET", target: "/", host: "acme.test", port: 80, scheme: "http")
end

describe Gori::Interceptor do
  it "passes through immediately when disabled" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      d = req(ic, "GET / HTTP/1.1\r\n\r\n")
      d.action.should eq(Gori::Interceptor::Action::Forward)
      String.new(d.bytes).should eq("GET / HTTP/1.1\r\n\r\n")
      ic.pending_count.should eq(0)
    end
  end

  it "holds a request until the TUI forwards it (edited bytes flow back)" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle # enable
      result = Channel(Gori::Interceptor::Decision).new
      spawn { result.send(req(ic, "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")) }
      Fiber.yield

      ic.pending_count.should eq(1)
      item = ic.pending.first
      item.kind.should eq(Gori::Interceptor::Kind::Request)
      item.host.should eq("acme.test")

      ic.forward(item.id, "GET /edited HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice)
      d = result.receive
      d.action.should eq(Gori::Interceptor::Action::Forward)
      String.new(d.bytes).should contain("/edited")
      ic.pending_count.should eq(0)
    end
  end

  it "drops a held request" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      result = Channel(Gori::Interceptor::Decision).new
      spawn { result.send(req(ic, "GET / HTTP/1.1\r\n\r\n")) }
      Fiber.yield
      ic.drop(ic.pending.first.id)
      result.receive.action.should eq(Gori::Interceptor::Action::Drop)
    end
  end

  it "auto-forwards held items when toggled off" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      result = Channel(Gori::Interceptor::Decision).new
      spawn { result.send(req(ic, "GET / HTTP/1.1\r\n\r\n")) }
      Fiber.yield
      ic.pending_count.should eq(1)
      ic.toggle # off → release held
      result.receive.action.should eq(Gori::Interceptor::Action::Forward)
      ic.pending_count.should eq(0)
    end
  end

  it "release_all unblocks every held fiber" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      done = Channel(Nil).new
      2.times { spawn { req(ic, "GET / HTTP/1.1\r\n\r\n"); done.send(nil) } }
      Fiber.yield
      ic.pending_count.should eq(2)
      ic.release_all
      2.times { done.receive }
      ic.pending_count.should eq(0)
    end
  end

  it "gates by the Scope lens (intercepts_host?)" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      ic = Gori::Interceptor.new(scope)
      ic.intercepts_host?("acme.test").should be_false # disabled
      ic.toggle
      ic.intercepts_host?("acme.test").should be_true # enabled, scope inactive → all
      scope.add("acme.test")
      scope.enable
      ic.intercepts_host?("acme.test").should be_true     # in scope
      ic.intercepts_host?("evil.test").should be_false    # out of scope
      ic.intercepts_host?("api.acme.test").should be_true # subdomain
    end
  end
end

describe "Gori::Scope#matches?" do
  it "matches exact host, subdomain, and glob" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("acme.test")
      scope.add("*.shop.test")
      scope.enable
      scope.matches?("acme.test").should be_true
      scope.matches?("api.acme.test").should be_true # subdomain
      scope.matches?("notacme.test").should be_false
      scope.matches?("a.shop.test").should be_true # glob
      scope.matches?("shop.test").should be_false  # glob needs a label
    end
  end
end
