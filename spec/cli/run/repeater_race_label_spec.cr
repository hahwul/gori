require "../../spec_helper"

module Gori::CLI::Run
  def self.race_request_line_for_spec(request : Bytes) : String
    race_request_line(request)
  end
end

# `repeater race` / `timing` label each member with its stored request line. That line need not
# be UTF-8 (the JSON form printed the raw byte) or free of control bytes (the text form wrote
# them to the terminal).
describe "gori run repeater race member label" do
  it "is valid UTF-8 and carries no raw control bytes" do
    label = Gori::CLI::Run.race_request_line_for_spec("GET /\xff\e[31m HTTP/1.1\r\nHost: h\r\n\r\n".to_slice)
    label.valid_encoding?.should be_true
    label.should_not contain('\e')
    label.should start_with("GET /")
  end
end

# #1678: in a limit-overrun race every side usually answers 200, so the body is the only
# evidence of which request won — and a race is not stored, so `--format json` is the only copy.
describe "gori run repeater race --format json" do
  it "carries each member's session id, head and capped body, plus the MCP tally" do
    plan = Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new(["GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice],
      default_target: "http://127.0.0.1:1"), ungated_outbound)
    head = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n".to_slice
    parsed = Gori::Proxy::Codec::Http1.parse_response_head(head)
    results = [Gori::Repeater::Result.new(head, "applied".to_slice, parsed, 10_i64),
               Gori::Repeater::Result.new(head, "already".to_slice, parsed, 20_i64)]
    j = JSON.parse(Gori::CLI::Run.race_json([7_i64, 9_i64], ["#7 GET /", "#9 GET /"], results, plan,
      Gori::CLI::Run::BodyCap.new(max: 3)))
    j["responded"].as_i.should eq(2)
    j["won_2xx"].as_i.should eq(2)
    members = j["members"].as_a
    members.map(&.["id"].as_i64).should eq([7, 9])
    members[0]["head"].as_s.should start_with("HTTP/1.1 200 OK")
    members.map(&.["body"]["text"].as_s).should eq(["app", "alr"])
    members[0]["body"]["size"].as_i.should eq(7)
  end
end
