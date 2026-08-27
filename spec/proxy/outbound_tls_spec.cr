require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

include Gori::Proxy::Tls

private def reset_outbound_tls : Nil
  Gori::Settings.outbound_tls = [] of Gori::Settings::OutboundTlsRule
end

private def tls_rule(host : String, cert : String = "", key : String = "",
                     min_version : String = "", max_version : String = "",
                     ciphers : String = "",
                     permissive : Bool = false,
                     preset : String = "", groups : String = "", sigalgs : String = "",
                     ciphersuites : String = "", alpn : Array(String) = [] of String,
                     session_tickets : Bool? = nil,
                     ocsp_stapling : Bool? = nil) : Gori::Settings::OutboundTlsRule
  Gori::Settings::OutboundTlsRule.new(host, cert, key, min_version, max_version, ciphers,
    permissive, preset, groups, sigalgs, ciphersuites, alpn, session_tickets, ocsp_stapling)
end

# The ClientHello a policy actually produces, parsed. Everything in the fingerprint section
# below asserts on THIS rather than on the settings that were fed in — the whole point of
# #822 is that a knob which does not reach the wire is indistinguishable from one that does.
private def hello_for(rule : Gori::Settings::OutboundTlsRule,
                      alpn : String? = nil) : Gori::Proxy::Tls::Fingerprint::Hello
  ctx = Gori::Proxy::Upstream.context_for_policy(rule, verify: false, alpn: alpn)
  Gori::Proxy::Tls::Fingerprint.parse(Gori::Proxy::Tls::Fingerprint.hello_bytes(ctx)).not_nil!
end

# host → rule → context, the chain a dial walks (`dial_tls_result` looks the policy up on the
# DIALED host, then hands it to `client_context`).
private def context_for_host(host : String, alpn : String? = "h2") : OpenSSL::SSL::Context::Client
  Gori::Proxy::Upstream.context_for_policy(
    Gori::Settings.outbound_tls_for(host), verify: false, alpn: alpn)
end

private def alpn_names(hello : Gori::Proxy::Tls::Fingerprint::Hello) : Array(String)
  hello.alpn.map { |b| String.new(b) }
end

# Drive a real settings.json through `Settings.load`, then put the process back.
#
# The restore is not optional and is not only about this section: settings.cr states plainly
# that "a full load rewrites every section's class properties", so an example that loads a
# temp file and walks away leaves bind_port, retention, listeners, tabs and the rest at
# whatever that file implied — for every spec that runs afterwards. Reloading from the
# restored GORI_HOME at the end is what makes this example order-independent.
private def with_settings_file(json : String, &)
  dir = File.tempname("gori-outbound-tls")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.path_override = nil
    File.write(File.join(dir, "settings.json"), json)
    Gori::Settings.load
    yield dir
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.path_override = nil
    Gori::Settings.load # back to what the suite's own home says, section by section
    reset_outbound_tls
    FileUtils.rm_rf(dir)
  end
end

# A TLS origin that advertises h2 over ALPN and answers HTTP/1.1 bytes, so a dial can be asked
# what it NEGOTIATED. The h2 advertisement is what makes the offer observable: an origin that
# never offers h2 would report the same thing whatever gori sent.
private def start_h2_alpn_origin : TCPServer
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: true)
  server = TCPServer.new("127.0.0.1", 0)
  # Returns the SERVER, not the port: closing it is what ends the accept loop below, and an
  # example that leaked one would keep a bound port and a scheduled fiber for the rest of the
  # suite.
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  server
end

# Write a self-signed cert + key pair to disk and yield their paths — what a client certificate
# actually is on this path (PEM files, not inline material).
private def with_client_cert(&)
  dir = File.tempname("gori-client-cert")
  Dir.mkdir_p(dir)
  cert_path = File.join(dir, "client.crt.pem")
  key_path = File.join(dir, "client.key.pem")
  cert, key = CertBuilder.build_root("client.test")
  cert.write_pem(cert_path)
  key.write_pem(key_path)
  begin
    yield cert_path, key_path
  ensure
    FileUtils.rm_rf(dir)
  end
end

