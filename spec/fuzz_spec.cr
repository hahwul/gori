require "./spec_helper"
require "socket"

private alias F = Gori::Fuzz

# A Backend that returns a canned response per request, with no socket.
private class FakeBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, &@fn : Bytes -> Gori::Replay::Result)
  end

  def send(bytes : Bytes) : Gori::Replay::Result
    @sent += 1
    @fn.call(bytes)
  end
end

private def ok_result(status : Int32, body : String) : Gori::Replay::Result
  head = "HTTP/1.1 #{status} OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
  resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
  Gori::Replay::Result.new(head, body.to_slice, resp, 1234_i64)
end

private def drain(engine : F::Engine) : {Array(F::Result), F::DoneEvent?}
  results = [] of F::Result
  done = nil.as(F::DoneEvent?)
  engine.run do |ev|
    case ev
    when F::ResultEvent then results << ev.result
    when F::DoneEvent   then done = ev
    end
  end
  {results, done}
end

describe F::Template do
  it "parses §…§ markers into segments + positioned defaults" do
    t = F::Template.parse("GET /a?x=§foo§&y=§bar§ HTTP/1.1\r\n\r\n")
    t.position_count.should eq(2)
    t.positions.map(&.default).should eq(["foo", "bar"])
    String.new(t.render(["1", "2"])).should eq("GET /a?x=1&y=2 HTTP/1.1\r\n\r\n")
  end

  it "treats §§ as a literal § and an unbalanced § as text" do
    F::Template.parse("a§§b").position_count.should eq(0)
    String.new(F::Template.parse("a§§b").render([] of String)).should eq("a§b")
    F::Template.parse("a§b").position_count.should eq(0) # unbalanced trailing § → literal
    String.new(F::Template.parse("a§b").render([] of String)).should eq("a§b")
  end

  it "keeps the literal tail after a position when a trailing § is unbalanced (no truncation)" do
    # x=§A§&y=§z : one position (A), then a stray trailing § that opens no pair.
    t = F::Template.parse("x=§A§&y=§z")
    t.position_count.should eq(1)
    # render must keep '&y=§z' verbatim — it used to drop everything from the stray §.
    String.new(t.render(["PP"])).should eq("x=PP&y=§z")
  end

  it "auto-mark leaves empty values unmarked instead of injecting a literal § (§§)" do
    # Empty values across query / cookie / urlencoded body / JSON must not be wrapped.
    F::Template.auto_mark("GET /?a=&b=2 HTTP/1.1\r\n\r\n").should eq("GET /?a=&b=§2§ HTTP/1.1\r\n\r\n")
    body = "POST / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"a\":\"\",\"b\":\"x\"}"
    marked = F::Template.auto_mark(body)
    marked.includes?("§§").should be_false                # no escaped-literal collision
    F::Template.parse(marked).position_count.should eq(1) # only "b"
  end

  it "renders defaults back to the base request" do
    t = F::Template.parse("v=§x§")
    String.new(t.render(t.default_payloads)).should eq("v=x")
  end

  it "does not forge an empty position from a delimiter (a bare §§ parses as a literal §)" do
    marked = F::Template.mark_word("a && b", 3) # cursor between the two delimiters → no token
    marked.should eq("a && b")
    F::Template.parse(marked).position_count.should eq(0)
  end

  it "auto-marks query, cookie, and urlencoded body values" do
    raw = "POST /s?q=hi&p=2 HTTP/1.1\r\nHost: h\r\nCookie: sid=abc; t=1\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\na=1&b=2"
    marked = F::Template.auto_mark(raw)
    t = F::Template.parse(marked)
    t.position_count.should eq(6) # q, p, sid, t, a, b
    marked.includes?("q=§hi§").should be_true
    marked.includes?("sid=§abc§").should be_true
    marked.includes?("a=§1§").should be_true
  end

  it "does not double-mark already-marked text" do
    F::Template.auto_mark("q=§hi§").should eq("q=§hi§")
  end

  it "toggles a marker around the word at the cursor" do
    # cursor inside "admin"
    F::Template.mark_word("user=admin", 7).should eq("user=§admin§")
    # cursor inside the marked span → strip it
    F::Template.mark_word("user=§admin§", 8).should eq("user=admin")
  end

  it "marked_spans returns [start,end) char offsets incl. delimiters, 1:1 with positions" do
    t = "GET /a?x=§foo§&y=§bar§ HTTP/1.1\r\n\r\n"
    spans = F::Template.marked_spans(t)
    spans.size.should eq(F::Template.parse(t).position_count)
    a, b = spans[0]
    t[a].should eq('§')
    t[b - 1].should eq('§')
    t[(a + 1)...(b - 1)].should eq("foo")
  end

  it "marked_spans honours §§ escape and unbalanced trailing § (matches parse)" do
    F::Template.marked_spans("a§§b").should be_empty # escaped literal §
    F::Template.marked_spans("a§b").should be_empty  # unbalanced trailing §
    F::Template.marked_spans("x=§A§&y=§z").should eq([{2, 5}])
    F::Template.marked_spans("§a§b§c§").should eq([{0, 3}, {4, 7}])
    F::Template.marked_spans("k=§§§v§").should eq([{4, 7}]) # leading §§ escaped, then a pair
  end

  it "marked_spans count always equals parse.position_count" do
    ["plain", "§a§", "§§", "§a§b§c§", "k=§§§v§", "x=§A§&y=§z",
     F::Template.auto_mark("GET /?q=hi&p=2 HTTP/1.1\r\n\r\n")].each do |t|
      F::Template.marked_spans(t).size.should eq(F::Template.parse(t).position_count)
    end
  end
