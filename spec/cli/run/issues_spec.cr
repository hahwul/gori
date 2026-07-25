require "../../spec_helper"
require "json"

# `gori run issues` — the text listing row, and the JSON / Markdown reports the
# `--format` and `--export` flags write (Issues::Export, shared with the TUI's
# issues.export-md / issues.export-json verbs).

private def with_store(&)
  path = File.tempname("gori-cliissues", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def issue(id : Int64, title : String, severity : Gori::Store::Severity,
                  host : String?, flow_id : Int64?, notes = "",
                  status = Gori::Store::Status::Open) : Gori::Store::Issue
  Gori::Store::Issue.new(id, 0_i64, 0_i64, title, severity, host, flow_id, notes, status)
end

# `issues_text` is private CLI glue — reopen the module for a bare-call wrapper.
module Gori::CLI::Run
  def self.issues_text_for_spec(issues : Array(Gori::Store::Issue)) : String
    issues_text(issues)
  end
end

describe "gori run issues — the text listing" do
  it "leads with the id, then the [severity/status] pair, title, host and flow" do
    # Every triage subcommand addresses an issue BY ID, so the id has to be the first
    # thing on the row — copy-pasteable straight into `issues update <id>`.
    txt = Gori::CLI::Run.issues_text_for_spec([
      issue(12_i64, "Reflected XSS", Gori::Store::Severity::High, "shop.test", 7_i64),
    ])
    txt.should eq("#12  [high/open]  Reflected XSS  (shop.test)  flow#7")
  end

  it "omits the host and flow clauses when the issue has neither" do
    txt = Gori::CLI::Run.issues_text_for_spec([
      issue(3_i64, "manual note", Gori::Store::Severity::Info, nil, nil),
    ])
    txt.should eq("#3  [info/open]  manual note")
  end

  it "flattens a multi-line title so one issue is always one row" do
    # An issue title is free text (and can arrive from an MCP client); a raw newline would
    # split one issue across two rows and desync the id column from the title.
    txt = Gori::CLI::Run.issues_text_for_spec([
      issue(4_i64, "line one\nline two", Gori::Store::Severity::Low, "h\nevil", nil),
    ])
    txt.lines.size.should eq(1)
    txt.should_not contain('\n')
  end

  it "emits one row per issue with no trailing blank line" do
    txt = Gori::CLI::Run.issues_text_for_spec([
      issue(1_i64, "a", Gori::Store::Severity::Low, nil, nil),
      issue(2_i64, "b", Gori::Store::Severity::Low, nil, nil),
    ])
    txt.lines.size.should eq(2)
    txt.ends_with?('\n').should be_false
    Gori::CLI::Run.issues_text_for_spec([] of Gori::Store::Issue).should eq("")
  end
end

describe "gori run issues --format json" do
  it "serialises issues with the documented fields" do
    issues = [
      issue(1_i64, "XSS", Gori::Store::Severity::High, "shop.test", 13_i64, "reflected",
        Gori::Store::Status::Confirmed),
      issue(2_i64, "note", Gori::Store::Severity::Info, nil, nil),
    ]
    parsed = JSON.parse(Gori::Issues::Export.json(issues)).as_a
    parsed.size.should eq(2)
    parsed[0]["title"].as_s.should eq("XSS")
    parsed[0]["severity"].as_s.should eq("high")
    parsed[0]["status"].as_s.should eq("confirmed")
    parsed[0]["flow_id"].as_i.should eq(13)
    parsed[0]["links"].as_a.should be_empty
    parsed[1]["host"].raw.should be_nil
    parsed[1]["flow_id"].raw.should be_nil
  end

  it "serialises entity links" do
    with_store do |store|
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443, method: "GET",
        target: "/x", http_version: "HTTP/1.1",
        head: "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice))
      issue_id = store.insert_issue("linked", Gori::Store::Severity::Medium, "api.test", fid)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Repeater, 9_i64)
      parsed = JSON.parse(Gori::Issues::Export.json(store.issues, store)).as_a
      links = parsed[0]["links"].as_a
      links.size.should eq(1) # primary flow link is deduped from the export list
      links[0]["kind"].as_s.should eq("repeater")
      links[0]["ref_id"].as_i.should eq(9)
      links[0]["label"].as_s.should_not be_empty
    end
  end
end

describe "gori run issues --format markdown" do
  it "renders a report with severity/status labels and notes" do
    with_store do |store|
      issues = [issue(1_i64, "Reflected XSS", Gori::Store::Severity::High, "shop.test", nil,
        "encode on output")]
      md = Gori::Issues::Export.markdown(issues, store, "demo")
      md.should contain("# Issues — demo")
      md.should contain("## [high] Reflected XSS")
      md.should contain("**Severity:** high")
      md.should contain("**Status:** open")
      md.should contain("encode on output")
    end
  end

  it "embeds linked-flow evidence" do
    with_store do |store|
      req = Gori::Store::CapturedRequest.new(
        created_at: 0_i64, scheme: "https", host: "api.test", port: 443, method: "GET",
        target: "/v1/debug", http_version: "HTTP/1.1",
        head: "GET /v1/debug HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice)
      fid = store.insert_flow(req)
      store.flush
      issues = [issue(1_i64, "leak", Gori::Store::Severity::Medium, "api.test", fid)]
      md = Gori::Issues::Export.markdown(issues, store, "demo")
      md.should contain("### Request")
      md.should contain("GET /v1/debug HTTP/1.1")
      md.should contain("(##{fid})")
      # The header block's terminating CRLF CRLF is trimmed, so the last header
      # line abuts the closing fence (no stack of blank lines inside the block).
      md.should contain("Host: api.test\n```")
      md.should_not contain("\r\n\r\n")
    end
  end

  it "separates evidence headers from the body with exactly one blank line" do
    with_store do |store|
      req = Gori::Store::CapturedRequest.new(
        created_at: 0_i64, scheme: "https", host: "api.test", port: 443, method: "POST",
        target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: api.test\r\nContent-Length: 9\r\n\r\n".to_slice,
        body: "user=root".to_slice)
      fid = store.insert_flow(req)
      store.flush
      issues = [issue(1_i64, "creds in body", Gori::Store::Severity::High, "api.test", fid)]
      md = Gori::Issues::Export.markdown(issues, store, "demo")
      # one blank line between the last header and the body — not three
      md.should contain("Content-Length: 9\n\nuser=root")
      md.should_not contain("Content-Length: 9\n\n\nuser=root")
    end
  end

  it "scrubs control bytes on the STDOUT path but keeps a file export verbatim" do
    # The Markdown report embeds attacker-controlled evidence bodies; printed to a TTY a
    # raw OSC could drive the terminal. `--export PATH` writes the bytes untouched — a
    # saved file is not a live terminal, and stripping would corrupt captured evidence.
    raw = "head\e]0;pwned\a\ntail\ttab"
    scrubbed = Gori::Issues::Export.scrub_controls(raw)
    scrubbed.should_not contain('\e')
    scrubbed.should_not contain('\a')
    scrubbed.should contain("\n") # structure preserved
    scrubbed.should contain("\ttab")
  end
end