# A TLS server that ASKS for a client certificate and reports the subject it received, so mutual
# TLS is asserted by what the server saw rather than by "the handshake didn't blow up".
#
# `client_ca` is trusted so a presented certificate verifies; without it OpenSSL checks the
# client chain against an empty store and aborts the handshake, which would make this helper
# report a failure for the very case it is meant to observe. VerifyMode::PEER *without*
# FAIL_IF_NO_PEER_CERT is deliberate: a client that presents nothing must still connect, which
# is what the control example asserts.
private def start_mtls_origin(seen : Channel(String), client_ca : String? = nil) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::PEER
  ctx.ca_certificates = client_ca if client_ca
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        peer = ssl.peer_certificate
        seen.send(peer ? peer.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",") : "(none)")
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        ssl.flush
        ssl.close
      rescue
        seen.send("(handshake failed)") rescue nil
      end
    end
  end
  port
end

# A server that will speak ANY version from TLS 1.0 to 1.3 and reports what was actually
# negotiated. That range is the whole point: a ceiling is only observable against an origin
# that would otherwise have gone higher. `cipher: true` reports the negotiated cipher suite
# instead of the version — the second half of the same claim.
private def start_version_origin(seen : Channel(String), cipher : Bool = false) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  ctx.security_level = 0
  ctx.ciphers = "ALL:@SECLEVEL=0"
  ctx.remove_options(OpenSSL::SSL::Options.flags(NO_TLS_V1, NO_TLS_V1_1, NO_TLS_V1_2, NO_TLS_V1_3))
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        seen.send(cipher ? ssl.cipher : ssl.tls_version)
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        ssl.flush
        ssl.close
      rescue
        seen.send("(handshake failed)") rescue nil
      end
    end
  end
  port
end

