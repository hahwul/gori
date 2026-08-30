require "../../spec_helper"

module Gori::CLI::Run
  def self.fuzz_saved_bytes_json_for_spec(bytes : Bytes?) : String
    JSON.build do |json|
      json.object { fuzz_saved_bytes_json(json, "blob", bytes) }
    end
  end

  def self.fuzz_saved_mode_for_spec(mode : Fuzz::Mode, requested : Int32?, effective : Int32?) : String
    fuzz_saved_mode(mode, requested, effective)
  end
end

describe "gori run fuzz saved runs" do
  it "keeps valid UTF-8 detail bytes as text" do
    parsed = JSON.parse(Gori::CLI::Run.fuzz_saved_bytes_json_for_spec("GET / HTTP/1.1\r\n\r\n".to_slice))
    parsed["blob"].as_s.should eq("GET / HTTP/1.1\r\n\r\n")
    parsed["blob_encoding"].as_s.should eq("utf8")
    parsed["blob_size"].as_i.should eq(18)
  end

  it "base64-encodes invalid UTF-8 detail bytes without changing them" do
    bytes = Bytes[0x47, 0xff, 0x00]
    parsed = JSON.parse(Gori::CLI::Run.fuzz_saved_bytes_json_for_spec(bytes))
    parsed["blob_encoding"].as_s.should eq("base64")
    Base64.decode(parsed["blob"].as_s).should eq(bytes)
    parsed["blob_size"].as_i.should eq(3)
  end

  it "records race provenance instead of the bypassed attack mode" do
    Gori::CLI::Run.fuzz_saved_mode_for_spec(Gori::Fuzz::Mode::Sniper, 500, 100)
      .should eq("race ×100")
    Gori::CLI::Run.fuzz_saved_mode_for_spec(Gori::Fuzz::Mode::ClusterBomb, nil, nil)
      .should eq("cluster-bomb")
  end

  it "distinguishes a request-budget cutoff from an exhaustive run" do
    partial = Gori::Fuzz::Progress.new(2_i64, 5_i64, 0_i64, 0_i64, requests: 3_i64)
    Gori::Fuzz.terminal_status(partial, false, 3_i64).should eq("budget_exhausted")

    complete = Gori::Fuzz::Progress.new(5_i64, 5_i64, 0_i64, 0_i64, requests: 3_i64)
    Gori::Fuzz.terminal_status(complete, false, 3_i64).should eq("done")
  end

  it "gives stop and setup error precedence over the budget status" do
    p = Gori::Fuzz::Progress.new(2_i64, 5_i64, 0_i64, 0_i64, requests: 3_i64)
    Gori::Fuzz.terminal_status(p, true, 3_i64).should eq("stopped")
    Gori::Fuzz.terminal_status(p, false, 3_i64, true).should eq("error")
  end

  it "streams a valid empty or partial JSON array even when the producer raises" do
    empty = IO::Memory.new
    Gori::CLI::Output::FuzzArrayStream.new(empty).close
    JSON.parse(empty.to_s).as_a.should be_empty

    row = Gori::Fuzz::Result.new(7_i64, ["payload"], 0, 200, 2_i64, 1, 1,
      10_i64, nil, true, false, nil)
    partial = IO::Memory.new
    stream = Gori::CLI::Output::FuzzArrayStream.new(partial)
    expect_raises(Exception, "consumer failed") do
      begin
        stream.append(row)
        raise "consumer failed"
      ensure
        stream.close
      end
    end
    parsed = JSON.parse(partial.to_s).as_a
    parsed.size.should eq(1)
    parsed[0]["index"].as_i64.should eq(7)
  end

  it "neutralizes every dynamic one-line fuzz-row string" do
    inject = "ok\e[31mBAD\rOVERWRITE\nNEXT"
    row = Gori::Fuzz::Result.new(1_i64, [inject], 0, 200, 2_i64, 1, 1,
      10_i64, inject, true, false, inject, nil, nil, nil, false, inject, 7,
      inject)
    text = Gori::CLI::Output.fuzz_row_text(row)
    text.should_not contain("\e")
    text.should_not contain('\r')
    text.should_not contain('\n')
    text.should_not contain("BAD\rOVERWRITE")
    text.should contain("BAD·OVERWRITE·NEXT")
  end
end
