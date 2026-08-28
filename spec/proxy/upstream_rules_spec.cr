require "../spec_helper"
require "socket"

# Restore every knob upstream_route consults, so one example can't leak a route into the next.
private def reset_upstream : Nil
  Gori::Settings.upstream_rules = [] of Gori::Settings::UpstreamRule
  Gori::Settings.upstream_proxy = ""
  Gori::Settings.project_upstream_proxy = nil
  Gori::Settings.project_upstream_destination = nil
  Gori::Settings.project_upstream_auth = nil
  Gori::Settings.project_upstream_auth_error = nil
end

private def rule(host : String, kind : String, addr : String = "",
                 username : String = "", password_env : String = "") : Gori::Settings::UpstreamRule
  Gori::Settings::UpstreamRule.new(host, kind, addr, username, password_env)
end

# A one-shot HTTP proxy that captures the whole CONNECT head (request line + headers) and
# answers 200, so a spec can assert on what gori actually put on the wire.
private def with_capturing_http_proxy(&)
  server = TCPServer.new("127.0.0.1", 0)
  head = Channel(String).new(1)
  spawn do
    conn = server.accept
    buf = String::Builder.new
    while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
      buf << line << "\n"
    end
    conn << "HTTP/1.1 200 Connection established\r\n\r\n"
    conn.flush
    head.send(buf.to_s)
    sleep 50.milliseconds # hold the tunnel open until the client has read the reply
    conn.close rescue nil
  rescue
  end
  begin
    yield server.local_address.port, head
  ensure
    server.close rescue nil
  end
end

# A one-shot HTTP proxy that REFUSES the tunnel with `status`, the way a corporate proxy
# answers an unauthenticated (407) or ACL-blocked (403) CONNECT. Drains the request head first
# so gori's write completes, then answers and closes.
private def with_refusing_http_proxy(status : Int32, reason : String, &)
  server = TCPServer.new("127.0.0.1", 0)
  spawn do
    conn = server.accept
    while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
    end
    conn << "HTTP/1.1 #{status} #{reason}\r\nProxy-Agent: spec\r\nContent-Length: 0\r\n\r\n"
    conn.flush
    sleep 50.milliseconds
    conn.close rescue nil
  rescue
  end
  begin
    yield server.local_address.port
  ensure
    server.close rescue nil
  end
end

