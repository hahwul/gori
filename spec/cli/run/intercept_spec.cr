require "../../spec_helper"

# `gori run intercept edit --raw-file` is this subcommand's only byte-exact channel (there is
# no `--raw-base64` here, and argv cannot carry a NUL). Its own help promised the bytes are
# forwarded VERBATIM, but the whole message was CRLF-normalized — head AND body — so an
# operator's `alpha\rbeta\ngamma` reached the origin a byte longer with its bare LF promoted,
# under a Content-Length gori then recomputed over the corrupted body.
#
# Every other edit path on this branch is head-only (`Env.expand_wire` locates
# `head_body_boundary` first; the TUI's `intercept_view` does the same). The CLI is the one
# surface that never got the split.
describe "Gori::CLI::Run.normalize_head_crlf" do
  it "CRLF-terminates header lines and leaves the BODY byte-exact" do
    raw = "POST /held HTTP/1.1\nHost: h\nContent-Length: 5\n\nalpha\rbeta\ngamma".to_slice
    String.new(Gori::CLI::Run.normalize_head_crlf(raw))
      .should eq("POST /held HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nalpha\rbeta\ngamma")
  end

  it "is a no-op on a message whose head is already CRLF" do
    raw = "POST /held HTTP/1.1\r\nHost: h\r\nContent-Length: 16\r\n\r\nalpha\rbeta\ngamma".to_slice
    Gori::CLI::Run.normalize_head_crlf(raw).should eq(raw)
  end

  it "leaves a binary body untouched, including CR/LF/NUL bytes" do
    body = Bytes[0x0A, 0x00, 0x0D, 0xFF, 0x0A]
    raw = "POST /b HTTP/1.1\r\n\r\n".to_slice + body
    out = Gori::CLI::Run.normalize_head_crlf(raw)
    out[("POST /b HTTP/1.1\r\n\r\n".bytesize)..].to_a.should eq(body.to_a)
  end

  it "normalizes a head with no body at all" do
    String.new(Gori::CLI::Run.normalize_head_crlf("GET / HTTP/1.1\nHost: h\n\n".to_slice))
      .should eq("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
  end
end

# MCP has carried `intercept_forward_edit{update_content_length}` since the desync switch was
# made a declared argument; the CLI resynced unconditionally, so the whole CL-desync probe
# class (CL shorter than the body, CL longer than the body, CL alongside Transfer-Encoding —
# the RFC 9113 §8.1.1 shape) was unreachable from `gori run intercept edit`, even though the
# gate on the other end already honours a value the caller declared. `--raw-file` advertised
# itself as the byte-exact channel while being the one path that could not hold a length.
describe "Gori::CLI::Run.intercept_edit_bytes" do
  it "resyncs Content-Length to the edited body by default" do
    raw = "POST /h HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nlonger-body"
    String.new(Gori::CLI::Run.intercept_edit_bytes(raw, true))
      .should eq("POST /h HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\nlonger-body")
  end

  it "forwards a DELIBERATELY short Content-Length untouched with the resync off" do
    raw = "POST /h HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nlonger-body"
    String.new(Gori::CLI::Run.intercept_edit_bytes(raw, false)).should eq(raw)
  end

  it "keeps Content-Length ALONGSIDE Transfer-Encoding — the CL.TE smuggling pair" do
    raw = "POST /h HTTP/1.1\r\nHost: h\r\nContent-Length: 6\r\n" \
          "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    String.new(Gori::CLI::Run.intercept_edit_bytes(raw, false)).should eq(raw)
  end

  it "still CRLF-terminates the head with the resync off, and adds no Content-Length" do
    raw = "POST /h HTTP/1.1\nHost: h\n\nalpha\ngamma"
    String.new(Gori::CLI::Run.intercept_edit_bytes(raw, false))
      .should eq("POST /h HTTP/1.1\r\nHost: h\r\n\r\nalpha\ngamma")
  end
end

# R9/F1 — a held WebSocket message has NO head/body split at all (no start line, no headers),
# so `intercept_edit_bytes`'s HTTP-shaped CRLF rule has no boundary to bound itself by: with no
# blank line found, `normalize_head_crlf` (called via `intercept_edit_bytes`) treated the WHOLE
# message as "header" and promoted every bare LF to CRLF. `cmd_intercept_edit` now branches on
# the held row's `kind` BEFORE picking a rule (`ws_edit_bytes` for `row.ws?`, the function above
# for everything else) — this describes that new function directly, at the 838f55a3 control run
# `Gori::CLI::Run.intercept_edit_bytes("line1\nline2\nline3", true)` would have produced
# `"line1\r\nline2\r\nline3"` (19 bytes) for the identical input this spec pins at 17.
describe "Gori::CLI::Run.ws_edit_bytes" do
  it "takes a WS text edit LITERALLY — no CRLF promotion, no boundary search at all" do
    content = "line1\nline2\nline3"
    result = Gori::CLI::Run.ws_edit_bytes(content, 1_i64, false, used_raw_file: false)
    result.should be_a(Bytes)
    String.new(result.as(Bytes)).should eq(content) # bare LF preserved — NOT "\r\n"
  end

  it "is unchanged when there is no LF at all (the complement)" do
    content = "no-newlines-here"
    result = Gori::CLI::Run.ws_edit_bytes(content, 1_i64, false, used_raw_file: false)
    String.new(result.as(Bytes)).should eq(content)
  end

  it "never resyncs a Content-Length header even when the payload LOOKS like an HTTP head" do
    # A boundary DOES exist in this payload (a literal blank line) — proof the WS path never
    # even runs the HTTP boundary search, rather than running it and happening to no-op.
    content = "part1\n\npart2"
    result = Gori::CLI::Run.ws_edit_bytes(content, 1_i64, false, used_raw_file: false)
    String.new(result.as(Bytes)).should eq(content)
  end

  it "refuses a BINARY frame through --raw (used_raw_file: false) with an actionable message" do
    result = Gori::CLI::Run.ws_edit_bytes("\xFF\xFE", 5_i64, true, used_raw_file: false)
    result.should be_a(String)
    result.as(String).should contain("item 5")
    result.as(String).should contain("--raw-file")
  end

  it "allows a BINARY frame through --raw-file (used_raw_file: true) — the byte-exact channel" do
    body = Bytes[0xFF, 0xFE, 0x01, 0x02]
    content = String.new(body) # what File.read of the exact bytes hands back
    result = Gori::CLI::Run.ws_edit_bytes(content, 5_i64, true, used_raw_file: true)
    result.should be_a(Bytes)
    result.as(Bytes).to_a.should eq(body.to_a)
  end

  it "never refuses a TEXT WS item regardless of which channel carried it" do
    Gori::CLI::Run.ws_edit_bytes("hello", 1_i64, false, used_raw_file: false).should be_a(Bytes)
    Gori::CLI::Run.ws_edit_bytes("hello", 1_i64, false, used_raw_file: true).should be_a(Bytes)
  end
end

private def ws_held(kind : String = "wsout", binary : Bool = false) : Gori::Store::HeldRow
  Gori::Store::HeldRow.new(
    session_token: "t", item_id: 7_i64, kind: kind, method: "GET", host: "127.0.0.1",
    port: 20602, scheme: "http", target: "http://127.0.0.1:20602/chat",
    raw: "line1\nline2".to_slice, held_at_ms: 0_i64, binary: binary)
end

describe "Gori::Store::HeldRow#ws?/#binary?" do
  it "is true for both WS directions, false for request/response" do
    ws_held("wsout").ws?.should be_true
    ws_held("wsin").ws?.should be_true
    held("request", "/a").ws?.should be_false
    held("response", "200 OK").ws?.should be_false
  end

  it "carries the binary flag across the bridge row" do
    ws_held(binary: false).binary?.should be_false
    ws_held(binary: true).binary?.should be_true
  end
end

# `HeldRow#target` carries TWO different things depending on `kind`: a request's target, or a
# RESPONSE's status reason. The row builder never branched on it, so a held response rendered
# as `http://127.0.0.1200 OK` — a string that looks like a URL, is not one, drops the port,
# and left several held responses to different paths indistinguishable.
private def held(kind : String, target : String, flow_id : Int64? = nil) : Gori::Store::HeldRow
  Gori::Store::HeldRow.new(
    session_token: "t", item_id: 2_i64, kind: kind, method: "POST", host: "127.0.0.1",
    port: 19501, scheme: "http", target: target, raw: Bytes.empty, held_at_ms: 0_i64,
    flow_id: flow_id)
end

describe "Gori::CLI::Run.intercept_row_where" do
  it "renders a held RESPONSE as an authority plus its status reason, never as a URL" do
    Gori::CLI::Run.intercept_row_where(held("response", "200 OK", 2_i64))
      .should eq("http://127.0.0.1:19501 → 200 OK  (flow #2)")
  end

  it "omits the flow reference when the row does not carry one" do
    Gori::CLI::Run.intercept_row_where(held("response", "404 Not Found"))
      .should eq("http://127.0.0.1:19501 → 404 Not Found")
  end

  it "keeps a request held in ABSOLUTE form exactly as the wire had it" do
    Gori::CLI::Run.intercept_row_where(held("request", "http://127.0.0.1:19501/held"))
      .should eq("http://127.0.0.1:19501/held")
  end

  it "hangs an origin-form request off the authority — INCLUDING the port" do
    Gori::CLI::Run.intercept_row_where(held("request", "/held"))
      .should eq("http://127.0.0.1:19501/held")
  end
end

# R4. The refusal is decided when the message is HELD, and it reached no read surface: the
# operator (or the agent) composed an edit against a message described as ordinarily editable
# and learned otherwise from the ack. Both projections say so up front now.
private def refusing_row(refusal : String? = nil, head_only : Bool = false) : Gori::Store::HeldRow
  Gori::Store::HeldRow.new(
    session_token: "t", item_id: 1_i64, kind: "request", method: "GET", host: "h",
    port: 443, scheme: "https", target: "/a",
    raw: "GET /a HTTP/2\r\nHost: h\r\n\r\n".to_slice, held_at_ms: 0_i64,
    edit_refusal: refusal, head_only: head_only)
end

describe "held-item edit refusal on the read surfaces" do
  it "emits the reason and the head-only hold in the MCP list and detail projections" do
    row = refusing_row("the value of \"x-evil\" carries a CR or LF", head_only: true)
    listed = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_row(j, row, false, 0_i64) })
    listed["edit_refusal"].as_s.should contain("x-evil")
    listed["head_only"].as_bool.should be_true
    detail = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_detail(j, row, false, 0_i64) })
    detail["edit_refusal"].as_s.should contain("x-evil")
  end

  # An h2 hold whose body the gate could not buffer is head-only (no declared content-length,
  # or one over `H2::StreamGate::MAX_HOLD_BODY`), so folding that into `edit_refusal` would mark
  # such a message uneditable — head edits DO apply, only a body has nowhere to go. Two
  # statements, two fields.
  it "does not report a head-only hold as a refusal" do
    row = refusing_row(nil, head_only: true)
    row.edit_refusal.should be_nil
    row.head_only_note.not_nil!.should contain("HEAD only")
    obj = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_row(j, row, false, 0_i64) }).as_h
    obj["head_only"].as_bool.should be_true
    obj["head_only_note"].as_s.should contain("ADDS A BODY")
    obj.has_key?("edit_refusal").should be_false
  end

  # The complement: an h1 hold covers head+body and forwards byte-exact, so no field is
  # emitted and a client keying off field presence sees exactly the shape it saw before.
  it "says nothing at all about an ordinary h1 hold" do
    row = refusing_row
    row.edit_refusal.should be_nil
    row.head_only_note.should be_nil
    obj = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_row(j, row, false, 0_i64) }).as_h
    obj.has_key?("edit_refusal").should be_false
    obj.has_key?("head_only").should be_false
    obj.has_key?("head_only_note").should be_false
  end
