require "../../spec_helper"
require "json"

# `gori run import` — which source flag was given, and how the result is reported. The
# abort paths (zero / two+ sources) call `exit`, so they can't be exercised in-process.

# Private CLI glue — reopen the module for thin bare-call wrappers (same whitebox trick
# the other CLI specs use).
module Gori::CLI::Run
  def self.import_source_for_spec(sources : Hash(Symbol, String?)) : {Symbol, String}
    import_source(sources)
  end

  def self.import_result_json_for_spec(kind : Symbol, path : String, result : Import::Result) : String
    import_result_json(kind, path, result)
  end

  def self.import_result_text_for_spec(kind : Symbol, path : String, result : Import::Result) : String
    import_result_text(kind, path, result)
  end
end

private def only(kind : Symbol, path : String) : Hash(Symbol, String?)
  sources = {} of Symbol => String?
  Gori::Import::LABELS.each_key { |k| sources[k] = nil }
  sources[kind] = path
  sources
end

describe "gori run import" do
  it "maps each source flag to its {kind, path}" do
    {har: "a.har", urls: "urls.txt", oas: "api.yaml",
     postman: "c.postman_collection.json", insomnia: "i.json", burp: "items.xml"}.each do |kind, path|
      Gori::CLI::Run.import_source_for_spec(only(kind, path)).should eq({kind, path})
    end
  end

  it "covers every kind Import.import_file dispatches on" do
    # A parser reachable from the TUI but not from `gori run import` is a wiring miss; the
    # flag table and the label table are edited in different files.
    Gori::Import::LABELS.each_key do |kind|
      Gori::CLI::Run.import_source_for_spec(only(kind, "f")).should eq({kind, "f"})
    end
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

  it "names the source with the same label the TUI card uses" do
    # One table (Import::LABELS) feeds the CLI line, the overlay title and the TUI toast, so
    # they cannot drift apart as sources are added.
    {har: "HAR", urls: "URLs", oas: "OpenAPI",
     postman: "Postman", insomnia: "Insomnia", burp: "Burp"}.each do |kind, label|
      Gori::CLI::Run.import_result_text_for_spec(kind, "f", Gori::Import::Result.new(count: 1))
        .should eq("imported 1 flow from #{label} · f")
      Gori::Tui::ImportOverlay.new(kind).label.should eq(label)
    end
  end
end
