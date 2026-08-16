require "../spec_helper"
require "../../src/gori/authorize/passive"

private alias Passive = Gori::Authorize::Passive
private alias Identity = Gori::Authorize::Identity

private def detail(method = "GET", target = "/orders", headers = "Cookie: session=A\r\n",
                   state = Gori::Store::FlowState::Complete,
                   short_circuited = false) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 0_i64, "https", method, "h.test", 443, target,
    200, 100_i64, state, 50_i64, 1_i64, "text/html", short_circuited)
  head = "#{method} #{target} HTTP/1.1\r\nHost: h.test\r\n#{headers}\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
end

# The shipped default set: as-captured plus an anonymous identity that strips the session.
private def defaults : Array(Identity)
  [
    Identity.as_captured("as-captured"),
    Identity.new("anonymous", remove_headers: ["Cookie", "Authorization"]),
  ]
end

describe Gori::Authorize::Passive do
  describe ".skip_reason" do
    it "takes a safe request an identity would actually change" do
      Passive.skip_reason(detail, defaults).should be_nil
      Passive.replayable?(detail, defaults).should be_true
    end

    # THE regression that made this mode look broken. On a site the operator is not logged
    # into, the old "does it carry a Cookie?" test skipped everything and said nothing. The
    # question that matters is whether any identity CHANGES the request — and a session the
    # operator configures answers it immediately.
    describe "when no identity would change the request" do
      it "skips it, because every trial would send identical bytes" do
        d = detail(headers: "") # nothing to strip
        Passive.skip_reason(d, defaults).should eq(:no_effect)
      end

      # Left in, those rows read `⚠ same` — a finding manufactured out of nothing, on every
      # public page of the site.
      it "is what keeps a public site from lighting up as a bypass on every page" do
        Passive.replayable?(detail(headers: "Accept: */*\r\n"), defaults).should be_false
      end

      it "takes the same request once an identity SETS a session" do
        with_low_priv = defaults + [Identity.new("low-priv", set_headers: [{"Cookie", "session=USER"}])]
        Passive.skip_reason(detail(headers: ""), with_low_priv).should be_nil
      end

      it "skips when only the baseline exists — there is nothing to compare against" do
        Passive.skip_reason(detail, [Identity.as_captured]).should eq(:no_effect)
      end

      # An API authenticating through a header the old heuristic never listed.
      it "takes an X-Api-Key request when an identity replaces that header" do
        ids = defaults + [Identity.new("other-key", set_headers: [{"X-Api-Key", "k2"}])]
        Passive.skip_reason(detail(headers: "X-Api-Key: k1\r\n"), ids).should be_nil
      end
    end

    # Unattended replay of a state-changing request runs its side effect again, once per
    # identity, with nobody there to decide that is acceptable.
    it "skips methods that are not safe to repeat unattended" do
      %w[POST PUT PATCH DELETE].each do |m|
        Passive.skip_reason(detail(method: m), defaults).should eq(:unsafe_method)
      end
      %w[GET HEAD OPTIONS].each do |m|
        Passive.skip_reason(detail(method: m), defaults).should be_nil
      end
    end

    it "skips a flow that never completed" do
      Passive.skip_reason(detail(state: Gori::Store::FlowState::Error), defaults).should eq(:incomplete)
      Passive.skip_reason(detail(state: Gori::Store::FlowState::Pending), defaults).should eq(:incomplete)
    end

    it "skips a response gori fabricated itself" do
      Passive.skip_reason(detail(short_circuited: true), defaults).should eq(:short_circuited)
    end

    it "is case-insensitive about the header an identity strips" do
      Passive.skip_reason(detail(headers: "cookie: s=1\r\n"), defaults).should be_nil
    end
  end

  # Every refusal has to be sayable, or the tab can only show a number.
  it "labels every reason it can report" do
    {:no_effect, :unsafe_method, :incomplete, :short_circuited, :out_of_scope, :duplicate}.each do |r|
      Passive.reason_label(r).should_not be_empty
      Passive.reason_label(r).should_not eq(r.to_s) # a real sentence, not the symbol
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
