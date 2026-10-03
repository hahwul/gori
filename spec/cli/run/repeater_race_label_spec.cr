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
