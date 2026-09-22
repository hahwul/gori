require "../../spec_helper"
require "json"

# `gori run show --headers-only` / `--max-body` (#1119). The compact view is the heads and the
# capped bodies; everything DERIVED from a body is left out, and a transcript's count stays so
# its absence never reads as "there was none".
module Gori::CLI::Run
  def self.show_cap_json_for_spec(detail : Store::FlowDetail, cap : BodyCap,
                                  ws_msgs : Array(Store::WsMessage) = [] of Store::WsMessage) : JSON::Any
    JSON.parse(show_json(detail, true, true, ws_msgs, cap))
  end
end

private def cap_detail(request_head : String, response_head : String, response_body : String) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(
    id: 9_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "x.test", port: 443,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", request_head.to_slice, nil,
    response_head.to_slice, response_body.to_slice)
end

# A JWT in the request, so the full view has a decoded section to leave out.
private JWT_REQ = "GET / HTTP/1.1\r\nHost: x.test\r\nAuthorization: Bearer " \
                  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl\r\n\r\n"

describe "gori run show — --headers-only / --max-body (#1119)" do
  it "applies only to the text and json views" do
    omit = Gori::CLI::Run::BodyCap.new(omit: true)
    Gori::CLI::Run.show_cap_error(:text, omit).should be_nil
    Gori::CLI::Run.show_cap_error(:json, omit).should be_nil
    Gori::CLI::Run.show_cap_error(:raw, omit).not_nil!.should contain("--format raw")
    Gori::CLI::Run.show_cap_error(:har, Gori::CLI::Run::BodyCap.new(max: 1)).not_nil!.should contain("--max-body")
    Gori::CLI::Run.show_cap_error(:curl, Gori::CLI::Run::BodyCap.new).should be_nil
  end

  it "omits the bodies and the decoded views, and keeps the heads" do
    detail = cap_detail(JWT_REQ, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n", "hello world")
    full = Gori::CLI::Run.show_cap_json_for_spec(detail, Gori::CLI::Run::BodyCap.new)
    full["jwt"]?.should_not be_nil

    j = Gori::CLI::Run.show_cap_json_for_spec(detail, Gori::CLI::Run::BodyCap.new(omit: true))
    j["jwt"]?.should be_nil
    j["request"]["head"].as_s.should contain("Authorization: Bearer")
    body = j["response"]["body"]
    {body["omitted"].as_bool, body["size"].as_i}.should eq({true, 11})
    body["text"]?.should be_nil
  end

  it "cuts each body under --max-body" do
    detail = cap_detail(JWT_REQ, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n", "hello world")
    body = Gori::CLI::Run.show_cap_json_for_spec(detail, Gori::CLI::Run::BodyCap.new(max: 5))["response"]["body"]
    {body["text"].as_s, body["size"].as_i, body["shown_size"].as_i}.should eq({"hello", 11, 5})
  end

  it "names a transcript's count instead of printing it" do
    detail = cap_detail("GET /ws HTTP/1.1\r\nHost: x.test\r\n\r\n", "HTTP/1.1 101 Switching Protocols\r\n\r\n", "")
    msgs = [Gori::Store::WsMessage.new(1_i64, 9_i64, nil, 0_i64, "out", 1, "hi".to_slice)]
    ws = Gori::CLI::Run.show_cap_json_for_spec(detail, Gori::CLI::Run::BodyCap.new(omit: true), msgs)["ws_messages"]
    {ws["count"].as_i, ws["omitted"].as_bool}.should eq({1, true})
    ws["messages"]?.should be_nil

    sse_body = String.build { |io| 3.times { |i| io << "data: e#{i}\n\n" } }
    sse_detail = cap_detail("GET / HTTP/1.1\r\nHost: x.test\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n", sse_body)
    sse = Gori::CLI::Run.show_cap_json_for_spec(sse_detail, Gori::CLI::Run::BodyCap.new(max: 4))["sse_events"]
    {sse["count"].as_i, sse["omitted"].as_bool}.should eq({3, true})
  end
end
