require "../spec_helper"
require "socket"

private alias F = Gori::Fuzz

# What `Fuzz::Engine#follow_redirects` does to the two facts the hop must carry.
#
# The follower is twenty-four lines that round 4 never touched while both of the things it
# handles changed underneath it, and it got both wrong in the same way — by calling a
# neighbouring API positionally:
#
#   1. It called the ONE-argument `Backend#send`, i.e. "no verbatim exclusions", so round 4's
#      payload-span exclusion was dropped at the hop. Against an origin that reflects a query
#      parameter into `Location` — an ordinary login/redirect endpoint, and exactly what an
#      open-redirect probe aims at — `--payloads '$TOKEN'` put the live session credential in
#      the target's query string and access log while every surface still showed `$TOKEN`.
#   2. It rebuilt `Repeater::Result` with eight POSITIONAL arguments, so `retried` landed in
#      `timed_out`: every keep-alive re-send in a redirect-following sweep lost its row marker
#      and gained a `timed_out` nothing had observed.
#
# Both are asserted here on the ONE thing that settles them — the bytes an origin received,
# and the fields a surface reads — with the no-redirect control beside each.

private def with_clean_env(&)
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  yield
ensure
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
end

private def with_hop_store(&)
  path = File.tempname("gori-redirect-hop", ".db")
  store = Gori::Store.open(path)
  begin
    with_clean_env { yield store }
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def with_layer(layer : Gori::Env::Layer?, &)
  previous = Gori::Env.layer
  Gori::Env.layer = layer
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

# `name` DECLARED and BOUND to `value`, reached the only way a real session reaches it: by
# observing a response. A hand-poked hash would not prove the send path consults the same one.
private def bound(store : Gori::Store, name : String, value : String) : Gori::Bindings
  b = Gori::Bindings.load(store)
  b.add(name, "", Gori::ExtractKind::Cookie, "sid").should be_nil
  head = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=#{value}; Path=/\r\nContent-Length: 0\r\n\r\n"
  parsed = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
  b.observe(Gori::Repeater::Result.new(head.to_slice, Bytes.empty, parsed, 1_i64, nil),
    Gori::InterceptFilter::Subject.new(method: "GET", host: "acme.test", target: "/login",
      scheme: "https", status: 200))
  b.values[name]?.should eq(value)
  b
end

# An origin that REFLECTS the request's query string into its `Location`, which is the whole
# mechanism: it is how the operator's payload bytes reappear inside a request gori synthesised
# rather than one it was given. `redirects` says how many hops to answer before the 200.
private class ReflectingOrigin
  getter port : Int32
  getter requests = [] of String

  def initialize(@redirects : Int32 = 1, @server : TCPServer = TCPServer.new("127.0.0.1", 0))
    @port = @server.local_address.port
  end

  def serve : Nil
    spawn do
      hop = 0
      while conn = @server.accept?
        conn.read_timeout = 5.seconds
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        break unless head
        text = String.new(head)
        @requests << text
        line = text.split("\r\n", 2)[0]
        target = line.split(' ')[1]? || "/"
        query = target.includes?('?') ? target.split('?', 2)[1] : ""
        conn << if hop < @redirects
          "HTTP/1.1 302 Found\r\nLocation: /hop#{hop + 1}?#{query}\r\n" \
          "Content-Length: 0\r\nConnection: close\r\n\r\n"
        else
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        end
        conn.flush
        conn.close
        hop += 1
      end
    rescue
    ensure
      @server.close rescue nil
    end
  end

  def close : Nil
    @server.close rescue nil
  end
end

private def outbound_any : Gori::Outbound
  Gori::Outbound.cli(nil, false)
end

# One single-payload run through the real Sender against `origin`.
private def run_against(origin : ReflectingOrigin, template : String, payload : String,
                        follow : Bool = true) : Array(F::Result)
  tpl = F::Template.parse(template.gsub("{PORT}", origin.port))
  cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, follow_redirects: follow,
    max_redirects: 3, timeout: 2.seconds)
  gen = F::Generator.new(tpl, [F::PayloadSet.new(F::InlineList.new([payload]))], cfg)
  backend = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), outbound_any,
    http2: false, verify: false)
  results = [] of F::Result
  F::Engine.new(gen, F::Matcher.new, backend, cfg).run do |ev|
    results << ev.result if ev.is_a?(F::ResultEvent)
  end
  results
