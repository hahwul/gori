require "../spec_helper"

private alias FP = Gori::Discover::Fingerprint

describe Gori::Discover::Fingerprint do
  it "gives near-identical hashes to content differing only in ids/dates" do
    a = FP.simhash("Welcome user 12345 on 2021-01-01 to the account dashboard overview panel".to_slice)
    b = FP.simhash("Welcome user 98765 on 2024-09-09 to the account dashboard overview panel".to_slice)
    FP.hamming(a, b).should be <= 2
  end

  it "gives distant hashes to genuinely different content" do
    a = FP.simhash("the quick brown fox jumps over the lazy sleeping dog again".to_slice)
    b = FP.simhash("completely unrelated administrative control panel interface settings".to_slice)
    FP.hamming(a, b).should be > 5
  end
end

describe Gori::Discover::ClusterMap do
  it "counts distinct entries mapping to one content cluster" do
    cm = Gori::Discover::ClusterMap.new
    h = FP.simhash("product listing page row item price add to cart".to_slice)
    cm.observe(h, 3).should eq(1)
    cm.observe(h, 3).should eq(2)
    cm.observe(h, 3).should eq(3)
    other = FP.simhash("a totally separate unique article body with prose here".to_slice)
    cm.observe(other, 3).should eq(1)
  end
end
