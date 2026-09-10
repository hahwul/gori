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
  it "sends a rejected chain to the trust store, and does NOT offer another server" do
    line = hint(transport(Kind::TlsVerify))
    line.should contain("SSL_CERT_FILE=")
    line.should contain("THIS machine's trust store")
    line.should_not contain("--server=")
  end

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

  it "survives a malformed --server rather than replacing the diagnostic with a crash" do
    hint(transport(Kind::Connect), host: "ht tp://[bad").should contain("presets --check")
  end
end
