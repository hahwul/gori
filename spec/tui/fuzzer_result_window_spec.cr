require "../spec_helper"

private def window_result(idx : Int64, body_size : Int32 = 0,
                          matched : Bool = false) : Gori::Fuzz::Result
  body = body_size > 0 ? Bytes.new(body_size, idx.to_u8) : nil
  Gori::Fuzz::Result.new(idx, ["p#{idx}"], nil, 200, body_size.to_i64, 1, 1,
    1_i64, nil, matched, false, nil, Bytes[0x48], body, Bytes[0x47])
end

describe Gori::Tui::FuzzerResultWindow do
  it "evicts oldest rows at the row cap" do
    window = Gori::Tui::FuzzerResultWindow.new(2, 10_000_i64)
    window.append(window_result(0_i64)).should eq(0)
    window.append(window_result(1_i64)).should eq(0)
    window.append(window_result(2_i64)).should eq(1)
    window.rows.map(&.index).should eq([1_i64, 2_i64])
  end

  it "evicts by cumulative bytes independently of row count" do
    one = window_result(1_i64, 100)
    charge = Gori::Tui::FuzzerResultWindow.result_bytes(one)
    window = Gori::Tui::FuzzerResultWindow.new(10, charge + 10_i64)
    window.append(one).should eq(0)
    window.append(window_result(2_i64, 100)).should eq(1)
    window.rows.map(&.index).should eq([2_i64])
    window.bytes.should be <= charge + 10_i64
  end

  it "evicts in stable order after many post-cap appends" do
    window = Gori::Tui::FuzzerResultWindow.new(3, 10_000_i64)
    100.times { |i| window.append(window_result(i.to_i64)) }
    window.rows.map(&.index).should eq([97_i64, 98_i64, 99_i64])
  end

  it "keeps an individually oversized result as metrics only" do
    row = window_result(9_i64, 500, matched: true)
    metadata = Gori::Tui::FuzzerResultWindow.result_bytes(
      Gori::Tui::FuzzerResultWindow.metrics_only(row))
    window = Gori::Tui::FuzzerResultWindow.new(10, metadata + 1_i64)
    window.append(row).should eq(0)

    kept = window.rows.first
    kept.index.should eq(9_i64)
    kept.matched?.should be_true
    kept.length.should eq(500_i64)
    kept.request.should be_nil
    kept.head.should be_nil
    kept.body.should be_nil
    # The bytes are in the archive, not absent: the projection mark is what tells the detail
    # panes so, and it used to be set only when the SECOND cap tripped as well.
    window.projected?(9_i64).should be_true
    kept.wire.should be_nil
  end

  # Eviction looks for another row with the evicted index only when that index is MARKED
  # (an unmarked delete is a no-op), so the mark has to live exactly as long as a projected
  # copy of its index is still in the window — and never appear for one that was not.
  it "keeps a projection mark while its index is still in the window, and drops it after" do
    small = Gori::Tui::FuzzerResultWindow.result_bytes(window_result(0_i64))
    cap = small * 3 + 50_i64
    window = Gori::Tui::FuzzerResultWindow.new(3, cap)
    window.append(window_result(5_i64, (cap + 100).to_i32)) # oversized → projected
    window.projected?(5_i64).should be_true
    window.append(window_result(5_i64)) # the same index again (a resend), small
    window.append(window_result(6_i64))
    window.append(window_result(7_i64)).should eq(1) # evicts the projected copy of 5
    window.rows.map(&.index).should eq([5_i64, 6_i64, 7_i64])
    window.projected?(5_i64).should be_true # another row with index 5 is still shown
    window.append(window_result(8_i64)).should eq(1)
    window.projected?(5_i64).should be_false # its last copy is gone
    [6_i64, 7_i64, 8_i64].each { |i| window.projected?(i).should be_false }
    200.times { |i| window.append(window_result(100_i64 + i)) }
    window.rows.map(&.index).should eq([297_i64, 298_i64, 299_i64])
  end

  it "bounds oversized scalar text and marks the display projection" do
    row = Gori::Fuzz::Result.new(12_i64, ["p" * 500], nil, 500, 0_i64, 0, 0,
      1_i64, "e" * 500, false, false, "x" * 500)
    window = Gori::Tui::FuzzerResultWindow.new(10,
      Gori::Fuzz::Persistence::ROW_METADATA_BYTES + 80_i64)
    window.append(row).should eq(0)

    window.rows.size.should eq(1)
    window.bytes.should be <= Gori::Fuzz::Persistence::ROW_METADATA_BYTES + 80_i64
    window.projected?(12_i64).should be_true
    window.rows.first.payloads.join.bytesize.should be <= 80
    window.rows.first.payloads.join.should contain("display truncated")
    window.clear
    window.projected?(12_i64).should be_false
  end

  it "saves every spooled row rather than only the bounded display window" do
    root = File.tempname("gori-window-spool")
    project_path = File.tempname("gori-window-project", ".db")
    spool = Gori::Fuzz::Spool.new(root)
    project = Gori::Store.open(project_path, retention_flows: 0, background_index: false)
    begin
      source = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://complete.test", "sniper", 6_i64))
      window = Gori::Tui::FuzzerResultWindow.new(2, 10_000_i64)
      6.times do |i|
        result = window_result(i.to_i64)
        source.append(result).should be_true
        window.append(result)
      end
      source.finish(6_i64, 0_i64, 0_i64, "done").should be_true
      window.rows.map(&.index).should eq([4_i64, 5_i64])

      saved = Gori::Fuzz::Persistence.new(project,
        Gori::Fuzz::SavedRunMeta.new(nil, "https://complete.test", "sniper", 6_i64),
        initial_status: "saving")
      source.each_result { |record| saved.append(record).should be_true }
      saved.finish(6_i64, 0_i64, 0_i64, "done").should be_true
      project.fuzz_result_count(saved.run_id).should eq(6_i64)
    ensure
      spool.close
      project.close
      FileUtils.rm_rf(root)
      File.delete?(project_path)
      File.delete?("#{project_path}-wal")
      File.delete?("#{project_path}-shm")
      File.delete?("#{project_path}.open.lock")
    end
  end

  # A concurrent run's results arrive in completion order (#1432); the window is the identity
  # `o:index` view, so it has to hold them in index order, as a saved run is read back.
  it "keeps rows in index order whatever order they arrive in" do
    window = Gori::Tui::FuzzerResultWindow.new(10, 10_000_i64)
    [1, 2, 0, 4, 3, 6, 5, 7].each { |i| window.append(window_result(i.to_i64)) }
    window.rows.map(&.index).should eq((0_i64..7_i64).to_a)
    window.bytes.should eq(window.rows.sum { |r| Gori::Tui::FuzzerResultWindow.result_bytes(r) })
  end

  it "keeps the charge beside its row when a late row lands mid-window" do
    # Evicting the heavy row must release ITS charge: a charge pushed at the tail would
    # release a light one instead, and the byte cap would drift from what the window holds.
    window = Gori::Tui::FuzzerResultWindow.new(3, 10_000_i64)
    window.append(window_result(0_i64))
    window.append(window_result(2_i64))
    window.append(window_result(1_i64, 100)) # the heavy row lands between the two
    window.rows.map(&.index).should eq([0_i64, 1_i64, 2_i64])
    window.append(window_result(3_i64)) # evicts #0
    window.append(window_result(4_i64)) # evicts the heavy #1
    window.rows.map(&.index).should eq([2_i64, 3_i64, 4_i64])
    window.bytes.should eq(window.rows.sum { |r| Gori::Tui::FuzzerResultWindow.result_bytes(r) })
  end

  it "evicts a late row older than a full window's first at once" do
    window = Gori::Tui::FuzzerResultWindow.new(2, 10_000_i64)
    window.append(window_result(1_i64))
    window.append(window_result(2_i64))
    window.append(window_result(0_i64)).should eq(1)
    window.rows.map(&.index).should eq([1_i64, 2_i64])
  end

  it "puts a resend after the earlier copy of its index" do
    window = Gori::Tui::FuzzerResultWindow.new(10, 10_000_i64)
    window.append(window_result(1_i64))
    window.append(window_result(2_i64))
    resend = window_result(1_i64, 7)
    window.append(resend)
    window.rows.map(&.index).should eq([1_i64, 1_i64, 2_i64])
    window.rows[1].length.should eq(7_i64)
  end

  it "clears rows and byte accounting together" do
    window = Gori::Tui::FuzzerResultWindow.new(10, 10_000_i64)
    window.append(window_result(1_i64))
    window.clear
    window.rows.should be_empty
    window.bytes.should eq(0_i64)
  end
end
