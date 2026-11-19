require "../../spec_helper"

private WS_BROWSER_FIELDS = [
  {"origin", "https://partner.test"},
  {"sec-fetch-site", "cross-site"},
  {"sec-fetch-mode", "websocket"},
  {"cookie", "session=COOKIE_FIXTURE"},
]
private WS_CROSS_SITE_CODE = "ws_cross_site_cookie"

private def browser_ws_flow(store, fields = WS_BROWSER_FIELDS, status = 101, *,
                            accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", edited = false,
                            source = Gori::FlowSource::Kind::Proxy)
  target = "/messages?token=QUERY_FIXTURE"
  req = String.build do |io|
    io << "GET #{target} HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    io << "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    fields.each { |(name, value)| io << name << ": " << value << "\r\n" }
    io << "\r\n"
  end
  resp = String.build do |io|
    io << "HTTP/1.1 #{status} Response\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    io << "Sec-WebSocket-Accept: " << accept << "\r\n" if accept
    io << "\r\n"
  end
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443, method: "GET",
    target: target, http_version: "HTTP/1.1", head: req.to_slice, source: source,
    intercept_original: edited ? "GET /messages HTTP/1.1\r\n\r\n".to_slice : nil))
  store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: status, head: resp.to_slice))
  store.get_flow(id).not_nil!
end

describe Gori::Probe::Passive::WebSocketOrigin do
  it "reports an accepted browser cross-site WebSocket with cookies as Info" do
    with_store do |store|
      detail = browser_ws_flow(store)
      hit = Gori::Probe::Passive.analyze(detail).find!(&.code.==(WS_CROSS_SITE_CODE))
      hit.severity.should eq(Gori::Store::Severity::Info)
      hit.flow_id.should eq(detail.row.id)
      hit.url.should eq("https://acme.test/messages")
      hit.evidence.should eq("Sec-Fetch-Site: cross-site; Cookie header present")
      Gori::Probe::Passive.analyze(detail, disabled: Set{"websocket_origin"}).map(&.code)
        .should_not contain(WS_CROSS_SITE_CODE)
    end
  end

  it "requires an accepted handshake, cross-site metadata, a valid Origin, and a cookie" do
    with_store do |store|
      rejected = browser_ws_flow(store, status: 403)
      Gori::Probe::Passive.analyze(rejected).map(&.code).should_not contain(WS_CROSS_SITE_CODE)
      [nil, "mismatch"].each do |accept|
        Gori::Probe::Passive.analyze(browser_ws_flow(store, accept: accept)).map(&.code)
          .should_not contain(WS_CROSS_SITE_CODE)
      end

      [
        {"sec-fetch-mode", nil}, {"sec-fetch-site", "same-site"},
        {"origin", "https://acme.test:8443"}, {"origin", "null"},
        {"origin", "https://[:::.]"},
        {"origin", "https://partner.test/path"}, {"cookie", nil}, {"cookie", "session="},
      ].each do |(name, value)|
        fields = WS_BROWSER_FIELDS.reject { |(key, _)| key == name }
        fields << {name, value} if value
        Gori::Probe::Passive.analyze(browser_ws_flow(store, fields)).map(&.code)
          .should_not contain(WS_CROSS_SITE_CODE)
      end

      duplicate = browser_ws_flow(store, WS_BROWSER_FIELDS + [{"sec-fetch-site", "cross-site"}])
      Gori::Probe::Passive.analyze(duplicate).map(&.code).should_not contain(WS_CROSS_SITE_CODE)
    end
  end

  it "skips manually edited and gori-originated handshakes" do
    with_store do |store|
      [browser_ws_flow(store, edited: true), browser_ws_flow(store, source: Gori::FlowSource::Kind::Repeater)].each do |detail|
        Gori::Probe::Passive.analyze(detail).map(&.code).should_not contain(WS_CROSS_SITE_CODE)
      end
    end
  end

  it "reports the same observation for an HTTP/2 extended CONNECT" do
    with_store do |store|
      fields = [{":method", "CONNECT"}, {":scheme", "https"}, {":authority", "acme.test"},
                {":path", "/messages"}, {"sec-websocket-version", "13"}] + WS_BROWSER_FIELDS
      head = Gori::Proxy::H2::HeadCodec.synth_request(fields, "acme.test", protocol: "websocket")
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443, method: "CONNECT",
        target: "/messages", http_version: "HTTP/2", head: head, body: nil, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
        head: Gori::Proxy::H2::HeadCodec.synth_response([{":status", "200"}]), body: nil, duration_us: 1_i64))
      Gori::Probe::Scan.scan_flows(store, [id], active: false).map(&.code).should contain(WS_CROSS_SITE_CODE)
    end
  end
end
