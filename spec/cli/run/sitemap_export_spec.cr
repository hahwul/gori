require "../../spec_helper"

# `gori run sitemap export` — the CLI glue over `Gori::Export::OpenApi` (the engine is
# spec/export/openapi_spec.cr). Pinned here: the format spellings, the `export` reserved first
# positional, and what the report on STDERR says (STDOUT carries the document alone).

module Gori::CLI::Run
  def self.openapi_yaml_format_for_spec?(v : String) : Bool
    openapi_yaml_format?(v)
  end

  def self.sitemap_export_notes_for_spec(report : Gori::Export::OpenApi::Report,
                                         choice : Gori::Redact::Policy::Choice?) : String
    io = IO::Memory.new
    sitemap_export_notes(report, choice, io)
    io.to_s
  end
end

private alias OAR = Gori::Export::OpenApi::Report

describe "gori run sitemap export" do
  it "reads openapi / openapi-yaml, and their json / yaml short forms" do
    Gori::CLI::Run.openapi_yaml_format_for_spec?("openapi").should be_false
    Gori::CLI::Run.openapi_yaml_format_for_spec?("JSON").should be_false
    Gori::CLI::Run.openapi_yaml_format_for_spec?("openapi-yaml").should be_true
    Gori::CLI::Run.openapi_yaml_format_for_spec?("yaml").should be_true
  end

  it "reserves `export` as the first positional, like tag and params" do
    err = Gori::CLI::Run.reserved_query_verb_error(["export", "host:x"], "sitemap",
      ["tag", "params", "export"], "tag, params, export")
    err.should_not be_nil
  end

  it "reports the size, the hosts, what was skipped and the caps on STDERR" do
    report = OAR.new
    report.operations = 4
    report.paths = 3
    report.flows_read = 9
    report.hosts = ["a.test", "b.test"]
    report.endpoints_dropped = 2
    report.skip(Gori::Export::OpenApi::Skip::Gori)
    out = Gori::CLI::Run.sitemap_export_notes_for_spec(report, nil)
    lines = out.lines
    lines[0].should eq("gori run sitemap export: 4 operations on 3 paths from 9 flows across 2 hosts")
    lines[1].should contain("--host H gives one API per document")
    out.should contain("skipped 1 sent by gori")
    out.should contain("2 operations left out (max endpoints)")
    out.should_not contain("sanitized") # no examples, no redaction sentence
  end

  it "says what an empty export read" do
    Gori::CLI::Run.sitemap_export_notes_for_spec(OAR.new, nil)
      .should start_with("gori run sitemap export: no operations (0 flows read")
  end

  it "names the profile, a dead pattern and an unsaved salt when examples were redacted" do
    profile = Gori::Redact::Profile.new(name: "strict", json_fields: ["x"], patterns: ["(unclosed"])
    choice = Gori::Redact::Policy::Choice.new(matcher: Gori::Redact::Matcher.new(profile), salt_persisted: false)
    out = Gori::CLI::Run.sitemap_export_notes_for_spec(OAR.new, choice)
    out.should contain(%(examples sanitized with profile "strict"))
    out.should contain("redaction pattern skipped, it does not compile — (unclosed")
    out.should contain("will NOT match another session's")
  end
end
