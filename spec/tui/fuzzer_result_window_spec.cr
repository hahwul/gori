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
    kept.wire.should be_nil
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

  it "clears rows and byte accounting together" do
    window = Gori::Tui::FuzzerResultWindow.new(10, 10_000_i64)
    window.append(window_result(1_i64))
    window.clear
    window.rows.should be_empty
    window.bytes.should eq(0_i64)
  end
end
