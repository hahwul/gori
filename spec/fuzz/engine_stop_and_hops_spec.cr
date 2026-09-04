require "../spec_helper"

private alias F = Gori::Fuzz

# A backend that fails every send with a network-shaped error — the retry loop's input.
private class FailingBackend < F::Backend
  getter sent = 0

  def initialize(@origin : F::Origin)
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
  end
end

# Answers the n-th send with a 302 to `locs[n]` while there is one, then 200. `h2` is what
# `Backend#http2?` reports, so a spec can see what the engine writes on an h2 hop.
private class HopBackend < F::Backend
  getter sent = [] of String
  # Runs after each reply is built — a spec stops the engine from inside a send with it.
  property on_send : Proc(Int32, Nil)? = nil

  def initialize(@origin : F::Origin, @locs : Array(String?), @h2 : Bool = false)
  end

  def origin : F::Origin
    @origin
  end

  def http2? : Bool
    @h2
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent << String.new(bytes)
    loc = @locs[@sent.size - 1]?
    head = if loc
             "HTTP/1.1 302 Found\r\nLocation: #{loc}\r\nContent-Length: 0\r\n\r\n"
           else
             "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
           end.to_slice
    @on_send.try(&.call(@sent.size))
    Gori::Repeater::Result.new(head, Bytes.new(0), Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
  end
end

private def one_payload(tpl : String, cfg : F::Config) : F::Generator
  F::Generator.new(F::Template.parse(tpl), [F::PayloadSet.new(F::InlineList.new(["1"]))], cfg)
end

private def follow(origin : F::Origin, locs : Array(String?) | Array(String), h2 : Bool = false,
                   tpl : String = "GET /dir/start?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n") : Array(String)
  cfg = F::Config.new(concurrency: 1, follow_redirects: true, max_redirects: 5)
  be = HopBackend.new(origin, locs.map(&.as(String?)), h2)
  F::Engine.new(one_payload(tpl, cfg), F::Matcher.new, be, cfg).run { }
  be.sent
end

private def request_lines(sent : Array(String)) : Array(String)
  sent.map { |r| r.lines.first }
end

describe "Fuzz::Engine — a stop stops" do
  it "does not re-send a failed payload after stop, even with --retries pending" do
    cfg = F::Config.new(concurrency: 1, retries: 5, retry_pause: 60.milliseconds)
    be = FailingBackend.new(F::Origin.new("http", "h", 80))
    engine = F::Engine.new(one_payload("GET /?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n", cfg), F::Matcher.new, be, cfg)
    results = [] of F::Result
    done = Channel(Nil).new(1)
    spawn do
      engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }
      done.send(nil)
    end
    sleep 20.milliseconds # inside the first retry pause
    engine.stop
    done.receive
    be.sent.should eq(1) # the attempt that was in flight; none of the five retries
    results.size.should eq(1)
    results[0].error.should eq("connection refused")
    results[0].resent_count.should eq(0) # no re-send happened, so none is claimed
  end

  it "does not follow a redirect hop after stop — the 3xx in hand is the row" do
    cfg = F::Config.new(concurrency: 1, follow_redirects: true, max_redirects: 5)
    be = HopBackend.new(F::Origin.new("http", "h", 80), ["/a", "/b", "/c"] of String?)
    engine = F::Engine.new(one_payload("GET /start?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n", cfg), F::Matcher.new, be, cfg)
    # The stop lands while the payload's own send is in flight (its 302 is being answered).
    be.on_send = ->(n : Int32) { engine.stop if n == 1 }
    results = [] of F::Result
    engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }
    be.sent.size.should eq(1) # the payload; not one hop of the three on offer
    results.size.should eq(1)
    results[0].status.should eq(302)
    results[0].error.should be_nil # nothing failed — the chain was not started
  end
end

