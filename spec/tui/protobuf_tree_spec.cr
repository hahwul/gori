require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The schema-less protobuf decoder (#505) has fed `gori run history show --format json` and
# MCP `get_flow` since it landed, while the TUI stayed on hex — an inverted parity this repo
# otherwise holds to (#734). These pin the RENDERING, at all three gRPC sites, off the
# existing `Gori::Protobuf::Message`: no new decoder, no new fixtures.
#
# One payload carries every shape that matters:
#
#   field 1  varint 150                  08 96 01
#   field 2  len "hello"                 12 05 68 65 6c 6c 6f   → string, not a clean message
#   field 3  len {1: 42}                 1a 02 08 2a            → BOTH message and string
#
# Field 3 is the whole point of #496's design: without a `.proto` those two bytes are a
# nested message AND a valid UTF-8 string, and the decoder reports both rather than guessing.
private PB_BODY = Bytes[0x08, 0x96, 0x01,
  0x12, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
  0x1A, 0x02, 0x08, 0x2A]

# The same payload behind a gRPC length prefix (flag 0, 14 bytes).
private def grpc_frame(payload : Bytes, compressed = false) : Bytes
  io = IO::Memory.new
  io.write_byte(compressed ? 1_u8 : 0_u8)
  io.write_bytes(payload.size.to_u32, IO::ByteFormat::BigEndian)
  io.write(payload)
  io.to_slice
end

describe Gori::Tui::ProtobufTree do
  it "renders scalars and a string field with its wire type" do
    lines = ProtobufTree.lines(Gori::Protobuf.decode(PB_BODY))
    lines.should contain("  1  varint   150")
    lines.should contain("  2  len 5b  string | bytes")
    lines.should contain(%(     string: "hello"))
  end

  # The ambiguity report, rendered. A `len` field that parses as both must show BOTH, and the
  # row above them must say so — collapsing to one is exactly the guess #496 refused to make.
  it "shows a message and a string reading of the same bytes as siblings" do
    lines = ProtobufTree.lines(Gori::Protobuf.decode(PB_BODY))
    lines.should contain("  3  len 2b  message | string | bytes")
    lines.should contain("     message:")
    lines.should contain("       1  varint   42")
    lines.index { |l| l.starts_with?("     string: ") && l.includes?("*") }.should_not be_nil
  end

  # A payload with no string and no nested reading falls back to its octets INLINE, rather
  # than to a field row that names a reading and then shows nothing.
  it "prints hex for a payload that is only bytes" do
    # field 1, len 2, bytes ff fe — not valid UTF-8, not a clean message.
    lines = ProtobufTree.lines(Gori::Protobuf.decode(Bytes[0x0A, 0x02, 0xFF, 0xFE]))
    lines.should contain("  1  len 2b  bytes")
    lines.should contain("     bytes: ff fe")
  end

  # `complete: false` is the decoder saying it stopped mid-field. The fields above it are
  # real; the impression that they are ALL of them is not.
  it "names a truncated parse instead of showing a short tree as whole" do
    # field 1 varint 150, then a tag with no payload behind it.
    lines = ProtobufTree.lines(Gori::Protobuf.decode(Bytes[0x08, 0x96, 0x01, 0x12]))
    lines.should contain("  1  varint   150")
    lines.last.should contain("truncated")
  end

  # Control bytes in a captured payload must not reach the terminal as themselves — the same
  # class of desync the binary-body placeholder exists to avoid.
  it "escapes a string preview rather than emitting its control bytes" do
    # field 1, len 3, "a\x01b"
    lines = ProtobufTree.lines(Gori::Protobuf.decode(Bytes[0x0A, 0x03, 0x61, 0x01, 0x62]))
    line = lines.find(&.includes?("string:")).not_nil!
    line.should_not contain('')
    line.should contain("\\u0001")
  end

  # Width is measured in CELLS, not chars: a CJK payload is two columns per glyph, and a
  # `String#size` cut would hand the pane a row twice as wide as it asked for.
  it "cuts a wide string preview by draw width, not by character count" do
    wide = "한" * 200
    payload = wide.to_slice
    body = Bytes.new(2 + payload.size)
    body[0] = 0x0A_u8
    # A 2-byte varint length (600 bytes) — build the field by hand rather than re-deriving it.
    io = IO::Memory.new
    io.write_byte(0x0A_u8)
    len = payload.size
    while len >= 0x80
      io.write_byte(((len & 0x7F) | 0x80).to_u8)
      len >>= 7
    end
    io.write_byte(len.to_u8)
    io.write(payload)
    lines = ProtobufTree.lines(Gori::Protobuf.decode(io.to_slice))
    line = lines.find(&.includes?("string:")).not_nil!
    line.should contain("…")
    Screen.draw_width(line).should be <= ProtobufTree::STRING_PREVIEW_COLS + 16
  end
end

# --- site 1: History detail ------------------------------------------------------------

private def pb_tmp_store(&)
  path = File.tempname("gori-pbtree", ".db")
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

private GRPC_HEAD = "POST /svc/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"

describe "HistoryView gRPC detail" do
  seed = ->(store : Gori::Store, body : Bytes) do
    store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
      method: "POST", target: "/svc/M", http_version: "HTTP/2",
      head: GRPC_HEAD.to_slice, body: body, source: Gori::FlowSource::Kind::Proxy))
    view = HistoryView.new
    view.reload(store)
    view.open_detail(store).should be_true
    view
  end

  it "renders the protobuf tree on the REQUEST pane by default" do
    pb_tmp_store do |store|
      view = seed.call(store, grpc_frame(PB_BODY))
      view.pretty = true
      backend = MemoryBackend.new(160, 24)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("▸ message #1").should be_true
      backend.contains?("1  varint   150").should be_true
      backend.contains?("message | string | bytes").should be_true
      # …and it says out loud that none of those readings is authoritative.
      backend.contains?("none is authoritative").should be_true
    end
  end

  # Hex is the honest view for a payload the decoder cannot make sense of, and for anyone
  # verifying octets. It stays one keypress away — `p` swaps it back IN PLACE.
  it "falls back to the hex preview when PRETTY is off" do
    pb_tmp_store do |store|
      view = seed.call(store, grpc_frame(PB_BODY))
      view.pretty = false
      backend = MemoryBackend.new(160, 24)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("08 96 01 12 05").should be_true
      backend.contains?("varint   150").should be_false
    end
  end

  # The mode strip has to name the state and the key that changes it. `binary` alone used to
  # suppress the pretty chip here, which would have left `p` changing the pane with nothing
  # on screen saying so.
  it "offers a p: chip and names which reading is on screen" do
    pb_tmp_store do |store|
      view = seed.call(store, grpc_frame(PB_BODY))
      rect = Rect.new(0, 0, 160, 24)

      view.pretty = true
      on = MemoryBackend.new(160, 24)
      view.render_detail(Screen.new(on), rect)
      on.row(rect.y).should contain("PROTOBUF")
      on.row(rect.y).should contain("p:bytes")

      view.pretty = false
      off = MemoryBackend.new(160, 24)
      view.render_detail(Screen.new(off), rect)
      off.row(rect.y).should contain("BYTES")
      off.row(rect.y).should contain("p:tree")
      # ^X (the byte-exact dump of the whole body) never left either.
      off.row(rect.y).should contain("^X:hex")
    end
  end

  # The chip is drawn AND clickable — a chip only one of those is true for is the defect
  # `␣Pw:KEY` had. Both come off `detail_mode_chips`, so this pins them together.
  it "hit-tests the p: chip it draws" do
    pb_tmp_store do |store|
      view = seed.call(store, grpc_frame(PB_BODY))
      rect = Rect.new(0, 0, 160, 24)
      b = MemoryBackend.new(160, 24)
      view.render_detail(Screen.new(b), rect)
      col = b.row(rect.y).index("p:").not_nil!
      view.detail_mode_at(rect, col, rect.y).should eq(:pretty)
    end
  end

  # #1629: a gzip message is inflated under the stream's `grpc-encoding` and drawn as the same
  # tree, its header naming the codec — the CLI and MCP make the same projection.
  it "inflates a gzip-compressed payload and draws its tree" do
    pb_tmp_store do |store|
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/M", http_version: "HTTP/2",
        head: GRPC_HEAD.sub("\r\n\r\n", "\r\ngrpc-encoding: gzip\r\n\r\n").to_slice,
        body: grpc_frame(Gori::Proxy::H2::Grpc.compress("gzip", PB_BODY).not_nil!, compressed: true),
        source: Gori::FlowSource::Kind::Proxy))
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.pretty = true
      backend = MemoryBackend.new(160, 24)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("(gzip, inflated #{PB_BODY.size}b)").should be_true
      backend.contains?("varint   150").should be_true
    end
  end

  # The 0x01 flag with no `grpc-encoding` to name the codec: nothing to inflate with, so the
  # hex exit, with the reason above it. The CLI and MCP make the same carve-out.
  it "does not decode a compressed payload as protobuf" do
    pb_tmp_store do |store|
      view = seed.call(store, grpc_frame(PB_BODY, compressed: true))
      view.pretty = true
      backend = MemoryBackend.new(160, 24)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("(compressed)").should be_true
      backend.contains?("08 96 01 12 05").should be_true # hex, not a tree
      backend.contains?("no grpc-encoding").should be_true
      backend.contains?("varint   150").should be_false
      backend.contains?("none is authoritative").should be_false # no tree ⇒ no legend for one
    end
  end
