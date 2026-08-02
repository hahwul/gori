require "./spec_helper"
require "./support/memory_backend"
require "socket"
require "base64"
require "digest/sha1"

# The PROVENANCE axis at the four send seams round 4's first half did not reach.
#
# "The operator's draft" and "captured or operator-authored evidence" must not run through
# one policy. `Repeater::PlanOptions#evidence?` closed that for `$KEY` on ten call sites;
# these are the four downstream of them:
#
#   1. `Fuzz::Sender` — a PAYLOAD is the operator's test case, and a bound session binding
#      was substituting the live credential into it (reproduced on the wire).
#   2. `Repeater::Sender` — `plan.cr` deliberately defers a DECLARED binding to the send
#      seam, and that seam never asked whether the bytes were evidence.
#   3. `RepeaterView` — the tab a capture lands in FIRST had no evidence path at all.
#   4. WebSocket message frames — three copies of the same two lines, none of them
#      provenance-aware, on a population the WS relay had RECORDED.
#
# Plus the MCP WS transcript, which described the stored frame rather than the wire and
# printed the substituted value in the clear in the field beside the masked one.

include Gori::Tui

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

private def with_prov_store(&)
  path = File.tempname("gori-send-seam", ".db")
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

# A binding table with `name` DECLARED, and BOUND to `value` unless `value` is nil. The
# value is bound the only way it can be — by observing a response — so this is the same
# state a live session reaches, not a hand-poked hash.
private def bound_layer(store : Gori::Store, name : String, value : String?) : Gori::Bindings
  b = Gori::Bindings.load(store)
  b.add(name, "", Gori::ExtractKind::Cookie, "sid").should be_nil
  if value
    head = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=#{value}; Path=/\r\nContent-Length: 0\r\n\r\n"
    parsed = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
    b.observe(Gori::Repeater::Result.new(head.to_slice, Bytes.empty, parsed, 1_i64, nil),
      Gori::InterceptFilter::Subject.new(method: "GET", host: "acme.test", target: "/login",
        scheme: "https", status: 200))
    b.values[name]?.should eq(value)
  end
  b
end

# A recording origin: answers every request 200 and hands back the exact request bytes it
# read. The wire is the only thing that settles a provenance question.
private class RecordingOrigin
  getter port : Int32
  getter requests = [] of Bytes

  def initialize(@server : TCPServer = TCPServer.new("127.0.0.1", 0))
    @port = @server.local_address.port
  end

  def serve(count : Int32) : Nil
    spawn do
      count.times do
        break unless conn = @server.accept?
        conn.read_timeout = 5.seconds
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        break unless head
        @requests << head.dup
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        conn.flush
        conn.close
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

# A stored flow whose request head is exactly `head` — the seed a ^R tab loads.
private def seam_flow(store, target : String, head : String) : Gori::Store::FlowDetail
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil))
  store.get_flow(id).not_nil!
end

# No project scope at all → Layer 1 waived, Layer 2 (Sandbox) still applies. The scope
# gate is not what any of these examples is about.
private def outbound_any : Gori::Outbound
  Gori::Outbound.cli(nil, false)
end

