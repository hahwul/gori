require "../spec_helper"
require "json"

# `gori run notes create` takes its body from --text, positional args, or STDIN — and its own
# banner suggests `some-tool | gori run notes create`, so piping a gzip/binary response body
# (or a file the external $EDITOR wrote) stores raw non-UTF-8 bytes. The settings KV
# round-trips them verbatim, so the note-reading MCP tools were emitting an invalid byte onto
# a JSON-RPC line — the exact protocol violation `Serialize.text`'s contract exists to prevent
# ("every string that ORIGINATED OUTSIDE gori must pass through here before it reaches
# JSON::Builder"), and the same one `Serialize.issue` already guards for an issue's fields.
private def with_notes_store(text : String, &)
  path = File.tempname("gori-mcp-notes", ".db")
  store = Gori::Store.open(path)
  begin
    store.set_setting(Gori::Notes::DOCS_KEY,
      Gori::Notes.serialize(0, [Gori::Notes::NoteEntry.new(7_i64, text)], 8_i64))
    yield Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "MCP note tools — JSON-RPC UTF-8" do
  it "list_notes scrubs an invalid byte res of the title" do
    with_notes_store(String.new(Bytes[0x68, 0x69, 0x80, 0x0a, 0x78])) do |tools|
      res = tools.call("list_notes", JSON.parse("{}")).text
      res.valid_encoding?.should be_true
      JSON.parse(res)["notes"][0]["title"].as_s.should eq("hi\u{FFFD}")
    end
  end

  it "get_note scrubs an invalid byte res of the body and the title" do
    with_notes_store(String.new(Bytes[0x68, 0x69, 0x80, 0x0a, 0x78])) do |tools|
      res = tools.call("get_note", JSON.parse(%({"id":7}))).text
      res.valid_encoding?.should be_true
      note = JSON.parse(res)
      note["text"].as_s.valid_encoding?.should be_true
      # `scrub_only`, not `one_line`: a note is multi-line BY DESIGN, so its line break stays.
      note["text"].as_s.should contain('\n')
      note["title"].as_s.should eq("hi\u{FFFD}")
    end
  end

  it "leaves a valid note untouched" do
    with_notes_store("# Findings\nbody") do |tools|
      note = JSON.parse(tools.call("get_note", JSON.parse(%({"id":7}))).text)
      note["text"].as_s.should eq("# Findings\nbody")
      note["title"].as_s.should eq("# Findings")
    end
  end

  it "still reports Untitled for a blank note" do
    with_notes_store("   \n\t") do |tools|
      note = JSON.parse(tools.call("get_note", JSON.parse(%({"id":7}))).text)
      note["title"].as_s.should eq("Untitled")
    end
  end
end

describe "MCP issue tools — JSON-RPC UTF-8" do
  it "scrubs a linked flow's url/label, not just the issue's own fields" do
    path = File.tempname("gori-mcp-issues", ".db")
    store = Gori::Store.open(path)
    begin
      primary = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/a", http_version: "HTTP/1.1",
        head: "GET /a HTTP/1.1\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
      linked = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: String.new(Bytes[0x2f, 0x80, 0x61]), http_version: "HTTP/1.1",
        head: "GET /b HTTP/1.1\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
      iid = store.insert_issue("t", Gori::Store::Severity::Low, "h.test", primary)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, iid, Gori::Store::LinkRefKind::Flow, linked)

      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      %w[list_issues get_issue].each do |name|
        args = name == "get_issue" ? JSON.parse(%({"id":#{iid}})) : JSON.parse("{}")
        res = tools.call(name, args).text
        res.valid_encoding?.should be_true
        JSON.parse(res)
      end

      # `list_links` resolves the SAME Links::Resolved pair onto the same transport.
      links = tools.call("list_links", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid}}))).text
      links.valid_encoding?.should be_true
      JSON.parse(links)["links"][0]["url"].as_s.valid_encoding?.should be_true
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
