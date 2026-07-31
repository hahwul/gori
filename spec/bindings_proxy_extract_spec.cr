require "./spec_helper"
require "compress/gzip"

# Session bindings (#501), slice 2: the `Proxy::ResponseExtract` half of `Gori::Bindings` —
# the gates the proxy response path keys on, and `observe_response` itself.
#
# The gates are pinned as hard as the behaviour, because they are what makes slice 2 safe to
# put on the hot path at all: a proxy with no extract rule must buffer nothing (P6), and a
# body-scoped rule must cost its own hosts an h2 downgrade and no others (#526/#531).

private def with_store(&)
  path = File.tempname("gori-bindings-proxy", ".db")
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

private def gzip(text : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io, &.write(text.to_slice))
  io.to_slice
end

# A wire body in h1 chunked framing — what `Transfer-Encoding: chunked` actually puts on the
# socket, and what the proxy forwards byte-exact when no rule changed it.
private def chunked(*parts : String) : Bytes
  io = IO::Memory.new
  parts.each { |p| io << p.bytesize.to_s(16) << "\r\n" << p << "\r\n" }
  io << "0\r\n\r\n"
  io.to_slice
end

private def observe(bindings : Gori::Bindings, head : String, body : Bytes? = nil,
                    host : String = "acme.test", target : String = "/login",
                    method : String = "POST", status : Int32 = 200) : Nil
  bindings.observe_response(head.to_slice, body,
    method: method, host: host, target: target, scheme: "https", status: status)
end

# The deliberate-send shape of the same observation, for the contrast the throttle draws
# between one operator action and one response off the proxy.
private def sent(head : String) : {Gori::Repeater::Result, Gori::InterceptFilter::Subject}
  bytes = head.to_slice
  result = Gori::Repeater::Result.new(bytes, Bytes.empty,
    Gori::Proxy::Codec::Http1.parse_response_head(bytes), 1_i64, nil)
  subject = Gori::InterceptFilter::Subject.new(method: "POST", host: "acme.test",
    target: "/login", scheme: "https", status: 200)
  {result, subject}
end

