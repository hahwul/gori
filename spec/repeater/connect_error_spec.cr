require "../spec_helper"

# Round 4 / F1. `dial_tls_result` has always returned a `DialError` whose `kind` says WHICH
# layer broke — that is the documented reason `DialErrorKind` exists — and the proxy path has
# consumed it since #323. Every DIRECT sender (repeater, fuzz, mine, sequence, discover, probe
# active, and `ConnPool`, all of which reach the network through `Repeater::Engine`) read only
# `detail` and fell through to one sentence:
#
#   connect failed: host:port — host unreachable (DNS/refused/timeout) or the origin's TLS
#   certificate failed verification (e.g. self-signed/expired)
#
# A cert rejection, a handshake failure and a plain TCP refusal have three different fixes
# (add their private CA / "this port is not TLS" / a firewall-DNS problem) and that sentence
# named the third for all three.

private alias U = Gori::Proxy::Upstream
private alias E = Gori::Repeater::Engine

private def verify_error : U::DialError
  U::DialError.new(U::DialErrorKind::TlsVerify, cause: "SSL_connect: error:0A000086:SSL routines::certificate verify failed")
end

private def handshake_error : U::DialError
  U::DialError.new(U::DialErrorKind::Tls, cause: "SSL_connect: error:0A00010B:SSL routines::wrong version number")
end

private def blackhole_error : U::DialError
  U::DialError.new(U::DialErrorKind::Timeout, cause: "no TLS response within 3.0s")
end

private def dns_error : U::DialError
  U::DialError.new(U::DialErrorKind::Dns, cause: "Hostname lookup for h.test failed: No address found")
end

