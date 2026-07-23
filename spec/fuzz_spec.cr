require "./spec_helper"
require "socket"

private alias F = Gori::Fuzz

# A Backend that returns a canned response per request, with no socket.
private class FakeBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, &@fn : Bytes -> Gori::Repeater::Result)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    @fn.call(bytes)
  end
end

private def ok_result(status : Int32, body : String) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
  resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
  Gori::Repeater::Result.new(head, body.to_slice, resp, 1234_i64)
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

  it "auto-marks JSON boolean and null values, not only strings/numbers" do
    body = "POST / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"name\":\"bob\",\"admin\":true,\"age\":30,\"gone\":null}"
    marked = F::Template.auto_mark(body)
    marked.includes?("\"admin\":§true§").should be_true
    marked.includes?("\"gone\":§null§").should be_true
    F::Template.parse(marked).position_count.should eq(4) # name, admin, age, gone
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

  # --- inline Decoder chains (§value¦chain§) ---
  it "splits a marker's interior on the first unescaped ¦ into {default, chain}" do
    t = F::Template.parse("tok=§secret¦base64-encode > url-encode§")
    t.position_count.should eq(1)
    t.positions.first.default.should eq("secret")
    t.positions.first.chain.should eq("base64-encode > url-encode") # chain may contain '>' / '|' / ','
  end

  it "treats a chain-less marker as chain == \"\" (backward compatible)" do
    F::Template.parse("v=§x§").positions.first.chain.should eq("")
  end

  it "escapes ¦¦ to a literal ¦ inside the value or chain" do
    t = F::Template.parse("§a¦¦b¦rot13§") # value 'a¦b', chain 'rot13'
    t.positions.first.default.should eq("a¦b")
    t.positions.first.chain.should eq("rot13")
  end

  it "renders defaults through their chains via apply_chains (failure → untransformed)" do
    reg = Gori::Decoder.default_registry
    t = F::Template.parse("a=§hi¦base64-encode§&b=§keep¦nope-unknown§&c=§plain§")
    out = String.new(t.render(t.apply_chains(t.default_payloads, reg)))
    out.should eq("a=aGk=&b=keep&c=plain") # base64(hi)=aGk=; unknown chain passes through; no chain untouched
  end

  it "marked_spans still counts chained markers 1:1 with positions" do
    t = "a=§1¦base64-encode§&b=§2§"
    F::Template.marked_spans(t).size.should eq(F::Template.parse(t).position_count)
  end

  it "value_at / marker_start_at read the marker under the cursor (nil outside)" do
    t = "x=§hi¦base64-encode§ y"                    # open § at 2, ¦ at 5, close § at 19
    F::Template.value_at(t, 4).should eq("hi")      # cursor in the value
    F::Template.value_at(t, 10).should eq("hi")     # cursor in the (concealed) chain
    F::Template.marker_start_at(t, 10).should eq(2) # stable open-§ anchor for the ^Y commit
    F::Template.marker_start_at(t, 19).should eq(2) # even from the closing §
    F::Template.value_at(t, 0).should be_nil        # outside any marker
    F::Template.marker_start_at(t, 0).should be_nil
  end

  it "clear_markers drops the marker AND its chain" do
    F::Template.clear_markers("tok=§secret¦base64-encode§&x=1").should eq("tok=secret&x=1")
  end

  it "mark_word unmark strips a stray ¦chain, not just the § delimiters" do
    # cursor inside the marker → unmark leaves the raw value only (no dangling ¦base64-encode)
    F::Template.mark_word("tok=§secret¦base64-encode§", 8).should eq("tok=secret")
  end

  it "chain_at / set_chain read and write the marker under the cursor" do
    text = "a=§1§&b=§2¦rot13§"
    F::Template.chain_at(text, 3).should eq("")       # cursor in the first (chain-less) marker
    F::Template.chain_at(text, 10).should eq("rot13") # cursor in the second marker
    F::Template.chain_at("plain", 2).should be_nil    # not in a marker
    # attach a chain to the first marker
    F::Template.set_chain(text, 3, "base64-encode").should eq("a=§1¦base64-encode§&b=§2¦rot13§")
    # clearing (empty) removes the ¦chain
    F::Template.set_chain(text, 10, "").should eq("a=§1§&b=§2§")
  end

  it "marker_regions exposes the value|chain split for tinting" do
    # "a=§1¦rot13§" → open at 2, ¦ at 4, close at 10
    F::Template.marker_regions("a=§1¦rot13§").should eq([{2, 4, 10}])
    # chain-less marker: sep == close
    F::Template.marker_regions("a=§1§").should eq([{2, 4, 4}])
  end

  it "structural_marker_at flags the delimiters/separator of a closed marker" do
    text = "a=§1¦rot13§&b=§2§" # marker1 [2,11): §@2 ¦@4 §@10 ; marker2 [14,17): §@14 2@15 §@16
    span1 = {2, 11}
    span2 = {14, 17}
    # opening §, the ¦ separator, and the closing § are all structural
    F::Template.structural_marker_at(text, 2).should eq(span1)  # opening §
    F::Template.structural_marker_at(text, 4).should eq(span1)  # ¦ separator
    F::Template.structural_marker_at(text, 10).should eq(span1) # closing §
    F::Template.structural_marker_at(text, 16).should eq(span2) # chain-less closing §
    F::Template.structural_marker_at(text, 15).should be_nil    # the "2" value byte
    # a value byte, a byte in the concealed chain, and text outside a marker are NOT structural
    F::Template.structural_marker_at(text, 3).should be_nil  # the "1" value
    F::Template.structural_marker_at(text, 5).should be_nil  # inside "rot13"
    F::Template.structural_marker_at(text, 0).should be_nil  # "a"
    F::Template.structural_marker_at(text, -1).should be_nil # buffer start (backspace guard)
    # a §/¦ OUTSIDE every closed marker (escaped literal / unbalanced) folds to text
    F::Template.structural_marker_at("a§§b", 1).should be_nil
    F::Template.structural_marker_at("a§b", 1).should be_nil
  end

  it "insert_breaks_marker? escapes a §/¦ inside or flush against a marker, not in open text" do
    text = "a=§1§&b"                                                # marker [2,5): §@2 1@3 §@4
    F::Template.insert_breaks_marker?(text, 3, '§').should be_true  # strictly inside → escape
    F::Template.insert_breaks_marker?(text, 3, '¦').should be_true  # separator inside → escape
    F::Template.insert_breaks_marker?(text, 2, '§').should be_true  # flush against the opener (forms §§)
    F::Template.insert_breaks_marker?(text, 5, '§').should be_true  # flush past the closer (forms §§)
    F::Template.insert_breaks_marker?(text, 3, 'x').should be_false # a normal char is never escaped
    F::Template.insert_breaks_marker?(text, 6, '§').should be_false # open text → let a fresh §…§ be typed
    F::Template.insert_breaks_marker?("plain", 2, '§').should be_false
  end

  it "strip_marker drops the whole marker (both § and the ¦chain), leaving the raw value" do
    # chained marker: value survives, ¦chain + both § are gone; caret lands past the value
    F::Template.strip_marker("a=§secret¦base64-encode§&b", {2, 24}).should eq({"a=secret&b", 8})
    # chain-less marker
    F::Template.strip_marker("a=§1§&b", {2, 5}).should eq({"a=1&b", 3})
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

  it "detects chunked across a bare LF inside a CRLF head (smuggling/desync framing)" do
    # A CRLF-boundary head where the Transfer-Encoding line is terminated by a BARE LF (not
    # CRLF). chunked? tokenizes on LF like an LF-lenient backend does, so it must still see
    # "Transfer-Encoding: chunked" as its own line and leave the request byte-exact — NOT split
    # only on the CRLF boundary (which would merge the TE value, miss chunked, and rewrite the
    # Content-Length 3 → 6). Regression guard for the head "tokenize once" pitfall.
    req = "POST / HTTP/1.1\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\nX\r\n\r\nBODY!!".to_slice
    F::ContentLength.sync(req).should eq(req)
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

  it "stops at an Int64::MAX boundary without overflowing the run" do
    vals = [] of String
    # to == Int64::MAX: the terminal `@cur + @step` used to overflow → OverflowError aborts.
    F::PayloadSet.new(F::NumberRange.new(Int64::MAX - 2, Int64::MAX, step: 1_i64)).each { |v| vals << v }
    vals.should eq([(Int64::MAX - 2).to_s, (Int64::MAX - 1).to_s, Int64::MAX.to_s])
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

  it "applies a position's inline Decoder chain to the payload on the wire" do
    reg = Gori::Decoder.default_registry
    chained = F::Template.parse("GET /?a=§1¦base64-encode§&b=§2§ HTTP/1.1\r\nHost: h\r\n\r\n")
    s1 = F::PayloadSet.new(F::InlineList.new(["hi"]))
    g = F::Generator.new(chained, [s1], F::Config.new(mode: F::Mode::BatteringRam), registry: reg)
    bytes = [] of String
    g.each { |j| bytes << String.new(j.bytes) }
    # position a carries base64(hi)=aGk=; position b (no chain) gets the raw payload.
    bytes.first.should eq("GET /?a=aGk=&b=hi HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "leaves payloads untransformed when no registry is supplied (3-arg constructor)" do
    chained = F::Template.parse("GET /?a=§1¦base64-encode§ HTTP/1.1\r\nHost: h\r\n\r\n")
    s1 = F::PayloadSet.new(F::InlineList.new(["hi"]))
    g = F::Generator.new(chained, [s1], F::Config.new(mode: F::Mode::BatteringRam))
    bytes = [] of String
    g.each { |j| bytes << String.new(j.bytes) }
    bytes.first.should eq("GET /?a=hi HTTP/1.1\r\nHost: h\r\n\r\n")
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

  it "treats a blank match spec as unconstrained (CLI --ms= etc.), not 'reject everything'" do
    m = F::Matcher.new
    job = F::Job.new(0_i64, ["x"], nil, "".to_slice)
    # The CLI/MCP set the property to "" (not nil). A blank spec must mean 'no
    # constraint' — the old code ran it through Predicate (no terms → false) and
    # dropped every result.
    m.match_size = ""
    m.match_status = ""
    m.match_words = ""
    m.build(job, ok_result(200, "abcdef")).matched?.should be_true
  end

  it "matches --mh as a case-insensitive substring over the response head (no head String)" do
    m = F::Matcher.new
    job = F::Job.new(0_i64, ["x"], nil, "".to_slice)
    head = "HTTP/1.1 200 OK\r\nServer: nginx/1.25\r\nX-Powered-By: PHP/8.2\r\nContent-Length: 2\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    res = Gori::Repeater::Result.new(head, "ok".to_slice, resp, 1_i64)
    # Needle case need not match the head's case (old path downcased both).
    m.match_header = "SERVER: NGINX"
    m.build(job, res).matched?.should be_true
    m.match_header = "x-powered-by: php"
    m.build(job, res).matched?.should be_true
    m.match_header = "x-frame-options"
    m.build(job, res).matched?.should be_false # header absent
    # A blank/nil needle is unconstrained (matcher passes), not "reject everything".
    m.match_header = nil
    m.build(job, res).matched?.should be_true
  end

  it "survives a catastrophic-backtracking user regex instead of killing the worker" do
    # A user --mr/--fr/--extract regex like /(a+)+$/ raises Regex::Error ('match limit
    # exceeded') on a pathological body rather than returning false; unrescued it killed the
    # fuzz worker fiber. build() must yield a Result (no match / no capture), not raise.
    job = F::Job.new(0_i64, ["x"], nil, "".to_slice)
    evil = "a" * 60 + "!"
    m = F::Matcher.new
    m.match_regex = /(a+)+$/
    m.build(job, ok_result(200, evil)).matched?.should be_false
    f = F::Matcher.new
    f.filter_regex = /(a+)+$/
    f.build(job, ok_result(200, evil)).matched?.should be_true # filter never fires → kept
    e = F::Matcher.new
    e.extract = /(a+)+$/
    e.build(job, ok_result(200, evil)).extracted.should be_nil
  end

  it "auto-calibration (multi-sample) suppresses EVERY sampled baseline shape, not just one, " \
     "and never suppresses a status-flip anomaly (the original single-snapshot bug: only " \
     "whichever ONE shape the lone baseline call happened to catch got dropped)" do
    m = F::Matcher.new(auto_calibrate: true)
    job = F::Job.new(0_i64, ["x"], nil, "".to_slice)
    # As if Engine#calibrate_baseline sampled a target that rotates between two distinct
    # 200-status shapes ("a"*100 and "a"*250 have no whitespace → 1 word, 0 lines each).
    m.baseline = [
      F::BaselineSample.new(F::Metrics.new(200, 100_i64, 1, 0, 0_i64), 6),
      F::BaselineSample.new(F::Metrics.new(200, 250_i64, 1, 0, 0_i64), 11),
    ]
    m.build(job, ok_result(200, "a" * 100)).matched?.should be_false # shape 1 — calibrated out
    m.build(job, ok_result(200, "a" * 250)).matched?.should be_false # shape 2 — ALSO calibrated out
    m.build(job, ok_result(200, "a" * 400)).matched?.should be_true  # neither sampled shape — reported
    # Same size/words as a sampled shape, but status flips — never calibrated out.
    m.build(job, ok_result(500, "a" * 100)).matched?.should be_true
  end

  it "Matcher.reflects_length? detects response length tracking payload length across the " \
     "staggered calibration samples, and does not false-positive on merely-noisy (rotating, " \
     "non-tracking) samples" do
    reflecting = [
      F::BaselineSample.new(F::Metrics.new(200, 120_i64, 5, 1, 0_i64), 6),
      F::BaselineSample.new(F::Metrics.new(200, 125_i64, 5, 1, 0_i64), 11),
      F::BaselineSample.new(F::Metrics.new(200, 130_i64, 5, 1, 0_i64), 16),
    ]
    F::Matcher.reflects_length?(reflecting).should be_true

    rotating = [
      F::BaselineSample.new(F::Metrics.new(200, 100_i64, 20, 1, 0_i64), 6),
      F::BaselineSample.new(F::Metrics.new(200, 250_i64, 45, 1, 0_i64), 11),
      F::BaselineSample.new(F::Metrics.new(200, 150_i64, 30, 1, 0_i64), 16),
    ]
    F::Matcher.reflects_length?(rotating).should be_false
  end

  it "auto-calibration falls back to word/line counts when response length reflects payload " \
     "length (a target that echoes the fuzzed value back — the harder, continuously-varying " \
     "proven-broken scenario, where no finite exact-length baseline SET could ever suffice)" do
    m = F::Matcher.new(auto_calibrate: true)
    m.baseline = [
      F::BaselineSample.new(F::Metrics.new(200, 108_i64, 1, 0, 0_i64), 6),
      F::BaselineSample.new(F::Metrics.new(200, 118_i64, 1, 0, 0_i64), 16),
    ]
    m.reflects_length?.should be_true
    job = F::Job.new(0_i64, ["x"], nil, "".to_slice)
    # A payload length NEVER sampled (30) whose reflected body is a new exact byte length —
    # an exact-length-against-a-set match would never fire here; the word/line fallback still
    # recognizes the same (1 word, 0 lines) noise shape.
    m.build(job, ok_result(200, "R:" + "a" * 30)).matched?.should be_false
    # A genuine anomaly (extra words/lines) still flags despite sharing the baseline's status.
    m.build(job, ok_result(200, "totally different shape\nwith another line")).matched?.should be_true
    m.build(job, ok_result(500, "R:" + "a" * 30)).matched?.should be_true
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

  it "auto-calibration end-to-end: calibrate_baseline's synthetic sends capture EVERY shape " \
     "of a rotating-noise target, so the whole sweep is suppressed except a seeded status " \
     "anomaly planted mid-sweep (reproduces the reported bug: a single-snapshot baseline let " \
     "75/100 rotating-noise responses through; multi-sample calibration must let through only " \
     "the genuine anomaly)" do
    shapes = [100, 150, 200, 250] # 4 fixed "normal" body shapes, keyed off a global counter
    n = 0
    backend = FakeBackend.new(F::Origin.new("http", "h", 80)) do |bytes|
      if String.new(bytes).includes?("ANOMALY")
        ok_result(500, "Z" * 4000) # the genuine, never-to-be-suppressed anomaly
      else
        n += 1
        ok_result(200, "x" * shapes[n % shapes.size])
      end
    end
    payloads = (1..16).map { |i| "noise#{i}" }
    payloads.insert(8, "ANOMALY") # planted mid-sweep (17 payloads total)
    set = F::PayloadSet.new(F::InlineList.new(payloads))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, auto_calibrate: true)
    gen = F::Generator.new(base, [set], cfg)
    matcher = F::Matcher.new(auto_calibrate: true)
    engine = F::Engine.new(gen, matcher, backend, cfg)
    engine.calibrate_baseline # CALIBRATION_SAMPLES (6) synthetic sends — ≥ the rotation's
    # period of 4, so every shape gets captured regardless of which phase calibration starts on.
    results, _ = drain(engine)

    results.size.should eq(17)
    matched = results.select(&.matched?)
    matched.size.should eq(1) # only the anomaly — 0 false positives among the 16 noise rows
    matched.first.status.should eq(500)
  end

  it "retries on a network error up to the configured count" do
    attempts = 0
    set = F::PayloadSet.new(F::InlineList.new(["only"]))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, retries: 2)
    gen = F::Generator.new(base, [set], cfg)
    backend = FakeBackend.new(F::Origin.new("http", "h", 80)) do |_b|
      attempts += 1
      attempts < 3 ? Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "boom") : ok_result(200, "ok")
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

  it "enforces max_requests as a hard cap on real sends (retries count)" do
    # Each payload fails once then succeeds → 2 real sends per job without a hard cap.
    # With max_requests=3, CappedBackend must refuse the 4th send even though only ~2 jobs
    # were dispatched (the old dispatch-only check would have allowed 3 full jobs = 6 sends).
    attempts = 0
    set = F::PayloadSet.new(F::InlineList.new(["a", "b", "c", "d"]))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, retries: 1, max_requests: 3_i64)
    gen = F::Generator.new(base, [set], cfg)
    backend = FakeBackend.new(F::Origin.new("http", "h", 80)) do |_b|
      attempts += 1
      # Odd attempts fail so each successful job burns 2 real sends.
      attempts.odd? ? Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "boom") : ok_result(200, "ok")
    end
    drain(F::Engine.new(gen, F::Matcher.new, backend, cfg))
    backend.sent.should be <= 3
  end

  it "does not overshoot max_requests under concurrency" do
    set = F::PayloadSet.new(F::InlineList.new((1..40).map(&.to_s)))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 8, max_requests: 12_i64)
    gen = F::Generator.new(base, [set], cfg)
    backend = FakeBackend.new(F::Origin.new("http", "h", 80)) { |_b| ok_result(200, "ok") }
    drain(F::Engine.new(gen, F::Matcher.new, backend, cfg))
    backend.sent.should be <= 12
  end

  it "stops after the in-flight batch, not the buffered jobs" do
    gate = Channel(Nil).new        # unbuffered: each send blocks until released
    started = Channel(Nil).new(64) # buffered so a send-entry signal never blocks a worker
    set = F::PayloadSet.new(F::InlineList.new((1..20).map(&.to_s)))
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 2)
    gen = F::Generator.new(base, [set], cfg)
    backend = FakeBackend.new(F::Origin.new("http", "h", 80)) do |_b|
      started.send(nil)
      gate.receive
      ok_result(200, "ok")
    end
    engine = F::Engine.new(gen, F::Matcher.new, backend, cfg)

    done = Channel(Nil).new
    spawn { engine.run { |_ev| }; done.send(nil) }

    2.times { started.receive } # both workers are inside send() (in-flight)
    10.times { Fiber.yield }    # let the dispatcher fill the buffered @jobs channel
    engine.stop
    spawn { loop { gate.send(nil) } } # release: in-flight finish, buffered must be skipped
    done.receive

    # concurrency (2) buffered on top of concurrency (2) in-flight = 4 previously fired
    # after stop; now only the in-flight batch does.
    backend.sent.should eq(2)
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

