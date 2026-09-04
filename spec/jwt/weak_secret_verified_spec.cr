require "../spec_helper"
require "base64"
require "json"
require "openssl/hmac"

# `--attacks` re-signs the token under each dictionary key and told the operator "verifies if
# the server's HMAC key is X" — for all twelve keys, including the one whose signature it had
# just reproduced byte for byte. gori held the proof that the key was recovered and offered it
# as a payload to go try. `Attack#verified` says it instead.
#
# The check is a REAL verification over the ORIGINAL `header_seg.payload_seg` under the token's
# DECLARED alg — not a compare of the generated token against the input, which would miss any
# token whose header gori does not happen to re-serialize byte-identically, and not under
# `weak_secret_alg`'s HS256 fallback, which would let an HMAC coincidence over an RS256
# signature read as a recovered key.

private def b64(s : String) : String
  Base64.urlsafe_encode(s, padding: false)
end

private ALGO = {
  "HS256" => OpenSSL::Algorithm::SHA256,
  "HS384" => OpenSSL::Algorithm::SHA384,
  "HS512" => OpenSSL::Algorithm::SHA512,
}

private def token_for(header_json : String, payload_json : String, alg : String, secret : String) : String
  input = "#{b64(header_json)}.#{b64(payload_json)}"
  sig = Base64.urlsafe_encode(OpenSSL::HMAC.digest(ALGO[alg], secret, input), padding: false)
  "#{input}.#{sig}"
end

private def weak_rows(token : String)
  Gori::Jwt.attacks(token).select { |a| a.category == "weak-secret" }
end

describe "Jwt.attacks · a weak key that is THIS token's key" do
  it "marks the one dictionary key that reproduces the token's own signature" do
    rows = weak_rows(token_for(%({"alg":"HS256","typ":"JWT"}), %({"sub":"1"}), "HS256", "secret"))
    verified = rows.select(&.verified)
    verified.size.should eq(1)
    verified[0].name.should eq("HS256 secret=secret")
    verified[0].note.should contain("SECRET FOUND")
    # …and says what to DO with it, which is the whole reason the finding is worth a field.
    verified[0].note.should contain("--encode --secret secret")
  end

  it "leaves every other key a probe, with the note it always had" do
    rows = weak_rows(token_for(%({"alg":"HS256","typ":"JWT"}), %({"sub":"1"}), "HS256", "secret"))
    rows.reject(&.verified).each do |a|
      a.note.should start_with("verifies if the server's HMAC key is")
      a.note.should_not contain("SECRET FOUND")
    end
  end

  it "marks nothing for a token signed with a key outside the dictionary" do
    rows = weak_rows(token_for(%({"alg":"HS256","typ":"JWT"}), %({"sub":"1"}), "HS256",
      "Zg9-correct-horse-battery-staple"))
    rows.count(&.verified).should eq(0)
  end

  it "verifies under HS384/HS512 too, not only the HS256 the dictionary defaults to" do
    {"HS384", "HS512"}.each do |alg|
      rows = weak_rows(token_for(%({"alg":"#{alg}","typ":"JWT"}), %({"sub":"1"}), alg, "admin"))
      verified = rows.select(&.verified)
      verified.size.should eq(1)
      verified[0].name.should eq("#{alg} secret=admin")
    end
  end

  it "verifies over the ORIGINAL header bytes, not gori's re-serialization of them" do
    # `typ` BEFORE `alg`, and a space after each colon: `header.dup.to_json` re-emits this
    # compactly in its own order, so a generated-token compare would find no match. The
    # signature is over these bytes, and so is the check.
    odd = %({"typ": "JWT", "alg": "HS256"})
    rows = weak_rows(token_for(odd, %({"sub":"1"}), "HS256", "admin"))
    rows.count(&.verified).should eq(1)
  end

  it "claims nothing for a NON-HMAC token, where an HS256 match would be a coincidence" do
    # `weak_secret_alg` falls back to HS256 for an RS256 token — right for generating a
    # downgrade probe, wrong for claiming a key. The signature segment here IS the HS256
    # MAC of "" over the signing input, so a check that ignored the declared alg would call
    # this a recovered key; the real server signs RSA and that says nothing.
    header = %({"alg":"RS256","typ":"JWT"})
    input = "#{b64(header)}.#{b64(%({"sub":"1"}))}"
    sig = Base64.urlsafe_encode(OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "", input), padding: false)
    weak_rows("#{input}.#{sig}").count(&.verified).should eq(0)
  end

  it "claims nothing when there is no signature to check a key against" do
    input = "#{b64(%({"alg":"HS256","typ":"JWT"}))}.#{b64(%({"sub":"1"}))}"
    weak_rows("#{input}.").count(&.verified).should eq(0) # alg=none-shaped: empty segment
    weak_rows(input).count(&.verified).should eq(0)       # 2-part token
  end

  it "rides in the JSON every consumer reads — CLI --format json and MCP jwt_attacks" do
    rows = weak_rows(token_for(%({"alg":"HS256","typ":"JWT"}), %({"sub":"1"}), "HS256", "secret"))
    json = JSON.parse(Gori::Jwt.attacks_json(rows)).as_a
    # On EVERY row, so a consumer can `select(.verified)` instead of matching the note prose.
    json.all? { |o| o.as_h.has_key?("verified") }.should be_true
    json.count { |o| o["verified"].as_bool }.should eq(1)
  end

  it "is marked in the CLI's text row, which is the surface an operator actually reads" do
    rows = weak_rows(token_for(%({"alg":"HS256","typ":"JWT"}), %({"sub":"1"}), "HS256", "secret"))
    found = rows.find(&.verified).not_nil!
    Gori::CLI::Output.jwt_attack_text(found).should contain("✓ SECRET FOUND")
    other = rows.find { |a| !a.verified }.not_nil!
    Gori::CLI::Output.jwt_attack_text(other).should_not contain("✓")
  end
end
