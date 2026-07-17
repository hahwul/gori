require "../spec_helper"
require "base64"

private alias O = Gori::Oast

# Deterministic interactsh crypto fixture (generated offline with `openssl`):
# - PRIV_PEM: an RSA-2048 private key.
# - AESKEY_B64: base64 of RSA-OAEP(sha256, mgf1 sha256) encryption of a fixed 32-byte AES
#   key (bytes 0x00..0x1f) to PRIV_PEM's public key.
# - MSG_B64: base64 of (IV ‖ AES-256-CFB ciphertext) of INTERACTION_JSON under that key.
private PRIV_PEM = <<-PEM
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCYrErrK2qx8Pq5
SZuN3rkUl9VL/X4I0O/aoq/ZvDYYKo2pf19V69B2MPkOz9LJBEQmk8sTy0Q5vehv
69i8BApvlOC04QSTOfgjc7Cynx4kDUFXPkh24vePBK1fpkNuNoxQ8QsmLpGSSzfk
DuDldtxoTPTjCu9G6Z0hVAVHlMh/uGH0twGyIv+i6R6ADFZDAgB1A6aaddRY4OOR
Z/HLyvTIPVKGcWASlzN8Tsngp14RrZnNbwwp7OEvB8d6Idooi440R5wkx1FhuePs
7aSXfAryxMKZuBHM3IkaHr7GGxV7Z/tWHNSYpjnfizvTuvwzh1fXdHAeQF695lTK
MdAFnrp7AgMBAAECggEAA1UXZwL9v/zdPPgb91uQENaHyL+EZbyMtMGquXmQrwTF
6x7UWKzeNy6iJvGc9fJiDL6QkRU/nzEh67rXBpgyuKQ/GQzg7vL/+IuZv80xNZjE
QptlDJLXxnZhaOu+SBjGtNwarAl4SLB9nVeD5rycv7bnJQ1PriOQZzxNJgrHfBeg
9t/FmSXHtBeRdAN/eLxDwS+zpev6y1Qa400objedxkN2ptx/M6fCDBP5ZcgMfPu8
AhZcrBVcR7RB3BlON4Plz91HTHPflEqb92FcR475GNefGr4fQOeMOSW8JcYjeoHJ
EP3nG+d7y5y8AbwH2k8ZbRbN7bw5HVHLMSU4fssOGQKBgQDVWhWxm/QBczOSP678
aivxihzngQ4YeM1K2Rjx0JAFNNWj7eLE4Ee36j2aq5n6vuUmjC77WtR8fBASCloF
ip+eWBawihT6bOMuJhTVnHdTmqGBOJWiotCUVFu4/H7i8KrMFDlJK1CQzpgifWeX
cp7g+tpNP+3LhyfFs9GH0dVttQKBgQC3MRIzQo4MWOM+4ghGsawCPl3VLcxQZ8tt
RcY6GuN9sWGCRLEMvnkS6q/gQOWcN9BrlP6ePajVzP2NHa7VGd/efw7tFYccKVqR
cKHrMhWBjCv31htOASWqhTE/dqI8p85WcVj0J3sIS1s/XNsZ//Lmock6bE5kQczG
YO3lR/UlbwKBgG+14oQDv2h+9HLQK4R45xdqlKXW2hWQMxXMxJXg+XfwaSiTZ1hk
gsjWunjg/xfemkdrwTHVJksj/pojl20tX1RelUrMkh1ppC5GvEP40DYTUhtCEH9+
tq3j2b7rXljfYN7IfBJGvsGDmv78IKCY4H22e1VVcuJNm1KWS9DM2u69AoGBAJvG
pZRjRwlm2K6TZLhAw2URBZeOn0vMR2b/S0YDsWkj2if9I5UTrz8PxEjsxpNlvtyM
0UtcYWKVMxK5p/7cRssbvmSKxt6Cp9o/LeEjMLh9qrHQJl3Zid8L7cnqpqDvjP1i
22Ka4/s0oT4rRsFALZxC/SuqB6snbOtQZ1tuKh8PAoGBAIOcvhkavofj/oroiGcM
ZPyZPo4tC4GLzcCzRznUox6qw7GpJhaRW1f4e5k2hmCJp/Sha4BPqblWoD3f84Ej
AoYnPn6DAWVG5NOoazrfDDnYzWR0S6b9umD8W49e89Fgob56ZVgsJJy9euSuUZJ8
WJsgaeppj/Vuf90EO0Z5M5v0
-----END PRIVATE KEY-----
PEM

