require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def grpc_tmp_store(&)
  path = File.tempname("gori-grpcf", ".db")
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

# `Grpc.scan`'s residual — the tail bytes that are NOT a complete frame — is the whole point
# of the change on this branch ("report a framing failure instead of deleting the gRPC view").
# `gori run show --format json` got it; the Repeater pane kept calling `Grpc.messages`, which
# drops the residual, so a deliberately-wrong length prefix (a standard gRPC parser test)
# rendered as a bare "(no complete gRPC messages)" — indistinguishable from "not gRPC".
describe "RepeaterView gRPC framing failure" do
  private_head = "POST /svc/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"

  def_view = ->(store : Gori::Store) do
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
      method: "POST", target: "/svc/M", http_version: "HTTP/2",
      head: private_head.to_slice, body: Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41]))
    view = RepeaterView.new
    view.load_grpc(store.get_flow(id).not_nil!)
    view
  end

  resp_head = "HTTP/2 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\n\r\n"

  it "names the byte count when a length prefix claims more than arrived" do
    grpc_tmp_store do |store|
      view = def_view.call(store)
      # prefix claims 9999 bytes; five arrive.
      body = Bytes[0x00, 0x00, 0x00, 0x27, 0x0F, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
      resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
      view.apply(Gori::Repeater::Result.new(resp_head.to_slice, body, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("the last 10 bytes are not a complete gRPC frame").should be_true
      backend.contains?("(no complete gRPC messages)").should be_false
    end
  end

  it "still reports a complete message plus its unframed tail" do
    grpc_tmp_store do |store|
      view = def_view.call(store)
      msg = "Hi".to_slice
      io = IO::Memory.new
      io.write(Bytes[0x00, 0x00, 0x00, 0x00, msg.size.to_u8])
      io.write(msg)
      io.write(Bytes[0x00, 0x00]) # 2 leftover bytes — not even a 5-byte prefix
      resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
      view.apply(Gori::Repeater::Result.new(resp_head.to_slice, io.to_slice, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("message #1").should be_true
      backend.contains?("the last 2 bytes are not a complete gRPC frame").should be_true
    end
  end

  it "names the REQUEST body's unframed tail instead of just counting 0 messages" do
    grpc_tmp_store do |store|
      # A captured request whose own length prefix over-claims: `→ sent 0 request messages
      # (10b)` used to be the whole story — a byte count and a message count that disagree,
      # with nothing saying why.
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/M", http_version: "HTTP/2",
        head: private_head.to_slice,
        body: Bytes[0x00, 0x00, 0x00, 0x27, 0x0F, 0x68, 0x65, 0x6C, 0x6C, 0x6F]))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)
      resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
      view.apply(Gori::Repeater::Result.new(resp_head.to_slice, Bytes.empty, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("sent 0 request messages").should be_true
      backend.contains?("the last 10 bytes are not a complete gRPC frame").should be_true
    end
  end

  it "still says nothing framed when the body is genuinely not gRPC-shaped" do
    grpc_tmp_store do |store|
      view = def_view.call(store)
      resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
      view.apply(Gori::Repeater::Result.new(resp_head.to_slice, Bytes.empty, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("(no complete gRPC messages)").should be_true
    end
  end

  # The GRPC REQUEST head is a mode-switched text editor (`i`/esc, READ selection, and — since
  # the READ over-paint reached this branch — a visible NORMAL block caret), so it carries the
  # READ/INS chip like every other non-hex request card. Draw and hit-test share
  # `Frame.right_badge_edge` over one badge list; this pins them together, because a chip that
  # is drawn but not hit-testable (or the reverse) is the exact defect `␣K:KEY` had.
  it "draws a clickable READ/INS mode chip on the request head" do
    grpc_tmp_store do |store|
      view = def_view.call(store)
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 160, 24)
      b = MemoryBackend.new(160, 24)
      view.render(Screen.new(b), rect)

      # The request card's top border: below the 3-row TARGET band.
      border_y = rect.y + 3
      row = b.row(border_y)
      row.should contain("↵:READ")
      col = row.index("↵:READ").not_nil!
      view.chrome_hit(rect, col + 1, border_y).should eq(:mode)

      # And it reports the mode it is in, rather than a fixed label.
      view.enter_request_insert!
      b2 = MemoryBackend.new(160, 24)
      view.render(Screen.new(b2), rect)
      b2.row(border_y).should contain("INS")
    end
  end

  # Hex draws no chip (a nibble cursor has no READ/INS), so none may be hit-testable there.
  it "reports no mode chip while the payload is hex-edited" do
    grpc_tmp_store do |store|
      view = def_view.call(store)
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 160, 24)
      view.render(Screen.new(MemoryBackend.new(160, 24)), rect)
      border_y = rect.y + 3

      view.toggle_request_hex.should be_true
      b = MemoryBackend.new(160, 24)
      view.render(Screen.new(b), rect)
      b.row(border_y).should_not contain("↵:READ")
      (0...160).each { |x| view.chrome_hit(rect, x, border_y).should_not eq(:mode) }
    end
  end
end

# PR 13 — "unary, so hex-editable" and "reframe on send" were ONE flag (`grpc_reframable?`),
# so this tab always reframed and the operator had no way to send what `gori run repeater send`
# sends by default: the captured 5-byte length prefix in front of an edited payload, which is a
# standard gRPC parser test. They are two facts now, and only the second is a choice.
describe "RepeaterView gRPC reframe toggle" do
  head = "POST /svc/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"

  # One clean unary message: flag 0, length 1, payload "A".
  unary = ->(store : Gori::Store) do
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
      method: "POST", target: "/svc/M", http_version: "HTTP/2",
      head: head.to_slice, body: Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41]))
    view = RepeaterView.new
    view.load_grpc(store.get_flow(id).not_nil!)
    view
  end

  sent_body = ->(view : RepeaterView) do
    wire = view.request_bytes
    sep = String.new(wire).index("\r\n\r\n").not_nil!
    wire[(sep + 4)..]
  end

  # Grow the payload from 1 byte ("A") to 3 ("ABC") through the hex editor — the gesture the
  # whole tab exists for, and the one that makes the captured prefix a lie. `^X`, cursor to
  # the append slot, then four nibbles.
  grown = ->(view : RepeaterView) do
    view.toggle_request_hex.should be_true
    2.times { view.hex_move(0, 1) } # nib 0 → 2, the append slot past the single byte
    "4243".each_char { |c| view.hex_set_nibble(c) }
    view
  end

  # Two messages: `Grpc.reframe` declines these outright (every prefix present is honest), so
  # the tab does too rather than offering a knob that cannot act.
  multi_body = Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41, 0x00, 0x00, 0x00, 0x00, 0x01, 0x42]
  multi = ->(store : Gori::Store) do
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 3_i64, scheme: "https", host: "api.test", port: 443,
      method: "POST", target: "/svc/M", http_version: "HTTP/2",
      head: head.to_slice, body: multi_body))
    view = RepeaterView.new
    view.load_grpc(store.get_flow(id).not_nil!)
    view
  end

  it "defaults ON, the opposite of `gori run repeater send` (DESIGN.md §7)" do
    grpc_tmp_store do |store|
      view = unary.call(store)
      view.grpc_reframable?.should be_true # a fact about the capture
      view.grpc_reframe?.should be_true    # …and a separate, flippable choice
    end
  end

  it "recomputes the length prefix over a hex-edited payload while ON" do
    grpc_tmp_store do |store|
      view = grown.call(unary.call(store))
      sent_body.call(view).should eq(Bytes[0x00, 0x00, 0x00, 0x00, 0x03, 0x41, 0x42, 0x43])
    end
  end

  it "sends the CAPTURED prefix in front of the edited payload while OFF" do
    grpc_tmp_store do |store|
      view = grown.call(unary.call(store))
      view.toggle_grpc_reframe.should be_false
      # Prefix still declares 1 byte over a 3-byte payload — the deliberately-stale framing
      # `gori run repeater send` (no `--reframe-grpc`) would put on the wire.
      sent_body.call(view).should eq(Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41, 0x42, 0x43])
    end
  end

  it "is byte-exact with the toggle OFF and no edit at all" do
    grpc_tmp_store do |store|
      view = unary.call(store)
      view.toggle_grpc_reframe.should be_false
      sent_body.call(view).should eq(Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41])
    end
  end

  it "refuses to flip on a body that has no unary prefix to recompute" do
    grpc_tmp_store do |store|
      view = multi.call(store)
      view.grpc_reframable?.should be_false
      view.toggle_grpc_reframe.should be_true    # unchanged — the refusal, not a flip
      sent_body.call(view).should eq(multi_body) # …and the body is still verbatim
    end
  end

  it "starts back ON when the tab is re-seeded with another flow" do
    grpc_tmp_store do |store|
      view = unary.call(store)
      view.toggle_grpc_reframe.should be_false
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/N", http_version: "HTTP/2",
        head: head.to_slice, body: Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x5A]))
      view.load_grpc(store.get_flow(id).not_nil!)
      view.grpc_reframe?.should be_true
    end
  end

  # Drawn AND hit-testable, in both halves of the gRPC branch — the defect `␣K:KEY` had, and
  # the state matters most exactly while the payload is being hex-edited.
  it "draws a clickable ␣F:FRAME badge in both the MSG and HEX states" do
    grpc_tmp_store do |store|
      view = unary.call(store)
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 160, 24)
      border_y = rect.y + 3

      b = MemoryBackend.new(160, 24)
      view.render(Screen.new(b), rect)
      row = b.row(border_y)
      row.should contain("␣F:FRAME")
      col = row.index("␣F:FRAME").not_nil!
      view.chrome_hit(rect, col + 1, border_y).should eq(:grpc_reframe)

      view.toggle_request_hex.should be_true
      b2 = MemoryBackend.new(160, 24)
      view.render(Screen.new(b2), rect)
      row2 = b2.row(border_y)
      row2.should contain("␣F:FRAME")
      col2 = row2.index("␣F:FRAME").not_nil!
      view.chrome_hit(rect, col2 + 1, border_y).should eq(:grpc_reframe)
    end
  end

  it "draws no FRAME badge on a body it cannot reframe" do
    grpc_tmp_store do |store|
      view = multi.call(store)
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 160, 24)
      b = MemoryBackend.new(160, 24)
      view.render(Screen.new(b), rect)
      b.row(rect.y + 3).should_not contain("FRAME")
      (0...160).each { |x| view.chrome_hit(rect, x, rect.y + 3).should_not eq(:grpc_reframe) }
    end
  end