end

describe F::ContentLength do
  it "updates an existing Content-Length to the real body length" do
    req = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\n\r\nhello".to_slice
    synced = String.new(F::ContentLength.sync(req))
    synced.should contain("Content-Length: 5")
    synced.should end_with("\r\n\r\nhello")
  end

  it "adds Content-Length only when asked" do
    req = "POST / HTTP/1.1\r\nHost: h\r\n\r\nhello".to_slice
    String.new(F::ContentLength.sync(req)).includes?("Content-Length").should be_false
    String.new(F::ContentLength.sync(req, add_when_missing: true)).should contain("Content-Length: 5")
  end

  it "leaves chunked and body-less requests untouched" do
    chunked = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 9\r\n\r\n5\r\nhello\r\n0\r\n\r\n".to_slice
    String.new(F::ContentLength.sync(chunked)).should contain("Content-Length: 9")
    get = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    F::ContentLength.sync(get).should eq(get)
  end

  it "splices a binary body back byte-exact" do
    body = Bytes[0xff, 0x00, 0xfe, 0x80]
    head = "POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\n".to_slice
    req = Bytes.new(head.size + body.size)
    head.copy_to(req)
    body.copy_to(req[head.size, body.size])
    synced = F::ContentLength.sync(req)
    synced[(synced.size - 4), 4].should eq(body) # last 4 bytes are the exact binary body
    String.new(synced[0, synced.index!(0x0d_u8)]).should eq("POST / HTTP/1.1")
  end

  it "splits at the FIRST blank line: an LF-terminated head whose body holds a CRLFCRLF" do
    # Head ends with LF LF; the body itself contains a \r\n\r\n. The boundary must be
    # the head's LFLF (so CL counts the whole body), not the body's later CRLFCRLF.
    req = "POST / HTTP/1.0\nContent-Length: 0\n\nA\r\n\r\nB".to_slice
    synced = F::ContentLength.sync(req)
    # body is "A\r\n\r\nB" = 6 bytes; the head's LF line ending is preserved.
    String.new(synced).should eq("POST / HTTP/1.0\nContent-Length: 6\n\nA\r\n\r\nB")
  end
