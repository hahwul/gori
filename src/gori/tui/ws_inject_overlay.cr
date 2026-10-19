require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../proxy/ws/live"

module Gori::Tui
  # "Inject frame…" (#1630): one frame into a WebSocket the running proxy still relays, from
  # History's drill-in. A dumb form on the Overlay seam: the inject itself is the open-site's
  # `on_commit` (Runner#inject_ws_frame), which reads `direction`, `opcode` and `payload`.
  #   ↑/↓  field (direction → opcode → payload → Inject)
  #   ←/→  cycle direction or opcode on its row
  #   ↵    injects from any row · esc cancels
  class WsInjectOverlay < FormOverlay
    DIRECTIONS = ["client → server", "server → client"]
    # Every kind MCP `ws_inject` and `gori run intercept inject` take, from the one table.
    KINDS = Proxy::WS::Live::OPCODES.keys
    # The kinds whose payload is typed as hex: a binary frame's, and a close's, whose payload
    # opens with a 2-byte status code (`03e8` is 1000, RFC 6455 §5.5.1) that text cannot spell.
    HEX_KINDS = {"binary", "close"}

    getter flow_id : Int64

    def initialize(@flow_id : Int64)
      @dir_idx = 0
      @kind_idx = 0
      @payload = TextField.new("") # rows: 0 direction · 1 opcode · 2 payload · 3 inject
    end

    def direction : String
      @dir_idx == 0 ? "out" : "in"
    end

    def opcode : UInt8
      Proxy::WS::Live::OPCODES[KINDS[@kind_idx]]
    end

    # The bytes to send, or nil when a hex payload is not hex: a binary or close frame takes
    # hex, the way the Repeater's live session reads a line it sends as binary. Taken as typed
    # (P7): a close code gori would not send itself, or a 1-byte payload, still goes out.
    def payload : Bytes?
      text = @payload.value
      hex? ? RepeaterView.ws_hex(text) : text.to_slice
    end

    private def hex? : Bool
      HEX_KINDS.includes?(KINDS[@kind_idx])
    end

    # Send the frame through the engine the bridge drain uses (`Live.inject`: Layer 2 on the
    # socket's host, one budget slot) and answer the toast for it. Blocks for up to
    # `Live::BOUNDARY_WAIT`, so the shell calls it on a fiber of its own.
    def inject(sink : Proxy::FlowSink, outbound : Outbound, bytes : Bytes) : {String, Symbol}
      if refusal = Proxy::WS::Live.inject(sink, @flow_id, direction, opcode, bytes, outbound)
        return {"inject refused: #{refusal}", :error}
      end
      side = Proxy::WS::Live.side(direction)
      {"injected #{KINDS[@kind_idx].upcase} #{bytes.size}B #{side} on flow ##{@flow_id}", :done}
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::WsInject
    end

    def title : String
      "INJECT"
    end

    def text_fields : Array(TextField)
      [@payload]
    end

    def hint : String
      "↑/↓ field · ←/→ options · type payload · ↵ inject · esc cancel"
    end

    def row_count : Int32
      4
    end

    def preview? : Bool
      true
    end

    def adjust(d : Int32) : Nil
      case @sel
      when 0 then @dir_idx = (@dir_idx + d) % DIRECTIONS.size
      when 1 then @kind_idx = (@kind_idx + d) % KINDS.size
      end
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :commit if key.enter?
      return :stay if field_nav?(ev)
      @sel == 2 ? @payload.handle_edit_key(ev) : off_payload_key(ev)
      :stay
    end

    # A key on the direction, opcode or Inject row.
    private def off_payload_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.left? || key.right? || key.space?
        # Space cycles here as on every option row: falling through to the payload below put a
        # ' ' the operator never typed on the wire (P7).
        adjust(key.left? ? -1 : 1) if @sel < 2
      elsif (ch = ev.char) && ch.printable? && !ev.ctrl? && !ev.alt?
        # The form opens on direction, and the footer says "type payload": a printable typed
        # on another row lands in the payload instead of being dropped.
        @sel = 2
        @payload.insert(ch)
      end
    end

    private def text_field_for(row : Int32) : TextField?
      row == 2 ? @payload : nil
    end

    def card_title : String
      "INJECT FRAME · ##{@flow_id} · open socket"
    end

    def too_small_what : String
      "inject form needs a larger window"
    end

    def draw_row_body(screen : Screen, box : Rect, i : Int32, py : Int32,
                      x : Int32, bg : Color, fg : Color, sel : Bool) : Nil
      right = box.right - 2
      case i
      when 0 then Frame.option_cycle(screen, x, py, right, bg, "direction:", DIRECTIONS, @dir_idx, sel, value_x: x + 11)
      when 1 then Frame.option_cycle(screen, x, py, right, bg, "opcode:", KINDS, @kind_idx, sel, value_x: x + 11)
      when 2
        screen.text(x, py, "payload:", Theme.muted, bg)
        @payload.render(screen, x + 11, py, {right - x - 11, 3}.max, sel, fg, bg)
      else
        ok = !payload.nil?
        label = ok ? inject_label : "[ #{hex_hint} ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold, width: {right - x, 0}.max)
      end
    end

    # The close code the hex spells, beside the button: `1000` typed as hex is 4096.
    private def inject_label : String
      bytes = payload
      return "[ ↵ inject ]" unless KINDS[@kind_idx] == "close" && bytes && bytes.size >= 2
      "[ ↵ inject · close code #{(bytes[0].to_i << 8) | bytes[1].to_i} ]"
    end

    # Why `payload` is nil: the form's button row and the shell's refusal both say it.
    def hex_hint : String
      return "a close frame takes hex bytes: a status code, then a reason (e.g. 03e8)" if KINDS[@kind_idx] == "close"
      "a binary frame takes hex bytes (e.g. 48656c6c6f)"
    end

    private def draw_tail(screen : Screen, box : Rect, first : Int32) : Nil
      y = box.bottom - 2
      return unless y > first
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.panel)
      screen.text(box.x + 2, y, "waits for a message boundary (≤#{Proxy::WS::Live.span(Proxy::WS::Live::BOUNDARY_WAIT)}) · no Match & Replace",
        Theme.muted, Theme.panel, width: box.w - 4)
    end
  end
end
