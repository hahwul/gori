require "../../spec_helper"

describe "gori run grpc reflect --timeout" do
  it "accepts a positive fractional timeout" do
    Gori::CLI::Run.grpc_timeout("1.5").not_nil!.total_seconds.should eq(1.5)
  end

  it "refuses non-finite, overflowing, and sub-resolution values without raising" do
    %w[NaN Infinity -Infinity 1e300 1e-320].each do |value|
      Gori::CLI::Run.grpc_timeout(value).should be_nil
    end
  end

  it "refuses zero and negative values" do
    Gori::CLI::Run.grpc_timeout("0").should be_nil
    Gori::CLI::Run.grpc_timeout("-1").should be_nil
  end
end
