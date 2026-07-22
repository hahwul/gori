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

  it "bumps revision on enable / async hold / forward (drives the TUI redraw gate)" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      r0 = ic.revision
      ic.toggle                         # enable
      (ic.revision > r0).should be_true # enable bumped

      r1 = ic.revision
      result = Channel(Gori::Interceptor::Decision).new
      spawn { result.send(req(ic, "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")) }
      Fiber.yield
      (ic.revision > r1).should be_true # async hold (proxy-fiber path) bumped

      r2 = ic.revision
      ic.forward(ic.pending.first.id)
      result.receive
      (ic.revision > r2).should be_true # forward bumped
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

  it "get(id) returns the held item; held_at_ms is a stable wall-clock (#123 snapshot)" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      result = Channel(Gori::Interceptor::Decision).new
      spawn { result.send(req(ic, "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")) }
      Fiber.yield
      item = ic.pending.first
      ic.get(item.id).not_nil!.host.should eq("acme.test")
      item.held_at_ms.should be > 0                                  # wall-clock captured once at hold
      ic.get(item.id).not_nil!.held_at_ms.should eq(item.held_at_ms) # never re-stamped
      ic.forward(item.id)
      result.receive
      ic.get(item.id).should be_nil # gone after forward
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
      scope.add("include", "host", "acme.test")
      scope.enable
      ic.intercepts_host?("acme.test").should be_true     # in scope
      ic.intercepts_host?("evil.test").should be_false    # out of scope
      ic.intercepts_host?("api.acme.test").should be_true # subdomain
    end
  end
end

describe "Gori::Interceptor direction + condition gates" do
  it "cycle_direction wraps Both → RequestOnly → ResponseOnly → Both" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.direction.should eq(Gori::Interceptor::Direction::Both)
      ic.cycle_direction.should eq(Gori::Interceptor::Direction::RequestOnly)
      ic.cycle_direction.should eq(Gori::Interceptor::Direction::ResponseOnly)
      ic.cycle_direction.should eq(Gori::Interceptor::Direction::Both)
    end
  end

  it "set_direction sets an explicit value idempotently, bumping revision only on change (#123)" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.direction.should eq(Gori::Interceptor::Direction::Both)
      r0 = ic.revision
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
      ic.direction.should eq(Gori::Interceptor::Direction::ResponseOnly)
      (ic.revision > r0).should be_true
      r1 = ic.revision
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly) # unchanged
      ic.revision.should eq(r1)                                    # idempotent: no bump
    end
  end

  it "honours the catch direction at the request/response gates" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle # enable (default Both)
      req_ok = -> { ic.intercepts_request?(method: "GET", host: "acme.test", target: "/x", scheme: "http") }
      res_ok = -> { ic.intercepts_response?(method: "GET", host: "acme.test", target: "/x", scheme: "http", status: 200) }

      req_ok.call.should be_true
      res_ok.call.should be_true

      ic.cycle_direction # RequestOnly
      req_ok.call.should be_true
      res_ok.call.should be_false

      ic.cycle_direction # ResponseOnly
      req_ok.call.should be_false
      res_ok.call.should be_true
    end
  end

  it "disabled → both gates closed regardless of direction" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.intercepts_request?(method: "GET", host: "acme.test", target: "/x", scheme: "http").should be_false
      ic.intercepts_response?(method: "GET", host: "acme.test", target: "/x", scheme: "http", status: 200).should be_false
    end
  end

  it "the condition filter narrows holding (matched against in-flight attrs)" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      ic.set_filter("method:POST")
      ic.intercepts_request?(method: "POST", host: "acme.test", target: "/x", scheme: "http").should be_true
      ic.intercepts_request?(method: "GET", host: "acme.test", target: "/x", scheme: "http").should be_false
    end
  end

  it "a status: condition holds only matching responses, never requests" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      ic.set_filter("status:>=500")
      ic.intercepts_response?(method: "GET", host: "acme.test", target: "/x", scheme: "http", status: 503).should be_true
      ic.intercepts_response?(method: "GET", host: "acme.test", target: "/x", scheme: "http", status: 200).should be_false
      ic.intercepts_request?(method: "GET", host: "acme.test", target: "/x", scheme: "http").should be_false
    end
  end

  it "bumps revision on cycle_direction / set_filter (drives the TUI redraw)" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      r0 = ic.revision
      ic.cycle_direction
      (ic.revision > r0).should be_true
      r1 = ic.revision
      ic.set_filter("host:acme")
      (ic.revision > r1).should be_true
    end
  end

  it "the condition still respects the Scope lens" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      ic = Gori::Interceptor.new(scope)
      ic.toggle
      scope.add("include", "host", "acme.test")
      scope.enable
      ic.set_filter("method:GET")
      ic.intercepts_request?(method: "GET", host: "acme.test", target: "/x", scheme: "http").should be_true
      ic.intercepts_request?(method: "GET", host: "evil.test", target: "/x", scheme: "http").should be_false # out of scope
    end
  end
end

describe "Gori::Scope host matching (intercept gate)" do
  it "matches exact host, subdomain, and glob via may_match_host?" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      scope.add("include", "host", "*.shop.test")
      scope.enable
      scope.may_match_host?("acme.test").should be_true
      scope.may_match_host?("api.acme.test").should be_true # subdomain
      scope.may_match_host?("notacme.test").should be_false
      scope.may_match_host?("a.shop.test").should be_true # glob
      scope.may_match_host?("shop.test").should be_false  # glob needs a label
    end
  end
end

# ABSOLUTE-FORM targets: the wire shape a plain-HTTP forward-proxy request arrives in
# (curl -x http://proxy http://site/path, or any client proxying a non-TLS site) — the
# request-line target IS the full URL, not a bare path. Interceptor#sandbox_blocks?/
# #scope_allows? must recognise that instead of re-prepending scheme://host onto it
# (which doubles into "http://hosthttp://host/path" and breaks an anchored/exact-match
# string or regex scope rule). Regression for the bug fixed alongside this spec.
describe "Interceptor scope gates over an ABSOLUTE-FORM target" do
  it "sandbox_blocks? evaluates an anchored regex include the same for absolute- and origin-form" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      ic = Gori::Interceptor.new(scope)
      scope.add("include", "regex", "^http://acme\\.test/")
      scope.enable
      scope.enable_sandbox

      # origin-form (HTTPS/CONNECT-style target: a bare path)
      ic.sandbox_blocks?("http", "acme.test", "/x").should be_false

      # absolute-form (plain-HTTP forward-proxy target: already the full URL)
      ic.sandbox_blocks?("http", "acme.test", "http://acme.test/x").should be_false
    end
  end

  it "intercepts_request? (scope_allows?) matches an absolute-form target against an anchored include" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      ic = Gori::Interceptor.new(scope)
      ic.toggle
      scope.add("include", "regex", "^http://acme\\.test/")
      scope.enable

      ic.intercepts_request?(method: "GET", host: "acme.test", target: "/x", scheme: "http").should be_true
      ic.intercepts_request?(method: "GET", host: "acme.test", target: "http://acme.test/x", scheme: "http").should be_true
    end
  end

  it "Scope.request_url recognises an absolute-form target regardless of scheme case" do
    # RFC 3986 §3.1: URI schemes are case-insensitive. A case-sensitive check here would
    # double an uppercase-scheme absolute-form target into "http://acmeHTTP://acme/x".
    Gori::Scope.request_url("http", "acme.test", "HTTP://acme.test/x").should eq("HTTP://acme.test/x")
    Gori::Scope.request_url("http", "acme.test", "HTTPS://acme.test/x").should eq("HTTPS://acme.test/x")
  end
end