describe "Gori::Repeater::Engine.connect_error" do
  it "names a certificate rejection, with the remedy, and quotes OpenSSL" do
    msg = E.connect_error("https", "h.test", 443, true, verify_error)
    msg.should contain("TLS verification failed: h.test:443")
    msg.should contain("certificate is not trusted")
    msg.should contain("SSL_CERT_FILE")
    msg.should contain("certificate verify failed")
    # Not the reachability sentence — that is the whole defect.
    msg.should_not contain("host unreachable")
  end

  it "names a HANDSHAKE failure where verification is not the explanation" do
    msg = E.connect_error("https", "h.test", 443, false, handshake_error)
    msg.should contain("TLS handshake failed: h.test:443")
    msg.should contain("may not be TLS")
    msg.should_not contain("host unreachable")
    # …and it must not offer -k to someone who already passed it.
    msg.should_not contain("SSL_CERT_FILE")
    # The guess is checkable rather than believed.
    msg.should contain("wrong version number")
  end

  # Round 5 / Part 2 §2.1. The dial kind, not the `verify` flag, decides the sentence. Keying
  # on the flag is what made a black hole and a plaintext port read as an untrusted cert.
  it "does not offer a certificate remedy for a plaintext port just because verify is on" do
    msg = E.connect_error("https", "h.test", 443, true, handshake_error)
    msg.should contain("TLS handshake failed: h.test:443")
    msg.should_not contain("SSL_CERT_FILE")
    msg.should_not contain("certificate")
  end

  it "names a black hole as a timeout and says the two TLS remedies cannot help" do
    [true, false].each do |verify| # -k changes nothing: verification never ran
      msg = E.connect_error("https", "h.test", 443, verify, blackhole_error)
      msg.should contain("TLS handshake timed out: h.test:443")
      msg.should contain("sent nothing")
      msg.should contain("cannot help")
      msg.should contain("no TLS response within 3.0s")
      # The two remedies that were offered before, and are useless here: nothing may read as
      # "add a CA file" when no certificate was ever exchanged.
      msg.should_not contain("not trusted")
      msg.should_not contain("retry with")
      msg.should_not contain("host unreachable")
    end
  end

  it "separates a name that never resolved from a port that refused" do
    dns = E.connect_error("https", "h.test", 443, true, dns_error)
    dns.should contain("the name did not resolve")
    dns.should contain("nothing was dialed")
    tcp = E.connect_error("https", "h.test", 443, true, U::DialError::ORIGIN_UNREACHABLE)
    tcp.should_not contain("did not resolve")
    dns.should_not eq(tcp)
  end

  it "keeps the reachability sentence for a TCP failure, WITHOUT the TLS clause" do
    # `dial_tls_result` returns Connect (not Tls) when the socket itself never came up, so
    # this is now reachable only when the TCP layer really is what failed.
    https = E.connect_error("https", "h.test", 443, true, U::DialError::ORIGIN_UNREACHABLE)
    https.should eq("connect failed: h.test:443 — host unreachable (DNS/refused/timeout)")
    https.should_not contain("certificate")
    http = E.connect_error("http", "h.test", 80, false, U::DialError::ORIGIN_UNREACHABLE)
    http.should eq("connect failed: h.test:80 — host unreachable (DNS/refused/timeout)")
  end

  it "still uses a proxy detail VERBATIM, in preference to any kind-derived sentence" do
    # The #F3 case: a corporate proxy that refused the tunnel. The origin was never contacted,
    # so neither the TLS nor the reachability wording may replace what the dialer said.
    err = U::DialError.new(U::DialErrorKind::Proxy, "proxy.test:8080 wants credentials (407)")
    E.connect_error("https", "h.test", 443, true, err)
      .should eq("connect failed: proxy.test:8080 wants credentials (407)")
  end

  it "falls back to the reachability sentence when there is no DialError at all" do
    E.connect_error("https", "h.test", 443, true, nil)
      .should eq("connect failed: h.test:443 — host unreachable (DNS/refused/timeout)")
  end

  it "gives the five dial failures five DIFFERENT sentences" do
    all = [
      E.connect_error("https", "h.test", 443, true, verify_error),
      E.connect_error("https", "h.test", 443, true, handshake_error),
      E.connect_error("https", "h.test", 443, true, blackhole_error),
      E.connect_error("https", "h.test", 443, true, dns_error),
      E.connect_error("https", "h.test", 443, true, U::DialError::ORIGIN_UNREACHABLE),
    ]
    all.uniq.size.should eq(5)
  end

  # Round 9 / r9-tls Finding 2. A proxy that answers 200 to CONNECT and then closes without
  # relaying anything hands the TLS handshake a socket that fails EXACTLY like a direct
  # black-hole/non-TLS origin — before this fix, the operator was told the ORIGIN's port "may
  # not be TLS" when the origin was never contacted. `via_proxy` on the DialError is the fix;
  # these assert how `connect_error` renders it.
  describe "the proxy-tunnel clause (round 9 / Finding 2)" do
    it "appends the clause, AFTER the OpenSSL cause, for a proxied Tls failure" do
      err = U::DialError.new(U::DialErrorKind::Tls,
        cause: "SSL_connect: Unexpected EOF while reading",
        via_proxy: "upstream HTTP proxy 127.0.0.1:8080")
      msg = E.connect_error("https", "h.test", 443, false, err)
      msg.should eq(
        "TLS handshake failed: h.test:443 — the port may not be TLS, or the origin refused " \
        "the protocol/cipher (SSL_connect: Unexpected EOF while reading) (reached via " \
        "upstream HTTP proxy 127.0.0.1:8080 — the tunnel produced no data; the proxy may be " \
        "at fault, not the target)")
    end

    it "appends the same clause for a proxied Timeout (the tunnel opened, then silence)" do
      err = U::DialError.new(U::DialErrorKind::Timeout,
        cause: "no TLS response within 3.0s", via_proxy: "upstream SOCKS5 proxy 127.0.0.1:1080")
      msg = E.connect_error("https", "h.test", 443, true, err)
      msg.should contain("TLS handshake timed out: h.test:443")
      msg.should contain("no TLS response within 3.0s")
      msg.should contain("reached via upstream SOCKS5 proxy 127.0.0.1:1080")
      msg.should contain("tunnel produced no data")
    end

    # Complement of the two above: the UNPROXIED (direct) case must render BYTE-IDENTICAL to
    # what it did before this fix (`handshake_error`/`blackhole_error` above never set
    # `via_proxy`) — this is the regression risk the round explicitly flags.
    it "adds nothing for a direct dial — today's wording is unchanged" do
      E.connect_error("https", "h.test", 443, false, handshake_error)
        .should eq("TLS handshake failed: h.test:443 — the port may not be TLS, or the origin " \
                   "refused the protocol/cipher (SSL_connect: error:0A00010B:SSL routines::wrong version number)")
      E.connect_error("https", "h.test", 443, true, blackhole_error)
        .should eq("TLS handshake timed out: h.test:443 — the origin accepted the connection " \
                   "and then sent nothing; no certificate was exchanged, so -k and " \
                   "SSL_CERT_FILE cannot help (no TLS response within 3.0s)")
    end

    # Complement: a certificate REJECTION through a proxy must not get the tunnel-blame clause
    # — real bytes crossed the tunnel, so the ORIGIN (not the proxy) earned the verdict. Even
    # if `via_proxy` were (incorrectly) set on a TlsVerify error, `connect_error`'s OWN rendering
    # must not surface it — this is defensive on the render side, independent of the fact that
    # `tls_dial_error` never sets `via_proxy` for this kind.
    it "never shows the clause for TlsVerify, even if via_proxy were set" do
      err = U::DialError.new(U::DialErrorKind::TlsVerify,
        cause: "certificate verify failed", via_proxy: "upstream HTTP proxy 127.0.0.1:8080")
      E.connect_error("https", "h.test", 443, true, err).should_not contain("reached via upstream")
    end

    # Complement: the proxy's OWN refusal (407/403/502) already names itself precisely via
    # `detail`, used verbatim — this must keep working unchanged (no double-tagging).
    it "does not touch the existing verbatim wording for a proxy that refused the tunnel outright" do
      err = U::DialError.new(U::DialErrorKind::Proxy, "upstream HTTP proxy proxy.test:8080 refused CONNECT h.test:443: HTTP/1.1 407 Proxy Authentication Required — the proxy requires authentication; set `username` + `password_env` on the matching upstream rule")
      E.connect_error("https", "h.test", 443, true, err)
        .should eq("connect failed: upstream HTTP proxy proxy.test:8080 refused CONNECT h.test:443: HTTP/1.1 407 Proxy Authentication Required — the proxy requires authentication; set `username` + `password_env` on the matching upstream rule")
    end
  end
