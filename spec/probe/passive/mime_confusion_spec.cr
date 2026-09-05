require "../../spec_helper"
# The rule is not yet in Passive::RULES, so require it directly and drive `check` by hand
# (rather than going through Passive.analyze, which only runs registered rules).
require "../../../src/gori/probe/passive/mime_confusion"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def capture_flow(store, resp_head : String = "HTTP/1.1 200 OK\r\n\r\n", *,
                         scheme = "https", host = "acme.test", target = "/", status = 200,
                         content_type : String? = "text/html", body : String? = nil,
                         method = "GET", req_headers = "") : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Drive ONLY this rule over one captured flow. `ctx.ct_low` reads the stored content_type
# column (Context#content_type -> row.content_type), which is what `content_type:` sets;
# `resp_head` matters only for header lookups the rule makes off ctx.response (nosniff).
private def mime(store, **kw) : Array(Gori::Probe::Detection)
  ctx = Gori::Probe::Passive::Context.new(capture_flow(store, **kw))
  acc = [] of Gori::Probe::Detection
  Gori::Probe::Passive::MimeConfusion.new.check(ctx, acc)
  acc
end

private def codes(dets) : Array(String)
  dets.map(&.code)
end

describe Gori::Probe::Passive::MimeConfusion do
  it "has one rule id even though it emits two codes" do
    info = Gori::Probe::Passive::MimeConfusion.new.info
    info.id.should eq("mime_confusion")
    info.category.should eq(Gori::Probe::Category::HEADERS)
  end

  it "flags a JSON body served as text/html" do
    with_store do |store|
      dets = mime(store, content_type: "text/html", body: %({"user":"<script>alert(1)</script>"}))
      codes(dets).should contain("mime_json_as_html")
      codes(dets).should_not contain("mime_sniff_html")
      d = dets.find { |x| x.code == "mime_json_as_html" }.not_nil!
      d.severity.should eq(Gori::Store::Severity::Low)
      d.category.should eq(Gori::Probe::Category::HEADERS)
      d.title.should eq("JSON body served as text/html")
      d.evidence.should eq("declared text/html")
    end
  end

  it "does not flag an HTML body under text/html (the correct type)" do
    with_store do |store|
      mime(store, content_type: "text/html", body: "<html><body>hi</body></html>").should be_empty
    end
  end

  it "flags an HTML body served as text/plain without nosniff" do
    with_store do |store|
      dets = mime(store, content_type: "text/plain", body: "<!doctype html><script>alert(1)</script>")
      codes(dets).should contain("mime_sniff_html")
      codes(dets).should_not contain("mime_json_as_html")
      d = dets.find { |x| x.code == "mime_sniff_html" }.not_nil!
      d.severity.should eq(Gori::Store::Severity::Low)
      d.category.should eq(Gori::Probe::Category::HEADERS)
      d.title.should eq("Sniffable content served under a non-HTML type")
      d.evidence.should eq("declared text/plain; body is HTML")
    end
  end

  it "stays quiet when X-Content-Type-Options: nosniff is present" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nX-Content-Type-Options: nosniff\r\n\r\n"
      mime(store, resp_head: head, content_type: "text/plain",
        body: "<!doctype html><script>alert(1)</script>").should be_empty
    end
  end

  it "flags an HTML body with no declared Content-Type at all" do
    with_store do |store|
      dets = mime(store, content_type: nil, body: "<html><head><title>x</title></head></html>")
      codes(dets).should contain("mime_sniff_html")
      dets.find { |x| x.code == "mime_sniff_html" }.not_nil!
        .evidence.should eq("no Content-Type; body is HTML")
    end
  end

  it "does not flag JSON served as application/json" do
    with_store do |store|
      mime(store, content_type: "application/json", body: %({"a":1})).should be_empty
    end
  end

  it "does not flag plain text with no markup" do
    with_store do |store|
      mime(store, content_type: "text/plain", body: "just some text, no markup").should be_empty
    end
  end

  it "does not flag an HTML page that merely contains a brace (invalid JSON)" do
    with_store do |store|
      mime(store, content_type: "text/html", body: "<div>{not json</div>").should be_empty
    end
  end

  it "does not flag an HTML page that STARTS with a brace but is not JSON" do
    with_store do |store|
      # The prefix test alone would fire here; the real JSON.parse is what rejects it.
      mime(store, content_type: "text/html", body: "{{ template }}<html><body>hi</body></html>").should be_empty
    end
  end

  it "sniffs past a BOM and leading whitespace" do
    with_store do |store|
      codes(mime(store, content_type: "text/plain", body: "\uFEFF\r\n  <html><body>x</body></html>"))
        .should contain("mime_sniff_html")
    end
  end

  it "ignores Content-Type parameters when deciding sniffability" do
    with_store do |store|
      codes(mime(store, content_type: "text/plain; charset=utf-8", body: "<html>x</html>"))
        .should contain("mime_sniff_html")
    end
  end

  it "does not fire without a real scorable response" do
    with_store do |store|
      # status 0 == no response captured; Context#response returns nil.
      mime(store, status: 0, content_type: "text/plain", body: "<html>x</html>").should be_empty
    end
  end

  it "does not fire on a 3xx redirect (body is discarded, never rendered)" do
    with_store do |store|
      redir = "HTTP/1.1 302 Found\r\nLocation: /x\r\n\r\n"
      # An HTML body under text/plain, or a JSON body under text/html, would sniff/render only if
      # the browser rendered it — but on a 3xx it follows the Location and discards the body.
      mime(store, resp_head: redir, status: 302, content_type: "text/plain",
        body: "<html><script>x</script></html>").should be_empty
      mime(store, resp_head: redir, status: 302, content_type: "text/html",
        body: %({"a":1})).should be_empty
    end
  end
end
