require "../../spec_helper"
require "base64"
require "json"

# `gori run decoder` — the converter chain runner. Its `--format json` per-step document
# is what makes a failing chain diagnosable, and it is the only place the CLI reports a
# partial result: steps run left-to-right and stop at the first failure.

# Private CLI glue — reopen the module for bare-call wrappers. (`parse_render_mode`'s
# invalid branch aborts, so only the four valid spellings are exercised.)
module Gori::CLI::Run
  def self.decoder_json_for_spec(result : Gori::Decoder::ChainResult, mode : Gori::Decoder::RenderAs?) : String
    decoder_json(result, mode)
  end

  def self.parse_render_mode_for_spec(v : String) : Gori::Decoder::RenderAs?
    parse_render_mode(v)
  end
end

private def run_chain(input : String, chain : String) : Gori::Decoder::ChainResult
  Gori::Decoder.run(Gori::Decoder.shared_registry, input.to_slice, chain)
end

describe "gori run decoder --output" do
  it "maps every documented spelling, case-insensitively, with auto meaning nil" do
    Gori::CLI::Run.parse_render_mode_for_spec("auto").should be_nil # nil = let display() decide
    Gori::CLI::Run.parse_render_mode_for_spec("text").should eq(Gori::Decoder::RenderAs::Text)
    Gori::CLI::Run.parse_render_mode_for_spec("BASE64").should eq(Gori::Decoder::RenderAs::Base64)
    Gori::CLI::Run.parse_render_mode_for_spec("Hex").should eq(Gori::Decoder::RenderAs::Hex)
  end
end

describe "gori run decoder --format json" do
  it "reports ok with one step object per converter, in chain order" do
    json = JSON.parse(Gori::CLI::Run.decoder_json_for_spec(run_chain("SGVsbG8=", "base64-decode"), nil))
    json["ok"].as_bool.should be_true
    steps = json["steps"].as_a
    steps.size.should eq(1)
    steps[0]["token"].as_s.should eq("base64-decode")
    steps[0]["name"].as_s.should_not be_empty
    steps[0]["state"].as_s.should eq("ok")
    steps[0]["output"].as_s.should eq("Hello")
    json["output"].as_s.should eq("Hello")
    json["failed_at"].raw.should be_nil
  end

  it "composes a chain left-to-right, keeping each intermediate output" do
    result = run_chain("%53%47%56%73%62%47%38%3D", "url-decode > base64-decode")
    json = JSON.parse(Gori::CLI::Run.decoder_json_for_spec(result, nil))
    steps = json["steps"].as_a
    steps.size.should eq(2)
    steps[0]["output"].as_s.should eq("SGVsbG8=") # the url-decode result feeds step 2
    steps[1]["output"].as_s.should eq("Hello")
    json["output"].as_s.should eq("Hello")
  end

  it "reports an unknown converter as a 1-BASED failed_at, not a 0-based index" do
    # `failed_at` is printed back to the user as "step #N"; emitting the raw 0-based index
    # would point at the wrong converter in every chain longer than one.
    result = run_chain("x", "url-decode > definitely-not-a-converter")
    json = JSON.parse(Gori::CLI::Run.decoder_json_for_spec(result, nil))
    json["ok"].as_bool.should be_false
    json["failed_at"].as_i.should eq(2)
    json["steps"].as_a[1]["state"].as_s.should eq("unknown")
  end

  it "honours an explicit --output mode on the FINAL value only" do
    # Intermediate steps always render as-is (auto); forcing hex on them would bury the
    # very thing the per-step view exists to show.
    result = run_chain("hi", "sha256")
    auto = JSON.parse(Gori::CLI::Run.decoder_json_for_spec(result, nil))
    forced = JSON.parse(Gori::CLI::Run.decoder_json_for_spec(result, Gori::Decoder::RenderAs::Base64))
    forced["render"].as_s.should eq("base64")
    forced["output"].as_s.should_not eq(auto["output"].as_s)
    # the step's own output keeps the auto rendering in BOTH documents
    forced["steps"].as_a[0]["output"].as_s.should eq(auto["steps"].as_a[0]["output"].as_s)
  end

  it "renders binary output in a JSON-safe encoding, never raw bytes" do
    # Decoder input is routinely attacker-controlled captured traffic; a base64 blob that
    # decodes to arbitrary bytes must not put invalid UTF-8 into the JSON document.
    binary = Base64.strict_encode(Bytes[0x00, 0xFF, 0xFE, 0x80])
    json_str = Gori::CLI::Run.decoder_json_for_spec(run_chain(binary, "base64-decode"), nil)
    json_str.valid_encoding?.should be_true
    json = JSON.parse(json_str)
    json["render"].as_s.should_not eq("text") # auto picked a byte-safe rendering
    json["output"].as_s.valid_encoding?.should be_true
  end
end

# `gori run decoder <chain>` where the chain is only separators. The DECISION and the
# MESSAGE are split out of the abort for the same reason `list_leftover_error` is —
# `abort` calls `exit` and cannot run in-process.
describe "gori run decoder <chain>" do
  it "proceeds for a chain that has converter tokens" do
    Gori::CLI::Run.decoder_empty_chain_error("base64-decode").should be_nil
    Gori::CLI::Run.decoder_empty_chain_error(" hex , url-encode ").should be_nil
  end

  it "refuses a chain that is only separators, which would echo the input back as a success" do
    # `Chain.run` treats a zero-token spec as the IDENTITY, so `gori run decoder '>' hello`
    # printed `hello` and exited 0 — a chain the operator typed wrong reported as a decode
    # that worked. The MCP `decode` tool already refuses exactly this shape by name.
    ["", ">", ",", "|", " > | , ", ">>"].each do |chain|
      msg = Gori::CLI::Run.decoder_empty_chain_error(chain)
      msg.should_not be_nil
      msg.not_nil!.should contain("no converter tokens")
    end
  end
end

describe "gori run decoder --format json with --output text" do
  it "keeps the document parseable when text is forced over binary bytes" do
    binary = Base64.strict_encode(Bytes[0x00, 0xFF, 0xFE, 0x80])
    json_str = Gori::CLI::Run.decoder_json_for_spec(
      run_chain(binary, "base64-decode"), Gori::Decoder::RenderAs::Text)
    json_str.valid_encoding?.should be_true
    json = JSON.parse(json_str)
    json["render"].as_s.should_not eq("text")
    json["output"].as_s.valid_encoding?.should be_true
  end
end

describe "gori run decoder list" do
  # `quoted-printable-encode` is 23 chars; a fixed `ljust(22)` put its row's columns one cell
  # off the rest (and a long saved-chain name many more).
  it "aligns the category column for every converter, measured rather than fixed" do
    lines = Gori::CLI::Run.decoder_list_lines(Gori::Decoder.shared_registry)
    cols = lines.map { |l| l.index(/  (encoding|compression|serialization|hash|token|escape|text|saved)  /).not_nil! }
    cols.uniq.size.should eq 1
  end
end

describe "gori run decoder input" do
  it "refuses --input together with a 2nd positional rather than silently preferring one" do
    Gori::CLI::Run.decoder_input_twice_error("a", "b").not_nil!.should contain("twice")
    Gori::CLI::Run.decoder_input_twice_error("a", nil).should be_nil
    Gori::CLI::Run.decoder_input_twice_error(nil, "b").should be_nil
  end
end
