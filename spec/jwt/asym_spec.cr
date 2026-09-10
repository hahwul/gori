require "../spec_helper"
require "../support/jose_keys"
require "base64"
require "file_utils"

# `Jwt::Asym` — RS/PS/ES/EdDSA signing and verification over the OpenSSL FFI, plus the
# routing `Jwt.sign` / `Jwt.verify` do on top of it.
#
# What can and cannot be asserted here is decided by the algorithms: ECDSA and RSA-PSS are
# RANDOMIZED, so there is no known-answer test for signing them — only "the signature this
# run produced verifies" and "a tampered input does not". Ed25519 is deterministic, so its
# RFC 8037 Appendix A.4 vector IS a byte-exact answer, and it is the anchor that proves the
# digest-sign path is wired to the right primitive and not merely self-consistent.
private def b64url_decode(seg : String) : Bytes
  Base64.decode(seg)
end

describe Gori::Jwt::Asym do
  describe "sign + verify round-trip" do
    {
      {"RS256", JoseKeys::RSA, JoseKeys::RSA_PUB},
      {"RS384", JoseKeys::RSA, JoseKeys::RSA_PUB},
      {"RS512", JoseKeys::RSA, JoseKeys::RSA_PUB},
      {"PS256", JoseKeys::RSA, JoseKeys::RSA_PUB},
      {"PS384", JoseKeys::RSA, JoseKeys::RSA_PUB},
      {"PS512", JoseKeys::RSA, JoseKeys::RSA_PUB},
      {"ES256", JoseKeys::EC256, JoseKeys::EC256_PUB},
      {"ES384", JoseKeys::EC384, JoseKeys::EC384_PUB},
      {"ES512", JoseKeys::EC521, JoseKeys::EC521_PUB},
      {"EdDSA", JoseKeys::ED25519, JoseKeys::ED25519_PUB},
    }.each do |(alg, priv, pub)|
      it "#{alg}: a token signed with the private key verifies with the public one" do
        token = Gori::Jwt.encode(%({"typ":"JWT"}), %({"sub":"42"}), alg, priv)
        v = Gori::Jwt.verify(token, pub)
        v.alg.should eq(alg)
        v.verified.should be_true
        v.reason.should be_nil
      end

      it "#{alg}: a tampered payload does not verify" do
        token = Gori::Jwt.encode(%({"typ":"JWT"}), %({"sub":"42"}), alg, priv)
        h, _, sig = token.split('.')
        tampered = "#{h}.#{Gori::Jwt.b64url(%({"sub":"root"}))}.#{sig}"
        Gori::Jwt.verify(tampered, pub).verified.should be_false
      end
    end
  end

  describe "the JOSE wire form of an ECDSA signature" do
    # RFC 7518 §3.4: r and s as FIXED-WIDTH big-endian octet strings, concatenated — not the
    # DER SEQUENCE OpenSSL emits. ES512 is the one that catches people out: P-521 is 66 bytes
    # per component, so 132, not 128. Signing is randomized, so this runs enough times to
    # catch the short-r case (a DER INTEGER drops leading zero bytes ~1 time in 256).
    {
      {"ES256", JoseKeys::EC256, 64},
      {"ES384", JoseKeys::EC384, 96},
      {"ES512", JoseKeys::EC521, 132},
    }.each do |(alg, priv, width)|
      it "#{alg} is exactly #{width} raw bytes, every time" do
        20.times do
          sig = Gori::Jwt.sign("eyJ.eyJ", alg, priv)
          b64url_decode(sig).size.should eq(width)
        end
      end
    end

    it "round-trips DER <-> r||s, including a component with a leading zero" do
      # A `r` whose top byte is zero is the case a naive `der[4, 32]` slice gets wrong.
      raw = Bytes.new(64)
      raw[1] = 0x7f_u8  # r = 0x007f00…  (leading zero byte, no DER sign pad)
      raw[32] = 0xff_u8 # s = 0xff00…    (high bit set, DER must pad with 0x00)
      der = Gori::Jwt::Asym.raw_to_der(raw, 32)
      der[0].should eq(0x30)
      Gori::Jwt::Asym.der_to_raw(der, 32).should eq(raw)
    end

    it "refuses a DER blob that is not a SEQUENCE" do
      expect_raises(Gori::Jwt::ForgeError, /DER SEQUENCE/) do
        Gori::Jwt::Asym.der_to_raw(Bytes[0x02, 0x01, 0x00], 32)
      end
    end

    it "reports a signature of the wrong width as 'does not verify', not as an error" do
      # A truncated ES256 signature is a legitimate thing to find on the wire. The answer is
      # no, not a raise into the render path.
      token = Gori::Jwt.encode("{}", %({"s":1}), "ES256", JoseKeys::EC256)
      h, p, _ = token.split('.')
      Gori::Jwt.verify("#{h}.#{p}.#{Gori::Jwt.b64url(Bytes.new(63))}", JoseKeys::EC256_PUB).verified.should be_false
    end
  end

  describe "EdDSA" do
    it "reproduces the RFC 8037 A.4 signature byte for byte" do
      # Ed25519 is deterministic, so this is a real known-answer test — the one assertion in
      # this file that would catch a digest-sign path that is wrong but self-consistent.
      sig = Gori::Jwt.sign(JoseKeys::ED25519_KAT_INPUT, "EdDSA", JoseKeys::ED25519)
      sig.should eq(JoseKeys::ED25519_KAT_SIGNATURE)
    end

    it "verifies the RFC 8037 A.4 signature with the published public key" do
      token = "#{JoseKeys::ED25519_KAT_INPUT}.#{JoseKeys::ED25519_KAT_SIGNATURE}"
      Gori::Jwt.verify(token, JoseKeys::ED25519_PUB).verified.should be_true
    end
  end

  describe "PS* really is PSS" do
    it "produces a signature a PKCS#1 verifier rejects" do
      # Omitting the padding ctrl makes OpenSSL sign PKCS#1 v1.5 SILENTLY — a valid RS256
      # signature under a PS256 header, which no real verifier accepts and no error reports.
      # The two families over one key are the only local way to tell them apart.
      input = "eyJ.eyJ"
      ps = b64url_decode(Gori::Jwt.sign(input, "PS256", JoseKeys::RSA))
      rs = b64url_decode(Gori::Jwt.sign(input, "RS256", JoseKeys::RSA))
      Gori::Jwt::Asym.verify(input, "PS256", ps, JoseKeys::RSA_PUB).should be_true
      Gori::Jwt::Asym.verify(input, "RS256", ps, JoseKeys::RSA_PUB).should be_false
      Gori::Jwt::Asym.verify(input, "RS256", rs, JoseKeys::RSA_PUB).should be_true
      Gori::Jwt::Asym.verify(input, "PS256", rs, JoseKeys::RSA_PUB).should be_false
    end
  end

  describe "key input" do
    it "reads a key from a file path as well as inline PEM" do
      dir = File.tempname("gori-spec-jose")
      Dir.mkdir_p(dir)
      begin
        path = JoseKeys.write(dir, "ec256.pem", JoseKeys::EC256)
        pub = JoseKeys.write(dir, "ec256.pub.pem", JoseKeys::EC256_PUB)
        token = Gori::Jwt.encode("{}", %({"s":1}), "ES256", path)
        Gori::Jwt.verify(token, pub).verified.should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "verifies with a CERTIFICATE, not only a bare public key" do
      # An IdP publishes an x5c chain as often as a JWK; making the operator extract the
      # SPKI half by hand would be the sharp edge this feature exists to remove.
      token = Gori::Jwt.encode("{}", %({"s":1}), "RS256", JoseKeys::RSA)
      Gori::Jwt.verify(token, JoseKeys::RSA_CERT).verified.should be_true
    end

    it "verifies with the PRIVATE key too" do
      token = Gori::Jwt.encode("{}", %({"s":1}), "ES256", JoseKeys::EC256)
      Gori::Jwt.verify(token, JoseKeys::EC256).verified.should be_true
    end

    it "refuses to SIGN with a public key" do
      expect_raises(Gori::Jwt::ForgeError, /PRIVATE/) do
        Gori::Jwt.encode("{}", "{}", "ES256", JoseKeys::EC256_PUB)
      end
    end

    it "resolves a --key PATH to its PEM text even for an HMAC alg" do
      # `sign` reaches HMAC_DIGEST before it reaches Asym, so an unresolved key path would
      # HMAC-sign the PATH STRING and report a token signed with a filename — the silent
      # wrong result. Resolved, `HS256` + a public key IS the algorithm-confusion token.
      dir = File.tempname("gori-spec-jose")
      Dir.mkdir_p(dir)
      begin
        path = JoseKeys.write(dir, "rsa.pub.pem", JoseKeys::RSA_PUB)
        material = Gori::Jwt.key_material("", path)
        material.should eq(JoseKeys::RSA_PUB)
        token = Gori::Jwt.encode("{}", %({"s":1}), "HS256", material)
        Gori::Jwt.verify(token, JoseKeys::RSA_PUB).verified.should be_true
        # ...and NOT with the path, which is what the bug produced.
        Gori::Jwt.verify(token, path).verified.should be_false
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "key_material leaves a --secret literal alone and refuses a --key that is not a PEM" do
      Gori::Jwt.key_material("./looks/like/a/path", nil).should eq("./looks/like/a/path")
      Gori::Jwt.key_material("s3cret", "").should eq("s3cret")
      expect_raises(Gori::Jwt::ForgeError) { Gori::Jwt.key_material("", "s3cret") }
    end

    it "refuses a key path carrying a NUL byte instead of leaking an ArgumentError" do
      # `File.file?` raises ArgumentError, which is NOT an IO::Error, so it escaped every
      # caller's `rescue ForgeError` — reaching MCP's blanket rescue as INTERNAL ("gori is
      # broken") for a mistake in the caller's own argument, and crashing the TUI's JWT tab.
      ex = expect_raises(Gori::Jwt::ForgeError, /NUL byte/) do
        Gori::Jwt::Asym.pem_for("a#{0_u8.unsafe_chr}b")
      end
      ex.message.not_nil!.should_not contain("ArgumentError")
    end

    it "never echoes the key spec back in an error" do
      # Org rule and plain sense: an operator who passes an HMAC secret to an asymmetric alg
      # must not read their own key material out of the message (or out of a captured log).
      ex = expect_raises(Gori::Jwt::ForgeError) { Gori::Jwt.sign("a.b", "ES256", "hunter2-not-a-path") }
      ex.message.not_nil!.should_not contain("hunter2")
    end
  end

  describe "alg / key mismatch" do
    it "names the key type rather than emitting an unverifiable signature" do
      expect_raises(Gori::Jwt::ForgeError, /ES256 needs an EC key \(this key is RSA\)/) do
        Gori::Jwt.sign("a.b", "ES256", JoseKeys::RSA)
      end
      expect_raises(Gori::Jwt::ForgeError, /RS256 needs an RSA key \(this key is EC\)/) do
        Gori::Jwt.sign("a.b", "RS256", JoseKeys::EC256)
      end
      expect_raises(Gori::Jwt::ForgeError, /EdDSA needs an Ed25519 key/) do
        Gori::Jwt.sign("a.b", "EdDSA", JoseKeys::EC256)
      end
    end

    it "names the curve when the family is right but the size is not" do
      # An ES256 signature over a P-384 key would be 96 bytes wide under a header claiming
      # 64 — structurally a token, verifiable by nothing.
      # "a 384-bit curve", not "P-384": the check measures the WIDTH, so naming a NIST curve
      # would be a claim it never made (a brainpoolP384r1 key is not P-384).
      expect_raises(Gori::Jwt::ForgeError, /ES256 needs a P-256 curve \(this key is a 384-bit curve\)/) do
        Gori::Jwt.sign("a.b", "ES256", JoseKeys::EC384)
      end
    end
  end

  describe "Jwt::ALGS" do
    it "offers every asymmetric family plus HMAC and none" do
      Gori::Jwt::ALGS.first(3).should eq(%w[HS256 HS384 HS512])
      Gori::Jwt::ALGS.last.should eq("none")
      %w[RS256 PS256 ES256 ES512 EdDSA].each { |a| Gori::Jwt::ALGS.should contain(a) }
    end

    it "keeps HMAC_DIGEST symmetric-only" do
      # `attacks.cr` gates its "SECRET FOUND" claim on `HMAC_DIGEST.has_key?`. An asymmetric
      # alg in this map would turn an HMAC coincidence over an RSA signature into a claim
      # that gori had recovered the server's key.
      Gori::Jwt::HMAC_DIGEST.keys.sort!.should eq(%w[HS256 HS384 HS512])
    end
  end

  describe "Jwt.verify" do
    it "uses the alg the TOKEN declares, not one the caller picks" do
      # The question is "would a server holding this key accept this token", and that server
      # reads the alg off the wire too.
      token = Gori::Jwt.encode(%({"alg":"HS512"}), %({"s":1}), "HS512", "k")
      Gori::Jwt.verify(token, "k").alg.should eq("HS512")
    end

    it "answers no with a reason for an unsigned token instead of raising" do
      token = Gori::Jwt.encode("{}", %({"s":1}), "none", "")
      v = Gori::Jwt.verify(token, "anything")
      v.verified.should be_false
      v.reason.not_nil!.should contain("UNSIGNED")
    end

    it "answers no with a reason for an alg it cannot check" do
      # ES256K is real in the wild and not implemented here; saying so beats a false "no".
      token = "#{Gori::Jwt.b64url(%({"alg":"ES256K"}))}.#{Gori::Jwt.b64url("{}")}.AAAA"
      v = Gori::Jwt.verify(token, "k")
      v.verified.should be_false
      v.reason.not_nil!.should contain("cannot verify")
    end

    it "refuses a token that carries segments past the signature" do
      # `header.payload.sig.SMUGGLED` verified TRUE: the HMAC over parts[0..1] matches
      # parts[2] and the fourth segment was dropped on the floor, so gori vouched for a token
      # no server would accept.
      token = Gori::Jwt.encode("{}", %({"s":1}), "HS256", "k")
      v = Gori::Jwt.verify("#{token}.SMUGGLED", "k")
      v.verified.should be_false
      v.reason.not_nil!.should contain("4 dot-separated segments")
    end

    it "does not treat a garbage signature segment as an error" do
      token = Gori::Jwt.encode("{}", %({"s":1}), "HS256", "k")
      h, p, _ = token.split('.')
      Gori::Jwt.verify("#{h}.#{p}.!!!not-base64!!!", "k").verified.should be_false
    end
  end

  describe "the algorithm-confusion family" do
    it "appears only with a public key, and only for an asymmetric token" do
      rs = Gori::Jwt.encode("{}", %({"sub":"a"}), "RS256", JoseKeys::RSA)
      hs = Gori::Jwt.encode("{}", %({"sub":"a"}), "HS256", "k")
      Gori::Jwt.attacks(rs).map(&.category).should_not contain("alg-confusion")
      Gori::Jwt.attacks(rs, JoseKeys::RSA_PUB).map(&.category).should contain("alg-confusion")
      # An HS token is already HMAC — there is no asymmetric key to confuse it with.
      Gori::Jwt.attacks(hs, JoseKeys::RSA_PUB).map(&.category).should_not contain("alg-confusion")
    end

    it "HMAC-signs with the public key's own bytes, so gori can verify its own payload" do
      rs = Gori::Jwt.encode("{}", %({"sub":"a"}), "RS256", JoseKeys::RSA)
      row = Gori::Jwt.attacks(rs, JoseKeys::RSA_PUB).find! { |a| a.category == "alg-confusion" }
      Gori::Jwt.token_alg(row.token).should eq("HS256")
      # The canonical SPKI PEM is the first variant, and OpenSSL writes it with a trailing
      # newline — which is exactly why the no-newline spelling is offered beside it.
      Gori::Jwt.verify(row.token, Gori::Jwt::Asym.public_spki_pem(JoseKeys::RSA_PUB)).verified.should be_true
    end

    it "reduces a CERTIFICATE to the SPKI PEM a server would actually hold" do
      rs = Gori::Jwt.encode("{}", %({"sub":"a"}), "RS256", JoseKeys::RSA)
      rows = Gori::Jwt.attacks(rs, JoseKeys::RSA_CERT).select { |a| a.category == "alg-confusion" }
      canonical = rows.find!(&.name.includes?("canonical"))
      Gori::Jwt.verify(canonical.token, Gori::Jwt::Asym.public_spki_pem(JoseKeys::RSA_PUB)).verified.should be_true
      # ...and the cert's own bytes stay on offer, because a server may have loaded those.
      rows.map(&.name).should contain("HS256 = public key (as supplied)")
    end

    it "raises on a key that will not load rather than dropping the family in silence" do
      rs = Gori::Jwt.encode("{}", %({"sub":"a"}), "RS256", JoseKeys::RSA)
      expect_raises(Gori::Jwt::ForgeError) { Gori::Jwt.attacks(rs, "/nonexistent/key.pem") }
    end

    it "raises for a bad key whatever the token's alg is" do
      # The alg gate used to come first, so one typo raised for an RS256 token and was
      # swallowed in silence for an HS256 one — and MCP, which has no other key resolution,
      # got the silent half. The docstring promises the operator sees their typo.
      hs = Gori::Jwt.encode("{}", %({"sub":"a"}), "HS256", "k")
      expect_raises(Gori::Jwt::ForgeError) { Gori::Jwt.attacks(hs, "/nonexistent/key.pem") }
      # ...and a GOOD key on a token with no asymmetric alg to confuse still adds nothing.
      Gori::Jwt.attacks(hs, JoseKeys::RSA_PUB).map(&.category).should_not contain("alg-confusion")
    end
  end
end
