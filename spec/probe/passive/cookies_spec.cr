require "../../spec_helper"
require "../../support/probe_harness"

private def cookie_codes(store, cookie : String)
  probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: #{cookie}\r\n\r\n"))
end

describe Gori::Probe::Passive::Cookies do
  it "keeps live cookies scorable despite invalid or overridden deletion attributes" do
    with_store do |store|
      ["Expires=garbage", "Max-Age-ignored=0", "Max-Age=+0", "Max-Age=0; Max-Age=60",
       "Max-Age=99999999999999999999999; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
       "Max-Age=60; Expires=Thu, 01 Jan 1970 00:00:00 GMT"].each do |attributes|
        cookie_codes(store, "sid=secret; #{attributes}").should contain("cookie_no_secure")
      end
    end
  end

  it "uses the last valid Max-Age and suppresses real deletions" do
    with_store do |store|
      ["Max-Age=60; Max-Age=0", "Max-Age=0; Max-Age=bad",
       "Max-Age=-999999999999999999999999", "Expires=Thu, 01 Jan 1970 00:00:00 GMT"].each do |attributes|
        cookie_codes(store, "sid=deleted; #{attributes}").should_not contain("cookie_no_secure")
      end
    end
  end

  it "parses exact attribute names, whitespace, flag values and last SameSite" do
    with_store do |store|
      cookie_codes(store, "sid=x; SameSiteExtra=Lax").should contain("cookie_no_samesite")
      cookie_codes(store, "sid=x; SameSite = None").should contain("cookie_samesite_none_insecure")
      cookie_codes(store, "sid=x; SameSite=None; SameSite=Lax").should_not contain("cookie_samesite_none_insecure")
      cookie_codes(store, "sid=x; SameSite=Lax; SameSite=invalid").should contain("cookie_invalid_samesite")
      codes = cookie_codes(store, "sid=x; Secure=yes; HttpOnly=yes; SameSite = Strict")
      codes.should_not contain("cookie_no_secure")
      codes.should_not contain("cookie_no_httponly")
    end
  end

  it "detects CHIPS and HTTP prefix violations without exposing values" do
    with_store do |store|
      cookie_codes(store, "sid=secret; Partitioned").should contain("cookie_partitioned_insecure")
      cookie_codes(store, "sid=secret; Partitioned; Secure").should_not contain("cookie_partitioned_insecure")
      ["__Http-sid=x; Secure", "__Host-Http-sid=x; Secure; Path=/",
       "__Host-sid=x; Secure; Path=/; Path=/other"].each do |cookie|
        cookie_codes(store, cookie).should contain("cookie_prefix_violation")
      end
      ["__Http-sid=x; Secure; HttpOnly", "__Host-Http-sid=x; Secure; HttpOnly; Path=/"].each do |cookie|
        cookie_codes(store, cookie).should_not contain("cookie_prefix_violation")
      end
    end
  end
end
