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
      head: GRPC_HEAD.to_slice, body: body))
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
  # `␣K:KEY` had. Both come off `detail_mode_chips`, so this pins them together.
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

  # The 0x01 flag says these bytes are not protobuf until something inflates them, and the
  # encoding is named by `grpc-encoding`, not by gori. The CLI and MCP make the same carve-out.
  it "does not decode a compressed payload as protobuf" do
    pb_tmp_store do |store|
      view = seed.call(store, grpc_frame(PB_BODY, compressed: true))
      view.pretty = true
      backend = MemoryBackend.new(160, 24)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("(compressed)").should be_true
      backend.contains?("08 96 01 12 05").should be_true # hex, not a tree
      backend.contains?("varint   150").should be_false
      backend.contains?("none is authoritative").should be_false # no tree ⇒ no legend for one
    end
  end
end

# --- sites 2 & 3: the Repeater GRPC RESPONSE transcript --------------------------------

describe "RepeaterView gRPC protobuf transcript" do
  resp_head = "HTTP/2 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\n\r\n"

  loaded = ->(store : Gori::Store) do
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
      method: "POST", target: "/svc/M", http_version: "HTTP/2",
      head: GRPC_HEAD.to_slice, body: grpc_frame(PB_BODY)))
    view = RepeaterView.new
    view.load_grpc(store.get_flow(id).not_nil!)
    view
  end

  answered = ->(view : RepeaterView, body : Bytes) do
    resp = Gori::Proxy::Codec::Http1.parse_response_head(resp_head.to_slice)
    view.apply(Gori::Repeater::Result.new(resp_head.to_slice, body, resp, 5000_i64))
    view
  end

  it "decodes each response message into the same tree the History pane draws" do
    pb_tmp_store do |store|
      view = answered.call(loaded.call(store), grpc_frame(PB_BODY))
      view.pretty = true
      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("← message #1").should be_true
      backend.contains?("1  varint   150").should be_true
      backend.contains?("message | string | bytes").should be_true
    end
  end

  # `pretty=` drops the response-view cache; the transcript has a cache of its OWN, and
  # missing it would leave hex on screen under a lit ` p:bytes ` chip saying otherwise.
  it "re-renders the transcript when PRETTY flips (its cache is dropped too)" do
    pb_tmp_store do |store|
      view = answered.call(loaded.call(store), grpc_frame(PB_BODY))
      view.pretty = true
      view.render(Screen.new(MemoryBackend.new(160, 24)), Rect.new(0, 0, 160, 24))

      view.pretty = false
      off = MemoryBackend.new(160, 24)
      view.render(Screen.new(off), Rect.new(0, 0, 160, 24))
      off.contains?("varint   150").should be_false
      off.contains?("08 96 01 12 05").should be_true

      view.pretty = true
      on = MemoryBackend.new(160, 24)
      view.render(Screen.new(on), Rect.new(0, 0, 160, 24))
      on.contains?("varint   150").should be_true
    end
  end

  # The transcript was the one response pane with no chrome at all. `p` is live on it now, so
  # it carries a chip — drawn and hit-testable off one shared geometry (`grpc_chip_x`).
  it "draws a clickable p: chip on the transcript border" do
    pb_tmp_store do |store|
      view = answered.call(loaded.call(store), grpc_frame(PB_BODY))
      view.focus_pane(:response)
      view.pretty = true
      rect = Rect.new(0, 0, 160, 24)
      b = MemoryBackend.new(160, 24)
      view.render(Screen.new(b), rect)

      # The RESPONSE column is the right half, below the 3-row TARGET band.
      row = b.row(rect.y + 3)
      row.should contain("GRPC RESPONSE")
      row.should contain("p:bytes")
      col = row.index("p:bytes").not_nil!
      view.chrome_hit(rect, col, rect.y + 3).should eq(:pretty)
    end
  end

  # …and the inverse, which the shared geometry only half covered (#741 review). The draw's
  # stop is the LATENCY meta's left edge, not the card's '╮'; the hit-test passed its own
  # `right - 1`. At 60 columns the RESPONSE half is 30 wide, ` p:bytes ` no longer clears the
  # ` 5ms ` on that border, and the draw paints NOTHING — while the hit test kept nine live
  # cells there, two of them on the duration text itself. Clicking the send you just made and
  # having the pane silently swap readings is exactly the dead/ghost-cell class `␣K:KEY` had.
  it "does not light the p: chip over the duration meta it could not clear" do
    pb_tmp_store do |store|
      view = answered.call(loaded.call(store), grpc_frame(PB_BODY))
      view.focus_pane(:response)
      view.pretty = true
      rect = Rect.new(0, 0, 60, 24)
      b = MemoryBackend.new(60, 24)
      view.render(Screen.new(b), rect)

      row = b.row(rect.y + 3)
      row.should contain("GRPC RESPONSE")
      row.should_not contain("p:bytes") # the draw refused — it would have overpainted the meta
      meta = Fmt.dur(5000_i64)
      col = row.index(meta).not_nil!
      # Every cell the duration occupies.
      meta.size.times { |i| view.chrome_hit(rect, col + i, rect.y + 3).should be_nil }
    end
  end

  # The other half of the same split: a chip the draw refused paints no cell ANYWHERE, so no
  # cell on that border may answer for it — not the duration's, and not the bare border left
  # of it where the chip would have started.
  it "leaves the whole transcript border dead when the chip was not painted" do
    pb_tmp_store do |store|
      view = answered.call(loaded.call(store), grpc_frame(PB_BODY))
      view.focus_pane(:response)
      view.pretty = true
      # 60 cols: the chip fits under the card's corner but not under the meta (the draw is the
      # authority). 44: too narrow for it on any reading — a guard that the tightened stop
      # never re-opens a cell as the pane shrinks further.
      {60, 44}.each do |w|
        rect = Rect.new(0, 0, w, 24)
        b = MemoryBackend.new(w, 24)
        view.render(Screen.new(b), rect)
        b.row(rect.y + 3).should_not contain("p:bytes")
        # The RESPONSE half is everything right of the divider.
        half = (w - 1) // 2
        (half + 1).upto(w - 1) do |mx|
          view.chrome_hit(rect, mx, rect.y + 3).should be_nil
        end
      end
    end
  end

  it "keeps the hex preview for a compressed response message" do
    pb_tmp_store do |store|
      view = answered.call(loaded.call(store), grpc_frame(PB_BODY, compressed: true))
      view.pretty = true
      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("(compressed)").should be_true
      backend.contains?("varint   150").should be_false
    end
  end
end
