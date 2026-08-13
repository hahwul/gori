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

# FakeHttp plus the REQUEST BODY, which resume's whole contract lives in: it must replay the
# persisted correlation id / secret / public key rather than mint new ones, and the only place
# that shows is what it POSTs.
private class RecordingHttp < FakeHttp
  getter bodies = [] of String?

  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : O::Http::Response
    @bodies << body
    super
  end
end

# A shift-sequenced Http: each call pops the next scripted {status, body}. postbin polls by
# destructively shifting the bin one request at a time, so this models a bin that returns good
# requests and then a malformed body (a proxy or rate-limit page served with a 200).
private class SeqHttp < O::Http
  def initialize(@responses : Array(Tuple(Int32, String)))
  end

  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : O::Http::Response
    status, body_str = @responses.shift? || {404, ""}
    O::Http::Response.new(status, body_str)
  end
end

# The same script, but the transport RAISES once the scripted responses run out instead of
# answering 404 — the shape a reset connection, a TLS failure or `HttpClient`'s MAX_BODY refusal
# takes mid-drain, as opposed to `SeqHttp`'s "a 200 carrying junk".
private class RaisingAfterHttp < O::Http
  def initialize(@responses : Array(Tuple(Int32, String)))
  end

  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : O::Http::Response
    r = @responses.shift? || raise Gori::Error.new("OAST: connection reset by peer")
    O::Http::Response.new(r[0], r[1])
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
      key = Bytes.new(32, &.to_u8)
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

  # The probe out-of-band bridge ties a callback to the exact payload that caused it by finding
  # `payload_token(payload)` inside the callback's full_id. That only works if the token this
  # method extracts is actually a substring of the payload the same provider mints — assert it
  # per provider, since each puts its nonce in a different position.
  describe "Provider#payload_token" do
    it "extracts a nonce that is a substring of the minted payload, per provider" do
      cases = {
        O::Interactsh.new("https://oast.pro")            => O::Session.new(1_i64, O::ProviderKind::Interactsh, "https://oast.pro", "corr20charsabcdef012", "sec"),
        O::CustomHttp.new("https://my.oast.example/log") => O::Session.new(1_i64, O::ProviderKind::CustomHttp, "https://my.oast.example/log", "cid", ""),
        O::WebhookSite.new("https://webhook.site")       => O::Session.new(1_i64, O::ProviderKind::WebhookSite, "https://webhook.site", "uuid-1234", ""),
        O::Boast.new("https://boast.example", "secret")  => O::Session.new(1_i64, O::ProviderKind::Boast, "https://boast.example", "boastid", "secret", token: "secret"),
        O::Postbin.new("https://postb.in")               => O::Session.new(1_i64, O::ProviderKind::Postbin, "https://postb.in", "binid", "", token: "binid"),
      }
      cases.each do |provider, session|
        payload = provider.generate_payload(session)
        token = provider.payload_token(payload)
        token.should_not be_empty
        payload.downcase.should contain(token), "#{provider.kind.label}: #{token} not in #{payload}"
        # a DIFFERENT mint yields a DIFFERENT token (the nonce, not the shared correlation id)
        provider.payload_token(provider.generate_payload(session)).should_not eq(token)
      end
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

    # Resume is what makes a payload survive the process that minted it. Without it a restart
    # could only `register` a NEW correlation id, so every payload already planted — the whole
    # point of an out-of-band test, whose callbacks arrive hours later — was dead on exit.
    it "resume re-registers the PERSISTED correlation id, secret and public key" do
      provider = O::Interactsh.new("https://oast.pro")
      rsa = O::RsaKeyPair.from_private_pem(PRIV_PEM)
      session = O::Session.new(7_i64, O::ProviderKind::Interactsh, "https://oast.pro",
        "persisted-corr-id", "persisted-sec", private_key_pem: PRIV_PEM, registered: true)
      http = RecordingHttp.new("/register", "")

      provider.resume(http, session)

      body = JSON.parse(http.bodies.first.not_nil!)
      body["correlation-id"].as_s.should eq("persisted-corr-id")
      body["secret-key"].as_s.should eq("persisted-sec")
      # The SAME key, not a fresh one — the server has to hand back interactions this session
      # can still decrypt, and only this private key opens them.
      Base64.decode_string(body["public-key"].as_s).should eq(rsa.public_spki_pem)
    end

    # The server's answer to "I already know that id" is a 409 or a 400 naming it. Both mean
    # the session is alive, which is exactly the outcome resume wants — treating either as a
    # failure would refuse to resume the sessions that never needed rebuilding in the first place.
    it "resume accepts the server's already-registered answers" do
      provider = O::Interactsh.new("https://oast.pro")
      session = O::Session.new(7_i64, O::ProviderKind::Interactsh, "https://oast.pro",
        "abc123", "sec", private_key_pem: PRIV_PEM)
      provider.resume(RecordingHttp.new("/register", "", 409), session)
      provider.resume(RecordingHttp.new("/register", "correlation-id already exists", 400), session)
    end

    it "resume raises when the server rejects it, so a dead listener is never started" do
      provider = O::Interactsh.new("https://oast.pro")
      session = O::Session.new(7_i64, O::ProviderKind::Interactsh, "https://oast.pro",
        "abc123", "sec", private_key_pem: PRIV_PEM)
      expect_raises(Gori::Error, /resume failed/) do
        provider.resume(RecordingHttp.new("/register", "nope", 500), session)
      end
    end

    # A session restored from a row whose private key is missing cannot decrypt anything the
    # server would return, so resuming it would produce a listener that polls forever and
    # reports nothing. Fail at the resume, where the operator is watching.
    it "resume raises when the restored session has no private key" do
      provider = O::Interactsh.new("https://oast.pro")
      session = O::Session.new(7_i64, O::ProviderKind::Interactsh, "https://oast.pro",
        "abc123", "sec")
      expect_raises(Gori::Error, /no private key/) do
        provider.resume(RecordingHttp.new("/register", ""), session)
      end
    end

    # `session.server_url`, NOT the provider's configured host: the correlation id only means
    # something to the server that minted it, and a provider edited to point elsewhere since
    # must not re-register this session against a host that has never heard of it.
    it "resume targets the session's own server, not the provider's current host" do
      provider = O::Interactsh.new("https://oast.pro")
      session = O::Session.new(7_i64, O::ProviderKind::Interactsh, "https://oast.live",
        "abc123", "sec", private_key_pem: PRIV_PEM)
      http = RecordingHttp.new("/register", "")
      provider.resume(http, session)
      http.calls.first.should eq("POST https://oast.live/register")
    end
  end

  # The other four backends keep (or never had) server-side state independently of gori, so
  # resuming them is just polling the persisted correlation id again. Pinned because `resume`
  # is a network call on the abstract Provider: an override added later that forgets one of
  # these would turn a working resume into a round trip that can fail.
  describe "Provider#resume default" do
    it "is a no-op for every non-interactsh backend" do
      {
        O::CustomHttp.new("https://my.oast.example/log"),
        O::WebhookSite.new("https://webhook.site"),
        O::Boast.new("https://odiss.eu:2096/events", "sec"),
        O::Postbin.new("https://www.postb.in"),
      }.each do |provider|
        http = RecordingHttp.new("never", "")
        session = O::Session.new(1_i64, provider.kind, provider.host, "corr", "sec")
        provider.resume(http, session)
        http.calls.should be_empty
      end
    end
  end

  # Twin of `Session#host`: `payload_host` parses whatever endpoint the operator typed
  # (`normalize_endpoint` only prepends a scheme), and `URI.parse` RAISES on an authority it
  # cannot frame instead of returning nil. Minting a payload must degrade to the raw string,
  # not blow up mid-generation.
  describe "Boast#payload_host" do
    it "falls back to the raw base_url when URI.parse raises on a bad authority" do
      {"fd00::1:9000", "collector.local:8O80/events", "a:99999999999999999999"}.each do |host|
        provider = O::Boast.new(host, "sec")
        session = O::Session.new(1_i64, O::ProviderKind::Boast, host, "boastid", "sec", token: "sec")
        payload = provider.generate_payload(session)
        payload.should end_with("https://#{host}")
      end
    end

    it "still uses the parsed host for a well-formed endpoint" do
      provider = O::Boast.new("https://odiss.eu:2096/events", "sec")
      session = O::Session.new(1_i64, O::ProviderKind::Boast, "https://odiss.eu:2096/events",
        "boastid", "sec", token: "sec")
      provider.generate_payload(session).should end_with(".odiss.eu")
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

  describe O::Postbin do
    # Regression: a malformed body on a LATER shift must not discard the interactions already
    # shifted off the bin this cycle. The shifts are destructive server-side, so a raise out of
    # poll would lose them for good.
    it "keeps the interactions already shifted when a later shift returns a malformed body" do
      provider = O::Postbin.new("https://postb.in")
      session = O::Session.new(1_i64, O::ProviderKind::Postbin, "https://postb.in", "binid", "", token: "binid")
      good = ->(id : String) { {200, {"reqId" => id, "method" => "GET", "path" => "/#{id}"}.to_json} }
      http = SeqHttp.new([good.call("a"), good.call("b"), {200, "<html>rate limited</html>"}])
      results = provider.poll(http, session) # must NOT raise
      results.size.should eq(2)
      results.map(&.unique_id).should eq(["a", "b"])
    end

    # …and the same holds when the SHIFT ITSELF fails rather than its body: a reset connection,
    # a TLS error, or the MAX_BODY refusal `HttpClient` raises on an over-large response. The
    # bin has already handed those two over and no longer holds them.
    it "keeps the interactions already shifted when a later shift raises" do
      provider = O::Postbin.new("https://postb.in")
      session = O::Session.new(1_i64, O::ProviderKind::Postbin, "https://postb.in", "binid", "", token: "binid")
      good = ->(id : String) { {200, {"reqId" => id, "method" => "GET", "path" => "/#{id}"}.to_json} }
      http = RaisingAfterHttp.new([good.call("a"), good.call("b")])
      results = provider.poll(http, session)
      results.map(&.unique_id).should eq(["a", "b"])
    end

    # The other half: swallowing the failure would report "nothing arrived" for an unreachable
    # provider. With nothing collected there is no evidence to protect, so the error surfaces.
    it "raises when the very first shift fails, so an unreachable provider is not silent" do
      provider = O::Postbin.new("https://postb.in")
      session = O::Session.new(1_i64, O::ProviderKind::Postbin, "https://postb.in", "binid", "", token: "binid")
      expect_raises(Gori::Error, /connection reset/) do
        provider.poll(RaisingAfterHttp.new([] of Tuple(Int32, String)), session)
      end
    end
  end

  describe O::Presets do
    it "ships the public presets incl. 5 interactsh servers" do
      all = O::Presets.all
      all.count(&.kind.interactsh?).should eq(5)
      all.any?(&.kind.boast?).should be_true
      all.any?(&.kind.postbin?).should be_true
    end
  end

  # --- APPENDED: pure boundary / error cases ----------------------------------

  describe O::Crypto do
    describe ".aes256_decrypt" do
      it "raises Gori::Error when data is exactly 16 bytes (IV only, no ciphertext)" do
        key = Bytes.new(32, &.to_u8)
        expect_raises(Gori::Error) do
          O::Crypto.aes256_decrypt(Bytes.new(16, &.to_u8), key, "aes-256-cfb")
        end
      end

      it "does NOT raise at 17 bytes (16-byte IV + 1 ciphertext byte)" do
        key = Bytes.new(32, &.to_u8)
        out = O::Crypto.aes256_decrypt(Bytes.new(17, &.to_u8), key, "aes-256-cfb")
        # CFB is a stream cipher: one ciphertext byte -> exactly one plaintext byte.
        out.size.should eq(1)
      end

      it "round-trips aes-256-ctr (documented auto-detect fallback)" do
        key = Bytes.new(32, &.to_u8)
        iv = Bytes.new(16) { |i| (0x10 + i).to_u8 }
        plaintext = "안녕 世界 — ctr fallback 🎯 payload"
        cipher = OpenSSL::Cipher.new("aes-256-ctr")
        cipher.encrypt
        cipher.key = key
        cipher.iv = iv
        ct = IO::Memory.new
        ct.write(cipher.update(plaintext))
        ct.write(cipher.final)
        msg = Bytes.new(16 + ct.bytesize)
        iv.copy_to(msg)
        ct.to_slice.copy_to(msg + 16)
        String.new(O::Crypto.aes256_decrypt(msg, key, "aes-256-ctr")).should eq(plaintext)
      end
    end

    describe ".random_id" do
      it "returns the empty string for length 0" do
        O::Crypto.random_id(0).should eq("")
      end

      it "returns a single DNS-safe char for length 1" do
        id = O::Crypto.random_id(1)
        id.size.should eq(1)
        c = id[0]
        (c.ascii_lowercase? || c.ascii_number?).should be_true
      end

      it "produces distinct ids across two length-20 calls" do
        O::Crypto.random_id(20).should_not eq(O::Crypto.random_id(20))
      end
    end
  end

  describe O::RsaKeyPair do
    describe ".from_private_pem" do
      it "raises Gori::Error on non-PEM garbage" do
        expect_raises(Gori::Error) { O::RsaKeyPair.from_private_pem("not a pem") }
      end

      it "raises Gori::Error on an empty string" do
        expect_raises(Gori::Error) { O::RsaKeyPair.from_private_pem("") }
      end
    end

    describe "#oaep_sha256_decrypt" do
      it "raises Gori::Error on an undersized ciphertext (8 bytes)" do
        kp = O::RsaKeyPair.from_private_pem(PRIV_PEM)
        expect_raises(Gori::Error) { kp.oaep_sha256_decrypt(Bytes.new(8)) }
      end

      it "raises Gori::Error on a modulus-sized garbage buffer (OAEP unpad)" do
        kp = O::RsaKeyPair.from_private_pem(PRIV_PEM)
        garbage = Bytes.new(256) { |i| (i * 7 + 1).to_u8! }
        expect_raises(Gori::Error) { kp.oaep_sha256_decrypt(garbage) }
      end
    end

    describe ".generate_2048" do
      it "mints two DISTINCT keypairs (different public SPKI PEMs)" do
        a = O::RsaKeyPair.generate_2048
        b = O::RsaKeyPair.generate_2048
        a.public_spki_pem.should start_with("-----BEGIN PUBLIC KEY-----")
        a.public_spki_pem.should_not eq(b.public_spki_pem)
      end
    end
  end

  describe O::Presets do
    it "ships exactly 8 presets and no custom-http preset" do
      all = O::Presets.all
      all.size.should eq(8)
      all.any?(&.kind.custom_http?).should be_false
      # 5 interactsh + boast + webhook.site + postbin
      all.count(&.kind.webhook_site?).should eq(1)
    end

    it "gives every preset a non-empty host and a nil token" do
      O::Presets.all.each do |p|
        p.host.empty?.should be_false
        p.token.should be_nil
      end
    end

    it "names each interactsh preset with the bare host while .host is the full url" do
      interactsh = O::Presets.all.select(&.kind.interactsh?)
      interactsh.size.should eq(5)
      interactsh.each do |p|
        p.host.should start_with("https://")
        bare = URI.parse(p.host).host.not_nil!
        p.name.should contain(bare)
        p.name.should_not contain("https://")
      end
    end
  end

  describe O::ProviderKind do
    it "renders #label for all five kinds" do
      O::ProviderKind::Interactsh.label.should eq("interactsh")
      O::ProviderKind::CustomHttp.label.should eq("custom-http")
      O::ProviderKind::WebhookSite.label.should eq("webhook.site")
      O::ProviderKind::Boast.label.should eq("BOAST")
      O::ProviderKind::Postbin.label.should eq("postbin")
    end

    it "round-trips parse?(kind.label) == kind for every kind" do
      O::ProviderKind.values.each do |kind|
        O::ProviderKind.parse?(kind.label).should eq(kind)
      end
    end

    it "parses tolerant tokens (case- and separator-insensitive)" do
      O::ProviderKind.parse?("BOAST").should eq(O::ProviderKind::Boast)
      O::ProviderKind.parse?("boast").should eq(O::ProviderKind::Boast)
      O::ProviderKind.parse?("web_hook.site").should eq(O::ProviderKind::WebhookSite)
      O::ProviderKind.parse?("webhook-site").should eq(O::ProviderKind::WebhookSite)
    end

    it "returns nil for the empty string" do
      O::ProviderKind.parse?("").should be_nil
    end

    it "returns nil when a space separator is used (spaces are not normalized away)" do
      O::ProviderKind.parse?("custom http").should be_nil
    end
  end

  describe O::WebhookSite do
    it "keeps the payload nonce on an empty-body callback" do
      # generate_payload mints …/{uuid}/{nonce}; a GET with content:"" used to set
      # raw_request="" and full_id=request-uuid, so the nonce vanished from every surface.
      token = "tok-uuid-aaaa"
      nonce = "n0nc3payld"
      hit = "https://webhook.site/#{token}/#{nonce}"
      body = {
        "data" => [{
          "uuid"       => "req-bbbb",
          "method"     => "GET",
          "ip"         => "203.0.113.5",
          "content"    => "",
          "url"        => hit,
          "created_at" => "2024-01-01T00:00:00Z",
        }],
      }.to_json
      provider = O::WebhookSite.new("https://webhook.site")
      session = O::Session.new(0_i64, O::ProviderKind::WebhookSite,
        "https://webhook.site", token, "", registered: true)
      results = provider.poll(FakeHttp.new("/token/", body), session)
      results.size.should eq(1)
      i = results[0]
      i.unique_id.should eq("req-bbbb")
      i.full_id.should eq(hit)
      i.raw_request.should eq(hit)
      i.raw_request.should contain(nonce)
      i.method.should eq("GET")
    end
  end
end
