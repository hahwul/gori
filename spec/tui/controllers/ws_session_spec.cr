require "../../spec_helper"
require "../../support/fake_host"
require "../../support/memory_backend"
require "socket"
require "digest/sha1"
require "base64"

include Gori::Tui

private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Repeater::WsEngine

# A persistent WebSocket session in the Repeater (#1630): the MESSAGES list is the composer,
# `^R` connects + keeps the socket open and sends every line, `↵` sends the cursor line, the
# TRANSCRIPT streams both directions, and disconnect / tab close / project exit spawn the
# (blocking) close off the UI fiber. Driven against a local 127.0.0.1 origin.

private WS_HANDSHAKE_CA = File.tempname("gori-ws-sess-ca")
Spec.after_suite { FileUtils.rm_rf(WS_HANDSHAKE_CA) }

# A local WS origin that upgrades, then runs `handler` with the connection. Records the
# client frames it reads and counts handshakes.
private class LiveOrigin
  getter port : Int32
  getter accepts = 0
  getter client_text = [] of String

  def initialize(&@handler : IO, LiveOrigin -> Nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn do
      while conn = @server.accept?
        @accepts += 1
        spawn serve(conn)
      end
    end
  end

  def read(conn : IO) : WS::Frame?
    frame = WS.read_frame(conn)
    @client_text << String.new(frame.payload) if frame && frame.opcode == WS::OP_TEXT
    frame
  end

  def text(conn : IO, s : String) : Nil
    conn.write(WS.encode(WS::OP_TEXT, s.to_slice, mask: false))
    conn.flush
  end

  def close : Nil
    @server.close
  end

  private def serve(tcp : TCPSocket) : Nil
    tcp.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(tcp).not_nil!
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try(&.split(':', 2)[1].strip) || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
    tcp << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
           "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    tcp.flush
    @handler.call(tcp, self)
  rescue
  ensure
    tcp.close rescue nil
  end
end

# Echo each text as `re:<text>`; on `push` send two unprompted messages; answer PING and CLOSE.
private def echo_origin : LiveOrigin
  LiveOrigin.new do |conn, o|
    while frame = o.read(conn)
      case frame.opcode
      when WS::OP_TEXT
        msg = String.new(frame.payload)
        if msg == "push"
          o.text(conn, "p1")
          o.text(conn, "p2")
        else
          o.text(conn, "re:#{msg}")
        end
      when WS::OP_PING
        conn.write(WS.encode(WS::OP_PONG, frame.payload, mask: false)); conn.flush
      when WS::OP_CLOSE
        conn.write(WS.encode(WS::OP_CLOSE, frame.payload, mask: false)); conn.flush
        break
      end
    end
  end
end

private def with_ws_controller(&)
  root = File.tempname("gori-ws-sess")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("ws-session")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(WS_HANDSHAKE_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    host.active_tab = :repeater
    yield RepeaterController.new(host), host
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# Open a WS tab pointed at `port`, seeded with `messages` in the MESSAGES composer.
private def open_ws_tab(ctl, port : Int32, messages : Array(String)) : RepeaterView
  req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
  ctl.repeater_from_request("http://127.0.0.1:#{port}", req, false, nil)
  v = ctl.current_view.not_nil!
  v.restore("http://127.0.0.1:#{port}", req, false, true,
    ws_messages: messages.map { |m| Gori::Store::WsOutMessage.text(m) })
  v.focus_pane(:request)
  v
end

private def wait_until(timeout = 3.seconds, &) : Bool
  deadline = Time.instant + timeout
  until yield
    return false if Time.instant > deadline
    sleep 1.millisecond
  end
  true
end

# Connect and wait for the socket to open (^R while keep-open is armed).
private def connect!(ctl, v : RepeaterView) : Nil
  ctl.repeater_toggle_ws_session # arm keep-open
  v.ws_keep_open?.should be_true
  ctl.repeater_send # ^R → connect
  wait_until { ctl.drain_results; v.ws_connected? }.should be_true
end

describe "RepeaterController WebSocket live session (#1630)" do
  it "connects, sends two lines on one handshake, and streams a server push between them" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["hello", "push"])
        connect!(ctl, v)

        ctl.repeater_send # ^R sends ALL lines in order on the open socket
        # hello → re:hello, then push → p1,p2 — all on the one handshake.
        wait_until { ctl.drain_results; origin.client_text.size >= 2 && v.ws_session.not_nil!.transcript.count { |e| e.message.direction == "in" } >= 3 }.should be_true

        origin.accepts.should eq(1) # no re-dial
        origin.client_text.should eq(["hello", "push"])
        ins = v.ws_session.not_nil!.transcript.select { |e| e.message.direction == "in" }.map { |e| String.new(e.message.payload) }
        ins.should contain("re:hello")
        ins.should contain("p1")
        ins.should contain("p2")
      end
    ensure
      origin.close
    end
  end

  it "sends only the cursor line on ↵" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["first", "second"])
        connect!(ctl, v)
        v.ws_cursor_message.should eq({0, "first"})

        ctl.repeater_ws_send_cursor
        wait_until { ctl.drain_results; origin.client_text == ["first"] }.should be_true
        v.ws_sent_mark(0).should_not be_nil
        v.ws_sent_mark(1).should be_nil
      end
    ensure
      origin.close
    end
  end

  it "disconnects without blocking the UI fiber" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["x"])
        connect!(ctl, v)
        s = v.ws_session.not_nil!

        ctl.repeater_toggle_ws_session # OFF → spawn close
        v.ws_keep_open?.should be_false
        wait_until { s.closed? }.should be_true
        v.ws_session.should be(s) # the view keeps the reference so the close reason stays up
      end
    ensure
      origin.close
    end
  end

  it "closes the session when the tab is closed" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["x"])
        connect!(ctl, v)
        s = v.ws_session.not_nil!

        ctl.request_close # ^W (FakeHost confirms inline)
        wait_until { s.closed? }.should be_true
        ctl.current_view.should be_nil
      end
    ensure
      origin.close
    end
  end

  it "closes every live session on a project-level exit (stop_all)" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["x"])
        connect!(ctl, v)
        s = v.ws_session.not_nil!

        ctl.stop_all
        wait_until { s.closed? }.should be_true
        v.ws_session.should be_nil # the reference is dropped — the tab is being torn down
      end
    ensure
      origin.close
    end
  end

  it "goes back to the scripted send after a live session (keeps nothing stale)" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["hello"])
        connect!(ctl, v)
        ctl.repeater_ws_send_cursor
        wait_until { ctl.drain_results; origin.client_text == ["hello"] }.should be_true

        ctl.repeater_toggle_ws_session # o OFF → disconnect
        v.ws_keep_open?.should be_false
        wait_until { v.ws_session.not_nil!.closed? }.should be_true

        # ^R now takes the scripted one-shot path, which clears the stale live session (so the
        # scripted transcript is what shows) and re-dials → origin.accepts == 2.
        ctl.repeater_send
        wait_until(5.seconds) { ctl.drain_results; origin.accepts == 2 && !v.ws_session_active? }.should be_true
        v.ws_session.should be_nil
      end
    ensure
      origin.close
    end
  end

  it "closes the live session when the transport is switched off WebSocket (^V)" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["x"])
        connect!(ctl, v)
        s = v.ws_session.not_nil!

        ctl.repeater_toggle_http2 # ^V: WS → HTTP/1.1, leaves WS mode
        v.ws_mode?.should be_false
        v.ws_keep_open?.should be_false # disarmed, so the tick stops overwriting the status
        wait_until { s.closed? }.should be_true
      end
    ensure
      origin.close
    end
  end

  it "does not install a session when keep-open is turned off mid-connect" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["x"])
        ctl.repeater_toggle_ws_session # arm keep-open
        ctl.repeater_send              # ^R → spawn the connect
        v.toggle_ws_keep_open          # turn it OFF before the drain installs the session
        v.ws_keep_open?.should be_false

        # The dial completes, the drain sees keep-open off and closes it instead of installing.
        wait_until(5.seconds) { ctl.drain_results; !v.inflight? }.should be_true
        v.ws_session.should be_nil
        v.ws_connected?.should be_false
      end
    ensure
      origin.close
    end
  end

  it "tracks two concurrent connects and drops both cancel cells by identity" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        va = open_ws_tab(ctl, origin.port, ["a"]) # tab A is current
        ctl.repeater_toggle_ws_session            # arm keep-open on A
        ctl.repeater_send                         # ^R → spawn connect A (in flight)

        vb = open_ws_tab(ctl, origin.port, ["b"]) # tab B becomes current
        ctl.repeater_toggle_ws_session            # arm keep-open on B
        ctl.repeater_send                         # ^R → spawn connect B (in flight)

        ctl.ws_pending_connects.should eq(2) # both cells tracked before any drain

        wait_until(5.seconds) { ctl.drain_results; va.ws_connected? && vb.ws_connected? }.should be_true
        ctl.ws_pending_connects.should eq(0) # both dropped — neither removed the other's cell
      end
    ensure
      origin.close
    end
  end

  it "renders only on the active tab and throttles the live tick" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, host|
        v = open_ws_tab(ctl, origin.port, ["hi"])
        connect!(ctl, v)

        # Off the Repeater tab, the controller's drain does NOT tick the view (only the reader
        # fiber fills the ring), so the rendered seq stays behind what arrived.
        host.active_tab = :history
        s = v.ws_session.not_nil!
        ctl.repeater_ws_send_cursor
        wait_until { ctl.drain_results; s.transcript.any? { |e| e.message.direction == "in" } }.should be_true

        now = Time.instant
        v.ws_live_tick(now).should be_true  # the ring grew while the tab was away
        v.ws_live_tick(now).should be_false # same instant → throttled
      end
    ensure
      origin.close
    end
  end

  it "draws the live layout: ● LIVE / ● open titles and a ss.mmm → transcript" do
    origin = echo_origin
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, ["hi"])
        v.menu_registry = Gori::Verbs.registry
        connect!(ctl, v)
        ctl.repeater_ws_send_cursor
        wait_until { ctl.drain_results; v.ws_session.not_nil!.transcript.any? { |e| e.message.direction == "in" } }.should be_true
        v.ws_live_tick # fold the new rows into the cached transcript

        b = MemoryBackend.new(120, 32)
        v.render(Screen.new(b), Gori::Tui::Rect.new(0, 0, 120, 32))
        b.contains?("● LIVE").should be_true    # MESSAGES composer title
        b.contains?("● open").should be_true    # TRANSCRIPT title
        b.contains?("→ text hi").should be_true # the operator's sent line
        b.contains?("← text re:hi").should be_true
        b.contains?("✓ ").should be_true # the sent-row mark on the MESSAGES line
      end
    ensure
      origin.close
    end
  end

  it "answers the Engine.IO heartbeat when the preset is on" do
    # Push `2` right after the upgrade; the session answers `3` for the operator (a TEXT frame,
    # which the origin records in `client_text`).
    origin = LiveOrigin.new do |conn, o|
      o.text(conn, "2")
      while frame = o.read(conn)
        break if frame.opcode == WS::OP_CLOSE
      end
    end
    begin
      with_ws_controller do |ctl, _host|
        v = open_ws_tab(ctl, origin.port, [] of String)
        ctl.repeater_toggle_ws_heartbeat
        v.ws_heartbeat?.should be_true
        connect!(ctl, v)

        wait_until { ctl.drain_results; origin.client_text.includes?("3") }.should be_true
      end
    ensure
      origin.close
    end
  end
end
