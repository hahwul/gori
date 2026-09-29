require "../spec_helper"

private alias F = Gori::Fuzz

# The number both huge-run gates judge (`gori run fuzz`'s `--force`, MCP's BUDGET_EXHAUSTED):
# what the run can put on the wire, not how many candidates it has (#1209).
describe "Fuzz.request_bound" do
  it "bounds the candidate total by a positive max_requests" do
    F.request_bound(100_000_000_i64, 2_i64).should eq(2)
    F.request_bound(5_i64, 100_i64).should eq(5)
  end

  it "lets a cap bound a run whose total is unknown" do
    F.request_bound(nil, 1_i64).should eq(1)
    F.request_bound(nil, nil).should be_nil
  end

  it "ignores a non-positive cap, as CappedBackend does" do
    F.request_bound(200_000_i64, 0_i64).should eq(200_000)
    F.request_bound(nil, -1_i64).should be_nil
  end

  it "adds the requests a request-time macro's steps put on the wire (#1350)" do
    F.request_bound(1_000_i64, nil, 1_000_i64).should eq(2_000)
    F.request_bound(1_000_i64, 1_500_i64, 1_000_i64).should eq(1_500) # the cap still wins
    F.request_bound(nil, 40_i64, 1_000_i64).should eq(40)
    F.request_bound(Int64::MAX - 1, nil, 10_i64).should eq(Int64::MAX) # saturates, never overflows
  end
end
