require "../spec_helper"
require "socket"

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
  end
end