end

# ─── the retried/timed_out half: a Backend double, so the two flags are set exactly ───

# Returns a canned Result per call, so an example can put `retried` (or `timed_out`) on any
# hop of the chain and read back what the collapsed Result carries.
private class ScriptedBackend < F::Backend
  getter sent = [] of Bytes
  getter verbatim = [] of Array({Int32, Int32})?

  def initialize(@replies : Array(Gori::Repeater::Result))
  end

  def origin : F::Origin
    F::Origin.new("http", "127.0.0.1", 9)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    send(bytes, nil)
  end

  def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Gori::Repeater::Result
    @sent << bytes.dup
    @verbatim << verbatim
    @replies[@sent.size - 1]? || @replies.last
  end
end

private def reply(status : Int32, location : String? = nil, retried : Bool = false,
                  timed_out : Bool = false) : Gori::Repeater::Result
  head = String.build do |io|
    io << "HTTP/1.1 " << status << (status == 302 ? " Found" : " OK") << "\r\n"
    io << "Location: " << location << "\r\n" if location
    io << "Content-Length: 2\r\n\r\n"
  end
  Gori::Repeater::Result.new(head.to_slice, "ok".to_slice,
    Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice), 100_i64,
    retried: retried, timed_out: timed_out)
end

private def follow(replies : Array(Gori::Repeater::Result),
                   template : String = "GET /start?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n",
                   follow : Bool = true) : {F::Result, ScriptedBackend}
  tpl = F::Template.parse(template)
  cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, follow_redirects: follow,
    max_redirects: 3)
  gen = F::Generator.new(tpl, [F::PayloadSet.new(F::InlineList.new(["one"]))], cfg)
  backend = ScriptedBackend.new(replies)
  out = [] of F::Result
  F::Engine.new(gen, F::Matcher.new, backend, cfg).run do |ev|
    out << ev.result if ev.is_a?(F::ResultEvent)
  end
  {out.first, backend}
end

# ─────────────────────────────────────────────────────────────────────────────────────

