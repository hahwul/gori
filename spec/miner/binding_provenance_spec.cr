require "../spec_helper"

private alias M = Gori::Miner
private alias F = Gori::Fuzz

# The PROVENANCE axis at the param-miner send seam (carried defect #1, round 6).
#
# The miner injects candidate names/values into the request and sends. Round 5 taught the
# Fuzzer to exclude the operator's PAYLOAD bytes from session-binding expansion (`verbatim`
# spans) so a `$TOKEN` under test is not replaced by the live session credential on the wire.
# The miner reached the send seam through `Inject.apply` rather than the fuzz Generator, so it
# never passed spans: an injected candidate name like `$SECRET` — which real param wordlists
# carry — expanded to the bound value and left gori for the target, the run reporting 0 errors.
#
# These drive the real engine through a backend that mimics `Fuzz::Sender` exactly (the same
# `Env.expand_bindings` pass), so the assertion is on the bytes that would hit the socket.

# A layer with `SECRET` DECLARED and BOUND to `livevalue` — the send-time binding half.
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

# Records the WIRE bytes (after running the exact two-line pass `Fuzz::Sender` runs) and the
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
    wire_bytes = Gori::Env.expand_bindings(bytes, verbatim)
    @wire << String.new(wire_bytes)
    ok
  end

  private def ok : Gori::Repeater::Result
    body = "BASELINE BODY CONTENT"
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
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

private def mine_headers(backend : F::Backend, base : String, names : Array(String)) : Nil
  c = M::Config.new
  c.locations = [M::Location::Headers]
  c.bucket_size = M::Config::DEFAULT_BUCKETS.dup
  c.bucket_size[M::Location::Headers] = 4
  c.concurrency = 1
  c.stability_rounds = 2
  c.confirm_rounds = 1
  c.retries = 0
  engine = M::Engine.new(base.to_slice, http2: false, names: names, backend: backend, config: c)
  engine.run { }
end

describe "Gori::Miner::Engine session-binding provenance" do
  it "does NOT expand a `$BINDING` in an injected candidate name (no credential leak)" do
    with_binding("SECRET", "livevalue") do
      backend = ExpandingBackend.new(F::Origin.new("http", "h", 80))
      # `$SECRET` is a valid header-name token, and param wordlists really do carry templated
      # names. The seed head carries its OWN `$SECRET` (the operator's captured session), which
      # MUST still expand.
      base = "GET /api HTTP/1.1\r\nHost: h\r\nAuthorization: $SECRET\r\n\r\n"
      mine_headers(backend, base, ["alpha", "$SECRET", "beta"])

      # The seed's own binding resolved on the wire (that is what bindings are for).
      backend.wire.any?(&.includes?("Authorization: livevalue")).should be_true

      # The INJECTED candidate name stayed literal — it was sent as a header called `$SECRET`,
      # NOT expanded into a header called `livevalue` (which is the leak: the live credential
      # as an injected header name, reported back as a clean run).
      backend.wire.any?(&.includes?("$SECRET: ")).should be_true
      backend.wire.none?(&.includes?("livevalue: ")).should be_true

      # The spans that protect it actually reached the send seam.
      backend.got_verbatim.any? { |v| v && !v.empty? }.should be_true
    end
  end

  it "leaves a normal (no-`$`) candidate untouched — mining is not changed by the fix" do
    with_binding("SECRET", "livevalue") do
      backend = ExpandingBackend.new(F::Origin.new("http", "h", 80))
      base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n"
      mine_headers(backend, base, ["alpha", "beta", "gamma"])
      # No `$` anywhere → expansion is a no-op, the canary values ride the wire intact, and the
      # bound value never appears.
      backend.wire.none?(&.includes?("livevalue")).should be_true
      backend.wire.any? { |w| w.includes?("alpha: ") || w.includes?("beta: ") || w.includes?("gamma: ") }.should be_true
    end
  end
end
