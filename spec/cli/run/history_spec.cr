require "../../spec_helper"
require "base64"
require "json"

# `gori run history` / `gori run show` — the QL gate on the listing, the flow-row text and
# JSON contract in CLI::Output, and the `show --format json` document. Split out of the
# monolithic spec/cli_run_spec.cr so each subcommand mirrors src/gori/cli/run/.

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
  # tree compares them. The ONE deliberate difference is the timestamp field name.
  it "keeps the flow-row JSON keys in lockstep with the MCP serializer" do
    row = flow_row(target: "/a", host: "h", status: 200, state: Gori::Store::FlowState::Complete)
    cli = JSON.parse(Gori::CLI::Output.flow_row_json(row)).as_h.keys
    mcp = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.flow_row(j, row) }).as_h.keys

    # Sorted: the point is a missing/extra FIELD, not the emission order.
    (cli - ["time"]).sort!.should eq((mcp - ["created_at_iso"]).sort!)
    cli.should contain("time")               # CLI names it `time`
    mcp.should contain("created_at_iso")     # MCP names it `created_at_iso`
    cli.should_not contain("created_at_iso") # …and neither carries both
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