describe "Fuzz::Engine#follow_redirects — the hop's provenance" do
  it "does not resolve a session binding into a hop the ORIGIN's Location chose" do
    with_hop_store do |store|
      origin = ReflectingOrigin.new(redirects: 1)
      origin.serve
      with_layer(bound(store, "TOKEN", "SECRETTOKEN123")) do
        results = run_against(origin,
          "GET /redir?q=§X§ HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nAuthorization: Bearer $TOKEN\r\n\r\n",
          "$TOKEN")
        results.size.should eq(1)
        results[0].error.should be_nil
        origin.requests.size.should eq(2) # the hop really was followed

        # Hop 1 — round 4's fix, and the control that a binding IS live in this run: the
        # TEMPLATE's `$TOKEN` resolves, the PAYLOAD's does not.
        origin.requests[0].should contain("/redir?q=$TOKEN")
        origin.requests[0].should contain("Bearer SECRETTOKEN123")
        origin.requests[0].should_not contain("q=SECRETTOKEN123")

        # Hop 2 — gori assembled it from the origin's `Location`, which reflected the payload
        # straight back. Nothing in it is a `$NAME` anybody typed, so nothing in it resolves.
        origin.requests[1].should contain("/hop1?q=$TOKEN")
        origin.requests[1].should_not contain("SECRETTOKEN123")
      end
      origin.close
    end
  end

  it "keeps every hop of a MULTI-hop chain verbatim, not only the first" do
    with_hop_store do |store|
      origin = ReflectingOrigin.new(redirects: 3)
      origin.serve
      with_layer(bound(store, "TOKEN", "SECRETTOKEN123")) do
        results = run_against(origin,
          "GET /redir?q=§X§ HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n\r\n", "$TOKEN")
        results.size.should eq(1)
        # 1 original + max_redirects(3) hops.
        origin.requests.size.should eq(4)
        origin.requests.each { |r| r.should_not contain("SECRETTOKEN123") }
        origin.requests[3].should contain("/hop3?q=$TOKEN")
      end
      origin.close
    end
  end

  it "leaves a payload at offset 0 and one at the very end of the query verbatim on the hop" do
    with_hop_store do |store|
      origin = ReflectingOrigin.new(redirects: 1)
      origin.serve
      with_layer(bound(store, "TOKEN", "SECRETTOKEN123")) do
        # BatteringRam so both positions carry the same payload; the first span opens the
        # query, the second closes the request-target.
        tpl = F::Template.parse(
          "GET /redir?§A§=1&z=§B§ HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n\r\n")
        cfg = F::Config.new(mode: F::Mode::BatteringRam, concurrency: 1,
          follow_redirects: true, max_redirects: 3, timeout: 2.seconds)
        gen = F::Generator.new(tpl, [F::PayloadSet.new(F::InlineList.new(["$TOKEN"]))], cfg)
        backend = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), outbound_any,
          http2: false, verify: false)
        F::Engine.new(gen, F::Matcher.new, backend, cfg).run { }
        origin.requests.size.should eq(2)
        origin.requests[1].should contain("$TOKEN=1&z=$TOKEN")
        origin.requests.each { |r| r.should_not contain("SECRETTOKEN123") }
      end
      origin.close
    end
  end

  it "still follows the hop when the payload is ZERO-LENGTH (a zero-width span)" do
    with_hop_store do |store|
      origin = ReflectingOrigin.new(redirects: 1)
      origin.serve
      with_layer(bound(store, "TOKEN", "SECRETTOKEN123")) do
        # An empty payload renders a zero-width span, which `Env.clip_spans` drops entirely —
        # the edge where a spans-based exclusion degenerates to "no exclusions". The hop must
        # still be taken and the run must still finish; the template's own `$TOKEN` (outside
        # every span) must still resolve, exactly as it does with no exclusion in play.
        results = run_against(origin,
          "GET /redir?e=§d§&t=$TOKEN HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n\r\n", "")
        results.size.should eq(1)
        results[0].error.should be_nil
        origin.requests.size.should eq(2)
        origin.requests[0].should contain("/redir?e=&t=SECRETTOKEN123")
        origin.requests[1].should contain("/hop1?e=&t=SECRETTOKEN123")
      end
      origin.close
    end
  end

  it "keeps two payloads verbatim across a Content-Length resync, and on the hop after it" do
    with_hop_store do |store|
      origin = ReflectingOrigin.new(redirects: 1)
      origin.serve
      with_layer(bound(store, "TOKEN", "SECRETTOKEN123")) do
        tpl = F::Template.parse(
          "POST /redir?q=§A§ HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n" \
          "Content-Length: 1\r\n\r\nzz=§B§")
        cfg = F::Config.new(mode: F::Mode::BatteringRam, concurrency: 1, follow_redirects: true,
          max_redirects: 3, timeout: 2.seconds, update_content_length: true)
        gen = F::Generator.new(tpl, [F::PayloadSet.new(F::InlineList.new(["$TOKEN"]))], cfg)
        backend = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), outbound_any,
          http2: false, verify: false)
        F::Engine.new(gen, F::Matcher.new, backend, cfg).run { }
        origin.requests.size.should eq(2)
        origin.requests[0].should contain("Content-Length: 9") # resynced over `zz=$TOKEN`
        origin.requests[1].should contain("/hop1?q=$TOKEN")
        origin.requests.each { |r| r.should_not contain("SECRETTOKEN123") }
      end
      origin.close
    end
  end

  it "still resolves a template binding when NO redirect is followed (the control)" do
    with_hop_store do |store|
      origin = ReflectingOrigin.new(redirects: 0)
      origin.serve
      with_layer(bound(store, "TOKEN", "SECRETTOKEN123")) do
        run_against(origin,
          "GET /plain?q=§X§ HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nAuthorization: Bearer $TOKEN\r\n\r\n",
          "$TOKEN")
        origin.requests.size.should eq(1)
        origin.requests[0].should contain("q=$TOKEN")
        origin.requests[0].should contain("Bearer SECRETTOKEN123")
      end
      origin.close
    end
  end

  it "takes no hop at all with follow_redirects OFF (the other control)" do
    with_hop_store do |store|
      origin = ReflectingOrigin.new(redirects: 1)
      origin.serve
      with_layer(bound(store, "TOKEN", "SECRETTOKEN123")) do
        results = run_against(origin,
          "GET /redir?q=§X§ HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n\r\n", "$TOKEN", follow: false)
        results[0].status.should eq(302)
        origin.requests.size.should eq(1)
      end
      origin.close
    end
  end

  it "hands the hop a NON-NIL exclusion — the one thing the 1-argument overload could not" do
    # The mechanism, pinned directly: the first send gets the job's spans, the hop gets a
    # whole-message exclusion. A future edit that reverts either to `nil` fails here even if
    # no binding happens to be live in that run.
    _, backend = follow([reply(302, "/next"), reply(200)])
    backend.sent.size.should eq(2)
    backend.verbatim[0].should eq([{13, 16}]) # the §a§ payload's span in the rendered request
    backend.verbatim[1].should eq([{0, backend.sent[1].size}])
  end
