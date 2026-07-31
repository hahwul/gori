require "../../spec_helper"
require "log/spec"
require "socket"
require "openssl"
require "file_utils"

# The h2 downgrade gate, narrowed to the host a rule can actually match (#526).
#
# Before this, `Tls::Tunnel#h2_candidate?` asked two HOST-BLIND questions — "is any body rule
# live", "is any short-circuit rule live" — both of which read a global atomic count. One rule
# scoped to `alpha.test` therefore forced every h2 host on the proxy onto HTTP/1.1, including
# hosts its own glob can never match, and gori announced the downgrade for them.
#
# Every downgrade case here is paired with the control that makes it attributable: same proxy,
# same origin, same client, only the rule's host glob differs.

include Gori::Proxy
include Gori::Proxy::Tls

private alias GFrame = Gori::Proxy::H2::Frame
private alias GHPACK = Gori::Proxy::H2::HPACK

private SCOPED_SC   = Gori::Store::RuleOp::ShortCircuit
private SCOPED_REQ  = Gori::Store::RuleTarget::Request
private SCOPED_HEAD = Gori::Store::RulePart::Head
private SCOPED_BODY = Gori::Store::RulePart::Body

private class GateSink < FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

# The abstract seam with nothing overridden — what a caller gets from a rewriter that is not
# `Rules` (the h2c/reverse paths pass one).
private class NoopRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end
end

