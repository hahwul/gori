require "../spec_helper"
require "json"

# cookie_verify / cookie_crack must not read a real SHA-1 Django `sessionid` as bad/uncracked
# just because the tool defaulted `algorithm` to sha256. When 'algorithm' is absent it is read
# off the cookie's own signature length (sha1 = 20 bytes, sha256 = 32); an explicit 'algorithm'
# is still validated and honored. cookie_forge, which mints and has no input cookie, keeps the
# sha256 default. See `Tools#django_algorithm_for`.

private SECRET      = "s3cr3t-key"
private DJANGO_SHA1 = "eyJhIjoxfQ:1wqR8T:8BooTFI1B28NGHSf42JyGt1Or-0" # algorithm sha1, payload {"a":1}
private DJANGO      = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9:1wqQs6:ofPm07XfGfVUimPfVs9Bdy5M7H0cxBS_265YiN3lQsY"

private def verify(tools : Gori::MCP::Tools, cookie : String, secret : String, extra : String = "")
  tools.call("cookie_verify", JSON.parse(%({"cookie":#{cookie.to_json},"secret":#{secret.to_json}#{extra}})))
end

private def crack(tools : Gori::MCP::Tools, cookie : String, secrets : Array(String), extra : String = "")
  tools.call("cookie_crack", JSON.parse(%({"cookie":#{cookie.to_json},"secrets":#{secrets.to_json}#{extra}})))
end

describe "MCP cookie_verify — Django algorithm auto-detection" do
  it "verifies a SHA-1 cookie with the right secret and NO algorithm arg" do
    with_store do |store|
      r = verify(tools_for(store), DJANGO_SHA1, SECRET)
      r.is_error.should be_false
      JSON.parse(r.text)["valid"].as_bool.should be_true
    end
  end

  it "still verifies a SHA-256 cookie with no algorithm arg" do
    with_store do |store|
      r = verify(tools_for(store), DJANGO, SECRET)
      JSON.parse(r.text)["valid"].as_bool.should be_true
    end
  end

  it "honors an explicit algorithm (a mismatched sha256 on a SHA-1 cookie stays invalid)" do
    with_store do |store|
      r = verify(tools_for(store), DJANGO_SHA1, SECRET, %(,"algorithm":"sha256"))
      JSON.parse(r.text)["valid"].as_bool.should be_false
    end
  end

  it "refuses an unsupported algorithm by name" do
    with_store do |store|
      r = verify(tools_for(store), DJANGO_SHA1, SECRET, %(,"algorithm":"sha512"))
      r.is_error.should be_true
      r.text.should contain("algorithm")
    end
  end
end

describe "MCP cookie_crack — Django algorithm auto-detection" do
  it "cracks a SHA-1 cookie's secret from an inline list with NO algorithm arg" do
    with_store do |store|
      r = crack(tools_for(store), DJANGO_SHA1, ["foo", SECRET, "bar"])
      r.is_error.should be_false
      body = JSON.parse(r.text)
      body["found"].as_bool.should be_true
      body["secret"].as_s.should eq(SECRET)
    end
  end

  it "reports no match when the algorithm is explicitly wrong" do
    with_store do |store|
      r = crack(tools_for(store), DJANGO_SHA1, ["foo", SECRET, "bar"], %(,"algorithm":"sha256"))
      JSON.parse(r.text)["found"].as_bool.should be_false
    end
  end
end
