require "./spec_helper"

# `Gori::Url` is the ONE definition of "how a request target is written down when a surface
# has to say where a message went". Four copies of it existed: `Store::FlowRow.absolute_form?`
# (careful, byte-level, case-insensitive), `Tui::Url.origin_path` (case-SENSITIVE),
# `CLI::Output.flow_row_text` and `Links.flow_location` (`target.starts_with?("http")`, which
# is neither). The disagreement is not academic — see the uppercase-scheme examples below.
describe Gori::Url do
  describe ".absolute_form?" do
    it "recognises an absolute-form target in either scheme and either case" do
      Gori::Url.absolute_form?("http://h/x").should be_true
      Gori::Url.absolute_form?("https://h/x").should be_true
      Gori::Url.absolute_form?("HTTP://h/x").should be_true
      Gori::Url.absolute_form?("HttPs://h/x").should be_true
    end

    it "rejects an origin-form target, a near-miss scheme and a status line" do
      Gori::Url.absolute_form?("/x").should be_false
      Gori::Url.absolute_form?("http:/x").should be_false
      Gori::Url.absolute_form?("httpx://h/x").should be_false
      Gori::Url.absolute_form?("405 Method Not Allowed").should be_false
      Gori::Url.absolute_form?("").should be_false
    end

    it "does not raise on a target that is not valid UTF-8" do
      # A target is bytes a peer or an operator put on the wire. PCRE2 RAISES on an invalid
      # byte rather than not matching, which is why this check is byte-level.
      Gori::Url.absolute_form?(String.new(Bytes[0x48, 0x54, 0x54, 0x50, 0x3a, 0x2f, 0x2f, 0x80]))
        .should be_true
    end
  end

  describe ".origin_path" do
    it "projects an absolute-form target to origin form" do
      Gori::Url.origin_path("http://example.com/a/b?q=1#f").should eq("/a/b?q=1#f")
      Gori::Url.origin_path("https://host:8443/x").should eq("/x")
      Gori::Url.origin_path("http://example.com").should eq("/")
    end

    it "leaves a non-absolute target alone" do
      Gori::Url.origin_path("/foo/bar").should eq("/foo/bar")
      Gori::Url.origin_path("405 Method Not Allowed").should eq("405 Method Not Allowed")
      Gori::Url.origin_path("httpx://h/p").should eq("httpx://h/p")
    end

    # The behaviour that changed when the four copies collapsed onto one. `Tui::Url` was
    # case-sensitive and its spec asserted "actual"; `absolute_form?`'s own comment says an
    # uppercase scheme is exactly what must NOT slip past, because RFC 3986 §3.1 makes a URI
    # scheme case-insensitive and gori captures whatever the client wrote.
    it "projects an UPPERCASE scheme too" do
      Gori::Url.origin_path("HTTP://example.com/x").should eq("/x")
      Gori::Url.origin_path("HTTPS://example.com/x").should eq("/x")
    end
  end

  describe ".location" do
    it "returns an absolute-form target verbatim rather than gluing the host onto it" do
      Gori::Url.location("127.0.0.1", "http://127.0.0.1:19594/upper")
        .should eq("http://127.0.0.1:19594/upper")
    end

    # THE regression. Captured live through the proxy from `GET HTTP://127.0.0.1:19594/upper
    # HTTP/1.1`, `gori run history` printed `127.0.0.1HTTP://127.0.0.1:19594/upper` — a string
    # that is not a URL, and the exact doubling `FlowRow.absolute_form?` was written to stop.
    it "does not double the authority on an UPPERCASE absolute-form target" do
      out = Gori::Url.location("127.0.0.1", "HTTP://127.0.0.1:19594/upper")
      out.should eq("HTTP://127.0.0.1:19594/upper")
      out.should_not eq("127.0.0.1HTTP://127.0.0.1:19594/upper")
    end

    it "prefixes the host on an origin-form target" do
      Gori::Url.location("acme.test", "/api/users").should eq("acme.test/api/users")
    end
  end

  describe ".request_url" do
    # #884, and the failure direction was PERMISSIVE. A plaintext forward-proxy request
    # arrives ABSOLUTE-form, so its target already carries `host:port` and a scope rule naming
    # a port matched it. A CONNECT-tunnelled request arrives ORIGIN-form, and the URL built
    # here used to be port-FREE — so the identical rule silently skipped it and the excluded
    # TLS port was forwarded. Both transports now spell the same authority.
    it "carries a non-default port for an origin-form target" do
      Gori::Url.request_url("https", "127.0.0.1", "/x", 19316)
        .should eq("https://127.0.0.1:19316/x")
      Gori::Url.request_url("http", "127.0.0.1", "/x", 19316)
        .should eq("http://127.0.0.1:19316/x")
    end

    # The two transports on the SAME port must produce the same authority, or a `:PORT` rule
    # is still a coin flip. The plaintext side arrives absolute-form and is returned verbatim.
    it "spells the same authority for the plaintext and the tunnelled request on one port" do
      plaintext = Gori::Url.request_url("http", "127.0.0.1", "http://127.0.0.1:19316/x", 19316)
      tunnelled = Gori::Url.request_url("https", "127.0.0.1", "/x", 19316)
      plaintext.should eq("http://127.0.0.1:19316/x")
      [plaintext, tunnelled].each { |u| u.should contain(":19316") }
    end

    # RFC 3986 §3.2.3: the scheme's default port is not part of the canonical form. Appending
    # it would give every ordinary flow a bogus ":443"/":80" no operator would type.
    it "elides the scheme's default port" do
      Gori::Url.request_url("https", "acme.test", "/x", 443).should eq("https://acme.test/x")
      Gori::Url.request_url("http", "acme.test", "/x", 80).should eq("http://acme.test/x")
    end

    it "does not double the port onto an absolute-form target" do
      Gori::Url.request_url("http", "acme.test", "http://acme.test:8080/x", 8080)
        .should eq("http://acme.test:8080/x")
    end

    it "brackets an IPv6 literal, which is stored bare" do
      Gori::Url.request_url("https", "::1", "/x", 8443).should eq("https://[::1]:8443/x")
      Gori::Url.request_url("https", "::1", "/x", 443).should eq("https://[::1]/x")
    end

    # `Scope.request_url` — the include side and `QL::URL_EXPR_NO_PORT` — is this arm, so it
    # must stay byte-identical to the old `"#{scheme}://#{host}#{target}"`, unnormalised
    # authority and all, or the live gate and the SQL lens describe different sets.
    it "keeps the port-free spelling byte-identical for a caller with no port in hand" do
      Gori::Url.request_url("https", "acme.test", "/x").should eq("https://acme.test/x")
      Gori::Url.request_url("https", "::1", "/x").should eq("https://::1/x")
      Gori::Url.request_url("https", "acme.test", "*").should eq("https://acme.test*")
    end
  end

  describe ".url_path" do
    # `OPTIONS *` (RFC 9112 §3.2.4) is the one request target no URI can spell. Gluing it
    # straight onto the authority produced `https://acme.test*`, which URI.parse reads as a
    # HOST of "acme.test*" — and `https://acme.test:8443*` it refuses outright — so such a
    # flow could not be re-imported from the URL its own surfaces printed.
    it "gives a non-origin-form target the slash that keeps it out of the authority" do
      Gori::Url.url_path("*").should eq("/*")
      Gori::Url.url_path("/x").should eq("/x")
      Gori::Url.url_path("").should eq("")
    end
  end

  # The delegating names kept for their existing call sites must answer identically, or the
  # consolidation only moved the drift somewhere else.
  it "answers the same through every name that survived" do
    %w(http://h/x HTTP://h/x /x httpx://h/x 405\ Nope).each do |t|
      Gori::Tui::Url.origin_path(t).should eq(Gori::Url.origin_path(t))
      Gori::Store::FlowRow.absolute_form?(t).should eq(Gori::Url.absolute_form?(t))
    end
  end

  # `FlowRow.url_of` IS this function now, so History's url column, a `url:` query and a scope
  # string rule cannot drift apart again.
  it "is what FlowRow.url_of builds" do
    [
      {"https", "127.0.0.1", 19316, "/x"},
      {"https", "acme.test", 443, "/a?b=c"},
      {"http", "acme.test", 8080, "/a"},
      {"https", "::1", 8443, "/x"},
      {"http", "acme.test", 8080, "http://other.test/x"},
      {"https", "acme.test", 8443, "*"},
    ].each do |(scheme, host, port, target)|
      Gori::Store::FlowRow.url_of(scheme, host, port, target)
        .should eq(Gori::Url.request_url(scheme, host, target, port))
    end
  end

  # The re-import gap this closed: the URL a surface prints for an `OPTIONS *` flow has to
  # parse back to the host and port it came from. `https://acme.test:8443*` raised
  # `URI::Error: bad port`, so the flow was dropped by every parser that re-reads a URL.
  it "builds an OPTIONS * URL that parses back to its own authority" do
    url = Gori::Store::FlowRow.url_of("https", "acme.test", 8443, "*")
    url.should eq("https://acme.test:8443/*")
    uri = URI.parse(url)
    uri.host.should eq("acme.test")
    uri.port.should eq(8443)
    uri.path.should eq("/*")
  end
end
