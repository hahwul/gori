require "../../spec_helper"

# `gori run show --redact` / `gori run redact` — the shared flag parsing, the sentences a
# sanitized artifact carries on STDERR, and the preview table. The CLI glue is `private`
# (command wiring, not a public API), so the module is reopened for thin bare-call wrappers —
# the same whitebox trick spec/cli/run/history_spec.cr uses for `show_json`.
module Gori::CLI::Run
  def self.redact_flags_for_spec(args : Array(String)) : RedactFlags
    flags = RedactFlags.new
    parser = OptionParser.new { |p| redact_options(p, flags) }
    parser.parse(args)
    flags
  end

  def self.redact_notes_for_spec(report : Redact::Report, salt_persisted = true) : String
    io = IO::Memory.new
    redact_notes(report, "show", salt_persisted, io)
    io.to_s
  end

  def self.redact_preview_for_spec(report : Redact::Report) : String
    io = IO::Memory.new
    print_redact_preview(report, "show", io, io)
    io.to_s
  end

  def self.redact_rule_counts_for_spec(p : Redact::Profile) : String
    redact_rule_counts(p)
  end
end

private def report_for(profile = Gori::Redact::DEFAULT_PROFILE,
                       request_body = %({"password":"pw"}),
                       response_body = %({"access_token":"t"}))
  row = Gori::Store::FlowRow.new(
    id: 3_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "h.test",
    port: 443, target: "/login", status: 200, size: 0_i64,
    state: Gori::Store::FlowState::Complete)
  detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1",
    "POST /login HTTP/1.1\r\nContent-Type: application/json\r\n\r\n".to_slice,
    request_body.to_slice,
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
    response_body.to_slice)
  before = Gori::Redact.salt
  Gori::Redact.salt = "spec-salt"
  begin
    _, report = Gori::Redact::Wire.flow(detail, Gori::Redact::Matcher.new(profile))
    report
  ensure
    Gori::Redact.salt = before
  end
end

describe "gori run redact flags" do
  it "reads --redact as on with no profile named" do
    f = Gori::CLI::Run.redact_flags_for_spec(["--redact"])
    f.mode.should be_true
    f.profile.should be_nil
    f.preview?.should be_false
  end

  it "reads a profile name in either spelling" do
    Gori::CLI::Run.redact_flags_for_spec(["--redact=strict"]).profile.should eq "strict"
    Gori::CLI::Run.redact_flags_for_spec(["--redact", "strict"]).profile.should eq "strict"
  end

  it "reads --no-redact as an explicit off" do
    f = Gori::CLI::Run.redact_flags_for_spec(["--no-redact"])
    f.mode.should be_false
  end

  it "leaves the mode unset when neither flag was passed, so the config decides" do
    Gori::CLI::Run.redact_flags_for_spec([] of String).mode.should be_nil
  end

  it "reads --redact-preview as on plus preview" do
    f = Gori::CLI::Run.redact_flags_for_spec(["--redact-preview"])
    f.mode.should be_true
    f.preview?.should be_true
  end
end

describe "the sanitized-artifact notes" do
  it "names the profile, the count, and what it did NOT redact" do
    notes = Gori::CLI::Run.redact_notes_for_spec(report_for)
    notes.should contain "profile \"default\""
    notes.should contain "2 values redacted"
    notes.should contain "heads, URLs and query strings are NOT redacted"
  end

  it "says so when nothing matched, rather than staying silent" do
    notes = Gori::CLI::Run.redact_notes_for_spec(
      report_for(request_body: %({"a":1}), response_body: %({"b":2})))
    notes.should contain "0 values redacted"
  end

  it "reports a pattern that does not compile" do
    profile = Gori::Redact::Profile.new("p", json_fields: ["password"], patterns: ["([oops"])
    Gori::CLI::Run.redact_notes_for_spec(report_for(profile))
      .should contain "redaction pattern skipped"
  end

  it "warns when the placeholder salt is only in memory" do
    Gori::CLI::Run.redact_notes_for_spec(report_for, salt_persisted: false)
      .should contain "will NOT match another session's"
  end
end

describe "the redaction preview" do
  it "lists a row per replacement, both sides, with the rule that fired" do
    lines = Gori::CLI::Run.redact_preview_for_spec(report_for).lines
    lines[0].should contain "request"
    lines[0].should contain "/password"
    lines[0].should contain "json_field password"
    lines[0].should contain "[REDACTED:"
    lines[1].should contain "response"
    lines[1].should contain "/access_token"
  end

  it "says plainly when a profile matches nothing here" do
    Gori::CLI::Run.redact_preview_for_spec(
      report_for(request_body: %({"a":1}), response_body: %({"b":2})))
      .should contain "no body values match profile \"default\""
  end
end

describe "the profile listing's rule counts" do
  it "counts each kind and pluralizes it" do
    Gori::CLI::Run.redact_rule_counts_for_spec(
      Gori::Redact::Profile.new("p", json_fields: ["a", "b"], json_pointers: ["/x"],
        form_keys: ["k"], patterns: ["r"]))
      .should eq "2 fields, 1 pointer, 1 form key, 1 pattern"
  end

  it "says so for a profile that would sanitize nothing" do
    Gori::CLI::Run.redact_rule_counts_for_spec(Gori::Redact::Profile.new("p"))
      .should eq "no rules"
  end
end
