require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-takeover", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def capture_flow(store, *, host = "assets.acme.test", status = 404,
                         content_type : String? = "text/html", body : String = "") : Gori::Store::FlowDetail
  head = "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} Not Found\r\nContent-Type: #{content_type}\r\n\r\n".to_slice,
    body: body.to_slice, reason: "Not Found", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def takeovers(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw)).select { |d| d.code == "subdomain_takeover" }
end

describe Gori::Probe::Passive::SubdomainTakeover do
  it "flags an unclaimed S3 bucket behind a customer subdomain" do
    with_store do |store|
      dets = takeovers(store, content_type: "application/xml",
        body: %(<?xml version="1.0"?><Error><Code>NoSuchBucket</Code><BucketName>acme-assets</BucketName></Error>))
      dets.size.should eq(1)
      dets[0].severity.should eq(Gori::Store::Severity::High)
      dets[0].category.should eq(Gori::Probe::Category::INFOLEAK)
      dets[0].evidence.should eq("unclaimed S3/GCS bucket")
    end
  end

  it "flags the GitHub Pages, Heroku, Pantheon and Vercel pages" do
    with_store do |store|
      takeovers(store, body: "<h1>404</h1><p>There isn't a GitHub Pages site here.</p>").size.should eq(1)
      takeovers(store, body: %(<a href="https://www.herokucdn.com/error-pages/no-such-app.html">)).size.should eq(1)
      takeovers(store, body: "The gods are wise, but do not know of the site which you seek.").size.should eq(1)
      takeovers(store, body: %({"error":{"code":"DEPLOYMENT_NOT_FOUND"}}), content_type: "application/json").size.should eq(1)
    end
  end

  it "accepts the typographic apostrophe the provider's markup actually ships" do
    with_store do |store|
      takeovers(store, body: "There isn\u{2019}t a GitHub Pages site here.").size.should eq(1)
    end
  end

  it "does not flag a 200 page that merely quotes the marker" do
    with_store do |store|
      # A docs page / write-up about the technique — the whole reason for the status gate.
      takeovers(store, status: 200,
        body: "<p>A dangling bucket answers with <code>NoSuchBucket</code>.</p>").should be_empty
    end
  end

  it "does not flag the provider's own domain" do
    with_store do |store|
      takeovers(store, host: "acme-assets.s3.amazonaws.com", content_type: "application/xml",
        body: "<Error><Code>NoSuchBucket</Code></Error>").should be_empty
      takeovers(store, host: "gone.herokuapp.com",
        body: %(<a href="https://www.herokucdn.com/error-pages/no-such-app.html">)).should be_empty
      takeovers(store, host: "someone.github.io",
        body: "There isn't a GitHub Pages site here.").should be_empty
    end
  end

  it "stays silent on an ordinary 404" do
    with_store do |store|
      takeovers(store, body: "<html><title>404 Not Found</title><body>Page not found</body></html>").should be_empty
    end
  end

  it "reports one provider per response" do
    with_store do |store|
      dets = takeovers(store, body: "NoSuchBucket ... There isn't a GitHub Pages site here.")
      dets.size.should eq(1)
    end
  end
end
