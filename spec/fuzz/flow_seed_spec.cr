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
      head: h.to_slice, body: body))
    store.close
    yield({path, id, (h.to_slice.to_a + body.to_a)})
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
    fuzz_source(flow_id, request_file, nil, db_path)
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
        text, target, http2, evidence = Gori::CLI::Run.fuzz_source_for_spec(id, nil, path)
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
        text, _, _, _ = Gori::CLI::Run.fuzz_source_for_spec(id, nil, path)
        text.to_slice.to_a.should eq(wire) # WAS: ff fe → ef bf bd ef bf bd
      end
    end

    # COMPLEMENT: a valid-UTF-8 multibyte body (Korean, emoji) is untouched either way.
    it "leaves a valid multibyte capture alone" do
      body = %({"이름":"관리자","e":"🐿️"}).to_slice
      with_seed_store(body) do |(path, id, wire)|
        text, _, _, _ = Gori::CLI::Run.fuzz_source_for_spec(id, nil, path)
        text.to_slice.to_a.should eq(wire)
      end
    end

    # COMPLEMENT: a `--request` FILE is a DRAFT the operator authored, not evidence — their
    # own `§…§` must still mark and fuzz. Only the `--flow` branch escapes.
    it "keeps an operator's own §…§ live in a --request template" do
      file = File.tempname("gori-fuzzreq", ".txt")
      begin
        File.write(file, "GET /?x=§1§ HTTP/1.1\r\nHost: h.test\r\n\r\n")
        text, _, _, evidence = Gori::CLI::Run.fuzz_source_for_spec(nil, file, nil)
        Gori::Fuzz::Template.parse(text).position_count.should eq(1)
        evidence.should be_false
      ensure
        File.delete?(file)
      end
    end
  end

  describe "MCP fuzz_start{flow_id}" do
    it "escapes the capture's § and does not scrub it" do
      with_seed_store(seed_body) do |(path, id, wire)|
        store = Gori::Store.open(path)
        begin
          tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
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
          tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
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
          tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
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
