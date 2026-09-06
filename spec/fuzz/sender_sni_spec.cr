require "../spec_helper"

private alias F = Gori::Fuzz

private def sender(sni : String?) : F::Sender
  F::Sender.new(F::Origin.new("https", "t.test", 443), ungated_outbound,
    http2: false, verify: true, sni: sni)
end

# `Upstream.dial_tls_result` passes `hostname: sni || host` to OpenSSL and `""` is truthy in
# Crystal, so a blank override sends no SNI extension AND performs no hostname check on the
# certificate — with `verify: true` still set. A schema-filling MCP client sends `""` for every
# declared property, so the seam every workbench sender reaches has to read it as "no override".
describe "Fuzz::Sender SNI normalisation" do
  it "reads an absent override as no override" do
    sender(nil).sni.should be_nil
  end

  it "reads an EMPTY override as no override" do
    sender("").sni.should be_nil
  end

  it "reads a blank override as no override" do
    sender("   ").sni.should be_nil
  end

  it "keeps a real override verbatim — it is the vhost-confusion test" do
    sender("other.test").sni.should eq("other.test")
  end
end