end

# #1632: a Connect call takes the same pane — a unary protobuf body as its one message (named
# by the request's connect-protocol-version), and a stream's end-stream message as JSON text.
describe "HistoryView Connect detail" do
  seed = ->(store : Gori::Store, head : String, body : Bytes) do
    store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
      method: "POST", target: "/svc/M", http_version: "HTTP/1.1",
      head: head.to_slice, body: body, source: Gori::FlowSource::Kind::Proxy))
    view = HistoryView.new
    view.reload(store)
    view.open_detail(store).should be_true
    view.pretty = true
    backend = MemoryBackend.new(160, 24)
    view.render_detail(Screen.new(backend), Rect.new(0, 0, 160, 24))
    backend
  end

  it "decodes a unary proto body with no envelope" do
    pb_tmp_store do |store|
      backend = seed.call(store, "POST /svc/M HTTP/1.1\r\nHost: api.test\r\ncontent-type: application/proto\r\n" \
                                 "connect-protocol-version: 1\r\n\r\n", PB_BODY)
      backend.contains?("▸ message #1").should be_true
      backend.contains?("1  varint   150").should be_true
    end
  end

  it "shows a +json stream's messages and its end-stream as JSON, with no protobuf legend" do
    pb_tmp_store do |store|
      io = IO::Memory.new
      io.write(grpc_frame(%({"id":7}).to_slice))
      io.write_byte(2_u8)
      io.write_bytes(%({"error":{"code":"internal"}}).bytesize.to_u32, IO::ByteFormat::BigEndian)
      io << %({"error":{"code":"internal"}})
      backend = seed.call(store, "POST /svc/M HTTP/1.1\r\nHost: api.test\r\ncontent-type: application/connect+json\r\n\r\n",
        io.to_slice)
      backend.contains?(%({"id":7})).should be_true
      backend.contains?("▸ end-stream").should be_true
      backend.contains?(%({"error":{"code":"internal"}})).should be_true
      backend.contains?("none is authoritative").should be_false
      backend.contains?("JSON").should be_true # the mode strip names what PRETTY shows
      backend.contains?("PROTOBUF").should be_false
    end
  end

  it "cuts a long JSON payload at the protobuf tree's line ceiling" do
    pb_tmp_store do |store|
      max = Gori::Tui::ProtobufTree::MAX_LINES
      long = (1..(max + 50)).map { |i| %("k#{i}") }.join("\n")
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/M", http_version: "HTTP/1.1",
        head: "POST /svc/M HTTP/1.1\r\nHost: api.test\r\ncontent-type: application/connect+json\r\n\r\n".to_slice,
        body: grpc_frame(long.to_slice), source: Gori::FlowSource::Kind::Proxy))
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.pretty = true
      backend = MemoryBackend.new(160, max + 40)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 160, max + 40))
      backend.contains?(%("k#{max}")).should be_true
      backend.contains?("render cut at #{max} lines").should be_true
      backend.contains?(%("k#{max + 1}")).should be_false
    end
  end
end