end

describe F::PayloadSet do
  it "iterates inline / number / null sources and applies processing" do
    F::PayloadSet.new(F::InlineList.new(["a", "b"])).size.should eq(2)
    nums = [] of String
    F::PayloadSet.new(F::NumberRange.new(1_i64, 3_i64)).each { |v| nums << v }
    nums.should eq(["1", "2", "3"])
    padded = [] of String
    F::PayloadSet.new(F::NumberRange.new(8_i64, 10_i64, base: :hex, pad: 2)).each { |v| padded << v }
    padded.should eq(["08", "09", "0a"])
    nulls = [] of String
    F::PayloadSet.new(F::NullPayloads.new(3)).each { |v| nulls << v }
    nulls.should eq(["", "", ""])
    upper = [] of String
    F::PayloadSet.new(F::InlineList.new(["ab"]), [F::Prefix.new("x-"), F::Case.new(:upper)] of F::Processor).each { |v| upper << v }
    upper.should eq(["X-AB"])
  end

  it "counts brute-force size and enumerates the odometer" do
    bf = F::BruteForce.new("12", 1, 2)
    bf.size.should eq(6) # 2 + 4
    vals = [] of String
    bf.each { |v| vals << v }
    vals.should eq(["1", "2", "11", "12", "21", "22"])
  end
end

describe F::Generator do
  base = F::Template.parse("GET /?a=§1§&b=§2§ HTTP/1.1\r\nHost: h\r\n\r\n")

  it "counts and orders each attack mode" do
    s1 = F::PayloadSet.new(F::InlineList.new(["x", "y", "z"]))
    s2 = F::PayloadSet.new(F::InlineList.new(["p", "q"]))

    sniper = F::Generator.new(base, [s1], F::Config.new(mode: F::Mode::Sniper))
    sniper.total.should eq(6) # 2 positions × 3
    ram = F::Generator.new(base, [s1], F::Config.new(mode: F::Mode::BatteringRam))
    ram.total.should eq(3)
    pitch = F::Generator.new(base, [s1, s2], F::Config.new(mode: F::Mode::Pitchfork))
    pitch.total.should eq(2) # min(3, 2)
    cluster = F::Generator.new(base, [s1, s2], F::Config.new(mode: F::Mode::ClusterBomb))
    cluster.total.should eq(6) # 3 × 2

    seen = [] of Array(String)
    cluster.each { |j| seen << j.payloads }
    seen.size.should eq(6)
    seen.first.should eq(["x", "p"])
  end

  it "saturates an overflowing total to nil" do
    huge = F::PayloadSet.new(F::NumberRange.new(0_i64, Int64::MAX, step: 1_i64))
    g = F::Generator.new(base, [huge, huge], F::Config.new(mode: F::Mode::ClusterBomb))
    g.total.should be_nil
  end

  it "clusterbomb total honours the set-0 fallback when sets < positions" do
    # 2 positions, ONE set (size 3): position 1 falls back to set 0, like each().
    s1 = F::PayloadSet.new(F::InlineList.new(["x", "y", "z"]))
    g = F::Generator.new(base, [s1], F::Config.new(mode: F::Mode::ClusterBomb))
    g.total.should eq(9) # 3 × 3 (was nil/'?' before) — total must agree with each()
    seen = 0
    g.each { seen += 1 }
    seen.should eq(9)
  end
end

describe F::Matcher do
  it "matches on status and filters on size, and extracts a group" do
    m = F::Matcher.new
    m.match_status = "200,500-599"
    job = F::Job.new(0_i64, ["x"], nil, "".to_slice)
    m.build(job, ok_result(200, "abcdef")).matched?.should be_true
    m.build(job, ok_result(404, "abcdef")).matched?.should be_false

    m.filter_size = "6"
    m.build(job, ok_result(200, "abcdef")).matched?.should be_false # filtered by size 6

    m.filter_size = nil
    m.extract = /id=(\w+)/
    res = m.build(job, ok_result(200, "<x id=hunter2 />"))
    res.extracted.should eq("hunter2")
  end
