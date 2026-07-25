require "../../spec_helper"

# P7 — "never reject malformed input on replay, only on the live MITM path."
#
# Gori::Repeater::FlowRequest is the reconstruct step every headless replay goes through
# (`gori run repeater send --flow`, the MCP send_request(flow_id:) tool, the TUI's
# load-into-Repeater). It is deliberately NOT a parser: it rewrites an absolute-form
# request line to origin-form and otherwise hands the captured bytes back untouched.
#
# That is the whole point for a security tool — the malformed request IS the test case. A
# smuggling probe, a fuzzed target, a bare-CR terminator, a NUL in a header: if any of
# these were normalized or refused on the way out, the operator could no longer replay the
# exact bytes that produced the original behaviour. Nothing asserted that invariant until
# now; these examples pin it byte-for-byte.
#
# The WELL-FORMED side of the same function — the absolute→origin rewrite on ordinary
# requests, the http2 flag, the target derivation, and the Content-Length/chunked re-frame
# applied when a capture was TRUNCATED — is covered by `describe Gori::Repeater::FlowRequest`
# in spec/cli_run_spec.cr. This file only adds the hostile inputs.

# Every example reconstructs the same way `gori run repeater send --flow` does: a complete
# http/1.1 flow whose only interesting part is the captured request bytes.
private def rebuilt(head : String, body : Bytes? = nil) : Bytes
  row = Gori::Store::FlowRow.new(
    id: 1_i64, created_at: 0_i64, scheme: "http", method: "GET", host: "h", port: 80,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", head.to_slice, body, nil, nil)
  Gori::Repeater::FlowRequest.build(detail).bytes
end

describe "replay reconstruct (P7) — malformed input is never rejected" do
  it "replays a head with NO line terminator at all, verbatim" do
    head = "GET / HTTP/1.1" # no CRLF, no LF, no blank line
    String.new(rebuilt(head)).should eq(head)
  end

  it "replays an EMPTY request head without raising" do
    rebuilt("").size.should eq(0)
  end

  it "replays a two-token (HTTP/0.9-style) request line verbatim" do
    # rewrite_request_line only touches a well-formed 3-token line; anything else is the
    # operator's bytes and goes out as captured.
    head = "GET /only-two-tokens\r\nHost: h\r\n\r\n"
    String.new(rebuilt(head)).should eq(head)
  end

  it "replays a request line with a RAW SPACE in the target verbatim" do
    # 4 tokens — a classic fuzz/smuggling shape. Splitting or re-encoding it would destroy
    # exactly what the operator is testing.
    head = "GET /a b HTTP/1.1\r\nHost: h\r\n\r\n"
    String.new(rebuilt(head)).should eq(head)
    # …and the same in absolute-form: still 4 tokens, so still no rewrite.
    abs = "GET http://h/a b HTTP/1.1\r\nHost: h\r\n\r\n"
    String.new(rebuilt(abs)).should eq(abs)
  end

  it "replays a head that is not HTTP at all, byte-for-byte" do
    head = String.new(Bytes[0x00, 0x01, 0xFF, 0x0A, 0x7F, 0x00])
    rebuilt(head).to_a.should eq(head.to_slice.to_a)
  end

  it "preserves NUL and 8-bit bytes inside a header value" do
    head = String.new(Bytes[0x47, 0x45, 0x54, 0x20, 0x2F, 0x20, 0x48, 0x54, 0x54, 0x50, 0x2F,
      0x31, 0x2E, 0x31, 0x0D, 0x0A]) + # "GET / HTTP/1.1\r\n"
           "X-Raw: " + String.new(Bytes[0x00, 0xFF, 0x80]) + "\r\n\r\n"
    rebuilt(head).to_a.should eq(head.to_slice.to_a)
  end

  it "preserves a BARE CR inside the head (the CR-smuggling probe)" do
    # A lone \r that never becomes \r\n is the payload of a request-smuggling test; a
    # line-normalizing rebuild would silently defuse it.
    head = "GET / HTTP/1.1\r\nX-A: 1\rX-B: 2\r\n\r\n"
    String.new(rebuilt(head)).should eq(head)
    rebuilt(head).count(0x0D_u8).should eq(head.to_slice.count(0x0D_u8))
  end

  it "preserves BOTH framing headers of a CL.TE probe when the body was not truncated" do
    # RFC 7230 forbids TE+CL; keeping both is the entire test. (The single-Content-Length
    # collapse fires ONLY on the truncated-capture path, which cannot replay faithfully
    # anyway — that branch is covered in spec/cli_run_spec.cr, not here.)
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n"
    body = "0\r\n\r\n".to_slice
    String.new(rebuilt(head, body)).should eq(head + "0\r\n\r\n")
  end

  it "preserves a duplicate Host header and header-name casing" do
    head = "GET / HTTP/1.1\r\nhOsT: a\r\nHost: b\r\n\r\n"
    String.new(rebuilt(head)).should eq(head)
  end

  it "preserves the %%% group separator a pipelined send splits on" do
    head = "GET /a HTTP/1.1\r\nHost: h\r\n\r\n%%%\r\nGET /b HTTP/1.1\r\nHost: h\r\n\r\n"
    String.new(rebuilt(head)).should eq(head)
  end
end

describe "replay reconstruct (P7) — the ONE rewrite it does make" do
  it "keeps a percent-encoded path and query byte-identical through the rewrite" do
    # `/a%2Fb` and `%2e%2e` are traversal/normalization probes: decoding them on the way
    # out would replay a DIFFERENT request than the one that was captured.
    head = "GET http://h/a%2Fb/%2e%2e/x?q=%ff&x=1 HTTP/1.1\r\nHost: h\r\n\r\n"
    String.new(rebuilt(head)).should eq("GET /a%2Fb/%2e%2e/x?q=%ff&x=1 HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "supplies '/' for an absolute-form URL with no path" do
    String.new(rebuilt("GET http://h HTTP/1.1\r\nHost: h\r\n\r\n"))
      .should eq("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "keeps an empty query marker ('?') that a normalizing rebuild would drop" do
    String.new(rebuilt("GET http://h/a? HTTP/1.1\r\nHost: h\r\n\r\n"))
      .should eq("GET /a? HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "rewrites only the FIRST line, never an absolute URL appearing later in the head" do
    head = "GET http://h/p HTTP/1.1\r\nReferer: http://h/other\r\n\r\n"
    String.new(rebuilt(head)).should eq("GET /p HTTP/1.1\r\nReferer: http://h/other\r\n\r\n")
  end

  it "leaves a non-http scheme in the request line alone" do
    # Only http:// and https:// are absolute-form request lines; anything else is data.
    head = "GET ftp://h/p HTTP/1.1\r\nHost: h\r\n\r\n"
    String.new(rebuilt(head)).should eq(head)
  end
end

describe "replay reconstruct (P7) — target parsing never raises" do
  it "falls back to a neutral triple instead of raising on a hostile target" do
    # A --target can come straight off a captured (attacker-controlled) authority. A raise
    # here would abort the replay rather than let the operator send the bytes.
    Gori::Repeater::FlowRequest.parse_target("http://h:abc").should eq({"http", "", 0}) # URI::Error
    # Everything else degrades to the scheme default rather than exploding.
    ["://///", "", "   ", "ht tp://x"].each do |t|
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"http", "", 80})
    end
  end

  it "round-trips an IPv6 literal through build_target / parse_target" do
    # An unbracketed IPv6 host splits wrong on the ':' — both directions must agree, or a
    # replay dials the wrong address.
    target = Gori::Repeater::FlowRequest.build_target("https", "::1", 8443)
    target.should eq("https://[::1]:8443")
    Gori::Repeater::FlowRequest.parse_target(target).should eq({"https", "::1", 8443})

    default_port = Gori::Repeater::FlowRequest.build_target("https", "::1", 443)
    default_port.should eq("https://[::1]")
    Gori::Repeater::FlowRequest.parse_target(default_port).should eq({"https", "::1", 443})
  end

  it "maps the WebSocket schemes onto the right default ports" do
    Gori::Repeater::FlowRequest.build_target("wss", "h", 443).should eq("wss://h")
    Gori::Repeater::FlowRequest.build_target("ws", "h", 80).should eq("ws://h")
    Gori::Repeater::FlowRequest.build_target("ws", "h", 8080).should eq("ws://h:8080")
  end
end

describe "replay reconstruct (P7) — Content-Length re-sync" do
  it "rewrites an EXISTING Content-Length to the body it actually ships" do
    # Used after $KEY expansion changes the body; an unsynced CL makes the origin over-
    # or under-read.
    bytes = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nhello".to_slice
    String.new(Gori::Repeater::FlowRequest.resync_content_length(bytes))
      .should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello")
  end

  it "never ADDS a Content-Length to a request that has none" do
    # A bodyless GET must stay clean, and a chunked request must keep its framing.
    get = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    String.new(Gori::Repeater::FlowRequest.resync_content_length(get)).should eq(String.new(get))

    chunked = "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".to_slice
    String.new(Gori::Repeater::FlowRequest.resync_content_length(chunked)).should eq(String.new(chunked))
  end

  it "leaves a head with no CRLFCRLF separator completely untouched" do
    # LF-only or truncated heads have no recognizable body boundary; guessing one would
    # corrupt bytes the operator captured deliberately.
    lf_only = "POST /u HTTP/1.1\nContent-Length: 99\n\nhello".to_slice
    String.new(Gori::Repeater::FlowRequest.resync_content_length(lf_only)).should eq(String.new(lf_only))
  end
end
