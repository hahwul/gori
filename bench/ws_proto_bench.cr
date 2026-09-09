# WebSocket subprotocol decode, over a whole transcript.
#
# This is the shape that makes the cost interesting: the WS-protocol pane is a display-time
# projection with no table behind it, so a 101 detail left OPEN over a live socket re-decodes
# the whole windowed transcript (`DETAIL_LOG_CAP` = 10,000 frames) every time it gains a row.
# Two passes run per rebuild — the enablement sniff, which offers every frame to all five
# decoders, and the decode itself, which offers it only to the enabled ones.
#
# The number to watch is the NEGATIVE case: a busy socket carrying a framing gori has no
# decoder for still pays the sniff on every frame, so every decoder has to answer "not mine"
# from BYTES — a leading digit (`SocketIo`), a trailing 0x1e (`SignalR`), a NUL scan (`Stomp`),
# a frame letter (`SockJs`), a key needle (`ActionCable`). Those land at 1-90ns a frame. Two
# things cost four orders of magnitude more, and this harness is what found both:
#
#   * A LOOSE gate. `ActionCable` first admitted any `{`-leading frame carrying a `type`, so a
#     4 KiB chat message paid a String copy and a JSON parse per frame: 42µs each, 180ms and
#     37.7 MB to rebuild one pane. Admitting on `identifier` (or, for a short frame, one of the
#     three lifecycle values) took the same transcript to 9.5ms and 160 B.
#   * A RAISED parse. `JSON.parse` on a frame that merely opens like JSON throws, and a throw
#     is ~10µs — 10,000× the byte checks around it. A SignalR record is `{…}` plus a trailing
#     0x1e, so `ActionCable` threw on every frame of a SignalR transcript: 46ms a rebuild,
#     755µs once each reader asserted its closing/opening byte instead.
#
# For reference, `GraphqlWs.from_messages` over the same 4 KiB window costs 22ms.
#
# Build: crystal build bench/ws_proto_bench.cr -o bin/ws_proto_bench --release
require "benchmark"

# `store/models` reaches the decoder chain, which declares its error class against this one.
# Same stub `decoder_bench.cr` carries, and for the same reason: a harness requires a leaf,
# not the whole binary.
module Gori
  class Error < Exception; end
end

require "../src/gori/ws_proto"

include Gori

RS  = "\u{1e}"
NUL = "\u{0}"

FRAMES = 10_000 # DETAIL_LOG_CAP — the window the TUI pane rebuilds from

def transcript(&block : Int32 -> String) : Array(Store::WsMessage)
  Array.new(FRAMES) do |i|
    Store::WsMessage.new(i.to_i64, 1_i64, nil, 0_i64, i.even? ? "out" : "in", 1,
      block.call(i).to_slice)
  end
end

SOCKETIO = transcript { |i| %(42["chat message",{"room":"general","seq":#{i}}]) }
SIGNALR  = transcript { |i| %({"type":1,"invocationId":"#{i}","target":"SendMessage","arguments":["a","hi"]}) + RS }
STOMP    = transcript { |i| "SEND\ndestination:/app/chat\ncontent-type:application/json\n\n" + %({"seq":#{i}}) + NUL }
SOCKJS   = transcript { |i| "a" + [%(42["chat",{"seq":#{i}}])].to_json }
CABLE    = transcript { |i| {"command" => "message", "identifier" => %({"channel":"ChatChannel"}), "data" => %({"action":"speak","seq":#{i}})}.to_json }

# The negative cases — what the sniff costs a transcript nothing here decodes.
PLAIN  = transcript { |i| %({"type":"chat","user":"alice","text":"message number #{i}"}) }
GQL_WS = transcript { |i| %({"id":"#{i}","type":"next","payload":{"data":{"messageAdded":{"id":#{i}}}}}) }
BULKY  = transcript { |i| %({"type":"chat","text":") + ("x" * 4096) + %(","seq":#{i}"}) }

puts "#{FRAMES} frames per transcript\n\n"

Benchmark.ips do |x|
  x.report("socket.io") { WsProto.from_messages(SOCKETIO) }
  x.report("signalr") { WsProto.from_messages(SIGNALR) }
  x.report("stomp") { WsProto.from_messages(STOMP) }
  x.report("sockjs→socket.io") { WsProto.from_messages(SOCKJS) }
  x.report("action cable") { WsProto.from_messages(CABLE) }
  x.report("(none) plain json") { WsProto.from_messages(PLAIN) }
  x.report("(none) graphql-ws") { WsProto.from_messages(GQL_WS) }
  x.report("(none) 4KiB frames") { WsProto.from_messages(BULKY) }
end
