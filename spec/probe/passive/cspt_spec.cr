require "../../spec_helper"
require "../../support/probe_harness"

private def cspt_dets(store, js : String)
  probe_analyze_html(store, "<html><body><script>#{js}</script></body></html>").select(&.code.==("cspt_suspected"))
end

describe Gori::Probe::Passive::Cspt do
  it "flags a hash value in a fetch URL, Low, with labels only" do
    with_store do |store|
      dets = cspt_dets(store, %(fetch("/api/user/" + location.hash.slice(1));))
      dets.size.should eq(1)
      dets[0].severity.should eq(Gori::Store::Severity::Low)
      dets[0].evidence.should eq("location.hash → fetch")
      dets[0].category.should eq(Gori::Probe::Category::CLIENT)
    end
  end

  it "reports one detection per distinct source → sink on the host" do
    with_store do |store|
      cspt_dets(store, %(fetch("/a/" + location.hash); fetch("/b/" + location.hash);)).size.should eq(1)
    end
  end

  it "counts e.data as postMessage data only in a script with a message listener" do
    with_store do |store|
      cspt_dets(store, %(axios.get("/api/me").then(e=>fetch("/api/org/"+e.data.orgId));)).should be_empty
      dets = cspt_dets(store, %(addEventListener("message",function(e){fetch("/api/org/"+e.data.orgId)});))
      dets.map(&.evidence).should eq(["postMessage data → fetch"])
    end
  end

  it "stays quiet on a source-free request" do
    with_store do |store|
      cspt_dets(store, %(fetch("/api/user/1");)).should be_empty
    end
  end
end
