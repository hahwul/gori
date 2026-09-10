require "../spec_helper"
require "../support/probe_harness"
require "json"
require "base64"

# `Jwt::Jwe` — recognizing an ENCRYPTED JWT and reading its protected header, plus the sweep
# that matters more than the recognizer itself: every projection DERIVED from "this is a JWT"
# has to refuse a JWE rather than read its second segment (a wrapped key) as claims.

private def b64(s : String | Bytes) : String
  Base64.urlsafe_encode(s, padding: false)
end

# A structurally real JWE: a protected header plus four opaque segments. Nothing here decrypts,
# so the ciphertext bytes only have to be base64url.
private def jwe_token(alg = "RSA-OAEP", enc = "A256GCM", kid : String? = "key-1",
                      encrypted_key = "d3JhcHBlZC1rZXk") : String
  header = {"alg" => alg, "enc" => enc}
  header["kid"] = kid if kid
  [b64(header.to_json), encrypted_key, b64("iv-0123456789"), b64("ciphertext-bytes"), b64("tag-0123456789ab")].join('.')
end

describe Gori::Jwt::Jwe do
  describe ".parse" do
    it "recognizes the five-part shape and reads the protected header" do
      p = Gori::Jwt::Jwe.parse(jwe_token).not_nil!
      p.alg.should eq("RSA-OAEP")
      p.enc.should eq("A256GCM")
      p.kid.should eq("key-1")
      p.wrapped_key?.should be_true
    end

    it "accepts an empty encrypted-key segment (alg=dir carries no wrapped key)" do
      p = Gori::Jwt::Jwe.parse(jwe_token(alg: "dir", enc: "A128CBC-HS256", encrypted_key: "")).not_nil!
      p.wrapped_key?.should be_false
    end

    it "refuses a five-part blob whose header declares no `enc`" do
      # `enc` is the discriminator, not the dot count: RFC 7516 §4.1.2 requires it in a JWE and
      # no JWS defines it. Five dotted base64url words are otherwise just five dotted words.
      token = [b64(%({"alg":"RSA-OAEP"})), "a", "b", "c", "d"].join('.')
      Gori::Jwt::Jwe.parse(token).should be_nil
      Gori::Jwt.jose?(token).should be_false
    end

    it "refuses a JWS" do
      jws = Gori::Jwt.encode("{}", %({"s":1}), "HS256", "k")
      Gori::Jwt::Jwe.parse(jws).should be_nil
    end

    it "never raises on garbage" do
      ["", "....", "a.b.c.d.e", "eyJ.....", "%%%%.%.%.%.%"].each do |s|
        Gori::Jwt::Jwe.parse(s).should be_nil
      end
    end
  end

  describe ".render" do
    it "shows the header and says the claims are encrypted, without inventing one" do
      out = Gori::Jwt::Jwe.render(Gori::Jwt::Jwe.parse(jwe_token).not_nil!)
      out.should contain(%("enc": "A256GCM"))
      out.should contain("ENCRYPTED")
      out.should contain("gori does not decrypt")
      out.should_not contain("payload\n{")
    end
  end
end