private AESKEY_B64 = "i4CBi3bc+PYX6GqbkVqlF9NdghUyT9cJDPdJBDEfdxu2a2z1cLcrXCz0zISQplkWom1u622rnATmxmI7tH5x58T3m1mwW0+Fo8glhb4hZALcynWMacm6+nfDEKjVDP88pl9BzCezRkyrHl6FqGNvArssWb46YFGwhNCG4nFQWxPGEyBc5bI+0HlX3BibRv2K3YaJ6D267Ct5vgfYgo43yXOMqh09OUM3q7c5NGKtp+yCMd2hCL8A+wJxu/24ESbzIlx61S4isYDEGAGTpKq7zkubo2eg5nAc6slwblHQ4ghyeg1F4dUDAfb1NRVrnxJIG6kHrN0IQlIvepmeKjHaNA=="

private MSG_B64 = "oKGio6SlpqeoqaqrrK2ur6e9cY8ZzBNuYCfKvylvgpM60cK3B3HAA2e5AahUvuAYLNIfpeTwRMWFybdC276MjpNeOqEBB9x0PkQ7v4MI7PO+fxjPXYcdy6ewhwqV7KvE8yA8qBfa4WG6Do2sNQ62/pXzh31WXpmm9rOkVkNzZzR2ut7qLb/3tRzDCX0gmB1V93w5tnVDr5aPEyiGPyVDHDT3sWm0KV8sPhSg5TVwuRUM1ZwfJ1eowlMsErVhgSQdr3ECoB+LcA=="

# A minimal Http seam that returns a canned body when the request line contains `match`.
private class FakeHttp < O::Http
  getter calls = [] of String

  def initialize(@match : String, @body : String, @status : Int32 = 200)
  end

  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : O::Http::Response
    @calls << "#{method} #{url}"
    if "#{method} #{url}".includes?(@match)
      O::Http::Response.new(@status, @body)
    else
      O::Http::Response.new(404, "")
    end
  end
end