describe "Gori::Bindings — the proxy response seam (#501 slice 2)" do
  describe "the gates the hot path reads" do
    it "reports nothing live when no rule exists" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.extracts?.should be_false
        b.extracts_body?.should be_false
        b.extracts_body_for_host?("acme.test").should be_false
      end
    end

    it "a head-scoped rule is live but never asks for a body" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid").should be_nil
        b.extracts?.should be_true
        # The whole point: a `Set-Cookie` descriptor reads the parsed head, so it must not
        # cost a response its streaming (P6) — nor an h2 host its protocol.
        b.extracts_body?.should be_false
        b.extracts_body_for_host?("acme.test").should be_false
      end
    end

    it "a body-scoped rule asks for a body" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "path:/login", Gori::ExtractKind::Regex, "name=\"csrf\" value=\"([a-f0-9]+)\"").should be_nil
        b.extracts_body?.should be_true
      end
    end

    it "disabling the rule takes both gates back down" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
        b.toggle(b.rules.first.id)
        b.extracts?.should be_false
        b.extracts_body?.should be_false
      end
    end

    # #526/#531. The h2 downgrade gate costs a host its protocol, so it must be asked about
    # THAT host. A rule scoped to `alpha.test` downgrading `127.0.0.1` is the regression #531
    # fixed for Match&Replace, and adding a second rule table with the host-blind shape would
    # be the same bug wearing different clothes.
    it "scopes the h2 downgrade to the hosts the rule's glob can match" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)", host: "alpha.test").should be_nil
        b.extracts_body_for_host?("alpha.test").should be_true
        b.extracts_body_for_host?("api.alpha.test").should be_true # substring dialect
        b.extracts_body_for_host?("127.0.0.1").should be_false
        b.extracts_body_for_host?("beta.test").should be_false
      end
    end

    it "an unscoped body rule still downgrades everywhere" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
        b.extracts_body_for_host?("127.0.0.1").should be_true
      end
    end

    it "a wildcard glob is anchored, like the Rewriter's" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)", host: "*.alpha.test").should be_nil
        b.extracts_body_for_host?("api.alpha.test").should be_true
        b.extracts_body_for_host?("alpha.test.evil.com").should be_false
      end
    end
  end

  describe "#observe_response" do
    it "binds a cookie off a delivered head, with no body at all" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid").should be_nil
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123; HttpOnly\r\n\r\n")
        b.bound?("SESSION").should be_true
        b.values["SESSION"].should eq "abc123"
      end
    end

    it "does not bind when the rule's condition does not select the response" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "path:/login AND status:200", Gori::ExtractKind::Cookie, "sid").should be_nil
        observe(b, "HTTP/1.1 302 Found\r\nSet-Cookie: sid=abc123\r\n\r\n", status: 302)
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n", target: "/logout")
        b.bound?("SESSION").should be_false
      end
    end

    it "does not bind when the rule's host glob does not match" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid", host: "alpha.test").should be_nil
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n", host: "beta.test")
        b.bound?("SESSION").should be_false
      end
    end

    # The `ContentDecode` decision the design left open, settled: body-scoped extraction
    # ALWAYS decodes, through the same `TokenExtract` path slice 1's Repeater send takes.
    # A per-rule opt-in flag would let a rule silently never fire on the commonest shape
    # there is — a gzipped HTML login page.
    it "reaches a token inside a gzipped body" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "path:/login", Gori::ExtractKind::Regex,
          "name=\"csrf\" value=\"([a-f0-9]+)\"").should be_nil
        body = gzip(%(<form><input name="csrf" value="deadbeef01"></form>))
        observe(b, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Type: text/html\r\n\r\n", body)
        b.values["CSRF"].should eq "deadbeef01"
      end
    end

    it "reaches a token inside a chunked body without de-chunking it twice" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
        # The head and the body are handed over as the proxy FORWARDED them, so the body is
        # still chunk-framed and the head still says so. Handing over an already de-chunked
        # body with this head would make `ContentDecode` de-chunk it a second time.
        observe(b, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
          chunked("tok=", "swordfish"))
        b.values["CSRF"].should eq "swordfish"
      end
    end

    it "reaches a token inside a body that is both chunked and gzipped" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::JsonPath, "$.csrf").should be_nil
        raw = gzip(%({"csrf":"t0ken","ok":true}))
        io = IO::Memory.new
        io << raw.size.to_s(16) << "\r\n"
        io.write(raw)
        io << "\r\n0\r\n\r\n"
        observe(b, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Encoding: gzip\r\n\r\n",
          io.to_slice)
        b.values["CSRF"].should eq "t0ken"
      end
    end

    it "keeps the previous value when the extractor finds nothing" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=first\r\n\r\n")
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: other=x\r\n\r\n")
        b.values["SESSION"].should eq "first"
        store.events_after(0, 50).any? { |e| e.kind == "extract_miss" }.should be_true
      end
    end

    # A body-scoped rule matching a response gori never buffered (SSE, close-delimited, a 101,
    # a body over the ceiling, or the h2 relay) has to say WHICH it was. "found nothing" would
    # blame the operator's selector for gori's own framing decision.
    it "names gori's own decision when a body-scoped rule gets no body" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
        observe(b, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n", nil)
        events = store.events_after(0, 50)
        events.count { |e| e.kind == "extract_no_body" }.should eq 1
        events.any? { |e| e.kind == "extract_miss" }.should be_false
        b.bound?("CSRF").should be_false
      end
    end

    # Same flood, same key, and the far more common half: a cookie descriptor scoped to a
    # host the operator is browsing misses on every subresource, and each row was a
    # synchronous store write ON the proxy response path.
    it "reports a plain miss once per rule too, not once per response" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        20.times { observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: other=x\r\n\r\n") }
        store.events_after(0, 100).count { |e| e.kind == "extract_miss" }.should eq 1
      end
    end

    # The throttle is keyed on the binding revision, not latched: once something actually
    # moves — a rebind here — the rule missing again is news again.
    it "reports a plain miss again after a rebind moves the revision" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: other=x\r\n\r\n")
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n") # binds → @rev moves
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: other=x\r\n\r\n")
        store.events_after(0, 100).count { |e| e.kind == "extract_miss" }.should eq 2
      end
    end

    # A deliberate `#observe` (one Repeater send) is one operator action, so it is never
    # throttled — they asked for that send and want to hear about each one.
    it "does not throttle a deliberate single send" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        raw, subject = sent("HTTP/1.1 200 OK\r\nSet-Cookie: other=x\r\n\r\n")
        3.times { b.observe(raw, subject) }
        store.events_after(0, 100).count { |e| e.kind == "extract_miss" }.should eq 3
      end
    end

    it "says it once per rule, not once per response" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
        5.times { observe(b, "HTTP/1.1 200 OK\r\n\r\n", nil) }
        store.events_after(0, 50).count { |e| e.kind == "extract_no_body" }.should eq 1
      end
    end

    # An EMPTY buffered body is a body gori has, so a miss on it is an ordinary miss.
    it "treats a buffered-but-empty body as a body it has" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
        observe(b, "HTTP/1.1 204 No Content\r\n\r\n", Bytes.empty, status: 204)
        events = store.events_after(0, 50)
        events.any? { |e| e.kind == "extract_no_body" }.should be_false
        events.any? { |e| e.kind == "extract_miss" }.should be_true
      end
    end

    it "never raises into the proxy path on a head it cannot parse" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        observe(b, "\xff\xfe not a head at all")
        b.bound?("SESSION").should be_false
      end
    end

    it "does nothing at all when nothing is configured" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n")
        store.events_after(0, 50).should be_empty
      end
    end
  end
end
