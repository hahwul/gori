require "../../spec_helper"
require "socket"
require "digest/sha1"
require "base64"
require "json"

private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Repeater::WsEngine
private alias WsSession = Gori::Repeater::WsSession

private WS_UPGRADE_REQ = ("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                          "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                          "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").to_slice

private class CliWsTestOrigin
  getter port : Int32
  getter frames = [] of WS::Frame

  def initialize(@status : Int32 = 101, @bad_accept : Bool = false, &@handler : IO, CliWsTestOrigin -> Nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn do
      while conn = @server.accept?
        spawn serve(conn)
      end
    end
  end

  def read(conn : IO) : WS::Frame?
    WS.read_frame(conn).tap { |f| @frames << f if f }
  end

  def text(conn : IO, s : String) : Nil
    conn.write(WS.encode(WS::OP_TEXT, s.to_slice, mask: false))
    conn.flush
  end

  def bin(conn : IO, b : Bytes) : Nil
    conn.write(WS.encode(WS::OP_BIN, b, mask: false))
    conn.flush
  end

  def close : Nil
    @server.close
  end

  private def serve(tcp : TCPSocket) : Nil
    tcp.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(tcp).not_nil!
    if @status != 101
      tcp << "HTTP/1.1 #{@status} Forbidden\r\nContent-Length: 0\r\n\r\n"
      tcp.flush
      return
    end
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try(&.split(':', 2)[1].strip) || ""
    accept = @bad_accept ? "wrong-accept" : Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
    tcp << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
           "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    tcp.flush
    @handler.call(tcp, self)
  rescue
  ensure
    tcp.close rescue nil
  end
end

private def cli_ws_echo_origin(initial_push : String? = nil, *,
                               status : Int32 = 101, bad_accept : Bool = false) : CliWsTestOrigin
  CliWsTestOrigin.new(status, bad_accept) do |conn, o|
    o.text(conn, initial_push) if initial_push
    while frame = o.read(conn)
      case frame.opcode
      when WS::OP_TEXT
        o.text(conn, "echo:#{String.new(frame.payload)}")
      when WS::OP_BIN
        o.bin(conn, frame.payload)
      when WS::OP_CLOSE
        conn.write(WS.encode(WS::OP_CLOSE, frame.payload, mask: false))
        conn.flush
        break
      end
    end
  end
end

private def with_store(& : Gori::Store, Gori::Project ->) : Nil
  path = File.tempname("gori-spec", ".db")
  store = Gori::Store.open(path)
  prev_env = Gori::Settings.project_env_vars
  prev_layer = Gori::Env.layer
  raised = run_capturing { yield store, Gori::Project.new("ws-test", path) }
  Gori::Env.layer = prev_layer
  Gori::Settings.project_env_vars = prev_env
  Gori::Env.bump_highlight_rev
  store.close
  delete_db_files(path)
  raise raised if raised
end

private def insert_ws_repeater(store : Gori::Store, port : Int32, *,
                               target : String? = nil,
                               request : Bytes = WS_UPGRADE_REQ,
                               ws_http_only : Bool = false) : Int64
  store.insert_repeater(
    target: target || "http://127.0.0.1:#{port}",
    request: request,
    http2: false,
    auto_cl: true,
    flow_id: nil,
    position: 1,
    ws_http_only: ws_http_only
  )
end

describe "gori run repeater ws (#1660)" do
  describe "CLI::Run.ws_parse_auto_reply" do
    it "parses MATCH=REPLY pairs and preserves '=' in the reply" do
      Gori::CLI::Run.ws_parse_auto_reply("PING=PONG")
        .should eq(WsSession::AutoReply.new("PING", "PONG"))
      Gori::CLI::Run.ws_parse_auto_reply("k=a=b")
        .should eq(WsSession::AutoReply.new("k", "a=b"))
      Gori::CLI::Run.ws_parse_auto_reply("PING=")
        .should eq(WsSession::AutoReply.new("PING", ""))
    end

    it "refuses a missing '=' or an empty MATCH" do
      Gori::CLI::Run.ws_parse_auto_reply("PING").as(String)
        .should contain("expected MATCH=REPLY")
      Gori::CLI::Run.ws_parse_auto_reply("=PONG").as(String)
        .should contain("expected MATCH=REPLY")
    end
  end

  describe "CLI::Run.ws_parse_hex_line" do
    it "decodes hex lines with or without a 0x prefix" do
      Gori::CLI::Run.ws_parse_hex_line("deadbeef").should eq(Bytes[0xde, 0xad, 0xbe, 0xef])
      Gori::CLI::Run.ws_parse_hex_line("  0x0102  ").should eq(Bytes[0x01, 0x02])
      Gori::CLI::Run.ws_parse_hex_line("").should eq(Bytes.empty)
    end

    it "refuses odd-length or non-hex input" do
      Gori::CLI::Run.ws_parse_hex_line("abc").as(String).should contain("invalid hex line")
      Gori::CLI::Run.ws_parse_hex_line("zzzz").as(String).should contain("invalid hex line")
    end
  end

  describe "CLI::Run.open_and_run_ws_session" do
    it "streams text frames from stdin, prints the transcript, and sends CLOSE on EOF" do
      origin = cli_ws_echo_origin
      begin
        with_store do |store, project|
          id = insert_ws_repeater(store, origin.port)
          stdin = IO::Memory.new("hello\nworld\n")
          stdout = IO::Memory.new
          stderr = IO::Memory.new

          ok, err = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, stdin: stdin, stdout: stdout, stderr: stderr)
          err.should be_nil
          ok.should be_true

          stderr.to_s.should contain("→ WebSocket upgraded=true")
          lines = stdout.to_s.lines
          lines.should contain("→ hello")
          lines.should contain("← echo:hello")
          lines.should contain("→ world")
          lines.should contain("← echo:world")
          lines.any?(&.includes?("[CLOSE] code 1000")).should be_true
          origin.frames.any?(&.close?).should be_true
        end
      ensure
        origin.close
      end
    end

    it "emits one JSON line per frame under --format json with MCP get_job's row shape and prints handshake notes to stderr" do
      origin = cli_ws_echo_origin(bad_accept: true)
      begin
        with_store do |store, project|
          id = insert_ws_repeater(store, origin.port)
          stdin = IO::Memory.new("ping-one\n")
          stdout = IO::Memory.new
          stderr = IO::Memory.new

          ok, err = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, format: :json, stdin: stdin, stdout: stdout, stderr: stderr)
          err.should be_nil
          ok.should be_true
          stderr.to_s.should contain("note: handshake accept mismatch")

          rows = stdout.to_s.lines.reject(&.empty?).map { |l| JSON.parse(l) }
          rows.size.should be >= 3

          out_row = rows.find { |r| r["direction"].as_s == "out" && r["type"].as_s == "text" }.not_nil!
          out_row["seq"].as_i64.should be >= 1
          out_row["opcode"].as_i.should eq(1)
          out_row["origin"].as_s.should eq("client")
          out_row["frame"].as_s.should eq("TEXT")
          out_row["payload"].as_s.should eq("ping-one")

          in_row = rows.find { |r| r["direction"].as_s == "in" && r["type"].as_s == "text" }.not_nil!
          in_row["opcode"].as_i.should eq(1)
          in_row["origin"].as_s.should eq("target")
          in_row["frame"].as_s.should eq("TEXT")
          in_row["payload"].as_s.should eq("echo:ping-one")

          close_row = rows.find { |r| r["type"].as_s == "close" }.not_nil!
          close_row["opcode"].as_i.should eq(8)
          close_row["close_code"].as_i.should eq(1000)
        end
      ensure
        origin.close
      end
    end

    it "keeps the session open past stdin EOF when --for is set and prints a server push sent ~1s later" do
      close_elapsed : Time::Span? = nil
      origin = CliWsTestOrigin.new do |conn, o|
        started = Time.instant
        if frame = o.read(conn)
          o.text(conn, "ack:#{String.new(frame.payload)}")
        end
        spawn do
          sleep 900.milliseconds
          o.text(conn, "late-push") rescue nil
        end
        while frame = o.read(conn)
          if frame.close?
            close_elapsed = Time.instant - started
            conn.write(WS.encode(WS::OP_CLOSE, frame.payload, mask: false))
            conn.flush
            break
          end
        end
      end
      begin
        with_store do |store, project|
          id = insert_ws_repeater(store, origin.port)
          stdin = IO::Memory.new("sub\n")
          stdout = IO::Memory.new
          stderr = IO::Memory.new

          started = Time.instant
          ok, err = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, duration: 2.seconds,
            stdin: stdin, stdout: stdout, stderr: stderr)
          elapsed = Time.instant - started
          err.should be_nil
          ok.should be_true
          out = stdout.to_s
          out.should contain("→ sub")
          out.should contain("← ack:sub")
          out.should contain("← late-push")
          origin.frames.any?(&.close?).should be_true
          close_elapsed.not_nil!.should be >= 1.5.seconds
          elapsed.should be >= 1.8.seconds
        end
      ensure
        origin.close
      end
    end

    it "stops cleanly and sends CLOSE when the cancel proc fires" do
      origin = cli_ws_echo_origin(initial_push: "hello-live")
      r_in, w_in = IO.pipe
      begin
        with_store do |store, project|
          id = insert_ws_repeater(store, origin.port)
          stdout = IO::Memory.new
          stderr = IO::Memory.new
          cancelled = false

          spawn do
            sleep 80.milliseconds
            cancelled = true
          end

          ok, err = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, stdin: r_in, stdout: stdout, stderr: stderr,
            cancel: -> { cancelled })
          err.should be_nil
          ok.should be_true
          stdout.to_s.should contain("← hello-live")
          origin.frames.any?(&.close?).should be_true
        end
      ensure
        w_in.close rescue nil
        r_in.close rescue nil
        origin.close
      end
    end

    it "sends hex-decoded BINARY frames under --binary and flags invalid hex lines" do
      origin = cli_ws_echo_origin
      begin
        with_store do |store, project|
          id = insert_ws_repeater(store, origin.port)
          stdin = IO::Memory.new("0xdeadbeef\n")
          stdout = IO::Memory.new
          stderr = IO::Memory.new

          ok, err = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, binary: true, format: :json,
            stdin: stdin, stdout: stdout, stderr: stderr)
          err.should be_nil
          ok.should be_true

          rows = stdout.to_s.lines.reject(&.empty?).map { |l| JSON.parse(l) }
          bin_in = rows.find { |r| r["direction"].as_s == "in" && r["type"].as_s == "binary" }.not_nil!
          bin_in["binary"].as_bool.should be_true
          Base64.decode(bin_in["payload_base64"].as_s).should eq(Bytes[0xde, 0xad, 0xbe, 0xef])

          # Invalid hex line reports on stderr and returns ok=false.
          bad_in = IO::Memory.new("not-hex\n")
          bad_out = IO::Memory.new
          bad_err = IO::Memory.new
          ok2, err2 = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, binary: true,
            stdin: bad_in, stdout: bad_out, stderr: bad_err)
          err2.should be_nil
          ok2.should be_false
          bad_err.to_s.should contain("invalid hex line")
        end
      ensure
        origin.close
      end
    end

    it "answers server heartbeats via --auto-reply and --engine-io and marks auto_reply in JSON" do
      origin = CliWsTestOrigin.new do |conn, o|
        o.text(conn, "2")
        o.text(conn, "PING")
        while frame = o.read(conn)
          if frame.close?
            conn.write(WS.encode(WS::OP_CLOSE, frame.payload, mask: false))
            conn.flush
            break
          end
        end
      end
      begin
        with_store do |store, project|
          id = insert_ws_repeater(store, origin.port)
          r_in, w_in = IO.pipe
          stdout = IO::Memory.new
          stderr = IO::Memory.new
          rules = [
            WsSession::ENGINE_IO_HEARTBEAT,
            WsSession::AutoReply.new("PING", "PONG"),
          ]

          spawn do
            sleep 80.milliseconds
            w_in.close
          end

          ok, err = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, auto_replies: rules, format: :json,
            stdin: r_in, stdout: stdout, stderr: stderr)
          r_in.close rescue nil
          err.should be_nil
          ok.should be_true

          rows = stdout.to_s.lines.reject(&.empty?).map { |l| JSON.parse(l) }
          auto_rows = rows.select { |r| r["auto_reply"]?.try(&.as_bool?) == true }
          auto_rows.map(&.["payload"].as_s).should eq(["3", "PONG"])
        end
      ensure
        origin.close
      end
    end

    it "expands tokens in stdin text frames unless --verbatim is passed" do
      origin = cli_ws_echo_origin
      begin
        with_store do |store, project|
          Gori::Env.save_project(store, [{"WS_TOK", "expanded-val"}]).should be_true
          id = insert_ws_repeater(store, origin.port)

          out_exp = IO::Memory.new
          ok1, err1 = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, stdin: IO::Memory.new("msg:$WS_TOK\n"),
            stdout: out_exp, stderr: IO::Memory.new)
          err1.should be_nil
          ok1.should be_true
          out_exp.to_s.should contain("← echo:msg:expanded-val")

          out_verb = IO::Memory.new
          ok2, err2 = Gori::CLI::Run.open_and_run_ws_session(id, project,
            allow_unscoped: true, verbatim: true, stdin: IO::Memory.new("msg:$WS_TOK\n"),
            stdout: out_verb, stderr: IO::Memory.new)
          err2.should be_nil
          ok2.should be_true
          out_verb.to_s.should contain("← echo:msg:$WS_TOK")
        end
      ensure
        origin.close
      end
    end

    it "refuses missing, non-WebSocket, ws_http_only, RFC 8441, unresolved-token, and non-101 sessions" do
      refusing_origin = cli_ws_echo_origin(status: 403)
      begin
        with_store do |store, project|
          ok, err = Gori::CLI::Run.open_and_run_ws_session(999_i64, project)
          ok.should be_false
          err.should eq("gori run repeater ws: no repeater session #999")

          http_id = insert_ws_repeater(store, 80,
            request: "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice)
          ok, err = Gori::CLI::Run.open_and_run_ws_session(http_id, project)
          ok.should be_false
          err.not_nil!.should contain("is not a WebSocket handshake")

          http_only_id = insert_ws_repeater(store, 80, ws_http_only: true)
          ok, err = Gori::CLI::Run.open_and_run_ws_session(http_only_id, project)
          ok.should be_false
          err.not_nil!.should contain("ws_http_only")

          rfc8441_req = ("CONNECT /ws HTTP/2\r\nHost: 127.0.0.1\r\n" \
                         "X-Gori-Protocol: websocket\r\nSec-WebSocket-Version: 13\r\n\r\n").to_slice
          h2_id = insert_ws_repeater(store, 80, request: rfc8441_req)
          ok, err = Gori::CLI::Run.open_and_run_ws_session(h2_id, project)
          ok.should be_false
          err.not_nil!.should contain("RFC 8441 extended CONNECT")

          unresolved_id = insert_ws_repeater(store, refusing_origin.port,
            target: "http://$UNSET_WS_HOST:#{refusing_origin.port}")
          ok, err = Gori::CLI::Run.open_and_run_ws_session(unresolved_id, project, allow_unscoped: true)
          ok.should be_false
          err.not_nil!.should contain("UNSET_WS_HOST")

          refused_id = insert_ws_repeater(store, refusing_origin.port)
          ok, err = Gori::CLI::Run.open_and_run_ws_session(refused_id, project, allow_unscoped: true)
          ok.should be_false
          err.not_nil!.should contain("status 403")
        end
      ensure
        refusing_origin.close
      end
    end
  end
end
