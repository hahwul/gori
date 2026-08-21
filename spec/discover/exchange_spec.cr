require "../spec_helper"

private alias D = Gori::Discover
private alias R = Gori::Repeater::Result

# A discovery run used to persist a SYNTHESIZED flow per finding — a head gori wrote from the
# {url, status, length, content-type} projection, and no response body at all. Everything
# downstream (the Sitemap row, `get_flow`, the TUI's "open this finding") could therefore show
# what was found but never what it answered. These specs pin the exchange the engine now keeps
# alongside each finding, and the byte-exactness of the flow `Persist` writes from it.

private def resp(status : Int32, body : String, ctype : String? = "text/html",
                 extra : String = "") : R
  head = String.build do |s|
    s << "HTTP/1.1 " << status << " OK\r\n"
    s << "Content-Type: " << ctype << "\r\n" if ctype
    s << extra
    s << "Content-Length: " << body.bytesize << "\r\n\r\n"
  end.to_slice
  R.new(head, body.to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 4200_i64)
end

private def notfound : R
  resp(404, "nope")
end

# Frames a real request head the way `Discover::Sender` does, so a spec can assert the
# REQUEST half is the backend's bytes and not something the persist layer invented.
private class HeaderBackend < D::Backend
  def initialize(@route : String -> R)
  end

  def fetch(scheme : String, host : String, port : Int32, target : String) : R
    @route.call(target)
  end

  def request_head(scheme : String, host : String, port : Int32, target : String) : Bytes
    "GET #{target} HTTP/1.1\r\nHost: #{host}\r\nX-Probe: gori\r\n\r\n".to_slice
  end
end

private def run_events(seed : String, words : Array(String), cfg : D::Config,
                       backend : D::Backend) : Array(D::FindingEvent)
  events = [] of D::FindingEvent
  D::Engine.new(seed, words, backend, cfg).run do |ev|
    events << ev if ev.is_a?(D::FindingEvent)
  end
  events
end

