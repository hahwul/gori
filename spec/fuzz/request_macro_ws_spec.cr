require "../spec_helper"
require "socket"
require "digest/sha1"
require "base64"
require "../support/macro_origin"

private alias F = Gori::Fuzz
private alias WS = Gori::Proxy::WS
private alias RM = Gori::RequestMacro

# The request-time macro on a WebSocket sweep (#1350): one variation is one full session, and
# the macro precedes each session's HANDSHAKE — that is where a per-session token travels. The
# WS origin records the `X-Token` each handshake carried; the token origin mints them.

private def start_ws_token_origin(count : Int32) : {Int32, Array(String)}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  tokens = [] of String
  spawn do
    count.times do
      break unless accepted = origin.accept?
      spawn_with(accepted) do |conn|
        conn.read_timeout = 5.seconds
        head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
        text = String.new(head)
        tokens << (text.each_line.find(&.downcase.starts_with?("x-token:")).try(&.split(':', 2).[1].strip) || "")
        key = text.each_line.find(&.downcase.starts_with?("sec-websocket-key:")).try(&.split(':', 2).[1].strip) || ""
        accept = Base64.strict_encode(Digest::SHA1.digest(key + Gori::Repeater::WsEngine::GUID))
        conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
        conn.flush
        while (f = WS.read_frame(conn)) && f.data?
          conn.write(WS.encode(f.opcode, f.payload, mask: false))
          conn.flush
          break
        end
        conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xe8], mask: false))
        conn.flush
        conn.close
      rescue
      end
    end
  rescue
  end
  {port, tokens}
end

describe "Fuzz request-time macro over WebSocket" do
  it "runs the steps before each session's handshake" do
    macro_origin = MacroTokenOrigin.new
    ws_port, tokens = start_ws_token_origin(3)
    with_macro_project(macro_origin) do |store, _, _|
      handshake = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{ws_port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-Token: $CSRF\r\n\r\n"
      config = F::Config.new(concurrency: 3, request_macro: RM::Spec.new(["csrf-fetch"]))
      plan = F::Plan.build(
        F::PlanOptions.new(handshake, default_target: "http://127.0.0.1:#{ws_port}",
          sources: [F::InlineList.new(["a", "b", "c"])] of F::PayloadSource,
          config: config, matcher: F::Matcher.new(keep_bodies: :all),
          ws_messages: [F::WsMessageSource.new(1, %({"q":"§term§"}))], project: store),
        ungated_outbound)
      plan.websocket?.should be_true
      plan.request_macro_info.not_nil!.concurrency.should eq(1)
      rows = [] of F::Result
      plan.engine.run { |ev| rows << ev.result if ev.is_a?(F::ResultEvent) }
      rows.size.should eq(3)
      rows.map(&.error).should eq([nil, nil, nil])
      tokens.should eq(["T1", "T2", "T3"]) # each session's handshake carried a value of its own
      macro_origin.forms.should eq(3)
    end
    macro_origin.close
  end

  it "does not open a session for a candidate the macro failed" do
    macro_origin = MacroTokenOrigin.new
    macro_origin.form_status = 500
    ws_port, tokens = start_ws_token_origin(3)
    with_macro_project(macro_origin) do |store, _, _|
      handshake = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{ws_port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-Token: $CSRF\r\n\r\n"
      config = F::Config.new(concurrency: 1, request_macro: RM::Spec.new(["csrf-fetch"], on_failure: RM::OnFailure::Stop))
      plan = F::Plan.build(
        F::PlanOptions.new(handshake, default_target: "http://127.0.0.1:#{ws_port}",
          sources: [F::InlineList.new(["a", "b", "c"])] of F::PayloadSource,
          config: config, matcher: F::Matcher.new(keep_bodies: :all),
          ws_messages: [F::WsMessageSource.new(1, %({"q":"§term§"}))], project: store),
        ungated_outbound)
      rows = [] of F::Result
      errors = [] of String
      plan.engine.run do |ev|
        rows << ev.result if ev.is_a?(F::ResultEvent)
        errors << ev.message if ev.is_a?(F::ErrorEvent)
      end
      rows.size.should eq(1)
      rows.first.error.not_nil!.should start_with(RM::ERROR_PREFIX)
      errors.first.should contain("stop the run on a failure")
      tokens.should be_empty
    end
    macro_origin.close
  end
end