end

describe "Fuzz::Engine#follow_redirects — the collapsed Result's fields" do
  it "carries `retried` from the ORIGINAL send through the redirect chain" do
    # The defect: `retried` was the 8th positional argument, and the 8th parameter is
    # `timed_out`. The row said nothing was re-sent and (silently) that it timed out.
    res, _ = follow([reply(302, "/next", retried: true), reply(200)])
    res.retried?.should be_true
  end

  it "carries `retried` when a LATER hop is the one that was re-sent" do
    res, _ = follow([reply(302, "/next"), reply(200, retried: true)])
    res.retried?.should be_true
  end

  it "reports retried == false when no hop was re-sent (the complement)" do
    res, _ = follow([reply(302, "/next"), reply(200)])
    res.retried?.should be_false
  end

  it "does not invent a timed_out from a retried send" do
    # `Fuzz::Result` now HAS a `timed_out` field (B1), so assert on the ROW a surface reads, not
    # only on the Repeater::Result underneath: a keep-alive re-send must reach the row as
    # `retried?` and must NOT show up there as `timed_out?`. (The defect was that `retried` once
    # sat in the constructor slot `timed_out` had taken, so a re-send silently set `timed_out`.)
    res, _ = follow([reply(302, "/next", retried: true), reply(200)])
    res.retried?.should be_true
    res.timed_out?.should be_false
  end

  # B3: a hop the gate refuses must NOT destroy the payload's real answer — the 302 an
  # open-redirect probe is hunting. The row keeps status 302; the hop failure rides as a NOTE.
  it "keeps the payload's 302 when the redirect hop is scope-refused, and notes the refusal" do
    refused = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64,
      Gori::Outbound::EXCLUDE_SWEEP_ERROR)
    res, backend = follow([reply(302, "/offsite"), refused])
    backend.sent.size.should eq(2)          # the hop WAS attempted
    res.status.should eq(302)               # …but the 302 survives the collapse
    res.error.should_not be_nil
    res.error.not_nil!.should contain("redirect hop refused")
  end

  # The complement: a hop that FAILS on the wire is treated the same — keep the 3xx, note it.
  it "keeps the 302 when a redirect hop errors on the wire" do
    dead = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
    res, _ = follow([reply(302, "/next"), dead])
    res.status.should eq(302)
    res.error.not_nil!.should contain("redirect hop refused")
    res.error.not_nil!.should contain("connection refused")
  end

  it "preserves a genuine timed_out on the last hop" do
    r = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, nil, false,
      delivered: true, timed_out: true, retried: false)
    r.timed_out?.should be_true
    r.delivered?.should be_true
    r.retried?.should be_false
  end

  it "leaves a single-hop (no redirect) Result untouched, retried included" do
    res, backend = follow([reply(200, retried: true)])
    backend.sent.size.should eq(1)
    res.retried?.should be_true
  end
end
