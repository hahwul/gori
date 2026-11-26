require "../spec_helper"
require "socket"

# A plain HTTP server that answers every request with `prompt` at once and then `drip` one byte
# every `gap`: each byte lands inside the client's read timeout, so only a whole-exchange
# ceiling ends it.
#
# `tls: true` answers the ClientHello instead, with a handshake record header that promises
# 16000 bytes and then the bytes one by one: a TLS handshake dripped the same way.
private def with_dripping_server(prompt : String, drip : String, gap : Time::Span,
                                 tls : Bool = false, &)
  server = TCPServer.new("127.0.0.1", 0)
  spawn do
    while raw = server.accept?
      if tls
        spawn drip_handshake(raw, gap)
      else
        spawn drip_response(raw, prompt, drip, gap)
      end
    end
  rescue
  end
  begin
    yield server.local_address.port
  ensure
    server.close rescue nil
  end
end

private def drip_response(conn : TCPSocket, prompt : String, drip : String, gap : Time::Span) : Nil
  conn.read_timeout = 5.seconds
  while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
  end
  conn << prompt
  conn.flush
  drip.each_byte do |byte|
    sleep gap
    conn.write_byte(byte)
    conn.flush
  end
rescue
ensure
  conn.close rescue nil
end

private def drip_handshake(conn : TCPSocket, gap : Time::Span) : Nil
  conn.read_timeout = 5.seconds
  conn.read(Bytes.new(4096)) # the ClientHello
  conn.write(Bytes[0x16, 0x03, 0x03, 0x3e, 0x80])
  conn.flush
  loop do
    sleep gap
    conn.write_byte(0_u8)
    conn.flush
  end
rescue
ensure
  conn.close rescue nil
end

describe Gori::Oast::HttpClient do
  it "turns URI parser failures into a provider error" do
    client = Gori::Oast::HttpClient.new

    ["http://oast.test:abc/", "http://oast.test:99999999999/"].each do |url|
      expect_raises(Gori::Error, /OAST: invalid URL/) do
        client.request("GET", url)
      end
    end
  end

  # MCP runs every tool on one fiber, so a collector that drips its poll answer stalled every
  # later tool call for as long as the drip lasted: TIMEOUT is per read, MAX_BODY counts bytes.
  # 40 bytes 100 ms apart is 4 s against a 1 s ceiling.
  {
    "head" => {"HTTP/1.1 200 OK\r\n", "X-Slow: #{"a" * 22}\r\nContent-Length: 2\r\n\r\nok"},
    "body" => {"HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n", "b" * 40},
  }.each do |phase, (prompt, drip)|
    it "ends an exchange whose #{phase} is dripped at the whole-exchange ceiling" do
      with_dripping_server(prompt, drip, 100.milliseconds) do |port|
        started = Time.instant
        err = expect_raises(Gori::Oast::ExchangeError) do
          Gori::Oast::HttpClient.new(1.second).request("GET", "http://127.0.0.1:#{port}/poll")
        end
        (Time.instant - started).should be < 3.seconds
        err.message.not_nil!.should contain("did not finish within 1.0s")
      end
    end
  end

  # The handshake's own ceiling is 3 x TIMEOUT; the exchange's deadline has to reach it, or a
  # collector dripping its handshake holds the tool fiber past the budget the error names.
  it "ends a dripped TLS handshake at the whole-exchange ceiling" do
    with_dripping_server("", "", 100.milliseconds, tls: true) do |port|
      started = Time.instant
      err = expect_raises(Gori::Oast::ExchangeError) do
        Gori::Oast::HttpClient.new(1.second).request("GET", "https://127.0.0.1:#{port}/poll")
      end
      (Time.instant - started).should be < 3.seconds
      err.message.not_nil!.should contain("did not finish within 1.0s")
    end
  end
end
