require "../spec_helper"

private alias M = Gori::Miner
private alias F = Gori::Fuzz

# An origin that reads a request body the way HTTP/1.1 says to: `Content-Length` octets and no
# more. A message that carries a body and declares no length has no body at all (RFC 7230
# §3.3.3) — the octets after the blank line are the front of the next request line — so nothing
# the miner splices into them can reach the application.
private class FramedFormBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @secret : String)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    params = form_params(declared_body(bytes))
    body = "BASELINE BODY CONTENT"
    if v = params[@secret]?
      body += " reflected=#{v}"
    end
    ok(body)
  end

  private def declared_body(bytes : Bytes) : String
    text = String.new(bytes)
    idx = text.index("\r\n\r\n")
    return "" unless idx
    cl = nil.as(Int32?)
    text[0, idx].each_line do |line|
      name, sep, value = line.partition(':')
      cl = value.strip.to_i? if !sep.empty? && name.downcase == "content-length"
    end
    return "" unless cl
    rest = text[(idx + 4)..]
    rest[0, {cl, rest.bytesize}.min]
  end

  private def form_params(body : String) : Hash(String, String)
    out = Hash(String, String).new
    body.split('&') do |pair|
      k, _, v = pair.partition('=')
      out[k] = v unless k.empty?
    end
    out
  end

  private def ok(body : String) : Gori::Repeater::Result
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end
end

private UNFRAMED = "POST /s HTTP/1.1\r\nHost: t.test\r\n" \
                   "Content-Type: application/x-www-form-urlencoded\r\n\r\nn=jay"

private FRAMED = "POST /s HTTP/1.1\r\nHost: t.test\r\n" \
                 "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 5\r\n\r\nn=jay"

private def form_plan(raw : String, evidence : Bool = false) : M::Plan
  cfg = M::Config.new(locations: [M::Location::Form], concurrency: 4,
    stability_rounds: 2, confirm_rounds: 1)
  M::Plan.build(M::PlanOptions.new(raw, evidence: evidence, target: "http://t.test:80",
    config: cfg), ungated_outbound)
end

private def mine(raw : String) : Array(M::Finding)
  plan = form_plan(raw)
  backend = FramedFormBackend.new(F::Origin.new("http", "t.test", 80), "debug")
  engine = M::Engine.new(plan.request, false, plan.names, backend, plan.config)
  found = [] of M::Finding
  engine.run { |ev| found << ev.finding if ev.is_a?(M::FindingEvent) }
  found
end

describe "Miner::Plan framing a body the seed declared no length for" do
  it "finds a hidden form parameter when the seed declares a length" do
    mine(FRAMED).map(&.name).should contain("debug")
  end

  # The defect: the same seed WITHOUT a Content-Length reported `0 found` — a clean-looking
  # run over a request the origin never read a body from.
  it "finds the same parameter when the seed declares none" do
    mine(UNFRAMED).map(&.name).should contain("debug")
  end

  it "adds the header to the bytes the engine mines" do
    String.new(form_plan(UNFRAMED).request).should contain("Content-Length: 5\r\n")
  end

  it "adds it for an EVIDENCE seed too (a repeater session or an editor draft carries none)" do
    String.new(form_plan(UNFRAMED, evidence: true).request).should contain("Content-Length: 5\r\n")
  end

  # ADD-only. A declared length that deliberately disagrees with the body is the CL-desync
  # probe itself, and re-declaring it here would test something else.
  it "leaves a deliberately wrong Content-Length alone" do
    desync = "POST /s HTTP/1.1\r\nHost: t.test\r\n" \
             "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 99\r\n\r\nn=jay"
    String.new(form_plan(desync).request).should eq(desync)
  end

  it "invents nothing beside a Transfer-Encoding" do
    chunked = "POST /s HTTP/1.1\r\nHost: t.test\r\n" \
              "Content-Type: application/x-www-form-urlencoded\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nn=jay\r\n0\r\n\r\n"
    String.new(form_plan(chunked).request).should eq(chunked)
  end

  # A bare-LF head is what the TUI editor holds and what an evidence seed skips `expand_wire`'s
  # CRLF promotion for, so the added line has to carry the message's OWN terminator.
  it "frames an LF-separated head with an LF-terminated line" do
    lf = "POST /s HTTP/1.1\nHost: t.test\n" \
         "Content-Type: application/x-www-form-urlencoded\n\nn=jay"
    String.new(form_plan(lf, evidence: true).request)
      .should eq("POST /s HTTP/1.1\nHost: t.test\n" \
                 "Content-Type: application/x-www-form-urlencoded\nContent-Length: 5\n\nn=jay")
  end

  it "leaves a bodyless request byte-exact" do
    get = "GET /s?q=hi HTTP/1.1\r\nHost: t.test\r\n\r\n"
    cfg = M::Config.new(locations: [M::Location::Query], concurrency: 2)
    plan = M::Plan.build(M::PlanOptions.new(get, target: "http://t.test:80", config: cfg),
      ungated_outbound)
    String.new(plan.request).should eq(get)
  end
end
