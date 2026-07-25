require "../../spec_helper"
require "json"

# `gori run import` — which source flag was given, and how the result is reported. The
# abort paths (zero / two+ sources) call `exit`, so they can't be exercised in-process.

# Private CLI glue — reopen the module for thin bare-call wrappers (same whitebox trick
# the other CLI specs use).
module Gori::CLI::Run
  def self.import_source_for_spec(har : String?, oas : String?, urls : String?) : {Symbol, String}
    import_source(har, oas, urls)
  end

  def self.import_result_json_for_spec(kind : Symbol, path : String, result : Import::Result) : String
    import_result_json(kind, path, result)
  end

  def self.import_result_text_for_spec(kind : Symbol, path : String, result : Import::Result) : String
    import_result_text(kind, path, result)
  end
end

describe "gori run import" do
  it "maps each source flag to its {kind, path}" do
    Gori::CLI::Run.import_source_for_spec("a.har", nil, nil).should eq({:har, "a.har"})
    Gori::CLI::Run.import_source_for_spec(nil, "api.yaml", nil).should eq({:oas, "api.yaml"})
    Gori::CLI::Run.import_source_for_spec(nil, nil, "urls.txt").should eq({:urls, "urls.txt"})
  end

  it "carries kind, path, count and skipped in the JSON result" do
    result = Gori::Import::Result.new(count: 12, skipped: 3)
    json = JSON.parse(Gori::CLI::Run.import_result_json_for_spec(:har, "dump.har", result))
    json["kind"].as_s.should eq("har")
    json["path"].as_s.should eq("dump.har")
    json["count"].as_i.should eq(12)
    json["skipped"].as_i.should eq(3)
  end

  it "always reports `skipped` in JSON, even at zero" do
    # A script comparing count vs skipped must not have to special-case a missing key —
    # the text view drops the clause at zero, the machine contract does not.
    json = JSON.parse(Gori::CLI::Run.import_result_json_for_spec(:oas, "a.yaml", Gori::Import::Result.new(count: 1)))
    json["skipped"].as_i.should eq(0)
  end

  it "mirrors the TUI toast wording, with a skipped clause only when > 0" do
    clean = Gori::CLI::Run.import_result_text_for_spec(:oas, "api.json", Gori::Import::Result.new(count: 1))
    clean.should eq("imported 1 flow from OpenAPI · api.json")
    skipped = Gori::CLI::Run.import_result_text_for_spec(:urls, "u.txt", Gori::Import::Result.new(count: 5, skipped: 2))
    skipped.should eq("imported 5 flows from URLs · u.txt (2 entries skipped)")
  end

  it "singularises both counts independently" do
    one = Gori::CLI::Run.import_result_text_for_spec(:har, "d.har", Gori::Import::Result.new(count: 1, skipped: 1))
    one.should eq("imported 1 flow from HAR · d.har (1 entry skipped)")
    many = Gori::CLI::Run.import_result_text_for_spec(:har, "d.har", Gori::Import::Result.new(count: 0, skipped: 4))
    many.should eq("imported 0 flows from HAR · d.har (4 entries skipped)")
  end
end
