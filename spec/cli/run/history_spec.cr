require "../../spec_helper"
require "base64"
require "json"

# `gori run history` / `gori run show` — the QL gate on the listing, the flow-row text and
# JSON contract in CLI::Output, and the `show --format json` document. Split out of the
# monolithic spec/cli/run_spec.cr so each subcommand mirrors src/gori/cli/run/.

private def flow_row(*, target : String, host : String, status : Int32?, state : Gori::Store::FlowState)
  Gori::Store::FlowRow.new(
    id: 42_i64, created_at: 1_700_000_000_000_000_i64, scheme: "https", method: "GET",
    host: host, port: 443, target: target, status: status, size: 1536_i64, state: state,
    response_size: 1400_i64, duration_us: 3000_i64, content_type: "text/html")
end

private def flow_detail(scheme : String, host : String, port : Int32, request_head : String,
                        http_version = "HTTP/1.1",
                        response_head : String? = nil, response_body : String? = nil)
  row = Gori::Store::FlowRow.new(
    id: 7_i64, created_at: 0_i64, scheme: scheme, method: "GET", host: host, port: port,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, http_version, request_head.to_slice, nil,
    response_head.try(&.to_slice), response_body.try(&.to_slice))
end

# gRPC length-prefixed frame (1-byte flag + 4-byte big-endian length + payload).
private def grpc_frame_for_spec(payload : Bytes, flag : UInt8 = 0_u8) : Bytes
  io = IO::Memory.new
  io.write_byte(flag)
  io.write_bytes(payload.size.to_u32, IO::ByteFormat::BigEndian)
  io.write(payload)
  io.to_slice
end

# `show_json` is `private` (CLI-command glue, not a public API) — reopen the module to
# expose a thin bare-call wrapper for testing, same trick Crystal allows for whitebox
# specs of private `self.` methods (a bare call from within the same type is permitted;
# only an explicit-receiver call from outside is not).
module Gori::CLI::Run
  def self.show_json_for_spec(detail : Store::FlowDetail, req : Bool, resp : Bool,
                              ws_msgs : Array(Store::WsMessage) = [] of Store::WsMessage) : String
    show_json(detail, req, resp, ws_msgs)
  end
end

describe "gori run history — the QL gate" do
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

