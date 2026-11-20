require "../spec_helper"
require "../support/jose_keys"

describe Gori::Jwt do
  describe ".crack" do
    %w[HS256 HS384 HS512].each do |alg|
      it "finds the #{alg} secret and counts only candidates actually tried" do
        token = Gori::Jwt.encode("{}", %({"sub":"1"}), alg, "custom-key")
        result = Gori::Jwt.crack(token, ["wrong", "custom-key", "unused"])
        result.secret.should eq("custom-key")
        result.tried.should eq(2)
        result.stopped.should be_false
        Gori::Jwt.verify(token, result.secret.not_nil!).verified.should be_true
      end
    end

    it "reports a miss and supports the empty secret as a hit" do
      token = Gori::Jwt.encode("{}", "{}", "HS256", "")
      miss = Gori::Jwt.crack(token, ["x", "y"])
      miss.secret.should be_nil
      miss.tried.should eq(2)
      hit = Gori::Jwt.crack(token, ["x", ""])
      hit.secret.should eq("")
      hit.tried.should eq(2)
    end

    it "refuses asymmetric, unsigned, encrypted and malformed tokens before searching" do
      rsa = Gori::Jwt.encode("{}", "{}", "RS256", JoseKeys::RSA)
      expect_raises(Gori::Jwt::ForgeError, "only HS256/HS384/HS512") { Gori::Jwt.crack(rsa, ["x"]) }
      none = Gori::Jwt.encode("{}", "{}", "none", "")
      expect_raises(Gori::Jwt::ForgeError, "UNSIGNED") { Gori::Jwt.crack(none, [""]) }
      jwe = "#{Gori::Jwt.b64url(%({"alg":"dir","enc":"A256GCM"}))}.a.b.c.d"
      expect_raises(Gori::Jwt::ForgeError, "JWE") { Gori::Jwt.crack(jwe, ["x"]) }
      token = Gori::Jwt.encode("{}", "{}", "HS256", "x")
      ["not-a-token", "#{token}.extra", "#{token.rpartition('.')[0]}.%%%", "#{token.rpartition('.')[0]}.YQ"].each do |bad|
        expect_raises(Gori::Jwt::ForgeError) { Gori::Jwt.crack(bad, ["x"]) }
      end
    end

    it "keeps signing input bytes and accepts an equivalent padded signature" do
      input = "#{Gori::Jwt.b64url(%({ "alg": "HS256" }))}.#{Gori::Jwt.b64url(%({ "sub": 1 }))}"
      sig = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "literal", input)
      Gori::Jwt.crack("#{input}.#{Base64.strict_encode(sig)}", ["literal"]).secret.should eq("literal")
    end

    it "yields and stops during a search without claiming a complete miss" do
      token = Gori::Jwt.encode("{}", "{}", "HS512", "last")
      stop = false
      spawn { stop = true }
      result = Gori::Jwt.crack(token, Array.new(10_000, "wrong"), stop: -> { stop })
      result.stopped.should be_true
      result.tried.should be > 0
      result.tried.should be < 10_000
      result.secret.should be_nil
    end
  end
end
