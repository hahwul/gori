require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

describe Gori::Proxy::Upstream do
  describe "upstream proxy (CONNECT tunnel)" do
    it "tunnels a dial through the configured proxy when it answers 2xx" do
      proxy = TCPServer.new("127.0.0.1", 0)
      pport = proxy.local_address.port
      connect_line = Channel(String).new(1)
      spawn do
        conn = proxy.accept
        line = conn.gets("\r\n", chomp: true) || ""
        while (h = conn.gets("\r\n", chomp: true)) && !h.empty?
        end
        conn << "HTTP/1.1 200 Connection established\r\n\r\n"
        conn.flush
        connect_line.send(line)
        sleep 50.milliseconds # keep the tunnel open until the client reads the reply
        conn.close rescue nil
      end

      Gori::Settings.upstream_proxy = "127.0.0.1:#{pport}"
      begin
        sock = Gori::Proxy::Upstream.dial("example.test", 443)
        sock.should_not be_nil
        connect_line.receive.should eq("CONNECT example.test:443 HTTP/1.1")
        sock.try(&.close) rescue nil
      ensure
        Gori::Settings.upstream_proxy = ""
        proxy.close rescue nil
      end
    end

    it "fails the dial when the proxy refuses CONNECT" do
      proxy = TCPServer.new("127.0.0.1", 0)
      pport = proxy.local_address.port
      spawn do
        conn = proxy.accept
        while (h = conn.gets("\r\n", chomp: true)) && !h.empty?
        end
        conn << "HTTP/1.1 403 Forbidden\r\n\r\n"
        conn.flush
        conn.close rescue nil
      end

      Gori::Settings.upstream_proxy = "127.0.0.1:#{pport}"
      begin
        Gori::Proxy::Upstream.dial("example.test", 443).should be_nil
      ensure
        Gori::Settings.upstream_proxy = ""
        proxy.close rescue nil
      end
    end

    it "fails the dial (rather than buffering unboundedly) when the proxy floods the CONNECT reply headers" do
      proxy = TCPServer.new("127.0.0.1", 0)
      pport = proxy.local_address.port
      spawn do
        conn = proxy.accept
        while (h = conn.gets("\r\n", chomp: true)) && !h.empty?
        end
        # A "200" status then a runaway header section with no terminating blank line:
        # past the section cap the CONNECT must fail instead of draining forever.
        conn << "HTTP/1.1 200 Connection established\r\n"
        line = "X-Pad: #{"a" * 512}\r\n"
        (200).times { conn << line } # ~100 KiB > MAX_CONNECT_HEADERS (64 KiB)
        conn.flush rescue nil
        conn.close rescue nil
      end

      Gori::Settings.upstream_proxy = "127.0.0.1:#{pport}"
      begin
        Gori::Proxy::Upstream.dial("example.test", 443).should be_nil
      ensure
        Gori::Settings.upstream_proxy = ""
        proxy.close rescue nil
      end
    end
  end

  describe ".split_host_port" do
    it "parses host:port and bare host" do
      Gori::Proxy::Upstream.split_host_port("example.com:8080", 443).should eq({"example.com", 8080})
      Gori::Proxy::Upstream.split_host_port("example.com", 443).should eq({"example.com", 443})
    end

    it "parses bracketed IPv6 with and without a port (regression: was split inside the literal)" do
      Gori::Proxy::Upstream.split_host_port("[::1]:8443", 443).should eq({"::1", 8443})
      Gori::Proxy::Upstream.split_host_port("[::1]", 443).should eq({"::1", 443})
      Gori::Proxy::Upstream.split_host_port("[2001:db8::1]:8080", 443).should eq({"2001:db8::1", 8080})
    end

    it "treats an unbracketed IPv6 literal as a bare host" do
      Gori::Proxy::Upstream.split_host_port("::1", 443).should eq({"::1", 443})
    end
  end

  # The self-page / self-loop detection. The interesting case is a WILDCARD bind
  # (0.0.0.0 / ::): the proxy answers on every interface, so a request whose Host
  # names the LAN/interface IP the client connected through is the proxy itself —
  # but "0.0.0.0" alone can't see that. `local_host` (the accepted socket's local
  # address) supplies the concrete IP that makes the match work.
  describe ".addresses_self?" do
    it "recognises the LAN IP a device reached a 0.0.0.0 listener on (via local_host)" do
      Gori::Proxy::Upstream.addresses_self?(
        "192.168.1.5", 8080, {"0.0.0.0", 8080}, local_host: "192.168.1.5").should be_true
    end

    it "does NOT recognise that LAN IP without local_host (pins the pre-fix behaviour)" do
      # This is the bug: a mobile device hitting http://<LAN-IP>:port/ against a
      # 0.0.0.0 bind was neither served the self-page nor refused — it looped.
      Gori::Proxy::Upstream.addresses_self?(
        "192.168.1.5", 8080, {"0.0.0.0", 8080}).should be_false
    end

    it "still treats loopback as self under a wildcard bind (regression guard)" do
      Gori::Proxy::Upstream.addresses_self?("127.0.0.1", 8080, {"0.0.0.0", 8080}).should be_true
      Gori::Proxy::Upstream.addresses_self?("localhost", 8080, {"0.0.0.0", 8080}).should be_true
    end

    it "matches an IPv6 interface address under a :: bind, stripping Host brackets" do
      Gori::Proxy::Upstream.addresses_self?(
        "[fe80::1]", 8080, {"::", 8080}, local_host: "fe80::1").should be_true
    end

    it "is scoped to the listener port" do
      Gori::Proxy::Upstream.addresses_self?(
        "192.168.1.5", 9999, {"0.0.0.0", 8080}, local_host: "192.168.1.5").should be_false
    end

    it "does not match an unrelated host even when local_host is known" do
      Gori::Proxy::Upstream.addresses_self?(
        "example.com", 8080, {"0.0.0.0", 8080}, local_host: "192.168.1.5").should be_false
    end

    it "matches a concrete (non-wildcard) bind by literal host, local_host irrelevant" do
      Gori::Proxy::Upstream.addresses_self?("127.0.0.1", 8080, {"127.0.0.1", 8080}).should be_true
    end

    # Gap 1: the OS routes a connect() to the all-zero address onto loopback, so a
    # wildcard TARGET reaches us wherever a loopback target would.
    it "treats a 0.0.0.0 target as self against a loopback bind" do
      Gori::Proxy::Upstream.addresses_self?("0.0.0.0", 8080, {"127.0.0.1", 8080}).should be_true
      Gori::Proxy::Upstream.addresses_self?("::", 8080, {"127.0.0.1", 8080}).should be_true
      Gori::Proxy::Upstream.addresses_self?("0.0.0.0", 8080, {"0.0.0.0", 8080}).should be_true
    end

    # Gap 2: ::0 / 0:0:0:0:0:0:0:0 bind as full wildcards and Settings.bind_host_error
    # accepts them, but the old literal test only knew "0.0.0.0"/"::" — so the self-page
    # vanished under such a bind.
    it "recognises loopback under the expanded all-zero IPv6 binds" do
      {"::0", "0:0:0:0:0:0:0:0", "0000:0000:0000:0000:0000:0000:0000:0000"}.each do |bind|
        Gori::Proxy::Upstream.addresses_self?("localhost", 8080, {bind, 8080}).should be_true
        Gori::Proxy::Upstream.addresses_self?("::1", 8080, {bind, 8080}).should be_true
        Gori::Proxy::Upstream.addresses_self?("127.0.0.1", 8080, {bind, 8080}).should be_true
      end
    end

    it "classifies loopback by ADDRESS, not spelling (expanded v6 and v4-mapped)" do
      Gori::Proxy::Upstream.addresses_self?("0:0:0:0:0:0:0:1", 8080, {"127.0.0.1", 8080}).should be_true
      Gori::Proxy::Upstream.addresses_self?("::ffff:127.0.0.1", 8080, {"127.0.0.1", 8080}).should be_true
      # Not a parseable IP literal, but it dials to 127.0.0.1 — the string fallback
      # must survive the move to address-level classification.
      Gori::Proxy::Upstream.addresses_self?("127.1", 8080, {"127.0.0.1", 8080}).should be_true
    end

    # The false-positive boundary. A match here serves the landing page (or, in
    # loops_to_self?, 502s) instead of proxying, so these MUST stay false.
    it "leaves a real external host on gori's own port alone" do
      Gori::Proxy::Upstream.addresses_self?("example.com", 8080, {"::0", 8080}).should be_false
      Gori::Proxy::Upstream.addresses_self?("93.184.216.34", 8080, {"0.0.0.0", 8080}).should be_false
    end

    it "does not let a concrete non-loopback bind swallow loopback or wildcard targets" do
      # Measured: a listener on a concrete LAN address is NOT reachable by dialing
      # 0.0.0.0, so neither of these is self and both must proxy normally.
      Gori::Proxy::Upstream.addresses_self?("0.0.0.0", 8080, {"192.168.1.5", 8080}).should be_false
      Gori::Proxy::Upstream.addresses_self?("127.0.0.1", 8080, {"192.168.1.5", 8080}).should be_false
      Gori::Proxy::Upstream.addresses_self?("localhost", 8080, {"192.168.1.5", 8080}).should be_false
    end

    it "keeps the wildcard-target match scoped to the listener port" do
      Gori::Proxy::Upstream.addresses_self?("0.0.0.0", 9999, {"127.0.0.1", 8080}).should be_false
    end
  end

  describe ".loops_to_self?" do
    it "refuses a forward to the LAN IP of a 0.0.0.0 listener (via local_host)" do
      Gori::Proxy::Upstream.loops_to_self?(
        "192.168.1.5", 8080, nil, {"0.0.0.0", 8080}, local_host: "192.168.1.5").should be_true
    end

    it "still catches a loopback self-loop under a wildcard bind" do
      Gori::Proxy::Upstream.loops_to_self?("127.0.0.1", 8080, nil, {"0.0.0.0", 8080}).should be_true
    end

    it "leaves a real external host on the same port alone" do
      Gori::Proxy::Upstream.loops_to_self?(
        "example.com", 8080, nil, {"0.0.0.0", 8080}, local_host: "192.168.1.5").should be_false
    end

    # Gap 1, the wedge case: one such request cost 2048 connections (the MAX_CONNECTIONS
    # cap) in 3 seconds against the shipping 127.0.0.1 default bind, after which accept()
    # stalls and the proxy is unusable.
    it "refuses a forward to a 0.0.0.0 target that would land back on a loopback bind" do
      Gori::Proxy::Upstream.loops_to_self?("0.0.0.0", 8080, nil, {"127.0.0.1", 8080}).should be_true
      Gori::Proxy::Upstream.loops_to_self?("::", 8080, nil, {"127.0.0.1", 8080}).should be_true
      Gori::Proxy::Upstream.loops_to_self?("0.0.0.0", 8080, nil, {"0.0.0.0", 8080}).should be_true
    end

    # Gap 2: under an expanded all-zero bind the refusal disappeared entirely, so an
    # absolute-form GET http://localhost:<port>/ wedged the proxy the same way.
    it "still refuses a loopback self-loop under the expanded all-zero IPv6 binds" do
      {"::0", "0:0:0:0:0:0:0:0"}.each do |bind|
        Gori::Proxy::Upstream.loops_to_self?("localhost", 8080, nil, {bind, 8080}).should be_true
        Gori::Proxy::Upstream.loops_to_self?("127.0.0.1", 8080, nil, {bind, 8080}).should be_true
        Gori::Proxy::Upstream.loops_to_self?("0.0.0.0", 8080, nil, {bind, 8080}).should be_true
      end
    end

    it "refuses a hostname override that resolves onto the wildcard address" do
      Gori::Settings.hostname_overrides = [{"api.example.com", "0.0.0.0"}]
      begin
        Gori::Proxy::Upstream.loops_to_self?(
          "api.example.com", 8080, nil, {"127.0.0.1", 8080}).should be_true
      ensure
        Gori::Settings.hostname_overrides = [] of {String, String}
      end
    end

    # The false-positive boundary: refusing here is a 502 on traffic that would have
    # proxied fine, which is worse than the loop it guards against.
    it "does not refuse anything a concrete non-loopback bind cannot possibly serve" do
      Gori::Proxy::Upstream.loops_to_self?("0.0.0.0", 8080, nil, {"192.168.1.5", 8080}).should be_false
      Gori::Proxy::Upstream.loops_to_self?("localhost", 8080, nil, {"192.168.1.5", 8080}).should be_false
      Gori::Proxy::Upstream.loops_to_self?("example.com", 8080, nil, {"::0", 8080}).should be_false
    end

    it "keeps the wildcard-target refusal scoped to the listener port" do
      Gori::Proxy::Upstream.loops_to_self?("0.0.0.0", 9999, nil, {"127.0.0.1", 8080}).should be_false
    end
  end

  # System CA trust resolution (#323): a statically-linked binary whose compiled-in
  # OPENSSLDIR resolves to nothing leaves the verify store EMPTY, so all upstream HTTPS
  # verification fails. We probe the standard system CA locations and load them explicitly.
  describe ".resolve_ca_source" do
    it "returns the first existing file, preferring files over dirs" do
      f = File.tempname("gori-ca", ".pem")
      File.write(f, "x")
      d = File.tempname("gori-cadir")
      Dir.mkdir_p(d)
      begin
        file, dir = Gori::Proxy::Upstream.resolve_ca_source(["/nonexistent/a.pem", f], [d])
        file.should eq(f)
        dir.should be_nil
      ensure
        File.delete?(f)
        FileUtils.rm_rf(d)
      end
    end

    it "falls back to the first existing dir when no file candidate exists" do
      d = File.tempname("gori-cadir")
      Dir.mkdir_p(d)
      begin
        file, dir = Gori::Proxy::Upstream.resolve_ca_source(["/nonexistent/a.pem"], ["/nonexistent/dir", d])
        file.should be_nil
        dir.should eq(d)
      ensure
        FileUtils.rm_rf(d)
      end
    end

    it "returns {nil, nil} when no candidate exists" do
      file, dir = Gori::Proxy::Upstream.resolve_ca_source(["/nonexistent/a.pem"], ["/nonexistent/dir"])
      file.should be_nil
      dir.should be_nil
    end
  end

  describe ".apply_system_trust" do
    it "makes a client context trust an origin signed by a probed CA (untrusted without it)" do
      # A CA + a leaf for "localhost" signed by it; the origin presents [leaf, ca].
      ca_cert, ca_key = Gori::Proxy::Tls::CertBuilder.build_root("gori-spec Test CA")
      leaf_cert, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("localhost", ca_cert, ca_key)
      origin_ctx = Gori::Proxy::Tls::ContextFactory.server_context(leaf_cert, leaf_key, ca_cert: ca_cert)

      ca_path = File.tempname("gori-spec-ca", ".pem")
      ca_cert.write_pem(ca_path)

      origin = TCPServer.new("127.0.0.1", 0)
      port = origin.local_address.port
      spawn do
        2.times do
          next unless raw = origin.accept?
          begin
            OpenSSL::SSL::Socket::Server.new(raw, origin_ctx, sync_close: true).close
          rescue
            raw.close rescue nil
          end
        end
      end

      begin
        # WITHOUT the probed CA: the leaf chains to an untrusted root → verification fails.
        expect_raises(OpenSSL::SSL::Error) do
          tcp = TCPSocket.new("127.0.0.1", port)
          OpenSSL::SSL::Socket::Client.new(tcp, context: OpenSSL::SSL::Context::Client.new,
            sync_close: true, hostname: "localhost")
        end

        # WITH the probed CA loaded via apply_system_trust: verification succeeds.
        trusting = OpenSSL::SSL::Context::Client.new
        Gori::Proxy::Upstream.apply_system_trust(trusting, files: [ca_path], dirs: [] of String)
        tcp2 = TCPSocket.new("127.0.0.1", port)
        OpenSSL::SSL::Socket::Client.new(tcp2, context: trusting, sync_close: true, hostname: "localhost").close
      ensure
        origin.close rescue nil
        File.delete?(ca_path)
      end
    end
  end
end
