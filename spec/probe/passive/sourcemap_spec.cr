require "../../spec_helper"
require "compress/gzip"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-sourcemap", ".db")
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

private def capture_flow(store, resp_head : String = "HTTP/1.1 200 OK\r\n\r\n", *,
                         host = "acme.test", target = "/app.js", status = 200,
                         content_type : String? = "application/javascript",
                         body : Bytes? = nil) : Gori::Store::FlowDetail
  head = "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body,
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def maps(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw)).select { |d| d.code == "sourcemap_exposed" }
end

private def gzip(s : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io, &.print(s))
  io.to_slice
end

describe Gori::Probe::Passive::SourceMap do
  it "flags a sourceMappingURL comment in a JS bundle" do
    with_store do |store|
      dets = maps(store, body: "console.log(1)\n//# sourceMappingURL=app.9f2.js.map\n".to_slice)
      dets.size.should eq(1)
      dets[0].severity.should eq(Gori::Store::Severity::Info)
      dets[0].category.should eq(Gori::Probe::Category::INFOLEAK)
      dets[0].evidence.should eq("app.9f2.js.map")
    end
  end

  it "flags the legacy //@ and block-comment forms" do
    with_store do |store|
      maps(store, body: "x\n//@ sourceMappingURL=a.map\n".to_slice).size.should eq(1)
      maps(store, body: "x\n/*# sourceMappingURL=b.map */\n".to_slice).size.should eq(1)
    end
  end

  it "rates an inline data: source map Low (the sources are already in this response)" do
    with_store do |store|
      body = "x\n//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozfQ==\n"
      dets = maps(store, body: body.to_slice)
      dets[0].severity.should eq(Gori::Store::Severity::Low)
      dets[0].evidence.should eq("inline data: URI")
    end
  end

  it "flags the SourceMap / X-SourceMap response headers" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nSourceMap: /static/app.js.map\r\n\r\n"
      maps(store, resp_head: head).first.evidence.should eq("/static/app.js.map")
      head = "HTTP/1.1 200 OK\r\nX-SourceMap: /static/legacy.js.map\r\n\r\n"
      maps(store, resp_head: head).first.evidence.should eq("/static/legacy.js.map")
    end
  end

  it "ignores a JS bundle with no source map, and an HTML page that mentions one" do
    with_store do |store|
      maps(store, body: "console.log(1)\n".to_slice).should be_empty
      maps(store, target: "/", content_type: "text/html",
        body: "<p>add //# sourceMappingURL=x.map to your build</p>".to_slice).should be_empty
    end
  end

  it "finds the comment past the shared body prefix cap (end of a large bundle)" do
    with_store do |store|
      cap = Gori::Probe::Passive::Context::CLIENT_BODY_CAP
      body = ("x" * (cap + 32 * 1024)) + "\n//# sourceMappingURL=main.js.map\n"
      maps(store, body: body.to_slice).first.evidence.should eq("main.js.map")
    end
  end

  it "finds it past the cap in a gzip-encoded bundle" do
    with_store do |store|
      # Compresses to a few KiB, so the STORED body is tiny while the inflated one runs past
      # the prefix cap — exactly the case a raw-size heuristic would miss.
      cap = Gori::Probe::Passive::Context::CLIENT_BODY_CAP
      filler = String.build { |io| (cap + 32 * 1024).times { |i| io << ('a'.ord + i % 26).chr } }
      head = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n"
      body = gzip("#{filler}\n//# sourceMappingURL=gz.js.map\n")
      maps(store, resp_head: head, body: body).first.evidence.should eq("gz.js.map")
    end
  end
end
