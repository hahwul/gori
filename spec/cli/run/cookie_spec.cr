require "../../spec_helper"
require "json"

# `gori run cookie` drives the shared Gori::Cookie engine (covered end-to-end in
# spec/cookie_spec.cr); this file pins the CLI-only glue. The emit_* helpers call `exit`,
# so they aren't invoked in-process — the input helper is the reachable seam.

# `cookie_input` is private CLI glue — reopen the module for a bare-call wrapper. Only the
# positional branch is exercised (the STDIN branch would block on a non-tty spec runner).
module Gori::CLI::Run
  def self.cookie_input_for_spec(positional : Array(String)) : String
    cookie_input(positional)
  end

  # `--timestamp` parsing seam. The option callback wraps this and turns the raised
  # ArgumentError into an `abort` (which exits, so it can't run in-process).
  def self.parse_forge_timestamp_for_spec(v : String) : Int64
    parse_forge_timestamp(v)
  end

  # The `--verify`/`--crack` algorithm resolver seam (private glue the emit_* helpers call).
  def self.cookie_effective_algo_for_spec(cookie : String, type : String?, algorithm : String, pinned : Bool) : String
    cookie_effective_algo(cookie, type, algorithm, pinned)
  end
end

describe "gori run cookie" do
  it "takes the cookie from the positional argument, trimmed" do
    # A cookie pasted from a terminal or piped through a shell routinely arrives with
    # surrounding whitespace/newline.
    Gori::CLI::Run.cookie_input_for_spec(["  #{RACK}\n"]).should eq(RACK)
  end

  describe "--forge --timestamp" do
    it "parses a valid unix second" do
      Gori::CLI::Run.parse_forge_timestamp_for_spec("1750000000").should eq(1750000000_i64)
    end

    it "accepts 0 as the epoch" do
      Gori::CLI::Run.parse_forge_timestamp_for_spec("0").should eq(0_i64)
    end

    it "refuses an unparseable value by name (not silently 'now')" do
      # Without the fix `to_i64?` returned nil and the `|| now` fallback stamped the
      # current time, reporting a forged cookie as success.
      expect_raises(ArgumentError, /invalid --timestamp "notanumber"/) do
        Gori::CLI::Run.parse_forge_timestamp_for_spec("notanumber")
      end
    end

    it "refuses an out-of-Int64-range value by name" do
      expect_raises(ArgumentError, /invalid --timestamp/) do
        Gori::CLI::Run.parse_forge_timestamp_for_spec("1180591620717411303424")
      end
    end

    it "refuses a negative value by name" do
      expect_raises(ArgumentError, /invalid --timestamp "-5" \(must not be negative\)/) do
        Gori::CLI::Run.parse_forge_timestamp_for_spec("-5")
      end
    end
  end

  it "the CLI and MCP share the decode_json shape (no divergence)" do
    # Both surfaces emit Gori::Cookie.decode_json — assert the contract once here.
    j = JSON.parse(Gori::Cookie.decode_json(FLASK))
    j["format"].as_s.should eq("flask")
    j["payload"]["user_id"].as_i.should eq(42)
    j["signature"].as_s.should_not be_empty
  end

  describe "verify/crack --algorithm auto-detection" do
    algo = ->(cookie : String, type : String?, alg : String, pinned : Bool) do
      Gori::CLI::Run.cookie_effective_algo_for_spec(cookie, type, alg, pinned)
    end

    it "auto-detects sha1 for a real SHA-1 Django cookie when --algorithm is unset" do
      # The trap: the CLI defaults algorithm to sha256, so a SHA-1 `sessionid` read as
      # "invalid" even with the correct secret. Reading the algorithm off the signature
      # length spares the operator the wrong answer, matching the Cookie tab's badge.
      algo.call(DJANGO_SHA1, nil, "sha256", false).should eq("sha1")
      Gori::Cookie.verify(DJANGO_SHA1, "s3cr3t-key", "django",
        algorithm: algo.call(DJANGO_SHA1, nil, "sha256", false)).should be_true
    end

    it "keeps sha256 for a SHA-256 Django cookie" do
      algo.call(DJANGO, nil, "sha256", false).should eq("sha256")
    end

    it "honors an explicitly pinned --algorithm even against the signature length" do
      # A pinned choice is the operator's; do not second-guess it from the bytes.
      algo.call(DJANGO_SHA1, nil, "sha256", true).should eq("sha256")
    end

    it "leaves non-Django cookies on the passed algorithm (unused by Flask/Rack)" do
      algo.call(FLASK, nil, "sha256", false).should eq("sha256")
      algo.call(RACK, "rack", "sha256", false).should eq("sha256")
    end
  end
end

private FLASK       = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9.am71Yg.gd2MWkbBsGdhg4rScrYWBdGoj-Q"
private RACK        = "BAh7BkkiCXVzZXIGOgZFVEkiCmFsaWNlBjsAVA==--9156ef2ac6989f37064259efa196770c3ee052ca"
private DJANGO      = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9:1wqQs6:ofPm07XfGfVUimPfVs9Bdy5M7H0cxBS_265YiN3lQsY"
private DJANGO_SHA1 = "eyJhIjoxfQ:1wqR8T:8BooTFI1B28NGHSf42JyGt1Or-0"