end

# `head_and_body` backs BOTH read surfaces — MCP `intercept_list`/`intercept_get` and
# `gori run intercept list`/`show` — and it used to scan for `\r\n\r\n` alone and slice the
# body at a hard-coded `sep + 4`. A bare-LF header terminator is *the* CL/TE desync primitive
# (P7 keeps it byte-exact), so the one message class an operator holds precisely BECAUSE of its
# framing was the one whose framing these projections got wrong: the body was reported inside
# `head` with `body_size: 0`, while the EDIT path on the same bytes split it correctly through
# `Env.head_body_boundary`. `body_size` is the only body signal `intercept_get` gives without
# `include_sensitive`, and `intercept show` gates its raw-bytes hint on `body.empty?`.
private def desync_held(raw : String) : Gori::Store::HeldRow
  Gori::Store::HeldRow.new(
    session_token: "t", item_id: 3_i64, kind: "request", method: "POST", host: "h",
    port: 80, scheme: "http", target: "/x", raw: raw.to_slice, held_at_ms: 0_i64)
end

describe "Gori::MCP::Serialize.head_and_body" do
  it "splits a bare-LF-terminated head (LFLF) and keeps the body byte-exact" do
    head, body = Gori::MCP::Serialize.head_and_body(
      "POST /x HTTP/1.1\nHost: h\nContent-Length: 8\n\nSMUGGLED".to_slice)
    head.should eq("POST /x HTTP/1.1\nHost: h\nContent-Length: 8")
    String.new(body).should eq("SMUGGLED")
  end

  it "splits the mixed `\\n\\r\\n` spelling too" do
    head, body = Gori::MCP::Serialize.head_and_body("POST /x HTTP/1.1\nHost: h\n\r\nBODY".to_slice)
    head.should eq("POST /x HTTP/1.1\nHost: h")
    String.new(body).should eq("BODY")
  end

  it "is unchanged on a conformant CRLF message" do
    head, body = Gori::MCP::Serialize.head_and_body("POST /x HTTP/1.1\r\nHost: h\r\n\r\nBODY".to_slice)
    head.should eq("POST /x HTTP/1.1\r\nHost: h")
    String.new(body).should eq("BODY")
  end

  # The leftmost terminator wins, so a CRLFCRLF sitting INSIDE a smuggled body cannot pull the
  # split past the real one — the failure mode `Env.head_body_separator` is ordered to avoid.
  it "takes the earliest terminator when the body itself contains a CRLFCRLF" do
    head, body = Gori::MCP::Serialize.head_and_body(
      "POST /x HTTP/1.1\nCL: 1\n\nGET /smuggled HTTP/1.1\r\nHost: h\r\n\r\n".to_slice)
    head.should eq("POST /x HTTP/1.1\nCL: 1")
    String.new(body).should eq("GET /smuggled HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "treats a message with no terminator as all head" do
    head, body = Gori::MCP::Serialize.head_and_body("GET / HTTP/1.1".to_slice)
    head.should eq("GET / HTTP/1.1")
    body.size.should eq(0)
  end

  it "reports the body on the intercept detail projection, not a phantom empty one" do
    row = desync_held("POST /x HTTP/1.1\nHost: h\nContent-Length: 8\n\nSMUGGLED")
    obj = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_detail(j, row, false, 0_i64) })
    obj["body_size"].as_i.should eq(8)
    obj["raw_size"].as_i.should eq(52)
    obj["head"].as_s.should_not contain("SMUGGLED")
  end

  it "keeps the head preview on the list projection free of body bytes" do
    row = desync_held("POST /x HTTP/1.1\nHost: h\nContent-Length: 8\n\nSMUGGLED")
    obj = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.intercept_item_row(j, row, false, 0_i64) })
    obj["head_preview"]?.try(&.as_s).try(&.should_not(contain("SMUGGLED")))
  end
