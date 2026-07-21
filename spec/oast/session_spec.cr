require "../spec_helper"

private alias O = Gori::Oast

# Generate ONE interactsh-style private-key PEM for the whole file (RSA keygen is slow,
# so we materialize it once and reuse). Self-contained: no dependency on engine_spec's
# offline fixture PEM.
private PEM = O::RsaKeyPair.generate_2048.private_pem

private def interactsh_session(pem : String? = PEM) : O::Session
  O::Session.new(1_i64, O::ProviderKind::Interactsh, "https://oast.pro",
    "abc12300000000000000", "sec1234567890",
    private_key_pem: pem, registered: true)
end

private def custom_session(url : String) : O::Session
  O::Session.new(0_i64, O::ProviderKind::CustomHttp, url,
    "corr", "sec")
end

describe O::Session do
  describe "#rsa" do
    it "lazily materializes an RsaKeyPair from private_key_pem" do
      session = interactsh_session
      kp = session.rsa
      kp.should_not be_nil
      kp.not_nil!.public_spki_pem.should start_with("-----BEGIN PUBLIC KEY-----")
    end

    it "MEMOIZES: two calls return the SAME object identity" do
      session = interactsh_session
      first = session.rsa
      second = session.rsa
      first.should_not be_nil
      # identity, not just equality: the second call must reuse the cached instance
      first.not_nil!.same?(second.not_nil!).should be_true
    end

    it "materialized keypair re-derives the SAME public key the PEM was exported from" do
      # Contract: a resumed session (PEM only) keeps decrypting -> the reconstructed
      # keypair must be the very key behind that PEM.
      expected = O::RsaKeyPair.from_private_pem(PEM).public_spki_pem
      session = interactsh_session
      session.rsa.not_nil!.public_spki_pem.should eq(expected)
    end

    it "returns nil when private_key_pem is nil (non-interactsh session)" do
      session = O::Session.new(0_i64, O::ProviderKind::WebhookSite,
        "https://webhook.site", "token123", "")
      session.rsa.should be_nil
    end

    it "returns nil repeatedly (no caching of a bogus non-nil) when PEM is nil" do
      session = custom_session("https://my.oast.example/log")
      session.rsa.should be_nil
      session.rsa.should be_nil
    end

    it "prefers an rsa injected via the ctor over re-parsing the PEM" do
      # When both an explicit rsa and a PEM are present, the pre-supplied instance wins
      # and is returned by identity.
      injected = O::RsaKeyPair.from_private_pem(PEM)
      session = O::Session.new(1_i64, O::ProviderKind::Interactsh, "https://oast.pro",
        "corr", "sec", private_key_pem: PEM, rsa: injected)
      session.rsa.not_nil!.same?(injected).should be_true
    end
  end

  describe "#host" do
    it "returns the bare host for a scheme-qualified server_url" do
      custom_session("https://oast.pro").host.should eq("oast.pro")
    end

    it "falls back to the raw server_url when URI.parse yields no host (no scheme)" do
      # bare "oast.pro" -> URI.parse.host is nil -> the `|| @server_url` branch
      custom_session("oast.pro").host.should eq("oast.pro")
    end

    it "strips the port, returning only the host for scheme://host:port" do
      custom_session("https://oast.pro:8443").host.should eq("oast.pro")
    end

    it "strips scheme, port, and path, returning only the host" do
      custom_session("http://my.oast.example:8080/log?x=1").host.should eq("my.oast.example")
    end

    it "returns the bare host for an http (non-https) url" do
      custom_session("http://c1abc.interact.sh").host.should eq("c1abc.interact.sh")
    end

    it "handles a subdomained interactsh host" do
      custom_session("https://cabc123.oast.pro").host.should eq("cabc123.oast.pro")
    end

    it "returns the raw string for the empty server_url (no host -> fallback)" do
      custom_session("").host.should eq("")
    end

    it "returns the raw string for a bare host:port with no scheme (no host parsed)" do
      # No scheme means URI.parse treats "oast.pro:8443" as scheme:path, host is nil,
      # so the whole raw value comes back verbatim.
      custom_session("oast.pro:8443").host.should eq("oast.pro:8443")
    end

    it "preserves a punycode/IDN host verbatim" do
      custom_session("https://xn--r8jz45g.example").host.should eq("xn--r8jz45g.example")
    end

    it "returns the raw value for a bare multibyte host with no scheme" do
      custom_session("안녕.example").host.should eq("안녕.example")
    end
  end
end