end

# gRPC-Web is gRPC framing over HTTP/1.1 — what every browser client speaks, so it is the
# gRPC a proxy sees most. The Repeater gated its whole gRPC mode on `http_version == "HTTP/2"`
# and on a substring search of the head, so a grpc-web call opened as a plain raw tab: no
# deframed transcript, no hex-editable payload, no grpc-status — while the History PROTO
# column and the QL `proto:` filter both called the same flow GRPC.
describe "RepeaterView gRPC over HTTP/1.1 (grpc-web)" do
  def_web = ->(store : Gori::Store, ct : String, body : Bytes) do
    head = "POST /svc/M HTTP/1.1\r\nHost: api.test\r\nContent-Type:#{ct}\r\nContent-Length: #{body.size}\r\n\r\n"
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
      method: "POST", target: "/svc/M", http_version: "HTTP/1.1",
      head: head.to_slice, body: body))
    view = RepeaterView.new
    view.load_grpc(store.get_flow(id).not_nil!)
    view
  end

  it "keeps the flow's own transport instead of forcing h2" do
    grpc_tmp_store do |store|
      view = def_web.call(store, "application/grpc-web+proto", Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41])
      view.grpc_mode?.should be_true
      view.http2?.should be_false # forcing h2 would re-send it over a protocol the origin may not speak
      view.grpc_msg_count.should eq(1)
      view.grpc_reframable?.should be_true
    end
  end

  # Over h1 the body is delimited by Content-Length, not by a DATA frame with END_STREAM, so
  # a reframed payload that changed size leaves a header the origin reads as the message
  # boundary — the call hangs or is cut. (h2 keeps the header untouched, as before.)
  it "resyncs Content-Length to the body it actually sends" do
    grpc_tmp_store do |store|
      body = Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41]
      head = "POST /svc/M HTTP/1.1\r\nHost: api.test\r\nContent-Type: application/grpc-web\r\nContent-Length: 999\r\n\r\n"
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/M", http_version: "HTTP/1.1",
        head: head.to_slice, body: body))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)
      wire = String.new(view.request_bytes)
      sep = wire.index("\r\n\r\n").not_nil!
      declared = wire[0, sep].lines.find(&.downcase.starts_with?("content-length:")).not_nil!
        .split(':')[1].strip.to_i
      declared.should eq(body.size)
    end
  end

  # grpc-web-text carries the frames base64-encoded. Scanning the raw body finds a length
  # prefix made of base64 characters, so the tab reported "0 messages" for a perfectly ordinary
  # unary call — and a reframed payload has to go back out re-encoded, not as raw binary.
  it "deframes a grpc-web-text body and re-encodes what it sends" do
    grpc_tmp_store do |store|
      wire = Base64.strict_encode(Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41]).to_slice
      view = def_web.call(store, "application/grpc-web-text", wire)
      view.grpc_msg_count.should eq(1)
      view.grpc_reframable?.should be_true
      sent = view.request_bytes
      sep = String.new(sent).index("\r\n\r\n").not_nil!
      String.new(sent[(sep + 4)..]).should eq(String.new(wire)) # round-trips as base64, not raw binary
    end
  end
end
