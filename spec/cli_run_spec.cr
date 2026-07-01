require "./spec_helper"
require "json"

# Builds a minimal FlowDetail without touching the DB (the structs have public
# initializers) — enough to exercise the pure reconstruction/formatting code.
private def flow_detail(scheme : String, host : String, port : Int32, request_head : String,
                        request_body : Bytes? = nil, http_version = "HTTP/1.1",
                        target = "/", response_head : String? = nil, response_body : String? = nil,
                        request_body_truncated = false)
  row = Gori::Store::FlowRow.new(
    id: 7_i64, created_at: 0_i64, scheme: scheme, method: "GET", host: host, port: port,
    target: target, status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, http_version, request_head.to_slice, request_body,
    response_head.try(&.to_slice), response_body.try(&.to_slice),
    request_body_truncated: request_body_truncated)
end

private def flow_row(*, target : String, host : String, status : Int32?, state : Gori::Store::FlowState)
  Gori::Store::FlowRow.new(
    id: 42_i64, created_at: 1_700_000_000_000_000_i64, scheme: "https", method: "GET",
    host: host, port: 443, target: target, status: status, size: 1536_i64, state: state,
    response_size: 1400_i64, duration_us: 3000_i64, content_type: "text/html")
end

private def with_store(&)
  path = File.tempname("gori-clirun", ".db")
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

describe Gori::Replay::FlowRequest do
  it "rewrites an absolute-form request line to origin-form, keeping the rest exact" do
    head = "GET http://example.com/a?b=1 HTTP/1.1\r\nHost: example.com\r\nX-T: 1\r\n\r\n"
    built = Gori::Replay::FlowRequest.build(flow_detail("http", "example.com", 80, head))
    String.new(built.bytes).should eq("GET /a?b=1 HTTP/1.1\r\nHost: example.com\r\nX-T: 1\r\n\r\n")
    built.target.should eq("http://example.com") # default port omitted
    built.http2.should be_false
  end

  it "leaves an origin-form request byte-exact and derives the https target" do
    head = "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n"
    built = Gori::Replay::FlowRequest.build(flow_detail("https", "api.test", 443, head))
    String.new(built.bytes).should eq(head)
    built.target.should eq("https://api.test")
  end

  it "keeps a non-default port in the target" do
    built = Gori::Replay::FlowRequest.build(flow_detail("https", "api.test", 8443, "GET / HTTP/1.1\r\n\r\n"))
    built.target.should eq("https://api.test:8443")
  end

  it "flags HTTP/2 flows" do
    built = Gori::Replay::FlowRequest.build(flow_detail("https", "h", 443, "GET / HTTP/1.1\r\n\r\n", http_version: "HTTP/2"))
    built.http2.should be_true
  end

  it "preserves a binary body byte-for-byte (no text round-trip corruption)" do
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\n"
    body = Bytes[0x00, 0x0A, 0xFF, 0x0D] # contains LF/CR bytes a line-splitter would mangle
    built = Gori::Replay::FlowRequest.build(flow_detail("https", "h", 443, head, request_body: body))
    expected = head.to_slice.to_a + body.to_a
    built.bytes.to_a.should eq(expected)
  end

  it "rewrites the request line but keeps an absolute-form body exact" do
    head = "POST http://h/p HTTP/1.1\r\nHost: h\r\n\r\n"
    body = Bytes[0x0A, 0x41, 0x0A]
    built = Gori::Replay::FlowRequest.build(flow_detail("http", "h", 80, head, request_body: body))
    String.new(built.bytes).should eq("POST /p HTTP/1.1\r\nHost: h\r\n\r\n\nA\n")
  end

  it "re-syncs Content-Length to the stored body when the capture was truncated" do
    # Head over-promises CL: 9999 but only 3 bytes survived the 8 MiB cap — replaying the
    # original CL would hang the origin. build() rewrites CL to the actual length.
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 9999\r\nX-T: 1\r\n\r\n"
    body = Bytes[0x41, 0x42, 0x43] # "ABC"
    built = Gori::Replay::FlowRequest.build(
      flow_detail("http", "h", 80, head, request_body: body, request_body_truncated: true))
    String.new(built.bytes).should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nX-T: 1\r\n\r\nABC")
  end

  it "leaves Content-Length untouched when the body was NOT truncated" do
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n"
    body = Bytes[0x41, 0x42, 0x43]
    built = Gori::Replay::FlowRequest.build(flow_detail("http", "h", 80, head, request_body: body))
    String.new(built.bytes).should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nABC")
  end

  it "re-frames a truncated CHUNKED request to Content-Length so it can't hang" do
    # A chunked body cut at the cap (no terminating 0-chunk) would block the origin; replace
    # Transfer-Encoding with a Content-Length over the stored bytes so the request terminates.
    head = "POST /u HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
    body = "5\r\nhello\r\n".to_slice # 10 bytes of wire-form chunk data (cut before the 0-chunk)
    built = Gori::Replay::FlowRequest.build(
      flow_detail("http", "h", 80, head, request_body: body, request_body_truncated: true))
    String.new(built.bytes).should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\n5\r\nhello\r\n")
  end

  it "preserves a bare-LF request-line terminator when rewriting (no mixed endings)" do
    head = "GET http://h/p HTTP/1.1\nHost: h\n\n" # LF-only, absolute-form
    built = Gori::Replay::FlowRequest.build(flow_detail("http", "h", 80, head))
    String.new(built.bytes).should eq("GET /p HTTP/1.1\nHost: h\n\n") # stays LF — no \r introduced
  end

  it "parses targets (the inverse of build_target)" do
    Gori::Replay::FlowRequest.parse_target("https://h").should eq({"https", "h", 443})
    Gori::Replay::FlowRequest.parse_target("http://h:8080").should eq({"http", "h", 8080})
    Gori::Replay::FlowRequest.parse_target("h:9000").should eq({"http", "h", 9000}) # bare → http
    Gori::Replay::FlowRequest.parse_target("https://h:8443/p").should eq({"https", "h", 8443})
  end

  it "only rewrites a well-formed absolute request line" do
    Gori::Replay::FlowRequest.rewrite_request_line("GET http://e/a HTTP/1.1").should eq("GET /a HTTP/1.1")
    Gori::Replay::FlowRequest.rewrite_request_line("GET /a HTTP/1.1").should be_nil # already origin-form
    Gori::Replay::FlowRequest.rewrite_request_line("garbage").should be_nil
  end
