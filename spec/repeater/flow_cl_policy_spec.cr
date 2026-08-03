require "../spec_helper"

# The CAPTURED-FLOW Content-Length policy.
#
# `send_request{flow_id}` documents a flow replay as byte-exact and was not: it inherited
# `auto_content_length: true` and rewrote the stored CL line on every send. So a captured
# `Content-Length: 99` over a 2-byte body — a CL-desync probe someone captured *because* it
# is wrong — went out as `Content-Length: 2`, with `isError:false` and no notice. The
# operator read a verdict about a request gori never sent. `gori run repeater <flow-id>`
# had the same behaviour.
#
# The one case that must still recompute is why the resync exists on this path at all: a
# `$KEY` in the body, whose expansion changes the body length AFTER the CL was framed over
# the pre-expansion bytes. Distinguishing the two is what these examples pin.
describe "Gori::Repeater::FlowRequest.resync_content_length_if_body_changed" do
  it "leaves a deliberately-wrong Content-Length alone when the body did not change" do
    wire = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nAB".to_slice
    res = Gori::Repeater::FlowRequest.resync_content_length_if_body_changed(wire, wire)
    String.new(res).should eq("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nAB")
  end

  it "recomputes only when expansion changed the BODY's length" do
    before = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\np=$PW".to_slice
    after = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\np=hunter2".to_slice
    res = String.new(Gori::Repeater::FlowRequest.resync_content_length_if_body_changed(before, after))
    res.should contain("Content-Length: 9\r\n")
    res.should end_with("p=hunter2")
  end

  it "does NOT recompute when expansion only touched the HEAD" do
    # Otherwise a `$KEY` in a header would become a licence to overwrite a pinned CL that
    # has nothing to do with it.
    before = "POST /x HTTP/1.1\r\nX-A: $PW\r\nContent-Length: 99\r\n\r\nAB".to_slice
    after = "POST /x HTTP/1.1\r\nX-A: hunter2\r\nContent-Length: 99\r\n\r\nAB".to_slice
    String.new(Gori::Repeater::FlowRequest.resync_content_length_if_body_changed(before, after))
      .should contain("Content-Length: 99\r\n")
  end

  it "is a no-op on a message with no CRLFCRLF terminator (nothing to split on)" do
    raw = "GET /only-a-head".to_slice
    String.new(Gori::Repeater::FlowRequest.resync_content_length_if_body_changed(raw, raw))
      .should eq("GET /only-a-head")
  end
end

# `Env.head_body_boundary` is the shared head/body split. MCP's History recording used to
# carry its own CRLFCRLF-only scan that RAISED when it found none — which made
# `record_history` (on by default) refuse to send a bare-LF-terminated request at all, the
# exact payload `verbatim:true` advertises. Making the shared one public is the fix, so its
# contract is pinned here.
describe "Gori::Env.head_body_boundary" do
  it "accepts a bare-LF header terminator" do
    Gori::Env.head_body_boundary("GET / HTTP/1.1\nHost: h\n\nbody".to_slice).should eq(24)
  end

  it "accepts a CRLF header terminator" do
    Gori::Env.head_body_boundary("GET / HTTP/1.1\r\nHost: h\r\n\r\nbody".to_slice).should eq(27)
  end

  it "accepts a `\\n\\r\\n` terminator (bare-LF header end + CRLF blank line)" do
    # The 4th spelling: a header line ended by a lone LF, then a CRLF blank line. Missed by
    # both neighbors (LFLF needs a second LF; CRLFCRLF starts on CR), so the whole message
    # used to read as head and the body's bare LFs were promoted to CRLF. Body starts at 25.
    Gori::Env.head_body_boundary("GET / HTTP/1.1\nHost: h\n\r\nbody".to_slice).should eq(25)
  end

  it "takes whichever spelling comes FIRST, not a fixed preference" do
    # A body that itself contains a CRLFCRLF must not move the boundary past the real one.
    bytes = "GET / HTTP/1.1\nHost: h\n\nA\r\n\r\nB".to_slice
    Gori::Env.head_body_boundary(bytes).should eq(24)
  end

  it "returns the full size when there is no terminator at all" do
    bytes = "GET /no-terminator HTTP/1.1".to_slice
    Gori::Env.head_body_boundary(bytes).should eq(bytes.size)
  end
