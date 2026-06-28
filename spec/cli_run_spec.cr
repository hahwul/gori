require "./spec_helper"
require "json"

# Builds a minimal FlowDetail without touching the DB (the structs have public
# initializers) — enough to exercise the pure reconstruction/formatting code.
private def flow_detail(scheme : String, host : String, port : Int32, request_head : String,
                        request_body : Bytes? = nil, http_version = "HTTP/1.1",
                        target = "/", response_head : String? = nil, response_body : String? = nil,
                        request_body_truncated = false)
  row = Gori::Store::FlowRow.new(
    id: 7_i64, created_at: 0_i64, scheme: scheme, method: "GET", host: host, port: port,
    target: target, status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, http_version, request_head.to_slice, request_body,
    response_head.try(&.to_slice), response_body.try(&.to_slice),
    request_body_truncated: request_body_truncated)
end

private def flow_row(*, target : String, host : String, status : Int32?, state : Gori::Store::FlowState)
  Gori::Store::FlowRow.new(
    id: 42_i64, created_at: 1_700_000_000_000_000_i64, scheme: "https", method: "GET",
    host: host, port: 443, target: target, status: status, size: 1536_i64, state: state,
    response_size: 1400_i64, duration_us: 3000_i64, content_type: "text/html")
end

private def with_store(&)
  path = File.tempname("gori-clirun", ".db")
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

describe Gori::Replay::FlowRequest do
  it "rewrites an absolute-form request line to origin-form, keeping the rest exact" do
    head = "GET http://example.com/a?b=1 HTTP/1.1\r\nHost: example.com\r\nX-T: 1\r\n\r\n"
    built = Gori::Replay::FlowRequest.build(flow_detail("http", "example.com", 80, head))
    String.new(built.bytes).should eq("GET /a?b=1 HTTP/1.1\r\nHost: example.com\r\nX-T: 1\r\n\r\n")
    built.target.should eq("http://example.com") # default port omitted
    built.http2.should be_false
  end

  it "leaves an origin-form request byte-exact and derives the https target" do
    head = "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n"
    built = Gori::Replay::FlowRequest.build(flow_detail("https", "api.test", 443, head))
    String.new(built.bytes).should eq(head)
    built.target.should eq("https://api.test")
  end

  it "keeps a non-default port in the target" do
    built = Gori::Replay::FlowRequest.build(flow_detail("https", "api.test", 8443, "GET / HTTP/1.1\r\n\r\n"))
    built.target.should eq("https://api.test:8443")
  end

  it "flags HTTP/2 flows" do
    built = Gori::Replay::FlowRequest.build(flow_detail("https", "h", 443, "GET / HTTP/1.1\r\n\r\n", http_version: "HTTP/2"))
    built.http2.should be_true
  end

  it "preserves a binary body byte-for-byte (no text round-trip corruption)" do
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\n"
    body = Bytes[0x00, 0x0A, 0xFF, 0x0D] # contains LF/CR bytes a line-splitter would mangle
    built = Gori::Replay::FlowRequest.build(flow_detail("https", "h", 443, head, request_body: body))
    expected = head.to_slice.to_a + body.to_a
    built.bytes.to_a.should eq(expected)
  end

  it "rewrites the request line but keeps an absolute-form body exact" do
    head = "POST http://h/p HTTP/1.1\r\nHost: h\r\n\r\n"
    body = Bytes[0x0A, 0x41, 0x0A]
    built = Gori::Replay::FlowRequest.build(flow_detail("http", "h", 80, head, request_body: body))
    String.new(built.bytes).should eq("POST /p HTTP/1.1\r\nHost: h\r\n\r\n\nA\n")
  end

  it "re-syncs Content-Length to the stored body when the capture was truncated" do
    # Head over-promises CL: 9999 but only 3 bytes survived the 8 MiB cap — replaying the
    # original CL would hang the origin. build() rewrites CL to the actual length.
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 9999\r\nX-T: 1\r\n\r\n"
    body = Bytes[0x41, 0x42, 0x43] # "ABC"
    built = Gori::Replay::FlowRequest.build(
      flow_detail("http", "h", 80, head, request_body: body, request_body_truncated: true))
    String.new(built.bytes).should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nX-T: 1\r\n\r\nABC")
  end

  it "leaves Content-Length untouched when the body was NOT truncated" do
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n"
    body = Bytes[0x41, 0x42, 0x43]
    built = Gori::Replay::FlowRequest.build(flow_detail("http", "h", 80, head, request_body: body))
    String.new(built.bytes).should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nABC")
  end

  it "preserves a bare-LF request-line terminator when rewriting (no mixed endings)" do
    head = "GET http://h/p HTTP/1.1\nHost: h\n\n" # LF-only, absolute-form
    built = Gori::Replay::FlowRequest.build(flow_detail("http", "h", 80, head))
    String.new(built.bytes).should eq("GET /p HTTP/1.1\nHost: h\n\n") # stays LF — no \r introduced
  end

  it "parses targets (the inverse of build_target)" do
    Gori::Replay::FlowRequest.parse_target("https://h").should eq({"https", "h", 443})
    Gori::Replay::FlowRequest.parse_target("http://h:8080").should eq({"http", "h", 8080})
    Gori::Replay::FlowRequest.parse_target("h:9000").should eq({"http", "h", 9000}) # bare → http
    Gori::Replay::FlowRequest.parse_target("https://h:8443/p").should eq({"https", "h", 8443})
  end

  it "only rewrites a well-formed absolute request line" do
    Gori::Replay::FlowRequest.rewrite_request_line("GET http://e/a HTTP/1.1").should eq("GET /a HTTP/1.1")
    Gori::Replay::FlowRequest.rewrite_request_line("GET /a HTTP/1.1").should be_nil # already origin-form
    Gori::Replay::FlowRequest.rewrite_request_line("garbage").should be_nil
  end