describe F::ScopedBackend do
  # A mid-run EXCLUDE written to the store must take effect via the throttled reload,
  # not stay a start-time snapshot (R2-9). reload_every: 0 → re-read on every send, so
  # the change is observed deterministically without a wall-clock wait.
  it "honours a mid-run EXCLUDE via a throttled reload" do
    path = File.tempname("gori-fuzz-scope", ".db")
    store = Gori::Store.open(path)
    begin
      scope = Gori::Scope.load(store)
      calls = 0
      inner = FakeBackend.new(F::Origin.new("http", "target.test", 80)) do |_b|
        calls += 1
        ok_result(200, "ok")
      end
      backend = F::ScopedBackend.new(inner, scope, reload_every: Time::Span.zero)
      req = "GET / HTTP/1.1\r\nHost: target.test\r\n\r\n".to_slice

      # No rules yet → allowed, reaches the inner backend.
      backend.send(req).error.should be_nil
      calls.should eq(1)
      backend.blocked.should eq(0_i64)

      # Operator carves the host out mid-run (writes to the SAME db).
      store.add_scope_rule("exclude", "host", "target.test")

      # Next send reloads and now blocks WITHOUT touching the inner backend.
      backend.send(req).error.should eq(F::ScopedBackend::SCOPE_ERROR)
      calls.should eq(1)
      backend.blocked.should eq(1_i64)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "keeps a start-time snapshot when no reload interval is given" do
    path = File.tempname("gori-fuzz-scope-snap", ".db")
    store = Gori::Store.open(path)
    begin
      scope = Gori::Scope.load(store)
      calls = 0
      inner = FakeBackend.new(F::Origin.new("http", "target.test", 80)) do |_b|
        calls += 1
        ok_result(200, "ok")
      end
      backend = F::ScopedBackend.new(inner, scope) # reload_every defaults to nil
      req = "GET / HTTP/1.1\r\nHost: target.test\r\n\r\n".to_slice

      backend.send(req).error.should be_nil
      store.add_scope_rule("exclude", "host", "target.test")
      backend.send(req).error.should be_nil # snapshot: exclude not seen
      calls.should eq(2)
      backend.blocked.should eq(0_i64)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
