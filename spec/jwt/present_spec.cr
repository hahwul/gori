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
end