private def with_gate_rules(&)
  path = File.tempname("gori-h2-gate", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Rules.load(store)
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# An origin that advertises h2 in ALPN and counts accepts, so "the ALPN probe was skipped" is
# measured rather than inferred. Same shape as http2_toggle_spec's.
private def start_gate_origin(accepts : Array(Int32)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: true)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      accepts[0] += 1
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        Codec::Http1.read_head(ssl) # a probe connection sends nothing; this parks until close
      rescue
      end
    end
  end
  port
end

private def gate_client(raw : TCPSocket, ca_dir : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.alpn_protocol = "h2"
  ca_cert = Cert.read_pem(File.join(ca_dir, "root.crt.pem"))
  store = LibSSL.ssl_ctx_get_cert_store(ctx.to_unsafe)
  LibCrypto.x509_store_add_cert(store, ca_cert.handle)
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: "localhost")
end

# CONNECT to `localhost:<origin>` through a proxy carrying `rewriter`, and yield what gori
# advertised in ALPN plus how many times the origin was dialed.
private def alpn_through_proxy(rewriter : Gori::Proxy::HeadRewriter, tag : String, &) : Nil
  dir = File.tempname("gori-ca-#{tag}")
  accepts = [0]
  begin
    origin_port = start_gate_origin(accepts)
    ca = CertAuthority.load_or_create(dir)
    proxy = Server.new("127.0.0.1", 0, GateSink.new,
      tls: Tunnel.new(ca, verify_upstream: false, rewriter: rewriter))
    proxy.start

    raw = TCPSocket.new("127.0.0.1", proxy.port)
    raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
    raw.flush
    Codec::Http1.read_head(raw).not_nil!

    tls = gate_client(raw, dir)
    negotiated = tls.alpn_protocol
    tls.close
    proxy.stop
    yield negotiated, accepts[0]
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

private def with_gate_bindings(&)
  path = File.tempname("gori-h2-gate-bind", ".db")
  store = Gori::Store.open(path)
  begin
    # Both tables off ONE store, because that is how `Session` wires them: the same proxy
    # carries `rewriter: rules` and `extractor: bindings`, and the notice has to weigh both.
    yield Gori::Rules.load(store), Gori::Bindings.load(store)
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def gate_pipe(rewriter : Gori::Proxy::HeadRewriter?,
                      extractor : Gori::Proxy::ResponseExtract? = nil) : {Gori::Proxy::H2::HeadRewrite, Gori::Proxy::H2::Assembler}
  assembler = Gori::Proxy::H2::Assembler.new(GateSink.new, "api.example.com", 443, 1_i64)
  {Gori::Proxy::H2::HeadRewrite.new("out", rewriter, assembler, "api.example.com", extractor), assembler}
end

private def feed_authority(pipe : Gori::Proxy::H2::HeadRewrite,
                           assembler : Gori::Proxy::H2::Assembler, authority : String) : Nil
  block = GHPACK::Encoder.new.encode([{":method", "GET"}, {":scheme", "https"},
                                      {":authority", authority}, {":path", "/x"}])
  frame = GFrame::Header.new(GFrame::Type::Headers.value,
    GFrame::END_HEADERS | GFrame::END_STREAM, 1_u32, block)
  pipe.accept(frame) { |f, pre| assembler.feed("out", f, pre) }
end

describe "h2 downgrade gate, host-scoped (#526)" do
  describe Gori::Rules do
    it "answers false for a host no body rule's glob can match" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED", host: "alpha.test")
        # The host-blind pair stays true, and must: `ClientConn` asks it per message on a
        # connection already pinned to one host, which is not the question #526 narrowed.
        rules.rewrites_request_body?.should be_true

        rules.rewrites_body_for_host?("alpha.test").should be_true
        rules.rewrites_body_for_host?("api.alpha.test").should be_true # substring dialect
        rules.rewrites_body_for_host?("127.0.0.1").should be_false     # the bug
      end
    end

    it "answers true everywhere for an UNSCOPED body rule — today's behaviour, unchanged" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED") # empty glob
        rules.rewrites_body_for_host?("127.0.0.1").should be_true
        rules.rewrites_body_for_host?("anything.at.all").should be_true
      end
    end

    it "reads a wildcard glob the way the rewrite path does" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED", host: "*.alpha.test")
        rules.rewrites_body_for_host?("api.alpha.test").should be_true
        rules.rewrites_body_for_host?("alpha.test").should be_false
      end
    end

    it "scopes the short-circuit question exactly as `short_circuit` itself is scoped" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_HEAD, "/admin", "403 Forbidden", op: SCOPED_SC, host: "alpha.test")
        rules.short_circuits?.should be_true
        rules.short_circuits_for_host?("alpha.test").should be_true
        rules.short_circuits_for_host?("127.0.0.1").should be_false
        # ...and that is precisely the reachability `short_circuit` has for those two hosts,
        # which is what the gate exists to protect.
        rules.short_circuit("GET /admin HTTP/1.1\r\n\r\n".to_slice, "alpha.test").should_not be_nil
        rules.short_circuit("GET /admin HTTP/1.1\r\n\r\n".to_slice, "127.0.0.1").should be_nil
      end
    end

    it "ignores a disabled rule, and never counts a HEAD rule" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED")
        rules.toggle(rules.rules.first.id)
        rules.rewrites_body_for_host?("alpha.test").should be_false

        rules.add(SCOPED_REQ, SCOPED_HEAD, "Host: a", "Host: b") # head rules reach h2 since #492 step 2
        rules.rewrites_body_for_host?("alpha.test").should be_false
        rules.short_circuits_for_host?("alpha.test").should be_false
      end
    end

    it "defaults to false on the seam, matching the host-blind pair" do
      stub = NoopRewriter.new
      stub.rewrites_body_for_host?("anything").should be_false
      stub.short_circuits_for_host?("anything").should be_false
    end
  end

  # End to end against a real Tunnel: what the client is actually offered.
  describe "through the proxy" do
    it "keeps h2 for a host a BODY rule cannot match, and downgrades the host it can" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED", host: "alpha.test")
        # The fix: `localhost` is not `alpha.test`, so the rule costs it nothing.
        alpn_through_proxy(rules, "body-scoped-away") do |negotiated, accepts|
          negotiated.should eq("h2")
          accepts.should eq(1) # the ALPN reflection probe ran, i.e. the gate let it through
        end
      end

      # The control: the SAME rule, re-scoped to the host being reached, still downgrades.
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED", host: "localhost")
        alpn_through_proxy(rules, "body-scoped-here") do |negotiated, accepts|
          negotiated.should_not eq("h2")
          accepts.should eq(0) # a downgrade short-circuits before reflect_origin_h2 dials
        end
      end
    end

    it "still downgrades EVERY host for an unscoped body rule (the regression guard)" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED") # empty glob = every host
        alpn_through_proxy(rules, "body-unscoped") do |negotiated, accepts|
          negotiated.should_not eq("h2")
          accepts.should eq(0)
        end
      end
    end

    it "keeps h2 for a host a SHORT-CIRCUIT rule cannot match, and downgrades the host it can" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_HEAD, "/admin", "403 Forbidden", op: SCOPED_SC, host: "alpha.test")
        alpn_through_proxy(rules, "stub-scoped-away") do |negotiated, accepts|
          negotiated.should eq("h2")
          accepts.should eq(1)
        end
      end

      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_HEAD, "/admin", "403 Forbidden", op: SCOPED_SC, host: "localhost")
        alpn_through_proxy(rules, "stub-scoped-here") do |negotiated, accepts|
          negotiated.should_not eq("h2")
          accepts.should eq(0)
        end
      end
    end

    it "still downgrades EVERY host for an unscoped short-circuit rule (the regression guard)" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_HEAD, "/admin", "403 Forbidden", op: SCOPED_SC)
        alpn_through_proxy(rules, "stub-unscoped") do |negotiated, accepts|
          negotiated.should_not eq("h2")
          accepts.should eq(0)
        end
      end
    end
  end

  # The cost #526 states up front: a per-CONNECT gate cannot see a stream whose `:authority`
  # is a different host (RFC 9113 §9.1.1 coalescing). It stays SPOKEN rather than silent.
  describe "coalesced-stream notice" do
    it "logs once when a coalesced stream carries a rule the connection gate never saw" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED", host: "alpha.test")
        pipe, assembler = gate_pipe(rules)
        Log.capture do |logs|
          feed_authority(pipe, assembler, "alpha.test")
          logs.check(:warn, /stream authority "alpha\.test" is not the CONNECT host "api\.example\.com"/)
          # ...and it names WHICH kind, so the operator knows which table to look in (#536).
          logs.entry.message.should contain("a Match&Replace BODY rule")
          # Once per connection, not once per stream.
          feed_authority(pipe, assembler, "alpha.test")
          logs.empty
        end
      end
    end

    it "names the short-circuit rule when that is the kind that was skipped" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_HEAD, "/admin", "403 Forbidden", op: SCOPED_SC, host: "alpha.test")
        pipe, assembler = gate_pipe(rules)
        Log.capture do |logs|
          feed_authority(pipe, assembler, "alpha.test")
          logs.check(:warn, /stream authority "alpha\.test"/)
          logs.entry.message.should contain("a Match&Replace SHORT-CIRCUIT rule")
        end
      end
    end

    it "says nothing for the ordinary stream — the authority IS the connection host" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED", host: "api.example.com")
        pipe, assembler = gate_pipe(rules)
        Log.capture do |logs|
          feed_authority(pipe, assembler, "api.example.com")
          logs.empty
        end
      end
    end

    it "says nothing when no rule matches the coalesced authority either" do
      with_gate_rules do |rules|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED", host: "beta.test")
        pipe, assembler = gate_pipe(rules)
        Log.capture do |logs|
          feed_authority(pipe, assembler, "alpha.test")
          logs.empty
        end
      end
    end

    # #536: a body-scoped session-binding extract rule (#501 slice 2) is host-scoped through the
    # same gate and unreachable on this relay for the same reason, so it belongs in this notice.
    it "names a body-scoped EXTRACT rule that the connection gate never saw" do
      with_gate_bindings do |rules, bindings|
        bindings.add("SESSION", "", Gori::ExtractKind::Regex, "tok=(\\w+)", host: "alpha.test").should be_nil
        # No Match&Replace rule at all — the rewriter is INACTIVE. Before #536 the notice ran
        # from inside `rewrite`, behind `rw.active?`, so this case produced nothing.
        rules.active?.should be_false
        pipe, assembler = gate_pipe(rules, bindings)
        Log.capture do |logs|
          feed_authority(pipe, assembler, "alpha.test")
          logs.check(:warn, /stream authority "alpha\.test" is not the CONNECT host "api\.example\.com"/)
          logs.entry.message.should contain("a session-binding EXTRACT rule that reads the response body")
          feed_authority(pipe, assembler, "alpha.test")
          logs.empty # once per connection, same latch
        end
      end
    end

    it "says nothing for a HEAD-scoped extract rule — `H2::Extract` applies it on the relay" do
      with_gate_bindings do |rules, bindings|
        bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid", host: "alpha.test").should be_nil
        bindings.extracts?.should be_true # live, just not unreachable
        pipe, assembler = gate_pipe(rules, bindings)
        Log.capture do |logs|
          feed_authority(pipe, assembler, "alpha.test")
          logs.empty
        end
      end
    end

    it "says nothing when the extract rule's glob cannot match the coalesced authority" do
      with_gate_bindings do |rules, bindings|
        bindings.add("SESSION", "", Gori::ExtractKind::Regex, "tok=(\\w+)", host: "beta.test").should be_nil
        pipe, assembler = gate_pipe(rules, bindings)
        Log.capture do |logs|
          feed_authority(pipe, assembler, "alpha.test")
          logs.empty
        end
      end
    end

    it "names every kind that matches, in one line" do
      with_gate_bindings do |rules, bindings|
        rules.add(SCOPED_REQ, SCOPED_BODY, "secret", "REDACTED", host: "alpha.test")
        bindings.add("SESSION", "", Gori::ExtractKind::Regex, "tok=(\\w+)", host: "alpha.test").should be_nil
        pipe, assembler = gate_pipe(rules, bindings)
        Log.capture do |logs|
          feed_authority(pipe, assembler, "alpha.test")
          logs.check(:warn, /stream authority "alpha\.test"/)
          logs.entry.message.should contain("a Match&Replace BODY rule")
          logs.entry.message.should contain("a session-binding EXTRACT rule that reads the response body")
        end
      end
    end
  end
end
