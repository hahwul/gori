require "../spec_helper"

private alias O = Gori::Oast

# A provider whose poll answers or raises on demand — the two states an out-of-band listener
# must never conflate, and the two `Poller#answering?` exists to keep apart.
private class ScriptedProvider < O::Provider
  property? fail_next : Bool = false

  def initialize
    super(O::ProviderKind::CustomHttp, "https://oast.test")
  end

  def register(http : O::Http) : O::Session
    O::Session.new(1_i64, kind, host, "corr", "")
  end

  def generate_payload(session : O::Session) : String
    "https://oast.test?oid=abc"
  end

  def poll(http : O::Http, session : O::Session) : Array(O::Interaction)
    raise Gori::Error.new("custom-http poll: HTTP 401 unauthorized") if fail_next?
    [] of O::Interaction
  end
end

private class NoHttp < O::Http
  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : O::Http::Response
    O::Http::Response.new(204, "")
  end
end

private def session : O::Session
  O::Session.new(1_i64, O::ProviderKind::CustomHttp, "https://oast.test", "corr", "")
end

# One poll cycle: `run` polls immediately, then parks on the interval.
private def tick(poller : O::Poller) : Nil
  4.times { Fiber.yield }
end

describe Gori::Oast::Poller do
  it "starts answering — the register round trip just succeeded" do
    events = Channel(O::Event).new(8)
    O::Poller.new(ScriptedProvider.new, session, NoHttp.new, 1.hour, events).answering?.should be_true
  end

  it "stops answering once a poll is refused, and says so on the event stream" do
    events = Channel(O::Event).new(8)
    prov = ScriptedProvider.new
    prov.fail_next = true
    poller = O::Poller.new(prov, session, NoHttp.new, 1.hour, events)
    poller.start
    tick(poller)
    poller.answering?.should be_false
    ev = events.receive
    ev.should be_a(O::OastErrorEvent)
    poller.stop
  end

  # An EMPTY batch is an answer. The whole point of the flag is that "nothing came back" and
  # "the server refused us" are different facts.
  it "answers again once the provider recovers" do
    events = Channel(O::Event).new(8)
    prov = ScriptedProvider.new
    prov.fail_next = true
    poller = O::Poller.new(prov, session, NoHttp.new, 1.millisecond, events)
    poller.start
    tick(poller)
    poller.answering?.should be_false
    events.receive # drain the error
    prov.fail_next = false
    20.times do
      break if poller.answering?
      sleep 1.millisecond
    end
    poller.answering?.should be_true
    poller.stop
  end
end
