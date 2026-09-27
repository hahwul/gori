require "../spec_helper"
require "../support/mcp_harness"
require "openssl"

# `gori mcp --insecure-upstream` waives upstream TLS verification for every tool that sends.
# race_requests, timing_requests and cache_deception_check read only their own argument, so
# they failed every member against a self-signed lab target the rest of the server reached.
private def with_self_signed_origin(&)
  ca_cert, ca_key = Gori::Proxy::Tls::CertBuilder.build_root("insecure-upstream spec CA")
  leaf_cert, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("127.0.0.1", ca_cert, ca_key)
  ctx = Gori::Proxy::Tls::ContextFactory.server_context(leaf_cert, leaf_key, ca_cert: ca_cert, advertise_h2: false)
  server = TCPServer.new("127.0.0.1", 0)
  spawn do
    while raw = server.accept?
      spawn_with(raw) do |c|
        begin
          ssl = OpenSSL::SSL::Socket::Server.new(c, ctx, sync_close: true)
          Gori::Proxy::Codec::Http1.read_head(ssl)
          ssl << "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nhit"
          ssl.flush
          ssl.close rescue nil
        rescue
          c.close rescue nil
        end
      end
    end
  rescue
  end
  begin
    yield server.local_address.port
  ensure
    server.close rescue nil
  end
end

private def seed_tls_repeater(store, port : Int32, path : String) : Int64
  store.insert_repeater(target: "https://127.0.0.1:#{port}",
    request: "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
    http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
end

describe "gori mcp --insecure-upstream" do
  it "reaches a self-signed target from race_requests, timing_requests and cache_deception_check" do
    with_store do |store|
      with_self_signed_origin do |port|
        a = seed_tls_repeater(store, port, "/a")
        b = seed_tls_repeater(store, port, "/b")
        tools = tools_for(store, verify_upstream: false)

        race = JSON.parse(tools.call("race_requests", JSON.parse(%({"repeater_ids":[#{a},#{b}],"allow_unscoped":true}))).text)
        race["responded"].as_i.should eq(2)

        timing = JSON.parse(tools.call("timing_requests",
          JSON.parse(%({"repeater_ids":[#{a},#{b}],"allow_unscoped":true,"count":2,"warmup":0,"interleaved":true}))).text)
        timing["pairs_valid"].as_i.should eq(2)

        fid = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "127.0.0.1", port: port,
          method: "GET", target: "/me", http_version: "HTTP/1.1",
          head: "GET /me HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nCookie: s=1\r\n\r\n".to_slice,
          source: Gori::FlowSource::Kind::Proxy))
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: fid, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n".to_slice, body: "hit".to_slice))
        store.flush
        cd = tools.call("cache_deception_check", JSON.parse(%({"flow_id":#{fid},"allow_unscoped":true})))
        cd.text.should_not contain("TLS verification failed")
        JSON.parse(cd.text)["verdict"].as_s.should_not eq("errored")
      end
    end
  end
end