describe Gori::Oast do
  describe O::RsaKeyPair do
    it "generates a 2048 key and exports a valid SPKI PEM that round-trips" do
      kp = O::RsaKeyPair.generate_2048
      kp.public_spki_pem.should start_with("-----BEGIN PUBLIC KEY-----")
      priv = kp.private_pem
      priv.should start_with("-----BEGIN PRIVATE KEY-----")
      # re-importing the private PEM yields a working keypair
      O::RsaKeyPair.from_private_pem(priv).public_spki_pem.should eq(kp.public_spki_pem)
    end

    it "RSA-OAEP(SHA-256) decrypts the fixture AES key (MGF1 also SHA-256)" do
      kp = O::RsaKeyPair.from_private_pem(PRIV_PEM)
      key = kp.oaep_sha256_decrypt(Base64.decode(AESKEY_B64))
      key.size.should eq(32)
      key.to_a.should eq((0..31).map(&.to_u8))
    end
  end

  describe O::Crypto do
    it "AES-256 round-trips through the decrypt helper (IV prefixed)" do
      key = Bytes.new(32) { |i| i.to_u8 }
      iv = Bytes.new(16) { |i| (0xa0 + i).to_u8 }
      plaintext = "the quick brown fox jumps over 13 lazy dogs"
      cipher = OpenSSL::Cipher.new("aes-256-cfb")
      cipher.encrypt
      cipher.key = key
      cipher.iv = iv
      ct = IO::Memory.new
      ct.write(cipher.update(plaintext))
      ct.write(cipher.final)
      msg = Bytes.new(16 + ct.bytesize)
      iv.copy_to(msg)
      ct.to_slice.copy_to(msg + 16)
      String.new(O::Crypto.aes256_decrypt(msg, key, "aes-256-cfb")).should eq(plaintext)
    end

    it "mints DNS-safe lowercase-alnum ids of the requested length" do
      id = O::Crypto.random_id(20)
      id.size.should eq(20)
      id.chars.all? { |c| c.ascii_lowercase? || c.ascii_number? }.should be_true
    end
  end

  describe O::ProviderKind do
    it "round-trips labels and tolerant tokens" do
      O::ProviderKind::CustomHttp.label.should eq("custom-http")
      O::ProviderKind.parse?("custom-http").should eq(O::ProviderKind::CustomHttp)
      O::ProviderKind.parse?("CustomHttp").should eq(O::ProviderKind::CustomHttp)
      O::ProviderKind.parse?("webhook.site").should eq(O::ProviderKind::WebhookSite)
      O::ProviderKind.parse?("nope").should be_nil
    end
  end

  describe O::Interactsh do
    it "polls, RSA-OAEP + AES-CFB decrypts, and normalizes an interaction" do
      provider = O::Interactsh.new("https://oast.pro")
      session = O::Session.new(1_i64, O::ProviderKind::Interactsh, "https://oast.pro",
        "abc123", "sec", private_key_pem: PRIV_PEM, registered: true)
      body = {"data" => [MSG_B64], "aes_key" => AESKEY_B64}.to_json
      http = FakeHttp.new("/poll", body)

      results = provider.poll(http, session)
      results.size.should eq(1)
      i = results.first
      i.protocol.should eq("dns")
      i.method.should eq("A") # q-type for non-HTTP
      i.source_ip.should eq("203.0.113.9")
      i.full_id.should eq("abc123def.oast.pro")
      i.raw_request.should contain("opcode: QUERY")
    end

    it "generates a local payload sharing the correlation id" do
      provider = O::Interactsh.new("https://oast.pro")
      session = O::Session.new(1_i64, O::ProviderKind::Interactsh, "https://oast.pro",
        "abc123", "sec")
      url = provider.generate_payload(session)
      url.should start_with("abc123")
      url.should end_with(".oast.pro")
    end

    it "treats a 204 poll as no interactions" do
      provider = O::Interactsh.new("https://oast.pro")
      session = O::Session.new(1_i64, O::ProviderKind::Interactsh, "https://oast.pro",
        "abc123", "sec", private_key_pem: PRIV_PEM)
      http = FakeHttp.new("/poll", "", 204)
      provider.poll(http, session).should be_empty
    end
  end

  describe O::CustomHttp do
    it "parses a tolerant JSON list and hashes a dedup id when absent" do
      provider = O::CustomHttp.new("https://my.oast.example/log")
      session = provider.register(FakeHttp.new("never", ""))
      body = [{"protocol" => "http", "method" => "GET", "ip" => "10.0.0.1",
               "rawRequest" => "GET /oid=x HTTP/1.1"}].to_json
      http = FakeHttp.new("my.oast.example", body)
      results = provider.poll(http, session)
      results.size.should eq(1)
      results.first.method.should eq("GET")
      results.first.source_ip.should eq("10.0.0.1")
      results.first.unique_id.empty?.should be_false
    end
  end

  describe O::Presets do
    it "ships the public presets incl. 5 interactsh servers" do
      all = O::Presets.all
      all.count { |p| p.kind.interactsh? }.should eq(5)
      all.any? { |p| p.kind.boast? }.should be_true
      all.any? { |p| p.kind.postbin? }.should be_true
    end
  end
end