end

# The scanner both shapes come from. `head_body_boundary` (body start) and
# `head_body_separator` ({offset, width}) must never disagree, because a caller that renders
# the head as TEXT needs the offset and cannot derive it by subtracting a fixed 4.
describe "Gori::Env.head_body_separator" do
  it "agrees with head_body_boundary on every terminator spelling" do
    {
      "GET / HTTP/1.1\nHost: h\n\nbody",
      "GET / HTTP/1.1\r\nHost: h\r\n\r\nbody",
      "GET / HTTP/1.1\nHost: h\n\r\nbody",
    }.each do |wire|
      bytes = wire.to_slice
      offset, width = Gori::Env.head_body_separator(bytes).not_nil!
      (offset + width).should eq(Gori::Env.head_body_boundary(bytes))
    end
  end

  it "reports the width of each spelling" do
    Gori::Env.head_body_separator("a\n\nb".to_slice).should eq({1, 2})
    Gori::Env.head_body_separator("a\n\r\nb".to_slice).should eq({1, 3})
    Gori::Env.head_body_separator("a\r\n\r\nb".to_slice).should eq({1, 4})
  end

  it "is nil — and head_body_boundary is the full size — when there is no terminator" do
    bytes = "GET / HTTP/1.1\r\nHost: h\r\n".to_slice
    Gori::Env.head_body_separator(bytes).should be_nil
    Gori::Env.head_body_boundary(bytes).should eq(bytes.size)
  end
end
