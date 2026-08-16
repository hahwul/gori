require "../spec_helper"
require "../../src/gori/authorize/passive"

private alias Passive = Gori::Authorize::Passive

private def detail(method = "GET", target = "/orders", headers = "Cookie: session=A\r\n",
                   state = Gori::Store::FlowState::Complete,
                   short_circuited = false) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 0_i64, "https", method, "h.test", 443, target,
    200, 100_i64, state, 50_i64, 1_i64, "text/html", short_circuited)
  head = "#{method} #{target} HTTP/1.1\r\nHost: h.test\r\n#{headers}\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
end

describe Gori::Authorize::Passive do
  describe ".replayable?" do
    it "takes a GET that carries a session" do
      Passive.replayable?(detail).should be_true
      Passive.replayable?(detail(headers: "Authorization: Bearer t\r\n")).should be_true
    end

    # A request with no session IS the anonymous case: replaying it under an anonymous
    # identity compares a thing to itself and can only ever read `same`.
    it "skips a request that carries no session at all" do
      Passive.replayable?(detail(headers: "")).should be_false
      Passive.replayable?(detail(headers: "Accept: */*\r\n")).should be_false
    end

    # Unattended replay of a state-changing request runs its side effect again, once per
    # identity, with nobody there to decide that is acceptable.
    it "skips methods that are not safe to repeat unattended" do
      %w[POST PUT PATCH DELETE].each do |m|
        Passive.replayable?(detail(method: m)).should be_false, "#{m} was replayed"
      end
      %w[GET HEAD OPTIONS].each do |m|
        Passive.replayable?(detail(method: m)).should be_true, "#{m} was skipped"
      end
    end

    it "skips a flow that never completed" do
      Passive.replayable?(detail(state: Gori::Store::FlowState::Error)).should be_false
      Passive.replayable?(detail(state: Gori::Store::FlowState::Pending)).should be_false
    end

    it "skips a response gori fabricated itself" do
      Passive.replayable?(detail(short_circuited: true)).should be_false
    end

    it "is case-insensitive about the header name" do
      Passive.replayable?(detail(headers: "cookie: s=1\r\n")).should be_true
      Passive.replayable?(detail(headers: "AUTHORIZATION: Bearer t\r\n")).should be_true
    end

    it "treats an unparseable head as not replayable rather than raising" do
      Passive.carries_auth?("\x00\xffnot http at all".to_slice).should be_false
    end
  end

  # Passive sees a NEW flow per page load, so a flow-id key would add a row every time the
  # browser refetches — the queue would become a traffic log.
  describe ".key" do
    it "keys on the endpoint, so repeat visits do not requeue it" do
      Passive.key(detail).should eq(Passive.key(detail))
    end

    it "separates different resources and different methods" do
      Passive.key(detail(target: "/orders?id=1")).should_not eq(Passive.key(detail(target: "/orders?id=2")))
      Passive.key(detail(method: "GET")).should_not eq(Passive.key(detail(method: "HEAD")))
    end
  end
end