describe "gori run history — CLI::Output rows" do
  it "shows an absolute-form target as-is and prefixes an origin-form one with the host" do
    abs = Gori::CLI::Output.flow_row_text(flow_row(target: "http://e.test/a", host: "e.test", status: 200, state: Gori::Store::FlowState::Complete))
    abs.should contain("http://e.test/a")
    abs.should_not contain("e.testhttp://") # no double host

    rel = Gori::CLI::Output.flow_row_text(flow_row(target: "/a", host: "api.test", status: 200, state: Gori::Store::FlowState::Complete))
    rel.should contain("api.test/a")
  end

  # R4. `target.starts_with?("http")` is not the absolute-form test — RFC 3986 §3.1 makes a
  # URI scheme case-insensitive, and gori captures the request line the client wrote. Driven
  # live through the proxy: `GET HTTP://127.0.0.1:19594/upper HTTP/1.1` printed as
  # `127.0.0.1HTTP://127.0.0.1:19594/upper`, the doubling `FlowRow.absolute_form?` exists to
  # stop. `Gori::Url.location` is the one spelling now.
  it "does not double the authority when the captured scheme is UPPERCASE" do
    txt = Gori::CLI::Output.flow_row_text(flow_row(
      target: "HTTP://127.0.0.1:19594/upper", host: "127.0.0.1", status: 200,
      state: Gori::Store::FlowState::Complete))
    txt.should contain("HTTP://127.0.0.1:19594/upper")
    txt.should_not contain("127.0.0.1HTTP://")
  end

  # R4. `[!]` is the scannable pointer, exactly like `[stub]` beside it: a text-mode reader
  # must be able to see that gori has something to SAY about a row without opening it.
  it "chips a row gori has an advisory about, and leaves an ordinary row unmarked" do
    plain = flow_row(target: "/a", host: "h", status: 200, state: Gori::Store::FlowState::Complete)
    Gori::CLI::Output.flow_row_text(plain).should_not contain("[!]")
    noted = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "h", port: 443,
      target: "/a", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete,
      advisory: "Match&Replace was NOT applied to this request head")
    Gori::CLI::Output.flow_row_text(noted).should contain("[!]")
  end

  it "marks a pending flow with a dash status and a state tag" do
    txt = Gori::CLI::Output.flow_row_text(flow_row(target: "/p", host: "h", status: nil, state: Gori::Store::FlowState::Pending))
    txt.should contain("—")
    txt.should contain("[Pending]")
  end

  it "neutralizes terminal escape sequences in an untrusted captured target" do
    # A malicious client puts ANSI/OSC escapes in its request line; the text row must
    # not inject them into the operator's terminal (they'd be replayed on every view).
    evil = "/p\e[31m\r\n\e]0;pwned\a"
    txt = Gori::CLI::Output.flow_row_text(flow_row(target: evil, host: "h", status: 200, state: Gori::Store::FlowState::Complete))
    txt.should_not contain('\e') # no ESC
    txt.should_not contain('\r') # no CR
    txt.should_not contain('\a') # no BEL
    txt.should contain("·")      # control bytes replaced with a visible marker
  end

  it "scrubs the METHOD and SCHEME columns too, not just the target" do
    # All three come off the wire on the CLI's headless path; an escape in the method
    # would land in the operator's terminal exactly like one in the target.
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "ht\etp", method: "G\eET", host: "h", port: 80,
      target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
    txt = Gori::CLI::Output.flow_row_text(row)
    txt.should_not contain('\e')
    txt.should contain("G·ET")
  end

  it "term_safe leaves ordinary UTF-8 untouched but replaces control bytes" do
    Gori::CLI::Output.term_safe("api.test/π/데이터").should eq("api.test/π/데이터")
    Gori::CLI::Output.term_safe("a\tb\nc").should eq("a·b·c")
  end

  it "term_safe also scrubs invalid UTF-8 (not just control bytes) so JSON output stays valid" do
    # A captured host/path is raw bytes off the wire (see Sitemap.template_class's comment)
    # and can be invalid UTF-8 with NO control bytes at all — the old short-circuit
    # (`return s unless s.each_char.any?(&.control?)`) let such a value straight through
    # unchanged, since a replacement char isn't itself "control".
    bad = String.new(Bytes[0x68, 0x69, 0xff, 0x68, 0x69]) # "hi\xFFhi"
    bad.valid_encoding?.should be_false
    out = Gori::CLI::Output.term_safe(bad)
    out.valid_encoding?.should be_true
    out.should eq("hi�hi")
  end

  it "term_safe_multiline keeps newlines and tabs while still killing ANSI/OSC" do
    # This is the `show`/`repeater` TEXT view's scrubber: a captured head/body must keep
    # its layout (a head flattened to one line is unreadable) while escapes still die.
    src = "HTTP/1.1 200 OK\r\nX-A:\t1\n\e[31mred\e]0;title\a"
    out = Gori::CLI::Output.term_safe_multiline(src)
    out.should contain("\n") # line breaks survive
    out.should contain("\t") # tabs survive
    out.should_not contain('\e')
    out.should_not contain('\a')
    out.should contain('·') # the CR of the CRLF and the escapes are neutralized
  end

  it "emits a valid JSON object with the expected keys" do
    json = JSON.parse(Gori::CLI::Output.flow_row_json(flow_row(target: "/a", host: "h", status: 200, state: Gori::Store::FlowState::Complete)))
    json["id"].as_i.should eq(42)
    json["method"].as_s.should eq("GET")
    json["status"].as_i.should eq(200)
    json["state"].as_s.should eq("complete") # lowercased to match the MCP serializer
  end

  # CLI::Output is the shape `gori run history --format json`, `gori run capture`'s
  # JSON-Lines stream, and the MCP list_history tool all mirror. A field added to one
  # serializer and not the other is a silent three-surface drift, and nothing else in the
  # tree compares them. The ONE remaining difference is the CLI's extra human `time`.
  #
  # This used to subtract `time` from one side and `created_at_iso` from the other and assert
  # neither carried both, which made the pin PASS while the two surfaces rendered the same
  # instant as different strings — `time` is local at second precision, `created_at_iso` is
  # UTC at millisecond. The keys matched and the values could not be compared. Now the CLI
  # carries both and the shared key is asserted on VALUE, not just presence.
  it "keeps the flow-row JSON keys in lockstep with the MCP serializer" do
    row = flow_row(target: "/a", host: "h", status: 200, state: Gori::Store::FlowState::Complete)
    cli = JSON.parse(Gori::CLI::Output.flow_row_json(row)).as_h.keys
    mcp = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.flow_row(j, row) }).as_h.keys

    # Sorted: the point is a missing/extra FIELD, not the emission order.
    (cli - ["time"]).sort!.should eq(mcp.sort!)
    cli.should contain("time")           # the CLI's extra, human-facing, local
    cli.should contain("created_at_iso") # …alongside the machine-readable one MCP names
  end

  # The half the key-set pin cannot see. `Output.iso_time_utc` is a reimplementation of
  # `Serialize.unix_micros_iso` (CLI::Output deliberately takes no dependency on MCP::), so
  # nothing but this assertion stops the two from drifting.
  it "renders created_at_iso byte-for-byte the same as the MCP serializer" do
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 1_700_000_000_123_456_i64, scheme: "https", method: "GET",
      host: "h", port: 443, target: "/a", status: 200, size: 0_i64,
      state: Gori::Store::FlowState::Complete)
    cli = JSON.parse(Gori::CLI::Output.flow_row_json(row))
    mcp = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.flow_row(j, row) })
    cli["created_at_iso"].as_s.should eq(mcp["created_at_iso"].as_s)
    # UTC, milliseconds, Z — and the sub-second micros `time` drops are kept here.
    cli["created_at_iso"].as_s.should eq("2023-11-14T22:13:20.123Z")
    Gori::CLI::Output.iso_time_utc(1_700_000_000_123_456_i64)
      .should eq(Gori::MCP::Serialize.unix_micros_iso(1_700_000_000_123_456_i64))
  end

  # The class this round closed: `JSON::Builder#string` escapes JSON metacharacters but writes
  # raw bytes through, so ONE non-UTF-8 byte in a captured field makes the whole document
  # unparseable to a strict reader (python's json.loads raises UnicodeDecodeError) — and in the
  # JSON-Lines stream, every later line with it. Proven reachable end-to-end: `flows.host` /
  # `flows.target` round-trip such a byte through SQLite unchanged.
  it "emits valid UTF-8 for a captured target and host holding a non-UTF-8 byte" do
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET",
      host: String.new(Bytes[104, 255, 120]), port: 443,
      target: String.new(Bytes[47, 97, 255, 98]), status: 200, size: 0_i64,
      state: Gori::Store::FlowState::Complete,
      content_type: String.new(Bytes[116, 255]))
    json = Gori::CLI::Output.flow_row_json(row)
    json.valid_encoding?.should be_true
    parsed = JSON.parse(json)
    parsed["target"].as_s.should eq("/a�b")
    parsed["host"].as_s.should eq("h�x")
    parsed["content_type"].as_s.should eq("t�")
    # …and the MCP row for the same flow was already clean, which is what made this a drift.
    JSON.build { |j| Gori::MCP::Serialize.flow_row(j, row) }.valid_encoding?.should be_true
  end

  it "emits valid UTF-8 for a fuzz row whose extract captured non-UTF-8 response bytes" do
    bad = String.new(Bytes[115, 61, 255, 254])
    r = Gori::Fuzz::Result.new(0_i64, ["p"], 0, 200, 10_i64, 2, 1, 100_i64, nil, true, false, bad)
    Gori::CLI::Output.fuzz_row_json(r).valid_encoding?.should be_true
    JSON.parse(Gori::CLI::Output.fuzz_row_json(r))["extracted"].as_s.should eq("s=��")

    # …and the same for `error`, the sibling field the `payloads` fix did not cover.
    e = Gori::Fuzz::Result.new(1_i64, ["p"], 0, nil, 0_i64, 0, 0, 5_i64, bad, false, false, nil)
    Gori::CLI::Output.fuzz_row_json(e).valid_encoding?.should be_true
  end

  it "emits valid UTF-8 for a discover finding and a sequencer sample" do
    bad = String.new(Bytes[47, 255])
    f = Gori::Discover::Finding.new(
      url: "http://h/#{bad}", method: "GET", status: 200, length: 1_i64,
      content_type: bad, source: Gori::Discover::Source::Crawled, depth: 0,
      confidence: 1.0, note: nil)
    Gori::CLI::Output.discover_row_json(f).valid_encoding?.should be_true

    s = Gori::Sequencer::Sample.new(
      index: 0, token: bad, status: 200, length: 2, duration_us: 1_i64, error: nil)
    Gori::CLI::Output.sequence_sample_json(s).valid_encoding?.should be_true
    JSON.parse(Gori::CLI::Output.sequence_sample_json(s))["token"].as_s.should eq("/�")
  end

  # The same lockstep for the field this round added, since a conditional field is exactly
  # the kind that gets added to one serializer and forgotten in the other.
  it "keeps `advisory` in lockstep too, and omits it on an ordinary row" do
    noted = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "h", port: 443,
      target: "/a", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete,
      advisory: "line one\nline two")
    cli = JSON.parse(Gori::CLI::Output.flow_row_json(noted))
    mcp = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.flow_row(j, noted) })
    cli["advisory"].as_a.map(&.as_s).should eq(["line one", "line two"])
    mcp["advisory"].as_a.map(&.as_s).should eq(["line one", "line two"])

    plain = flow_row(target: "/a", host: "h", status: 200, state: Gori::Store::FlowState::Complete)
    JSON.parse(Gori::CLI::Output.flow_row_json(plain)).as_h.has_key?("advisory").should be_false
    JSON.parse(JSON.build { |j| Gori::MCP::Serialize.flow_row(j, plain) }).as_h.has_key?("advisory").should be_false
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

  it "rolls human_us over to seconds" do
    Gori::CLI::Output.human_us(1_000_000_i64).should eq("1.0s")
    # Both formatters share ONE rounding edge, and it is deliberate: the tier check runs
    # before round1, so a value just under a boundary prints as the rounded boundary.
    # Pinned here so it reads as a known edge rather than a formatter bug.
    Gori::CLI::Output.human_us(999_999_i64).should eq("1000.0ms")
    Gori::CLI::Output.human_size(1_048_575_i64).should eq("1024.0kB")
  end
