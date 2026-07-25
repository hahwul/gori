require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-sri", ".db")
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

private def capture_flow(store, *, host = "acme.test", body : String) : Gori::Store::FlowDetail
  head = "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice, body: nil)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: body.to_slice,
    reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Only the SRI rule's detections (the same body also trips mixed-content/tech rules).
private def sri(store, body : String, host = "acme.test") : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, host: host, body: body))
    .select { |d| d.code == "missing_sri" }
end

describe Gori::Probe::Passive::Sri do
  it "flags a cross-origin script with no integrity, naming the host" do
    with_store do |store|
      dets = sri(store, %(<script src="https://cdn.example.com/lib/v1.js"></script>))
      dets.size.should eq(1)
      dets[0].severity.should eq(Gori::Store::Severity::Low)
      dets[0].category.should eq(Gori::Probe::Category::HEADERS)
      dets[0].evidence.should eq("cdn.example.com")
    end
  end

  it "does not flag the same script once it carries an integrity attribute" do
    with_store do |store|
      sri(store, %(<script src="https://cdn.example.com/v1.js" integrity="sha384-abc" crossorigin="anonymous"></script>))
        .should be_empty
    end
  end

  it "does not flag same-origin or relative references" do
    with_store do |store|
      sri(store, %(<script src="/static/app.js"></script>)).should be_empty
      sri(store, %(<script src="app.js"></script>)).should be_empty
      sri(store, %(<script src="https://acme.test/app.js"></script>)).should be_empty
      sri(store, %(<script>var x = 1</script>)).should be_empty
    end
  end

  it "handles protocol-relative references and userinfo" do
    with_store do |store|
      sri(store, %(<script src="//cdn.example.com/v1.js"></script>)).first.evidence.should eq("cdn.example.com")
      sri(store, %(<script src="https://u:p@cdn.example.com/v1.js"></script>)).first.evidence.should eq("cdn.example.com")
    end
  end

  it "flags a cross-origin stylesheet but not a non-stylesheet link" do
    with_store do |store|
      sri(store, %(<link rel="stylesheet" href="https://fonts.example.com/a.css">))
        .first.evidence.should eq("fonts.example.com")
      sri(store, %(<link rel="preconnect" href="https://fonts.example.com">)).should be_empty
      sri(store, %(<link rel="icon" href="https://cdn.example.com/f.ico">)).should be_empty
    end
  end

  it "ignores data-src/data-href placeholders and inline URIs" do
    with_store do |store|
      sri(store, %(<script data-src="https://cdn.example.com/v1.js"></script>)).should be_empty
      sri(store, %(<script src="data:text/javascript,void%200"></script>)).should be_empty
    end
  end

  it "reports each distinct external host once" do
    with_store do |store|
      body = %(<script src="https://a.example.com/1.js"></script>) +
             %(<script src="https://a.example.com/2.js"></script>) +
             %(<script src="https://b.example.com/3.js"></script>)
      sri(store, body).map(&.evidence).should eq(["a.example.com", "b.example.com"])
    end
  end
end