describe "outbound TLS policy" do
  describe ".outbound_tls_for" do
    it "returns the first matching rule, else the all-defaults policy" do
      Gori::Settings.outbound_tls = [
        tls_rule("api.acme.test", min_version: "tls1.0"),
        tls_rule("*", min_version: "tls1.2"),
      ]
      Gori::Settings.outbound_tls_for("api.acme.test").min_version.should eq("tls1.0")
      Gori::Settings.outbound_tls_for("other.test").min_version.should eq("tls1.2")

      reset_outbound_tls
      Gori::Settings.outbound_tls_for("anything.test").default?.should be_true
    ensure
      reset_outbound_tls
    end

    it "covers subdomains and is case-insensitive (shared host dialect)" do
      Gori::Settings.outbound_tls = [tls_rule("Acme.TEST", min_version: "tls1.1")]
      Gori::Settings.outbound_tls_for("api.acme.test").min_version.should eq("tls1.1")
      Gori::Settings.outbound_tls_for("acme.test.evil.test").default?.should be_true
    ensure
      reset_outbound_tls
    end
  end

  # This is the trap both #434 and #437 flagged: the TLS context cache was keyed on
  # {verify, alpn} only. Any policy field left out of the key means the FIRST context built
  # wins for the whole process — a client certificate would be presented to hosts it was never
  # configured for, and a settings change would silently do nothing.
  describe "context cache key" do
    it "gives every distinct policy its own key, and shares ONE key for the defaults" do
      keys = [
        tls_rule("a", cert: "/c.pem", key: "/k.pem"),
        tls_rule("a", cert: "/other.pem", key: "/k.pem"),
        tls_rule("a", min_version: "tls1.0"),
        tls_rule("a", min_version: "tls1.3"),
        tls_rule("a", max_version: "tls1.2"),
        tls_rule("a", ciphers: "DEFAULT@SECLEVEL=0"),
        tls_rule("a", permissive: true),
      ].map(&.cache_key)

      keys.uniq.size.should eq(keys.size) # no two distinct policies collide
      keys.should_not contain("")         # every non-default policy is distinguishable

      # All-defaults policies share the empty key, so the common case keeps one shared context.
      tls_rule("a").cache_key.should eq("")
      tls_rule("b").cache_key.should eq("")
      Gori::Settings::DEFAULT_OUTBOUND_TLS.cache_key.should eq("")
    end

    # Concatenating fields without a separator would let two different policies produce one
    # key (a cert path ending exactly where the next field begins).
    it "does not let differently-split fields collide into one key" do
      tls_rule("a", cert: "/ab", key: "/c").cache_key
        .should_not eq(tls_rule("a", cert: "/a", key: "b/c").cache_key)
    end
  end

  describe "client certificates (mutual TLS)" do
    it "presents the configured certificate to a server that asks for one" do
      seen = Channel(String).new(2)
      with_client_cert do |cert, key|
        port = start_mtls_origin(seen, client_ca: cert)
        Gori::Settings.outbound_tls = [tls_rule("localhost", cert: cert, key: key)]
        sock = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        sock.should_not be_nil
        seen.receive.should contain("client.test") # the origin saw OUR certificate
        sock.try(&.close) rescue nil
      end
    ensure
      reset_outbound_tls
    end

    # The control: same origin, same dial, no rule — nothing is presented. Without this, the
    # test above could pass on a server that happened to report something.
    it "presents nothing when no rule covers the host" do
      seen = Channel(String).new(2)
      port = start_mtls_origin(seen)
      reset_outbound_tls
      sock = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
      sock.should_not be_nil
      seen.receive.should eq("(none)")
      sock.try(&.close) rescue nil
    ensure
      reset_outbound_tls
    end

    # The consequence of the cache-key fix, stated as behaviour: a certificate configured for
    # one host must not leak to another host dialed later in the same process.
    it "does not leak one host's certificate to a host with no rule" do
      seen = Channel(String).new(4)
      with_client_cert do |cert, key|
        port = start_mtls_origin(seen, client_ca: cert)
        # 127.0.0.1 and localhost are the same origin but different rule keys.
        Gori::Settings.outbound_tls = [tls_rule("localhost", cert: cert, key: key)]
        a = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        seen.receive.should contain("client.test")
        a.try(&.close) rescue nil

        b = Gori::Proxy::Upstream.dial_tls("127.0.0.1", port, verify: false)
        seen.receive.should eq("(none)") # a cached context would have re-presented the cert
        b.try(&.close) rescue nil
      end
    ensure
      reset_outbound_tls
    end
  end

  describe "protocol floor" do
    # Crystal's Context::Client.new adds NO_TLS_V1 | NO_TLS_V1_1, which is exactly why a
    # legacy appliance was unreachable at ANY setting before this. Asserted against a real
    # TLS 1.0-only server, so it pins the behaviour rather than the flag arithmetic.
    it "reaches a TLS 1.0-only origin only when the floor is lowered" do
      cert, key = CertBuilder.build_root("legacy.test")
      ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
      ctx.security_level = 0
      ctx.ciphers = "ALL:@SECLEVEL=0"
      # Force TLS 1.0 only: forbid everything above it.
      ctx.add_options(OpenSSL::SSL::Options.flags(NO_TLS_V1_2, NO_TLS_V1_3))
      ctx.remove_options(OpenSSL::SSL::Options.flags(NO_TLS_V1, NO_TLS_V1_1))
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      spawn do
        while raw = server.accept?
          begin
            ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
            ssl << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
            ssl.flush
            ssl.close
          rescue
          end
        end
      end

      begin
        # Default policy: the constructor's NO_TLS_V1/NO_TLS_V1_1 makes this unreachable.
        reset_outbound_tls
        Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false).should be_nil

        # Floor lowered + legacy ciphers allowed: it connects.
        Gori::Settings.outbound_tls = [
          tls_rule("localhost", min_version: "tls1.0", ciphers: "ALL:@SECLEVEL=0", permissive: true),
        ]
        sock = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        sock.should_not be_nil
        sock.try(&.close) rescue nil
      ensure
        server.close rescue nil
        reset_outbound_tls
      end
    end
  end

  # A floor alone cannot CHOOSE a version: against an origin that also speaks 1.3 the
  # handshake always landed on 1.3, which is what made `ciphers` dead too (OpenSSL's cipher
  # list governs TLS 1.2 and below only). These assert the version the ORIGIN negotiated, not
  # the option flags, because the flags were never the claim in doubt.
  describe "protocol ceiling" do
    it "pins the negotiated version below an origin's best offer" do
      seen = Channel(String).new(4)
      port = start_version_origin(seen)
      begin
        # Control: no ceiling → the origin's best, TLS 1.3.
        reset_outbound_tls
        a = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        a.should_not be_nil
        seen.receive.should eq("TLSv1.3")
        a.try(&.close) rescue nil

        # Ceiling at 1.2 against the SAME origin.
        Gori::Settings.outbound_tls = [tls_rule("localhost", max_version: "tls1.2", permissive: true)]
        b = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        b.should_not be_nil
        seen.receive.should eq("TLSv1.2")
        b.try(&.close) rescue nil
      ensure
        reset_outbound_tls
      end
    end

    # The consequence the ceiling exists for: with the negotiation held at 1.2, the cipher
    # list finally applies. Without a ceiling this rule is silently ignored.
    it "makes the cipher list reachable once the negotiation is held at 1.2" do
      seen = Channel(String).new(4)
      port = start_version_origin(seen, cipher: true)
      begin
        Gori::Settings.outbound_tls = [
          tls_rule("localhost", min_version: "tls1.2", max_version: "tls1.2",
            ciphers: "ECDHE-ECDSA-AES128-SHA", permissive: true),
        ]
        sock = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        sock.should_not be_nil
        seen.receive.should eq("ECDHE-ECDSA-AES128-SHA")
        sock.try(&.close) rescue nil
      ensure
        reset_outbound_tls
      end
    end
  end

  # ── #822: the ClientHello gori sends ──────────────────────────────────────────────────────
  #
  # Every example here reads the hello OpenSSL actually wrote for the policy, never the policy
  # fields that were fed in. A knob that does not reach the wire is exactly the failure this
  # issue exists to stop, and it is invisible to any assertion made on the settings alone.
  describe "fingerprint knobs" do
    it "puts the configured groups on the wire, in the configured order" do
      # 23 = secp256r1, 29 = x25519. Reversed from OpenSSL's own preference, so the ORDER is
      # part of the claim and not an accident of the default.
      hello_for(tls_rule("a", groups: "P-256:X25519")).groups.should eq([23, 29])
      hello_for(tls_rule("a", groups: "X25519:P-256")).groups.should eq([29, 23])
    end

    it "puts the configured signature algorithms on the wire, in order" do
      hello = hello_for(tls_rule("a", sigalgs: "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256"))
      hello.sig_algs.should eq([0x0403, 0x0804])
    end

    # `ciphers` cannot reach these — SSL_CTX_set_cipher_list governs TLS 1.2 and below — which
    # is the whole reason the field exists.
    it "narrows the TLS 1.3 suites, which the TLS 1.2 cipher list cannot touch" do
      hello = hello_for(tls_rule("a", ciphersuites: "TLS_CHACHA20_POLY1305_SHA256"))
      hello.ciphers.should contain(0x1303)
      hello.ciphers.should_not contain(0x1301)
    end

    it "offers an ORDERED ALPN list, which the single-protocol setter could not express" do
      alpn_names(hello_for(tls_rule("a", alpn: ["h2", "http/1.1"]), alpn: "h2"))
        .should eq(["h2", "http/1.1"])
      alpn_names(hello_for(tls_rule("a", alpn: ["http/1.1", "h2"]), alpn: "h2"))
        .should eq(["http/1.1", "h2"])
    end

    # 0x0023 session_ticket and 0x0005 status_request: both are present-or-absent facts about
    # the hello, and both move the fingerprint.
    it "drops session_ticket when tickets are switched off" do
      hello_for(tls_rule("a")).extensions.should contain(0x0023)
      hello_for(tls_rule("a", session_tickets: false)).extensions.should_not contain(0x0023)
    end

    it "adds status_request when OCSP stapling is requested" do
      hello_for(tls_rule("a")).extensions.should_not contain(0x0005)
      hello_for(tls_rule("a", ocsp_stapling: true)).extensions.should contain(0x0005)
    end
  end

  # The single most likely bug in #822, named as such in the issue: a new field left out of
  # `cache_key` means two destinations with DIFFERENT fingerprints quietly share one SSL_CTX,
  # and the second one silently sends the first one's ClientHello.
  describe "fingerprint cache key" do
    it "gives every distinct fingerprint policy its own key" do
      keys = [
        tls_rule("a", preset: "chrome"),
        tls_rule("a", preset: "firefox"),
        tls_rule("a", groups: "X25519"),
        tls_rule("a", groups: "P-256"),
        tls_rule("a", sigalgs: "rsa_pss_rsae_sha256"),
        tls_rule("a", ciphersuites: "TLS_AES_128_GCM_SHA256"),
        tls_rule("a", alpn: ["h2"]),
        tls_rule("a", alpn: ["h2", "http/1.1"]),
        tls_rule("a", alpn: ["http/1.1", "h2"]),
        tls_rule("a", session_tickets: false),
        tls_rule("a", session_tickets: true),
        tls_rule("a", ocsp_stapling: false),
        tls_rule("a", ocsp_stapling: true),
      ].map(&.cache_key)

      keys.uniq.size.should eq(keys.size)
      keys.should_not contain("") # every one of them is non-default
    end

    # An ALPN identifier is an arbitrary byte string, and a hand-edited settings.json is not
    # required to hold to the supported list. Flattening the array on a delimiter would let
    # one bogus protocol and two real ones produce the same key — and then one destination
    # would send the other's ClientHello, which is the exact failure the key exists to stop.
    it "does not let one ALPN entry collide with two that concatenate to it" do
      tls_rule("a", alpn: ["h2,http/1.1"]).cache_key
        .should_not eq(tls_rule("a", alpn: ["h2", "http/1.1"]).cache_key)
      tls_rule("a", alpn: ["h2h", "ttp/1.1"]).cache_key
        .should_not eq(tls_rule("a", alpn: ["h2", "http/1.1"]).cache_key)
    end

    # The behavioural half: not "the keys differ" but "the CONTEXTS differ, and the bytes they
    # produce differ". A cache_key that is right for the wrong reason still fails this.
    it "does not let two differently-fingerprinted destinations share one SSL context" do
      Gori::Settings.outbound_tls = [
        tls_rule("chrome.test", preset: "chrome"),
        tls_rule("firefox.test", preset: "firefox"),
      ]
      # Resolved the way a dial resolves it: host → rule → context.
      a = context_for_host("chrome.test")
      b = context_for_host("firefox.test")
      a.should_not be(b)

      fa = Fingerprint.of_context(a).not_nil!
      fb = Fingerprint.of_context(b).not_nil!
      fa.ja3.should_not eq(fb.ja3)
      fa.ja4_r.should_not eq(fb.ja4_r)

      # …and the cache still IS a cache: the same policy asked for twice is one context.
      context_for_host("chrome.test").should be(a)
    ensure
      reset_outbound_tls
    end
  end

  # The composition rule between what the CALLER asked for and what the DESTINATION configured.
  # It is a safety rule before it is a fingerprint one — see ClientShape.alpn_offer.
  describe "ALPN offer composition" do
    it "keeps today's behaviour when nothing is configured" do
      ClientShape.alpn_offer(nil, [] of String).should be_nil
      ClientShape.alpn_offer("h2", [] of String).should eq(["h2"])
    end

    it "uses the configured list verbatim on a leg that can take h2" do
      ClientShape.alpn_offer("h2", ["h2", "http/1.1"]).should eq(["h2", "http/1.1"])
    end

    # The load-bearing one. An origin that selected h2 on a leg gori is about to write
    # HTTP/1.1 into would corrupt the connection with no error anywhere.
    it "never offers h2 on a leg the caller will speak HTTP/1.1 on" do
      ClientShape.alpn_offer(nil, ["h2", "http/1.1"]).should eq(["http/1.1"])
      ClientShape.alpn_offer(nil, ["h2"]).should be_nil
    end

    # Asserted against a real origin that WOULD take h2, so the rule above is a fact about the
    # handshake rather than about a pure function.
    it "is what an origin actually sees" do
      server = start_h2_alpn_origin
      port = server.local_address.port
      begin
        reset_outbound_tls
        control = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false, alpn: "h2")
        control.should_not be_nil
        control.try(&.alpn_protocol).should eq("h2")
        control.try(&.close) rescue nil

        Gori::Settings.outbound_tls = [tls_rule("localhost", alpn: ["h2", "http/1.1"])]
        tunnelled = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false, alpn: "h2")
        tunnelled.try(&.alpn_protocol).should eq("h2")
        tunnelled.try(&.close) rescue nil

        # Same rule, the forced-HTTP/1.1 leg: h2 is withheld, so the origin cannot pick it.
        forced = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        forced.should_not be_nil
        forced.try(&.alpn_protocol).should be_nil
        forced.try(&.close) rescue nil
      ensure
        server.close rescue nil
        reset_outbound_tls
      end
    end
  end

  describe "presets" do
    # A preset that this build's OpenSSL refuses raises at the FIRST DIAL, on a host the
    # operator chose it for, with a message that reads like the origin's TLS leg refusing.
    #
    # This example is a CROSS-PLATFORM gate, not a local tautology, and it has already earned
    # its keep: Debian and Ubuntu ship OpenSSL with SHA-1 signature algorithms refused outright
    # by `SSL_CTX_set1_sigalgs_list`, which macOS accepts at every security level — so the
    # `ecdsa_sha1`/`rsa_pkcs1_sha1` tail that Firefox and Safari really do send was green here
    # and red on CI. A preset edit is not verified until this has run on Linux.
    it "is accepted by the linked OpenSSL, every one of them" do
      Gori::Settings::TLS_PRESET_NAMES.each do |name|
        Gori::Settings::TLS_PRESETS.has_key?(name).should be_true
        Gori::Settings.outbound_tls_error(tls_rule("a.test", preset: name)).should be_nil
      end
    end

    it "reaches the wire — every preset offers the browser ALPN pair" do
      Gori::Settings::TLS_PRESET_NAMES.each do |name|
        alpn_names(hello_for(tls_rule("a", preset: name), alpn: "h2"))
          .should eq(["h2", "http/1.1"])
      end
    end

    it "gives each browser preset a distinct fingerprint" do
      ja4s = %w[chrome firefox safari].map do |name|
        Fingerprint.of_context(
          Gori::Proxy::Upstream.context_for_policy(tls_rule("a", preset: name), false, "h2")
        ).not_nil!.ja4_r
      end
      ja4s.uniq.size.should eq(3)
    end

    # The `curl` preset configures nothing but ALPN, on purpose: curl on OpenSSL sends
    # OpenSSL's hello. If it ever grew a groups/sigalgs list this would catch the drift.
    it "leaves the curl preset at this build's stock hello apart from ALPN" do
      curl = tls_rule("a", preset: "curl")
      curl.effective_groups.should eq("")
      curl.effective_sigalgs.should eq("")
      curl.effective_ciphersuites.should eq("")
      curl.effective_ocsp_stapling?.should be_false
    end

    it "lets a rule's own field override the preset it names" do
      rule = tls_rule("a", preset: "chrome", groups: "P-521")
      rule.effective_groups.should eq("P-521")
      rule.effective_sigalgs.should eq(Gori::Settings::TLS_PRESETS["chrome"].sigalgs)
      hello_for(rule).groups.should eq([25]) # secp521r1 — the rule's value, not chrome's
    end

    # Why the two booleans are nilable: with a preset in play, "not stated" and "stated false"
    # have to be different answers or an explicit `false` could never override a preset's true.
    it "distinguishes an unstated boolean from an explicit false" do
      tls_rule("a", preset: "chrome").effective_ocsp_stapling?.should be_true
      tls_rule("a", preset: "chrome", ocsp_stapling: false).effective_ocsp_stapling?.should be_false
      tls_rule("a").effective_ocsp_stapling?.should be_false
      tls_rule("a", session_tickets: false).effective_session_tickets?.should be_false
      tls_rule("a").effective_session_tickets?.should be_true
    end
  end

  describe ".outbound_tls_error" do
    it "accepts a rule with neither half of a certificate pair" do
      Gori::Settings.outbound_tls_error(tls_rule("a.test", min_version: "tls1.2")).should be_nil
    end

    it "accepts a readable cert/key pair" do
      with_client_cert do |cert, key|
        Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: cert, key: key)).should be_nil
      end
    end

    it "rejects half a pair, since one half alone can never complete a handshake" do
      Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: "/tmp/c.pem")).to_s
        .should contain("BOTH client_cert and client_key")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", key: "/tmp/k.pem")).to_s
        .should contain("BOTH client_cert and client_key")
    end

    it "rejects an unreadable file at save time rather than at the first dial" do
      Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: "/nope/c.pem", key: "/nope/k.pem")).to_s
        .should contain("client_cert not readable")
    end

    it "rejects a missing host and an unknown min_version" do
      Gori::Settings.outbound_tls_error(tls_rule(" ")).to_s.should contain("host pattern")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", min_version: "ssl3")).to_s
        .should contain("min_version must be one of")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", max_version: "ssl3")).to_s
        .should contain("max_version must be one of")
    end

    # An inverted pair offers no protocol version at all; OpenSSL's error would name the
    # ORIGIN, so the disagreement has to be caught where the two fields are visible.
    it "rejects a floor above the ceiling, and accepts a pin where they are equal" do
      Gori::Settings.outbound_tls_error(tls_rule("a.test", min_version: "tls1.3", max_version: "tls1.2")).to_s
        .should contain("is above max_version")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", min_version: "tls1.2", max_version: "tls1.2"))
        .should be_nil
    end

    # An encrypted key makes OpenSSL prompt for a passphrase on the terminal the TUI owns —
    # the process would look hung with no visible prompt.
    it "rejects a passphrase-protected key, naming the fix" do
      with_client_cert do |cert, key|
        File.write(key, "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n")
        msg = Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: cert, key: key)).to_s
        msg.should contain("passphrase-protected")
        msg.should contain("openssl pkey")
      end
    end

    it "rejects a traditional-format key carrying the legacy Proc-Type header" do
      with_client_cert do |cert, key|
        File.write(key, "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,00\n\nAAAA\n")
        Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: cert, key: key)).to_s
          .should contain("passphrase-protected")
      end
    end

    # #822's last acceptance criterion. Each of these would otherwise reach `apply_outbound_tls`
    # and raise there — at the first dial, with a message that reads like the ORIGIN's fault.
    it "refuses a groups / sigalgs / ciphersuites string this OpenSSL does not accept" do
      Gori::Settings.outbound_tls_error(tls_rule("a.test", groups: "not-a-curve")).to_s
        .should contain("`groups`")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", sigalgs: "not-a-sigalg")).to_s
        .should contain("`sigalgs`")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", ciphersuites: "NOT_A_SUITE")).to_s
        .should contain("`ciphersuites`")
    end

    it "accepts the strings it does" do
      Gori::Settings.outbound_tls_error(
        tls_rule("a.test", groups: "X25519:P-256", sigalgs: "ecdsa_secp256r1_sha256",
          ciphersuites: "TLS_AES_128_GCM_SHA256", alpn: ["h2", "http/1.1"])).should be_nil
    end

    # ALPN is checked against what GORI can speak, not against what OpenSSL will encode:
    # whatever the origin selects is what gori then has to write on that socket.
    it "refuses an ALPN protocol gori cannot speak" do
      msg = Gori::Settings.outbound_tls_error(tls_rule("a.test", alpn: ["h3"])).to_s
      msg.should contain("`alpn`")
      msg.should contain("h2, http/1.1")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", alpn: [""])).to_s.should contain("empty")
    end

    it "refuses an unknown preset, naming the ones that exist" do
      msg = Gori::Settings.outbound_tls_error(tls_rule("a.test", preset: "chromium")).to_s
      msg.should contain("preset must be one of")
      msg.should contain("chrome")
    end

    # The check above is worthless unless a typo SURVIVES THE LOADER — and the tolerant-parse
    # habit of this section (an unknown `min_version` folds to "") would have deleted it, so
    # the rule would load as all-defaults, nothing would warn, and gori would dial with its
    # bare OpenSSL hello while the operator believed Chrome's was going out. This drives the
    # settings file, not the constructor, because that is where the two disagree.
    it "keeps an unknown preset name through a load so the warning can name it" do
      with_settings_file(<<-JSON) do
        { "outbound_tls": [ { "host": "typo.test", "preset": "chromium" } ] }
        JSON
        Gori::Settings.outbound_tls_for("typo.test").preset.should eq("chromium")
        warnings = Gori::Settings.outbound_tls_warnings
        warnings.size.should eq(1)
        warnings.first.should contain("chromium")
        warnings.first.should contain("preset must be one of")
      end
    end

    # A preset is applied through `effective_*`, so validating only what the operator TYPED
    # left the preset itself unchecked on the build that has to run it — and a preset this
    # OpenSSL refuses raises at the first dial, on a host chosen for it, with a message that
    # reads like the origin's TLS leg refusing.
    it "validates what a preset contributes, not only what the rule states" do
      Gori::Settings::TLS_PRESET_NAMES.each do |name|
        rule = tls_rule("a.test", preset: name)
        rule.effective_groups.should eq(Gori::Settings::TLS_PRESETS[name].groups)
        Gori::Settings.outbound_tls_error(rule).should be_nil
      end
    end

    # `permissive` drops the security level to 0 BEFORE these knobs are applied, so a
    # validator that probed at the distribution's default level would report a rule that
    # dials perfectly well as one that "will fail".
    it "validates at the security level the dial will actually use" do
      Gori::Settings.outbound_tls_error(
        tls_rule("a.test", permissive: true, groups: "X25519:P-256",
          ciphersuites: "TLS_AES_128_GCM_SHA256")).should be_nil
    end
  end

  # `outbound_tls` is the one section with no in-app editor, so its validator had no save to
  # run at. These are what gives it one — the startup lines the TUI and the headless banner
  # both emit.
  describe ".outbound_tls_warnings" do
    it "is empty when every rule is applicable" do
      Gori::Settings.outbound_tls = [
        tls_rule("a.test", preset: "chrome"),
        tls_rule("b.test", groups: "X25519:P-256", alpn: ["h2", "http/1.1"]),
      ]
      Gori::Settings.outbound_tls_warnings.should be_empty
    ensure
      reset_outbound_tls
    end

    # A rule gori cannot apply is otherwise invisible until every dial to that ONE destination
    # fails, with an OpenSSL message that reads like the origin's TLS leg refusing.
    it "names the rule, the setting and the consequence" do
      Gori::Settings.outbound_tls = [
        tls_rule("good.test", preset: "chrome"),
        tls_rule("bad.test", groups: "not-a-curve"),
      ]
      warnings = Gori::Settings.outbound_tls_warnings
      warnings.size.should eq(1)
      warnings.first.should contain("`groups`")
      warnings.first.should contain("bad.test")
      warnings.first.should contain("will fail")
    ensure
      reset_outbound_tls
    end
  end

  # The section round-trips through settings.json: what an operator writes must survive a load,
  # and what `save` writes must survive the next load unchanged. Without this, a field can be
  # parsed and applied perfectly and still be silently dropped the first time gori saves.
  describe "settings.json round trip" do
    it "keeps every fingerprint field across load → save → load" do
      with_settings_file(<<-JSON) do |dir|
        {
          "outbound_tls": [
            {
              "host": "shop.test",
              "preset": "chrome",
              "groups": "X25519:P-256",
              "sigalgs": "ecdsa_secp256r1_sha256",
              "ciphersuites": "TLS_AES_128_GCM_SHA256",
              "alpn": ["h2", "http/1.1"],
              "session_tickets": false,
              "ocsp_stapling": true
            },
            { "host": "loose.test", "alpn": "h2, http/1.1" }
          ]
        }
        JSON
        2.times do |round|
          Gori::Settings.load
          rule = Gori::Settings.outbound_tls_for("shop.test")
          rule.preset.should eq("chrome")
          rule.groups.should eq("X25519:P-256")
          rule.sigalgs.should eq("ecdsa_secp256r1_sha256")
          rule.ciphersuites.should eq("TLS_AES_128_GCM_SHA256")
          rule.alpn.should eq(["h2", "http/1.1"])
          rule.session_tickets.should be_false
          rule.ocsp_stapling.should be_true
          # A hand-edited comma string is accepted for `alpn` too — writing one and having it
          # load as "no ALPN configured" is the silent no-op this section refuses elsewhere.
          Gori::Settings.outbound_tls_for("loose.test").alpn.should eq(["h2", "http/1.1"])
          Gori::Settings.save.should be_true if round == 0
        end

        # A preset NAME survives; the preset's CONTENTS are never baked into the file, so a
        # later release's preset edit still reaches an install that named it.
        File.read(File.join(dir, "settings.json")).should_not contain("ECDHE-ECDSA-AES128-GCM-SHA256")
      end
    end
  end
end
