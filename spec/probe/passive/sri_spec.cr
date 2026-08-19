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

# `port` is the port the page itself was served on. Left nil the fixture keeps its original
# port-less Host line, so the examples written before this parameter existed are untouched;
# `scheme` then picks the port a page of that scheme is served on by default.
private def capture_flow(store, *, host = "acme.test", port : Int32? = nil,
                         scheme = "https", body : String) : Gori::Store::FlowDetail
  authority = port ? "#{host}:#{port}" : host
  head = "GET / HTTP/1.1\r\nHost: #{authority}\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: port || (scheme == "https" ? 443 : 80),
    method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice, body: nil)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: body.to_slice,
    reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Only the SRI rule's detections (the same body also trips mixed-content/tech rules).
private def sri(store, body : String, host = "acme.test", port : Int32? = nil,
                scheme = "https") : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, host: host, port: port, scheme: scheme, body: body))
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

  # `page_host` is `FlowRow#host`, which never carries a port — so a subresource authority
  # spelled `host:port` compared straight against it never matched, and a page served on an
  # explicit port reported its OWN scripts as un-hashed third parties.
  it "does not flag the page's own origin spelled with its port" do
    with_store do |store|
      # (a) non-default port
      sri(store, %(<script src="https://app.test:8443/main.js"></script>),
        "app.test", 8443).map(&.evidence).should eq([] of String)
      # (b) default port spelled out explicitly
      sri(store, %(<link rel="stylesheet" href="https://acme.test:443/a.css">),
        "acme.test", 443).map(&.evidence).should eq([] of String)
      # (c) protocol-relative spelling of the same origin
      sri(store, %(<script src="//app.test:8443/main.js"></script>),
        "app.test", 8443).map(&.evidence).should eq([] of String)
    end
  end

  # The other half of that compare, and why it takes the flow's PORT and not its host alone:
  # port is part of the origin tuple, so the page's own host on a DIFFERENT port serves
  # third-party code and its missing hash must still be reported. DROPPING the reference's
  # port before the compare (instead of comparing it) traded the false positive above for a
  # silent false negative here — the worse trade in a scanner.
  it "flags the page's own host on a different port" do
    with_store do |store|
      # (a) explicit non-default port, page on the scheme default
      sri(store, %(<script src="https://acme.test:8443/admin/app.js"></script>))
        .map(&.evidence).should eq(["acme.test:8443"])
      # (b) the reverse: page on a non-default port, reference on the scheme default
      sri(store, %(<link rel="stylesheet" href="https://app.test/a.css">), "app.test", 8443)
        .map(&.evidence).should eq(["app.test"])
      # (c) two explicit, differing ports
      sri(store, %(<script src="https://app.test:9443/x.js"></script>), "app.test", 8443)
        .map(&.evidence).should eq(["app.test:9443"])
    end
  end

  # A reference whose port the markup omits defaults from ITS OWN scheme, which is what keeps
  # the http/https split without the compare carrying the scheme dimension as well: an https
  # reference from a plaintext page is :443 against the page's :80, a different origin, and a
  # browser fetches it as one.
  it "flags an https reference to its own host from a plaintext page" do
    with_store do |store|
      sri(store, %(<script src="https://acme.test/app.js"></script>), "acme.test", nil, "http")
        .map(&.evidence).should eq(["acme.test"])
    end
  end

  it "still flags a genuine third party spelled with a port, keeping the port in evidence" do
    with_store do |store|
      dets = sri(store, %(<script src="https://cdn.example.com:8443/v1.js"></script>),
        "app.test", 8443)
      dets.map(&.evidence).should eq(["cdn.example.com:8443"])
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