describe "Fuzz::Engine#follow_redirects — resolving the Location" do
  it "follows a RELATIVE reference against the request that was answered" do
    sent = follow(F::Origin.new("http", "h", 80), ["next?x=1", "?y=2", "../up", "sub/leaf", nil])
    request_lines(sent).should eq([
      "GET /dir/start?q=1 HTTP/1.1",
      "GET /dir/next?x=1 HTTP/1.1", # relative to /dir/
      "GET /dir/next?y=2 HTTP/1.1", # query-only: same path, new query
      "GET /up HTTP/1.1",           # dot-segment climbs out of /dir/
      "GET /sub/leaf HTTP/1.1",     # …and the next hop resolves against /up
    ])
  end

  it "treats scheme and host case-insensitively on an absolute-form Location" do
    sent = follow(F::Origin.new("http", "h", 80), ["HTTP://H/abs", nil])
    request_lines(sent).should eq(["GET /dir/start?q=1 HTTP/1.1", "GET /abs HTTP/1.1"])
  end

  it "still refuses a cross-origin, cross-scheme, or unsafe Location" do
    follow(F::Origin.new("http", "h", 80), ["http://other/x"]).size.should eq(1)
    follow(F::Origin.new("http", "h", 80), ["https://h/x"]).size.should eq(1)
    follow(F::Origin.new("http", "h", 80), ["//other/x"]).size.should eq(1)
    follow(F::Origin.new("http", "h", 80), ["/a b"]).size.should eq(1)
    follow(F::Origin.new("http", "h", 80), ["a b"]).size.should eq(1)
  end

  it "brackets an IPv6 literal in the hop's Host header" do
    sent = follow(F::Origin.new("http", "::1", 8080), ["/x", nil])
    sent[1].should contain("Host: [::1]:8080\r\n")
    sent = follow(F::Origin.new("https", "::1", 443), ["/x", nil])
    sent[1].should contain("Host: [::1]\r\n") # default port omitted
  end

  it "writes no Connection: close on an h2 hop (a connection-specific field h2 forbids)" do
    h1 = follow(F::Origin.new("https", "h", 443), ["/x", nil], h2: false)
    h1[1].should contain("Connection: close\r\n")
    h2 = follow(F::Origin.new("https", "h", 443), ["/x", nil], h2: true)
    h2[1].should_not contain("Connection")
    h2[1].should eq("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
  end
end

# A hop that FAILED: the row keeps the payload's own 3xx and notes the hop on `error`.
private class RefusedHopBackend < F::Backend
  def initialize(@origin : F::Origin)
    @n = 0
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @n += 1
    if @n == 1
      head = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 2\r\n\r\n".to_slice
      Gori::Repeater::Result.new(head, "ok".to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
    else
      Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
    end
  end
end

describe "Fuzz::Matcher — a row whose redirect hop was refused" do
  it "is still matched on the payload's own response" do
    cfg = F::Config.new(concurrency: 1, follow_redirects: true)
    matcher = F::Matcher.new
    matcher.match_status = "302"
    be = RefusedHopBackend.new(F::Origin.new("http", "h", 80))
    results = [] of F::Result
    F::Engine.new(one_payload("GET /start?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n", cfg), matcher, be, cfg).run do |ev|
      results << ev.result if ev.is_a?(F::ResultEvent)
    end
    results.size.should eq(1)
    r = results[0]
    r.status.should eq(302)
    r.error.not_nil!.should start_with(F::REDIRECT_HOP_REFUSED)
    r.matched?.should be_true # the 302 IS the open-redirect finding
  end

  it "is still not matched when the row itself is a failed send" do
    m = F::Matcher.new
    m.match_status = "302"
    dead = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "#{F::REDIRECT_HOP_REFUSED}x")
    job = F::Job.new(0_i64, ["1"], nil, Bytes.new(0))
    m.build(job, dead).matched?.should be_false # no response to match on
  end
end

# `baseline_request` raising is the one way `run_race` can fail before its first dial.
private class ExplodingGenerator < F::Generator
  def baseline_request : Bytes
    raise Gori::Error.new("chain exploded")
  end
end

describe "Fuzz::Engine#run_race — a raise before the release" do
  it "reports an ErrorEvent, then Done, instead of a silent empty run" do
    cfg = F::Config.new(concurrency: 1, race_count: 2)
    tpl = F::Template.parse("GET /race HTTP/1.1\r\nHost: h\r\n\r\n")
    gen = ExplodingGenerator.new(tpl, [] of F::PayloadSet, cfg)
    be = FailingBackend.new(F::Origin.new("http", "h", 80))
    events = [] of F::Event
    F::Engine.new(gen, F::Matcher.new, be, cfg).run { |ev| events << ev }
    errors = events.select(F::ErrorEvent)
    errors.size.should eq(1)
    errors[0].message.should eq("chain exploded")
    events.last.should be_a(F::DoneEvent)
    be.sent.should eq(0)
  end
end
