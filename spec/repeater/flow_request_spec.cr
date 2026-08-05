require "../spec_helper"

# A `Store::FlowDetail` the way a proxy capture stores one.
private def flow_detail(head : String, body : Bytes? = nil) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(
    id: 1_i64, created_at: 0_i64, scheme: "http", method: "GET", host: "h", port: 80,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head.to_slice, body, nil, nil)
end

describe Gori::Repeater::FlowRequest do
  describe ".build_target / .parse_target" do
    it "omits the default port and round-trips a normal host" do
      t = Gori::Repeater::FlowRequest.build_target("https", "api.test", 443)
      t.should eq("https://api.test")
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"https", "api.test", 443})
    end

    it "keeps a non-default port" do
      t = Gori::Repeater::FlowRequest.build_target("http", "api.test", 8080)
      t.should eq("http://api.test:8080")
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"http", "api.test", 8080})
    end

    it "uses the standard ports for ws and wss targets" do
      Gori::Repeater::FlowRequest.parse_target("ws://api.test/socket").should eq({"ws", "api.test", 80})
      Gori::Repeater::FlowRequest.parse_target("wss://api.test/socket").should eq({"wss", "api.test", 443})
      Gori::Repeater::FlowRequest.build_target("wss", "api.test", 443).should eq("wss://api.test")
    end

    it "brackets an IPv6 literal host so it round-trips (was dropped to host=\"\")" do
      t = Gori::Repeater::FlowRequest.build_target("http", "::1", 80)
      t.should eq("http://[::1]")
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"http", "::1", 80})
    end

    it "brackets an IPv6 literal host with a non-default port" do
      t = Gori::Repeater::FlowRequest.build_target("https", "2001:db8::1", 8443)
      t.should eq("https://[2001:db8::1]:8443")
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"https", "2001:db8::1", 8443})
    end
  end

  describe ".resync_content_length" do
    it "rewrites an existing Content-Length to the actual body length" do
      # body is 10 bytes ("ABCDEFGHIJ") but the header claims 3 — resync corrects it
      wire = "POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\nABCDEFGHIJ".to_slice
      out = String.new(Gori::Repeater::FlowRequest.resync_content_length(wire))
      out.should eq("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nABCDEFGHIJ")
    end

    it "matches the byte length after env expansion grows the body" do
      # a $KEY expands to a longer value → CL must follow
      expanded = Gori::Env.expand_wire("POST /x HTTP/1.1\nContent-Length: 5\n\nvalue-here",
        {"K" => "value-here"}, "$")
      out = String.new(Gori::Repeater::FlowRequest.resync_content_length(expanded))
      out.should contain("Content-Length: 10\r\n")
    end

    it "adds no header to a BODYLESS request (a GET with no Content-Length is untouched)" do
      wire = "GET /x HTTP/1.1\r\nHost: t\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(wire).should eq(wire)
    end

    # The auto-CL toggle's whole job: an operator edits a repeater request, types a body, and
    # leaves the Content-Length out. Returning the bytes unchanged (the pre-fix behaviour) sent
    # a framing-ambiguous request that a spec-conforming origin reads as a ZERO-length body —
    # silently, while gori's own captured `request_body` still displayed the typed text.
    it "adds a Content-Length when a body has none" do
      wire = "POST /x HTTP/1.1\r\nHost: t\r\n\r\na=1&b=2".to_slice
      String.new(Gori::Repeater::FlowRequest.resync_content_length(wire))
        .should eq("POST /x HTTP/1.1\r\nHost: t\r\nContent-Length: 7\r\n\r\na=1&b=2")
    end

    # The captured-flow REPLAY path (and MCP `send_request{apply_rules}`, which runs past the
    # point `auto_content_length` was honoured) opts out: a capture that carried no CL — an
    # h2/gRPC streamed POST is stored exactly that way — is evidence, not a draft to complete.
    it "adds nothing when add_if_missing is false" do
      wire = "POST /x HTTP/1.1\r\nHost: t\r\n\r\na=1&b=2".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(wire, add_if_missing: false).should eq(wire)
    end

    # A bare-LF header line makes `split("\r\n")` merge it into the line before, so the
    # Transfer-Encoding guard cannot see a TE that is really there. Adding a CL beside it would
    # hand back a CL.TE desync probe the operator never wrote, with the length counting the
    # CHUNKED wire bytes.
    it "refuses to add when a bare-LF line hides a Transfer-Encoding" do
      wire = "POST / HTTP/1.1\r\nHost: x\nTransfer-Encoding: chunked\r\n\r\n5\r\nHELLO\r\n0\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(wire).should eq(wire)
    end

    # An LF-framed head means the first `\r\n\r\n` can occur inside the BODY — here inside a
    # smuggled inner request — so the "head" runs past the real terminator and the appended
    # header would land in the middle of the smuggled bytes.
    it "refuses to add when the CRLFCRLF terminator lands inside the body" do
      wire = "POST /x HTTP/1.1\nHost: v\n\nGET /admin HTTP/1.1\r\nHost: v\r\n\r\nX".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(wire).should eq(wire)
    end

    it "leaves bytes without a CRLFCRLF separator untouched" do
      wire = "GET /x HTTP/1.1\r\nHost: t\r\n".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(wire).should eq(wire)
    end

    # RFC 7230 §3.3.3 forbids sending Transfer-Encoding and Content-Length together, so a
    # message carrying both is a CL.TE / TE.CL smuggling probe and the disagreement IS the
    # test. `repeater create` (auto-CL on by default) used to "correct" the CL over the
    # chunked wire form — `Content-Length: 6` went out as `10` — turning the probe into a
    # different probe with no notice, while the sibling flow-replay path already knew better.
    it "leaves a message carrying Transfer-Encoding alone, Content-Length or not" do
      clte = "POST /clte HTTP/1.1\r\nHost: h\r\nContent-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGPOST".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(clte).should eq(clte)
    end

    it "matches Transfer-Encoding case-insensitively and through leading OWS" do
      wire = "POST /x HTTP/1.1\r\n transfer-encoding: chunked\r\nContent-Length: 3\r\n\r\nABCDEFGHIJ".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(wire).should eq(wire)
    end
  end

  # The REQUEST-side fact behind the "captured incomplete" replay warning. It used to key on
  # `FlowRow#state`, which is the whole FLOW's — set by response-side failures too — so the
  # warning fired on essentially every flow whose response failed and prescribed `-b/--body`
  # on bodyless GETs that carry no Content-Length at all.
  describe ".request_short_of_framing?" do
    it "is FALSE for a bodyless GET (the control case: only its RESPONSE failed)" do
      head = "GET /r HTTP/1.1\r\nHost: h\r\nUser-Agent: curl/8.7.1\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.request_short_of_framing?(head, nil).should be_false
      Gori::Repeater::FlowRequest.request_short_of_framing?(head, Bytes.empty).should be_false
    end

    it "is TRUE for a POST whose stored body is shorter than its Content-Length" do
      head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.request_short_of_framing?(head, "short".to_slice).should be_true
    end

    it "is FALSE when the stored body matches, or EXCEEDS, its Content-Length" do
      head = "POST /u HTTP/1.1\r\nContent-Length: 5\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.request_short_of_framing?(head, "hello".to_slice).should be_false
      # Over-long is a deliberate desync probe (the extra bytes are the smuggled prefix), not
      # a truncated capture — and the origin will not block on it.
      Gori::Repeater::FlowRequest.request_short_of_framing?(head, "hello-and-more".to_slice).should be_false
    end

    it "is TRUE for a chunked body cut before its terminating 0-chunk" do
      head = "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.request_short_of_framing?(head, "5\r\nhel".to_slice).should be_true
    end

    it "is FALSE for a complete chunked body, even when a CL disagrees" do
      head = "POST /u HTTP/1.1\r\nContent-Length: 999\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.request_short_of_framing?(head, "5\r\nhello\r\n0\r\n\r\n".to_slice).should be_false
    end

    it "ignores an unparseable Content-Length rather than guessing" do
      head = "POST /u HTTP/1.1\r\nContent-Length: not-a-number\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.request_short_of_framing?(head, "x".to_slice).should be_false
    end
  end

  describe ".build — provenance of the absolute-form rewrite" do
    it "REPORTS the rewrite it makes, so a surface can say so" do
      built = Gori::Repeater::FlowRequest.build(flow_detail("GET http://evil.example/abs HTTP/1.1\r\nHost: evil.example\r\n\r\n"))
      String.new(built.bytes).should start_with("GET /abs HTTP/1.1\r\n")
      built.rewrote_request_line.should be_true
    end

    it "reports nothing when there was nothing to rewrite" do
      built = Gori::Repeater::FlowRequest.build(flow_detail("GET /abs HTTP/1.1\r\nHost: h\r\n\r\n"))
      built.rewrote_request_line.should be_false
    end

    # An absolute-form line is a proxy artifact on a proxy capture and the PAYLOAD on a flow
    # recorded from a direct send (routing / cache-poisoning / SSRF probes are written that
    # way). Nothing on the row tells them apart, so the operator gets the switch.
    it "keeps the stored line when the caller opts out of the rewrite" do
      head = "GET http://evil.example/abs HTTP/1.1\r\nHost: evil.example\r\n\r\n"
      built = Gori::Repeater::FlowRequest.build(flow_detail(head), rewrite_absolute_form: false)
      String.new(built.bytes).should eq(head)
      built.rewrote_request_line.should be_false
    end

    # The BACKSTOP for an h2 field list recorded as HTTP/1.1 head text: sent verbatim over h1
    # it makes `:method: POST` the start line, leaves every later header off by one, and gori
    # then reports the origin's status as if the request had gone out intact.
    it "refuses a head that opens with an HTTP/2 pseudo-header" do
      head = ":method: POST\r\n:path: /api\r\n:scheme: http\r\ncookie: sid=abc\r\n\r\n"
      expect_raises(Gori::Repeater::FlowRequest::PseudoHeaderHead, /pseudo-header/) do
        Gori::Repeater::FlowRequest.build(flow_detail(head))
      end
    end

    # …and refuses NOTHING else. P7 owns every other malformed head here; see
    # spec/cli/run/replay_reconstruct_spec.cr for the full set.
    it "still replays every other malformed head" do
      ["", "GET / HTTP/1.1", "GET /only-two-tokens\r\nHost: h\r\n\r\n",
       "GET /a b HTTP/1.1\r\nHost: h\r\n\r\n", String.new(Bytes[0x00, 0x01, 0xFF, 0x0A])].each do |head|
        Gori::Repeater::FlowRequest.build(flow_detail(head)) # must not raise
      end
    end
  end

  describe ".retarget_version_line" do
    it "downgrades an h2-captured request line to HTTP/1.1 for the verbatim h1 send" do
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a HTTP/2", false).should eq("GET /a HTTP/1.1")
    end

    it "upgrades an h1 request line to HTTP/2" do
      Gori::Repeater::FlowRequest.retarget_version_line("POST /a HTTP/1.1", true).should eq("POST /a HTTP/2")
    end

    it "no-ops (nil) when the version already matches the transport" do
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a HTTP/1.1", false).should be_nil
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a HTTP/2", true).should be_nil
    end

    it "bounds the version by the LAST space, tolerating a raw space in the target" do
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a b HTTP/2", false).should eq("GET /a b HTTP/1.1")
    end

    it "leaves a line that isn't a recognizable request line alone (nil)" do
      Gori::Repeater::FlowRequest.retarget_version_line("not a request line", false).should be_nil
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a", false).should be_nil
    end
  end

  describe ".downgrade_version_line" do
    it "rewrites a version an HTTP/1.x connection cannot carry" do
      Gori::Repeater::FlowRequest.downgrade_version_line("GET /a HTTP/2").should eq("GET /a HTTP/1.1")
      Gori::Repeater::FlowRequest.downgrade_version_line("POST /a HTTP/2.0").should eq("POST /a HTTP/1.1")
      Gori::Repeater::FlowRequest.downgrade_version_line("GET /a HTTP/3").should eq("GET /a HTTP/1.1")
    end

    # It runs unasked on every send, so — unlike `retarget_version_line`, which backs the
    # explicit ^V toggle — it must leave a version the operator meant alone.
    it "leaves every other version alone (nil)" do
      ["GET /a HTTP/1.1", "GET /a HTTP/1.0", "GET /a HTTP/0.9", "GET /a HTTP/9.9",
       "GET /a", "not a request line", "GET /a http/2"].each do |line|
        Gori::Repeater::FlowRequest.downgrade_version_line(line).should be_nil
      end
    end

    it "bounds the version by the LAST space, tolerating a raw space in the target" do
      Gori::Repeater::FlowRequest.downgrade_version_line("GET /a b HTTP/2").should eq("GET /a b HTTP/1.1")
    end
  end

  describe ".normalize_multipart_body" do
    it "restores the CRLF delimiters a multipart body needs" do
      raw = "POST /u HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=B\r\n\r\n--B\nX: 1\n\nhi\n--B--\n".to_slice
      String.new(Gori::Repeater::FlowRequest.normalize_multipart_body(raw))
        .should eq("POST /u HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=B\r\n\r\n--B\r\nX: 1\r\n\r\nhi\r\n--B--\r\n")
    end

    it "is idempotent on a body that already has CRLF" do
      raw = "POST /u HTTP/1.1\r\nContent-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\n\r\nhi\r\n--B--\r\n".to_slice
      Gori::Repeater::FlowRequest.normalize_multipart_body(raw).should eq(raw)
    end

    it "matches the header name and media type case-insensitively" do
      raw = "POST /u HTTP/1.1\r\ncontent-type: MULTIPART/Form-Data; boundary=B\r\n\r\n--B\n--B--\n".to_slice
      String.new(Gori::Repeater::FlowRequest.normalize_multipart_body(raw)).should end_with("--B\r\n--B--\r\n")
    end

    # A bare 0x0A in any other body is a BYTE, not a line ending — this is the one media
    # type that opts out of `Env.expand_wire`'s head-only rule.
    it "leaves every other body untouched" do
      [
        "POST /x HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\n\"a\":1\n}",
        "POST /x HTTP/1.1\r\nContent-Type: application/octet-stream\r\n\r\n\x01\n\x02",
        "POST /x HTTP/1.1\r\n\r\nno content-type\nhere",
        "GET /x HTTP/1.1\r\nContent-Type: multipart/form-data\r\n\r\n", # head-only: no body to touch
        "GET /x HTTP/1.1\r\nContent-Type: multipart/form-data",         # not even a separator
      ].each do |text|
        raw = text.to_slice
        Gori::Repeater::FlowRequest.normalize_multipart_body(raw).should eq(raw)
      end
    end

    # A header VALUE that merely mentions multipart doesn't make the body one.
    it "keys on the Content-Type header, not on the text anywhere" do
      raw = "POST /x HTTP/1.1\r\nX-Note: multipart/form-data\r\n\r\na\nb".to_slice
      Gori::Repeater::FlowRequest.normalize_multipart_body(raw).should eq(raw)
    end

    # The step's premise ("the CRs are already gone — `TextArea#set_text` strips \r off every
    # line") became FALSE once the editor started round-tripping terminators exactly, so on a
    # CAPTURED upload it stopped restoring missing delimiters and started corrupting surviving
    # ones: `alpha\nbeta\ngamma\n` of file content came back `alpha\r\nbeta\r\ngamma\r\n`,
    # three bytes the operator never captured, with auto-Content-Length re-framing the body so
    # nothing hung and nothing said a word.
    it "leaves a CAPTURED multipart body byte-exact — its LFs are file content" do
      body = "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" \
             "Content-Type: text/plain\r\n\r\nalpha\nbeta\ngamma\n\r\n--B--\r\n"
      raw = ("POST /u HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=B\r\n" \
             "Content-Length: #{body.bytesize}\r\n\r\n" + body).to_slice
      Gori::Repeater::FlowRequest.normalize_multipart_body(raw).should eq(raw)
    end

    it "still fixes a freshly TYPED multipart, whose body has no CRLF anywhere" do
      raw = "POST /u HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=B\r\n\r\n--B\nX: 1\n\nhi\n--B--\n".to_slice
      String.new(Gori::Repeater::FlowRequest.normalize_multipart_body(raw))
        .should end_with("--B\r\nX: 1\r\n\r\nhi\r\n--B--\r\n")
    end
  end
end
