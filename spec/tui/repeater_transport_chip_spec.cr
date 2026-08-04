require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `^V` picks the transport `^R` dials — h1 ⇄ h2 on an ordinary tab, and (since the WebSocket
# override landed) WS → h1 → h2 → WS on a tab holding a handshake. Nothing on screen said so:
# the key was discoverable only from the footer of one pane in one mode, so a tab that could be
# asked three different questions looked like a tab that could be asked one.
#
# The ` ^V:… ` chip fixes that, and it rides the TARGET band rather than the REQUEST border on
# purpose: the request border is a HALF-width column that already carries ^R:SEND, ^L:CL,
# ^U:PRETTY and the NOR/INS chip, and a fifth badge there pushes the mode chip past `min_x` on a
# 100-column terminal — the badge chain drops its leftmost first. The TARGET band is full width
# and already holds the other "how do we connect" facts (the URL, the SNI override).
describe "RepeaterView transport chip" do
  ws_head = "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 13\r\n\r\n"

  render = ->(view : RepeaterView, rect : Rect) {
    b = MemoryBackend.new(rect.w, rect.h)
    view.render(Screen.new(b), rect)
    b
  }

  describe "an ordinary HTTP tab" do
    it "names the transport and cycles it on a click" do
      view = RepeaterView.new
      view.load_blank
      rect = Rect.new(0, 0, 100, 24)
      b = render.call(view, rect)

      row = b.row(rect.y)
      row.should contain("^V:h1")
      col = row.index("^V:h1").not_nil!
      view.chrome_hit(rect, col + 1, rect.y).should eq(:transport)

      view.toggle_http2.should be_true
      render.call(view, rect).row(rect.y).should contain("^V:h2")
    end

    # The reason the chip is not on the REQUEST border: at 100 columns the request column is 49
    # wide, and SEND+CL+PRETTY+NOR already fill it to within 3 cells of the card title.
    #
    # h2 is the case that pins the title cleanup: the card used to be titled "REQUEST (h2)",
    # and those five columns moved `min_x` far enough right that the chain dropped its leftmost
    # badge — the mode chip — on exactly this terminal. The transport lives on the band now, so
    # the title is "REQUEST" in both states and the chip survives in both.
    it "leaves the request border's own badges alone, in h1 and h2 alike" do
      view = RepeaterView.new
      view.load_blank
      rect = Rect.new(0, 0, 100, 24)
      border_y = rect.y + 3 # below the 3-row TARGET band

      row = render.call(view, rect).row(border_y)
      row.should contain("^R:SEND")
      row.should contain("↵:NOR")
      row.should_not contain("^V:")

      view.toggle_http2
      row2 = render.call(view, rect).row(border_y)
      row2.should contain("REQUEST")
      row2.should_not contain("(h2)")
      row2.should contain("↵:NOR")
    end

    # The chip reports state, not on/off: its NAME is the state, so `toggle_badge`'s muted-grey
    # "off" dress would read as a disabled control. At rest it is a filled chip; an override
    # wears the ^R:SEND gold.
    it "draws a filled chip at rest and the gold one while overridden" do
      view = RepeaterView.new
      view.load_blank
      rect = Rect.new(0, 0, 100, 24)
      b = render.call(view, rect)
      col = b.row(rect.y).index("^V:h1").not_nil!
      b.bg_at(col, rect.y).should eq(Theme.accent_bg)
      b.bg_at(col, rect.y).should_not eq(Theme.bg)
    end
  end

  describe "a WebSocket tab" do
    it "cycles WS → h1 → h2 → WS and lights while overridden" do
      view = RepeaterView.new
      view.restore("https://ws.test", ws_head, false, true,
        ws_messages: [Gori::Store::WsOutMessage.text("hello")])
      rect = Rect.new(0, 0, 100, 30)

      render.call(view, rect).row(rect.y).should contain("^V:WS")
      view.transport_badge_lit?.should be_false # WS is the DETECTED transport, not an override

      # Both ends, not just the destination: the request card is titled REQUEST once the
      # override is on, so this chip is the only text left saying the tab holds a handshake.
      view.cycle_ws_transport
      render.call(view, rect).row(rect.y).should contain("^V:WS→h1")
      view.transport_badge_lit?.should be_true # …h1 on a handshake tab is the operator's call

      view.cycle_ws_transport
      render.call(view, rect).row(rect.y).should contain("^V:WS→h2")

      view.cycle_ws_transport
      render.call(view, rect).row(rect.y).should contain("^V:WS")
      view.transport_badge_lit?.should be_false
    end

    it "wears the gold while the handshake is going out as plain HTTP" do
      view = RepeaterView.new
      view.restore("https://ws.test", ws_head, false, true,
        ws_messages: [Gori::Store::WsOutMessage.text("hello")])
      rect = Rect.new(0, 0, 100, 30)

      b = render.call(view, rect)
      ws_col = b.row(rect.y).index("^V:WS").not_nil!
      b.bg_at(ws_col, rect.y).should eq(Theme.accent_bg) # detected transport: the resting fill

      view.cycle_ws_transport
      b2 = render.call(view, rect)
      h1_col = b2.row(rect.y).index("^V:WS→h1").not_nil!
      b2.bg_at(h1_col, rect.y).should eq(Theme.focus_gold) # an override interrupts the glance
    end

    it "hit-tests the chip in both WS and overridden-HTTP shapes" do
      view = RepeaterView.new
      view.restore("https://ws.test", ws_head, false, true,
        ws_messages: [Gori::Store::WsOutMessage.text("hello")])
      rect = Rect.new(0, 0, 100, 30)

      b = render.call(view, rect)
      col = b.row(rect.y).index("^V:WS").not_nil!
      view.chrome_hit(rect, col + 1, rect.y).should eq(:transport)

      view.cycle_ws_transport # the pane geometry changes here; the TARGET band does not
      b2 = render.call(view, rect)
      row = b2.row(rect.y)
      col2 = row.index("^V:WS→h1").not_nil!
      view.chrome_hit(rect, col2 + 1, rect.y).should eq(:transport)
      # The wider label must not run into its neighbour: the last cell of the chip still
      # hit-tests as the chip, and the cell after it does not. `→` measures one column.
      view.chrome_hit(rect, col2 + "^V:WS→h1".size, rect.y).should eq(:transport)
      view.chrome_hit(rect, col2 + "^V:WS→h1".size + 1, rect.y).should_not eq(:transport)
    end
  end

  describe "a gRPC tab" do
    # gRPC rides h2 by specification and `repeater_toggle_http2` refuses it. A chip drawn where
    # the key does nothing is worse than no chip, so this mode gets none — and nothing may
    # hit-test as `:transport` across the whole band either.
    it "draws no chip, because ^V refuses there" do
      path = File.tempname("gori-transport", ".db")
      store = Gori::Store.open(path)
      begin
        head = "POST /svc/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
          method: "POST", target: "/svc/M", http_version: "HTTP/2",
          head: head.to_slice, body: Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41]))
        view = RepeaterView.new
        view.load_grpc(store.get_flow(id).not_nil!)
        rect = Rect.new(0, 0, 100, 24)

        render.call(view, rect).row(rect.y).should_not contain("^V:")
        (0...100).each { |x| view.chrome_hit(rect, x, rect.y).should_not eq(:transport) }
      ensure
        store.close
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end
  end

  # The SNI marker used to position itself at `right - " SNI ".size - 1`, which is INSIDE the
  # NOR/INS chip's cells and drawn after it: setting an override painted over the chip's right
  # five columns. Chaining the band's chrome — mode, then SNI, then ^V — is what makes room for
  # the transport chip, and it fixes this at the same time.
  it "keeps the SNI marker, the mode chip and the transport chip on separate cells" do
    view = RepeaterView.new
    view.restore("https://api.test/x", "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n", false, true,
      sni: "other.test")
    rect = Rect.new(0, 0, 100, 24)
    row = render.call(view, rect).row(rect.y)

    row.should contain("↵:NOR")
    row.should contain("SNI")
    row.should contain("^V:h1")
    row.index("^V:h1").not_nil!.should be < row.index("SNI").not_nil!
    row.index("SNI").not_nil!.should be < row.index("↵:NOR").not_nil!
  end
end
