require "../spec_helper"

# PROVENANCE, on the two HEADLESS roads into a capture: `gori run fuzz --flow N` and MCP
# `fuzz_start{flow_id}`. Both seed a `Fuzz::PlanOptions` template straight from the captured
# bytes, and both used to do it with `String.new(built.bytes).scrub` — which is two defects in
# one line, the pair `FuzzerView#load` carried on the TUI's ⇧I road until ec1be05b:
#
#   * a CAPTURED `§` became a live injection POSITION. `§` is U+00A7, ordinary text a German
#     or legal body carries constantly, but `§…§` is this template's position syntax — so a
#     captured `"mk":"§SEED§"` was swept with every payload in the set, with no `--auto` and
#     no `--mark` ever passed. Measured at 6d204ffe against a recording origin, `gori run fuzz
#     --flow 1 --payloads PWNED` put `"mk":"PWNED"` on the wire.
#   * `.scrub` REWROTE the capture. A body that is legitimately not valid UTF-8 (a protobuf /
#     gRPC frame, a gzip'd POST, a latin-1 field) had every such byte replaced by the three
#     bytes of U+FFFD before the sweep ever ran, with Content-Length resynced to the
#     corruption. Same run, same flow: `"bin":"<ff fe 01 02>"` reached the origin as
#     `"bin":"<ef bf bd ef bf bd 01 02>"`, 70 → 71 bytes under a recomputed CL.
#
# Both are fixed at the seed with `Fuzz::Template.escape_literal_markers` — the byte-level
# escape to the `§§` form `Template.parse` already folds back to one literal `§` — and by not
# scrubbing. `render` puts the single `§` back on the wire, so the capture still replays
# byte-exact; it simply is not a position any more.
#
# The fixtures below carry RAW invalid UTF-8 (`ff fe 01 02`) and are searched BYTE-wise:
# a String-level `includes?` would walk chars and hand back the very substitution under test.

# A capture whose body legitimately holds a `§…§` pair AND invalid UTF-8, beside the other
# byte classes a template has to carry unchanged: a CRLF inside the body, a captured `$TOKEN`,
# a raw tab.
BINARY_RUN = Bytes[0xFF, 0xFE, 0x01, 0x02]

