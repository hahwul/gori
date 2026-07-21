require "../spec_helper"
require "json"

private alias O = Gori::Oast

# The exact top-level key set the JSON contract promises (anti-drift for the CLI
# `--format json` surface and the MCP oast_* tools — the two must never diverge).
private INTERACTION_KEYS = %w[
  unique_id protocol method source destination provider timestamp
  raw_request raw_response
]

# Build an Interaction record with sensible HTTP defaults; individual fields are
# overridable so each example can drive exactly the branch it cares about.
private def build_interaction(
  unique_id = "abc123",
  protocol = "http",
  method : String? = "GET",
  source_ip : String? = "203.0.113.7",
  full_id = "abc123.oast.example.com",
  raw_request = "GET / HTTP/1.1\r\nHost: abc123.oast.example.com\r\n\r\n",
  raw_response : String? = "HTTP/1.1 200 OK\r\n\r\n",
  at = Time.utc(2026, 7, 21, 12, 30, 45),
) : O::Interaction
  O::Interaction.new(
    unique_id: unique_id,
    protocol: protocol,
    method: method,
    source_ip: source_ip,
    full_id: full_id,
    raw_request: raw_request,
    raw_response: raw_response,
    at: at,
  )
end

describe Gori::Oast::Present do
  describe ".interaction" do
    it "returns a NamedTuple with EXACTLY the documented key set" do
      nt = O::Present.interaction(build_interaction, "interactsh")
      # NamedTuple#keys is a tuple of symbols; compare against the contract names.
      nt.keys.map(&.to_s).to_a.sort.should eq(INTERACTION_KEYS.sort)
      nt.keys.size.should eq(INTERACTION_KEYS.size)
    end

    it "maps each key to the documented Interaction accessor (renames included)" do
      i = build_interaction(
        unique_id: "uid-42",
        protocol: "dns",
        method: "POST",
        source_ip: "198.51.100.9",
        full_id: "sub.host.oast.example.com",
        raw_request: "raw-req-bytes",
        raw_response: "raw-resp-bytes",
        at: Time.utc(2026, 1, 2, 3, 4, 5),
      )
      nt = O::Present.interaction(i, "webhook.site")

      nt[:unique_id].should eq("uid-42")
      nt[:protocol].should eq("dns")
      nt[:method].should eq("POST")
      # source <- i.source_ip (renamed)
      nt[:source].should eq("198.51.100.9")
      # destination <- i.full_id (renamed)
      nt[:destination].should eq("sub.host.oast.example.com")
      # provider comes from the argument, not the record
      nt[:provider].should eq("webhook.site")
      # timestamp <- i.at.to_rfc3339
      nt[:timestamp].should eq(i.at.to_rfc3339)
      nt[:raw_request].should eq("raw-req-bytes")
      nt[:raw_response].should eq("raw-resp-bytes")
    end

    it "renders timestamp as the RFC3339 string of i.at (Zulu form for UTC)" do
      i = build_interaction(at: Time.utc(2026, 7, 21, 12, 30, 45))
      nt = O::Present.interaction(i, "boast")
      nt[:timestamp].should eq("2026-07-21T12:30:45Z")
      nt[:timestamp].should eq(i.at.to_rfc3339)
    end

    it "carries the provider argument through verbatim, independent of the record" do
      i = build_interaction
      O::Present.interaction(i, "custom-http")[:provider].should eq("custom-http")
      O::Present.interaction(i, "postbin")[:provider].should eq("postbin")
      # empty provider string is preserved, not defaulted
      O::Present.interaction(i, "")[:provider].should eq("")
    end
  end

  describe ".interaction JSON contract" do
    it "serializes to a JSON object with exactly the documented keys" do
      json = O::Present.interaction(build_interaction, "interactsh").to_json
      keys = JSON.parse(json).as_h.keys
      keys.sort.should eq(INTERACTION_KEYS.sort)
      keys.size.should eq(INTERACTION_KEYS.size)
    end

    it "serializes a DNS interaction (method:nil) to \"method\":null" do
      i = build_interaction(protocol: "dns", method: nil)
      json = O::Present.interaction(i, "interactsh").to_json
      parsed = JSON.parse(json).as_h
      # The key is present but its value is JSON null.
      parsed.has_key?("method").should be_true
      parsed["method"].raw.should be_nil
      # Explicit textual proof of the null literal in the emitted JSON.
      json.should contain(%("method":null))
    end

    it "serializes raw_response:nil to \"raw_response\":null" do
      i = build_interaction(raw_response: nil)
      json = O::Present.interaction(i, "interactsh").to_json
      parsed = JSON.parse(json).as_h
      parsed.has_key?("raw_response").should be_true
      parsed["raw_response"].raw.should be_nil
      json.should contain(%("raw_response":null))
    end

    it "serializes source_ip:nil (no source) to \"source\":null" do
      i = build_interaction(source_ip: nil)
      json = O::Present.interaction(i, "interactsh").to_json
      parsed = JSON.parse(json).as_h
      parsed.has_key?("source").should be_true
      parsed["source"].raw.should be_nil
    end

    it "emits non-null string values for a full HTTP interaction" do
      i = build_interaction(protocol: "http", method: "GET", source_ip: "203.0.113.7")
      parsed = JSON.parse(O::Present.interaction(i, "interactsh").to_json).as_h
      parsed["method"].as_s.should eq("GET")
      parsed["source"].as_s.should eq("203.0.113.7")
      parsed["protocol"].as_s.should eq("http")
    end

    it "round-trips a multibyte/Unicode (emoji + CJK) raw_request through JSON" do
      req = "GET /안녕世界🔥 HTTP/1.1\r\nHost: oast\r\nX-Combining: é\r\n\r\n"
      i = build_interaction(raw_request: req)
      json = O::Present.interaction(i, "interactsh").to_json
      parsed = JSON.parse(json).as_h
      parsed["raw_request"].as_s.should eq(req)
    end

    it "round-trips multibyte content in raw_response too" do
      resp = "HTTP/1.1 200 OK\r\n\r\n<body>세계 🌍 café</body>"
      i = build_interaction(raw_response: resp)
      parsed = JSON.parse(O::Present.interaction(i, "boast").to_json).as_h
      parsed["raw_response"].as_s.should eq(resp)
    end

    it "escapes and round-trips control bytes / quotes / backslashes / NUL in raw_request" do
      req = "l1\r\nl2\tv=\"q\"\\slash\\ z\u0000 trail"
      i = build_interaction(raw_request: req)
      json = O::Present.interaction(i, "interactsh").to_json
      # A raw newline byte must never be emitted literally into the JSON text.
      json.should_not contain('\n')
      # Round-trip proves the escaping is lossless.
      JSON.parse(json).as_h["raw_request"].as_s.should eq(req)
    end

    it "round-trips an empty raw_request (empty string, not null)" do
      i = build_interaction(raw_request: "")
      parsed = JSON.parse(O::Present.interaction(i, "interactsh").to_json).as_h
      parsed["raw_request"].raw.should_not be_nil
      parsed["raw_request"].as_s.should eq("")
    end

    it "full round-trip preserves every field for a DNS interaction with nil method+response" do
      i = build_interaction(
        unique_id: "dns-uid",
        protocol: "dns",
        method: nil,
        source_ip: "192.0.2.53",
        full_id: "lookup.oast.example.com",
        raw_request: "쿼리 A? lookup.oast.example.com",
        raw_response: nil,
        at: Time.utc(2026, 12, 31, 23, 59, 59),
      )
      parsed = JSON.parse(O::Present.interaction(i, "interactsh").to_json).as_h
      parsed["unique_id"].as_s.should eq("dns-uid")
      parsed["protocol"].as_s.should eq("dns")
      parsed["method"].raw.should be_nil
      parsed["source"].as_s.should eq("192.0.2.53")
      parsed["destination"].as_s.should eq("lookup.oast.example.com")
      parsed["provider"].as_s.should eq("interactsh")
      parsed["timestamp"].as_s.should eq("2026-12-31T23:59:59Z")
      parsed["raw_request"].as_s.should eq("쿼리 A? lookup.oast.example.com")
      parsed["raw_response"].raw.should be_nil
    end
  end

  describe ".payload" do
    it "returns {payload_url:, session_id:, provider:} with the documented keys" do
      nt = O::Present.payload("https://x.oast.example.com", 42_i64, "interactsh")
      nt.keys.map(&.to_s).to_a.sort.should eq(%w[payload_url provider session_id].sort)
      nt[:payload_url].should eq("https://x.oast.example.com")
      nt[:session_id].should eq(42_i64)
      nt[:provider].should eq("interactsh")
    end

    it "keeps the session_id an Int64 (compile-time type, not widened/stringified)" do
      nt = O::Present.payload("u", 7_i64, "boast")
      nt[:session_id].should be_a(Int64)
      nt[:session_id].should eq(7_i64)
    end

    it "preserves a large Int64 session_id through JSON without precision loss" do
      big = Int64::MAX
      json = O::Present.payload("https://u", big, "webhook.site").to_json
      parsed = JSON.parse(json).as_h
      parsed["session_id"].as_i64.should eq(big)
      parsed["payload_url"].as_s.should eq("https://u")
      parsed["provider"].as_s.should eq("webhook.site")
    end

    it "preserves the ad-hoc/unpersisted session marker (session_id 0)" do
      nt = O::Present.payload("https://u", 0_i64, "postbin")
      nt[:session_id].should eq(0_i64)
      JSON.parse(nt.to_json).as_h["session_id"].as_i64.should eq(0_i64)
    end

    it "round-trips a multibyte payload URL and the negative-boundary Int64" do
      url = "https://안녕-🔥.oast.example.com/path?x=世界"
      nt = O::Present.payload(url, Int64::MIN, "custom-http")
      parsed = JSON.parse(nt.to_json).as_h
      parsed["payload_url"].as_s.should eq(url)
      parsed["session_id"].as_i64.should eq(Int64::MIN)
    end

    it "serializes to a JSON object with exactly the three documented keys" do
      keys = JSON.parse(O::Present.payload("u", 1_i64, "interactsh").to_json).as_h.keys
      keys.sort.should eq(%w[payload_url provider session_id].sort)
      keys.size.should eq(3)
    end
  end
end
