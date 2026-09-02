require "../../spec_helper"

# Test seam: read_token_list is a private module method; expose a thin caller within
# the same namespace (this only exists in the test binary) so Fix #1 can be exercised
# directly without going through the network/exit paths of the full subcommand.
module Gori::CLI::Run
  def self.spec_read_token_list(file : String) : Array(String)
    read_token_list(file)
  end

  # `tokens_live_conflicts` is private and `cmd_sequence` ends in `abort`, so this is the only
  # way to read the list back without running the binary. Defaults mirror the parser's.
  def self.spec_tokens_live_conflicts(positional : Array(String) = [] of String,
                                      flow_id : Int64? = nil, request_file : String? = nil,
                                      target : String? = nil, sni : String? = nil,
                                      http2 : Bool = false, insecure : Bool = false,
                                      bind_from : Int64? = nil, slot : String? = nil,
                                      allow_unscoped : Bool = false,
                                      max_requests : Int64? = nil, rate : Float64? = nil,
                                      throttle : Int32? = nil, timeout : Time::Span? = nil,
                                      keep_alive : Bool = true,
                                      kind : Gori::Sequencer::ExtractKind? = nil) : Array(String)
    tokens_live_conflicts(positional: positional, flow_id: flow_id, request_file: request_file,
      target: target, sni: sni, http2: http2, insecure: insecure, bind_from: bind_from,
      slot: slot, allow_unscoped: allow_unscoped, max_requests: max_requests, rate: rate,
      throttle: throttle, timeout: timeout, keep_alive: keep_alive, kind: kind)
  end
end

# `--tokens FILE` analyzes a pasted list and sends nothing, so every flag that only shapes a
# live collection has to be refused rather than accepted-and-dropped. The flags that PUT a
# request on the wire were already named; the PACING knobs were not, so
# `--tokens list.txt --max-requests 10` asked for ten samples, said nothing, and analyzed the
# whole file.
describe "gori run sequence --tokens — the live-only flags it refuses" do
  it "accepts a bare --tokens run" do
    Gori::CLI::Run.spec_tokens_live_conflicts.should be_empty
  end

  it "names each pacing knob, which only ever sized a collection that is not happening" do
    Gori::CLI::Run.spec_tokens_live_conflicts(max_requests: 10_i64).should eq(["--max-requests"])
    Gori::CLI::Run.spec_tokens_live_conflicts(rate: 5.0).should eq(["--rate"])
    Gori::CLI::Run.spec_tokens_live_conflicts(throttle: 250).should eq(["--throttle"])
    Gori::CLI::Run.spec_tokens_live_conflicts(timeout: 3.seconds).should eq(["--timeout"])
    Gori::CLI::Run.spec_tokens_live_conflicts(keep_alive: false).should eq(["--no-keep-alive"])
  end

  it "still names the flags that would put a request on the wire" do
    Gori::CLI::Run.spec_tokens_live_conflicts(flow_id: 7_i64, target: "http://acme.test",
      slot: "admin", bind_from: 3_i64)
      .should eq(["--flow", "--target", "--bind-from", "--slot"])
  end

  it "names every flag once, in the parser's order" do
    all = Gori::CLI::Run.spec_tokens_live_conflicts(positional: ["5"], flow_id: 7_i64,
      request_file: "r.txt", target: "http://acme.test", sni: "acme.test", http2: true,
      insecure: true, bind_from: 3_i64, slot: "admin", allow_unscoped: true,
      max_requests: 10_i64, rate: 5.0, throttle: 250, timeout: 3.seconds, keep_alive: false,
      kind: Gori::Sequencer::ExtractKind::Cookie)
    # `--count`/`--concurrency`/`--retries` have no parameter here at all: their non-nil
    # defaults make "was it passed" unrecoverable, which is why they stay exempt.
    all.should eq(["<flow-id> \"5\"", "--flow", "--request", "--target", "--sni", "--http2",
                   "--insecure-upstream", "--bind-from", "--slot", "--allow-unscoped",
                   "--max-requests", "--rate", "--throttle", "--timeout", "--no-keep-alive",
                   "a token location (--cookie/--header/--regex/--position/--jsonpath)"])
    all.size.should eq(all.uniq.size)
  end
end

# Fix #1 — `gori run sequence --tokens=FILE` used to crash with
# "ArgumentError: Regex match error: UTF-8 error" when the file held a non-UTF-8 byte,
# because the `raw.split(/\r?\n/)` PCRE2 split rejects invalid UTF-8. The read now
# scrubs to valid UTF-8 first so a stray byte doesn't abort the whole analysis.
describe "Gori::CLI::Run.read_token_list" do
  it "does not crash on a non-UTF-8 tokens file (scrubs the bad byte to U+FFFD)" do
    path = File.tempname("gori-tokens")
    # a \n b<0xff> \n c \n  — the 0xff used to make the regex split raise.
    File.write(path, Bytes[0x61_u8, 0x0a_u8, 0x62_u8, 0xff_u8, 0x0a_u8, 0x63_u8, 0x0a_u8])
    begin
      tokens = Gori::CLI::Run.spec_read_token_list(path)
      tokens.size.should eq(3)
      tokens[0].should eq("a")
      tokens[1].should eq("b\u{FFFD}") # invalid byte replaced with U+FFFD, token preserved
      tokens[2].should eq("c")
    ensure
      File.delete(path) rescue nil
    end
  end

  it "reads a normal UTF-8 tokens file unchanged (CRLF + blank lines handled)" do
    path = File.tempname("gori-tokens")
    File.write(path, "one\r\ntwo\n\n  three  \n")
    begin
      Gori::CLI::Run.spec_read_token_list(path).should eq(["one", "two", "three"])
    ensure
      File.delete(path) rescue nil
    end
  end
end
