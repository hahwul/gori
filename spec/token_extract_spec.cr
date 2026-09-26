require "./spec_helper"

# `Gori::TokenExtract` — the Set-Cookie jar's date reads. Everything else in the module is pinned
# by its consumers (`bindings_spec`, `session_from_flow_spec`, the Sequencer specs); this file
# holds what belongs to no single one of them.

private def response_cookie(head : String, name : String) : String?
  subject = Gori::ExtractSubject.response(head.to_slice, nil)
  Gori::TokenExtract.extract(subject, Gori::TokenLoc.cookie(name))
end

describe Gori::TokenExtract do
  describe ".http_date?" do
    it "reads the three HTTP date forms" do
      want = Time.utc(1994, 11, 6, 8, 49, 37)
      Gori::TokenExtract.http_date?("Sun, 06 Nov 1994 08:49:37 GMT").should eq(want)
      Gori::TokenExtract.http_date?("Sunday, 06-Nov-94 08:49:37 GMT").should eq(want)
      Gori::TokenExtract.http_date?("Sun Nov  6 08:49:37 1994").should eq(want)
    end

    # Well-formed but impossible: `HTTP.parse_time` raises on each of these rather than
    # answering nil, and the origin writes them.
    it "answers nil for a date it cannot read, never raising" do
      ["Sat, 31 Feb 2026 00:00:00 GMT", "Mon, 00 Jan 2026 00:00:00 GMT",
       "Mon, 01 Jan 2026 25:00:00 GMT", "Mon, 01 Jan 0000 00:00:00 GMT",
       "Mon, 01 Jan 99999 00:00:00 GMT", "Mon, 01 Jan 2026 00:00:00 +9999",
       "soon", ""].each do |bad|
        Gori::TokenExtract.http_date?(bad).should be_nil
      end
    end
  end

  describe "Set-Cookie dates" do
    # The `Date` header is read for every cookie lookup, even one whose cookie has no `Expires`.
    it "falls back to now on an impossible Date instead of raising" do
      head = "HTTP/1.1 200 OK\r\nDate: Sat, 31 Feb 2026 00:00:00 GMT\r\nSet-Cookie: sid=abc; Path=/\r\n\r\n"
      response_cookie(head, "sid").should eq("abc")
    end

    it "still expires a past Expires against now when the Date is unreadable" do
      head = "HTTP/1.1 200 OK\r\nDate: Mon, 01 Jan 2026 25:00:00 GMT\r\n" \
             "Set-Cookie: sid=old; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n"
      response_cookie(head, "sid").should be_nil
    end

    # RFC 6265 §5.2.1: an `Expires` that fails to parse is ignored, so the cookie is kept.
    it "ignores an impossible Expires" do
      head = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc; Expires=Mon, 00 Jan 2026 00:00:00 GMT\r\n\r\n"
      response_cookie(head, "sid").should eq("abc")
    end
  end
end
