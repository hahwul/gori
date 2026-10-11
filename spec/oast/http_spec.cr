require "../spec_helper"
require "socket"
require "openssl"

# An HTTPS collector whose leaf is signed by a CA this machine does not trust: the handshake
# completes on the server side and the client must refuse it.
private def with_untrusted_collector(&)
  ca_cert, ca_key = Gori::Proxy::Tls::CertBuilder.build_root("gori-spec untrusted OAST CA")
  leaf_cert, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("localhost", ca_cert, ca_key)
  ctx = Gori::Proxy::Tls::ContextFactory.server_context(leaf_cert, leaf_key,
    ca_cert: ca_cert, advertise_h2: false)
  server = TCPServer.new("127.0.0.1", 0)
  spawn do
    while raw = server.accept?
      spawn untrusted_handshake(raw, ctx)
    end
  rescue
  end
  begin
    yield server.local_address.port
  ensure
    server.close rescue nil
  end
end

private def untrusted_handshake(raw : TCPSocket, ctx : OpenSSL::SSL::Context::Server) : Nil
  ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
  ssl.close rescue nil
rescue
  raw.close rescue nil
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

  # OAST is gori's own service traffic: `--insecure-upstream` / `-k` relax a TARGET's
  # certificate, never a collector's, so there is no way to build an unverifying client.
  it "always verifies the collector's certificate" do
    with_untrusted_collector do |port|
      err = expect_raises(Gori::HttpTransport::Error) do
        Gori::Oast::HttpClient.new.request("GET", "https://localhost:#{port}/poll")
      end
      err.kind.should eq(Gori::Proxy::Upstream::DialErrorKind::TlsVerify)
    end
  end
end
