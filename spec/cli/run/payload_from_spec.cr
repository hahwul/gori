require "../../spec_helper"

# `--payload-from` on the CLI (#1352). The flags themselves abort and print, so what an example can
# pin is the part around them: the run-wide policy the companions build, and the words a source's
# report is said in on STDERR.
describe "gori run --payload-from" do
  describe Gori::CLI::Run::PayloadFromFlags do
    it "starts at the safe answer: defaults, nothing sensitive" do
      p = Gori::CLI::Run::PayloadFromFlags.new.policy
      p.include_sensitive.should be_false
      p.locations.should be_nil
      p.max_flows.should eq(Gori::PayloadFrom::DEFAULT_MAX_FLOWS)
      p.max_values.should eq(Gori::PayloadFrom::DEFAULT_MAX_VALUES)
    end

    it "carries what the companions set" do
      f = Gori::CLI::Run::PayloadFromFlags.new
      f.sensitive = true
      f.locations = [Gori::Miner::Location::Query, Gori::Miner::Location::Cookies]
      f.max_flows = 50
      f.max_values = 7
      p = f.policy
      p.include_sensitive.should be_true
      p.locations.should eq([Gori::Miner::Location::Query, Gori::Miner::Location::Cookies])
      p.max_flows.should eq(50)
      p.max_values.should eq(7)
    end

    it "applies to a source parsed BEFORE the companion was typed, wherever the flag sat" do
      f = Gori::CLI::Run::PayloadFromFlags.new
      spec = Gori::PayloadFrom.parse("host:api param-values") # what `--payload-from` built first
      f.sensitive = true                                      # the companion typed after it
      spec.apply(f.policy).include_sensitive.should be_true
    end
  end

  describe ".payload_from_note_lines" do
    report = ->(capped : Gori::PayloadFrom::Cap?, sensitive : Bool) do
      Gori::PayloadFrom::Report.new("host:api param-names", Gori::PayloadFrom::Projection::ParamNames, "host:api",
        137, 412, capped, 2000, 10_000, 0, 0, 0, sensitive, %w[query form multipart json])
    end

    it "says what a source read, prefixed by the command, with no value" do
      lines = Gori::CLI::Run.payload_from_note_lines("gori run fuzz", [report.call(nil, false)])
      lines.should eq(["gori run fuzz: payload-from: host:api param-names → 137 values from 412 flows"])
    end

    it "names the flag that lifts the cap that ended the read" do
      Gori::CLI::Run.payload_from_note_lines("gori run mine", [report.call(Gori::PayloadFrom::Cap::Flows, false)])
        .first.should end_with("read only the newest 2000 flows (raise --payload-from-max-flows)")
      Gori::CLI::Run.payload_from_note_lines("gori run mine", [report.call(Gori::PayloadFrom::Cap::Values, false)])
        .first.should end_with("stopped at 10000 values (raise --payload-from-max-values)")
      Gori::CLI::Run.payload_from_note_lines("gori run mine", [report.call(Gori::PayloadFrom::Cap::Bytes, false)])
        .first.should end_with("(narrow the query)")
    end

    it "shouts when the opt-in is on" do
      Gori::CLI::Run.payload_from_note_lines("gori run fuzz", [report.call(nil, true)]).first.should contain("SENSITIVE INCLUDED")
    end
  end
end
