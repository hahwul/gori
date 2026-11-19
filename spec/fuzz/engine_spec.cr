require "../spec_helper"

private alias F = Gori::Fuzz

# Answers 200 after `delay`, so the drain has nothing queued while a send is in flight.
private class SlowBackend < F::Backend
  def initialize(@origin : F::Origin, @delay : Time::Span)
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    sleep @delay
    head = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".to_slice
    Gori::Repeater::Result.new(head, Bytes.new(0), Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
  end
end

# The CLI flushed a buffered row only when the next event arrived; `idle` runs when the drain
# is about to block, and again after the wait it answers.
describe "Fuzz::Engine#run idle" do
  it "runs idle while no event is queued, again after its wait, and still drains every event" do
    cfg = F::Config.new(concurrency: 1)
    gen = F::Generator.new(F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n"),
      [F::PayloadSet.new(F::InlineList.new(["1", "2"]))], cfg)
    engine = F::Engine.new(gen, F::Matcher.new, SlowBackend.new(F::Origin.new("http", "h", 80), 60.milliseconds), cfg)
    idles = 0
    results = 0
    engine.run(-> { idles += 1; 5.milliseconds.as(Time::Span?) }) do |ev|
      results += 1 if ev.is_a?(F::ResultEvent)
    end
    results.should eq(2)
    idles.should be > 4 # several 5 ms waits inside each 60 ms send
  end
end
