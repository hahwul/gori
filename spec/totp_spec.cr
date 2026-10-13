require "./spec_helper"

private alias Totp = Gori::Totp

# RFC 6238 Appendix B: one seed per algorithm, the ASCII key padded to the digest size.
private SEEDS = {
  OpenSSL::Algorithm::SHA1   => "12345678901234567890",
  OpenSSL::Algorithm::SHA256 => "12345678901234567890123456789012",
  OpenSSL::Algorithm::SHA512 => "1234567890123456789012345678901234567890123456789012345678901234",
}

private VECTORS = [
  {59_i64, "94287082", "46119246", "90693936"},
  {1111111109_i64, "07081804", "68084774", "25091201"},
  {1111111111_i64, "14050471", "67062674", "99943326"},
  {1234567890_i64, "89005924", "91819424", "93441116"},
  {2000000000_i64, "69279037", "90698825", "38618901"},
  {20000000000_i64, "65353130", "77737706", "47863826"},
]

# "12345678901234567890" in base32: the RFC 4226 / RFC 6238 SHA1 seed.
private SHA1_B32 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

private def config!(value : String) : Totp::Config
  Totp.parse(value).as(Totp::Config)
end

describe Gori::Totp do
  it "matches the RFC 6238 Appendix B vectors for SHA1, SHA256 and SHA512 at 8 digits" do
    VECTORS.each do |(t, *codes)|
      SEEDS.keys.each_with_index do |algorithm, i|
        config = Totp::Config.new(SEEDS[algorithm].to_slice, 8, 30, algorithm)
        Totp.code(config, Time.unix(t)).should eq(codes[i])
      end
    end
  end

  it "matches the RFC 4226 Appendix D values at 6 digits, one per 30 s counter step" do
    expected = %w[755224 287082 359152 969429 338314 254676 287922 162583 399871 520489]
    config = Totp::Config.new(SEEDS[OpenSSL::Algorithm::SHA1].to_slice)
    expected.each_with_index do |code, counter|
      Totp.code(config, Time.unix(counter * 30_i64 + 29)).should eq(code)
    end
  end

  it "reads a bare base32 secret the way authenticator apps print it" do
    [SHA1_B32, SHA1_B32.downcase, SHA1_B32.scan(/.{4}/).map(&.[0]).join(' '), "  #{SHA1_B32}\n"].each do |text|
      config = config!(text)
      config.key.should eq(SEEDS[OpenSSL::Algorithm::SHA1].to_slice)
      {config.digits, config.period, config.algorithm}.should eq({6, 30, OpenSSL::Algorithm::SHA1})
    end
    # Unpadded: a 16-symbol secret is a whole quantum, and a 10-symbol one is not padded.
    config!("JBSWY3DPEHPK3PXP").key.size.should eq(10)
    config!("MZXW6YQ").key.should eq("foob".to_slice)
  end

  it "takes digits, period and algorithm from an otpauth://totp/ URI" do
    seed = SEEDS[OpenSSL::Algorithm::SHA256]
    b32 = Gori::Decoder::Codecs.base32_encode(seed.to_slice).rstrip('=')
    config = config!("otpauth://totp/Example:alice@example.test?secret=#{b32}&issuer=Example&digits=8&period=60&algorithm=sha256")
    {config.digits, config.period, config.algorithm}.should eq({8, 60, OpenSSL::Algorithm::SHA256})
    # Counter 1111111111 // 60 is the 30 s vector's counter / 2, so check against a direct HMAC.
    expect = Totp.code(Totp::Config.new(seed.to_slice, 8, 60, OpenSSL::Algorithm::SHA256), Time.unix(1111111111))
    Totp.code(config, Time.unix(1111111111)).should eq(expect)
    config!("OTPAUTH://TOTP/x?secret=#{SHA1_B32}").digits.should eq(6)
  end

  it "refuses what cannot be a TOTP secret, and never quotes the value" do
    secret = "Q9!#{SHA1_B32}"
    refusals = {
      ""                                                  => "is empty",
      secret                                              => "is not a base32 secret",
      "otpauth://hotp/x?secret=#{SHA1_B32}&counter=1"     => "only TOTP is supported",
      "otpauth://other/x?secret=#{SHA1_B32}"              => "not an otpauth://totp/ one",
      "otpauth://totp/x?issuer=x"                         => "no secret parameter",
      "otpauth://totp/x?secret=#{secret}"                 => "secret is not base32",
      "otpauth://totp/x?secret=#{SHA1_B32}&digits=5"      => "digits is not 6 to 10",
      "otpauth://totp/x?secret=#{SHA1_B32}&digits=eight"  => "digits is not 6 to 10",
      "otpauth://totp/x?secret=#{SHA1_B32}&period=0"      => "period is not a positive",
      "otpauth://totp/x?secret=#{SHA1_B32}&algorithm=MD5" => "algorithm is not SHA1, SHA256, SHA512",
      "otpauth://totp:4294967296/x?secret=#{SHA1_B32}"    => "is not a parseable otpauth: URI",
      "otpauth://totp/x?secret=%3D%3D%3D%3D%3D%3D%3D%3D"  => "secret is not base32",
    }
    refusals.each do |value, reason|
      got = Totp.parse(value)
      got.should be_a(String)
      got.as(String).should contain(reason)
      # Not the secret, not one of its characters' quoting (`base32_decode` names the bad char).
      got.as(String).should_not contain(SHA1_B32)
      got.as(String).should_not contain("Q9")
      got.as(String).should_not contain("char")
    end
  end
end
