require "../spec_helper"

# Issue #400 — an imported CRLF-bearing request target must replay onto the wire BYTE-EXACT.
#
# The import path (src/gori/import/builder.cr) deliberately stops rejecting a control byte in a
# URL's PATH/QUERY: that byte is the operator's own smuggling payload, and reproducing a broken
# request is the point of a security-testing proxy (P7; DESIGN.md §7). This file proves it end
# to end, on the SOCKET rather than in a string — #390/#397/#401 established that for this class
# a string-level assertion proves nothing, because something downstream (a codec guard, an
# origin re-parse, an Env pass) could re-validate or mangle the bytes between store and wire.
#
# The chain under test is the exact one every headless replay takes:
#   Import::Builder.request_head  (the serializer HAR/OAS/--urls all call)
#     → Store::FlowDetail          (the captured flow, reconstructed DB-free like replay_reconstruct_spec)
#       → Repeater::FlowRequest.build → Repeater::Plan → Repeater::Sender → upstream.write
private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

# Reconstruct a captured flow exactly as `gori run repeater send --flow` does, from a head the
# IMPORT serializer produced, then read what actually reaches the origin socket.
private def wire_of(head : Bytes, port : Int32, seen : Channel(Bytes)) : Nil
  row = Gori::Store::FlowRow.new(
    id: 1_i64, created_at: 0_i64, scheme: "http", method: "GET", host: "evil.test", port: 80,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
  built = Gori::Repeater::FlowRequest.build(detail)

  plan = Gori::Repeater::Plan.build(
    Gori::Repeater::PlanOptions.new([built.bytes],
      target: "127.0.0.1:#{port}", auto_content_length: false, verify: false,
      timeout: 3.seconds),
    ungated)
  plan.send
end

describe "import → repeater wire fidelity (#400, P7)" do
  it "replays an imported CRLF-smuggling target byte-exact onto the socket" do
    # The operator's HAR carried this URL; import stored it via Builder.request_head. The CRLF is
    # in the PATH, so the host stayed a real host and the entry was NOT skipped.
    target = "/path\r\nX-Injected: pwn\r\n\r\nGET /second HTTP/1.1"
    head = Gori::Import::Builder.request_head(
      "GET", target, "HTTP/1.1", "evil.test", Gori::Import::Builder::Headers.new, nil)

    # The send-layer guard's OWN verdict on these bytes is "unsafe" — it would refuse to
    # SYNTHESIZE a request line out of them. That it fires here and the replay below still sends
    # them verbatim is the proof that the guard does NOT gate the operator-replay path (its
    # docstring, landed by #399, promises exactly this). If this path ever started calling the
    # guard, the socket assertion below would fail instead — this line just names the contrast.
    Gori::Proxy::Codec::Http1.request_token_safe?(target).should be_false

    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    seen = Channel(Bytes).new(1)
    spawn do
      if sock = server.accept?
        buf = Bytes.new(8192)
        n = sock.read(buf)
        seen.send(buf[0, n].dup)
        sock << "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        sock.close rescue nil
      end
    rescue
    end

    begin
      wire_of(head, port, seen)
      select
      when wire = seen.receive
        # Byte-for-byte: the smuggled second request line and injected header reach the wire
        # exactly as the operator built them. Nothing percent-encoded, normalized, or rejected.
        String.new(wire).should eq(
          "GET /path\r\nX-Injected: pwn\r\n\r\nGET /second HTTP/1.1 HTTP/1.1\r\n" \
          "Host: evil.test\r\n\r\n")
      when timeout(3.seconds)
        fail "repeater never dialed the origin — the imported entry did not replay"
      end
    ensure
      server.close
    end
  end

  it "replays an imported raw-SPACE target verbatim too (the case #400 was first filed about)" do
    # A space in the request target is the original, still-correct behaviour: 4 tokens on the
    # request line, replayed as-is. Confirming it on the wire, not just in a reconstruct string.
    target = "/a b?x=1 2"
    head = Gori::Import::Builder.request_head(
      "GET", target, "HTTP/1.1", "evil.test", Gori::Import::Builder::Headers.new, nil)

    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    seen = Channel(Bytes).new(1)
    spawn do
      if sock = server.accept?
        buf = Bytes.new(8192)
        n = sock.read(buf)
        seen.send(buf[0, n].dup)
        sock << "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        sock.close rescue nil
      end
    rescue
    end

    begin
      wire_of(head, port, seen)
      select
      when wire = seen.receive
        String.new(wire).should eq(
          "GET /a b?x=1 2 HTTP/1.1\r\nHost: evil.test\r\n\r\n")
      when timeout(3.seconds)
        fail "repeater never dialed the origin"
      end
    ensure
      server.close
    end
  end
end