private def with_store(&)
  path = File.tempname("gori-discover-exchange", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "Gori::Discover finding exchanges" do
  it "keeps the request it framed and the response it read for a crawled page" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 1, concurrency: 1, retries: 0)
    backend = HeaderBackend.new(->(t : String) {
      t == "/" ? resp(200, "<h1>root</h1>", extra: "Server: acme\r\n") : notfound
    })
    events = run_events("http://t/", %w[], cfg, backend)
    seed = events.find { |e| e.finding.url == "http://t/" }.not_nil!
    ex = seed.exchange.not_nil!

    String.new(ex.request_head).should eq("GET / HTTP/1.1\r\nHost: t\r\nX-Probe: gori\r\n\r\n")
    ex.response.status.should eq(200)
    ex.response.headers.get?("Server").should eq("acme")
    String.new(ex.body.not_nil!).should eq("<h1>root</h1>")
    ex.incomplete.should be_false
    ex.duration_us.should eq(4200_i64)
  end

  it "keeps nothing for the brute-force probes that missed" do
    # `/admin` hits (200 against a soft-404 baseline of 404s); `/login` does not. The miss is
    # the common case by three orders of magnitude on a wordlist sweep, and shipping its body
    # through the channel for the orchestrator to drop is what the hit-gate avoids.
    cfg = D::Config.new(spider: false, bruteforce: true, concurrency: 1, retries: 0,
      calibrate_probes: 2)
    backend = HeaderBackend.new(->(t : String) {
      t == "/admin" ? resp(200, "admin panel") : notfound
    })
    events = run_events("http://t/", %w[admin login], cfg, backend)
    events.map(&.finding.url).should eq(["http://t/admin"])
    events.first.exchange.not_nil!.body.not_nil!.should eq("admin panel".to_slice)
  end

  it "carries the run's SNI onto the stored flow, so its re-send reaches the same vhost" do
    # `--sni` / `discover_start{sni}` express an IP-direct sweep of a name-based vhost. The
    # stored flow is re-sendable (`Repeater::FlowRequest.build` seeds from `FlowDetail#sni`),
    # so a finding persisted without the name would re-send under the dialed IP and miss the
    # vhost it was found on.
    ex = D::Exchange.new(
      request_head: "GET / HTTP/1.1\r\nHost: 10.0.0.5\r\n\r\n".to_slice,
      response: Gori::Proxy::Codec::Http1.parse_response_head(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice),
      body: "ok".to_slice, body_size: 2_i64, incomplete: false, duration_us: 1_i64,
      sni: "vhost.example")
    f = D::Finding.new("https://10.0.0.5/", "GET", 200, 2_i64, nil, D::Source::Seed, 0, 0.95, nil)

    with_store do |store|
      pair = D::Persist.flow_pair(f, 4_i64, ex, surface: Gori::FlowSource::Surface::Cli)
      id = store.insert_import_batch_ids([{pair.request, pair.response}]).first
      store.get_flow(id).not_nil!.sni.should eq("vhost.example")
    end
  end

  it "reads the SNI off the send seam, not off a copy the engine keeps" do
    # The backend owns the wire decision; the default Backend presents no override.
    HeaderBackend.new(->(_t : String) { notfound }).sni.should be_nil
    Gori::Discover::Sender.new(verify: true, sni: "vhost.example").sni.should eq("vhost.example")
    Gori::Discover::CappedBackend.new(
      Gori::Discover::Sender.new(verify: true, sni: "vhost.example"), nil).sni.should eq("vhost.example")
  end

  it "persists the wire bytes as an openable flow" do
    ex = D::Exchange.new(
      request_head: "GET /a HTTP/1.1\r\nHost: t\r\nAccept: */*\r\n\r\n".to_slice,
      response: Gori::Proxy::Codec::Http1.parse_response_head(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\n".to_slice),
      body: "hello".to_slice, body_size: 5_i64, incomplete: false, duration_us: 900_i64)
    f = D::Finding.new("http://t/a", "GET", 200, 5_i64, "text/html", D::Source::Crawled, 1, 0.95, nil)

    with_store do |store|
      pair = D::Persist.flow_pair(f, 1_i64, ex, surface: Gori::FlowSource::Surface::Cli)
      id = store.insert_import_batch_ids([{pair.request, pair.response}]).first
      detail = store.get_flow(id).not_nil!

      # Byte-exact both ways — this is what History's detail renders (P7).
      String.new(detail.request_head).should eq("GET /a HTTP/1.1\r\nHost: t\r\nAccept: */*\r\n\r\n")
      String.new(detail.response_body.not_nil!).should eq("hello")
      detail.row.status.should eq(200)
      detail.row.method.should eq("GET")
      detail.row.url.should eq("http://t/a")
      detail.response_body_truncated?.should be_false
    end
  end

  it "marks a body the origin cut short as truncated" do
    ex = D::Exchange.new(
      request_head: "GET /big HTTP/1.1\r\nHost: t\r\n\r\n".to_slice,
      response: Gori::Proxy::Codec::Http1.parse_response_head(
        "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n".to_slice),
      body: "part".to_slice, body_size: 4096_i64, incomplete: true, duration_us: 10_i64)
    f = D::Finding.new("http://t/big", "GET", 200, 4096_i64, nil, D::Source::Crawled, 1, 0.95, nil)

    with_store do |store|
      pair = D::Persist.flow_pair(f, 2_i64, ex, surface: Gori::FlowSource::Surface::Cli)
      id = store.insert_import_batch_ids([{pair.request, pair.response}]).first
      detail = store.get_flow(id).not_nil!
      detail.response_body_truncated?.should be_true
      String.new(detail.response_body.not_nil!).should eq("part")
    end
  end

  it "still writes the synthesized stub when there is no exchange" do
    f = D::Finding.new("http://t/x", "GET", 403, 12_i64, "text/plain", D::Source::Bruteforced, 1, 0.9, nil)
    pair = D::Persist.flow_pair(f, 3_i64, surface: Gori::FlowSource::Surface::Cli)
    String.new(pair.response.not_nil!.head).should contain("X-Gori-Discover: bruteforced")
  end

  it "returns the new flow ids in pair order" do
    with_store do |store|
      pairs = (1..3).map do |i|
        f = D::Finding.new("http://t/#{i}", "GET", 200, 1_i64, nil, D::Source::Crawled, 1, 0.9, nil)
        p = D::Persist.flow_pair(f, i.to_i64, surface: Gori::FlowSource::Surface::Cli)
        {p.request, p.response}
      end
      ids = store.insert_import_batch_ids(pairs)
      ids.size.should eq(3)
      ids.should eq(ids.sort)
      ids.map { |id| store.get_flow(id).not_nil!.row.url }.should eq(%w[http://t/1 http://t/2 http://t/3])
    end
  end
end
