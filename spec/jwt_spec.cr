require "./spec_helper"

private TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0.x"

# A value pasted straight from a header (`Bearer <t>`) decoded `Bearer eyJ…` as the header
# segment, which then read as undecodable.
describe "Gori::Jwt.locate" do
  it "leaves a bare token as it is" do
    Gori::Jwt.locate(TOKEN).should eq(TOKEN)
    Gori::Jwt.locate(" #{TOKEN}\n").should eq(TOKEN)
  end

  it "takes the token out of an Authorization or Cookie value" do
    Gori::Jwt.locate("Bearer #{TOKEN}").should eq(TOKEN)
    Gori::Jwt.locate("session=#{TOKEN}; Path=/").should eq(TOKEN)
  end

  it "returns a value with no token unchanged, for the caller's refusal" do
    Gori::Jwt.locate("Bearer nothing-here").should eq("Bearer nothing-here")
  end

  it "leaves a malformed bare token whole, rather than decoding its claims as the header" do
    Gori::Jwt.locate("xyz.eyJzdWIiOiIxIn0.sig").should eq("xyz.eyJzdWIiOiIxIn0.sig")
  end
end