private def seed_body : Bytes
  io = IO::Memory.new
  io << %({"note":"a\r\nb","mk":"§SEED§","env":"$TOKEN","bin":")
  io.write(BINARY_RUN)
  io << %(","tab":"\tx"})
  io.to_slice
end

private def plain_body : Bytes
  io = IO::Memory.new
  io << %({"note":"a\r\nb","env":"$TOKEN","bin":")
  io.write(BINARY_RUN)
  io << %(","tab":"\tx"})
  io.to_slice
end

private def seed_head(body : Bytes) : String
  "POST /seed?q=1&r=2 HTTP/1.1\r\nHost: h.test\r\n" \
  "Content-Type: application/json\r\nContent-Length: #{body.size}\r\n" \
  "Connection: close\r\n\r\n"
end

# Byte-wise `includes?`. The fixture is deliberately not valid UTF-8, so nothing here may
# look for it through a String.
private def holds_bytes?(text : String, needle : Bytes) : Bool
  b = text.to_slice
  return false if b.size < needle.size
  (0..(b.size - needle.size)).any? { |i| b[i, needle.size] == needle }
end

private def with_seed_store(body : Bytes, head : String? = nil, &)
  path = File.tempname("gori-fuzzseed", ".db")
  store = Gori::Store.open(path)
  prev_layer = Gori::Env.layer
  begin
    h = head || seed_head(body)
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
      method: "POST", target: "/seed?q=1&r=2", http_version: "HTTP/1.1",
      head: h.to_slice, body: body, source: Gori::FlowSource::Kind::Proxy))
    store.close
    yield({path, id, (h.to_slice.to_a + body.to_a)})
  ensure
    Gori::Env.layer = prev_layer
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# A store carrying one repeater session (#749's `--repeater` / `repeater_id` seed), yielded as
# {db path, repeater id}. `request` is the stored wire request; a WS handshake makes it a
# WebSocket session, which the fuzz seed now SWEEPS (handshake + stored frames) rather than
# refusing — see the WebSocket cases below.
private def with_repeater_store(target : String, request : String, sni : String? = nil, &)
  path = File.tempname("gori-repseed", ".db")
  store = Gori::Store.open(path)
  prev_layer = Gori::Env.layer
  begin
    id = store.insert_repeater(target, request.to_slice, false, true, nil, 0, sni: sni)
    store.close
    yield({path, id})
  ensure
    Gori::Env.layer = prev_layer
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# The CLI's seed lives behind `private def self.` (nothing outside `gori run` may phrase it),
# so it is reached through a shim in the same module — the `env_unresolved_error_for_spec` /
# `emit_fuzz_result_for_spec` pattern the other `gori run` specs already use.
module Gori::CLI::Run
  def self.fuzz_source_for_spec(flow_id : Int64?, request_file : String?, db_path : String?)
    fuzz_source(flow_id, nil, request_file, nil, db_path)
  end

  def self.fuzz_source_repeater_for_spec(repeater_id : Int64?, db_path : String?)
    fuzz_source(nil, repeater_id, nil, nil, db_path)
  end

  def self.fuzz_plan_error_for_spec(reason : Gori::Fuzz::PlanError::Reason, template : String?) : String
    fuzz_plan_error(Gori::Fuzz::PlanError.new(reason, ""), template)
  end
end

# Same for MCP's, which are private INSTANCE methods on the tools object.
class Gori::MCP::Tools
  def fuzz_template_source_for_spec(args : String)
    fuzz_template_source(JSON.parse(args))
  end

  def fuzz_plan_error_for_spec(reason : Gori::Fuzz::PlanError::Reason, template : String?) : String
    fuzz_plan_error(Gori::Fuzz::PlanError.new(reason, ""), template)
  end
end

describe "a captured fuzz seed is evidence, not a template the site wrote" do
  # One expectation set, run against whichever surface produced the seed — the defect and the
  # fix are identical on both roads, and pinning them separately is how they drift apart.
  seed_assertions = ->(text : String, wire : Array(UInt8)) do
    tmpl = Gori::Fuzz::Template.parse(text)
    # WAS 1: the capture's own `§SEED§` was a live position, swept with every payload.
    tmpl.position_count.should eq(0)
    text.should contain(%("mk":"§§SEED§§"))
    # WAS `ef bf bd ef bf bd 01 02` — `.scrub` grew four captured bytes into eight.
    holds_bytes?(text, BINARY_RUN).should be_true
    # Exactly the two doubled § (2 bytes each) separate the buffer from the wire; nothing
    # else was re-encoded.
    text.to_slice.size.should eq(wire.size + 4)
    # …and the template still renders back to the captured request BYTE FOR BYTE, so the
    # single `§` is what the origin sees.
    tmpl.render(tmpl.default_payloads).to_a.should eq(wire)
  end

  describe "gori run fuzz --flow" do
    it "escapes the capture's § and does not scrub it" do
      with_seed_store(seed_body) do |(path, id, wire)|
        seed = Gori::CLI::Run.fuzz_source_for_spec(id, nil, path)
        text, target, http2, evidence = seed.text, seed.target, seed.http2, seed.evidence
        seed_assertions.call(text, wire)
        evidence.should be_true # unchanged: a --flow template is a CAPTURE
        target.should eq("http://h.test")
        http2.should be_false
      end
    end

    # COMPLEMENT: the overwhelmingly common capture — no `§` anywhere — must seed exactly as
    # it did before, invalid UTF-8 and all. This is the example that would catch an escape
    # that fired on the wrong bytes, and the `.scrub` removal on its own.
    it "seeds a capture with no § byte-identically, invalid UTF-8 included" do
      with_seed_store(plain_body) do |(path, id, wire)|
        text = Gori::CLI::Run.fuzz_source_for_spec(id, nil, path).text
        text.to_slice.to_a.should eq(wire) # WAS: ff fe → ef bf bd ef bf bd
      end
    end

    # COMPLEMENT: a valid-UTF-8 multibyte body (Korean, emoji) is untouched either way.
    it "leaves a valid multibyte capture alone" do
      body = %({"이름":"관리자","e":"🐿️"}).to_slice
      with_seed_store(body) do |(path, id, wire)|
        text = Gori::CLI::Run.fuzz_source_for_spec(id, nil, path).text
        text.to_slice.to_a.should eq(wire)
      end
    end

    # COMPLEMENT: a `--request` FILE is a DRAFT the operator authored, not evidence — their
    # own `§…§` must still mark and fuzz. Only the `--flow` branch escapes.
    it "keeps an operator's own §…§ live in a --request template" do
      file = File.tempname("gori-fuzzreq", ".txt")
      begin
        File.write(file, "GET /?x=§1§ HTTP/1.1\r\nHost: h.test\r\n\r\n")
        seed = Gori::CLI::Run.fuzz_source_for_spec(nil, file, nil)
        text, evidence = seed.text, seed.evidence
        Gori::Fuzz::Template.parse(text).position_count.should eq(1)
        evidence.should be_false
      ensure
        File.delete?(file)
      end
    end
  end

  describe "gori run fuzz --repeater (#749)" do
    it "seeds from an HTTP repeater session: markers escaped, evidence FALSE, target/http2 from the session" do
      with_repeater_store("http://r.test", "GET /r?q=§SEED§ HTTP/1.1\r\nHost: r.test\r\n\r\n") do |(path, id)|
        seed = Gori::CLI::Run.fuzz_source_repeater_for_spec(id, path)
        text, target, http2, evidence = seed.text, seed.target, seed.http2, seed.evidence
        Gori::Fuzz::Template.parse(text).position_count.should eq(0) # the session's § is literal, escaped
        text.should contain("§§SEED§§")
        evidence.should be_false # a repeater session is an authored draft — $NAME expands
        target.should eq("http://r.test")
        http2.should be_false
      end
    end

    # A session pinned to a specific SNI (vhost routing, a cert-pinned origin) must be SWEPT
    # against that name — dropping it sends `fuzz --repeater N` to a different vhost, or fails
    # the handshake, where `repeater send N` succeeds.
    it "carries the session's stored SNI into the seed" do
      with_repeater_store("https://r.test", "GET /s HTTP/1.1\r\nHost: r.test\r\n\r\n", sni: "pinned.example") do |(path, id)|
        sni = Gori::CLI::Run.fuzz_source_repeater_for_spec(id, path).sni
        sni.should eq("pinned.example")
      end
    end

    # A WebSocket session seeds its handshake AND its stored outbound frames — the refusal
    # that used to live here is gone. The frames are the half that matters, so they are
    # asserted directly rather than through the handshake.
    it "seeds a WebSocket session's handshake and its stored outbound frames" do
      handshake = "GET /ws HTTP/1.1\r\nHost: r.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
      with_repeater_store("http://r.test", handshake) do |(path, id)|
        store = Gori::Store.open(path)
        begin
          store.update_repeater_ws_messages(id, [
            Gori::Store::WsOutMessage.text(%({"op":"sub","q":"§SEED§"})),
            Gori::Store::WsOutMessage.new(9, Bytes[0x01, 0x02]),
          ])
        ensure
          store.close
        end
        seed = Gori::CLI::Run.fuzz_source_repeater_for_spec(id, path)
        Gori::Proxy::WS.upgrade_request?(seed.text).should be_true
        ws = seed.ws.should_not be_nil
        ws.size.should eq(2)
        # The frame's own `§` is ESCAPED, exactly as the handshake's is: it is the app's text,
        # not a position anyone marked. Without this the sweep would replace the app's own
        # `SEED` with every payload in the set, with no --auto and no --mark passed.
        ws[0].payload.should contain("§§SEED§§")
        Gori::Fuzz::Template.parse(ws[0].payload).position_count.should eq(0)
        # The SHAPE survives: a PING is not folded to TEXT (`WsEngine::OutMsg`'s own defect).
        ws[1].opcode.should eq(9)
        ws[1].payload.bytes.should eq([0x01, 0x02])
      end
    end

    # gori's own `[gori] …` advisory rows are diagnostics it wrote ABOUT the socket, not frames
    # the client sent. Seeding one would put gori's sentence on the wire as a TEXT message —
    # the defect `CLI::Run.ws_seed_rows` exists to prevent, reached here from the fuzz side.
    it "drops gori advisory rows from a WebSocket seed" do
      handshake = "GET /ws HTTP/1.1\r\nHost: r.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
      with_repeater_store("http://r.test", handshake) do |(path, id)|
        store = Gori::Store.open(path)
        begin
          store.update_repeater_ws_messages(id, [
            Gori::Store::WsOutMessage.text("real frame"),
            Gori::Store::WsOutMessage.text("#{Gori::Proxy::WS::NOTICE_PREFIX}a cap tripped"),
          ])
        ensure
          store.close
        end
        ws = Gori::CLI::Run.fuzz_source_repeater_for_spec(id, path).ws.should_not be_nil
        ws.size.should eq(1)
        ws[0].payload.should eq("real frame")
      end
    end
  end

  describe "MCP fuzz_start{flow_id}" do
    it "escapes the capture's § and does not scrub it" do
      with_seed_store(seed_body) do |(path, id, wire)|
        store = Gori::Store.open(path)
        begin
          tools = tools_for(store)
          text, target, http2, evidence = tools.fuzz_template_source_for_spec(%({"flow_id":#{id}}))
          seed_assertions.call(text, wire)
          evidence.should be_true
          target.should eq("http://h.test")
          http2.should be_false
        ensure
          store.close
        end
      end
    end

    it "seeds a capture with no § byte-identically, invalid UTF-8 included" do
      with_seed_store(plain_body) do |(path, id, wire)|
        store = Gori::Store.open(path)
        begin
          tools = tools_for(store)
          text, _, _, _ = tools.fuzz_template_source_for_spec(%({"flow_id":#{id}}))
          text.to_slice.to_a.should eq(wire)
        ensure
          store.close
        end
      end
    end

    # COMPLEMENT: a `template` STRING is the agent's draft — its `§…§` is a position it typed.
    it "keeps a caller-typed §…§ live in a 'template' string" do
      with_seed_store(plain_body) do |(path, _, _)|
        store = Gori::Store.open(path)
        begin
          tools = tools_for(store)
          draft = "GET /?x=§1§ HTTP/1.1\r\nHost: h.test\r\n\r\n"
          text, _, _, evidence = tools.fuzz_template_source_for_spec(%({"template":#{draft.to_json}}))
          text.should eq(draft)
          Gori::Fuzz::Template.parse(text).position_count.should eq(1)
          evidence.should be_false
        ensure
          store.close
        end
      end
    end
  end

  describe "MCP fuzz_start{repeater_id} (#749)" do
    it "seeds from an HTTP repeater session: markers escaped, evidence FALSE" do
      with_repeater_store("http://r.test", "GET /r?q=§SEED§ HTTP/1.1\r\nHost: r.test\r\n\r\n") do |(path, id)|
        store = Gori::Store.open(path)
        begin
          tools = tools_for(store)
          text, target, http2, evidence = tools.fuzz_template_source_for_spec(%({"repeater_id":#{id}}))
          Gori::Fuzz::Template.parse(text).position_count.should eq(0)
          text.should contain("§§SEED§§")
          evidence.should be_false
          target.should eq("http://r.test")
          http2.should be_false
        ensure
          store.close
        end
      end
    end

    it "carries the session's stored SNI into the seed" do
      with_repeater_store("https://r.test", "GET /s HTTP/1.1\r\nHost: r.test\r\n\r\n", sni: "pinned.example") do |(path, id)|
        store = Gori::Store.open(path)
        begin
          tools = tools_for(store)
          _, _, _, _, sni = tools.fuzz_template_source_for_spec(%({"repeater_id":#{id}}))
          sni.should eq("pinned.example")
        ensure
          store.close
        end
      end
    end

    # The CLI refuses every seed pair; MCP used to return on the FIRST match in order, so
    # `{flow_id, repeater_id}` swept the flow and dropped the repeater seed without a word.
    it "refuses two template sources instead of silently ignoring one" do
      with_repeater_store("http://r.test", "GET /r HTTP/1.1\r\nHost: r.test\r\n\r\n") do |(path, id)|
        store = Gori::Store.open(path)
        begin
          tools = tools_for(store)
          expect_raises(Gori::MCP::Tools::FuzzArgError, /ONE template source/) do
            tools.fuzz_template_source_for_spec(%({"template":"GET / HTTP/1.1\\r\\n\\r\\n","repeater_id":#{id}}))
          end
        ensure
          store.close
        end
      end
    end

    # This case used to assert a REFUSAL ("the Fuzzer sweeps HTTP requests, not a framed
    # WebSocket exchange"), which was the asymmetry the WebSocket sweep closed: the Repeater
    # could replay the exchange and the Fuzzer would not touch it. It now seeds, and what the
    # seed must carry is the handshake — the frames come from `fuzz_ws_messages`, asserted in
    # `spec/fuzz/ws_seed_spec.cr`.
    it "seeds a WebSocket repeater session's handshake instead of refusing it" do
      handshake = "GET /ws HTTP/1.1\r\nHost: r.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
      with_repeater_store("http://r.test", handshake) do |(path, id)|
        store = Gori::Store.open(path)
        begin
          tools = tools_for(store)
          text, target, _http2, evidence = tools.fuzz_template_source_for_spec(%({"repeater_id":#{id}}))
          Gori::Proxy::WS.upgrade_request?(text).should be_true
          target.should eq("http://r.test")
          evidence.should be_false # a repeater session is an authored draft, WS or not
        ensure
          store.close
        end
      end
    end
  end
end

# The knock-on the escape creates, on both surfaces. `Template.auto_mark` is a documented
# no-op once ANY `§` is in the text, and the escape puts one there — so a `--flow --auto` run
# over a capture that happens to contain `§` now ends in `NoPositions`, and the standing
# wording would answer "no positions — add §…§ markers, --auto, …" about a request that
# visibly has `?q=1&r=2` and a JSON body full of values, to an operator who passed --auto.
# Naming the literal § is the only true thing to say, and `--mark` / `marks` is the only
# remedy that still works while one is present.
describe "the NoPositions refusal names a literal § instead of re-recommending --auto" do
  seeded = %({"mk":"§§SEED§§"}) # what the --flow / flow_id seed produces
  none = "GET /?q=1 HTTP/1.1\r\nHost: h\r\n\r\n"
  r = Gori::Fuzz::PlanError::Reason::NoPositions

  it "gori run fuzz says so" do
    msg = Gori::CLI::Run.fuzz_plan_error_for_spec(r, seeded)
    msg.should contain("literal")
    msg.should contain("--mark")
    # …and stops pointing at the flag that cannot help.
    msg.should contain("--auto adds nothing")
  end

  it "MCP says so" do
    tools = Gori::MCP::Tools.new(Gori::Store.open(":memory:"), allow_actions: false, verify_upstream: false)
    msg = tools.fuzz_plan_error_for_spec(r, seeded)
    msg.should contain("literal")
    msg.should contain("'marks'")
    msg.should contain("'auto' adds nothing")
  end

  # CONTROL: a template with NO § at all keeps the standing wording — that advice is correct
  # there, and `--auto` / `auto:true` really is the shortest way out of it.
  it "leaves the ordinary no-marker message alone on both surfaces" do
    Gori::CLI::Run.fuzz_plan_error_for_spec(r, none)
      .should eq("no positions — add §…§ markers, --auto, or --mark TOKEN")
    tools = Gori::MCP::Tools.new(Gori::Store.open(":memory:"), allow_actions: false, verify_upstream: false)
    tools.fuzz_plan_error_for_spec(r, none)
      .should eq("template has no §…§ positions (add markers, or pass auto:true with a flow_id)")
  end
end
