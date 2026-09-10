require "../../spec_helper"

# Test seam: oast_register_hint is a private module method (test binary only).
module Gori::CLI::Run
  def self.spec_oast_register_hint(kind : Gori::Oast::ProviderKind, host : String,
                                   ex : Exception) : String
    oast_register_hint(kind, host, ex)
  end
end

private alias Kind = Gori::Proxy::Upstream::DialErrorKind

private def hint(ex : Exception, host = "https://oast.pro",
                 kind = Gori::Oast::ProviderKind::Interactsh) : String
  Gori::CLI::Run.spec_oast_register_hint(kind, host, ex)
end

private def transport(kind : Kind?) : Gori::HttpTransport::Error
  Gori::HttpTransport::Error.new("dial failed", kind)
end

# #1020 — a failed registration used to end at one sentence, so a custom trust store, a
# restricted resolver and a provider outage all looked alike. The message names the stage;
# this line names the NEXT COMMAND, and it has to fit the stage: telling an operator whose
# machine rejects every public certificate to try four more interactsh servers just spends
# four more timeouts arriving at the same wrong conclusion.
describe "Gori::CLI::Run.oast_register_hint" do
  it "sends an unresolved name to the resolver, and does NOT offer another server" do
    line = hint(transport(Kind::Dns))
    line.should contain("resolver")
    line.should_not contain("--server=")
  end

  it "offers the sibling presets of the SAME kind when the host itself failed" do
    line = hint(transport(Kind::Connect), host: "https://oast.pro")
    line.should contain("--server=URL")
    line.should contain("https://oast.live")
    # Never the host that just failed.
    line.should_not contain("https://oast.pro")
  end

  it "offers no sibling when the kind has only one public preset" do
    line = hint(transport(Kind::Timeout), host: "https://webhook.site",
      kind: Gori::Oast::ProviderKind::WebhookSite)
    line.should_not contain("--server=URL")
    line.should contain("presets --check")
  end

  it "calls a provider's own refusal what it is — no network remedy applies" do
    line = hint(Gori::Error.new("interactsh register failed: HTTP 401 bad token"))
    line.should contain("the provider answered and refused")
    line.should contain("--token")
    line.should_not contain("SSL_CERT_FILE")
  end

  it "does not blame a token for a peer that never answered" do
    # `Oast::ExchangeError` is a failure PAST the dial — the socket was open and the transfer
    # broke. Folding it into the provider-refusal branch printed "the provider answered and
    # refused — check --token" directly under gori's own "…did not answer within 20s".
    line = hint(Gori::Oast::ExchangeError.new(
      "OAST: oast.pro accepted the connection but did not answer within 20s"))
    line.should contain("established and then broke")
    line.should_not contain("--token")
    line.should_not contain("SSL_CERT_FILE")
    line.should_not contain("--server=")
  end

  it "sends a refusing upstream proxy to the proxy, not to four identical siblings" do
    line = hint(transport(Kind::Proxy))
    line.should contain("network.upstream_proxy")
    line.should_not contain("--server=")
  end

  it "offers no sibling for a connect failure that took an upstream proxy leg" do
    # Every sibling routes through the same proxy, so naming them is advice that cannot work.
    Gori::Settings.upstream_proxy = "http://127.0.0.1:3128"
    line = hint(transport(Kind::Connect), host: "https://oast.pro")
    line.should contain("same leg")
    line.should_not contain("https://oast.live")
  ensure
    Gori::Settings.upstream_proxy = ""
  end

  it "hedges on tls-verify — an expired leaf earns the same OpenSSL verdict as an untrusted one" do
    # `Upstream.tls_dial_error` folds an expired certificate and a hostname mismatch into
    # TlsVerify. Asserting "this is your CA store" would withhold the one remedy that works
    # when a free public interactsh host's certificate lapses.
    line = hint(transport(Kind::TlsVerify))
    line.should contain("SSL_CERT_FILE")
    line.should contain("presets --check")
    line.should contain("--server=URL")
  end

  it "falls back to the probe when the transport could not attribute a stage" do
    hint(transport(nil)).should contain("presets --check")
  end

  it "survives a malformed --server rather than replacing the diagnostic with a crash" do
    hint(transport(Kind::Connect), host: "ht tp://[bad").should contain("presets --check")
  end
end