end

describe "gori run show --format json" do
  it "nests the flow row under `flow` and carries the http version + error" do
    detail = flow_detail("https", "x", 443, "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
      response_head: "HTTP/1.1 200 OK\r\n\r\n", response_body: "hi", http_version: "HTTP/2")
    json = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, true))
    json["flow"]["id"].as_i.should eq(7)
    json["flow"]["state"].as_s.should eq("complete")
    json["http_version"].as_s.should eq("HTTP/2")
    json["error"].raw.should be_nil
    json["request"]["head"].as_s.should contain("GET /")
    json["response"]["head"].as_s.should contain("200 OK")
  end

  it "omits the side the --request-only / --response-only flags exclude" do
    # --request-only must not leak a response-side token into the document; the flags are
    # the only thing standing between a redacted export and the whole flow.
    detail = flow_detail("https", "x", 443, "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
      response_head: "HTTP/1.1 200 OK\r\n\r\n", response_body: "secret")
    req_only = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, false)).as_h
    req_only.has_key?("request").should be_true
    req_only.has_key?("response").should be_false

    resp_only = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, false, true)).as_h
    resp_only.has_key?("request").should be_false
    resp_only.has_key?("response").should be_true
  end

  # Regression for the `sse_events.truncated` field: it used to be hardcoded `false`
  # regardless of how many events were parsed, while the MCP `get_flow` serializer
  # computed it from `events.size > SSE_EVENTS_MAX`. The two must agree.
  it "reports sse_events.truncated as false at or under the cap" do
    body = String.build { |io| 3.times { |i| io << "data: e#{i}\n\n" } }
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
    detail = flow_detail("http", "x", 80, "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
      response_head: head, response_body: body)
    sse = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, true))["sse_events"]
    sse["count"].as_i.should eq(3)
    sse["truncated"].as_bool.should be_false
  end

  it "reports sse_events.truncated once past SSE_EVENTS_MAX, matching the MCP serializer" do
    n = Gori::MCP::Serialize::SSE_EVENTS_MAX + 1
    body = String.build { |io| n.times { |i| io << "data: e#{i}\n\n" } }
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
    detail = flow_detail("http", "x", 80, "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
      response_head: head, response_body: body)
    sse = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, true))["sse_events"]
    sse["count"].as_i.should eq(n)
    sse["truncated"].as_bool.should be_true
    # the CLI path stays unclipped (a script can read whole values) — unlike MCP, it
    # does NOT drop events past the cap; `truncated` is a signal, not a clip.
    sse["events"].as_a.size.should eq(n)
  end

  it "emits ws_messages with base64 for a binary frame and text for a text frame" do
    detail = flow_detail("https", "ws.test", 443, "GET /ws HTTP/1.1\r\nHost: ws.test\r\n\r\n",
      response_head: "HTTP/1.1 101 Switching Protocols\r\n\r\n")
    msgs = [
      Gori::Store::WsMessage.new(1_i64, 7_i64, nil, 0_i64, "out", 1, "hello".to_slice),
      Gori::Store::WsMessage.new(2_i64, 7_i64, nil, 0_i64, "in", 2, Bytes[0x00, 0xFF]),
    ]
    ws = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, true, msgs))["ws_messages"]
    ws["count"].as_i.should eq(2)
    entries = ws["messages"].as_a
    entries[0]["text"].as_s.should eq("hello")
    entries[0]["direction"].as_s.should eq("out")
    entries[1]["binary"].as_bool.should be_true
    entries[1]["size"].as_i.should eq(2)
    Base64.decode(entries[1]["base64"].as_s).should eq(Bytes[0x00, 0xFF])
  end

  # gRPC + schema-less protobuf: `request/response.grpc_messages` carries the
  # framed messages and each uncompressed non-trailer payload's protobuf tree.
  describe "grpc_messages" do
    it "decodes a unary gRPC request/response into protobuf field trees" do
      # protobuf field 1 = "alice" / field 1 = "Hello, alice"
      hello = Bytes[0x0a, 0x05, 0x61, 0x6c, 0x69, 0x63, 0x65]
      # "Hello, alice" is 12 bytes
      reply = Bytes[0x0a, 0x0c, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x61, 0x6c, 0x69, 0x63, 0x65]
      req_body = grpc_frame_for_spec(hello)
      resp_body = grpc_frame_for_spec(reply)

      req_head = "POST /demo.Greeter/SayHello HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"
      resp_head = "HTTP/2 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\n\r\n"
      row = Gori::Store::FlowRow.new(
        id: 7_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "api.test", port: 443,
        target: "/demo.Greeter/SayHello", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete,
        content_type: "application/grpc")
      detail = Gori::Store::FlowDetail.new(row, "HTTP/2", req_head.to_slice, req_body,
        resp_head.to_slice, resp_body)

      json = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, true))
      req_msgs = json["request"]["grpc_messages"]
      req_msgs["count"].as_i.should eq(1)
      m0 = req_msgs["messages"].as_a[0]
      m0["compressed"].as_bool.should be_false
      m0["trailer"].as_bool.should be_false
      m0["protobuf"]["complete"].as_bool.should be_true
      m0["protobuf"]["fields"].as_a[0]["string"].as_s.should eq("alice")

      resp_msgs = json["response"]["grpc_messages"]
      resp_msgs["messages"].as_a[0]["protobuf"]["fields"].as_a[0]["string"].as_s.should eq("Hello, alice")
    end

    it "does not feed a compressed gRPC payload to the protobuf decoder" do
      body = grpc_frame_for_spec(Bytes[0xab, 0xcd], flag: 0x01_u8)
      req_head = "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"
      row = Gori::Store::FlowRow.new(
        id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "api.test", port: 443,
        target: "/S/M", status: nil, size: 0_i64, state: Gori::Store::FlowState::Pending)
      detail = Gori::Store::FlowDetail.new(row, "HTTP/2", req_head.to_slice, body, nil, nil)
      json = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, false))
      m = json["request"]["grpc_messages"]["messages"].as_a[0]
      m["compressed"].as_bool.should be_true
      m["protobuf"]?.should be_nil
      m["note"].as_s.should contain("compressed")
      Base64.decode(m["bytes"].as_s).should eq(Bytes[0xab, 0xcd])
    end

    it "parses a grpc-web trailer frame as headers, not protobuf" do
      trailer_payload = "grpc-status: 5\r\ngrpc-message: not found\r\n"
      body = grpc_frame_for_spec(trailer_payload.to_slice, flag: 0x80_u8)
      resp_head = "HTTP/2 200 OK\r\ncontent-type: application/grpc-web+proto\r\n\r\n"
      row = Gori::Store::FlowRow.new(
        id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "api.test", port: 443,
        target: "/S/M", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
      detail = Gori::Store::FlowDetail.new(row, "HTTP/2",
        "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc-web+proto\r\n\r\n".to_slice, nil,
        resp_head.to_slice, body)
      json = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, false, true))
      m = json["response"]["grpc_messages"]["messages"].as_a[0]
      m["trailer"].as_bool.should be_true
      m["protobuf"]?.should be_nil
      m["headers"]["grpc-status"].as_s.should eq("5")
      m["headers"]["grpc-message"].as_s.should eq("not found")
    end

    # A length prefix that lies about the payload size is one of the standard gRPC parser
    # tests. The guard used to be `msgs.empty?`, so the whole object vanished — which reads
    # identically to "this flow is not gRPC", and the operator concludes the probe was never
    # framed as gRPC at all.
    it "reports a lying length prefix as a framing error instead of omitting the object" do
      body = Bytes[0x00, 0x00, 0x00, 0x00, 0x63, 0x0a, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f] # claims 99, has 7
      head = "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"
      row = Gori::Store::FlowRow.new(
        id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "api.test", port: 443,
        target: "/S/M", status: nil, size: 0_i64, state: Gori::Store::FlowState::Pending)
      detail = Gori::Store::FlowDetail.new(row, "HTTP/2", head.to_slice, body, nil, nil)
      msgs = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, false))["request"]["grpc_messages"]
      msgs["count"].as_i.should eq(0)
      msgs["residual_bytes"].as_i.should eq(12)
      msgs["framing_error"].as_s.should contain("not a complete gRPC frame")
    end

    # A clean message followed by a truncated one: the good message must still decode AND the
    # leftover must be counted, not dropped without trace.
    it "counts the residual bytes of a trailing partial frame" do
      good = grpc_frame_for_spec(Bytes[0x0a, 0x02, 0x68, 0x69])
      partial = Bytes[0x00, 0x00, 0x00, 0x00, 0x09, 0x61, 0x62] # claims 9, has 2
      body = Bytes.new(good.size + partial.size)
      good.copy_to(body)
      partial.copy_to(body + good.size)
      head = "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"
      row = Gori::Store::FlowRow.new(
        id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "api.test", port: 443,
        target: "/S/M", status: nil, size: 0_i64, state: Gori::Store::FlowState::Pending)
      detail = Gori::Store::FlowDetail.new(row, "HTTP/2", head.to_slice, body, nil, nil)
      msgs = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, false))["request"]["grpc_messages"]
      msgs["count"].as_i.should eq(1)
      msgs["residual_bytes"].as_i.should eq(7)
    end

    # The complement, pinned so the residual field never becomes noise on a healthy body.
    it "omits residual_bytes when the body frames cleanly" do
      body = grpc_frame_for_spec(Bytes[0x0a, 0x02, 0x68, 0x69])
      head = "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"
      row = Gori::Store::FlowRow.new(
        id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "api.test", port: 443,
        target: "/S/M", status: nil, size: 0_i64, state: Gori::Store::FlowState::Pending)
      detail = Gori::Store::FlowDetail.new(row, "HTTP/2", head.to_slice, body, nil, nil)
      msgs = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, false))["request"]["grpc_messages"].as_h
      msgs.has_key?("residual_bytes").should be_false
      msgs.has_key?("framing_error").should be_false
    end

    it "omits grpc_messages on a non-gRPC flow" do
      detail = flow_detail("https", "x", 443, "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        response_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        response_body: %({"a":1}))
      json = JSON.parse(Gori::CLI::Run.show_json_for_spec(detail, true, true)).as_h
      json["request"].as_h.has_key?("grpc_messages").should be_false
      json["response"].as_h.has_key?("grpc_messages").should be_false
    end
  end
end

# --- `gori run history --format json/jsonl`'s listing extras, and `history delete` ----------
#
# The private glue below is reached the same whitebox way `show_json_for_spec` is: a bare call
# from inside the module, which Crystal permits where an explicit-receiver call from outside
# would not.
module Gori::CLI::Run
  def self.curl_command_for_spec(detail : Store::FlowDetail) : String?
    curl_command_for(detail)
  end

  def self.delete_selector_error_for_spec(positional : Array(String), query : String?) : String?
    delete_selector_error(positional, query)
  end

  def self.delete_confirmation_error_for_spec(q : String, count : Int32, yes : Bool) : String?
    delete_confirmation_error(q, count, yes)
  end

  def self.delete_query_error_for_spec(q : String) : String?
    delete_query_error(q)
  end

  def self.delete_scope_error_for_spec(q : String, lens : QL::ScopeLens) : String?
    delete_scope_error(q, lens)
  end

  def self.matching_flow_ids_for_spec(store : Store, filter : QL::Filter) : Array(Int64)
    matching_flow_ids(store, filter)
  end

  def self.fts_backlog_error_for_spec(store : Store, filter : QL::Filter,
                                      consequence : String) : String?
    fts_backlog_error(store, filter, consequence)
  end
end

private def history_store(&)
  path = File.tempname("gori-history-delete", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def captured(host : String, target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
end

describe "gori run history --format json — the listing's url and headers" do
  # The two fields exist because the metadata-only row could not answer "what request was
  # this?": a script had to re-derive the URL from four columns (getting the default-port and
  # IPv6 cases wrong) and could not see a single header at all.
  head = ("POST /login?next=/home HTTP/1.1\r\nHost: accounts.test\r\n" \
          "Content-Type: application/json\r\nCookie: a=1\r\nCookie: b=2\r\n\r\n").to_slice

  it "adds the absolute url and a compact request-header object when the head is supplied" do
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "accounts.test",
      port: 443, target: "/login?next=/home", status: 200, size: 0_i64,
      state: Gori::Store::FlowState::Complete)
    json = JSON.parse(Gori::CLI::Output.flow_row_json(row, head))
    json["url"].as_s.should eq("https://accounts.test/login?next=/home")
    json["headers"]["Host"].as_s.should eq("accounts.test")
    json["headers"]["Content-Type"].as_s.should eq("application/json")
  end

  it "keeps a repeated header name as an ARRAY rather than collapsing it to last-wins" do
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "accounts.test",
      port: 443, target: "/login", status: 200, size: 0_i64,
      state: Gori::Store::FlowState::Complete)
    json = JSON.parse(Gori::CLI::Output.flow_row_json(row, head))
    json["headers"]["Cookie"].as_a.map(&.as_s).should eq(["a=1", "b=2"])
  end

  # `FlowRow#url` is the one definition; these are the two cases a script re-deriving it
  # from scheme/host/port/target gets wrong.
  it "carries a non-default port and passes an absolute-form target through untouched" do
    ported = Gori::Store::FlowRow.new(
      id: 2_i64, created_at: 0_i64, scheme: "http", method: "GET", host: "acme.test",
      port: 8080, target: "/a", status: 404, size: 0_i64,
      state: Gori::Store::FlowState::Complete)
    JSON.parse(Gori::CLI::Output.flow_row_json(ported, "GET /a HTTP/1.1\r\n\r\n".to_slice))["url"]
      .as_s.should eq("http://acme.test:8080/a")

    absolute = Gori::Store::FlowRow.new(
      id: 3_i64, created_at: 0_i64, scheme: "http", method: "GET", host: "plain.test",
      port: 80, target: "http://plain.test/x", status: 200, size: 0_i64,
      state: Gori::Store::FlowState::Complete)
    JSON.parse(Gori::CLI::Output.flow_row_json(absolute, "GET http://plain.test/x HTTP/1.1\r\n\r\n".to_slice))["url"]
      .as_s.should eq("http://plain.test/x")
  end

  # The listing extras are OPT-IN precisely so the shape `gori run capture`'s live JSON-Lines
  # stream and MCP's `list_history` mirror is untouched — the key-set pin above depends on it.
  it "emits neither field when no request head is supplied" do
    row = flow_row(target: "/a", host: "h", status: 200, state: Gori::Store::FlowState::Complete)
    keys = JSON.parse(Gori::CLI::Output.flow_row_json(row)).as_h.keys
    keys.should_not contain("url")
    keys.should_not contain("headers")
  end
end

describe "gori run show --format curl" do
  it "builds the command from the stored head AND body, through the shared serializer" do
    head = "POST /api/login HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\n" \
           "Content-Length: 14\r\n\r\n"
    row = Gori::Store::FlowRow.new(
      id: 9_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "example.com",
      port: 443, target: "/api/login", status: 200, size: 0_i64,
      state: Gori::Store::FlowState::Complete)
    detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", head.to_slice, %({"user":"neo"}).to_slice, nil, nil)
    cmd = Gori::CLI::Run.curl_command_for_spec(detail).not_nil!
    cmd.should contain("curl 'https://example.com/api/login'")
    cmd.should contain("-X 'POST'")
    cmd.should contain(%q(--data-raw '{"user":"neo"}'))
    cmd.should_not contain("Content-Length")
  end

  # The URL comes from the flow's OWN scheme/host/port, not from the Host header — a capture
  # on a non-default port would otherwise produce a command aimed at the wrong socket.
  it "targets the flow's scheme and non-default port" do
    row = Gori::Store::FlowRow.new(
      id: 10_i64, created_at: 0_i64, scheme: "http", method: "GET", host: "acme.test",
      port: 8080, target: "/a", status: 404, size: 0_i64,
      state: Gori::Store::FlowState::Complete)
    detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", "GET /a HTTP/1.1\r\nHost: acme.test:8080\r\n\r\n".to_slice,
      nil, nil, nil)
    Gori::CLI::Run.curl_command_for_spec(detail).not_nil!.should contain("curl 'http://acme.test:8080/a'")
  end