end

describe F::Engine do
  base = F::Template.parse("GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n")

  it "runs every job concurrently and reports a final tally (fake backend)" do
    set = F::PayloadSet.new(F::InlineList.new(["a", "b", "c", "d"]))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 3)
    gen = F::Generator.new(base, [set], cfg)
    backend = FakeBackend.new(F::Origin.new("http", "h", 80)) { |_b| ok_result(200, "ok") }
    engine = F::Engine.new(gen, F::Matcher.new, backend, cfg)
    results, done = drain(engine)
    results.size.should eq(4)
    results.map(&.index).sort!.should eq([0_i64, 1, 2, 3])
    backend.sent.should eq(4)
    done.as(F::DoneEvent).progress.matched.should eq(4)
    done.as(F::DoneEvent).stopped.should be_false
  end

  it "retries on a network error up to the configured count" do
    attempts = 0
    set = F::PayloadSet.new(F::InlineList.new(["only"]))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, retries: 2)
    gen = F::Generator.new(base, [set], cfg)
    backend = FakeBackend.new(F::Origin.new("http", "h", 80)) do |_b|
      attempts += 1
      attempts < 3 ? Gori::Replay::Result.new(Bytes.new(0), nil, nil, 0_i64, "boom") : ok_result(200, "ok")
    end
    engine = F::Engine.new(gen, F::Matcher.new, backend, cfg)
    results, _ = drain(engine)
    attempts.should eq(3) # 1 + 2 retries
    results.first.status.should eq(200)
  end

  it "treats a non-positive max_requests as no cap (doesn't halt at request 0)" do
    set = F::PayloadSet.new(F::InlineList.new(["a", "b", "c"]))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 2, max_requests: 0_i64)
    gen = F::Generator.new(base, [set], cfg)
    backend = FakeBackend.new(F::Origin.new("http", "h", 80)) { |_b| ok_result(200, "x") }
    results, _ = drain(F::Engine.new(gen, F::Matcher.new, backend, cfg))
    results.size.should eq(3) # all sent — a 0 cap must not break at @dispatched >= 0
  end

  it "sends byte-exact requests to a real origin and records metrics" do
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    seen = Channel(String).new(8)
    spawn do
      while conn = origin.accept?
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        seen.send(head ? String.new(head) : "")
        body = "pong"
        conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        conn.flush
        conn.close
      end
    end

    tmpl = F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    set = F::PayloadSet.new(F::InlineList.new(["one", "two"]))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 2)
    gen = F::Generator.new(tmpl, [set], cfg)
    backend = F::Sender.new(F::Origin.new("http", "127.0.0.1", port), http2: false, verify: false)
    engine = F::Engine.new(gen, F::Matcher.new, backend, cfg)
    results, _ = drain(engine)

    results.size.should eq(2)
    results.all? { |r| r.status == 200 && r.length == 4 }.should be_true
    got = [seen.receive, seen.receive].sort
    got.should contain("GET /?q=one HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    got.should contain("GET /?q=two HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    origin.close
  end
end

describe Gori::CLI::Output do
  it "formats a fuzz result as JSON and text" do
    r = F::Result.new(3_i64, ["admin"], 0, 403, 21_i64, 3, 1, 1500_i64, nil, true, false, "tok")
    json = JSON.parse(Gori::CLI::Output.fuzz_row_json(r))
    json["index"].should eq(3)
    json["status"].should eq(403)
    json["payloads"].should eq(["admin"])
    json["extracted"].should eq("tok")
    json["matched"].should eq(true)

    txt = Gori::CLI::Output.fuzz_row_text(r)
    txt.should contain("#3")
    txt.should contain("admin")
    txt.should contain("403")
  end
end