describe "JWE across the derived projections" do
  it "is a JOSE token to the locator but never a JWS to the claim readers" do
    token = jwe_token
    Gori::Jwt.jose?(token).should be_true
    Gori::Jwt.jwt?(token).should be_false
  end

  it "decode_json marks it encrypted instead of reporting a null payload" do
    # The old shape would have base64-decoded the WRAPPED KEY as the payload segment and
    # emitted `payload: null` — which reads as "unparseable", not "there is a key here".
    j = JSON.parse(Gori::Jwt.decode_json(jwe_token))
    j["type"].as_s.should eq("JWE")
    j["alg"].as_s.should eq("RSA-OAEP")
    j["enc"].as_s.should eq("A256GCM")
    j["payload"].raw.should be_nil
    j["encrypted"].as_bool.should be_true
    j["ciphertext"].as_s.should_not be_empty
  end

  it "keeps the JWS shape discriminated by the same field" do
    j = JSON.parse(Gori::Jwt.decode_json(Gori::Jwt.encode("{}", %({"s":1}), "HS256", "k")))
    j["type"].as_s.should eq("JWS")
    j["signed"].as_bool.should be_true
  end

  it "generates NO attack payloads" do
    # Every gate in `attacks` would pass on a JWE (five segments, a decodable header) and then
    # splice its wrapped key in as the claims segment.
    Gori::Jwt.attacks(jwe_token).should be_empty
  end

  it "verify says there is no signature, not that the alg is unsupported" do
    v = Gori::Jwt.verify(jwe_token, "any-key")
    v.verified.should be_false
    v.reason.not_nil!.should contain("JWE")
    v.reason.not_nil!.should contain("not a signature")
  end

  it "the decoder codec renders it rather than warning about extra segments" do
    out = Gori::Decoder::Codecs.jwt_decode(jwe_token.to_slice)
    out.should contain("JWE (encrypted JWT)")
    out.should_not contain("extra segment")
  end

  it "a five-part blob that is NOT a JWE still gets the extra-segments warning" do
    token = [b64(%({"alg":"HS256"})), b64(%({"s":1})), "sig", "extra", "more"].join('.')
    out = Gori::Decoder::Codecs.jwt_decode(token.to_slice)
    out.should contain("extra segment")
    out.should contain("declares no `enc`")
  end

  it "Pretty renders a JWE body as its header, labelled as encrypted" do
    r = Gori::Pretty.format(nil, jwe_token.to_slice).not_nil!
    r.note.should contain("jwe")
    String.new(r.bytes).should contain(%("enc": "A256GCM"))
  end

  it "from_flow finds one in an Authorization header and briefs it as encrypted" do
    head = "GET / HTTP/1.1\r\nHost: a.test\r\nAuthorization: Bearer #{jwe_token}\r\n\r\n"
    found = Gori::Jwt.from_flow("/", head.to_slice, nil, nil, nil)
    found.size.should eq(1)
    found[0].token.should eq(jwe_token)
    found[0].brief.not_nil!.should contain("enc A256GCM")
    found[0].brief.not_nil!.should contain("encrypted")
  end

  it "from_flow finds one embedded in a body" do
    body = %({"id_token":"#{jwe_token}"})
    found = Gori::Jwt.from_flow("/", nil, nil, nil, body.to_slice)
    found.map(&.token).should contain(jwe_token)
  end
end

describe "Jwt.narrow" do
  it "keeps a three-part token that a greedy scan over-matched" do
    # SCAN_RE runs to five segments so a JWE matches whole; the cost is that a JWS ending a
    # sentence ("…a.b.c.Next") comes back with a fourth segment glued on. That token must
    # still be found, not dropped for failing the JOSE shape.
    jws = Gori::Jwt.encode("{}", %({"s":1}), "HS256", "k")
    Gori::Jwt.narrow("#{jws}.Next").should eq(jws)
  end

  it "returns a genuine JWE whole rather than its first three segments" do
    Gori::Jwt.narrow(jwe_token).should eq(jwe_token)
  end

  it "is nil when there is no token in the match at all" do
    Gori::Jwt.narrow("eyJ.notjson.x").should be_nil
  end

  it "still finds a token in a body that a period follows" do
    jws = Gori::Jwt.encode("{}", %({"s":1}), "HS256", "k")
    found = Gori::Jwt.from_flow("/", nil, nil, nil, "the token is #{jws}.Trailing here".to_slice)
    found.map(&.token).should contain(jws)
  end
end

describe "the passive JWT rule and a JWE" do
  it "does not report an encrypted token as signed with a non-standard algorithm" do
    # A JWE's `alg` names KEY MANAGEMENT (`RSA-OAEP`, `dir`, `ECDH-ES`). Read as a signing
    # alg it is not in KNOWN_ALGS, so every encrypted token used to raise `jwt_weak_alg`.
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        req_headers: "Authorization: Bearer #{jwe_token}\r\n")
      probe_codes_of(dets).should_not contain("jwt_weak_alg")
      probe_codes_of(dets).should_not contain("jwt_no_expiry")
    end
  end

  it "still reports a real JWS in the same position" do
    with_store do |store|
      jws = Gori::Jwt.encode(%({"alg":"XS999"}), %({"s":1}), "HS256", "k")
      # An unknown SIGNING alg is exactly what the rule is for; forcing it into the header
      # after signing is how a captured token with a bogus alg looks.
      forged = "#{Gori::Jwt.b64url(%({"alg":"XS999"}))}.#{jws.split('.')[1]}.#{jws.split('.')[2]}"
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        req_headers: "Authorization: Bearer #{forged}\r\n")
      probe_codes_of(dets).should contain("jwt_weak_alg")
    end
  end
end