end

describe "gori run history delete — the selector" do
  it "refuses an empty selector rather than reading it as `every flow`" do
    err = Gori::CLI::Run.delete_selector_error_for_spec([] of String, nil).not_nil!
    err.should contain("nothing selected")
    err.should contain("history clear --yes")
  end

  it "refuses an id and a query together — the two disagree about scope" do
    Gori::CLI::Run.delete_selector_error_for_spec(["1"], "host:a").not_nil!.should contain("not both")
  end

  it "accepts exactly one of the two" do
    Gori::CLI::Run.delete_selector_error_for_spec(["1"], nil).should be_nil
    Gori::CLI::Run.delete_selector_error_for_spec([] of String, "host:a").should be_nil
  end
end

describe "gori run history delete -q — the refusals" do
  it "refuses without --yes and puts the COUNT in the sentence" do
    err = Gori::CLI::Run.delete_confirmation_error_for_spec("host:a", 12, false).not_nil!
    err.should contain("12 flows")
    err.should contain("--yes")
    Gori::CLI::Run.delete_confirmation_error_for_spec("host:a", 12, true).should be_nil
  end

  # The one this whole gate exists for. QL free-texts a field it does not know, so `methd:GET`
  # compiles CLEAN (nothing in `QL.analyze` reports it) and the delete quietly matches nothing
  # — exiting 0 against a query the operator believes they ran.
  it "aborts on an unrecognized field instead of silently deleting nothing" do
    err = Gori::CLI::Run.delete_query_error_for_spec("methd:GET").not_nil!
    err.should contain("unknown field")
    err.should contain("`methd:`")
    Gori::QL.analyze("methd:GET").ignored.should be_empty # …which is why `analyze` alone is not enough
  end

  it "aborts on a `req.`/`resp.` prefixed field QL does not implement" do
    Gori::CLI::Run.delete_query_error_for_spec("resp.status:200").not_nil!.should contain("unknown field")
  end

  it "aborts on a query that folds to match-all, which would take the whole project" do
    err = Gori::CLI::Run.delete_query_error_for_spec("status:>=foo").not_nil!
    err.should contain("EVERY flow")
    Gori::CLI::Run.delete_query_error_for_spec("   ").not_nil!.should contain("empty -q query")
  end

  it "aborts on an invalid regex, which compiles to a never-match clause" do
    Gori::CLI::Run.delete_query_error_for_spec("host~[").not_nil!.should contain("invalid regex")
  end

  it "lets an ordinary query through" do
    Gori::CLI::Run.delete_query_error_for_spec("host:accounts.google.com").should be_nil
    Gori::CLI::Run.delete_query_error_for_spec("status:>=500 -method:GET").should be_nil
  end

  # The two states a `scope:` query is silently empty in. Pinned as text because the fix differs
  # per state (add scope rules; drop one of the two lenses) and the TUI carries the same pair.
  it "notes the two states a scope: query comes back empty in" do
    none = Gori::QL::ScopeLens.new(nil)
    configured = Gori::QL::ScopeLens.new(Gori::QL::Filter.new("(1)", [] of DB::Any))
    Gori::CLI::Run.scope_query_notes("scope:in", none).join(" ").should contain("no scope rules are configured")
    Gori::CLI::Run.scope_query_notes("scope:in", configured).should be_empty
    # Says what COMPOSES, not which spelling empties: `--in-scope` narrows flows on `history` and
    # whole HOSTS on `sitemap`/`probe`, and it is the un-negated `scope:out` that goes empty.
    Gori::CLI::Run.scope_query_notes("scope:out", configured, in_scope: true)
      .join(" ").should contain("already narrowing to what is in scope")
    # Both at once, and neither for a query that never asked — including `scope~in`, which QL
    # free-texts (so it names no scope term at all).
    Gori::CLI::Run.scope_query_notes("scope:out", none, in_scope: true).size.should eq(2)
    Gori::CLI::Run.scope_query_notes("host:acme", none, in_scope: true).should be_empty
    Gori::CLI::Run.scope_query_notes("scope~in", none, in_scope: true).should be_empty
  end

  # `scope:` on a project with no scope rules. `scope:out` compiles to a never-match, so the
  # positive spelling would delete nothing — but a NEGATED one is that never-match inverted, i.e.
  # every flow, and it clears every other guard here: the match-all test compares the compiled
  # SQL against `1`, and `NOT (0)` is not that string.
  it "aborts a scope query on a project that has no scope rules" do
    none = Gori::QL::ScopeLens.new(nil)
    err = Gori::CLI::Run.delete_scope_error_for_spec("-scope:in", none).not_nil!
    err.should contain("NO scope rules")
    err.should contain("NEGATED")
    Gori::CLI::Run.delete_scope_error_for_spec("scope:out", none).should_not be_nil
    # The guard it is NOT: the pre-store checks read the query's SHAPE under a lens that has no
    # rules, and `NOT (0)` is a real clause under it — so they pass this, and must, or a scope
    # query would be refused on every project including the ones that can answer it.
    Gori::CLI::Run.delete_query_error_for_spec("-scope:in").should be_nil
    Gori::CLI::Run.delete_query_error_for_spec("scope:in").should be_nil
    Gori::CLI::Run.delete_query_error_for_spec("host:acme scope:in").should be_nil
    Gori::QL.parse("-scope:in", scope: none).sql.should eq("(NOT (0))") # …which is every flow

    # With rules configured the term answers, and the delete proceeds like any other query.
    configured = Gori::QL::ScopeLens.new(Gori::QL::Filter.new("(1)", [] of DB::Any))
    Gori::CLI::Run.delete_scope_error_for_spec("-scope:in", configured).should be_nil
    Gori::CLI::Run.delete_scope_error_for_spec("host:acme", none).should be_nil
  end
