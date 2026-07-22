require "./spec_helper"
require "base64"
require "json"
require "openssl/hmac"

private def b64(s : String) : String
  Base64.urlsafe_encode(s, padding: false)
end

# A minimal HS256 token: header {"alg":"HS256","typ":"JWT"}, payload {"sub":"1","admin":false}.
private def hs256_token(secret : String) : String
  header = b64(%({"alg":"HS256","typ":"JWT"}))
  payload = b64(%({"sub":"1","admin":false}))
  input = "#{header}.#{payload}"
  sig = Base64.urlsafe_encode(OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, secret, input), padding: false)
  "#{input}.#{sig}"
end

describe Gori::Jwt do
  describe ".sign" do
    it "matches a known HS256 HMAC vector and is base64url with no padding" do
      sig = Gori::Jwt.sign("a.b", "HS256", "secret")
      expected = Base64.urlsafe_encode(OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "secret", "a.b"), padding: false)
      sig.should eq(expected)
      sig.should_not contain("=")
    end

    it "returns an empty signature for alg=none" do
      Gori::Jwt.sign("a.b", "none", "irrelevant").should eq("")
    end

    it "raises ForgeError on an unsupported alg" do
      expect_raises(Gori::Jwt::ForgeError, /unsupported alg/) do
        Gori::Jwt.sign("a.b", "RS256", "k")
      end
    end
  end

  describe ".encode" do
    it "round-trips: an encoded token verifies with the same secret" do
      tok = Gori::Jwt.encode(%({"typ":"JWT"}), %({"sub":"42"}), "HS256", "s3cr3t")
      header, payload, sig = tok.split('.')
      # alg is forced into the header even though the input header omitted it.
      JSON.parse(String.new(Base64.decode(header)))["alg"].should eq("HS256")
      JSON.parse(String.new(Base64.decode(payload)))["sub"].should eq("42")
      recomputed = Gori::Jwt.sign("#{header}.#{payload}", "HS256", "s3cr3t")
      sig.should eq(recomputed)
    end

    it "produces an unsigned token (empty 3rd segment) for alg=none" do
      tok = Gori::Jwt.encode(%({}), %({"sub":"x"}), "none", "")
      tok.ends_with?('.').should be_true
      tok.split('.').size.should eq(3)
    end

    it "raises ForgeError on invalid header JSON" do
      expect_raises(Gori::Jwt::ForgeError, /header/) do
        Gori::Jwt.encode("not json", %({}), "HS256", "k")
      end
    end

    it "raises ForgeError when the header is not a JSON object" do
      expect_raises(Gori::Jwt::ForgeError, /object/) do
        Gori::Jwt.encode(%(["a"]), %({}), "HS256", "k")
      end
    end
  end

  describe ".attacks" do
    it "returns an empty list for a non-JWT string" do
      Gori::Jwt.attacks("plainstring").should be_empty       # 1 segment
      Gori::Jwt.attacks("notbase64.alsonot").should be_empty # 2 segments, header not a JSON object
    end

    it "generates the alg:none case variants with an empty signature" do
      attacks = Gori::Jwt.attacks(hs256_token("k"))
      none = attacks.select(&.category.== "none")
      none.map(&.name).should contain("alg=none")
      none.map(&.name).should contain("alg=nOnE")
      # every none-family 3-part token has an empty final segment
      none.each do |a|
        parts = a.token.split('.')
        parts[2].should eq("") if parts.size == 3
      end
    end

    it "generates weak-secret re-signs that actually verify under that secret" do
      attacks = Gori::Jwt.attacks(hs256_token("orig"))
      weak = attacks.select(&.category.== "weak-secret")
      weak.size.should eq(Gori::Jwt::WEAK_SECRETS.size)
      # The "secret" entry must verify when the server key is "secret".
      entry = weak.find { |a| a.name == "HS256 secret=secret" }.not_nil!
      header, payload, sig = entry.token.split('.')
      Gori::Jwt.sign("#{header}.#{payload}", "HS256", "secret").should eq(sig)
    end

    it "generates header-injection tokens (kid/jku/x5u/jwk)" do
      names = Gori::Jwt.attacks(hs256_token("k")).select(&.category.== "header-inject").map(&.name)
      names.any?(&.starts_with?("kid")).should be_true
      names.any?(&.starts_with?("jku")).should be_true
      names.any?(&.starts_with?("jwk")).should be_true
    end

    it "makes the /dev/null kid verify with an empty HMAC key" do
      dn = Gori::Jwt.attacks(hs256_token("k")).find { |a| a.name == "kid=/dev/null" }.not_nil!
      header, payload, sig = dn.token.split('.')
      Gori::Jwt.sign("#{header}.#{payload}", "HS256", "").should eq(sig)
      JSON.parse(String.new(Base64.decode(header)))["kid"].as_s.should contain("dev/null")
    end
  end
end