end

# End-to-end proof that the `\n\r\n` boundary fix reaches the wire through the shared
# plan builder. A draft whose Content-Length line is bare-LF-terminated and whose blank
# line is CRLF used to read as all-head: `expand_wire` then promoted the BODY's bare LF to
# CRLF (`a\nb` → `a\r\nb`) and the auto-CL resync re-framed it to `Content-Length: 4` — a
# silently corrupted request. With the boundary recognized, the head is normalized and the
# 3-byte body `a\nb` is spliced through verbatim.
describe "Gori::Repeater::Plan.build with a `\\n\\r\\n` head boundary" do
  it "sends the body `a\\nb` (3 bytes) unchanged, not reframed to `a\\r\\nb`/CL:4" do
    wire = "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 3\n\r\na\nb"
    options = Gori::Repeater::PlanOptions.new([wire.to_slice], target: "http://h")
    ungated = Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
    out = String.new(Gori::Repeater::Plan.build(options, ungated).bytes)

    out.should end_with("\r\n\r\na\nb")     # body verbatim, head terminated with a real blank line
    out.should_not contain("a\r\nb")        # the body's bare LF was NOT promoted to CRLF
    out.should contain("Content-Length: 3") # framed over the real 3-byte body
    out.should_not contain("Content-Length: 4")
  end
end

# A hand-authored head's start line, for the RECORD path only.
#
# The shared `parse_request_head` stays strict-CRLF on purpose, and that is not a detail:
# `Body.framing_ambiguous?` detects a response desync by comparing the strict parse against
# what a lenient recipient would read, and Fuzz's redirect guard refuses a `Location` whose
# bare LF splices a second request. Teaching the shared parser about bare LF turned three of
# those specs red — which is the reason this second, narrower function exists at all.
describe "Gori::Proxy::Codec::Http1.authored_start_line" do
  it "reads the version correctly from a BARE-LF head" do
    # The strict scan found the CRLF inside the BODY instead, so History filed
    # `http_version: "HTTP/1.1\nHost:"` for a request whose bytes it held byte-exact.
    head = "GET /x2 HTTP/1.1\nHost: h\nX-Probe: v\n\n".to_slice
    Gori::Proxy::Codec::Http1.authored_start_line(head).should eq({"GET", "/x2", "HTTP/1.1"})
  end

  it "reads a CRLF head identically" do
    head = "POST /y HTTP/1.0\r\nHost: h\r\n\r\n".to_slice
    Gori::Proxy::Codec::Http1.authored_start_line(head).should eq({"POST", "/y", "HTTP/1.0"})
  end

  it "takes the FIRST terminator, so a CRLF later in the message cannot move the line" do
    head = "GET /z HTTP/9.9\nA: 1\r\nB: 2\n\n".to_slice
    Gori::Proxy::Codec::Http1.authored_start_line(head).should eq({"GET", "/z", "HTTP/9.9"})
  end

  it "returns empty strings for the tokens a malformed line omits, without raising" do
    Gori::Proxy::Codec::Http1.authored_start_line("GET /only-two\n\n".to_slice)
      .should eq({"GET", "/only-two", ""})
    Gori::Proxy::Codec::Http1.authored_start_line("".to_slice).should eq({"", "", ""})
  end

  it "leaves the shared parser strict — the security machinery that depends on it" do
    # If this ever starts returning "HTTP/1.1", the desync detectors have lost their lever.
    Gori::Proxy::Codec::Http1.parse_request_head("GET /x HTTP/1.1\nHost: h\n\n".to_slice)
      .version.should_not eq("HTTP/1.1")
  end
end
