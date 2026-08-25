require "../spec_helper"
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

  describe ".patch_payload" do
    it "sets a string claim when the value is not valid JSON" do
      out = JSON.parse(Gori::Jwt.patch_payload(%({"sub":"1"}), ["role=admin"]))
      out["role"].as_s.should eq("admin")
      out["sub"].as_s.should eq("1") # existing claims are kept
    end

    it "keeps JSON types: a bare true/number stays boolean/number" do
      out = JSON.parse(Gori::Jwt.patch_payload(%({"admin":false}), ["admin=true", "n=3"]))
      out["admin"].as_bool.should be_true
      out["n"].as_i.should eq(3)
    end

    it "a quoted value forces a numeric-looking string" do
      out = JSON.parse(Gori::Jwt.patch_payload(%({}), [%(s="1")]))
      out["s"].as_s.should eq("1")
    end

    it "applies patches in order (last write wins)" do
      out = JSON.parse(Gori::Jwt.patch_payload(%({}), ["x=1", "x=2"]))
      out["x"].as_i.should eq(2)
    end

    it "sets the empty string for key= with no value" do
      out = JSON.parse(Gori::Jwt.patch_payload(%({}), ["k="]))
      out["k"].as_s.should eq("")
    end

    it "starts from {} when the base payload is blank" do
      out = JSON.parse(Gori::Jwt.patch_payload("", ["a=1"]))
      out["a"].as_i.should eq(1)
    end

    it "raises ForgeError on a patch with no '='" do
      expect_raises(Gori::Jwt::ForgeError, /key=value/) do
        Gori::Jwt.patch_payload(%({}), ["role"])
      end
    end

    it "raises ForgeError on an empty key" do
      expect_raises(Gori::Jwt::ForgeError, /empty key/) do
        Gori::Jwt.patch_payload(%({}), ["=admin"])
      end
    end

    it "raises ForgeError when the base payload is not a JSON object" do
      expect_raises(Gori::Jwt::ForgeError, /object/) do
        Gori::Jwt.patch_payload(%(["a"]), ["role=admin"])
      end
    end

    it "re-signs cleanly: patch then encode verifies" do
      patched = Gori::Jwt.patch_payload(%({"sub":"1"}), ["role=admin"])
      tok = Gori::Jwt.encode(%({"typ":"JWT"}), patched, "HS256", "s3cr3t")
      header, payload, sig = tok.split('.')
      JSON.parse(String.new(Base64.decode(payload)))["role"].should eq("admin")
      Gori::Jwt.sign("#{header}.#{payload}", "HS256", "s3cr3t").should eq(sig)
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

    it "re-signs the weak-secret family under the token's own HS alg (HS384/HS512)" do
      # An HS512 token whose weak key is 'secret' is only caught if the re-sign is HS512 —
      # a server that pins HS512 rejects an HS256 signature regardless of the key, so the old
      # hardcoded HS256 made every HS384/HS512 weak-secret payload a non-starter.
      {"HS384", "HS512"}.each do |alg|
        header_seg = b64(%({"alg":"#{alg}","typ":"JWT"}))
        payload_seg = b64(%({"sub":"1"}))
        token = "#{header_seg}.#{payload_seg}.orig-sig"
        entry = Gori::Jwt.attacks(token)
          .select(&.category.== "weak-secret")
          .find { |a| a.name == "#{alg} secret=secret" }.not_nil!
        h, p, sig = entry.token.split('.')
        # The forged header carries the token's own alg…
        JSON.parse(String.new(Base64.decode(h)))["alg"].should eq(alg)
        # …and the signature verifies under that alg with the weak key.
        Gori::Jwt.sign("#{h}.#{p}", alg, "secret").should eq(sig)
      end
    end

    it "falls the weak-secret family back to HS256 for a non-HMAC token (downgrade probe)" do
      # A none/RS/ES/PS token isn't HMAC, so there is no 'own' HS alg — HS256 is the classic
      # downgrade-to-HMAC-with-a-weak-key attempt.
      none_token = "#{b64(%({"alg":"none"}))}.#{b64(%({"sub":"1"}))}."
      names = Gori::Jwt.attacks(none_token).select(&.category.== "weak-secret").map(&.name)
      names.should contain("HS256 secret=secret")
      names.none?(&.starts_with?("HS384")).should be_true
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
