require "../spec_helper"
require "socket"

# Round 4 / F6. `fuzz` / `mine` / `sequence` all took `--sni` (and `--http2`) on both the CLI
# and MCP, and all three landed it on the ClientHello. `discover` took neither on any surface,
# and `grep -rn sni src/gori/discover/` returned nothing — the engine had no field to carry
# one. Since the crawler also owns its own `Host:` header, an IP-direct sweep of a name-based
# vhost was not expressible at all.

private alias D = Gori::Discover

# A TCP listener that reads the ClientHello, reports its SNI, and hangs up. The handshake never
# completes, which is all this needs: the question is what gori put on the wire, not what came
# back. Same technique as spec/proxy/tls/client_hello_spec.cr, in the other direction.
private def with_hello_watcher(&)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = Channel(String?).new(8)
  spawn do
    while conn = server.accept?
      begin
        sni, _ = Gori::Proxy::Tls::ClientHello.peek_sni(conn)
        seen.send(sni)
      rescue
        seen.send(nil)
      ensure
        conn.close rescue nil
      end
    end
  rescue
    # server closed
  end
  begin
    yield port, seen
  ensure
    server.close rescue nil
  end
end

# Never a bare receive on a socket-driven channel (the PR #555 lesson).
private def take_sni(seen : Channel(String?)) : String?
  select
  when got = seen.receive
    got
  when timeout(15.seconds)
    fail "no ClientHello reached the listener"
  end
end

describe "Discover — --sni / --http2 parity with the other three engines" do
  it "threads sni and http2 from PlanOptions all the way to the Sender" do
    options = D::PlanOptions.new("https://127.0.0.1:1/", sni: "vhost.local", http2: true)
    plan = D::Plan.build(options, ungated_outbound)
    plan.sender.sni.should eq("vhost.local")
    plan.sender.http2?.should be_true
  end

  it "defaults to no override, which is what every existing caller gets" do
    plan = D::Plan.build(D::PlanOptions.new("https://127.0.0.1:1/"), ungated_outbound)
    plan.sender.sni.should be_nil
    plan.sender.http2?.should be_false
  end

  it "puts the override on the ClientHello of a real dial" do
    with_hello_watcher do |port, seen|
      options = D::PlanOptions.new("https://127.0.0.1:#{port}/", verify: false, sni: "vhost.local")
      plan = D::Plan.build(options, ungated_outbound)
      # `fetch` is the wire seam every crawl send goes through; driving it directly keeps the
      # example to one dial instead of a whole sweep.
      plan.sender.fetch("https", "127.0.0.1", port, "/")
      take_sni(seen).should eq("vhost.local")
      plan.sender.close
    end
  end

  it "presents the dialed host, not the override, when --sni is absent" do
    with_hello_watcher do |port, seen|
      plan = D::Plan.build(D::PlanOptions.new("https://127.0.0.1:#{port}/", verify: false), ungated_outbound)
      plan.sender.fetch("https", "127.0.0.1", port, "/")
      take_sni(seen).should_not eq("vhost.local")
      plan.sender.close
    end
  end

  it "carries the override through the keep-alive pool's own dial too" do
    # The pool dials independently of `Repeater::Engine.send`, and it was constructed with a
    # hard-coded `nil` sni — so a crawl with keep-alive on (the default) would have dropped the
    # override on every probe after the first even if the direct path had it.
    with_hello_watcher do |port, seen|
      config = D::Config.new(keep_alive: true, concurrency: 1)
      options = D::PlanOptions.new("https://127.0.0.1:#{port}/", config: config,
        verify: false, sni: "pooled.local")
      plan = D::Plan.build(options, ungated_outbound)
      plan.sender.fetch("https", "127.0.0.1", port, "/")
      take_sni(seen).should eq("pooled.local")
      plan.sender.close
    end
  end
end
