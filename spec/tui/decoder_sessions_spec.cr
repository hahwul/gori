require "../spec_helper"

include Gori::Tui

# The per-project wire form of the Decoder tab's open sub-tabs. The value is a row in the
# project db, so the parser has to survive whatever ends up in that column — a corrupt row
# may cost the restored sub-tabs, never the tab itself.
describe Gori::Tui::DecoderSessions do
  it "round-trips sessions, omitting an unset name" do
    sessions = [{"in1", "base64", "first"}, {"in2", "hex > upper", ""}]
    raw = DecoderSessions.to_json(sessions)
    raw.includes?(%("name":"first")).should be_true
    raw.scan(%("name")).size.should eq(1) # the unnamed session writes no name field
    DecoderSessions.parse(raw).should eq(sessions)
  end

  it "keeps a blank session (an empty sub-tab is a real sub-tab)" do
    DecoderSessions.parse(DecoderSessions.to_json([{"", "", ""}])).should eq([{"", "", ""}])
  end

  it "yields nothing for malformed JSON, a non-array, or non-object entries" do
    DecoderSessions.parse("{{not json").should be_empty
    DecoderSessions.parse(%({"input":"x"})).should be_empty
    DecoderSessions.parse("[1,\"two\",null]").should be_empty
    DecoderSessions.parse("").should be_empty
  end

  it "defaults missing fields to empty rather than dropping the session" do
    DecoderSessions.parse(%([{"chain":"md5"},{"input":"x"},{}]))
      .should eq([{"", "md5", ""}, {"x", "", ""}, {"", "", ""}])
  end

  it "reads the legacy settings.json object shape unchanged (the migration is a copy)" do
    legacy = %([{"input":"tok","chain":"base64-decode > json","name":"jwt"}])
    DecoderSessions.parse(legacy).should eq([{"tok", "base64-decode > json", "jwt"}])
  end
end
