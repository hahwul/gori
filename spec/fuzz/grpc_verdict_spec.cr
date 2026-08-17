require "../spec_helper"

private alias F = Gori::Fuzz

# Round 7 / H2 F1 + F2 — the fuzz surface had ZERO gRPC awareness (`grep -rn grpc
# src/gori/fuzz/` was empty), which cost the operator two different facts:
#
#   F1  For gRPC the h2 `:status` is 200 BY DEFINITION and the call's real outcome lives in
#       the `grpc-status` / `grpc-message` trailers. A sweep against an origin that DENIED
#       every call produced output byte-identical to one against an origin that allowed them
#       all — `200 · matched` on every row, including the denied ones, on the exact workflow
#       (telling an authz bypass from a rejection) a fuzz run over gRPC is for.
#
#   F2  A payload that changes the message length leaves the 5-byte gRPC length prefix
#       declaring the OLD length (`00000000054141414141414141` — prefix says 5, payload is 8).
#       A real gRPC server rejects that, and gori reported `3 sent · 0 errors`. The BYTES are
#       right under P7; the defect is the asymmetry with Content-Length, which IS resynced by
#       default and says so loudly. So: bytes unchanged, said once.
#
# Everything here runs off a FakeBackend — the wire behaviour is `spec/repeater/*` and the
# round-7 live origin's job; what is pinned here is what the row and the run REPORT.

private class FakeBackend < F::Backend
  getter origin : F::Origin
  getter wire = [] of Bytes

  def initialize(@origin : F::Origin, &@fn : Bytes -> Gori::Repeater::Result)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @wire << bytes.dup
    @fn.call(bytes)
  end
end

# A gRPC response exactly as the h2 Assembler projects one: 200 with the trailers merged
# into the head after the initial block, plus gori's own `X-Gori-Trailers` marker.
private def grpc_response(code : Int32, message : String) : Gori::Repeater::Result
  body = Bytes[0, 0, 0, 0, 7, 0x0a, 5, 104, 101, 108, 108, 111] # one framed message
  head = ("HTTP/2 200\r\ncontent-type: application/grpc\r\n" +
          "grpc-status: #{code}\r\ngrpc-message: #{message}\r\n" +
          "X-Gori-Trailers: grpc-status, grpc-message\r\n\r\n").to_slice
  resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
  Gori::Repeater::Result.new(head, body, resp, 1234_i64)
end

private def plain_response : Gori::Repeater::Result
  head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice
  resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
  Gori::Repeater::Result.new(head, "ok".to_slice, resp, 1234_i64)
end

# The 5-byte gRPC length prefix, built from bytes rather than written as an escape so it is
# unambiguous what goes on the wire. GOOD declares 5 over a 5-byte message; LYING declares
# 255 over the same one — a deliberately-wrong prefix is one of the standard gRPC parser
# tests (see `Grpc.scan`), authored on purpose.
private GOOD_PREFIX  = String.new(Bytes[0_u8, 0_u8, 0_u8, 0_u8, 5_u8])
private LYING_PREFIX = String.new(Bytes[0_u8, 0_u8, 0_u8, 0_u8, 255_u8])

# `00 00000005 §hello§` — a cleanly-framed unary gRPC request whose message is the marked
# position, i.e. the shape every real gRPC fuzz template has.
private GRPC_HEAD = "POST /pkg.Svc/Good HTTP/2\r\nHost: h\r\n" +
                    "content-type: application/grpc\r\nte: trailers\r\nContent-Length: 10\r\n\r\n"

private PLAIN_TEMPLATE = "POST /s HTTP/1.1\r\nHost: h\r\n" +
                         "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 7\r\n\r\nq=§hello§"

private def grpc_template(prefix : String = GOOD_PREFIX) : String
  "#{GRPC_HEAD}#{prefix}§hello§"
end

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