# A one-shot SOCKS5 proxy. Performs method negotiation (offering `auth_method`), the optional
# RFC 1929 exchange, then reads the CONNECT request and reports what it was asked for instead of
# actually connecting — the point is to pin the bytes gori emits, not to relay.
private def with_socks5_proxy(auth_method : UInt8 = 0_u8, auth_ok : Bool = true, &)
  server = TCPServer.new("127.0.0.1", 0)
  seen = Channel(NamedTuple(atyp: UInt8, addr: String, port: Int32, user: String, pass: String)).new(1)
  spawn do
    conn = server.accept
    greeting = Bytes.new(2)
    conn.read_fully(greeting)
    methods = Bytes.new(greeting[1].to_i)
    conn.read_fully(methods)
    conn.write(Bytes[5_u8, auth_method])
    conn.flush

    user = ""
    pass = ""
    if auth_method == 2_u8
      hdr = Bytes.new(2)
      conn.read_fully(hdr) # VER, ULEN
      ubuf = Bytes.new(hdr[1].to_i)
      conn.read_fully(ubuf)
      user = String.new(ubuf)
      plen = Bytes.new(1)
      conn.read_fully(plen)
      pbuf = Bytes.new(plen[0].to_i)
      conn.read_fully(pbuf)
      pass = String.new(pbuf)
      conn.write(Bytes[1_u8, auth_ok ? 0_u8 : 1_u8])
      conn.flush
      unless auth_ok
        conn.close rescue nil
        next
      end
    end

    req = Bytes.new(4) # VER CMD RSV ATYP
    conn.read_fully(req)
    addr = case req[3]
           when 1_u8
             b = Bytes.new(4); conn.read_fully(b); b.join(".")
           when 4_u8
             b = Bytes.new(16); conn.read_fully(b)
             b.each_slice(2).map { |p| "%02x%02x" % {p[0], p[1]} }.join(":")
           else
             l = Bytes.new(1); conn.read_fully(l)
             b = Bytes.new(l[0].to_i); conn.read_fully(b); String.new(b)
           end
    pbytes = Bytes.new(2)
    conn.read_fully(pbytes)
    seen.send({atyp: req[3], addr: addr, port: (pbytes[0].to_i << 8) | pbytes[1].to_i,
               user: user, pass: pass})
    # Success reply with an IPv4 bound address, then hold the "tunnel" open.
    conn.write(Bytes[5_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    conn.flush
    sleep 50.milliseconds
    conn.close rescue nil
  rescue
  end
  begin
    yield server.local_address.port, seen
  ensure
    server.close rescue nil
  end
end

describe "upstream rules" do
  describe ".upstream_route" do
    it "matches the FIRST rule, so a specific rule above a catch-all wins" do
      Gori::Settings.upstream_rules = [
        rule("*.corp.test", "http", "corp-proxy.test:3128"),
        rule("*", "direct"),
      ]
      route = Gori::Settings.upstream_route("api.corp.test")
      route.kind.should eq("http")
      route.host.should eq("corp-proxy.test")
      route.port.should eq(3128)
      Gori::Settings.upstream_route("example.test").direct?.should be_true
    ensure
      reset_upstream
    end

    # A "direct" rule is the mechanism for carving an exception out of a broader proxy rule,
    # so its ordering behaviour is the feature, not a side effect.
    it "lets a direct rule carve an exception above a broader proxy rule" do
      Gori::Settings.upstream_rules = [
        rule("intranet.corp.test", "direct"),
        rule("*.corp.test", "http", "corp-proxy.test:3128"),
      ]
      Gori::Settings.upstream_route("intranet.corp.test").direct?.should be_true
      Gori::Settings.upstream_route("other.corp.test").host.should eq("corp-proxy.test")
    ensure
      reset_upstream
    end

    it "covers subdomains of a bare pattern and is case-insensitive (shared host dialect)" do
      Gori::Settings.upstream_rules = [rule("Corp.TEST", "http", "p.test:1")]
      Gori::Settings.upstream_route("api.corp.test").host.should eq("p.test")
      Gori::Settings.upstream_route("corp.test").host.should eq("p.test")
      Gori::Settings.upstream_route("corp.test.evil.test").direct?.should be_true
    ensure
      reset_upstream
    end

    it "defaults the port per kind: 8080 for http, 1080 for either SOCKS mode" do
      Gori::Settings.upstream_rules = [
        rule("a.test", "http", "p.test"),
        rule("b.test", "socks5", "s.test"),
        rule("c.test", "socks5h", "h.test"),
      ]
      Gori::Settings.upstream_route("a.test").port.should eq(8080)
      Gori::Settings.upstream_route("b.test").port.should eq(1080)
      Gori::Settings.upstream_route("b.test").socks5?.should be_true
      Gori::Settings.upstream_route("c.test").port.should eq(1080)
      Gori::Settings.upstream_route("c.test").remote_dns?.should be_true
    ensure
      reset_upstream
    end

    it "falls back to the legacy scalar when no rule matches, and to direct when it is blank" do
      Gori::Settings.upstream_rules = [rule("only.test", "http", "p.test:1")]
      Gori::Settings.upstream_proxy = "legacy.test:8888"
      Gori::Settings.upstream_route("other.test").host.should eq("legacy.test")
      Gori::Settings.upstream_route("other.test").port.should eq(8888)
      Gori::Settings.upstream_proxy = ""
      Gori::Settings.upstream_route("other.test").direct?.should be_true
    ensure
      reset_upstream
    end

    # Back-compat: a project that pinned its own upstream before rules existed must keep
    # going through it, whatever the global table now says.
    it "lets a project pin beat the rule table entirely" do
      Gori::Settings.upstream_rules = [rule("*", "http", "table.test:1")]
      Gori::Settings.project_upstream_proxy = "pinned.test:9"
      route = Gori::Settings.upstream_route("anything.test")
      route.host.should eq("pinned.test")
      route.port.should eq(9)
    ensure
      reset_upstream
    end

    it "uses the project destination pattern as a direct-or-proxy gate" do
      Gori::Settings.upstream_rules = [rule("*", "http", "table.test:1")]
      Gori::Settings.project_upstream_destination = "*.corp.test"

      Gori::Settings.upstream_route("corp.test").direct?.should be_true
      route = Gori::Settings.upstream_route("api.corp.test")
      {route.kind, route.host, route.port}.should eq({"http", "table.test", 1})
      Gori::Settings.upstream_route("outside.test").direct?.should be_true

      Gori::Settings.project_upstream_destination = "10.*"
      Gori::Settings.upstream_route("10.2.3.4").host.should eq("table.test")
      Gori::Settings.upstream_route("11.2.3.4").direct?.should be_true

      Gori::Settings.project_upstream_destination = "*"
      Gori::Settings.upstream_route("outside.test").host.should eq("table.test")
    ensure
      reset_upstream
    end

    it "keeps credentials on matching destinations and sends non-matches direct" do
      Gori::Settings.project_upstream_proxy = "http://proxy.test:8080"
      Gori::Settings.project_upstream_destination = "target.test"
      Gori::Settings.project_upstream_auth =
        Gori::Settings::ProjectProxyAuth.new("basic", "alice", "secret")

      route = Gori::Settings.upstream_route("api.target.test")
      {route.host, route.username, route.password}.should eq({"proxy.test", "alice", "secret"})
      Gori::Settings.upstream_route("outside.test").direct?.should be_true
    ensure
      reset_upstream
    end

    it "fails closed when a persisted destination pattern is invalid" do
      Gori::Settings.project_upstream_destination = "https://target.test"
      route = Gori::Settings.upstream_route("target.test")
      route.invalid?.should be_true
      route.configuration_error.to_s.should contain("destination proxy filter is invalid")

      socket, error = Gori::Proxy::Upstream.dial_result("target.test", 443)
      socket.should be_nil
      error.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Proxy)
      error.try(&.detail).to_s.should contain("origin was never contacted")
    ensure
      reset_upstream
    end

    # An explicit project "" means DIRECT and must not fall through to the table or the
    # global scalar (the nil-vs-empty distinction is load-bearing).
    it "treats an explicit empty project pin as direct, not as absent" do
      Gori::Settings.upstream_rules = [rule("*", "http", "table.test:1")]
      Gori::Settings.upstream_proxy = "global.test:2"
      Gori::Settings.project_upstream_proxy = ""
      Gori::Settings.upstream_route("anything.test").direct?.should be_true
    ensure
      reset_upstream
    end

    it "reads the password from the OS environment at route time, never from settings" do
      ENV["GORI_SPEC_PROXY_PASS"] = "s3cret"
      Gori::Settings.upstream_rules = [rule("a.test", "http", "p.test:1", "bob", "GORI_SPEC_PROXY_PASS")]
      route = Gori::Settings.upstream_route("a.test")
      route.username.should eq("bob")
      route.password.should eq("s3cret")

      # Unset the variable and the credential disappears — nothing was cached at load.
      ENV.delete("GORI_SPEC_PROXY_PASS")
      Gori::Settings.upstream_route("a.test").password.should be_nil
    ensure
      ENV.delete("GORI_SPEC_PROXY_PASS")
      reset_upstream
    end

    # A hand-edited file can hold a rule the validator would have rejected. Sending direct in
    # that case would leak the exact destination the operator intended to proxy.
    it "fails a proxy rule with no address closed" do
      Gori::Settings.upstream_rules = [rule("a.test", "http", "")]
      route = Gori::Settings.upstream_route("a.test")
      route.invalid?.should be_true
      route.direct?.should be_false

      sock, err = Gori::Proxy::Upstream.dial_result("a.test", 443)
      sock.should be_nil
      err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Proxy)
      err.try(&.detail).to_s.should contain("origin was never contacted")
    ensure
      reset_upstream
    end

    it "fails a malformed host pattern closed instead of falling through to direct" do
      Gori::Settings.upstream_rules = [rule("[", "http", "proxy.test:8080")]

      route = Gori::Settings.upstream_route("origin.test")
      route.invalid?.should be_true
      route.direct?.should be_false
      route.configuration_error.to_s.should contain("invalid upstream rule host pattern")
    ensure
      reset_upstream
    end
  end

  describe "HTTP proxy authentication" do
    it "sends the Basic credentials saved in Project settings" do
      with_capturing_http_proxy do |pport, head|
        Gori::Settings.project_upstream_proxy = "http://127.0.0.1:#{pport}"
        Gori::Settings.project_upstream_auth =
          Gori::Settings::ProjectProxyAuth.new("basic", "project-user", "project-pass")

        sock = Gori::Proxy::Upstream.dial("example.test", 443)
        sock.should_not be_nil
        sent = head.receive
        sock.try(&.close) rescue nil

        sent.should contain("CONNECT example.test:443 HTTP/1.1")
        sent.should contain("Proxy-Authorization: Basic #{Base64.strict_encode("project-user:project-pass")}")
      end
    ensure
      reset_upstream
    end

    # The headline fix: before upstream rules, gori emitted no Proxy-Authorization at all, so
    # an authenticating proxy could not be used.
    it "sends Basic Proxy-Authorization when the rule carries credentials" do
      ENV["GORI_SPEC_PROXY_PASS"] = "p4ss"
      with_capturing_http_proxy do |pport, head|
        Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}", "bob", "GORI_SPEC_PROXY_PASS")]
        sock = Gori::Proxy::Upstream.dial("example.test", 443)
        sock.should_not be_nil
        sent = head.receive
        sock.try(&.close) rescue nil

        sent.should contain("CONNECT example.test:443 HTTP/1.1")
        sent.should contain("Proxy-Authorization: Basic #{Base64.strict_encode("bob:p4ss")}")
      end
    ensure
      ENV.delete("GORI_SPEC_PROXY_PASS")
      reset_upstream
    end

    it "omits Proxy-Authorization entirely when the rule has no credentials" do
      with_capturing_http_proxy do |pport, head|
        Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}")]
        sock = Gori::Proxy::Upstream.dial("example.test", 443)
        sock.should_not be_nil
        sent = head.receive
        sock.try(&.close) rescue nil
        sent.downcase.should_not contain("proxy-authorization")
      end
    ensure
      reset_upstream
    end

    # A CR/LF in a credential would inject a header line into gori's OWN CONNECT request —
    # self-inflicted request smuggling (the #403 shape). These values come from settings.json
    # and the OS environment, so they are stripped rather than trusted.
    it "strips CR/LF from credentials instead of injecting a header line" do
      ENV["GORI_SPEC_PROXY_PASS"] = "p4ss\r\nX-Injected: 1"
      with_capturing_http_proxy do |pport, head|
        Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}", "bo\r\nb", "GORI_SPEC_PROXY_PASS")]
        sock = Gori::Proxy::Upstream.dial("example.test", 443)
        sent = head.receive
        sock.try(&.close) rescue nil

        sent.should_not contain("X-Injected")
        sent.should contain("Proxy-Authorization: Basic #{Base64.strict_encode("bob:p4ssX-Injected: 1")}")
      end
    ensure
      ENV.delete("GORI_SPEC_PROXY_PASS")
      reset_upstream
    end
  end

  describe "SOCKS5" do
    it "uses Project settings credentials and delegates SOCKS5H DNS to the proxy" do
      with_socks5_proxy(auth_method: 2_u8) do |sport, seen|
        Gori::Settings.project_upstream_proxy = "socks5h://127.0.0.1:#{sport}"
        Gori::Settings.project_upstream_auth =
          Gori::Settings::ProjectProxyAuth.new("socks5", "project-user", "project-pass")

        sock = Gori::Proxy::Upstream.dial("remote-only.test", 443)
        sock.should_not be_nil
        got = seen.receive
        sock.try(&.close) rescue nil

        got[:user].should eq("project-user")
        got[:pass].should eq("project-pass")
        got[:atyp].should eq(3_u8)
        got[:addr].should eq("remote-only.test")
      end
    ensure
      reset_upstream
    end

    it "uses the scalar socks5h:// form and sends hostnames as ATYP DOMAIN" do
      with_socks5_proxy do |sport, seen|
        Gori::Settings.upstream_proxy = "socks5h://127.0.0.1:#{sport}"
        sock = Gori::Proxy::Upstream.dial("remote-only.test", 80)
        sock.should_not be_nil
        got = seen.receive
        sock.try(&.close) rescue nil

        got[:atyp].should eq(3_u8)
        got[:addr].should eq("remote-only.test")
      end
    ensure
      reset_upstream
    end

    it "resolves a hostname locally for a SOCKS5 rule and sends its address literal" do
      with_socks5_proxy do |sport, seen|
        Gori::Settings.upstream_rules = [rule("*", "socks5", "127.0.0.1:#{sport}")]
        sock = Gori::Proxy::Upstream.dial("localhost", 443)
        sock.should_not be_nil
        got = seen.receive
        sock.try(&.close) rescue nil

        [1_u8, 4_u8].includes?(got[:atyp]).should be_true
        got[:addr].should_not eq("localhost")
        got[:port].should eq(443)
      end
    ensure
      reset_upstream
    end

    it "sends an IPv4 literal target as ATYP IPV4, not as a domain name" do
      with_socks5_proxy do |sport, seen|
        Gori::Settings.upstream_rules = [rule("*", "socks5", "127.0.0.1:#{sport}")]
        sock = Gori::Proxy::Upstream.dial("93.184.216.34", 8080)
        sock.should_not be_nil
        got = seen.receive
        sock.try(&.close) rescue nil

        got[:atyp].should eq(1_u8)
        got[:addr].should eq("93.184.216.34")
        got[:port].should eq(8080)
      end
    ensure
      reset_upstream
    end

    # The brackets are URL syntax; on the wire the address is 16 raw bytes.
    it "sends a bracketed IPv6 literal as 16 raw bytes (ATYP IPV6), brackets stripped" do
      with_socks5_proxy do |sport, seen|
        Gori::Settings.upstream_rules = [rule("*", "socks5", "127.0.0.1:#{sport}")]
        sock = Gori::Proxy::Upstream.dial("[2001:db8::1]", 443)
        sock.should_not be_nil
        got = seen.receive
        sock.try(&.close) rescue nil

        got[:atyp].should eq(4_u8)
        got[:addr].should eq("2001:0db8:0000:0000:0000:0000:0000:0001")
      end
    ensure
      reset_upstream
    end

    it "performs the RFC 1929 username/password exchange when the proxy asks for it" do
      ENV["GORI_SPEC_SOCKS_PASS"] = "socks-pass"
      with_socks5_proxy(auth_method: 2_u8) do |sport, seen|
        Gori::Settings.upstream_rules = [
          rule("*", "socks5h", "127.0.0.1:#{sport}", "alice", "GORI_SPEC_SOCKS_PASS"),
        ]
        sock = Gori::Proxy::Upstream.dial("example.test", 443)
        sock.should_not be_nil
        got = seen.receive
        sock.try(&.close) rescue nil

        got[:user].should eq("alice")
        got[:pass].should eq("socks-pass")
        got[:atyp].should eq(3_u8)
        got[:addr].should eq("example.test")
      end
    ensure
      ENV.delete("GORI_SPEC_SOCKS_PASS")
      reset_upstream
    end

    it "fails the dial when the proxy rejects the credentials" do
      ENV["GORI_SPEC_SOCKS_PASS"] = "wrong"
      with_socks5_proxy(auth_method: 2_u8, auth_ok: false) do |sport, _seen|
        Gori::Settings.upstream_rules = [
          rule("*", "socks5h", "127.0.0.1:#{sport}", "alice", "GORI_SPEC_SOCKS_PASS"),
        ]
        Gori::Proxy::Upstream.dial("example.test", 443).should be_nil
      end
    ensure
      ENV.delete("GORI_SPEC_SOCKS_PASS")
      reset_upstream
    end

    it "reports rejected Project settings credentials as a proxy error" do
      with_socks5_proxy(auth_method: 2_u8, auth_ok: false) do |sport, _seen|
        Gori::Settings.project_upstream_proxy = "socks5h://127.0.0.1:#{sport}"
        Gori::Settings.project_upstream_auth =
          Gori::Settings::ProjectProxyAuth.new("socks5", "project-user", "wrong")

        sock, error = Gori::Proxy::Upstream.dial_result("example.test", 443)
        sock.should be_nil
        error.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Proxy)
        error.try(&.detail).to_s.should contain("refused the tunnel")
      end
    ensure
      reset_upstream
    end

    it "fails a local-DNS SOCKS5 dial before contacting the proxy when resolution fails" do
      server = TCPServer.new("127.0.0.1", 0)
      Gori::Settings.upstream_proxy = "socks5://127.0.0.1:#{server.local_address.port}"

      sock, error = Gori::Proxy::Upstream.dial_result("does-not-exist.invalid", 443)
      sock.should be_nil
      error.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Dns)

      accepted = Channel(Nil).new(1)
      spawn do
        conn = server.accept
        conn.close rescue nil
        accepted.send(nil)
      rescue
      end
      contacted = select
      when accepted.receive then true
      when timeout(20.milliseconds) then false
      end
      contacted.should be_false
    ensure
      server.try(&.close) rescue nil
      reset_upstream
    end

    # 0xFF is "no acceptable methods" — the dial must fail rather than proceed onto a socket
    # that is not a tunnel.
    it "fails the dial when the proxy accepts no offered auth method" do
      with_socks5_proxy(auth_method: 0xFF_u8) do |sport, _seen|
        Gori::Settings.upstream_rules = [rule("*", "socks5h", "127.0.0.1:#{sport}")]
        Gori::Proxy::Upstream.dial("example.test", 443).should be_nil
      end
    ensure
      reset_upstream
    end
  end

  describe ".upstream_rule_error" do
    it "accepts a well-formed rule of each kind" do
      Gori::Settings.upstream_rule_error(rule("*", "direct")).should be_nil
      Gori::Settings.upstream_rule_error(rule("a.test", "http", "p.test:3128")).should be_nil
      Gori::Settings.upstream_rule_error(rule("a.test", "socks5", "127.0.0.1:1080")).should be_nil
      Gori::Settings.upstream_rule_error(rule("a.test", "socks5h", "127.0.0.1:1080")).should be_nil
    end

    it "rejects a missing host, an unknown kind, and a proxy rule with no address" do
      Gori::Settings.upstream_rule_error(rule(" ", "http", "p.test:1")).to_s.should contain("host pattern")
      Gori::Settings.upstream_rule_error(rule("a.test", "socks4", "p.test:1")).to_s.should contain("kind must be")
      Gori::Settings.upstream_rule_error(rule("a.test", "http", "")).to_s.should contain("needs an address")
    end

    it "rejects a bad port, so a typo can't silently resolve to the default" do
      Gori::Settings.upstream_rule_error(rule("a.test", "http", "p.test:8O80")).to_s.should contain("invalid upstream proxy port")
    end

    # An address on a direct rule means the operator meant http/socks5; accepting it would
    # route the host DIRECT and look like the rule did nothing.
    it "rejects an address on a direct rule" do
      Gori::Settings.upstream_rule_error(rule("a.test", "direct", "p.test:1")).to_s.should contain("no address")
    end

    # password_env holds a NAME. A "$VALUE" here means the operator expected gori's env
    # expansion, which deliberately is not used (it would put the secret in settings.json).
    it "rejects a $-prefixed password_env, which would be a value not a variable name" do
      Gori::Settings.upstream_rule_error(rule("a.test", "http", "p.test:1", "u", "$SECRET")).to_s
        .should contain("environment variable NAME")
    end
  end

  # Every dial failure used to collapse into one nil socket, so an upstream proxy refusing the
  # tunnel arrived at the operator as "host unreachable (DNS/refused/timeout)" — naming the
  # ORIGIN, a machine gori had never tried to contact. These assert the reason survives the
  # dialer and reaches the send path.
  describe "a refused CONNECT" do
    it "identifies rejected Project settings credentials without printing the password" do
      with_refusing_http_proxy(407, "Proxy Authentication Required") do |pport|
        Gori::Settings.project_upstream_proxy = "http://127.0.0.1:#{pport}"
        Gori::Settings.project_upstream_auth =
          Gori::Settings::ProjectProxyAuth.new("basic", "alice", "do-not-print")
        _, err = Gori::Proxy::Upstream.dial_result("example.test", 443)
        detail = err.try(&.detail).to_s
        detail.should contain("configured upstream proxy credentials were rejected")
        detail.should_not contain("do-not-print")
      end
    ensure
      reset_upstream
    end

    it "names the proxy and the status it returned, not the origin" do
      with_refusing_http_proxy(407, "Proxy Authentication Required") do |pport|
        Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}")]
        sock, err = Gori::Proxy::Upstream.dial_result("example.test", 443)
        sock.should be_nil
        err.try(&.kind).should eq(Gori::Proxy::Upstream::DialErrorKind::Proxy)
        detail = err.try(&.detail).to_s
        detail.should contain("upstream HTTP proxy 127.0.0.1:#{pport}")
        detail.should contain("407 Proxy Authentication Required")
        detail.should contain("requires authentication")
        detail.should_not contain("unreachable")
      end
    ensure
      reset_upstream
    end

    it "distinguishes 403 (an ACL) from 407 (a credential)" do
      with_refusing_http_proxy(403, "Forbidden") do |pport|
        Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}")]
        _, err = Gori::Proxy::Upstream.dial_result("example.test", 443)
        err.try(&.detail).to_s.should contain("ACL does not permit CONNECT")
      end
    ensure
      reset_upstream
    end

    # The whole point of carrying the reason: it has to reach the sentence an operator reads.
    # `Repeater::Engine` is the dial seam for repeater, fuzz, mine, sequence, discover and MCP
    # alike, so pinning it here pins all of them.
    it "reaches the send path's error string instead of 'host unreachable'" do
      with_refusing_http_proxy(407, "Proxy Authentication Required") do |pport|
        Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}")]
        result = Gori::Repeater::Engine.send("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".to_slice,
          scheme: "http", host: "example.test", port: 80, verify_upstream: false)
        msg = result.error.to_s
        msg.should contain("407")
        msg.should contain("upstream HTTP proxy 127.0.0.1:#{pport}")
        msg.should_not contain("DNS/refused/timeout")
      end
    ensure
      reset_upstream
    end

    # A proxy address that answers nothing at all is still a proxy problem, and must not be
    # reported against the origin either.
    it "says the PROXY is unreachable when the proxy itself cannot be dialled" do
      srv = TCPServer.new("127.0.0.1", 0)
      pport = srv.local_address.port
      srv.close
      Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}")]
      sock, err = Gori::Proxy::Upstream.dial_result("example.test", 443)
      sock.should be_nil
      err.try(&.detail).to_s.should contain("upstream HTTP proxy 127.0.0.1:#{pport} unreachable")
      err.try(&.detail).to_s.should contain("the origin was never contacted")
    ensure
      reset_upstream
    end
  end

  # A rule that NAMES a password variable is a statement that a password is required. gori
  # used to read the unset variable, get nil, and send `Basic base64("bob:")` — an empty
  # password the proxy answers 407 to, which the dialer then collapsed. The name of the
  # variable is the whole answer and nothing downstream can recover it.
  describe "an unset password_env" do
    it "refuses before the socket and names the variable" do
      ENV.delete("GORI_SPEC_UNSET_PW")
      with_refusing_http_proxy(407, "Proxy Authentication Required") do |pport|
        Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}", "bob", "GORI_SPEC_UNSET_PW")]
        sock, err = Gori::Proxy::Upstream.dial_result("example.test", 443)
        sock.should be_nil
        detail = err.try(&.detail).to_s
        detail.should contain("$GORI_SPEC_UNSET_PW is unset")
        detail.should contain("export it")
      end
    ensure
      ENV.delete("GORI_SPEC_UNSET_PW")
      reset_upstream
    end

    # The control: with the variable exported, the same rule dials and authenticates. Without
    # it the example above could pass on any refusal at all.
    it "dials normally once the variable is exported" do
      ENV["GORI_SPEC_UNSET_PW"] = "s3cr3t"
      with_capturing_http_proxy do |pport, head|
        Gori::Settings.upstream_rules = [rule("*", "http", "127.0.0.1:#{pport}", "bob", "GORI_SPEC_UNSET_PW")]
        sock, err = Gori::Proxy::Upstream.dial_result("example.test", 443)
        sock.should_not be_nil
        err.should be_nil
        head.receive.should contain("Proxy-Authorization: Basic #{Base64.strict_encode("bob:s3cr3t")}")
        sock.try(&.close) rescue nil
      end
    ensure
      ENV.delete("GORI_SPEC_UNSET_PW")
      reset_upstream
    end

    # A username with NO password_env is untouched: some proxies key on the username alone,
    # and that was never the broken case.
    it "leaves a username-only rule alone" do
      Gori::Settings.upstream_rules = [rule("a.test", "http", "p.test:3128", "bob")]
      Gori::Settings.upstream_route("a.test").credential_error.should be_nil
    ensure
      reset_upstream
    end
  end
end
