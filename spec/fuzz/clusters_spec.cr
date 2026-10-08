require "../spec_helper"

private alias F = Gori::Fuzz

private def res(index : Int64, shape : Int64?, *, matched : Bool = false, error : String? = nil,
                status : Int32? = 200, length : Int64 = 10_i64, words : Int32 = 2,
                incomplete : Bool = false, payload : String = "p#{index}") : F::Result
  F::Result.new(index, [payload], 0, status, length, words, 1, 100_i64 * (index + 1), error,
    matched, incomplete, nil, Bytes[1], Bytes[2], Bytes[3], shape: shape)
end

describe Gori::Fuzz::Clusters do
  it "groups rows by shape and counts matched, errored and incomplete members" do
    c = F::Clusters.new
    c.add(res(0, 1_i64))
    c.add(res(1, 1_i64, matched: true, length: 30_i64))
    c.add(res(2, 2_i64, error: "Read timed out", status: nil))
    c.add(res(3, 1_i64, incomplete: true, length: 5_i64))
    c.size.should eq(2)
    c.rows.should eq(4)
    one = c[1_i64]?.not_nil!
    one.count.should eq(3)
    one.matched.should eq(1)
    one.incomplete.should eq(1)
    one.first_matched_index.should eq(1)
    {one.length_min, one.length_max}.should eq({5_i64, 30_i64})
    c[2_i64]?.not_nil!.errored.should eq(1)
  end

  it "picks the LOWEST index as representative whatever order rows arrive in" do
    c = F::Clusters.new
    [5, 2, 9, 0, 7].each { |i| c.add(res(i.to_i64, 1_i64)) }
    cl = c[1_i64]?.not_nil!
    cl.representative.index.should eq(0)
    cl.representative.payloads.should eq(["p0"])
    cl.samples.should eq([0_i64, 2_i64, 5_i64, 7_i64, 9_i64])
    cl.sample_complete?.should be_true
  end

  it "keeps no captured bytes on the representative" do
    c = F::Clusters.new
    c.add(res(0, 1_i64))
    rep = c[1_i64]?.not_nil!.representative
    rep.head.should be_nil
    rep.body.should be_nil
    rep.request.should be_nil
  end

  it "keeps only the lowest SAMPLE_INDICES member indices" do
    c = F::Clusters.new
    (0...50).to_a.reverse.each { |i| c.add(res(i.to_i64, 7_i64)) }
    cl = c[7_i64]?.not_nil!
    cl.samples.should eq((0...F::Clusters::SAMPLE_INDICES).map(&.to_i64))
    cl.sample_complete?.should be_false
  end

  it "orders rare-first, common-first and by first appearance, ties on index" do
    c = F::Clusters.new
    c.add(res(0, 10_i64))
    c.add(res(1, 10_i64))
    c.add(res(2, 10_i64))
    c.add(res(3, 20_i64))
    c.add(res(4, 30_i64))
    c.add(res(5, 30_i64))
    c.add(res(6, 40_i64))
    c.sorted(F::Clusters::Order::Rare).map(&.id).should eq([20_i64, 40_i64, 30_i64, 10_i64])
    c.sorted(F::Clusters::Order::Common).map(&.id).should eq([10_i64, 30_i64, 20_i64, 40_i64])
    c.sorted(F::Clusters::Order::First).map(&.id).should eq([10_i64, 20_i64, 30_i64, 40_i64])
  end

  it "counts new shapes past the cap as overflow instead of dropping them silently" do
    c = F::Clusters.new(max_clusters: 2)
    c.add(res(0, 1_i64))
    c.add(res(1, 2_i64))
    c.add(res(2, 3_i64, matched: true))
    c.add(res(3, 1_i64)) # an EXISTING shape still joins its cluster
    c.size.should eq(2)
    c.truncated?.should be_true
    c.overflow_rows.should eq(1)
    c.overflow_matched.should eq(1)
    c[1_i64]?.not_nil!.count.should eq(2)
  end

  it "keys a row saved before shapes existed approximately, apart from every real shape" do
    c = F::Clusters.new
    c.add(res(0, nil))
    c.add(res(1, nil))
    c.add(res(2, nil, words: 9))
    c.size.should eq(2)
    c.sorted.all?(&.approximate?).should be_true
  end

  it "never changes a row: clustering is a read projection" do
    c = F::Clusters.new
    r = res(4, 1_i64, matched: true)
    c.add(r)
    r.matched?.should be_true
    r.index.should eq(4)
    r.body.should eq(Bytes[2])
  end

  it "emits one field set, with the surface's own row and text sanitizer" do
    c = F::Clusters.new
    c.add(res(3, 0x0f_i64, matched: true))
    c.add(res(1, 0x0f_i64, error: "Read timed out"))
    json = JSON.parse(JSON.build do |j|
      j.object do
        F::Clusters.emit_summary(j, c)
        j.field("clusters") do
          j.array do
            c.sorted.each do |cl|
              F::Clusters.emit(j, cl, ->(t : String) { t.upcase }) { |rep| j.object { j.field "index", rep.index } }
            end
          end
        end
      end
    end)
    json["cluster_count"].should eq(1)
    json["clusters_truncated"].should be_false
    cl = json["clusters"][0]
    cl["id"].should eq("000000000000000f")
    cl["count"].should eq(2)
    cl["matched"].should eq(1)
    cl["errored"].should eq(1)
    cl["representative_index"].should eq(1)
    cl["representative_payloads"].should eq(["P1"])
    cl["representative"]["index"].should eq(1)
    cl["error_class"].should eq("timeout")
    cl["sample_indices"].should eq([1, 3])
  end

  # The TUI's matched-only list heads a cluster with its first hit; MCP and the CLI emit
  # through here, so they must too, never a row the lens hides.
  it "heads a matched-only cluster with its first hit, on every surface" do
    c = F::Clusters.new
    c.add(res(1, 0x0f_i64))
    c.add(res(3, 0x0f_i64, matched: true))
    cl = c[0x0f_i64]?.not_nil!
    json = JSON.parse(JSON.build { |j| F::Clusters.emit(j, cl, ->(t : String) { t }, true) { |rep| j.number rep.index } })
    json["representative_index"].should eq(3)
    json["representative_payloads"].should eq(["p3"])
    json["representative"].should eq(3)
    Gori::CLI::Output.fuzz_cluster_text(cl, true).should end_with("#3 p3")
    cl.head(false).index.should eq(1)
  end
end