end

# Round 9 / r9-tls Finding 2, the PLAIN-HTTP half. `Engine.exchange` gets no `DialError` at all
# when the dial itself SUCCEEDED (a proxy answering 200 to CONNECT is a successful tunnel open,
# by the CONNECT protocol's own rules) — the silence only shows up later, on the very first
# read. So `no_response_error` has to ask `Settings.upstream_route` directly rather than reading
# a `DialError` field; these specs exercise exactly that live global-state seam, save/restoring
# it the same way `spec/settings_spec.cr` does around every other `Settings.upstream_proxy=` use.
describe "Gori::Repeater::Engine.no_response_error" do
  it "stays exactly today's wording for a direct (unproxied) host" do
    Gori::Repeater::Engine.no_response_error("origin.test", 8080)
      .should eq("no response from origin.test:8080")
  end

  it "appends the proxy-tunnel clause when the host currently routes through a configured proxy" do
    Gori::Settings.upstream_proxy = "127.0.0.1:1"
    begin
      Gori::Repeater::Engine.no_response_error("origin.test", 8080).should eq(
        "no response from origin.test:8080 (reached via upstream HTTP proxy 127.0.0.1:1 — " \
        "the tunnel produced no data; the proxy may be at fault, not the target)")
    ensure
      Gori::Settings.upstream_proxy = ""
    end
  end

  it "goes back to the plain sentence once the proxy is cleared" do
    Gori::Settings.upstream_proxy = "127.0.0.1:1"
    Gori::Settings.upstream_proxy = ""
    Gori::Repeater::Engine.no_response_error("origin.test", 8080)
      .should eq("no response from origin.test:8080")
  end
end