# Build + drain a run over `template` against `respond`, through Fuzz::Plan (the builder is
# what decides `grpc_template?`, so going around it would test the wrong seam).
private def sweep(template : String, payloads : Array(String),
                  matcher : F::Matcher = F::Matcher.new(keep_bodies: :none),
                  reframe_grpc : Bool = false,
                  &respond : Bytes -> Gori::Repeater::Result) : {Array(F::Result), F::Progress, Array(Bytes)}
  sources = [F::InlineList.new(payloads).as(F::PayloadSource)]
  options = F::PlanOptions.new(template, evidence: true, target: "http://h:80",
    sources: sources,
    config: F::Config.new(mode: F::Mode::Sniper, concurrency: 1, keep_bodies: :none,
      reframe_grpc: reframe_grpc),
    matcher: matcher)
  plan = F::Plan.build(options, ungated)
  backend = FakeBackend.new(plan.origin, &respond)
  engine = F::Engine.new(plan.generator, plan.matcher, backend, plan.config)
  results = [] of F::Result
  progress = F::Progress.new(0_i64, nil, 0_i64, 0_i64)
  engine.run do |ev|
    case ev
    when F::ResultEvent then results << ev.result
    when F::DoneEvent   then progress = ev.progress
    end
  end
  {results, progress, backend.wire}
end

