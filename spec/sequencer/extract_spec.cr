require "../spec_helper"

private alias Q = Gori::Sequencer

private def response(head : String, body : String) : Gori::Repeater::Result
  hb = head.to_slice
  resp = Gori::Proxy::Codec::Http1.parse_response_head(hb)
  Gori::Repeater::Result.new(hb, body.to_slice, resp, 1000_i64)
end

private HEAD = "HTTP/1.1 200 OK\r\n" \
               "Set-Cookie: theme=dark; Path=/\r\n" \
               "Set-Cookie: SESSIONID=abc123XYZ; Path=/; HttpOnly\r\n" \
               "Content-Type: application/json\r\n" \
               "X-Csrf-Token: tok-99\r\n\r\n"
private BODY = %({"data":{"token":"deadbeef"},"items":["a","b"]})

describe Gori::Sequencer::Extract do
  it "extracts a cookie value by name across multiple Set-Cookie headers" do
    r = response(HEAD, BODY)
    Q::Extract.extract(r, Q::TokenLoc.cookie("SESSIONID")).should eq("abc123XYZ")
    Q::Extract.extract(r, Q::TokenLoc.cookie("theme")).should eq("dark")
    Q::Extract.extract(r, Q::TokenLoc.cookie("nope")).should be_nil
  end

  it "extracts a named header (case-insensitive)" do
    r = response(HEAD, BODY)
    loc = Q::TokenLoc.new(Q::ExtractKind::Header, "x-csrf-token")
    Q::Extract.extract(r, loc).should eq("tok-99")
  end

  it "extracts a regex capture group over the decoded body" do
    r = response(HEAD, BODY)
    loc = Q::TokenLoc.new(Q::ExtractKind::Regex, %("token":"(\\w+)"))
    Q::Extract.extract(r, loc).should eq("deadbeef")
  end

  it "extracts a fixed byte position range of the body" do
    r = response(HEAD, BODY)
    loc = Q::TokenLoc.new(Q::ExtractKind::Position, "", 0, 1)
    Q::Extract.extract(r, loc).should eq("{")
  end

  it "extracts a JSON path leaf" do
    r = response(HEAD, BODY)
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "$.data.token")).should eq("deadbeef")
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "$.items[1]")).should eq("b")
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "$.missing")).should be_nil
  end

  it "auto-detects the first Set-Cookie as the token location" do
    loc = Q::Extract.autodetect(response(HEAD, BODY))
    loc.not_nil!.kind.should eq(Q::ExtractKind::Cookie)
    loc.not_nil!.selector.should eq("theme")
    Q::Extract.candidate_cookies(response(HEAD, BODY)).should eq(["theme", "SESSIONID"])
  end

  it "returns nil for an errored result" do
    err = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 0_i64, "connection refused")
    Q::Extract.extract(err, Q::TokenLoc.cookie("SESSIONID")).should be_nil
  end
end
