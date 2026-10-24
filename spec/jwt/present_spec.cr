require "../spec_helper"

# A token's segments decode to whatever bytes its author chose — and tokens are lifted from
# captured traffic. One that is not UTF-8 used to make the whole `--json` document invalid.
private def seg(bytes : Bytes) : String
  Base64.urlsafe_encode(bytes, padding: false)
end

describe "Gori::Jwt JSON presenters" do
  it "keeps decode_json valid UTF-8 JSON when a segment is not UTF-8" do
    header = seg(Bytes[0x7b, 0x22, 0x61, 0x6c, 0x67, 0x22, 0x3a, 0x22, 0x48, 0x53, 0x32, 0x35, 0x36, 0x22,
      0x2c, 0x22, 0x78, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d]) # {"alg":"HS256","x":"\xff"}
    json = Gori::Jwt.decode_json("#{header}.e30.c2ln")
    json.valid_encoding?.should be_true
    JSON.parse(json)["header"]["x"].as_s.should eq("�")
  end

  it "names the segment that did not decode, and a pasted Bearer prefix" do
    header = seg(%({"alg":"HS256"}).to_slice)
    JSON.parse(Gori::Jwt.decode_json("#{header}.e30.c2ln"))["note"]?.should be_nil
    bad = JSON.parse(Gori::Jwt.decode_json("#{header}.!!!.c2ln"))
    bad["payload"].raw.should be_nil
    bad["note"].as_s.should start_with("payload segment is empty or not base64url-encoded JSON")
    bearer = JSON.parse(Gori::Jwt.decode_json("Bearer #{header}.e30.c2ln"))
    bearer["header"].raw.should be_nil
    bearer["note"].as_s.should contain("header segment is")
    bearer["note"].as_s.should contain("`Bearer ` prefix")
  end
end
