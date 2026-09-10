require "./spec_helper"
require "socket"
require "openssl"

# An HTTPS origin whose leaf is signed by a CA this machine does not trust — the shape a
# TLS-inspecting corporate proxy or a private interactsh server presents to a client whose
# trust store has never heard of it (#1020).
private def with_untrusted_tls_origin(&)
  ca_cert, ca_key = Gori::Proxy::Tls::CertBuilder.build_root("gori-spec untrusted CA")
  leaf_cert, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("localhost", ca_cert, ca_key)
  ctx = Gori::Proxy::Tls::ContextFactory.server_context(leaf_cert, leaf_key,
    ca_cert: ca_cert, advertise_h2: false)
  server = TCPServer.new("127.0.0.1", 0)
  spawn do
    while raw = server.accept?
      # The CALL form, like the CONNECT-proxy fixture above: `spawn` evaluates its arguments
      # before the fiber starts, so this iteration's socket is what the fiber serves. A block
      # would capture the loop variable and close a socket the next accept has replaced.
      spawn serve_untrusted_handshake(raw, ctx)
    end
  rescue
  end
  begin
    yield server.local_address.port
  ensure
    server.close rescue nil
  end
end

# Complete the handshake and hang up. The client rejects the chain during the handshake, so
# nothing past it is ever needed — and a server that then wrote a response would be racing a
# socket the client has already torn down.
private def serve_untrusted_handshake(raw : TCPSocket, ctx : OpenSSL::SSL::Context::Server) : Nil
  ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
  ssl.close rescue nil
rescue
  raw.close rescue nil
end

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

  # --- stage-accurate dial failures (#1020) ------------------------------------------------
  #
  # Every one of these used to arrive as the same shapeless sentence, which is why an OAST
  # registration failing behind a corporate trust store was indistinguishable from a provider
  # outage. The kind is asserted alongside the text because it is what `oast listen` branches
  # its remedy on — a message that reads right with the wrong kind still gives wrong advice.

  it "names the DNS stage, and does not call an unresolved name unreachable" do
    err = expect_raises(Gori::HttpTransport::Error) do
      Gori::HttpTransport.client(URI.parse("https://oast.remote-only.invalid/register"))
    end
    err.kind.should eq(Gori::Proxy::Upstream::DialErrorKind::Dns)
    err.message.not_nil!.should contain("DNS lookup for oast.remote-only.invalid failed")
    err.message.not_nil!.should contain("never resolved")
    err.message.not_nil!.should_not contain("unreachable")
  ensure
    reset_http_transport_proxy
  end

  it "names the TCP connect stage for a closed port" do
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.local_address.port
    closed.close
    err = expect_raises(Gori::HttpTransport::Error) do
      Gori::HttpTransport.client(URI.parse("http://127.0.0.1:#{port}/"))
    end
    err.kind.should eq(Gori::Proxy::Upstream::DialErrorKind::Connect)
    err.message.not_nil!.should contain("TCP connect to 127.0.0.1:#{port} failed")
  ensure
    reset_http_transport_proxy
  end

  it "names TLS VERIFICATION and offers the CA bundle only there" do
    with_untrusted_tls_origin do |port|
      err = expect_raises(Gori::HttpTransport::Error) do
        Gori::HttpTransport.client(URI.parse("https://localhost:#{port}/register"))
      end
      err.kind.should eq(Gori::Proxy::Upstream::DialErrorKind::TlsVerify)
      message = err.message.not_nil!
      message.should contain("TLS certificate verification for localhost failed")
      message.should contain("SSL_CERT_FILE=/path/to/ca-bundle.crt")
      # The library's own words are kept as evidence, not replaced by gori's sentence.
      message.should contain("certificate verify failed")
    end
  ensure
    reset_http_transport_proxy
  end

  it "does not offer a CA bundle for a handshake that never judged a certificate" do
    # A plaintext port answered as if it were TLS: no certificate was exchanged, so a trust
    # store cannot be the fix and saying so would send the operator after the wrong thing.
    plain = TCPServer.new("127.0.0.1", 0)
    spawn do
      while conn = plain.accept?
        conn << "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
        conn.flush rescue nil
        conn.close rescue nil
      end
    rescue
    end
    err = expect_raises(Gori::HttpTransport::Error) do
      Gori::HttpTransport.client(URI.parse("https://127.0.0.1:#{plain.local_address.port}/"))
    end
    err.kind.should eq(Gori::Proxy::Upstream::DialErrorKind::Tls)
    err.message.not_nil!.should contain("before any certificate was judged")
    err.message.not_nil!.should contain("SSL_CERT_FILE cannot help")
  ensure
    plain.try(&.close) rescue nil
    reset_http_transport_proxy
  end
end
