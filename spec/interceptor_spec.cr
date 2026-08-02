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
      d = receive_within(result)
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
      receive_within(result)
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
      receive_within(result).action.should eq(Gori::Interceptor::Action::Drop)
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
      receive_within(result)
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
      receive_within(result).action.should eq(Gori::Interceptor::Action::Forward)
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
      2.times { receive_within(done) }
      ic.pending_count.should eq(0)
    end
  end

  # #492 step 3 split `hold` into `enqueue` + `receive` so the h2 relay can wait on a decision
  # off its pump fiber. `Interceptor` is SHARED with h1, so these pin the h1 side: the hold is
  # still one blocking call, resolving to the exact decision bytes, gated in the same places.
  it "h1 hold_request is unchanged by the enqueue split: one blocking call, byte-exact result" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      result = Channel(Gori::Interceptor::Decision).new
      spawn { result.send(req(ic, "GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n")) }
      Fiber.yield

      # It BLOCKS — nothing has been decided, so nothing has come back.
      select
      when result.receive
        fail "hold_request returned before a decision"
      when timeout(5.milliseconds)
      end
      ic.pending_count.should eq(1)
      item = ic.pending.first
      item.kind.should eq(Gori::Interceptor::Kind::Request)
      item.method.should eq("GET")

      ic.forward(item.id) # no override → the ORIGINAL bytes, byte-exact
      d = receive_within(result)
      d.action.should eq(Gori::Interceptor::Action::Forward)
      String.new(d.bytes).should eq("GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      ic.pending_count.should eq(0)
    end
  end

  it "h1 hold_* and h2 enqueue_* short-circuit on exactly the same gates" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      ic = Gori::Interceptor.new(scope)

      # Disabled: hold returns Forward(original) synchronously, enqueue returns nil. Same gate.
      req(ic, "GET / HTTP/1.1\r\n\r\n").action.should eq(Gori::Interceptor::Action::Forward)
      ic.enqueue_request("GET / HTTP/1.1\r\n\r\n".to_slice,
        method: "GET", target: "/", host: "acme.test", port: 80, scheme: "http").should be_nil

      # Out of scope: same again, on both.
      ic.toggle
      scope.add("include", "host", "other.test")
      scope.enable
      req(ic, "GET / HTTP/1.1\r\n\r\n").action.should eq(Gori::Interceptor::Action::Forward)
      ic.enqueue_request("GET / HTTP/1.1\r\n\r\n".to_slice,
        method: "GET", target: "/", host: "acme.test", port: 80, scheme: "http").should be_nil
      ic.pending_count.should eq(0)

      # Shutting down: latched, so neither enqueues.
      scope.add("include", "host", "acme.test")
      ic.release_all
      ic.enqueue_request("GET / HTTP/1.1\r\n\r\n".to_slice,
        method: "GET", target: "/", host: "acme.test", port: 80, scheme: "http").should be_nil
    end
  end

  it "hold_response still takes an Int64 flow_id from h1 (the h2 path is what needs nil)" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      spawn do
        ic.hold_response("HTTP/1.1 200 OK\r\n\r\n".to_slice, flow_id: 7_i64, method: "GET",
          target: "200 OK", host: "acme.test", port: 80, scheme: "http")
      end
      Fiber.yield
      ic.pending.first.flow_id.should eq(7_i64)

      item = ic.enqueue_response("HTTP/1.1 200 OK\r\n\r\n".to_slice, flow_id: nil, method: "GET",
        target: "200", host: "acme.test", port: 80, scheme: "http")
      item.not_nil!.flow_id.should be_nil
      ic.release_all
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

  describe "the WebSocket gates (#500 step 2)" do
    it "holds nothing on WS without an explicit proto:ws term, whatever the filter says" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        # A blank filter matches every HTTP message and still arms nothing on WebSocket —
        # design D1, and the exact inverse of the HTTP default. An ordinary host condition
        # that WOULD match this socket does not arm it either: a filter typed for HTTP must
        # never freeze every socket on the host.
        {"", "host:acme.test", "-proto:ws", "proto:grpc"}.each do |query|
          ic.set_filter(query)
          ic.arms_ws_hold?("acme.test", to_server: true).should be_false
          ic.intercepts_ws?(to_server: true, method: "GET", host: "acme.test", target: "/ws",
            scheme: "http", payload: "anything".to_slice).should be_false
        end
      end
    end

    it "holds on WS once the condition carries proto:ws, and narrows with body:" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        ic.set_filter("proto:ws body:subscribe")
        ic.arms_ws_hold?("acme.test", to_server: true).should be_true
        ic.intercepts_ws?(to_server: true, method: "GET", host: "acme.test", target: "/ws",
          scheme: "http", payload: %({"op":"subscribe"}).to_slice).should be_true
        ic.intercepts_ws?(to_server: true, method: "GET", host: "acme.test", target: "/ws",
          scheme: "http", payload: %({"op":"ping"}).to_slice).should be_false
      end
    end

    it "respects the catch direction on both legs" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        ic.set_filter("proto:ws")
        ic.set_direction(Gori::Interceptor::Direction::RequestOnly)
        ic.arms_ws_hold?("acme.test", to_server: true).should be_true
        ic.arms_ws_hold?("acme.test", to_server: false).should be_false
        ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
        ic.arms_ws_hold?("acme.test", to_server: true).should be_false
        ic.arms_ws_hold?("acme.test", to_server: false).should be_true
      end
    end

    it "arms nothing while catch is OFF, so an unarmed socket pays nothing per message" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.set_filter("proto:ws") # catch never toggled on
        ic.arms_ws_hold?("acme.test", to_server: true).should be_false
      end
    end

    it "queues a WS message under its own Kind, carrying the handshake's identity" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        ic.set_filter("proto:ws")
        item = ic.enqueue_ws("hi".to_slice, to_server: true, method: "GET", target: "/ws",
          host: "acme.test", port: 443, scheme: "https", flow_id: 9_i64, binary: false).not_nil!
        item.kind.should eq(Gori::Interceptor::Kind::WsOut)
        item.kind.ws?.should be_true
        item.binary?.should be_false
        # The message has no authority, scheme or path of its own — these are the 101's, and
        # they are what a scope test and the queue row's label read.
        item.host.should eq("acme.test")
        item.target.should eq("/ws")
        item.scheme.should eq("https")
        item.flow_id.should eq(9_i64)

        inbound = ic.enqueue_ws(Bytes[0xFF], to_server: false, method: "GET", target: "/ws",
          host: "acme.test", port: 443, scheme: "https", flow_id: 9_i64, binary: true).not_nil!
        inbound.kind.should eq(Gori::Interceptor::Kind::WsIn)
        inbound.binary?.should be_true
      end
    end
  end
  # R2-F5. The ack for a forward/drop/edit is the agent's and the script's ONLY receipt for an
  # irreversible action on a held message, and one expression composed it for every kind:
  # `"#{method} #{host}#{target}"`. `Item#target` is deliberately overloaded per kind, so a
  # proxied h1 request doubled its authority and a held response welded the host to the status
  # line — `POST 127.0.0.1200 OK`, which reads as HTTP status 1200.
  describe "Item#label" do
    it "does not double the authority of an absolute-form (forward-proxy) request target" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        item = ic.enqueue_request("x".to_slice, method: "POST",
          target: "http://127.0.0.1:19201/held", host: "127.0.0.1", port: 19201,
          scheme: "http").not_nil!
        item.label.should eq("POST 127.0.0.1/held")
      end
    end

    it "leaves an origin-form request target alone (the case that always read correctly)" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        item = ic.enqueue_request("x".to_slice, method: "POST", target: "/held",
          host: "127.0.0.1", port: 19201, scheme: "http").not_nil!
        item.label.should eq("POST 127.0.0.1/held")
      end
    end

    it "separates a response's status line from the host" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        h1 = ic.enqueue_response("x".to_slice, flow_id: 1_i64, method: "POST", target: "200 OK",
          host: "127.0.0.1", port: 19201, scheme: "http").not_nil!
        h1.label.should eq("POST 127.0.0.1 -> 200 OK")
        h1.label.should_not contain("127.0.0.1200")
        # h2 has no reason phrase (RFC 9113 §8.3.2), so its response target is the bare code.
        h2 = ic.enqueue_response("x".to_slice, flow_id: 2_i64, method: "GET", target: "200",
          host: "api.test", port: 443, scheme: "https").not_nil!
        h2.label.should eq("GET api.test -> 200")
      end
    end

    it "identifies WHICH message on a socket, since every row on it shares the handshake" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        out = ic.enqueue_ws("hello".to_slice, to_server: true, method: "GET", target: "/ws",
          host: "acme.test", port: 443, scheme: "https", flow_id: 9_i64, binary: false).not_nil!
        out.label.should eq("acme.test/ws client->server 5B")
        back = ic.enqueue_ws(Bytes[0xFF, 0xFE], to_server: false, method: "GET", target: "/ws",
          host: "acme.test", port: 443, scheme: "https", flow_id: 9_i64, binary: true).not_nil!
        back.label.should eq("acme.test/ws server->client 2B")
      end
    end

    # R9/F1-b. `apply_intercept_command`'s "edited" ack used to pass `desc = item.label`
    # (computed BEFORE the edit, off the item's ORIGINAL held bytes) unconditionally — so an
    # edit that legitimately changes a WS message's length acked the WRONG size: the caller's
    # only receipt for an irreversible forward named bytes that never went on the wire. `size:`
    # lets the settle side report what it is ACTUALLY about to forward.
    it "reports the size the caller PASSES, not the held item's original raw size (#123 ack fix)" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        out = ic.enqueue_ws("line1\nline2\nline3".to_slice, to_server: true, method: "GET",
          target: "/ws", host: "acme.test", port: 443, scheme: "https", flow_id: 9_i64,
          binary: false).not_nil!
        out.raw.size.should eq(17)
        # An edit that grows the payload (e.g. appends text) must ack the NEW size.
        out.label(size: 19).should eq("acme.test/ws client->server 19B")
        # The default (no size: argument) still reflects the HELD bytes, for a plain
        # forward/drop where nothing was rewritten.
        out.label.should eq("acme.test/ws client->server 17B")
      end
    end

    # `size:` is a no-op for request/response — neither branch of `Item#label`'s case renders a
    # byte count — so passing it from the one shared call site in `apply_intercept_command`
    # cannot regress an HTTP ack (the complement `size:` has to hold).
    it "ignores size: for a request/response label — only the WS branches render a byte count" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        req = ic.enqueue_request("x".to_slice, method: "GET", target: "/held",
          host: "127.0.0.1", port: 19201, scheme: "http").not_nil!
        req.label(size: 999).should eq(req.label)
        req.label(size: 999).should eq("GET 127.0.0.1/held")
      end
    end

    # R4. The composition is ONE definition now: `InterceptView#row_label` and
    # `InterceptController#intercept_label` had their own per-kind branches and call this
    # instead, passing the EDITED method/target so a queue row and a forward toast name the
    # message about to be sent rather than the hold-time metadata. Same rule either way —
    # which is the point, since three separate branches is how `POST 127.0.0.1200 OK` shipped.
    it "composes an OVERRIDDEN method/target by exactly the same rule" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        req = ic.enqueue_request("x".to_slice, method: "GET", target: "/held",
          host: "127.0.0.1", port: 19201, scheme: "http").not_nil!
        # A GET the operator edited into a PUT against another path, absolute-form and all.
        req.label("PUT", "http://127.0.0.1:19201/edited").should eq("PUT 127.0.0.1/edited")
        # An unedited call is the no-argument one.
        req.label(req.method, req.target).should eq(req.label)

        resp = ic.enqueue_response("x".to_slice, flow_id: 1_i64, method: "POST", target: "200 OK",
          host: "127.0.0.1", port: 19201, scheme: "http").not_nil!
        # A 200→201 status edit, which is what the editor's first line gives back.
        resp.label("POST", "201 CREATED").should eq("POST 127.0.0.1 -> 201 CREATED")
        resp.label("POST", "201 CREATED").should_not contain("127.0.0.1201")
      end
    end
  end

  # The head/body boundary an intercept edit is split on. Shared with `H2::StreamGate`, which
  # encodes the head half, so the surface that acks the edit and the gate that applies it
  # cannot disagree about whether an edit added a body.
  describe ".split_edit" do
    it "takes the EARLIEST blank line in either spelling" do
      head, body = Gori::Interceptor.split_edit("GET / HTTP/2\r\nHost: h\r\n\r\nBODY".to_slice)
      String.new(head).should eq("GET / HTTP/2\r\nHost: h\r\n\r\n")
      body.should be_true
      # LF-joined head (what the intercept editor's TextArea produces) whose BODY carries a
      # CRLFCRLF: preferring the CRLF form took the boundary INSIDE the body.
      head, body = Gori::Interceptor.split_edit("GET / HTTP/2\nHost: h\n\nA\r\n\r\nB".to_slice)
      String.new(head).should eq("GET / HTTP/2\nHost: h\n\n")
      body.should be_true
    end

    it "reports no body for a head-only edit, in either spelling" do
      Gori::Interceptor.split_edit("GET / HTTP/2\r\nHost: h\r\n\r\n".to_slice)[1].should be_false
      Gori::Interceptor.split_edit("GET / HTTP/2\nHost: h\n\n".to_slice)[1].should be_false
      # No blank line at all: the whole thing is the head.
      Gori::Interceptor.split_edit("GET / HTTP/2".to_slice)[1].should be_false
    end
  end
  # R3-F1/F2, the surface half. `refuse_edit` is what every surface that offers an edit asks
  # BEFORE it decides, because the settle side can only discard — and discarding after an ack
  # is how "edited: GET 127.0.0.1/unf3" came to mean "the original went on the wire".
  describe "Item#refuse_edit" do
    it "refuses every edit to a message gori cannot apply one to, and says why" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        item = ic.enqueue_request("GET /unf3 HTTP/2\r\nHost: h\r\n\r\n".to_slice, method: "GET",
          target: "/unf3", host: "h", port: 443, scheme: "https", head_only: true,
          edit_refusal: "the value of \"x-evil\" carries a CR or LF").not_nil!
        item.refuse_edit("GET /OPERATOR-EDIT HTTP/2\r\nHost: h\r\n\r\n".to_slice)
          .not_nil!.should contain("x-evil")
        # ...including one that changes nothing structural: the refusal is about the MESSAGE.
        item.refuse_edit(item.raw).not_nil!.should contain("x-evil")
      end
    end

    it "refuses a body added to a head-only (h2) hold, and allows a head-only edit" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        item = ic.enqueue_request("GET /p HTTP/2\r\nHost: h\r\n\r\n".to_slice, method: "GET",
          target: "/p", host: "h", port: 443, scheme: "https", head_only: true).not_nil!
        item.refuse_edit("GET /edited HTTP/2\r\nHost: h\r\n\r\nOPERATORBODY".to_slice)
          .not_nil!.should contain("HEAD only")
        # Complement: the same edit without a body is applied.
        item.refuse_edit("GET /edited HTTP/2\r\nHost: h\r\n\r\n".to_slice).should be_nil
        # ...and so is one that only declares a content-length. That value is the operator's
        # RFC 9113 §8.1.1 probe, not a body.
        item.refuse_edit("POST /edited HTTP/2\r\nHost: h\r\ncontent-length: 3\r\n\r\n".to_slice)
          .should be_nil
      end
    end

    it "leaves an h1 hold (head AND body) free to carry a body, as it always has" do
      with_store do |store|
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        item = ic.enqueue_request("POST /p HTTP/1.1\r\nHost: h\r\n\r\nab".to_slice, method: "POST",
          target: "/p", host: "h", port: 80, scheme: "http").not_nil!
        item.head_only?.should be_false
        item.edit_refusal.should be_nil
        item.refuse_edit("POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\n\r\nZZZZ".to_slice)
          .should be_nil
      end
    end
  end
end
