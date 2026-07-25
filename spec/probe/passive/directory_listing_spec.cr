require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-dirlist", ".db")
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

private def capture_flow(store, *, status = 200, content_type : String? = "text/html",
                         body : String) : Gori::Store::FlowDetail
  head = "GET /files/ HTTP/1.1\r\nHost: acme.test\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/files/", http_version: "HTTP/1.1", head: head.to_slice, body: nil)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} OK\r\n\r\n".to_slice,
    body: body.to_slice, reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def listing(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw)).select { |d| d.code == "directory_listing" }
end

NGINX_INDEX = <<-HTML
  <html><head><title>Index of /files/</title></head><body>
  <h1>Index of /files/</h1><hr><pre><a href="../">../</a>
  <a href="backup.sql.gz">backup.sql.gz</a>   12-Jul-2026 09:14   4021
  </pre><hr></body></html>
  HTML

APACHE_INDEX = <<-HTML
  <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
  <html><head><title>Index of /files</title></head><body><h1>Index of /files</h1>
  <table><tr><th>Name</th></tr>
  <tr><td><a href="/">Parent Directory</a></td></tr>
  <tr><td><a href=".env.bak">.env.bak</a></td></tr></table>
  <address>Apache/2.4.58 Server at acme.test Port 443</address></body></html>
  HTML

describe Gori::Probe::Passive::DirectoryListing do
  it "flags an nginx autoindex page" do
    with_store do |store|
      dets = listing(store, body: NGINX_INDEX)
      dets.size.should eq(1)
      dets[0].severity.should eq(Gori::Store::Severity::Low)
      dets[0].category.should eq(Gori::Probe::Category::INFOLEAK)
    end
  end

  it "flags an Apache mod_autoindex page" do
    with_store do |store|
      listing(store, body: APACHE_INDEX).size.should eq(1)
    end
  end

  it "does not flag prose that merely says index of /" do
    with_store do |store|
      body = "<html><head><title>Index of /docs — our API</title></head>" \
             "<body><p>Below is an index of /docs endpoints.</p></body></html>"
      listing(store, body: body).should be_empty
    end
  end

  it "does not flag an error page that carries the same words" do
    with_store do |store|
      listing(store, status: 403, body: NGINX_INDEX).should be_empty
      listing(store, status: 404, body: APACHE_INDEX).should be_empty
    end
  end

  it "does not flag a non-HTML response" do
    with_store do |store|
      listing(store, content_type: "application/json", body: NGINX_INDEX).should be_empty
    end
  end
end