end

describe Gori::Findings::Export do
  it "serialises findings to JSON with the documented fields" do
    findings = [
      Gori::Store::Finding.new(1_i64, 10_i64, 20_i64, "XSS", Gori::Store::Severity::High,
        "shop.test", 13_i64, "reflected", Gori::Store::Status::Confirmed),
      Gori::Store::Finding.new(2_i64, 11_i64, 11_i64, "note", Gori::Store::Severity::Info,
        nil, nil, "", Gori::Store::Status::Open),
    ]
    parsed = JSON.parse(Gori::Findings::Export.json(findings)).as_a
    parsed.size.should eq(2)
    parsed[0]["title"].as_s.should eq("XSS")
    parsed[0]["severity"].as_s.should eq("high")
    parsed[0]["status"].as_s.should eq("confirmed")
    parsed[0]["flow_id"].as_i.should eq(13)
    parsed[1]["host"].raw.should be_nil
    parsed[1]["flow_id"].raw.should be_nil
  end

  it "renders a Markdown report with severity/status labels and notes" do
    with_store do |store|
      findings = [Gori::Store::Finding.new(1_i64, 0_i64, 0_i64, "Reflected XSS",
        Gori::Store::Severity::High, "shop.test", nil, "encode on output", Gori::Store::Status::Open)]
      md = Gori::Findings::Export.markdown(findings, store, "demo")
      md.should contain("# Findings — demo")
      md.should contain("## [high] Reflected XSS")
      md.should contain("**Severity:** high")
      md.should contain("**Status:** open")
      md.should contain("encode on output")
    end
  end

  it "embeds linked-flow evidence in the Markdown report" do
    with_store do |store|
      req = Gori::Store::CapturedRequest.new(
        created_at: 0_i64, scheme: "https", host: "api.test", port: 443, method: "GET",
        target: "/v1/debug", http_version: "HTTP/1.1",
        head: "GET /v1/debug HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice)
      fid = store.insert_flow(req)
      store.flush
      findings = [Gori::Store::Finding.new(1_i64, 0_i64, 0_i64, "leak",
        Gori::Store::Severity::Medium, "api.test", fid, "", Gori::Store::Status::Open)]
      md = Gori::Findings::Export.markdown(findings, store, "demo")
      md.should contain("### Request")
      md.should contain("GET /v1/debug HTTP/1.1")
      md.should contain("(##{fid})")
      # The header block's terminating CRLF CRLF is trimmed, so the last header
      # line abuts the closing fence (no stack of blank lines inside the block).
      md.should contain("Host: api.test\n```")
      md.should_not contain("\r\n\r\n")
    end
  end

  it "separates evidence headers from the body with exactly one blank line" do
    with_store do |store|
      req = Gori::Store::CapturedRequest.new(
        created_at: 0_i64, scheme: "https", host: "api.test", port: 443, method: "POST",
        target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: api.test\r\nContent-Length: 9\r\n\r\n".to_slice,
        body: "user=root".to_slice)
      fid = store.insert_flow(req)
      store.flush
      findings = [Gori::Store::Finding.new(1_i64, 0_i64, 0_i64, "creds in body",
        Gori::Store::Severity::High, "api.test", fid, "", Gori::Store::Status::Open)]
      md = Gori::Findings::Export.markdown(findings, store, "demo")
      # one blank line between the last header and the body — not three
      md.should contain("Content-Length: 9\n\nuser=root")
      md.should_not contain("Content-Length: 9\n\n\nuser=root")
    end
  end
end

describe Gori::QL do
  # `gori run history -q` relies on this: a query that fails to compile to any
  # clause collapses to the match-all EMPTY filter. The CLI special-cases that so
  # a typo like `status:>=foo` errors instead of silently dumping every flow.
  it "collapses an un-compilable query to EMPTY (so the CLI can reject it)" do
    Gori::QL.parse("status:>=foo").should eq(Gori::QL::EMPTY)
    Gori::QL.parse("-status:bar").should eq(Gori::QL::EMPTY)
    Gori::QL.parse("login").should_not eq(Gori::QL::EMPTY)
    Gori::QL.parse("status:>=500").should_not eq(Gori::QL::EMPTY)
  end
end

describe Gori::CLI::Output do
  it "shows an absolute-form target as-is and prefixes an origin-form one with the host" do
    abs = Gori::CLI::Output.flow_row_text(flow_row(target: "http://e.test/a", host: "e.test", status: 200, state: Gori::Store::FlowState::Complete))
    abs.should contain("http://e.test/a")
    abs.should_not contain("e.testhttp://") # no double host

    rel = Gori::CLI::Output.flow_row_text(flow_row(target: "/a", host: "api.test", status: 200, state: Gori::Store::FlowState::Complete))
    rel.should contain("api.test/a")
  end

  it "marks a pending flow with a dash status and a state tag" do
    txt = Gori::CLI::Output.flow_row_text(flow_row(target: "/p", host: "h", status: nil, state: Gori::Store::FlowState::Pending))
    txt.should contain("—")
    txt.should contain("[Pending]")
  end

  it "emits a valid JSON object with the expected keys" do
    json = JSON.parse(Gori::CLI::Output.flow_row_json(flow_row(target: "/a", host: "h", status: 200, state: Gori::Store::FlowState::Complete)))
    json["id"].as_i.should eq(42)
    json["method"].as_s.should eq("GET")
    json["status"].as_i.should eq(200)
    json["state"].as_s.should eq("Complete")
  end

  it "humanises sizes and durations" do
    Gori::CLI::Output.human_size(500_i64).should eq("500B")
    Gori::CLI::Output.human_size(1536_i64).should eq("1.5kB")
    Gori::CLI::Output.human_us(500_i64).should eq("500µs")
    Gori::CLI::Output.human_us(1_500_i64).should eq("1.5ms")
  end

  it "scales human_size up to GB and TB (no '1024.0MB')" do
    Gori::CLI::Output.human_size(1_073_741_824_i64).should eq("1.0GB")     # exactly 1 GiB
    Gori::CLI::Output.human_size(5_368_709_120_i64).should eq("5.0GB")     # 5 GiB
    Gori::CLI::Output.human_size(2_199_023_255_552_i64).should eq("2.0TB") # 2 TiB
  end
end
