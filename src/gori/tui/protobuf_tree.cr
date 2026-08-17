require "./screen"
require "../protobuf"
require "../proxy/h2/grpc"

module Gori::Tui
  # Plain-text rendering of a `Gori::Protobuf::Message` — the schema-less wire-format tree
  # that `gori run history show --format json` and MCP `get_flow` already emit, in the shape
  # a terminal pane can show. ONE renderer for all three gRPC render sites (History detail,
  # the Repeater GRPC RESPONSE transcript, and the framing pane they share), which is the
  # decision #496 parked: three sites must not each answer it differently.
  #
  # ## Ambiguity is the content, not a defect to smooth over
  #
  # `Protobuf` reports a length-delimited field as `bytes` + `string` + `message` **coexisting
  # siblings** rather than guessing which one the absent `.proto` meant. Collapsing that into
  # one chosen line here would throw the whole design away, so a `len` field names every
  # reading that fits on its own row — `message | string | bytes` — and then shows each of
  # them. `|` reads "or": nothing on screen claims to know which is real.
  #
  # ## Rendering is bounded
  #
  # A pane is not a JSON dump. Field count, nesting depth and string/hex previews are all
  # capped, and every cut says so on a line of its own — a silently shortened tree would be a
  # worse lie than hex. The decoder's own `MAX_DEPTH` / `MAX_FIELDS` bound the PARSE; these
  # bound the DRAW, which is a different (much smaller) budget.
  module ProtobufTree
    # Rows emitted per top-level message before the render gives up and says so.
    MAX_LINES = 400

    # Nesting levels drawn. Deeper than this and a terminal pane is all indentation; the
    # decoder still walked it (to `Protobuf::MAX_DEPTH`), so the cut is named where it lands.
    MAX_RENDER_DEPTH = 8

    # Columns a `string` preview may occupy before it is cut (measured with `draw_width`, not
    # `size` — a CJK or emoji payload is twice the cells per char and would blow the pane).
    STRING_PREVIEW_COLS = 96

    # Bytes shown for a payload with no `string` and no `message` reading.
    HEX_PREVIEW_BYTES = 24

    # The one-line legend that keeps the `|` honest. Drawn once per pane, above the messages —
    # not once per field, where it would be noise.
    NOTE = "— protobuf decoded from the wire (no .proto): a length-delimited field lists every reading that fits — none is authoritative —"

    # Whether a framed gRPC message's payload gets the tree. The two carve-outs the headless
    # surfaces make (`cli/run/history.cr`, `mcp/serialize.cr`) are made ONCE, here, so the two
    # TUI sites cannot answer them differently: a TRAILER frame is ASCII headers, not
    # protobuf, and a COMPRESSED payload is not protobuf until something inflates it — the
    # 0x01 flag says so, and `grpc-encoding` names the codec, not gori. Both take the hex exit.
    def self.decode?(m : Proxy::H2::Grpc::Message, tree : Bool) : Bool
      tree && !m.trailer && !m.compressed
    end

    # Whether `NOTE` belongs above `msgs`: only when a tree will actually be drawn. A body of
    # nothing but trailers and compressed frames gets no tree, so it gets no explanation of one.
    def self.legend?(msgs : Array(Proxy::H2::Grpc::Message), tree : Bool) : Bool
      msgs.any? { |m| decode?(m, tree) }
    end

    # Render `msg` as indented rows. `indent` prefixes every row, so a caller can nest the
    # tree under its own "▸ message #N" header.
    def self.lines(msg : Protobuf::Message, indent : String = "  ") : Array(String)
      acc = [] of String
      emit_message(acc, msg, indent, 0)
      acc
    end

    private def self.emit_message(acc : Array(String), msg : Protobuf::Message,
                                  indent : String, depth : Int32) : Nil
      if msg.fields.empty?
        acc << "#{indent}(no fields)"
      else
        msg.fields.each do |f|
          if acc.size >= MAX_LINES
            acc << "#{indent}… (render cut at #{MAX_LINES} lines)"
            return
          end
          emit_field(acc, f, indent, depth)
        end
      end
      # `complete: false` is the decoder saying it stopped mid-field — a truncated capture, a
      # length that overran, an illegal wire type. The fields above it are still real; what is
      # NOT real is the impression that they are all of them.
      acc << "#{indent}⚠ truncated — the rest of these bytes are not valid protobuf" unless msg.complete
    end

    private def self.emit_field(acc : Array(String), f : Protobuf::Field,
                                indent : String, depth : Int32) : Nil
      case f.wire
      in .varint?
        acc << "#{indent}#{f.number}  varint   #{f.uint || 0}"
      in .fixed64?
        # The RAW BITS, as the headless surfaces emit them. Without a `.proto` there is
        # nothing saying whether they are a double, an sfixed64 or a packed pair.
        acc << "#{indent}#{f.number}  fixed64  #{f.uint || 0}"
      in .fixed32?
        acc << "#{indent}#{f.number}  fixed32  #{f.uint || 0}"
      in .start_group?
        acc << "#{indent}#{f.number}  group    (deprecated wire type — interior skipped)"
      in .end_group?
        acc << "#{indent}#{f.number}  end_group"
      in .length_delimited?
        emit_length_field(acc, f, indent, depth)
      end
    end

    private def self.emit_length_field(acc : Array(String), f : Protobuf::Field,
                                       indent : String, depth : Int32) : Nil
      bytes = f.bytes || Bytes.empty
      # An empty payload reads as a valid empty message AND a valid empty string AND zero
      # bytes. Listing three readings of nothing is noise, not honesty.
      if bytes.empty?
        acc << "#{indent}#{f.number}  len 0b   (empty)"
        return
      end
      acc << "#{indent}#{f.number}  len #{bytes.size}b  #{readings(f)}"
      inner = "#{indent}   "
      if m = f.message
        if depth + 1 >= MAX_RENDER_DEPTH
          acc << "#{inner}message: … (#{m.fields.size} field#{m.fields.size == 1 ? "" : "s"} — deeper than this pane draws)"
        else
          acc << "#{inner}message:"
          emit_message(acc, m, "#{inner}  ", depth + 1)
        end
      end
      if s = f.string
        acc << "#{inner}string: #{preview(s)}"
      end
      # Only when nothing structured fit: the raw octets are one keypress away (the hex view)
      # for every other field, and repeating them under each one would bury the tree.
      acc << "#{inner}bytes: #{hex(bytes)}" if f.message.nil? && f.string.nil?
    end

    # Every interpretation the decoder attached, most-structured first. `bytes` is always in
    # the list because the raw octets are always a legal reading of the same payload — that is
    # what makes this an ambiguity report rather than a guess.
    private def self.readings(f : Protobuf::Field) : String
      parts = [] of String
      parts << "message" if f.message
      parts << "string" if f.string
      parts << "bytes"
      parts.join(" | ")
    end

    # A `string` reading, escaped (control bytes become `\u…`, so nothing in a captured
    # payload can move the terminal's cursor) and cut to a fixed CELL budget.
    private def self.preview(s : String) : String
      shown = s.inspect
      return shown if Screen.draw_width_upto(shown, STRING_PREVIEW_COLS + 1) <= STRING_PREVIEW_COLS
      cut = String.build do |io|
        w = 0
        shown.each_grapheme do |g|
          gs = g.to_s
          gw = Screen.grapheme_cols(gs)
          break if w + gw > STRING_PREVIEW_COLS - 1
          io << gs
          w += gw
        end
      end
      "#{cut}…"
    end

    private def self.hex(data : Bytes) : String
      shown = data[0, {data.size, HEX_PREVIEW_BYTES}.min]
      s = shown.map(&.to_s(16).rjust(2, '0')).join(' ')
      data.size > HEX_PREVIEW_BYTES ? "#{s} … (+#{data.size - HEX_PREVIEW_BYTES})" : s
    end
  end
end
