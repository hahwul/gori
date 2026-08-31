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

  def self.fuzz_saved_run_json_for_spec(run : Store::FuzzRunRecord, stored : Int64) : String
    JSON.build { |json| fuzz_saved_run_json(json, run, stored) }
  end

  def self.fuzz_saved_run_line_for_spec(run : Store::FuzzRunRecord, stored : Int64) : String
    fuzz_saved_run_line(run, stored)
  end
end

private def saved_run(snapshot : Int32 = 1, http2 : Bool = false, websocket : Bool = false,
                      finished : Int64? = 1_700_000_002_500_000_i64) : Gori::Store::FuzzRunRecord
  Gori::Store::FuzzRunRecord.new(7_i64, 3_i64, 1_700_000_001_250_000_i64, finished,
    "https://h.test", "sniper", 4_i64, 4_i64, 2_i64, 0_i64, "done", http2,
    nil, nil, websocket, "tui", "tui:3:1", snapshot)
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

    calls = 0
    encoder = ->(result : Gori::Fuzz::Result) do
      calls += 1
      raise "encoder failed" if calls == 2
      Gori::CLI::Output.fuzz_row_json(result)
    end
    encoded = IO::Memory.new
    guarded = Gori::CLI::Output::FuzzArrayStream.new(encoded, encoder)
    guarded.append(row)
    expect_raises(Exception, "encoder failed") { guarded.append(row) }
    guarded.close
    JSON.parse(encoded.to_s).as_a.size.should eq(1)
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

  # A `snapshot_version = 0` row predates the V24 transport columns, so `http2`/`websocket`
  # are the migration's DEFAULTS, not observations. Both listing surfaces draw a one-word
  # transport chip off them, and only the TUI picker checked this — the CLI printed `[H1]`,
  # asserting HTTP/1.1 about a run whose protocol was never recorded, on the very command
  # the picker's refusal points the operator at.
  it "labels a legacy snapshot's transport as LEGACY rather than asserting H1" do
    saved_run(snapshot: 0).proto_label.should eq("LEGACY")
    saved_run(snapshot: 0, http2: true).proto_label.should eq("LEGACY")
    saved_run(snapshot: 1).proto_label.should eq("H1")
    saved_run(snapshot: 1, http2: true).proto_label.should eq("H2")
    saved_run(snapshot: 1, websocket: true).proto_label.should eq("WS")
    saved_run(snapshot: 1, websocket: true, http2: true).proto_label.should eq("WS")

    # …and the LISTING has to read it off the record rather than re-deriving it. This is the
    # line the TUI picker's refusal sends the operator to, and it used to print `[H1]`.
    Gori::CLI::Run.fuzz_saved_run_line_for_spec(saved_run(snapshot: 0), 3_i64)
      .should contain("[LEGACY]")
    Gori::CLI::Run.fuzz_saved_run_line_for_spec(saved_run(snapshot: 1, http2: true), 3_i64)
      .should contain("[H2]")
  end

  # The key sets of the two saved-run feeds, pinned against each other — the same discipline
  # `spec/cli/run/history_spec.cr` keeps for flow rows. `gori run fuzz list --format json`
  # carried the raw unix micros and no RFC3339 twin while `list_fuzz_runs` emitted both, so a
  # script correlating the two could not compare them as strings.
  it "emits the same saved-run field set as MCP's list_fuzz_runs" do
    run = saved_run
    cli = JSON.parse(Gori::CLI::Run.fuzz_saved_run_json_for_spec(run, 4_i64)).as_h
    mcp = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.saved_fuzz_run(j, run, 4_i64) }).as_h
    cli.keys.sort.should eq(mcp.keys.sort)
    cli.each { |key, value| value.should eq(mcp[key]) }
    cli["created_at_iso"].as_s.should eq("2023-11-14T22:13:21.250Z")
    cli["finished_at_iso"].as_s.should eq("2023-11-14T22:13:22.500Z")
  end

  it "emits a null finished_at_iso for a run that never finished" do
    cli = JSON.parse(Gori::CLI::Run.fuzz_saved_run_json_for_spec(
      saved_run(finished: nil), 0_i64)).as_h
    cli["finished_at"].raw.should be_nil
    cli["finished_at_iso"].raw.should be_nil
  end
end
