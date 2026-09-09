require "./ws_proto/frame"
require "./ws_proto/socketio"
require "./ws_proto/signalr"
require "./ws_proto/stomp"
require "./ws_proto/sockjs"
require "./ws_proto/action_cable"
require "./store/models"

module Gori
  module WsProto
    extend self

    # Detection order. Only matters where two decoders could both claim a payload, which the
    # envelopes are chosen to prevent — a `0x1e` terminator, a NUL terminator, a leading digit,
    # a leading frame letter and a JSON object are disjoint — so this is the tie-break of last
    # resort, most-specific first.
    PROTOCOLS = [SignalR::NAME, Stomp::NAME, SocketIo::NAME, SockJs::NAME, ActionCable::NAME]

    # The decoded records a transcript carries, in transcript order. Empty ⇒ no pane.
    #
    # `subprotocols` is the handshake's negotiated `Sec-WebSocket-Protocol`, and it is a HINT
    # ONLY — the `GraphqlWs` lesson, one protocol family over. It can switch a decoder on for a
    # transcript whose every frame is weak (a STOMP session that only ever heartbeats), and it
    # can never make a frame decode as something its bytes do not say: the payload is always
    # the authority. A server that echoes `actioncable-v1-json` over a socket carrying
    # something else therefore costs a failed parse, not a wrong pane.
    def from_messages(msgs : Array(Store::WsMessage),
                      subprotocols : Array(String)? = nil) : Array(Frame)
      enabled = enabled_protocols(msgs, subprotocols)
      return [] of Frame if enabled.empty?
      frames = [] of Frame
      msgs.each_with_index do |m, i|
        break if frames.size >= MAX_FRAMES
        next unless decodable?(m)
        records = decode_frame(m.payload, enabled) || next
        records.each do |(protocol, d, via)|
          break if frames.size >= MAX_FRAMES
          frames << Frame.new(i + 1, m.direction, protocol, d.kind, d.name, d.id, d.note,
            d.payload, via)
        end
      end
      frames
    end

    # Which decoders this transcript has EARNED. A protocol is enabled by one unmistakable
    # frame (see `Decoded#strong`) or by the handshake naming it — never by a frame that is
    # merely consistent with it. Without this pass a one-character `h` heartbeat would light
    # up the SockJS pane on any socket that sends the letter h, and a chat protocol sending
    # `2` as a text frame would be reported as Socket.IO.
    private def enabled_protocols(msgs : Array(Store::WsMessage),
                                  subprotocols : Array(String)?) : Array(String)
      strong = Set(String).new
      examined = 0
      msgs.each do |m|
        break if examined >= MAX_EXAMINE || strong.size == PROTOCOLS.size
        next unless decodable?(m)
        examined += 1
        sniff(m.payload, strong, unwrap: true)
      end
      hinted = hinted_protocols(subprotocols)
      PROTOCOLS.select { |p| strong.includes?(p) || hinted.includes?(p) }
    end

    # Record every protocol that reads `payload` unmistakably. `unwrap` follows a SockJS
    # envelope one layer down, because the protocol SockJS carries is the one an operator came
    # for and its strong frames only ever appear inside the wrapper.
    private def sniff(payload : Bytes, strong : Set(String), *, unwrap : Bool) : Nil
      PROTOCOLS.each do |p|
        next if strong.includes?(p) && !(unwrap && p == SockJs::NAME)
        records = decode_with(p, payload) || next
        strong << p if records.any?(&.strong)
        next unless unwrap && p == SockJs::NAME
        records.each do |d|
          inner = d.payload || next
          sniff(inner.to_slice, strong, unwrap: false)
        end
      end
    end

    # The first enabled decoder that reads the frame, as {protocol, record, via} triples.
    private def decode_frame(payload : Bytes,
                             enabled : Array(String)) : Array({String, Decoded, String?})?
      enabled.each do |p|
        records = decode_with(p, payload) || next
        return expand_sockjs(records, enabled) if p == SockJs::NAME
        return records.map { |d| {p, d, nil.as(String?)} }
      end
      nil
    end

    # A SockJS message frame carries another protocol's frame as a JSON string. Hand each
    # unwrapped message to the other enabled decoders and report the winner as itself, tagged
    # with the wrapper it arrived in; a message nothing claims stays a SockJS message, showing
    # the unwrapped text — which is still strictly more than the raw `a["…\"…\"…"]` said.
    private def expand_sockjs(records : Array(Decoded),
                              enabled : Array(String)) : Array({String, Decoded, String?})
      out = [] of {String, Decoded, String?}
      records.each do |d|
        inner = d.payload
        if inner && d.kind == "message"
          if got = decode_inner(inner.to_slice, enabled)
            got.each { |(p, id)| out << {p, id, SockJs::NAME} }
            next
          end
        end
        out << {SockJs::NAME, d, nil.as(String?)}
      end
      out
    end

    private def decode_inner(payload : Bytes,
                             enabled : Array(String)) : Array({String, Decoded})?
      enabled.each do |p|
        next if p == SockJs::NAME # a SockJS frame never wraps another SockJS frame
        records = decode_with(p, payload) || next
        return records.map { |d| {p, d} }
      end
      nil
    end

    private def decode_with(protocol : String, payload : Bytes) : Array(Decoded)?
      case protocol
      when SignalR::NAME     then SignalR.decode(payload)
      when Stomp::NAME       then Stomp.decode(payload)
      when SocketIo::NAME    then SocketIo.decode(payload)
      when SockJs::NAME      then SockJs.decode(payload)
      when ActionCable::NAME then ActionCable.decode(payload)
      end
    end

    private def hinted_protocols(subprotocols : Array(String)?) : Array(String)
      subs = subprotocols
      return [] of String if subs.nil? || subs.empty?
      PROTOCOLS.select do |p|
        subs.any? do |s|
          case p
          when SignalR::NAME     then SignalR.hinted?(s)
          when Stomp::NAME       then Stomp.hinted?(s)
          when SocketIo::NAME    then SocketIo.hinted?(s)
          when SockJs::NAME      then SockJs.hinted?(s)
          when ActionCable::NAME then ActionCable.hinted?(s)
          else                        false
          end
        end
      end
    end

    # TEXT frames only, and never a `notice?` row: those are gori's own prose ABOUT the socket
    # (the handshake advisory, the ping-flood marker), not a frame a peer sent — decoding one
    # would report gori's diagnostics as the application's traffic.
    private def decodable?(m : Store::WsMessage) : Bool
      m.text? && !m.notice? && !m.payload.empty? && m.payload.size <= MAX_FRAME
    end

    # The `Sec-WebSocket-Protocol` tokens the handshake carries, folded and de-duplicated.
    # Both heads are read: the request OFFERS a list and the 101 response names the one the
    # server accepted, and a capture may hold either side alone.
    def subprotocols(*heads : Bytes?) : Array(String)
      out = [] of String
      heads.each do |head|
        h = head || next
        String.new(h).scrub.each_line do |raw|
          line = raw.chomp
          break if line.empty? # the blank line ends the head
          idx = line.index(':') || next
          next unless line[0, idx].strip.compare("sec-websocket-protocol", case_insensitive: true) == 0
          line[(idx + 1)..].split(',') do |tok|
            t = tok.strip.downcase
            out << t unless t.empty? || out.includes?(t)
          end
        end
      end
      out
    end

    def label(protocol : String) : String
      case protocol
      when SignalR::NAME     then SignalR::LABEL
      when Stomp::NAME       then Stomp::LABEL
      when SocketIo::NAME    then SocketIo::LABEL
      when SockJs::NAME      then SockJs::LABEL
      when ActionCable::NAME then ActionCable::LABEL
      else                        protocol
      end
    end

    # The protocol a pane should NAME itself after: the one that read the most records, ties
    # broken by `PROTOCOLS` order.
    #
    # SockJS is excluded while anything else is present, and NOT as a tie-break: it is a
    # wrapper, and its `o`/`h`/`c` lifecycle frames routinely outnumber the messages it
    # carries — a session that opened, heartbeat twice, closed and sent one STOMP frame is a
    # STOMP session, and a chip reading SOCKJS names the shim instead of the protocol the
    # operator is working in. Counting alone got that backwards.
    def primary(frames : Array(Frame)) : String?
      return nil if frames.empty?
      counts = Hash(String, Int32).new(0)
      frames.each { |f| counts[f.protocol] += 1 }
      carried = PROTOCOLS.select { |p| p != SockJs::NAME && counts.has_key?(p) }
      candidates = carried.empty? ? [SockJs::NAME] : carried
      best = candidates.max_of { |p| counts[p] }
      candidates.find { |p| counts[p] == best }
    end

    # The distinct protocols present, in `PROTOCOLS` order.
    def protocols(frames : Array(Frame)) : Array(String)
      seen = frames.map(&.protocol).to_set
      PROTOCOLS.select { |p| seen.includes?(p) }
    end

    # The one-line header for a decoded record: who sent it, which frame it came out of, and
    # every name the envelope carries. One spelling, so the TUI pane, `gori run show` and a
    # copied line all read identically.
    def header(f : Frame) : String
      String.build do |io|
        io << (f.direction == "out" ? "→" : "←")
        io << " frame #" << f.index << ' ' << f.protocol
        f.via.try { |v| io << " via " << v }
        io << ' ' << f.kind
        f.name.try { |n| io << ' ' << n }
        f.id.try { |v| io << " id=" << v }
        f.note.try { |v| io << " (" << v << ')' }
      end
    end

    # The pane text: every decoded record in transcript order under its header.
    def display(frames : Array(Frame)) : String
      String.build do |io|
        frames.each_with_index do |f, i|
          io << "\n\n" if i > 0
          io << "# --- " << header(f) << " ---"
          f.payload.try { |p| io << '\n' << p }
        end
      end
    end

    # A one-line summary for a pane header / CLI section title.
    def summary(frames : Array(Frame)) : String
      labels = protocols(frames).map { |p| label(p) }
      names = frames.compact_map(&.name).uniq!
      s = "#{frames.size} frame#{frames.size == 1 ? "" : "s"} · #{labels.join(" + ")}"
      names.empty? ? s : "#{s} · #{names.first(4).join(", ")}#{names.size > 4 ? ", …" : ""}"
    end
  end
end
