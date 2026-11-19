require "../spec_helper"

private alias F = Gori::Fuzz
private alias M = Gori::Miner

# Records the bytes and verbatim spans the wrapper hands down, so a test can assert what actually
# went to the inner sender after cache-busting.
private class RecordingBackend < F::Backend
  getter sends = [] of {Bytes, Array({Int32, Int32})?}

  def origin : F::Origin
    F::Origin.new("http", "example.test", 80)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    send(bytes, nil)
  end

  def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Gori::Repeater::Result
    @sends << {bytes, verbatim}
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, nil)
  end
end

private def line(bytes : Bytes) : String
  String.new(bytes).lines.first
end

describe M::CachebusterBackend do
  it "is on by default in a fresh Config — a mine must not poison a shared cache unasked" do
    M::Config.new.cachebuster?.should be_true
  end

  it "appends a unique cache-busting query param to every send" do
    inner = RecordingBackend.new
    backend = M::CachebusterBackend.new(inner)

    backend.send("GET /p HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, nil)
    backend.send("GET /p HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, nil)

    first = line(inner.sends[0][0])
    second = line(inner.sends[1][0])
    first.should match(/\AGET \/p\?__gcb=[0-9a-f]{16} HTTP\/1\.1\z/)
    second.should match(/\AGET \/p\?__gcb=[0-9a-f]{16} HTTP\/1\.1\z/)
    # Unique per request — nothing it sends shares a cache key with the probe before it.
    first.should_not eq(second)
  end

  it "shifts a header candidate's verbatim span past the inserted param" do
    inner = RecordingBackend.new
    backend = M::CachebusterBackend.new(inner)
    # A Headers-location probe: the candidate span lives past the request line, so adding a query
    # param to the request line must move it, or the send seam would protect the wrong bytes.
    req = "GET /p HTTP/1.1\r\nHost: h\r\nX-Cand: gqdeadbeef\r\n\r\n".to_slice
    span_start = String.new(req).index!("gqdeadbeef")
    sent, verbatim = begin
      backend.send(req, [{span_start, span_start + 10}])
      inner.sends[0]
    end
    # The injected value still sits exactly under its (shifted) span in the bytes handed down.
    s, e = verbatim.not_nil![0]
    String.new(sent[s, e - s]).should eq("gqdeadbeef")
  end

  it "does NOT shift a query candidate's span before the insertion point" do
    inner = RecordingBackend.new
    backend = M::CachebusterBackend.new(inner)
    # A Query-location probe already appended its candidate to the query; the cache-buster goes
    # AFTER it, so that span must not move.
    req = "GET /p?cand=gqdeadbeef HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    span_start = String.new(req).index!("gqdeadbeef")
    backend.send(req, [{span_start, span_start + 10}])
    sent, verbatim = inner.sends[0]
    s, e = verbatim.not_nil![0]
    String.new(sent[s, e - s]).should eq("gqdeadbeef")
    # …and the buster landed after the candidate.
    line(sent).should match(/\AGET \/p\?cand=gqdeadbeef&__gcb=[0-9a-f]{16} HTTP\/1\.1\z/)
  end

  it "never mints a canary-shaped value (Fingerprint would read it as a reflection)" do
    inner = RecordingBackend.new
    backend = M::CachebusterBackend.new(inner)
    50.times { backend.send("GET /p HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, nil) }
    inner.sends.each do |(bytes, _)|
      M::Canary.each_token(bytes) { fail "cache-buster produced a canary-shaped token" }
    end
  end
end
