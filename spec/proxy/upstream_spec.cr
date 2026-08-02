require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

describe Gori::Proxy::Upstream do
  # An IPv6 literal reaches this path BRACKETED — that is how it appears in an absolute-form
  # request target and what `URI#host` returns — and a bracketed string is not an address, so
  # `TCPSocket.new` treated it as a hostname and the resolve failed. gori could not reach an
  # IPv6-literal origin at all through the forward proxy, while the same origin answered
  # direct. The brackets were already stripped at the two other places a host becomes an
  # address in this file; the direct dial was the site that was not.
  describe "IPv6 literal targets" do
    it "dials a bracketed IPv6 literal, as an absolute-form request target carries it" do
      server = TCPServer.new("::1", 0)
      port = server.local_address.port
      spawn { server.accept?.try(&.close) }

      sock = Gori::Proxy::Upstream.dial("[::1]", port)
      sock.should_not be_nil
      sock.try(&.close)
      server.close
    end

    it "still dials the same host unbracketed, and an IPv4 literal and a hostname" do
      v6 = TCPServer.new("::1", 0)
      v4 = TCPServer.new("127.0.0.1", 0)
      spawn { v6.accept?.try(&.close) }
      spawn { v4.accept?.try(&.close) }

      Gori::Proxy::Upstream.dial("::1", v6.local_address.port).should_not be_nil
      Gori::Proxy::Upstream.dial("127.0.0.1", v4.local_address.port).should_not be_nil
      v6.close
      v4.close
    end
  end

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

    # Round 9 / r9-tls Finding 2. A proxy that answers `200 Connection Established` and then
    # closes WITHOUT relaying anything (an overloaded proxy, an ACL that 200s before checking,
    # a proxy whose own backend dial failed after it already committed) hands back a socket
    # that, to the subsequent TLS handshake, looks EXACTLY like a direct connection to a broken
    # origin — nothing on the bare socket remembers it came through a tunnel. Before this fix
    # `tls_dial_error` reported plain `Tls` with no proxy context, so the operator was told the
    # ORIGIN's port "may not be TLS" when the origin was never contacted at all.
    it "tags the DialError with the proxy when it answers 200 and then closes with no data" do
      proxy = TCPServer.new("127.0.0.1", 0)
      pport = proxy.local_address.port
      spawn do
        conn = proxy.accept
        while (h = conn.gets("\r\n", chomp: true)) && !h.empty?
        end
        conn << "HTTP/1.1 200 Connection Established\r\n\r\n"
        conn.flush rescue nil
        conn.close rescue nil # no relay at all — the tunnel produced nothing
      end

      Gori::Settings.upstream_proxy = "127.0.0.1:#{pport}"
      begin
        sock, err = Gori::Proxy::Upstream.dial_tls_result("example.test", 443, verify: false,
          io_timeout: 3.seconds)
        sock.should be_nil
        # Same kind a direct black-hole/non-TLS port gets (Tls, via OpenSSL's own EOF verdict) —
        # the NEW information is `via_proxy` / `proxy_note`, not a new DialErrorKind.
        err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Tls)
        err.try(&.via_proxy).should eq("upstream HTTP proxy 127.0.0.1:#{pport}")
        note = err.try(&.proxy_note).to_s
        note.should contain("upstream HTTP proxy 127.0.0.1:#{pport}")
        note.should contain("tunnel produced no data")
        note.should contain("proxy may be at fault, not the target")
      ensure
        Gori::Settings.upstream_proxy = ""
        proxy.close rescue nil
      end
    end

    # Complement: an untrusted-cert rejection through the SAME proxy shape must NOT get the
    # tunnel-blame clause — real handshake bytes crossed the tunnel and the ORIGIN's chain is
    # what failed, so `proxy_note` must stay empty even though the dial went via a proxy.
    it "does NOT tag a TlsVerify failure with the proxy note — real bytes crossed the tunnel" do
      ca_cert, ca_key = Gori::Proxy::Tls::CertBuilder.build_root("gori-spec Untrusted CA (r9)")
      leaf_cert, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("localhost", ca_cert, ca_key)
      origin_ctx = Gori::Proxy::Tls::ContextFactory.server_context(leaf_cert, leaf_key, ca_cert: ca_cert)

      origin = TCPServer.new("127.0.0.1", 0)
      oport = origin.local_address.port
      spawn do
        next unless raw = origin.accept?
        begin
          ssl = OpenSSL::SSL::Socket::Server.new(raw, origin_ctx, sync_close: true)
          ssl.close rescue nil
        rescue
          raw.close rescue nil
        end
      end

      proxy = TCPServer.new("127.0.0.1", 0)
      pport = proxy.local_address.port
      spawn do
        conn = proxy.accept
        while (h = conn.gets("\r\n", chomp: true)) && !h.empty?
        end
        conn << "HTTP/1.1 200 Connection Established\r\n\r\n"
        conn.flush rescue nil
        # A real (bidirectional) tunnel this time — bytes DO cross it, unlike the
        # accept-then-close example above.
        upstream = TCPSocket.new("127.0.0.1", oport)
        done = Channel(Nil).new(2)
        spawn { IO.copy(conn, upstream) rescue nil; done.send(nil) }
        spawn { IO.copy(upstream, conn) rescue nil; done.send(nil) }
        2.times { done.receive }
        conn.close rescue nil
        upstream.close rescue nil
      end

      Gori::Settings.upstream_proxy = "127.0.0.1:#{pport}"
      begin
        sock, err = Gori::Proxy::Upstream.dial_tls_result("127.0.0.1", oport, verify: true,
          sni: "localhost", io_timeout: 3.seconds)
        sock.should be_nil
        err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::TlsVerify)
        err.try(&.via_proxy).should be_nil
        err.try(&.proxy_note).should eq("")
      ensure
        Gori::Settings.upstream_proxy = ""
        proxy.close rescue nil
        origin.close rescue nil
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

    it "does not swallow the port for a malformed multi-colon authority (regression #13)" do
      # Was: host="127.0.0.1:19110:bogus", port=80 — a non-v6 multi-colon authority was
      # treated as a whole IPv6 host and the real port was silently dropped.
      host, _ = Gori::Proxy::Upstream.split_host_port("127.0.0.1:19110:bogus", 80)
      host.should_not eq("127.0.0.1:19110:bogus") # the whole authority is NOT the host
      # host:port semantics win — split on the LAST colon.
      Gori::Proxy::Upstream.split_host_port("127.0.0.1:19110:bogus", 80).should eq({"127.0.0.1:19110", 80})
      Gori::Proxy::Upstream.split_host_port("127.0.0.1:80", 443).should eq({"127.0.0.1", 80})
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

    it "falls back to the first NON-EMPTY dir when no file candidate exists" do
      d = File.tempname("gori-cadir")
      Dir.mkdir_p(d)
      File.write(File.join(d, "some-ca.0"), "x") # a hashed-cert dir is non-empty
      begin
        file, dir = Gori::Proxy::Upstream.resolve_ca_source(["/nonexistent/a.pem"], ["/nonexistent/dir", d])
        file.should be_nil
        dir.should eq(d)
      ensure
        FileUtils.rm_rf(d)
      end
    end

    it "ignores an empty dir (present but shipping no certs → not a usable store)" do
      d = File.tempname("gori-cadir-empty")
      Dir.mkdir_p(d)
      begin
        file, dir = Gori::Proxy::Upstream.resolve_ca_source(["/nonexistent/a.pem"], [d])
        file.should be_nil
        dir.should be_nil
      ensure
        FileUtils.rm_rf(d)
      end
    end

    it "ignores a zero-byte file (present but shipping no certs → not a usable store)" do
      f = File.tempname("gori-ca-empty", ".pem")
      File.write(f, "")
      begin
        # A placeholder/zero-byte bundle at a standard path must not count as "trust available"
        # — doing so would suppress the no-store warning while verify fails on an empty store.
        file, dir = Gori::Proxy::Upstream.resolve_ca_source([f], [] of String)
        file.should be_nil
        dir.should be_nil
      ensure
        File.delete?(f)
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

  # The #323 diagnostic split: the proxy capture path records WHY an HTTPS upstream dial
  # failed, so a verify rejection (fix: --insecure-upstream) is never mislabelled as an
  # unreachable origin. dial_tls delegates to dial_tls_result, so this covers both.
  describe ".dial_tls_result" do
    it "classifies an unreachable origin as a Connect failure" do
      srv = TCPServer.new("127.0.0.1", 0)
      port = srv.local_address.port
      srv.close # free the port so the connect is refused, not accepted
      sock, err = Gori::Proxy::Upstream.dial_tls_result("127.0.0.1", port, verify: false)
      sock.should be_nil
      err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Connect)
    end

    it "classifies an untrusted-cert origin as a TlsVerify failure under verify, and succeeds with verify off" do
      # A leaf for "localhost" signed by a CA the client does NOT trust: the origin is REACHED
      # (so not a Connect failure) but the chain doesn't verify — exactly the #323 shape.
      ca_cert, ca_key = Gori::Proxy::Tls::CertBuilder.build_root("gori-spec Untrusted CA")
      leaf_cert, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("localhost", ca_cert, ca_key)
      origin_ctx = Gori::Proxy::Tls::ContextFactory.server_context(leaf_cert, leaf_key, ca_cert: ca_cert)

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
        # verify ON: chain to an untrusted root → a TLS (verify) failure, NOT Connect.
        # Dial 127.0.0.1 explicitly (no localhost→::1 resolution race), verify the "localhost" cert via SNI.
        sock, err = Gori::Proxy::Upstream.dial_tls_result("127.0.0.1", port, verify: true, sni: "localhost")
        sock.should be_nil
        err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::TlsVerify)
        # …and still the TLS leg for anything that only asks which layer broke.
        err.try(&.tls?).should be_true
        # OpenSSL's own verdict is kept, not thrown away — it is the ONLY evidence that
        # separates this from a plaintext port or an origin that never answered.
        err.try(&.cause).to_s.should contain("certificate verify failed")

        # verify OFF: the same origin dials fine — a live socket, no error.
        sock2, err2 = Gori::Proxy::Upstream.dial_tls_result("127.0.0.1", port, verify: false, sni: "localhost")
        sock2.should_not be_nil
        err2.should be_nil
        sock2.try(&.close) rescue nil
      ensure
        origin.close rescue nil
      end
    end

    # Round 5 / Part 2 §2.1. The rescue here used to be bare: it threw the exception away and
    # called EVERY outcome `Tls`, so a socket that accepts the TCP connection and then never
    # speaks — a silent firewall drop, a wedged origin, an inline IPS — arrived at the operator
    # as "origin certificate not trusted; retry with --insecure-upstream or set SSL_CERT_FILE".
    # No certificate is exchanged in that conversation and both remedies are useless.
    it "classifies an origin that accepts and then says nothing as Timeout, not a TLS verdict" do
      origin = TCPServer.new("127.0.0.1", 0)
      port = origin.local_address.port
      held = [] of TCPSocket
      spawn do
        while sock = origin.accept?
          held << sock # accepted, and deliberately never written to
        end
      end

      begin
        [true, false].each do |verify| # -k must not change the answer
          sock, err = Gori::Proxy::Upstream.dial_tls_result("127.0.0.1", port, verify: verify,
            io_timeout: 300.milliseconds)
          sock.should be_nil
          err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Timeout)
          # Not the TLS leg at all: nothing came back to judge, so no surface may offer a
          # certificate remedy — and -k must not change the answer, because verification
          # never ran either way.
          err.try(&.tls?).should be_false
          # The stall was invisible before (a failed dial records no duration), so the wait
          # itself is the evidence.
          err.try(&.cause).to_s.should contain("0.3s")
        end
      ensure
        origin.close rescue nil
        held.each { |s| s.close rescue nil }
      end
    end

    it "classifies a plaintext port spoken to as TLS by what OpenSSL said, not as a cert failure" do
      origin = TCPServer.new("127.0.0.1", 0)
      port = origin.local_address.port
      spawn do
        while sock = origin.accept?
          # Answers immediately, so OpenSSL parses the reply as a TLS record and refuses —
          # the complement of the silent case above, which times out instead.
          sock.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".to_slice) rescue nil
          sock.close rescue nil
        end
      end

      begin
        sock, err = Gori::Proxy::Upstream.dial_tls_result("127.0.0.1", port, verify: true,
          io_timeout: 3.seconds)
        sock.should be_nil
        err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Tls)
        # Under verify-on this used to be indistinguishable from an untrusted certificate.
        err.try(&.kind).should_not eq(Gori::Proxy::Upstream::DialErrorKind::TlsVerify)
        err.try(&.cause).to_s.downcase.should contain("version")
      ensure
        origin.close rescue nil
      end
    end

    it "keeps a library verdict storable: no heap address, no control bytes" do
      origin = TCPServer.new("127.0.0.1", 0)
      port = origin.local_address.port
      spawn do
        while sock = origin.accept?
          sock.linger = 0 # RST rather than FIN, so the failure is an IO error, not a TLS alert
          sock.close rescue nil
        end
      end

      begin
        _, err = Gori::Proxy::Upstream.dial_tls_result("127.0.0.1", port, verify: true,
          io_timeout: 3.seconds)
        cause = err.try(&.cause).to_s
        # NOT asserted non-empty. Whether the TLS library has words for a connection reset
        # mid-handshake is platform-dependent — macOS yields an IO error carrying a message,
        # Linux yields one without. That a cause is PRESENT when the library has a verdict is
        # pinned by the untrusted-certificate example above, which reports `certificate verify
        # failed` everywhere. This example is about the SHAPE of whatever comes back, and an
        # absent cause is trivially storable.
        # Crystal decorates an IO failure with the object's inspect
        # ("write (#<TCPSocket:0x104245c80>): Broken pipe"); a heap address in a string the
        # DB keeps and HAR/MCP export makes two identical failures compare unequal.
        cause.should_not contain("#<")
        cause.should_not contain("\r")
        cause.should_not contain("\n")
      ensure
        origin.close rescue nil
      end
    end

    it "classifies a name that does not resolve as Dns — nothing was dialed" do
      _, err = Gori::Proxy::Upstream.dial_result("gori-spec-does-not-exist.invalid", 443,
        connect_timeout: 3.seconds, io_timeout: 3.seconds)
      err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Dns)
      err.try(&.detail).should be_nil # the caller words this one itself
    end

    it "still reports a refused port as Connect, not as the new DNS kind" do
      srv = TCPServer.new("127.0.0.1", 0)
      port = srv.local_address.port
      srv.close
      _, err = Gori::Proxy::Upstream.dial_result("127.0.0.1", port)
      err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Connect)
    end
  end

  describe "DialError#because" do
    it "is empty when there is nothing the library added, and parenthesised when there is" do
      Gori::Proxy::Upstream::DialError::ORIGIN_UNREACHABLE.because.should eq("")
      Gori::Proxy::Upstream::DialError.new(Gori::Proxy::Upstream::DialErrorKind::Tls, cause: "")
        .because.should eq("")
      Gori::Proxy::Upstream::DialError.new(Gori::Proxy::Upstream::DialErrorKind::Tls,
        cause: "wrong version number").because.should eq(" (wrong version number)")
    end
  end

  # Round 9 / r9-tls Finding 2.
  describe "DialError#proxy_note" do
    it "is empty for a direct (non-proxied) DialError, whatever its kind" do
      Gori::Proxy::Upstream::DialError::ORIGIN_UNREACHABLE.proxy_note.should eq("")
      Gori::Proxy::Upstream::DialError.new(Gori::Proxy::Upstream::DialErrorKind::Tls,
        cause: "wrong version number").proxy_note.should eq("")
      Gori::Proxy::Upstream::DialError.new(Gori::Proxy::Upstream::DialErrorKind::Timeout,
        cause: "no TLS response within 3.0s").proxy_note.should eq("")
    end

    it "names the proxy and blames the tunnel, not the target, when via_proxy is set" do
      err = Gori::Proxy::Upstream::DialError.new(Gori::Proxy::Upstream::DialErrorKind::Tls,
        cause: "SSL_connect: Unexpected EOF while reading",
        via_proxy: "upstream HTTP proxy 127.0.0.1:8080")
      err.proxy_note.should eq(
        " (reached via upstream HTTP proxy 127.0.0.1:8080 — the tunnel produced no data; " \
        "the proxy may be at fault, not the target)")
    end
  end

  describe "Upstream.proxied_via" do
    it "is nil for a direct route and the proxy label for a configured one" do
      Gori::Proxy::Upstream.proxied_via("h.test").should be_nil
      Gori::Settings.upstream_proxy = "10.0.0.1:3128"
      begin
        Gori::Proxy::Upstream.proxied_via("h.test").should eq("upstream HTTP proxy 10.0.0.1:3128")
      ensure
        Gori::Settings.upstream_proxy = ""
      end
    end
  end
end
