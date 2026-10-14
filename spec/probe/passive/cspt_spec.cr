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
      cspt_dets(store, %(fetch("/a/" + location.hash.slice(1)); fetch("/b/" + location.hash.slice(1));)).size.should eq(1)
    end
  end

  it "stays quiet where a ../ cannot reach the path" do
    with_store do |store|
      # A whole hash is a fragment, which no request sends.
      cspt_dets(store, %(fetch("/api/" + window.location.hash);)).should be_empty
      # After the URL's `?` the value is query, not path.
      cspt_dets(store, %(fetch("/api/search?q=" + location.hash.slice(1));)).should be_empty
      cspt_dets(store, %(fetch(`/api/items?page=${location.hash.slice(1)}`);)).should be_empty
      # An app-chosen prefix before the whole URL still counts.
      cspt_dets(store, %(fetch("/proxy/" + location.href);)).map(&.evidence).should eq(["location.href → fetch"])
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
