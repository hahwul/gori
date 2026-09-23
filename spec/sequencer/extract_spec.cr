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

  it "takes the cookie a client would hold: the LAST Set-Cookie, and none after a deletion (#1206)" do
    regen = response("HTTP/1.1 200 OK\r\n" \
                     "Set-Cookie: sid=deleted; Max-Age=0; Path=/\r\n" \
                     "Set-Cookie: sid=0f3ae760; Path=/; HttpOnly\r\n\r\n", "ok")
    Q::Extract.extract(regen, Q::TokenLoc.cookie("sid")).should eq("0f3ae760")

    replaced = response("HTTP/1.1 200 OK\r\nSet-Cookie: sid=a\r\nSet-Cookie: sid=b\r\n\r\n", "ok")
    Q::Extract.extract(replaced, Q::TokenLoc.cookie("sid")).should eq("b")

    logout = response("HTTP/1.1 200 OK\r\n" \
                      "Set-Cookie: sid=live\r\n" \
                      "Set-Cookie: sid=deleted; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n", "ok")
    Q::Extract.extract(logout, Q::TokenLoc.cookie("sid")).should be_nil

    # Max-Age outranks Expires (RFC 6265 §5.3 step 3), and an unparsable Max-Age is ignored.
    kept = response("HTTP/1.1 200 OK\r\n" \
                    "Set-Cookie: sid=x; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=60\r\n" \
                    "Set-Cookie: t=y; Max-Age=soon\r\n\r\n", "ok")
    Q::Extract.extract(kept, Q::TokenLoc.cookie("sid")).should eq("x")
    Q::Extract.extract(kept, Q::TokenLoc.cookie("t")).should eq("y")

    # `+0` is not a Max-Age (§5.2.2) and an overflowing one is a long-lived cookie.
    odd = response("HTTP/1.1 200 OK\r\n" \
                   "Set-Cookie: a=1; Max-Age=+0\r\n" \
                   "Set-Cookie: b=2; Max-Age=99999999999999999999; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\n" \
                   "Set-Cookie: c=3; Max-Age=-1\r\n\r\n", "ok")
    Q::Extract.extract(odd, Q::TokenLoc.cookie("a")).should eq("1")
    Q::Extract.extract(odd, Q::TokenLoc.cookie("b")).should eq("2")
    Q::Extract.extract(odd, Q::TokenLoc.cookie("c")).should be_nil
  end

  it "judges Expires against the response's own Date, so a stored flow reads the same later" do
    # Captured in 2001 with a cookie good for 30 minutes: still set, whatever today's date is.
    stored = response("HTTP/1.1 200 OK\r\n" \
                      "Date: Mon, 01 Jan 2001 00:00:00 GMT\r\n" \
                      "Set-Cookie: sid=abc; Expires=Mon, 01 Jan 2001 00:30:00 GMT\r\n\r\n", "ok")
    Q::Extract.extract(stored, Q::TokenLoc.cookie("sid")).should eq("abc")
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

  it "extracts a JSON path leaf when another number in the body is past Int64 (#1200)" do
    body = %({"id":18446744073709551615,"token":"deadbeef","n":[99999999999999999999]})
    r = response(HEAD, body)
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "$.token")).should eq("deadbeef")
    # The oversized number itself comes back as the digits the body carried.
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "$.id")).should eq("18446744073709551615")
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "$.n[0]")).should eq("99999999999999999999")
  end

  it "reads the path grammar Retest reads, and refuses a path it cannot resolve (#1201)" do
    r = response(HEAD, BODY)
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "items.1")).should eq("b")
    # An unclosed bracket used to be dropped, silently resolving `$.data` instead.
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "$.data[")).should be_nil
    Q::Extract.extract(r, Q::TokenLoc.new(Q::ExtractKind::JsonPath, "$..token")).should be_nil
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