end

describe Gori::Findings::Export do
  it "serialises findings to JSON with the documented fields" do
    findings = [
      Gori::Store::Finding.new(1_i64, 10_i64, 20_i64, "XSS", Gori::Store::Severity::High,
        "shop.test", 13_i64, "reflected", Gori::Store::Status::Confirmed),
      Gori::Store::Finding.new(2_i64, 11_i64, 11_i64, "note", Gori::Store::Severity::Info,
        nil, nil, "", Gori::Store::Status::Open),
    ]
    parsed = JSON.parse(Gori::Findings::Export.json(findings)).as_a
    parsed.size.should eq(2)
    parsed[0]["title"].as_s.should eq("XSS")
    parsed[0]["severity"].as_s.should eq("high")
    parsed[0]["status"].as_s.should eq("confirmed")
    parsed[0]["flow_id"].as_i.should eq(13)
    parsed[1]["host"].raw.should be_nil
    parsed[1]["flow_id"].raw.should be_nil
  end

  it "renders a Markdown report with severity/status labels and notes" do
    with_store do |store|
      findings = [Gori::Store::Finding.new(1_i64, 0_i64, 0_i64, "Reflected XSS",
        Gori::Store::Severity::High, "shop.test", nil, "encode on output", Gori::Store::Status::Open)]
      md = Gori::Findings::Export.markdown(findings, store, "demo")
      md.should contain("# Findings — demo")
      md.should contain("## [high] Reflected XSS")
      md.should contain("**Severity:** high")
      md.should contain("**Status:** open")
      md.should contain("encode on output")
    end
  end

  it "embeds linked-flow evidence in the Markdown report" do
    with_store do |store|
      req = Gori::Store::CapturedRequest.new(
        created_at: 0_i64, scheme: "https", host: "api.test", port: 443, method: "GET",
        target: "/v1/debug", http_version: "HTTP/1.1",
        head: "GET /v1/debug HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice)
      fid = store.insert_flow(req)
      store.flush
      findings = [Gori::Store::Finding.new(1_i64, 0_i64, 0_i64, "leak",
        Gori::Store::Severity::Medium, "api.test", fid, "", Gori::Store::Status::Open)]
      md = Gori::Findings::Export.markdown(findings, store, "demo")
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
      findings = [Gori::Store::Finding.new(1_i64, 0_i64, 0_i64, "creds in body",
        Gori::Store::Severity::High, "api.test", fid, "", Gori::Store::Status::Open)]
      md = Gori::Findings::Export.markdown(findings, store, "demo")
      # one blank line between the last header and the body — not three
      md.should contain("Content-Length: 9\n\nuser=root")
      md.should_not contain("Content-Length: 9\n\n\nuser=root")
    end
  end
end

describe Gori::QL do
  # `gori run history -q` relies on this: a query that fails to compile to any
  # clause collapses to the match-all EMPTY filter. The CLI special-cases that so
  # a typo like `status:>=foo` errors instead of silently dumping every flow.
  it "collapses an un-compilable query to EMPTY (so the CLI can reject it)" do
    Gori::QL.parse("status:>=foo").should eq(Gori::QL::EMPTY)
    Gori::QL.parse("-status:bar").should eq(Gori::QL::EMPTY)
    Gori::QL.parse("login").should_not eq(Gori::QL::EMPTY)
    Gori::QL.parse("status:>=500").should_not eq(Gori::QL::EMPTY)
  end
end

describe Gori::CLI::Output do
  it "shows an absolute-form target as-is and prefixes an origin-form one with the host" do
    abs = Gori::CLI::Output.flow_row_text(flow_row(target: "http://e.test/a", host: "e.test", status: 200, state: Gori::Store::FlowState::Complete))
    abs.should contain("http://e.test/a")
    abs.should_not contain("e.testhttp://") # no double host

    rel = Gori::CLI::Output.flow_row_text(flow_row(target: "/a", host: "api.test", status: 200, state: Gori::Store::FlowState::Complete))
    rel.should contain("api.test/a")
  end

  it "marks a pending flow with a dash status and a state tag" do
    txt = Gori::CLI::Output.flow_row_text(flow_row(target: "/p", host: "h", status: nil, state: Gori::Store::FlowState::Pending))
    txt.should contain("—")
    txt.should contain("[Pending]")
  end

  it "emits a valid JSON object with the expected keys" do
    json = JSON.parse(Gori::CLI::Output.flow_row_json(flow_row(target: "/a", host: "h", status: 200, state: Gori::Store::FlowState::Complete)))
    json["id"].as_i.should eq(42)
    json["method"].as_s.should eq("GET")
    json["status"].as_i.should eq(200)
    json["state"].as_s.should eq("Complete")
  end

  it "humanises sizes and durations" do
    Gori::CLI::Output.human_size(500_i64).should eq("500B")
    Gori::CLI::Output.human_size(1536_i64).should eq("1.5kB")
    Gori::CLI::Output.human_us(500_i64).should eq("500µs")
    Gori::CLI::Output.human_us(1_500_i64).should eq("1.5ms")
  end

  it "scales human_size up to GB and TB (no '1024.0MB')" do
    Gori::CLI::Output.human_size(1_073_741_824_i64).should eq("1.0GB")     # exactly 1 GiB
    Gori::CLI::Output.human_size(5_368_709_120_i64).should eq("5.0GB")     # 5 GiB
    Gori::CLI::Output.human_size(2_199_023_255_552_i64).should eq("2.0TB") # 2 TiB
  end

  it "serialises a prism group to JSON with the documented fields (incl. remediation)" do
    g = Gori::Prism::Group.new("secret_in_url", "infoleak", "api.test", "Secret in URL",
      Gori::Store::Severity::High, 3, ["https://api.test/a", "https://api.test/b"], "token", 7_i64)
    parsed = JSON.parse(Gori::CLI::Output.prism_group_json(g))
    parsed["code"].as_s.should eq("secret_in_url")
    parsed["category"].as_s.should eq("infoleak")
    parsed["severity"].as_s.should eq("high")
    parsed["hit_count"].as_i.should eq(3)
    parsed["affected"].as_a.size.should eq(2)
    parsed["affected_count"].as_i.should eq(2)
    parsed["evidence"].as_s.should eq("token")
    parsed["sample_flow_id"].as_i.should eq(7)
    parsed["remediation"].as_s.should_not be_empty
  end

  it "renders prism text with the severity tag, ×hit_count, and a representative affected URL" do
    g = Gori::Prism::Group.new("missing_csp", "headers", "api.test", "Missing CSP",
      Gori::Store::Severity::Medium, 4,
      ["https://api.test/a", "https://api.test/b", "https://api.test/c"], nil, nil)
    txt = Gori::CLI::Output.prism_group_text(g)
    txt.should contain("[medium]")
    txt.should contain("missing_csp")
    txt.should contain("×4")
    txt.should contain("https://api.test/a")
    txt.should contain("(+2 more)") # 3 affected − 1 shown
  end

  it "formats a note listing row: 1-based index, title, '*' for the active note" do
    row = Gori::CLI::Output.note_row_text(1, "scope\nmore", current: true)
    row.should contain("* 2")                                                           # 0-based 1 → shown as #2
    row.should contain("scope")                                                         # title = first non-blank line
    row.should contain("(2 lines, ")                                                    # plural
    Gori::CLI::Output.note_row_text(0, "x", current: false).should contain(" 1")        # no '*'
    Gori::CLI::Output.note_row_text(0, "x", current: false).should contain("(1 line, ") # singular
  end

  it "falls back to 'note N' in a row for a blank note" do
    Gori::CLI::Output.note_row_text(2, "   \n\t", current: false).should contain("note 3")
  end

  it "emits a single-note JSON object with the documented fields (text only when asked)" do
    full = JSON.parse(Gori::CLI::Output.note_object_json(0, "Title\nbody", current: true, with_text: true))
    full["index"].as_i.should eq(1)
    full["title"].as_s.should eq("Title")
    full["lines"].as_i.should eq(2)
    full["bytes"].as_i.should eq("Title\nbody".bytesize)
    full["current"].as_bool.should be_true
    full["text"].as_s.should eq("Title\nbody")

    summary = JSON.parse(Gori::CLI::Output.note_object_json(0, "Title\nbody", current: false, with_text: false))
    summary["text"]?.should be_nil # summary omits the body
    summary["title"].as_s.should eq("Title")
  end

  it "emits the whole note set as a JSON array, marking the active note" do
    doc = Gori::Notes::Doc.new(1, ["one", "two"])
    arr = JSON.parse(Gori::CLI::Output.notes_array_json(doc, with_text: false)).as_a
    arr.size.should eq(2)
    arr[0]["index"].as_i.should eq(1)
    arr[0]["current"].as_bool.should be_false
    arr[1]["current"].as_bool.should be_true # cur == 1
    arr[0]["text"]?.should be_nil            # summary array

    with_text = JSON.parse(Gori::CLI::Output.notes_array_json(doc, with_text: true)).as_a
    with_text[1]["text"].as_s.should eq("two")
  end
  it "renders the sitemap as an indented tree with counts, methods, and a path tag" do
    hosts = Gori::Sitemap.build([
      {"acme.test", "GET", "/"},
      {"acme.test", "POST", "/api/orders"},
      {"acme.test", "GET", "/api/users"},
    ])
    Gori::Sitemap.stamp_tags!(hosts, { {"acme.test", "/api"} => "payment flow" })
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("acme.test  (3 paths)")
    txt.should contain("├─ ") # tree guide
    txt.should contain("orders  [POST]")
    txt.should contain("api  # payment flow") # tag on the folder node, no methods
  end

  it "collapses a folded numeric group in the text tree with a value count" do
    hosts = Gori::Sitemap.build((1001..1012).map { |i| {"h", "GET", "/p/#{i}"} })
    hosts.each { |h| Gori::Sitemap.group_sequences!(h) }
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("[1001, 1002, 1003 … +9]  (12 values)")
    txt.should_not contain("1010") # a folded child is hidden in the collapsed text tree
  end

  it "lists every endpoint flat in the paths format (numeric folding irrelevant)" do
    hosts = Gori::Sitemap.build([
      {"acme.test", "GET", "/api/users"},
      {"acme.test", "POST", "/api/users"},
    ])
    Gori::CLI::Output.sitemap_paths(hosts).should eq("GET,POST  acme.test/api/users\n")
  end

  it "emits the sitemap as JSON with host/endpoint/children fields and an empty array when blank" do
    hosts = Gori::Sitemap.build([{"acme.test", "GET", "/api/users"}])
    Gori::Sitemap.stamp_tags!(hosts, { {"acme.test", "/api"} => "memo" })
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    json = JSON.parse(Gori::CLI::Output.sitemap_json(hosts)).as_a
    json.size.should eq(1)
    json[0]["host"].as_s.should eq("acme.test")
    json[0]["endpoints"].as_i.should eq(1)
    api = json[0]["children"].as_a.find! { |c| c["label"].as_s == "api" }
    api["tag"].as_s.should eq("memo")
    users = api["children"].as_a.find! { |c| c["label"].as_s == "users" }
    users["path"].as_s.should eq("/api/users")
    users["methods"].as_a.map(&.as_s).should eq(["GET"])

    Gori::CLI::Output.sitemap_json([] of Gori::Sitemap::Node).should eq("[]")
  end
end

describe Gori::Notes do
  # Doc is a record (struct) → value equality, so whole-Doc comparison avoids
  # unwrapping the nilable parse result (and keeps the spec ameba-clean).
  it "parses a well-formed document set" do
    Gori::Notes.parse(%({"cur":1,"notes":["a","b"]})).should eq(Gori::Notes::Doc.new(1, ["a", "b"]))
  end

  it "defaults cur to 0 and coerces non-string note entries to empty strings" do
    Gori::Notes.parse(%({"notes":[1,"x",null]})).should eq(Gori::Notes::Doc.new(0, ["", "x", ""]))
  end

  it "treats an empty notes array as a (non-nil) empty set" do
    Gori::Notes.parse(%({"cur":0,"notes":[]})).should eq(Gori::Notes::Doc.new(0, [] of String))
  end

  it "exposes size/empty? on a Doc" do
    Gori::Notes::Doc.new(0, ["a", "b"]).size.should eq(2)
    Gori::Notes::Doc.new(0, ["a", "b"]).empty?.should be_false
    Gori::Notes::Doc.new(0, [] of String).empty?.should be_true
  end

  it "returns nil for malformed JSON or a missing notes key (so callers fall back)" do
    Gori::Notes.parse("not json {{{").should be_nil
    Gori::Notes.parse(%({"cur":0})).should be_nil
  end

  it "round-trips through serialize/parse" do
    raw = Gori::Notes.serialize(2, ["alpha", "beta\ngamma", ""])
    Gori::Notes.parse(raw).should eq(Gori::Notes::Doc.new(2, ["alpha", "beta\ngamma", ""]))
  end

  it "loads the JSON set, the legacy single note, and prefers the JSON set over legacy" do
    with_store do |store|
      Gori::Notes.load(store).empty?.should be_true # nothing stored yet

      store.set_setting("notes", "legacy body")
      legacy = Gori::Notes.load(store)
      legacy.texts.should eq(["legacy body"]) # migrated single note

      store.set_setting("notes.docs", %({"cur":0,"notes":["fresh"]}))
      Gori::Notes.load(store).texts.should eq(["fresh"]) # JSON set wins
    end
  end

  it "falls back through malformed JSON to the legacy key, then to empty" do
    with_store do |store|
      store.set_setting("notes.docs", "not json {{{")
      Gori::Notes.load(store).empty?.should be_true # malformed + no legacy → empty

      store.set_setting("notes", "kept")
      Gori::Notes.load(store).texts.should eq(["kept"]) # malformed docs → legacy
    end
  end

  it "derives a title from the first non-blank line (trimmed, CRLF-tolerant); nil when blank" do
    Gori::Notes.title("  hello world  ").should eq("hello world")
    Gori::Notes.title("\n\n  second\nthird").should eq("second") # leading blank lines skipped
    Gori::Notes.title("done\r\nmore").should eq("done")          # trailing CR trimmed
    Gori::Notes.title("").should be_nil
    Gori::Notes.title("   \n\t ").should be_nil # all whitespace
  end

  it "counts editor lines (an empty note is one line)" do
    Gori::Notes.line_count("").should eq(1)
    Gori::Notes.line_count("a\nb").should eq(2)
    Gori::Notes.line_count("a\n").should eq(2) # trailing newline → a second (empty) line
  end
end