# ─────────────────────────────────────────────────────────────────────────────────────
describe "Fuzz payload provenance (a payload is the test case, not a draft)" do
  it "renders the byte span of every spliced payload, in order" do
    tpl = Gori::Fuzz::Template.parse("GET /q?a=§X§&b=§Y§ HTTP/1.1\r\nHost: h\r\n\r\n")
    bytes, spans = tpl.render_spans(["aa", "bbbb"])
    spans.size.should eq(2)
    spans.each do |(a, b)|
      String.new(bytes[a, b - a]).should_not be_empty
    end
    String.new(bytes[spans[0][0], spans[0][1] - spans[0][0]]).should eq("aa")
    String.new(bytes[spans[1][0], spans[1][1] - spans[1][0]]).should eq("bbbb")
  end

  it "keeps the spans correct across the Content-Length resync that runs after the splice" do
    body = "q=§X§"
    tpl = Gori::Fuzz::Template.parse(
      "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\n\r\n#{body}")
    cfg = Gori::Fuzz::Config.new(mode: Gori::Fuzz::Mode::Sniper, update_content_length: true)
    gen = Gori::Fuzz::Generator.new(tpl, [Gori::Fuzz::PayloadSet.new(Gori::Fuzz::InlineList.new(["PAYLOADVALUE"]))], cfg)
    jobs = [] of Gori::Fuzz::Job
    gen.each { |j| jobs << j }
    jobs.size.should eq(1)
    job = jobs.first
    # The header really was rewritten (2 → 14), so the span MUST have moved with it.
    String.new(job.bytes).should contain("Content-Length: 14")
    a, b = job.payload_spans.first
    String.new(job.bytes[a, b - a]).should eq("PAYLOADVALUE")
  end

  it "sends the payload `$TOKEN` verbatim while the TEMPLATE's own $TOKEN resolves" do
    with_prov_store do |store|
      origin = RecordingOrigin.new
      origin.serve(1)
      with_layer(bound_layer(store, "TOKEN", "SECRETTOKEN123")) do
        tpl = Gori::Fuzz::Template.parse(
          "GET /q?p=§X§ HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer $TOKEN\r\n\r\n")
        cfg = Gori::Fuzz::Config.new(mode: Gori::Fuzz::Mode::Sniper)
        gen = Gori::Fuzz::Generator.new(tpl, [Gori::Fuzz::PayloadSet.new(Gori::Fuzz::InlineList.new(["$TOKEN"]))], cfg)
        job = nil.as(Gori::Fuzz::Job?)
        gen.each { |j| job = j }
        j = job.not_nil!

        sender = Gori::Fuzz::Sender.new(
          Gori::Fuzz::Origin.new("http", "127.0.0.1", origin.port), outbound_any, false, false)
        res = sender.send(j.bytes, j.payload_spans)
        res.error.should be_nil

        wire = String.new(origin.requests.first)
        wire.should contain("/q?p=$TOKEN")           # the PAYLOAD, byte-exact
        wire.should_not contain("p=SECRETTOKEN123")  # …not the live credential
        wire.should contain("Bearer SECRETTOKEN123") # the TEMPLATE still resolves
      end
      origin.close
    end
  end

  it "does not refuse the run when the payload names an UNBOUND declared binding" do
    with_prov_store do |store|
      with_layer(bound_layer(store, "TOKEN", nil)) do
        tpl = Gori::Fuzz::Template.parse("GET /q?p=§X§ HTTP/1.1\r\nHost: h\r\n\r\n")
        cfg = Gori::Fuzz::Config.new(mode: Gori::Fuzz::Mode::Sniper)
        gen = Gori::Fuzz::Generator.new(tpl, [Gori::Fuzz::PayloadSet.new(Gori::Fuzz::InlineList.new(["$TOKEN"]))], cfg)
        job = nil.as(Gori::Fuzz::Job?)
        gen.each { |j| job = j }
        j = job.not_nil!
        # Unbound is where the old behaviour was worst: it refused, and its remedy
        # ("replay the flow that mints the token first") produced the substitution. The
        # refusal is gone entirely now (see `Env.unbound`), but the SPAN exclusion is not —
        # `Env.unbound` is still the report `Rules` uses, and it must still skip a payload.
        Gori::Env.unbound(j.bytes, j.payload_spans).should be_empty
        # …and the COMPLEMENT: the same name in the TEMPLATE is still REPORTED (the spans are
        # what makes the difference), it simply no longer stops anything.
        Gori::Env.unbound(
          "GET /q?p=x HTTP/1.1\r\nAuthorization: Bearer $TOKEN\r\n\r\n".to_slice,
          j.payload_spans).should eq(["TOKEN"])
      end
    end
  end

  it "still expands a binding OUTSIDE the payload spans, and leaves an undeclared name alone" do
    with_prov_store do |store|
      with_layer(bound_layer(store, "TOKEN", "SECRETTOKEN123")) do
        tpl = Gori::Fuzz::Template.parse("GET /q?p=§X§&t=$TOKEN&u=$NOSUCH HTTP/1.1\r\nHost: h\r\n\r\n")
        cfg = Gori::Fuzz::Config.new(mode: Gori::Fuzz::Mode::Sniper)
        gen = Gori::Fuzz::Generator.new(tpl, [Gori::Fuzz::PayloadSet.new(Gori::Fuzz::InlineList.new(["$TOKEN"]))], cfg)
        job = nil.as(Gori::Fuzz::Job?)
        gen.each { |j| job = j }
        j = job.not_nil!
        out = String.new(Gori::Env.expand_bindings(j.bytes, j.payload_spans))
        out.should contain("p=$TOKEN")         # payload: verbatim
        out.should contain("t=SECRETTOKEN123") # template: resolved
        out.should contain("u=$NOSUCH")        # undeclared: literal, as always
      end
    end
  end

  it "leaves a payload that merely CONTAINS a binding name alone too, whatever follows it" do
    with_prov_store do |store|
      with_layer(bound_layer(store, "TOKEN", "SECRETTOKEN123")) do
        tpl = Gori::Fuzz::Template.parse("GET /q?p=§X§ HTTP/1.1\r\nHost: h\r\n\r\n")
        cfg = Gori::Fuzz::Config.new(mode: Gori::Fuzz::Mode::Sniper)
        # `foo$TOKENbar` never substituted (the key scanner reads `TOKENbar`); `x$TOKEN.y`
        # DID, because the byte after the name happens to end it. Both are now the payload.
        gen = Gori::Fuzz::Generator.new(tpl,
          [Gori::Fuzz::PayloadSet.new(Gori::Fuzz::InlineList.new(["foo$TOKENbar", "x$TOKEN.y", "$TOKEN$TOKEN"]))], cfg)
        seen = [] of String
        gen.each { |j| seen << String.new(Gori::Env.expand_bindings(j.bytes, j.payload_spans)) }
        seen.size.should eq(3)
        seen[0].should contain("p=foo$TOKENbar")
        seen[1].should contain("p=x$TOKEN.y")
        seen[2].should contain("p=$TOKEN$TOKEN")
        seen.none?(&.includes?("SECRETTOKEN123")).should be_true
      end
    end
  end

  it "an EMPTY payload keeps a span and excludes nothing" do
    with_prov_store do |store|
      with_layer(bound_layer(store, "TOKEN", "SECRETTOKEN123")) do
        tpl = Gori::Fuzz::Template.parse("GET /q?p=§X§$TOKEN HTTP/1.1\r\nHost: h\r\n\r\n")
        cfg = Gori::Fuzz::Config.new(mode: Gori::Fuzz::Mode::Sniper)
        gen = Gori::Fuzz::Generator.new(tpl, [Gori::Fuzz::PayloadSet.new(Gori::Fuzz::InlineList.new([""]))], cfg)
        job = nil.as(Gori::Fuzz::Job?)
        gen.each { |j| job = j }
        j = job.not_nil!
        j.payload_spans.size.should eq(1)
        j.payload_spans.first[0].should eq(j.payload_spans.first[1]) # zero width
        # The `$TOKEN` right after the empty payload is template, so it still resolves.
        String.new(Gori::Env.expand_bindings(j.bytes, j.payload_spans))
          .should contain("p=SECRETTOKEN123")
      end
    end
  end

  it "a Job with no spans behaves exactly as before (the miner/probe/spec-double path)" do
    with_prov_store do |store|
      with_layer(bound_layer(store, "TOKEN", "SECRETTOKEN123")) do
        raw = "GET /q?p=$TOKEN HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
        String.new(Gori::Env.expand_bindings(raw)).should contain("p=SECRETTOKEN123")
        String.new(Gori::Env.expand_bindings(raw, [] of {Int32, Int32}))
          .should contain("p=SECRETTOKEN123")
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────────────
describe "Repeater::Sender provenance (a DECLARED binding at the send seam)" do
  it "leaves a captured request's $NAME alone when the plan says the bytes are evidence" do
    with_prov_store do |store|
      origin = RecordingOrigin.new
      origin.serve(2)
      with_layer(bound_layer(store, "TOKEN", "SECRETTOKEN123")) do
        captured = "GET /api?$TOKEN=1&sort=asc HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

        plan = Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new([captured.to_slice],
          evidence: true, target: "http://127.0.0.1:#{origin.port}"), outbound_any)
        plan.send.error.should be_nil
        String.new(origin.requests[0]).should contain("/api?$TOKEN=1&sort=asc")

        # THE COMPLEMENT — a DRAFT over the identical bytes, same binding, same everything:
        # the send seam still resolves it. Provenance is the only thing that differs.
        draft = Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new([captured.to_slice],
          evidence: false, expand_request: false,
          target: "http://127.0.0.1:#{origin.port}"), outbound_any)
        draft.send.error.should be_nil
        String.new(origin.requests[1]).should contain("/api?SECRETTOKEN123=1")
      end
      origin.close
    end
  end

  # The seam is `Sender`, but the SIGNAL has to arrive at every flow-replay caller, and
  # this example exists because the first cut of the fix missed one. `gori run repeater
  # <flow-id>` already passed `evidence: true`; MCP `send_request{flow_id}` reached "the
  # same end state" through `expand_request: false`, which
  # stop at the BUILDER. So the live repro still put `GET /api?SECRETTOKEN123=1` on the
  # wire from MCP after `Sender` was fixed — two surfaces, one flow id, different requests,
  # which is the exact shape round 3 was burned by. Driven through the real tool, not
  # through `PlanOptions`, because `PlanOptions` is the thing that was wrong.
  it "reaches MCP send_request{flow_id}, not just a hand-built PlanOptions" do
    with_prov_store do |store|
      origin = RecordingOrigin.new
      origin.serve(1)
      with_layer(bound_layer(store, "TOKEN", "SECRETTOKEN123")) do
        head = "GET /api?$TOKEN=1&sort=asc HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        fid = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: origin.port,
          method: "GET", target: "/api?$TOKEN=1&sort=asc", http_version: "HTTP/1.1",
          head: head.to_slice, body: nil))
        store.flush
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        r = tools.call("send_request", JSON.parse(%({"flow_id":#{fid},"allow_unscoped":true})))
        r.is_error.should be_false
        wire = String.new(origin.requests.first)
        wire.should contain("/api?$TOKEN=1&sort=asc")
        wire.should_not contain("SECRETTOKEN123")
        # …and the transcript describes that wire, which it also did not before: it
        # reported the stored target while 14 different bytes went out.
        JSON.parse(r.text)["effective_request"]["target"].as_s
          .should eq("/api?$TOKEN=1&sort=asc")
      end
      origin.close
    end
  end

  # POLICY (owner, round 7): `$NAME` with a value follows the value; without one it is a
  # literal string on the wire. Never a refusal — including for a name an extract rule has
  # DECLARED but nothing has bound. This spec used to assert the opposite for the DRAFT half;
  # it is inverted deliberately, not because the old assertion was buggy.
  it "refuses neither an evidence NOR a draft send over a declared-but-UNBOUND name" do
    with_prov_store do |store|
      with_layer(bound_layer(store, "TOKEN", nil)) do
        captured = "GET /api?$TOKEN=1 HTTP/1.1\r\nHost: h\r\n\r\n"
        opts = Gori::Repeater::PlanOptions.new([captured.to_slice], evidence: true,
          target: "http://127.0.0.1:1")
        Gori::Repeater::Plan.build(opts, outbound_any).refusal.should be_nil

        # Complement, and the inverted half: a DRAFT carrying the same unbound name used to
        # come back as a named refusal. It now proceeds, and the token ships literally.
        draft = Gori::Repeater::PlanOptions.new([captured.to_slice], expand_request: false,
          target: "http://127.0.0.1:1")
        plan = Gori::Repeater::Plan.build(draft, outbound_any)
        plan.refusal.should be_nil
        String.new(Gori::Env.expand_bindings(plan.bytes)).should contain("/api?$TOKEN=1")
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────────────
describe "TUI Repeater provenance" do
  it "sends a captured $filter/$top byte-exact even with those names set as project vars" do
    with_prov_store do |store|
      Gori::Settings.project_env_vars = [{"filter", "PWNED"}, {"top", "99"}]
      detail = seam_flow(store, "/api?$filter=name&$top=10",
        "GET /api?$filter=name&$top=10 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      view = RepeaterView.new
      view.load(detail)
      view.evidence?.should be_true
      String.new(view.request_bytes).should contain("/api?$filter=name&$top=10")

      # An operator EDIT does not clear evidence (the call `FuzzerView#evidence_template`
      # made): seed a capture, tweak a header, send is the commonest workflow there is.
      view.replace_request(view.request_text + "X-Probe: 1\r\n")
      view.evidence?.should be_true
      String.new(view.request_bytes).should contain("/api?$filter=name&$top=10")
    end
  end

  it "still promotes a bare-LF head terminator on an evidence tab" do
    with_prov_store do |store|
      detail = seam_flow(store, "/api?$filter=1",
        "GET /api?$filter=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      view = RepeaterView.new
      view.load(detail)
      # The editor hands typed lines back with bare LFs; a head must not carry one.
      view.replace_request("GET /api?$filter=1 HTTP/1.1\nHost: 127.0.0.1\nX-Typed: 1\n\n")
      wire = String.new(view.request_bytes)
      wire.should contain("X-Typed: 1\r\n")
      wire.should_not match(/[^\r]\n/)
      wire.should contain("$filter=1") # …and STILL no substitution
    end
  end

  it "keeps expanding a HAND-AUTHORED draft over the same var names" do
    with_prov_store do |_store|
      Gori::Settings.project_env_vars = [{"filter", "PWNED"}]
      view = RepeaterView.new
      view.load_blank
      view.evidence?.should be_false
      view.replace_request("GET /api?$filter=name HTTP/1.1\nHost: h\n\n")
      String.new(view.request_bytes).should contain("/api?PWNED=name")
    end
  end

  it "carries provenance across a restore, so a reopened capture is not a draft" do
    with_prov_store do |_store|
      Gori::Settings.project_env_vars = [{"filter", "PWNED"}]
      view = RepeaterView.new
      view.restore("http://h", "GET /api?$filter=n HTTP/1.1\r\nHost: h\r\n\r\n", false, false,
        evidence: true)
      view.evidence?.should be_true
      String.new(view.request_bytes).should contain("$filter=n")

      # Complement: the same row without a flow_id restores as a draft.
      plain = RepeaterView.new
      plain.restore("http://h", "GET /api?$filter=n HTTP/1.1\r\nHost: h\r\n\r\n", false, false)
      plain.evidence?.should be_false
      String.new(plain.request_bytes).should contain("PWNED=n")
    end
  end

  it "does not expand or refuse a captured WebSocket frame in the message pane" do
    with_prov_store do |store|
      Gori::Settings.project_env_vars = [{"where", "WHEREVAL"}]
      detail = seam_flow(store, "/chat",
        "GET /chat HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
      view = RepeaterView.new
      view.load_ws(detail, [Gori::Store::WsOutMessage.text(%({"$where":"this.a==1"}))])
      String.new(view.ws_out_messages.first.payload).should eq(%({"$where":"this.a==1"}))
      view.ws_out_messages.first.evidence.should be_true
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────────────
describe "WebSocket message provenance across the three surfaces" do
  # `ws_out_messages` is private CLI glue; reopen for a bare-call wrapper. Distinctly
  # named — every spec file compiles into the same module in a full run.
  it "gori run repeater send replays a FLOW-SEEDED session's frames byte-exact" do
    with_prov_store do |store|
      Gori::Settings.project_env_vars = [{"where", "WHEREVAL"}, {"WHO", "alice"}]
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h", port: 80, method: "GET", target: "/ws",
        http_version: "HTTP/1.1", head: WS_SEAM_UPGRADE.to_slice, body: nil))
      seeded = store.insert_repeater("ws://h", WS_SEAM_UPGRADE.to_slice, false, true, fid, 0)
      store.insert_ws_message(0_i64, "out", 1, %({"$where":"this.a==1"}).to_slice, repeater_id: seeded)
      store.flush

      msgs = Gori::CLI::Run.ws_out_messages_prov_spec(store, seeded, evidence: true)
      String.new(msgs.first.payload).should eq(%({"$where":"this.a==1"}))
      msgs.first.evidence.should be_true

      # COMPLEMENT 1 — a session with NO flow_id is a draft, and its stored rows still
      # expand. `spec/env_send_paths_spec.cr` pins that half and it stays true.
      hand = store.insert_repeater("ws://h", WS_SEAM_UPGRADE.to_slice, false, true, nil, 0)
      store.insert_ws_message(0_i64, "out", 1, "hi $WHO".to_slice, repeater_id: hand)
      store.flush
      drafts = Gori::CLI::Run.ws_out_messages_prov_spec(store, hand, evidence: false)
      String.new(drafts.first.payload).should eq("hi alice")
      drafts.first.evidence.should be_false
    end
  end

  it "treats a --message override on a SEEDED session as the operator's draft" do
    with_prov_store do |store|
      Gori::Settings.project_env_vars = [{"WHO", "alice"}]
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h", port: 80, method: "GET", target: "/ws",
        http_version: "HTTP/1.1", head: WS_SEAM_UPGRADE.to_slice, body: nil))
      id = store.insert_repeater("ws://h", WS_SEAM_UPGRADE.to_slice, false, true, fid, 0)
      store.insert_ws_message(0_i64, "out", 1, %({"$where":"x"}).to_slice, repeater_id: id)
      store.flush
      # The bytes the operator typed HERE AND NOW are a draft even on an evidence session.
      frames = Gori::CLI::Run.ws_out_messages_prov_spec(store, id, evidence: true,
        override: [Gori::Store::WsOutMessage.text("hi $WHO")])
      frames.size.should eq(1)
      String.new(frames.first.payload).should eq("hi alice")
      frames.first.evidence.should be_false
    end
  end

  it "never seeds or sends a [gori] advisory row as a client frame, whatever its opcode" do
    notice = "#{Gori::Proxy::WS::NOTICE_PREFIX}more than 8 control frames arrived"
    Gori::CLI::Run.ws_notice_row?(1, notice.to_slice).should be_true
    # NOT keyed on the opcode. Two pre-existing markers stand in for a real frame at its
    # position and keep that frame's own opcode — the ping-flood marker is a PING (9) and
    # is under §5.5's 125-byte cap, so an opcode-1 test would have let it replay as a real
    # control frame. Every marker is built from one prefix, so the prefix is the whole test.
    Gori::CLI::Run.ws_notice_row?(9, notice.to_slice).should be_true
    Gori::CLI::Run.ws_notice_row?(2, notice.to_slice).should be_true
    # Complements: a frame that MENTIONS the marker without leading with it is the
    # operator's, and a truncated prefix is not a marker.
    Gori::CLI::Run.ws_notice_row?(1, "the [gori] proxy said".to_slice).should be_false
    Gori::CLI::Run.ws_notice_row?(1, "[gori".to_slice).should be_false
    Gori::CLI::Run.ws_notice_row?(1, Bytes.empty).should be_false

    with_prov_store do |store|
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h", port: 80, method: "GET", target: "/ws",
        http_version: "HTTP/1.1", head: WS_SEAM_UPGRADE.to_slice, body: nil))
      id = store.insert_repeater("ws://h", WS_SEAM_UPGRADE.to_slice, false, true, fid, 0)
      store.insert_ws_message(0_i64, "out", 1, "AAA".to_slice, repeater_id: id)
      store.insert_ws_message(0_i64, "out", 1, notice.to_slice, repeater_id: id)
      store.insert_ws_message(0_i64, "out", 9, notice.to_slice, repeater_id: id)
      store.insert_ws_message(0_i64, "in", 1, "server".to_slice, repeater_id: id)
      store.flush

      rows, dropped = Gori::CLI::Run.ws_seed_rows(store.ws_messages_for_repeater(id))
      rows.size.should eq(1)
      String.new(rows.first.payload).should eq("AAA")
      # The drop is REPORTED, not silent: a seed quietly shorter than the capture is the
      # same class of problem as one carrying an extra frame.
      dropped.should eq(2)
      Gori::CLI::Run.ws_notice_dropped_note(dropped).should contain("2 gori advisory rows")

      frames = Gori::CLI::Run.ws_out_messages_prov_spec(store, id, evidence: true)
      frames.size.should eq(1)
      String.new(frames.first.payload).should eq("AAA")
    end
  end

  it "MCP send_websocket replays a flow-seeded frame byte-exact and reports the WIRE" do
    with_prov_store do |store|
      # `Tools#call` reloads the project's env FROM THE STORE on every call, so the var
      # has to be persisted or the example would pass vacuously (nothing to substitute).
      Gori::Env.save_project(store, [{"where", "WHEREVAL"}])
      port = start_seam_ws_origin
      upgrade = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port, method: "GET",
        target: "/ws", http_version: "HTTP/1.1", head: upgrade.to_slice, body: nil))
      id = store.insert_repeater("ws://127.0.0.1:#{port}", upgrade.to_slice, false, true, fid, 0)
      store.insert_ws_message(0_i64, "out", 1, %({"$where":"this.a==1"}).to_slice, repeater_id: id)
      store.flush

      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      r = tools.call("send_websocket",
        JSON.parse(%({"repeater_id":#{id},"idle_ms":300,"allow_unscoped":true})))
      r.is_error.should be_false
      sent = JSON.parse(r.text)["messages"].as_a.find! { |m| m["direction"] == "out" }
      # The origin echoes what it received, so the "in" row IS the wire.
      echoed = JSON.parse(r.text)["messages"].as_a.find { |m| m["direction"] == "in" }
      sent["payload"].as_s.should eq(%({"$where":"this.a==1"}))
      sent["payload_expanded"]?.should be_nil
      echoed.try(&.["payload"].as_s).should eq(%({"$where":"this.a==1"}))
    end
  end

  it "MCP send_websocket accepts `verbatim` for a `messages` payload that IS a $NAME" do
    with_prov_store do |store|
      # `Tools#call` reloads the project's env FROM THE STORE on every call, so the var
      # has to be persisted or the example would pass vacuously (nothing to substitute).
      Gori::Env.save_project(store, [{"where", "WHEREVAL"}])
      port = start_seam_ws_origin
      upgrade = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      id = store.insert_repeater("ws://127.0.0.1:#{port}", upgrade.to_slice, false, true, nil, 0)
      store.flush
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      r = tools.call("send_websocket", JSON.parse(
        %({"repeater_id":#{id},"idle_ms":300,"allow_unscoped":true,"verbatim":true,"messages":["{\\"$where\\":1}"]})))
      r.is_error.should be_false
      echoed = JSON.parse(r.text)["messages"].as_a.find! { |m| m["direction"] == "in" }
      echoed["payload"].as_s.should eq(%({"$where":1}))
    end
  end

  it "says so when it DID rewrite a draft payload, and never prints the value in the clear" do
    with_prov_store do |store|
      # `Tools#call` reloads the project's env FROM THE STORE on every call, so the var
      # has to be persisted or the example would pass vacuously (nothing to substitute).
      Gori::Env.save_project(store, [{"where", "WHEREVAL"}])
      port = start_seam_ws_origin
      upgrade = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      id = store.insert_repeater("ws://127.0.0.1:#{port}", upgrade.to_slice, false, true, nil, 0)
      store.flush
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      # An invalid-UTF-8 TEXT payload is the one shape that reaches `payload_base64`, which
      # is where the raw substituted value used to be printed unmasked beside the masked
      # `payload`. Base64 of `bad\xff\xfe$where` — the frame the h3 report caught.
      raw = Base64.strict_encode(Bytes[0x62, 0x61, 0x64, 0xFF, 0xFE] + "$where".to_slice)
      r = tools.call("send_websocket", JSON.parse(
        %({"repeater_id":#{id},"idle_ms":300,"allow_unscoped":true,) +
        %("messages":[{"opcode":"text","payload_base64":"#{raw}"}]})))
      (r.is_error ? r.text : "").should eq("")
      sent = JSON.parse(r.text)["messages"].as_a.find! { |m| m["direction"] == "out" }
      sent["payload_expanded"]?.try(&.as_bool).should be_true
      sent["payload_authored"].as_s.should contain("$where")
      b64 = sent["payload_base64"]?.try(&.as_s)
      b64.should_not be_nil
      String.new(Base64.decode(b64.not_nil!)).should_not contain("WHEREVAL")
      String.new(Base64.decode(b64.not_nil!)).should contain("$where")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Cross-package: the two verdicts that had to be drawn on H2CORE's new facts. Both are
# pinned as DATA — the sentences they read are written in another module, and a reword
# there must fail an example rather than silently flip a verdict an agent acts on.
describe "why a response is incomplete, and whether a stall is retryable" do
  it "names the read deadline instead of blaming an origin that never closed" do
    short = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".to_slice, "ab".to_slice, nil, 1_i64,
      nil, true)
    # The three causes, and the three different next moves.
    Gori::CLI::Run.incomplete_reason(short, timed_out: true)
      .should contain("did not close the connection")
    Gori::CLI::Run.incomplete_reason(short, timed_out: true)
      .should_not contain("origin closed")
    Gori::CLI::Run.incomplete_reason(short, timed_out: false)
      .should contain("origin closed before the framed body finished")

    ceiling = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice,
      Bytes.new(Gori::Proxy::Codec::Body::CAPTURE_READ_MAX), nil, 1_i64, nil, true)
    # The ceiling wins over the deadline: gori stopping the read is gori's own doing, and
    # saying "raise the timeout" for it would send the operator after a fix that cannot work.
    Gori::CLI::Run.incomplete_reason(ceiling, timed_out: true)
      .should contain("capture ceiling")
  end

  it "treats an h2 EXCHANGE-BUDGET stall as a deadline, and its siblings as protocol" do
    budget = "h2 flow control: only 1 of 20000 request body bytes could be sent — the origin " \
             "granted flow-control window in increments too small to finish it, and the 2s " \
             "budget for the whole exchange expired first (RFC 9113 §6.9): its connection " \
             "window is 65536 and its stream window 0. The request was NOT fully sent."
    Gori::MCP::Tools.network_error_kind(budget).should eq("timeout")
    Gori::MCP::Tools.send_error_code("timeout").should eq("NETWORK_ERROR")

    # THE COMPLEMENT, and the whole reason this is keyed on a phrase rather than on
    # "NOT fully sent": the sibling stalls end with that same clause and must stay a
    # non-retryable protocol verdict — retrying reproduces them, and the refusal is the
    # finding. These two sentences are `H2Engine.flow_stalled`'s, verbatim.
    never = "h2 flow control: only 1 of 20000 request body bytes could be sent — the origin " \
            "never granted flow-control window for the rest (RFC 9113 §6.9): its connection " \
            "window is 65536 and its stream window 0. The request was NOT fully sent."
    closed = "h2 flow control: only 1 of 20000 request body bytes could be sent — the origin " \
             "closed the connection before granting window for the rest (RFC 9113 §6.9). " \
             "The request was NOT fully sent."
    Gori::MCP::Tools.network_error_kind(never).should eq("protocol")
    Gori::MCP::Tools.network_error_kind(closed).should eq("protocol")
    Gori::MCP::Tools.send_error_code("protocol").should eq("PROTOCOL_ERROR")

    # And the phrase itself is in the sentence gori would render — so a reword on either
    # side breaks here rather than in an agent's retry loop.
    budget.downcase.should contain(Gori::MCP::Tools::EXCHANGE_BUDGET_PHRASE)
    never.downcase.should_not contain(Gori::MCP::Tools::EXCHANGE_BUDGET_PHRASE)
  end
end

private WS_SEAM_UPGRADE = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"

# Upgrade, echo every client frame back, then close.
private def start_seam_ws_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try { |line| line.split(':', 2)[1].strip } || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + Gori::Repeater::WsEngine::GUID))
    conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    conn.flush
    while (frame = Gori::Proxy::WS.read_frame(conn)) && frame.data?
      conn.write(Gori::Proxy::WS.encode(frame.opcode, frame.payload, mask: false))
      conn.flush
    end
    conn.write(Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
    conn.flush
    conn.close
    origin.close
  rescue
    origin.close rescue nil
  end
  port
end

module Gori::CLI::Run
  # Bare-call wrapper for the private CLI glue. Distinctly named from the wrappers in
  # `cli_run_spec.cr` / `env_send_paths_spec.cr` — all three compile into this one module
  # in a full run, and two identical `def`s would silently redefine each other.
  def self.ws_out_messages_prov_spec(store : Gori::Store, id : Int64, *, evidence : Bool,
                                     override : Array(Gori::Store::WsOutMessage) = [] of Gori::Store::WsOutMessage,
                                     verbatim : Bool = false) : Array(Gori::Repeater::WsEngine::OutMsg)
    ws_out_messages(store, id, override, verbatim, evidence)
  end
end
