require "../../spec_helper"
require "json"

# `gori run show --find`: the matches of a regex over the bytes MCP `get_response_body_chunk`
# pages for the same side, so the offsets carry across surfaces.
module Gori::CLI::Run
  def self.show_find_json_for_spec(detail : Store::FlowDetail, f : ShowFind, request : Bool) : JSON::Any
    io = IO::Memory.new
    show_find(detail, f, request, true, Redact::Policy::Choice.new, io)
    JSON.parse(io.to_s)
  end
end

private def find_detail(request_head : String, response_body : String) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(
    id: 9_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "x.test", port: 443,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", request_head.to_slice, nil,
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, response_body.to_slice)
end

private def find_flags(pattern : String, include_sensitive = false) : Gori::CLI::Run::ShowFind
  f = Gori::CLI::Run::ShowFind.new
  f.pattern = pattern
  f.include_sensitive = include_sensitive
  f
end

describe "gori run show --find" do
  it "prints MCP's match shape over the response body" do
    j = Gori::CLI::Run.show_find_json_for_spec(find_detail("GET / HTTP/1.1\r\n\r\n", "x token=abc y"),
      find_flags("token=\\w+"), false)
    m = j["matches"][0]
    {m["offset"].as_i, m["length"].as_i, j["part"].as_s, j["has_more"].as_bool}.should eq({2, 9, "response", false})
    j["origin"].as_s.should eq("target")
  end

  it "withholds a request head carrying a credential, as paging does" do
    detail = find_detail("GET / HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n\r\n", "")
    j = Gori::CLI::Run.show_find_json_for_spec(detail, find_flags("s3cr3t"), true)
    j["matches"].as_a.should be_empty
    j["head_omitted"].as_bool.should be_true
    j["origin"].as_s.should eq("client")
    j = Gori::CLI::Run.show_find_json_for_spec(detail, find_flags("s3cr3t", include_sensitive: true), true)
    j["matches"][0]["offset"].as_i.should eq(38)
  end

  it "refuses the flags that do not fit" do
    redaction = Gori::CLI::Run::RedactFlags.new
    Gori::CLI::Run.show_find_error(find_flags("x"), :text, redaction).should be_nil
    Gori::CLI::Run.show_find_error(find_flags("x"), :har, redaction).not_nil!.should contain("--format har")
    Gori::CLI::Run.show_find_error(find_flags(""), :text, redaction).not_nil!.should contain("non-empty")
    tuned = Gori::CLI::Run::ShowFind.new
    tuned.tuned = true
    Gori::CLI::Run.show_find_error(tuned, :text, redaction).not_nil!.should contain("need --find")
    Gori::CLI::Run.show_find_error(find_flags("x"), :text, redaction, ["--original", "--max-body"])
      .not_nil!.should contain("--original, --max-body cannot apply")
    redaction.mode = true
    Gori::CLI::Run.show_find_error(find_flags("x"), :text, redaction).not_nil!.should contain("--redact")
  end

  it "refuses a redaction profile that is on by default, and one that does not resolve" do
    Gori::CLI::Run.show_find_choice_error(Gori::Redact::Policy::Choice.new).should be_nil
    on = Gori::Redact::Policy::Choice.new(matcher: Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE))
    Gori::CLI::Run.show_find_choice_error(on).not_nil!.should contain("--no-redact")
    bad = Gori::Redact::Policy::Choice.new(error: "no redaction profile named 'x'")
    Gori::CLI::Run.show_find_choice_error(bad).should eq("no redaction profile named 'x'")
  end
end
