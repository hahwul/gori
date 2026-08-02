require "../spec_helper"

private alias P = Gori::Probe
private alias F = Gori::Fuzz
private alias S = Gori::Store

# The PROVENANCE axis at the PROBE ACTIVE send seam (round 7, hunter finding 1a).
#
# Probe active builds every probe from a CAPTURED request. Real captured traffic is full of
# `$NAME`-shaped bytes the operator never typed — Mongo `$ne`/`$where`, JSON Schema
# `$ref`/`$schema`, and a GraphQL operation, which is MADE of `$variable` references. The
# `$`+`[A-Za-z_]`+`[A-Za-z0-9_]*` grammar has no delimiter requirement, so with an extract
# rule named `id` bound, `Active.analyze`'s one-arg `sender.send(plan.request)` ran
# `Env.expand_bindings` over the whole captured body and shipped
# `query GetUser(<live session token>: ID!)` to the target — a real credential in its access
# log, inside a request nobody authored, with the scan reporting itself clean.
#
# Round 6 fixed the identical class in the param-miner (see miner/binding_provenance_spec.cr)
# with the polarity INVERTED: there the INJECTED candidate is verbatim and the captured seed
# expands. Here the captured request IS the test case and nothing in the buffer is
# operator-authored, so the whole request is verbatim.
#
# The backend below mimics `Fuzz::Sender` exactly (the same
# `Env.expand_bindings` pass), so every assertion is on the bytes that would hit the socket.

# A layer with the name DECLARED and BOUND — the send-time binding half.
private class StubLayer < Gori::Env::Layer
  def initialize(@vals : Hash(String, String))
  end

  def declared : Array(String)
    @vals.keys
  end

  def values : Hash(String, String)
    @vals
  end

  def rev : UInt64
    1_u64
  end
end

