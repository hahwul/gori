require "./spec_helper"
require "socket"

private def reset_http_transport_proxy : Nil
  Gori::Settings.upstream_rules = [] of Gori::Settings::UpstreamRule
  Gori::Settings.upstream_proxy = ""
  Gori::Settings.project_upstream_proxy = nil
  Gori::Settings.project_upstream_destination = nil
end

# A one-shot SOCKS5 tunnel whose far side is a tiny HTTP origin. The hostname is deliberately
# not resolvable locally; receiving it as ATYP DOMAIN is proof the target lookup stayed remote.
private def with_socks_http_response(body : String, &)
  server = TCPServer.new("127.0.0.1", 0)
  seen = Channel({UInt8, String, String}).new(1)
  spawn do
    conn = server.accept
    greeting = Bytes.new(2)
    conn.read_fully(greeting)
    conn.read_fully(Bytes.new(greeting[1].to_i))
    conn.write(Bytes[5_u8, 0_u8])
    request = Bytes.new(4)
    conn.read_fully(request)
    len = Bytes.new(1)
    conn.read_fully(len)
    host_bytes = Bytes.new(len[0].to_i)
    conn.read_fully(host_bytes)
    port = Bytes.new(2)
    conn.read_fully(port)
    conn.write(Bytes[5_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    conn.flush
    head = String::Builder.new
    while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
      head << line << "\n"
    end
    seen.send({request[3], String.new(host_bytes), head.to_s})
    conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    conn.flush
    conn.close rescue nil
  rescue
  end
  begin
    yield server.local_address.port, seen
  ensure
    server.close rescue nil
  end
end

describe Gori::HttpTransport do
  it "performs HTTP over scalar SOCKS5H with proxy-side DNS and the correct Host header" do
    with_socks_http_response("ok") do |port, seen|
      Gori::Settings.upstream_proxy = "socks5h://127.0.0.1:#{port}"
      uri = URI.parse("http://remote-only.invalid/resource")
      client = Gori::HttpTransport.client(uri)
      begin
        client.get(uri.request_target).body.should eq("ok")
      ensure
        client.close
      end
      atyp, host, head = seen.receive
      atyp.should eq(3_u8)
      host.should eq("remote-only.invalid")
      head.should contain("Host: remote-only.invalid")
    end
  ensure
    reset_http_transport_proxy
  end

  it "carries Update and OAST through the same routed client" do
    release = %({"tag_name":"v9.9.9","assets":[]})
    with_socks_http_response(release) do |port, seen|
      Gori::Settings.upstream_proxy = "socks5h://127.0.0.1:#{port}"
      Gori::Update.fetch_latest_release_json("http://updates.remote-only.invalid/latest").should eq(release)
      seen.receive[1].should eq("updates.remote-only.invalid")
    end

    with_socks_http_response("callbacks") do |port, seen|
      Gori::Settings.upstream_proxy = "socks5h://127.0.0.1:#{port}"
      response = Gori::Oast::HttpClient.new.request("GET", "http://oast.remote-only.invalid/poll")
      response.body.should eq("callbacks")
      seen.receive[1].should eq("oast.remote-only.invalid")
    end
  ensure
    reset_http_transport_proxy
  end

  it "does not fall back to the origin when the configured proxy is unreachable" do
    origin = TCPServer.new("127.0.0.1", 0)
    accepted = Channel(Nil).new(1)
    spawn do
      conn = origin.accept
      accepted.send(nil)
      conn.close
    rescue
    end
    dead = TCPServer.new("127.0.0.1", 0)
    dead_port = dead.local_address.port
    dead.close
    Gori::Settings.upstream_proxy = "socks5://127.0.0.1:#{dead_port}"

    expect_raises(Gori::HttpTransport::Error) do
      Gori::HttpTransport.client(URI.parse("http://127.0.0.1:#{origin.local_address.port}/"))
    end
    select
    when accepted.receive
      fail("origin was contacted after the proxy failed")
    when timeout(50.milliseconds)
    end
  ensure
    origin.try(&.close) rescue nil
    reset_http_transport_proxy
  end
end
