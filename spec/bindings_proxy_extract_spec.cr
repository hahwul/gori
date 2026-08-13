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

    # The gate answers "does this rule need the ENTITY", and a rule's CONDITION can need it
    # just as much as its extraction target does. A head-scoped descriptor whose condition
    # reads `body:` used to be counted as body-free, so ClientConn streamed past the body and
    # the condition was asked about bytes nobody kept.
    it "asks for a body when the CONDITION reads one, not just the target" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "body:logged-in", Gori::ExtractKind::Cookie, "sid",
          host: "alpha.test").should be_nil
        b.extracts_body?.should be_true
        b.extracts_body_for_host?("alpha.test").should be_true
        b.extracts_body_for_host?("beta.test").should be_false # still host-scoped
      end
    end

    # The negated spelling needs the bytes MORE, not less: with nothing buffered `body:x` is
    # false and `-body:x` negates it to a match on every response.
    it "asks for a body for a NEGATED body term too" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "-body:guest", Gori::ExtractKind::Cookie, "sid").should be_nil
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

    # `observe_response` is handed the head and the body and used to build a Subject from
    # neither, so a condition naming them answered false against bytes sitting in its own
    # argument list. This is the one surface that has BOTH.
    it "lets the condition read the response head" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "header:x-authoritative", Gori::ExtractKind::Cookie, "sid").should be_nil
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n")
        b.bound?("SESSION").should be_false # no such header ⇒ the rule does not claim it
        observe(b, "HTTP/1.1 200 OK\r\nX-Authoritative: 1\r\nSet-Cookie: sid=abc123\r\n\r\n")
        b.values["SESSION"].should eq "abc123"
      end
    end

    it "lets the condition read the response body" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "body:logged-in", Gori::ExtractKind::Cookie, "sid").should be_nil
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n", "guest page".to_slice)
        b.bound?("SESSION").should be_false
        observe(b, "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n", "you are logged-in".to_slice)
        b.values["SESSION"].should eq "abc123"
      end
    end

    # The boundary right next to "reaches a token inside a gzipped body" below, and the reason
    # that spec is not a contradiction: EXTRACTION decodes, the CONDITION does not. The condition
    # is evaluated before any decode on purpose (see `candidates`) — that is what stops a rule
    # from decompressing every response it is going to reject — so a `body:` term reads wire
    # bytes here exactly as it does on every other surface.
    it "reads WIRE bytes in the condition, even where extraction would decode" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "body:logged-in", Gori::ExtractKind::Cookie, "sid").should be_nil
        observe(b, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nSet-Cookie: sid=abc123\r\n\r\n",
          gzip("you are logged-in"))
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

    # One origin response, five descriptors, ONE value. `decoded_text` used to `#scrub` the
    # whole body before `regex`, `position` and `jsonpath` touched it, so an invalid UTF-8 byte
    # became U+FFFD and every `position` offset past it slid by two — a cookie rule returned the
    # origin's `41 42 FF 43 44` and a `position` rule asking for the same five bytes returned
    # five different ones. `bindings.cr` states the rule that breaks: "the same `TokenLoc` on
    # the same response has to mean one thing", and its own comment says "`Position` has no
    # text-only reading at all".
    describe "a body that is not valid UTF-8" do
      # `AB\xffCD` in the cookie, the header and the body — mint.py's `/login?m=nonutf8` shape.
      nonutf8_body = String.new(Bytes[0x7b, 0x22, 0x74, 0x22, 0x3a, 0x22, 0x41, 0x42, 0xff,
        0x43, 0x44, 0x22, 0x7d, 0x54, 0x4f, 0x4b, 0x45, 0x4e, 0x3d, 0x41, 0x42, 0xff, 0x43,
        0x44, 0x3b]) # {"t":"AB\xffCD"}TOKEN=AB\xffCD;
      head = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=" + String.new(Bytes[0x41, 0x42, 0xff, 0x43, 0x44]) +
             "\r\n\r\n"

      it "gives a position descriptor the origin's bytes, not a repaired reading" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("CTOK", "", Gori::ExtractKind::Cookie, "sid").should be_nil
          # bytes 6..10 of the body are exactly `AB\xffCD` — the same five the cookie carries.
          b.add("QTOK", "", Gori::ExtractKind::Position, "", 6, 11).should be_nil
          observe(b, head, nonutf8_body.to_slice)
          origin = Bytes[0x41, 0x42, 0xff, 0x43, 0x44]
          b.values["QTOK"].to_slice.should eq origin
          # The whole point: the two descriptors agree, byte for byte.
          b.values["QTOK"].should eq b.values["CTOK"]
        end
      end

      it "does not slide a range that starts past the invalid byte" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          # `TOKEN` — five bytes at 13..17, all AFTER the 0xff at offset 8. Under the scrubbed
          # reading this came back as `EN=AB` (the U+FFFD had pushed everything two along).
          b.add("PTOK", "", Gori::ExtractKind::Position, "", 13, 18).should be_nil
          observe(b, head, nonutf8_body.to_slice)
          b.values["PTOK"].should eq "TOKEN"
        end
      end

      it "is unaffected by an invalid byte AFTER the requested range" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          # bytes 0..5 are `{"t":"`, entirely before the 0xff at 8.
          b.add("PTOK", "", Gori::ExtractKind::Position, "", 0, 6).should be_nil
          observe(b, head, nonutf8_body.to_slice)
          b.values["PTOK"].should eq %({"t":")
        end
      end

      it "returns the invalid byte itself when the range ends exactly on it" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("PTOK", "", Gori::ExtractKind::Position, "", 6, 9).should be_nil
          observe(b, head, nonutf8_body.to_slice)
          b.values["PTOK"].to_slice.should eq Bytes[0x41, 0x42, 0xff]
        end
      end

      # `Regex` and `JsonPath` genuinely need a valid subject — Crystal's `Regex` raises
      # `ArgumentError` otherwise — so the scrub STAYS there. What must not stay is it being
      # silent: binding bytes that are not the origin's without saying so is the one option
      # ruled out. Refusing outright was rejected: a page in a legacy encoding with a CSRF
      # token in it is an ordinary target and refusing would break a case that works today.
      it "binds a regex descriptor but says the body was repaired" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("RTOK", "", Gori::ExtractKind::Regex, "TOKEN=([\\s\\S]*?);").should be_nil
          observe(b, head, nonutf8_body.to_slice)
          b.bound?("RTOK").should be_true
          ev = store.events_after(0, 50).find { |e| e.kind == "extract_scrubbed" }.not_nil!
          ev.level.should eq("warn")
          ev.message.should contain("$RTOK")
          ev.message.should contain("not valid UTF-8")
          ev.message.should contain("U+FFFD")
        end
      end

      # Once per rule per rule revision, the same key `extract_no_body` uses: this is a
      # structural fact about the target's body, so it is news when the operator edits the
      # rule and noise on every subsequent response.
      it "says it once per rule, not once per response" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("RTOK", "", Gori::ExtractKind::Regex, "TOKEN=([\\s\\S]*?);").should be_nil
          5.times { observe(b, head, nonutf8_body.to_slice) }
          store.events_after(0, 50).count { |e| e.kind == "extract_scrubbed" }.should eq 1
        end
      end

      # The COMPLEMENT of the condition the advisory keys on, in both directions.
      it "says nothing for a valid-UTF-8 body, and nothing for a byte-scoped descriptor" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("RTOK", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
          observe(b, "HTTP/1.1 200 OK\r\n\r\n", "tok=swordfish".to_slice)
          b.values["RTOK"].should eq "swordfish"
          store.events_after(0, 50).any? { |e| e.kind == "extract_scrubbed" }.should be_false
        end
        with_store do |store|
          b = Gori::Bindings.load(store)
          # `position` reads bytes, so an invalid body costs it nothing and says nothing.
          b.add("PTOK", "", Gori::ExtractKind::Position, "", 6, 11).should be_nil
          b.add("CTOK", "", Gori::ExtractKind::Cookie, "sid").should be_nil
          observe(b, head, nonutf8_body.to_slice)
          store.events_after(0, 50).any? { |e| e.kind == "extract_scrubbed" }.should be_false
        end
      end

      # A gzip body is the case `Position`'s own comment names — "forty bytes of DEFLATE" —
      # so the range must land on the DECODED entity and be byte-exact there too.
      it "slices the decoded entity of a gzipped body, byte-exact" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("PTOK", "", Gori::ExtractKind::Position, "", 6, 11).should be_nil
          observe(b, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n", gzip(nonutf8_body))
          b.values["PTOK"].to_slice.should eq Bytes[0x41, 0x42, 0xff, 0x43, 0x44]
        end
      end

      it "slices the de-chunked entity of a chunked body, byte-exact" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("PTOK", "", Gori::ExtractKind::Position, "", 6, 11).should be_nil
          observe(b, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            chunked(nonutf8_body[0, 4], nonutf8_body[4..]))
          b.values["PTOK"].to_slice.should eq Bytes[0x41, 0x42, 0xff, 0x43, 0x44]
        end
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