describe "fuzz over gRPC" do
  # F1. The two runs differ ONLY in the origin's trailer; before the fix their result sets
  # were byte-identical, which is the false-positive machine the finding names.
  it "carries the grpc-status trailer on every row, so a denied call differs from a granted one" do
    denied, _, _ = sweep(grpc_template, ["hello", "world"]) { grpc_response(7, "nope; you may not") }
    granted, _, _ = sweep(grpc_template, ["hello", "world"]) { grpc_response(0, "") }

    denied.size.should eq(2)
    denied.each do |r|
      r.status.should eq(200) # the h2 status is 200 for BOTH runs — that is the whole point
      r.grpc_status.should eq(7)
      r.grpc_message.should eq("nope; you may not")
    end
    granted.each do |r|
      r.status.should eq(200)
      r.grpc_status.should eq(0)
      r.grpc_message.should be_nil # an empty grpc-message is absent, not ""
    end
    # The fact a scripted caller keys on: the two runs are now distinguishable.
    denied.map(&.grpc_status).should_not eq(granted.map(&.grpc_status))
  end

  # F1, the reporting half: the row field reaches the CLI text row and `--format json`,
  # named, and is ABSENT (not a false null) on a non-gRPC row.
  it "emits grpc_status / grpc_status_name / grpc_message on the JSON and text rows, only when present" do
    r = F::Result.new(0_i64, ["hello"], 0, 200, 12_i64, 2, 1, 660_i64, nil, true, false, nil,
      grpc_status: 7, grpc_message: "nope; you may not")
    j = JSON.parse(Gori::CLI::Output.fuzz_row_json(r))
    j["grpc_status"].as_i.should eq(7)
    j["grpc_status_name"].as_s.should eq("PERMISSION_DENIED")
    j["grpc_message"].as_s.should eq("nope; you may not")
    text = Gori::CLI::Output.fuzz_row_text(r)
    text.should contain("grpc 7 PERMISSION_DENIED")
    text.should contain("nope; you may not")

    # Complement: an ordinary HTTP row is byte-identical to what it was — no new field noise.
    plain = F::Result.new(1_i64, ["hello"], 0, 200, 8_i64, 2, 1, 300_i64, nil, true, false, nil)
    Gori::CLI::Output.fuzz_row_json(plain).should_not contain("grpc")
    Gori::CLI::Output.fuzz_row_text(plain).should_not contain("grpc")
  end

  # F1, the MCP half — `fuzz_results` had the same shape as the CLI and the same gap.
  it "emits the gRPC verdict on the MCP fuzz_result row" do
    r = F::Result.new(0_i64, ["hello"], 0, 200, 12_i64, 2, 1, 660_i64, nil, true, false, nil,
      grpc_status: 7, grpc_message: "nope; you may not")
    j = JSON.parse(JSON.build { |b| Gori::MCP::Serialize.fuzz_result(b, r) })
    j["grpc_status"].as_i.should eq(7)
    j["grpc_status_name"].as_s.should eq("PERMISSION_DENIED")
    j["grpc_message"].as_s.should eq("nope; you may not")

    plain = F::Result.new(1_i64, ["hello"], 0, 200, 8_i64, 2, 1, 300_i64, nil, true, false, nil)
    JSON.build { |b| Gori::MCP::Serialize.fuzz_result(b, plain) }.should_not contain("grpc")
  end

  # F1, the "make it usable" half: the verdict is a MATCH dimension, not just a printed
  # field. `--mc`/`--fc` cannot express it — every gRPC response is 200.
  it "matches and filters on grpc-status the way --mc does on the HTTP status" do
    m = F::Matcher.new(keep_bodies: :none)
    m.match_grpc = ">0"
    denied, _, _ = sweep(grpc_template, ["hello", "world"], m) { grpc_response(7, "no") }
    denied.count(&.matched?).should eq(2)

    m2 = F::Matcher.new(keep_bodies: :none)
    m2.match_grpc = ">0"
    granted, _, _ = sweep(grpc_template, ["hello", "world"], m2) { grpc_response(0, "") }
    granted.count(&.matched?).should eq(0)

    # A filter is the mirror.
    m3 = F::Matcher.new(keep_bodies: :none)
    m3.filter_grpc = "0"
    kept, _, _ = sweep(grpc_template, ["hello"], m3) { grpc_response(0, "") }
    kept.first.matched?.should be_false

    # A spec that is PRESENT can never match a response with no gRPC status at all — the same
    # rule `--mc` follows for a response with no status.
    m4 = F::Matcher.new(keep_bodies: :none)
    m4.match_grpc = "7"
    plain_rows, _, _ = sweep(PLAIN_TEMPLATE, ["hello"], m4) { plain_response }
    plain_rows.first.matched?.should be_false
  end

  # F2. Two of three payloads change the message length, so two requests go out with a prefix
  # claiming 5. The bytes stay VERBATIM (P7) and the run says so once.
  it "counts and names the requests a payload left with a stale gRPC length prefix" do
    _, progress, wire = sweep(grpc_template, ["AAAAAAAA", "x", "hello"]) { grpc_response(0, "") }

    progress.errors.should eq(0_i64) # the wire is fine; this is a framing NOTICE, not an error
    progress.grpc_requests.should eq(3_i64)
    progress.grpc_stale.should eq(2_i64)
    progress.grpc_stale_reason.not_nil!.should contain("not a complete gRPC frame")

    # And the bytes really did go out untouched — the prefix still says 5 for an 8-byte
    # payload, exactly as the round-7 origin logged it. NO re-framing was introduced.
    bodies = wire.map { |w| String.new(w).split("\r\n\r\n", 2)[1].to_slice.hexstring }
    bodies.should eq([
      "00000000054141414141414141", # prefix 5, payload 8 — left stale, verbatim
      "000000000578",               # prefix 5, payload 1 — left stale, verbatim
      "000000000568656c6c6f",       # the only well-framed one
    ])
  end

  # Complement: a gRPC run whose every request frames cleanly must NOT emit the notice.
  it "stays silent when every rendered request still frames cleanly" do
    _, progress, _ = sweep(grpc_template, ["world", "plain"]) { grpc_response(0, "") }
    progress.grpc_requests.should eq(2_i64)
    progress.grpc_stale.should eq(0_i64)
    progress.grpc_stale_reason.should be_nil
  end

  # Complement: a non-gRPC run is untouched — the template flag is off, nothing is scanned,
  # and the counters stay at the zero every surface renders as "no line at all".
  it "does not scan or report framing for a non-gRPC template" do
    _, progress, _ = sweep(PLAIN_TEMPLATE, ["hello", "world"]) { plain_response }
    progress.grpc_requests.should eq(0_i64)
    progress.grpc_stale.should eq(0_i64)
    progress.grpc_stale_reason.should be_nil
  end

  # PR 7 — `--reframe-grpc` / `reframe_grpc:true`, the OPT-IN inverse. Same three payloads as
  # the F2 case above, so the pair reads as one before/after: the flag is the ONLY difference,
  # and the run that asked for it puts well-framed bytes on the wire.
  it "recomputes the length prefix for every request when reframe_grpc is on" do
    _, progress, wire = sweep(grpc_template, ["AAAAAAAA", "x", "hello"], reframe_grpc: true) { grpc_response(0, "") }

    bodies = wire.map { |w| String.new(w).split("\r\n\r\n", 2)[1].to_slice.hexstring }
    bodies.should eq([
      "00000000084141414141414141", # prefix now 8 for an 8-byte payload
      "000000000178",               # prefix now 1
      "000000000568656c6c6f",       # already right — byte-identical to the default run
    ])

    # And with nothing stale left on the wire, the notice's counter is zero: the two halves
    # read the SAME bytes, so a run cannot both reframe and report itself stale.
    progress.grpc_requests.should eq(3_i64)
    progress.grpc_stale.should eq(0_i64)
    progress.grpc_stale_reason.should be_nil
  end

  # The default is not merely "off", it is the P7 answer, and it stays the default. Pinned
  # against the flag so a future change cannot flip it without this failing.
  it "leaves the prefix stale by default — reframing is opt-in only" do
    _, off, wire_off = sweep(grpc_template, ["AAAAAAAA"]) { grpc_response(0, "") }
    _, on, wire_on = sweep(grpc_template, ["AAAAAAAA"], reframe_grpc: true) { grpc_response(0, "") }
    off.grpc_stale.should eq(1_i64)
    on.grpc_stale.should eq(0_i64)
    wire_off.first.should_not eq(wire_on.first)
    # Size-preserving, so the Content-Length the CL pass wrote is still right either way.
    wire_off.first.size.should eq(wire_on.first.size)
  end

  # A CLIENT-STREAMING template: two framed messages, the marked position inside the second.
  # `Grpc.reframe` refuses this one on purpose (collapsing two honest frames into one would
  # send a different message), so the run reports it stale exactly as it does with the flag
  # off — the opt-in never trades a warning for a corrupt body.
  it "leaves a multi-message body alone even with reframe_grpc on, and still reports it" do
    tmpl = "#{GRPC_HEAD}#{GOOD_PREFIX}hello#{GOOD_PREFIX}§world§"
    _, progress, wire = sweep(tmpl, ["AAAAAAAA"], reframe_grpc: true) { grpc_response(0, "") }
    body = String.new(wire.first).split("\r\n\r\n", 2)[1].to_slice.hexstring
    body.should eq("000000000568656c6c6f00000000054141414141414141") # both prefixes verbatim
    progress.grpc_stale.should eq(1_i64)
  end

  # A non-gRPC run must not grow a body rewrite from a flag it has no use for.
  it "does not touch a non-gRPC template when reframe_grpc is on" do
    _, _, plain_off = sweep(PLAIN_TEMPLATE, ["hello"]) { plain_response }
    _, _, plain_on = sweep(PLAIN_TEMPLATE, ["hello"], reframe_grpc: true) { plain_response }
    plain_on.first.should eq(plain_off.first)
  end

  # A seed that is ALREADY mis-framed is the operator's own deliberate parser test. There is
  # nothing left for a payload to break, so the run must not grow a notice about bytes the
  # operator wrote on purpose.
  it "leaves a deliberately mis-framed seed alone" do
    _, progress, _ = sweep(grpc_template(LYING_PREFIX), ["hello", "AAAAAAAA"]) { grpc_response(0, "") }
    progress.grpc_requests.should eq(0_i64)
    progress.grpc_stale.should eq(0_i64)
  end

  # …and `--reframe-grpc` does not override that. "Recompute the prefix after a PAYLOAD
  # changed the message" has nothing to recompute over a seed that was wrong before any
  # payload existed — repairing it would destroy the test the operator wrote.
  it "does not repair a deliberately mis-framed seed even with reframe_grpc on" do
    _, _, off = sweep(grpc_template(LYING_PREFIX), ["hello"]) { grpc_response(0, "") }
    _, _, on = sweep(grpc_template(LYING_PREFIX), ["hello"], reframe_grpc: true) { grpc_response(0, "") }
    on.first.should eq(off.first)
    # the lying prefix, verbatim. Compared as hex: 0xFF is not valid UTF-8, so a String
    # comparison would be about the scrub and not about the bytes.
    String.new(on.first).split("\r\n\r\n", 2)[1].to_slice.hexstring
      .should eq("00000000ff68656c6c6f")
  end
end

describe F::GrpcVerdict do
  it "reads the LAST grpc-status, so a head-promoted 0 cannot hide the trailer's 7" do
    head = ("HTTP/2 200\r\ncontent-type: application/grpc\r\n" +
            "grpc-status: 0\r\ngrpc-message: all good\r\n" +
            "grpc-status: 7\r\ngrpc-message: nope\r\n\r\n").to_slice
    code, msg = F::GrpcVerdict.response(head)
    code.should eq(7)
    msg.should eq("nope")
  end

  it "answers nil for a response with no gRPC status at all" do
    F::GrpcVerdict.response("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice).should eq({nil, nil})
    F::GrpcVerdict.response(nil).should eq({nil, nil})
  end
end