# Records the WIRE bytes (after the exact two-line pass `Fuzz::Sender` runs) and the
# `verbatim` spans it was handed, so a test can assert both what left and what was protected.
private class ExpandingBackend < F::Backend
  getter origin : F::Origin
  getter wire = [] of String
  getter got_verbatim = [] of Array({Int32, Int32})?

  def initialize(@origin : F::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    record(bytes, nil)
  end

  def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Gori::Repeater::Result
    record(bytes, verbatim)
  end

  private def record(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Gori::Repeater::Result
    @got_verbatim << verbatim
    @wire << String.new(Gori::Env.expand_bindings(bytes, verbatim))
    ok
  end

  private def ok : Gori::Repeater::Result
    body = "{\"ok\":true}"
    head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, body.to_slice, nil, 1000_i64)
  end
end

private def with_binding(name : String, value : String, &)
  prev_layer = Gori::Env.layer
  prev_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Env.layer = StubLayer.new({name => value})
  begin
    yield
  ensure
    Gori::Env.layer = prev_layer
    Gori::Settings.env_prefix = prev_prefix
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
  end
end

# A captured POST flow, built directly (no store) so the spec asserts on the send seam alone.
private def captured(body : String, target : String = "/graphql?q=hello") : S::FlowDetail
  head = "POST #{target} HTTP/1.1\r\nHost: acme.test\r\n" \
         "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n"
  row = S::FlowRow.new(
    1_i64, 1_i64, "https", "POST", "acme.test", 443, target,
    200, 100_i64, S::FlowState::Complete, 11_i64, 1_i64, "application/json")
  resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
  S::FlowDetail.new(row, "HTTP/1.1", head.to_slice, body.to_slice,
    resp.to_slice, "{\"ok\":true}".to_slice)
end

# The same captured flow, but pointed at a real loopback port over cleartext http, so the
# analyzer's own `Fuzz::Sender` actually dials it.
private def local_captured(body : String, port : Int32) : S::FlowDetail
  target = "/graphql?q=hello"
  head = "POST #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
         "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n"
  row = S::FlowRow.new(
    1_i64, 1_i64, "http", "POST", "127.0.0.1", port, target,
    200, 100_i64, S::FlowState::Complete, 11_i64, 1_i64, "application/json")
  resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
  S::FlowDetail.new(row, "HTTP/1.1", head.to_slice, body.to_slice,
    resp.to_slice, "{\"ok\":true}".to_slice)
end

private def with_store(&)
  path = File.tempname("gori-probe-prov", ".db")
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

# The exact body H1 captured: a GraphQL operation carrying `$id`, plus a Mongo `$ne`.
private GQL_BODY = %({"query":"query GetUser($id: ID!) { user(id: $id) { name } }",) +
                   %("variables":{"id":"42"},"filter":{"age":{"$ne":null}}})

describe "Gori::Probe::Active session-binding provenance" do
  it "does NOT expand a `$NAME` that arrived from the wire in a CAPTURED body" do
    with_binding("id", "ORIGINSID1234567890") do
      backend = ExpandingBackend.new(F::Origin.new("https", "acme.test", 443))
      P::Active.analyze(captured(GQL_BODY), outbound: ungated_outbound, backend: backend,
        opts: P::Active::Options.new(allow_unsafe: true))

      backend.wire.should_not be_empty
      # The credential never left the machine. Before the fix this appeared 14 times.
      backend.wire.none?(&.includes?("ORIGINSID1234567890")).should be_true
      # And the captured evidence reached the wire as the client wrote it.
      backend.wire.any?(&.includes?("query GetUser($id: ID!)")).should be_true
      # `$ne` survives for the same reason `$id` now does, not by luck of the name.
      backend.wire.any?(&.includes?(%("$ne":null))).should be_true
    end
  end

  it "marks the WHOLE probe request verbatim at every send, primary and followup" do
    with_binding("id", "ORIGINSID1234567890") do
      backend = ExpandingBackend.new(F::Origin.new("https", "acme.test", 443))
      P::Active.analyze(captured(GQL_BODY), outbound: ungated_outbound, backend: backend,
        opts: P::Active::Options.new(allow_unsafe: true))

      # Not "some spans reached the seam" — EVERY send, including the differential rules'
      # followups, must be covered start-to-end, or a followup measures the substitution.
      backend.got_verbatim.should_not be_empty
      backend.got_verbatim.each do |v|
        spans = v.should_not be_nil
        spans.size.should eq(1)
        spans.first[0].should eq(0)
      end
      backend.got_verbatim.size.should eq(backend.wire.size)
    end
  end

  it "leaves a capture with NO `$` byte-identical — the scan is not otherwise changed" do
    plain = %({"query":"query GetUser","variables":{"id":"42"}})
    with_binding("id", "ORIGINSID1234567890") do
      fixed = ExpandingBackend.new(F::Origin.new("https", "acme.test", 443))
      P::Active.analyze(captured(plain), outbound: ungated_outbound, backend: fixed,
        opts: P::Active::Options.new(allow_unsafe: true))
      # With no `$` in the buffer, expansion was already a no-op: `verbatim` changes nothing
      # about which probes are built or what they carry.
      fixed.wire.none?(&.includes?("ORIGINSID1234567890")).should be_true
      fixed.wire.any?(&.includes?("query GetUser")).should be_true
    end
  end

  # The TUI path. `Probe::Analyzer#execute_active` is a SEPARATE send loop over the same
  # plans — it builds its own `Fuzz::Sender` and never enters `Active.analyze` — so a spec
  # that drove only `.analyze` above would stay green while the live TUI leaked. That is
  # exactly how this survived the headless audit, so this one goes through a real socket:
  # the analyzer offers no backend seam, and the bytes on the wire are the claim anyway.
  it "does not expand a captured `$NAME` on the ANALYZER loop either (the TUI twin)" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    seen = [] of String
    done = Channel(Nil).new(16)
    spawn do
      while sock = server.accept?
        begin
          buf = Bytes.new(16384)
          n = sock.read(buf)
          seen << String.new(buf[0, n]) if n > 0
          body = "{\"ok\":true}"
          sock << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                  "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
          sock.flush
        rescue
        ensure
          sock.close rescue nil
          done.send(nil) rescue nil
        end
      end
    end

    begin
      with_binding("id", "ORIGINSID1234567890") do
        with_store do |store|
          scope = Gori::Scope.load(store)
          scope.add("include", "host", "127.0.0.1")
          detail = local_captured(GQL_BODY, port)
          a = P::Analyzer.new(store, scope, Channel(S::FlowEvent).new(1), P::Mode::Active, false)
          a.start
          a.run_active_now(detail, allow_unsafe: true)
          # Wait for probe traffic without a bare receive (PR #555): poll to a deadline.
          deadline = Time.instant + 8.seconds
          while seen.size < 3 && Time.instant < deadline
            sleep 20.milliseconds
          end
          a.stop
        end
      end

      seen.should_not be_empty
      # The live credential never reached the socket…
      seen.none?(&.includes?("ORIGINSID1234567890")).should be_true
      # …and the captured GraphQL operation did, exactly as the client wrote it.
      seen.any?(&.includes?("query GetUser($id: ID!)")).should be_true
    ensure
      server.close
    end
  end

  it "still refuses and REPORTS a scope block — blocked accounting is untouched" do
    with_binding("id", "ORIGINSID1234567890") do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("exclude", "host", "acme.test")
        inner = ExpandingBackend.new(F::Origin.new("https", "acme.test", 443))
        errs = [] of String
        dets = P::Active.analyze(captured(GQL_BODY),
          outbound: Gori::Outbound.interactive(scope), backend: inner,
          opts: P::Active::Options.new(allow_unsafe: true),
          on_error: ->(_id : String, ex : Exception) { errs << ex.message.to_s; nil })

        inner.wire.should be_empty # hard-blocked before the socket, as before
        dets.should be_empty
        # The refusal still reaches the caller, deduped to one row for the flow (#491):
        # `verbatim` only silences the BINDING half of the gate, never the scope half.
        errs.size.should eq(1)
      end
    end
  end
end
