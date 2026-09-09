require "./spec_helper"

private alias WP = Gori::WsProto

private RS  = "\u{1e}"
private NUL = "\u{0}"

private def frame(payload : String, direction = "out", opcode = 1) : Gori::Store::WsMessage
  Gori::Store::WsMessage.new(0_i64, 1_i64, nil, 0_i64, direction, opcode, payload.to_slice)
end

private def decode(payloads : Array(String), subprotocols : Array(String)? = nil) : Array(WP::Frame)
  WP.from_messages(payloads.map { |p| frame(p) }, subprotocols)
end

# One WebSocket message carrying one SockJS `a` array of `inner`.
private def sockjs(*inner : String) : String
  "a" + inner.to_a.to_json
end

# gori decoded exactly one WebSocket subprotocol — GraphQL-over-WS — and every other
# real-time framing rode raw: a Socket.IO event as `42["chat",{…}]`, a SignalR hub invocation
# as an 0x1e-terminated blob, a STOMP frame as a text lump. Those envelopes carry the names
# the interesting work is done on (event enumeration, hub-method authorization), so the
# operator was reading them by eye on the one tool built to read framings for them.
describe Gori::WsProto do
  describe "Socket.IO" do
    it "reads an event's name and arguments out of the stacked envelopes" do
      fs = decode([%(42["chat message",{"room":"general","body":"hi"}])])
      fs.size.should eq(1)
      fs[0].protocol.should eq("socketio")
      fs[0].kind.should eq("event")
      fs[0].name.should eq("chat message")
      fs[0].payload.should eq(%([{"room":"general","body":"hi"}]))
    end

    # `[<attachments>-][<namespace>,][<ack id>]` are all optional and all run together in
    # front of the JSON, so the parse is a strict left-to-right consume or nothing.
    it "consumes the namespace and the ack id in front of the payload" do
      fs = decode([%(42/admin,3["ban",{"user":7}])])
      fs[0].name.should eq("ban")
      fs[0].id.should eq("3")
      fs[0].note.should eq("ns=/admin")
      fs[0].payload.should eq(%([{"user":7}]))
    end

    it "reads a binary event's attachment count" do
      fs = decode([%(451-["upload",{"_placeholder":true,"num":0}])])
      fs[0].kind.should eq("binary_event")
      fs[0].name.should eq("upload")
      fs[0].note.should eq("attachments=1")
    end

    it "reads the Engine.IO handshake and the transport frames around the events" do
      fs = decode([%(0{"sid":"lv_VI97","pingInterval":25000}), "2", "3", "40", "41"])
      fs.map(&.kind).should eq(["open", "ping", "pong", "connect", "disconnect"])
      fs[0].id.should eq("lv_VI97")
    end

    # A `2` heartbeat is ONE ASCII digit. A chat app that sends numeric ids as text frames
    # would light up the Socket.IO pane on every one of them, so a weak frame may never
    # enable the decoder by itself — only an unmistakable envelope can.
    it "does not claim a transcript whose only Socket.IO-shaped frames are bare digits" do
      decode(["2", "3", "40", "41", %({"type":"chat","text":"2"})]).should be_empty
    end

    it "falls through rather than guessing when the digits lead nowhere" do
      WP::SocketIo.decode("42".to_slice).should be_nil         # EVENT with no array
      WP::SocketIo.decode("4200".to_slice).should be_nil       # …nor after an ack id
      WP::SocketIo.decode(%(42{"a":1}).to_slice).should be_nil # an object is not an event
      WP::SocketIo.decode("7".to_slice).should be_nil          # no such Engine.IO type
      WP::SocketIo.decode("2hello".to_slice).should be_nil     # ping carries nothing but "probe"
    end
  end

  describe "SignalR" do
    it "reads a hub invocation's target and arguments" do
      fs = decode([%({"type":1,"invocationId":"0","target":"SendMessage","arguments":["a","hi"]}) + RS])
      fs[0].protocol.should eq("signalr")
      fs[0].kind.should eq("invocation")
      fs[0].name.should eq("SendMessage")
      fs[0].id.should eq("0")
      fs[0].payload.should eq(%(["a","hi"]))
    end

    it "reads the handshake and the lifecycle records" do
      fs = decode([
        %({"protocol":"json","version":1}) + RS,
        "{}" + RS,
        %({"type":6}) + RS,
        %({"type":3,"invocationId":"0","error":"nope"}) + RS,
        %({"type":7,"error":"boom"}) + RS,
      ])
      fs.map(&.kind).should eq(["handshake", "handshake_response", "ping", "completion", "close"])
      fs[0].note.should eq("json v1")
      fs[3].note.should eq("nope")
    end

    # One frame, several records — the separator TERMINATES each, so a reader that treated the
    # frame as one document would see only the first invocation of a batch.
    it "splits the records one frame packs behind the separator" do
      fs = decode([%({"type":1,"target":"A","arguments":[]}) + RS + %({"type":1,"target":"B","arguments":[]}) + RS])
      fs.map(&.name).should eq(["A", "B"])
      fs.map(&.index).should eq([1, 1]) # both point back at the one frame they came out of
    end

    it "requires the record separator, so ordinary JSON is not a hub message" do
      WP::SignalR.decode(%({"type":1,"target":"A","arguments":[]}).to_slice).should be_nil
      decode([%({"type":1,"target":"A","arguments":[]})]).should be_empty
    end
  end

  describe "STOMP" do
    it "reads the command, headers, destination and body" do
      fs = decode(["SEND\ndestination:/app/chat\ncontent-type:application/json\n\n" +
                   %({"body":"hi"}) + NUL])
      fs[0].protocol.should eq("stomp")
      fs[0].kind.should eq("SEND")
      fs[0].name.should eq("/app/chat")
      fs[0].payload.should eq("destination: /app/chat\ncontent-type: application/json\n\n" + %({"body":"hi"}))
    end

    # `id`, `receipt-id` and `message-id` are different claims; a bare number in the pane
    # would flatten them into one.
    it "names which header the correlation id came from" do
      fs = decode(["SUBSCRIBE\nid:sub-0\ndestination:/topic/x\n\n" + NUL,
                   "MESSAGE\nsubscription:sub-0\nmessage-id:7\ndestination:/topic/x\n\nhi" + NUL])
      fs[0].id.should eq("sub-0")
      fs[0].note.should be_nil # a plain `id` needs no qualifier
      fs[1].id.should eq("7")
      fs[1].note.should eq("message-id")
    end

    it "unescapes 1.2 header values but leaves CONNECT alone, as the spec requires" do
      decode(["ERROR\nmessage:Access\\cdenied\n\n" + NUL])[0].payload.should eq("message: Access:denied")
      decode(["CONNECT\npasscode:a\\cb\n\n" + NUL,
              "SEND\ndestination:/x\n\n" + NUL])[0].payload.should eq("passcode: a\\cb")
    end

    it "requires the NUL terminator, so an uppercase word is not a frame" do
      WP::Stomp.decode("SEND\ndestination:/app/chat\n\nhi".to_slice).should be_nil
      WP::Stomp.decode("SENDING\ndestination:/x\n\n#{NUL}".to_slice).should be_nil
      WP::Stomp.decode("SEND\ndestination:/x\n\nhi#{NUL}trailing".to_slice).should be_nil
    end

    # A bare EOL is real STOMP traffic but could be any protocol's whitespace, so on its own
    # it decodes nothing — until the handshake names the subprotocol, which is exactly what a
    # hint is for.
    it "decodes a heartbeat-only session only when the handshake named STOMP" do
      decode(["\n", "\n"]).should be_empty
      fs = decode(["\n", "\n"], ["v12.stomp"])
      fs.map(&.kind).should eq(["heartbeat", "heartbeat"])
    end
  end

  describe "SockJS" do
    # SockJS's whole job is wrapping another protocol, so decoding only the envelope would
    # tell the operator nothing the raw frame did not already say.
    it "unwraps the array and hands each message to the protocol inside it" do
      fs = decode(["o", sockjs(%(42["chat",{"body":"hi"}])), "h"])
      fs.map(&.protocol).should eq(["sockjs", "socketio", "sockjs"])
      fs[1].via.should eq("sockjs")
      fs[1].name.should eq("chat")
      fs[1].index.should eq(2) # still pointing at the frame it arrived in
    end

    it "unwraps every message a batched frame carries" do
      fs = decode([sockjs("SEND\ndestination:/a\n\n" + NUL, "SEND\ndestination:/b\n\n" + NUL)])
      fs.map(&.name).should eq(["/a", "/b"])
      fs.map(&.protocol).uniq!.should eq(["stomp"])
    end

    # An inner payload nothing claims is still worth showing UNWRAPPED — `a["…\"…\"…"]` is
    # the one form the raw MESSAGES pane renders unreadably.
    it "keeps a message no decoder claims, as an unwrapped SockJS message" do
      fs = decode([sockjs(%(42["chat",{}])), sockjs("just some text")])
      fs[1].protocol.should eq("sockjs")
      fs[1].kind.should eq("message")
      fs[1].payload.should eq("just some text")
      fs[1].via.should be_nil
    end

    it "reads the close frame's code and reason" do
      fs = decode([sockjs(%(42["chat",{}])), %(c[3000,"Go away!"])])
      fs[1].kind.should eq("close")
      fs[1].id.should eq("3000")
      fs[1].note.should eq("Go away!")
    end

    # `o` and `h` are one ASCII letter each.
    it "does not claim a transcript of bare letters" do
      decode(["o", "h", "h", "h"]).should be_empty
    end
  end

  describe "Action Cable" do
    # The channel and the action are both buried a layer down, inside JSON *strings* — which
    # is the whole reason the raw frame is unreadable and this pane is worth having.
    it "lifts the channel and action out of the nested JSON strings" do
      fs = decode([
        {"command" => "subscribe", "identifier" => %({"channel":"ChatChannel","room":"1"})}.to_json,
        {"command" => "message", "identifier" => %({"channel":"ChatChannel"}),
         "data" => %({"action":"speak","message":"hi"})}.to_json,
      ])
      fs[0].protocol.should eq("action_cable")
      fs[0].kind.should eq("subscribe")
      fs[0].name.should eq("ChatChannel")
      # The identifier's OTHER params stay visible: the room id in it is what an IDOR test moves.
      fs[0].payload.should eq(%({"channel":"ChatChannel","room":"1"}))
      fs[1].name.should eq("ChatChannel#speak")
      fs[1].payload.not_nil!.should contain(%("action":"speak"))
    end

    it "reads the server's lifecycle frames and broadcasts" do
      fs = decode([
        %({"type":"welcome"}),
        %({"type":"confirm_subscription","identifier":"{\\"channel\\":\\"ChatChannel\\"}"}),
        %({"identifier":"{\\"channel\\":\\"ChatChannel\\"}","message":{"body":"hi"}}),
      ])
      fs.map(&.kind).should eq(["welcome", "confirm_subscription", "broadcast"])
      fs[2].name.should eq("ChatChannel")
      fs[2].payload.not_nil!.should contain(%("body":"hi"))
    end

    # graphql-transport-ws spells its keepalive `{"type":"ping"}` too, so that shape may not
    # enable this decoder — a real Action Cable ping always carries its timestamp.
    it "does not claim a socket whose only match is a bare ping" do
      decode([%({"type":"ping"}), %({"id":"1","type":"next","payload":{}})]).should be_empty
      decode([%({"type":"ping","message":1699000000})]).map(&.kind).should eq(["ping"])
    end

    it "does not claim an unrelated JSON protocol" do
      decode([%({"type":"search","query":"shoes"}), %({"jsonrpc":"2.0","method":"x"})]).should be_empty
    end
  end

  describe "the transcript, as a whole" do
    # P7. gori's other WS lens (`GraphqlWs`) sniffs the PAYLOAD and never the negotiated name;
    # so does this one. The hint can switch a decoder on for a transcript that is all weak
    # frames, and it can never make a frame decode as something its bytes do not say.
    it "treats the negotiated subprotocol as a hint, never as the authority" do
      # A server echoing the wrong subprotocol costs a failed parse, not a wrong pane.
      decode([%({"type":"chat","text":"hello"})], ["actioncable-v1-json"]).should be_empty
      # …and a hinted decoder still yields to the framing the bytes actually carry.
      fs = decode([%(42["chat",{}])], ["v12.stomp"])
      fs.map(&.protocol).should eq(["socketio"])
    end

    it "reads the hint out of either handshake head" do
      req = "GET /cable HTTP/1.1\r\nHost: api.test\r\n" \
            "Sec-WebSocket-Protocol: actioncable-v1-json, actioncable-unsupported\r\n\r\n"
      resp = "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n"
      WP.subprotocols(req.to_slice, resp.to_slice).should eq(["actioncable-v1-json", "actioncable-unsupported"])
      WP.subprotocols(nil, resp.to_slice).should eq(["actioncable-v1-json"])
      WP.subprotocols(nil, nil).should be_empty
    end

    # gori's own prose ABOUT a socket — the handshake advisory, the ping-flood marker — is a
    # diagnostic, not traffic. Decoding one would report gori's diagnostics as the
    # application's, the same rule every repeater-seed reader follows.
    it "never decodes a notice row or a binary frame" do
      msgs = [frame(%(42["chat",{}])),
              frame(Gori::Proxy::WS::NOTICE_PREFIX + %(42["notice",{}]), "in"),
              frame(%(42["binary",{}]), "out", 2)]
      WP.from_messages(msgs).map(&.index).should eq([1])
    end

    it "leaves a GraphQL-over-WebSocket transcript to its own decoder" do
      decode([%({"type":"connection_init","payload":{}}),
              %({"id":"1","type":"subscribe","payload":{"query":"subscription { x }"}}),
              %({"type":"ping"})]).should be_empty
    end

    # The chip has to name the FRAMING an operator is working in. A SockJS transcript's
    # wrapper is not it — and counting frames gets that backwards, because a session that
    # opened, heartbeat and closed spends more frames on the shim than on its traffic.
    it "names itself after the protocol carried, never after the wrapper" do
      fs = decode(["o", sockjs(%(42["a",{}])), sockjs(%(42["b",{}])), "h"])
      WP.primary(fs).should eq("socketio")
      WP.protocols(fs).should eq(["socketio", "sockjs"])
      WP.summary(fs).should eq("4 frames · Socket.IO + SockJS · a, b")

      outnumbered = decode(["o", "h", "h",
                            sockjs("SEND\ndestination:/app/chat\n\n" + NUL),
                            %(c[3000,"bye"])])
      outnumbered.count(&.protocol.==("sockjs")).should eq(4) # the wrapper has the majority…
      WP.primary(outnumbered).should eq("stomp")              # …and still does not name the pane
    end

    it "names the wrapper only when there is nothing inside it to name" do
      fs = decode(["o", sockjs("just some text"), "h", %(c[3000,"bye"])])
      WP.primary(fs).should eq("sockjs")
    end

    it "caps the frames one transcript contributes" do
      fs = WP.from_messages(Array.new(WP::MAX_FRAMES + 50) { frame(%(42["chat",{}])) })
      fs.size.should eq(WP::MAX_FRAMES)
    end

    # A cap that just stops reads as "the frame ended here", which for a batching framing is
    # the same lie as reporting a filtered list as an empty one.
    it "says so in the pane when one frame carries more records than the cap decodes" do
      packed = String.build do |io|
        (WP::MAX_RECORDS + 5).times { |i| io << %({"type":1,"target":"m#{i}","arguments":[]}) << RS }
      end
      fs = decode([packed])
      fs.size.should eq(WP::MAX_RECORDS + 1)
      fs.last.kind.should eq("truncated")
      fs.last.note.should_not be_nil
    end

    it "skips a frame past the size cap rather than parsing it" do
      big = %(42["chat",") + ("x" * (WP::MAX_FRAME + 1)) + %("])
      decode([big, %(42["small",{}])]).map(&.name).should eq(["small"])
    end
  end
end