end

describe "gori run history delete -q --yes" do
  it "names every match, not just the first page, and deletes exactly those" do
    history_store do |store|
      # More than one DELETE_BATCH page of matches, so the cursor walk is exercised rather
      # than a single LIMIT that happened to cover the set.
      600.times { store.insert_flow(captured("accounts.google.com", "/a")) }
      3.times { store.insert_flow(captured("acme.test", "/b")) }
      store.flush

      ids = Gori::CLI::Run.matching_flow_ids_for_spec(store, Gori::QL.parse("host:accounts.google.com"))
      ids.size.should eq(600)
      store.delete_flows(ids).should be_true
      store.flush

      remaining = store.recent_flows(100)
      remaining.size.should eq(3)
      remaining.map(&.host).uniq!.should eq(["acme.test"])
    end
  end

  it "names nothing when nothing matches" do
    history_store do |store|
      store.insert_flow(captured("acme.test", "/b"))
      store.flush
      Gori::CLI::Run.matching_flow_ids_for_spec(store, Gori::QL.parse("host:nope.test")).should be_empty
    end
  end
end

# The guard behind three aborts: `history` (listing), `history delete -q`, and — same `Run`
# module — `sitemap`. Spec'd at the helper, the way every other refusal in this file is
# (`delete_query_error`, `delete_confirmation_error`): the abort itself is `exit`, which a
# spec process cannot survive, and the helper holds the whole decision.
#
# `index_pending!` reports a batch that lost SQLite's single writer slot to a capturing peer as
# "0 indexed" and takes its `break if n == 0` there (Store#index_pending!), so it returns
# NORMALLY with rows still dirty. Every caller read that as success: the listing printed a short
# match set with no marker on it, and the DELETE spared flows the operator had asked to remove
# while printing a count for the ones it did take.
private def contended_history_store(&)
  path = File.tempname("gori-history-fts", ".db")
  url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=1" # the real 5 s wait is what this skips
  db = DB.open(url)
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  # Without this the idle indexer drains the backlog within one FAST tick (5 ms), before the peer
  # lock can be taken — the order these examples need is unreachable with it running. A real
  # product state (#752: a view-only Session that lost the capture lock pauses it); explicit
  # `index_pending!` is an op on the write channel and still runs, which is what is under test.
  store.pause_background_index
  peer = DB.open(url)
  begin
    yield store, peer
  ensure
    done = Channel(Nil).new(1)
    spawn do
      store.close
      done.send(nil)
    end
    select
    when done.receive
      # closed cleanly
    when timeout(20.seconds)
      # a wedged writer must fail the example, never hang the run
    end
    peer.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Holds the WAL write lock the way a peer gori's writer would.
