require "../spec_helper"

private alias SE = Gori::Repeater::SendError

describe Gori::Repeater::SendError do
  it "reads a project budget refusal as a stop, not a retryable network error" do
    {Gori::Outbound::BUDGET_SPENT_ERROR, Gori::Outbound::BUDGET_STOPPED_ERROR}.each do |e|
      SE.kind(e).should eq("budget")
      SE.code(SE.kind(e)).should eq("BUDGET_EXHAUSTED")
      SE.retryable?(SE.code(SE.kind(e)), false).should be_false
    end
  end

  it "reads a busy project database as a retryable PROJECT_BUSY, not a spent budget" do
    e = Gori::Outbound::BUDGET_UNAVAILABLE_ERROR
    SE.code(SE.kind(e)).should eq("PROJECT_BUSY")
    SE.retryable?("PROJECT_BUSY", false).should be_true
  end
end
