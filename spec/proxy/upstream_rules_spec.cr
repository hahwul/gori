require "../spec_helper"
require "socket"

# Restore every knob upstream_route consults, so one example can't leak a route into the next.
private def reset_upstream : Nil
  Gori::Settings.upstream_rules = [] of Gori::Settings::UpstreamRule
  Gori::Settings.upstream_proxy = ""
  Gori::Settings.project_upstream_proxy = nil
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

    it "defaults the port per kind: 8080 for http, 1080 for socks5" do
      Gori::Settings.upstream_rules = [rule("a.test", "http", "p.test"), rule("b.test", "socks5", "s.test")]
      Gori::Settings.upstream_route("a.test").port.should eq(8080)
      Gori::Settings.upstream_route("b.test").port.should eq(1080)
      Gori::Settings.upstream_route("b.test").socks5?.should be_true
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

    # A hand-edited file can hold a rule the validator would have rejected. Degrading to
    # direct beats failing every dial for the host.
    it "degrades a proxy rule with no address to direct" do
      Gori::Settings.upstream_rules = [rule("a.test", "http", "")]
      Gori::Settings.upstream_route("a.test").direct?.should be_true
    ensure
      reset_upstream
    end
  end

  describe "HTTP proxy authentication" do
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
    it "reaches a hostname target through a SOCKS5 proxy, letting the proxy resolve it" do
      with_socks5_proxy do |sport, seen|
        Gori::Settings.upstream_rules = [rule("*", "socks5", "127.0.0.1:#{sport}")]
        sock = Gori::Proxy::Upstream.dial("example.test", 443)
        sock.should_not be_nil
        got = seen.receive
        sock.try(&.close) rescue nil

        got[:atyp].should eq(3_u8) # ATYP DOMAIN — remote resolution ("socks5h"), not a local lookup
        got[:addr].should eq("example.test")
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
          rule("*", "socks5", "127.0.0.1:#{sport}", "alice", "GORI_SPEC_SOCKS_PASS"),
        ]
        sock = Gori::Proxy::Upstream.dial("example.test", 443)
        sock.should_not be_nil
        got = seen.receive
        sock.try(&.close) rescue nil

        got[:user].should eq("alice")
        got[:pass].should eq("socks-pass")
      end
    ensure
      ENV.delete("GORI_SPEC_SOCKS_PASS")
      reset_upstream
    end

    it "fails the dial when the proxy rejects the credentials" do
      ENV["GORI_SPEC_SOCKS_PASS"] = "wrong"
      with_socks5_proxy(auth_method: 2_u8, auth_ok: false) do |sport, _seen|
        Gori::Settings.upstream_rules = [
          rule("*", "socks5", "127.0.0.1:#{sport}", "alice", "GORI_SPEC_SOCKS_PASS"),
        ]
        Gori::Proxy::Upstream.dial("example.test", 443).should be_nil
      end
    ensure
      ENV.delete("GORI_SPEC_SOCKS_PASS")
      reset_upstream
    end

    # 0xFF is "no acceptable methods" — the dial must fail rather than proceed onto a socket
    # that is not a tunnel.
    it "fails the dial when the proxy accepts no offered auth method" do
      with_socks5_proxy(auth_method: 0xFF_u8) do |sport, _seen|
        Gori::Settings.upstream_rules = [rule("*", "socks5", "127.0.0.1:#{sport}")]
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
end