private def while_history_peer_writes(peer : DB::Database, &)
  lock = peer.checkout
  lock.exec("BEGIN IMMEDIATE")
  begin
    yield
  ensure
    lock.exec("ROLLBACK") rescue nil
    lock.release rescue nil
  end
end

# A flow whose RESPONSE body carries `needle` (≥3 chars → the trigram path in QL's `body_cond`,
# not the `instr` fallback), left DIRTY: nothing flushes and the idle indexer is paused.
private def seed_dirty_body_flow(store, needle : String) : Int64
  id = store.insert_flow(captured("acme.test", "/login"))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
    body: "<p>#{needle}</p>".to_slice, reason: "OK", content_type: "text/html", duration_us: 1_i64))
  id
end

describe "gori run history / sitemap — the FTS drain that did not finish" do
  it "refuses a body: query when the drain lost the writer slot, naming the count and the consequence" do
    contended_history_store do |store, peer|
      seed_dirty_body_flow(store, "needleone")
      store.fts_backlog.should be > 0 # the drain has real work to fail at

      err = nil.as(String?)
      while_history_peer_writes(peer) do
        err = Gori::CLI::Run.fts_backlog_error_for_spec(store, Gori::QL.parse("body:needleone"),
          "\"body:needleone\" would silently omit them. Nothing was listed;")
      end

      msg = err.not_nil!
      msg.should contain("1 flow could not be indexed")
      msg.should contain("writer is busy")
      msg.should contain("Nothing was listed")
      msg.should contain("Retry in a moment")
      # The rows are still there and still dirty: this refused, it did not lose anything.
      store.fts_backlog.should be > 0
    end
  end

  # The delete's own consequence clause, because under-deleting is the failure this command
  # cannot have: it printed "Deleted 3 flows" for a query whose match set it could not see.
  it "carries the caller's own consequence — a delete spares flows, a listing omits rows" do
    contended_history_store do |store, peer|
      seed_dirty_body_flow(store, "needletwo")
      err = nil.as(String?)
      while_history_peer_writes(peer) do
        err = Gori::CLI::Run.fts_backlog_error_for_spec(store, Gori::QL.parse("body:needletwo"),
          "\"body:needletwo\" cannot see all of them and this delete would silently spare some. " \
          "NOTHING was deleted;")
      end
      err.not_nil!.should contain("NOTHING was deleted")
    end
  end

  # The complement, and the reason the guard is not unconditional: with nothing holding the
  # writer the drain finishes, and the same filter is cleared to run.
  it "clears a body: query once the drain actually completes" do
    contended_history_store do |store, _peer|
      seed_dirty_body_flow(store, "needlethree")
      Gori::CLI::Run.fts_backlog_error_for_spec(store, Gori::QL.parse("body:needlethree"),
        "anything;").should be_nil
      store.fts_backlog.should eq(0) # it drained here — not a pre-indexed pass
    end
  end

  # A filter that never reads `flows_fts` must not be refused by, or pay for, a backlog it does
  # not depend on.
  it "leaves a non-FTS filter alone while the backlog is stuck" do
    contended_history_store do |store, peer|
      seed_dirty_body_flow(store, "needlefour")
      while_history_peer_writes(peer) do
        Gori::CLI::Run.fts_backlog_error_for_spec(store, Gori::QL.parse("host:acme.test"),
          "anything;").should be_nil
      end
    end
  end
end
