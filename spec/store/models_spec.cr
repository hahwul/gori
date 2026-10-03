require "../spec_helper"

private def cut_detail(request_cut : Bool, response_cut : Bool) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(
    id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "a.test", port: 443,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", "POST / HTTP/1.1\r\n\r\n".to_slice, "req".to_slice,
    "HTTP/1.1 200 OK\r\n\r\n".to_slice, "resp".to_slice,
    request_body_truncated: request_cut, response_body_truncated: response_cut)
end

# The per-side cut `gori run compare` and MCP `compare_flows` both report in
# `source_truncated` (#1463 moved it here from the two surfaces).
describe "Gori::Store::FlowDetail#body_truncated?" do
  it "reads the request flag for :request and the response flag otherwise" do
    req_only = cut_detail(request_cut: true, response_cut: false)
    req_only.body_truncated?(:request).should be_true
    req_only.body_truncated?(:response).should be_false

    resp_only = cut_detail(request_cut: false, response_cut: true)
    resp_only.body_truncated?(:request).should be_false
    resp_only.body_truncated?(:response).should be_true
  end

  it "is false on both sides of a body captured whole" do
    whole = cut_detail(request_cut: false, response_cut: false)
    whole.body_truncated?(:request).should be_false
    whole.body_truncated?(:response).should be_false
  end
end

# A stored severity/status out of the enum's range (a foreign row) raised "enum value outside
# of defined enum members" from every exhaustive `case` that labelled it.
describe "Gori::Store::Severity.stored / Status.stored" do
  it "keeps a stored value in range" do
    Gori::Store::Severity.stored(-1).should eq(Gori::Store::Severity::Info)
    Gori::Store::Severity.stored(99).should eq(Gori::Store::Severity::Critical)
    Gori::Store::Severity.stored(3).should eq(Gori::Store::Severity::High)
    Gori::Store::Status.stored(-1).should eq(Gori::Store::Status::Open)
    Gori::Store::Status.stored(2).label.should eq("false-positive")
  end
end
