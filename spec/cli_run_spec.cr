require "./spec_helper"
require "json"

# What is LEFT of the old monolithic `gori run` spec.
#
# MOVED to spec/cli/run/<subcommand>_spec.cr, mirroring src/gori/cli/run/:
#   history · sitemap · notes · issues · links · decoder · jwt · compare · project · import
#   plus spec/cli/run/replay_reconstruct_spec.cr — the P7 "never reject malformed input on
#   replay" invariant over Repeater::FlowRequest's HOSTILE inputs.
#
# STILL HERE, and why:
#   • describe Gori::Repeater::FlowRequest — the WELL-FORMED reconstruct cases (absolute→
#     origin rewrite, http2 flag, truncated-capture Content-Length/chunked re-frame).
#   • describe Gori::CLI::Output — the probe group JSON/text rows. `gori run probe` is an
#     active-sender subcommand, so its spec waits with the rest of them.
#   • describe Gori::Notes — the notes ENGINE (parse/serialize/load/title/line_count), not
#     the `gori run notes` output; spec/cli/run/notes_spec.cr covers the CLI formatting.
#   • The active-sender subcommands: repeater send (h1/WS), fuzz/mine/sequence host
#     overrides, intercept bridge state, probe categories. Their semantics are being
#     changed under separate issues, so specs written against today's behaviour would be
#     rewritten anyway — split them out with that work.
#
# Two more `gori run` specs predate the split and still sit at the top level:
# spec/cli_run_oast_stop_spec.cr and spec/cli_run_sequence_tokens_spec.cr (oast / sequence,
# also active-sender). Fold them into spec/cli/run/ when those subcommands are covered.

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

describe Gori::Repeater::FlowRequest do
  it "rewrites an absolute-form request line to origin-form, keeping the rest exact" do
    head = "GET http://example.com/a?b=1 HTTP/1.1\r\nHost: example.com\r\nX-T: 1\r\n\r\n"
    built = Gori::Repeater::FlowRequest.build(flow_detail("http", "example.com", 80, head))
    String.new(built.bytes).should eq("GET /a?b=1 HTTP/1.1\r\nHost: example.com\r\nX-T: 1\r\n\r\n")
    built.target.should eq("http://example.com") # default port omitted
    built.http2.should be_false
  end

  it "leaves an origin-form request byte-exact and derives the https target" do
    head = "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n"
    built = Gori::Repeater::FlowRequest.build(flow_detail("https", "api.test", 443, head))
    String.new(built.bytes).should eq(head)
    built.target.should eq("https://api.test")
  end

  it "keeps a non-default port in the target" do
    built = Gori::Repeater::FlowRequest.build(flow_detail("https", "api.test", 8443, "GET / HTTP/1.1\r\n\r\n"))
    built.target.should eq("https://api.test:8443")
  end

  it "flags HTTP/2 flows" do
    built = Gori::Repeater::FlowRequest.build(flow_detail("https", "h", 443, "GET / HTTP/1.1\r\n\r\n", http_version: "HTTP/2"))
    built.http2.should be_true
  end

  it "preserves a binary body byte-for-byte (no text round-trip corruption)" do
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\n"
    body = Bytes[0x00, 0x0A, 0xFF, 0x0D] # contains LF/CR bytes a line-splitter would mangle
    built = Gori::Repeater::FlowRequest.build(flow_detail("https", "h", 443, head, request_body: body))
    expected = head.to_slice.to_a + body.to_a
    built.bytes.to_a.should eq(expected)
  end

  it "rewrites the request line but keeps an absolute-form body exact" do
    head = "POST http://h/p HTTP/1.1\r\nHost: h\r\n\r\n"
    body = Bytes[0x0A, 0x41, 0x0A]
    built = Gori::Repeater::FlowRequest.build(flow_detail("http", "h", 80, head, request_body: body))
    String.new(built.bytes).should eq("POST /p HTTP/1.1\r\nHost: h\r\n\r\n\nA\n")
  end

  it "re-syncs Content-Length to the stored body when the capture was truncated" do
    # Head over-promises CL: 9999 but only 3 bytes survived the capture cap — replaying the
    # original CL would hang the origin. build() rewrites CL to the actual length.
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 9999\r\nX-T: 1\r\n\r\n"
    body = Bytes[0x41, 0x42, 0x43] # "ABC"
    built = Gori::Repeater::FlowRequest.build(
      flow_detail("http", "h", 80, head, request_body: body, request_body_truncated: true))
    String.new(built.bytes).should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nX-T: 1\r\n\r\nABC")
  end

  it "leaves Content-Length untouched when the body was NOT truncated" do
    head = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n"
    body = Bytes[0x41, 0x42, 0x43]
    built = Gori::Repeater::FlowRequest.build(flow_detail("http", "h", 80, head, request_body: body))
    String.new(built.bytes).should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nABC")
  end

  it "re-frames a truncated CHUNKED request to Content-Length so it can't hang" do
    # A chunked body cut at the cap (no terminating 0-chunk) would block the origin; replace
    # Transfer-Encoding with a Content-Length over the stored bytes so the request terminates.
    head = "POST /u HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
    body = "5\r\nhello\r\n".to_slice # 10 bytes of wire-form chunk data (cut before the 0-chunk)
    built = Gori::Repeater::FlowRequest.build(
      flow_detail("http", "h", 80, head, request_body: body, request_body_truncated: true))
    String.new(built.bytes).should eq("POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\n5\r\nhello\r\n")
  end

  it "preserves a bare-LF request-line terminator when rewriting (no mixed endings)" do
    head = "GET http://h/p HTTP/1.1\nHost: h\n\n" # LF-only, absolute-form
    built = Gori::Repeater::FlowRequest.build(flow_detail("http", "h", 80, head))
    String.new(built.bytes).should eq("GET /p HTTP/1.1\nHost: h\n\n") # stays LF — no \r introduced
  end

  it "parses targets (the inverse of build_target)" do
    Gori::Repeater::FlowRequest.parse_target("https://h").should eq({"https", "h", 443})
    Gori::Repeater::FlowRequest.parse_target("http://h:8080").should eq({"http", "h", 8080})
    Gori::Repeater::FlowRequest.parse_target("h:9000").should eq({"http", "h", 9000}) # bare → http
    Gori::Repeater::FlowRequest.parse_target("https://h:8443/p").should eq({"https", "h", 8443})
  end

  it "only rewrites a well-formed absolute request line" do
    Gori::Repeater::FlowRequest.rewrite_request_line("GET http://e/a HTTP/1.1").should eq("GET /a HTTP/1.1")
    Gori::Repeater::FlowRequest.rewrite_request_line("GET /a HTTP/1.1").should be_nil # already origin-form
    Gori::Repeater::FlowRequest.rewrite_request_line("garbage").should be_nil
  end
end

describe Gori::CLI::Output do
  it "serialises a probe group to JSON with the documented fields (incl. remediation)" do
    g = Gori::Probe::Group.new("secret_in_url", "infoleak", "api.test", "Secret in URL",
      Gori::Store::Severity::High, 3, ["https://api.test/a", "https://api.test/b"], "token", 7_i64)
    parsed = JSON.parse(Gori::CLI::Output.probe_group_json(g))
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

  it "renders probe text with the severity tag, ×hit_count, and a representative affected URL" do
    g = Gori::Probe::Group.new("missing_csp", "headers", "api.test", "Missing CSP",
      Gori::Store::Severity::Medium, 4,
      ["https://api.test/a", "https://api.test/b", "https://api.test/c"], nil, nil)
    txt = Gori::CLI::Output.probe_group_text(g)
    txt.should contain("[medium]")
    txt.should contain("missing_csp")
    txt.should contain("×4")
    txt.should contain("https://api.test/a")
    txt.should contain("(+2 more)") # 3 affected − 1 shown
  end
end

def notes_spec_entries(texts : Array(String)) : Array(Gori::Notes::NoteEntry)
  texts.map_with_index { |t, i| Gori::Notes::NoteEntry.new((i + 1).to_i64, t) }
end

def notes_spec_doc(cur : Int32, texts : Array(String), next_id : Int64 = 0_i64) : Gori::Notes::Doc
  entries = notes_spec_entries(texts)
  nid = next_id > 0 ? next_id : (entries.size + 1).to_i64
  Gori::Notes::Doc.new(cur, entries, nid)
end

describe Gori::Notes do
  # Doc is a record (struct) → value equality, so whole-Doc comparison avoids
  # unwrapping the nilable parse result (and keeps the spec ameba-clean).
  it "parses a well-formed document set" do
    Gori::Notes.parse(%({"cur":1,"notes":["a","b"]})).should eq(notes_spec_doc(1, ["a", "b"]))
  end

  it "defaults cur to 0 and coerces non-string note entries to empty strings" do
    Gori::Notes.parse(%({"notes":[1,"x",null]})).should eq(notes_spec_doc(0, ["", "x", ""]))
  end

  it "treats an empty notes array as a (non-nil) empty set" do
    Gori::Notes.parse(%({"cur":0,"notes":[]})).should eq(Gori::Notes::Doc.new(0, [] of Gori::Notes::NoteEntry, 1_i64))
  end

  it "exposes size/empty? on a Doc" do
    notes_spec_doc(0, ["a", "b"]).size.should eq(2)
    notes_spec_doc(0, ["a", "b"]).empty?.should be_false
    Gori::Notes::Doc.new(0, [] of Gori::Notes::NoteEntry, 1_i64).empty?.should be_true
  end

  it "returns nil for malformed JSON or a missing notes key (so callers fall back)" do
    Gori::Notes.parse("not json {{{").should be_nil
    Gori::Notes.parse(%({"cur":0})).should be_nil
  end

  it "round-trips through serialize/parse" do
    entries = notes_spec_entries(["alpha", "beta\ngamma", ""])
    raw = Gori::Notes.serialize(2, entries, 4_i64)
    Gori::Notes.parse(raw).should eq(Gori::Notes::Doc.new(2, entries, 4_i64))
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

describe "gori run probe --active" do
  it "includes Category::ACTIVE in PROBE_CATEGORIES" do
    Gori::CLI::Run::PROBE_CATEGORIES.should contain(Gori::Probe::Category::ACTIVE)
  end
end

# The guard behind `unknown subcommand` on the verb-dispatching subcommands. `issues`/`links`
# used to end their `case` with `else <the read command>`, so an unrecognized verb silently
# LISTED and exited 0: `gori run issues remove 1` deleted nothing and reported success. The
# dispatch itself calls `abort`, so the classification is spec'd here and the messages are
# covered by the subcommand help.
module Gori::CLI::Run
  def self.verb_token_for_spec(sub : String?) : Bool
    verb_token?(sub)
  end
end

describe "Gori::CLI::Run.verb_token?" do
  it "is true for a bare word — a verb the case must recognize or reject" do
    Gori::CLI::Run.verb_token_for_spec("remove").should be_true
    Gori::CLI::Run.verb_token_for_spec("delet").should be_true # a typo is still a verb token
    Gori::CLI::Run.verb_token_for_spec("severity:high").should be_true
  end

  it "is false for a flag, which means the default read command" do
    # `gori run issues --project x` and `gori run links --owner note --id 2` still list.
    Gori::CLI::Run.verb_token_for_spec("--project").should be_false
    Gori::CLI::Run.verb_token_for_spec("-h").should be_false
    Gori::CLI::Run.verb_token_for_spec("--format=json").should be_false
  end

  it "is false when there is no first token at all" do
    Gori::CLI::Run.verb_token_for_spec(nil).should be_false
    Gori::CLI::Run.verb_token_for_spec("").should be_false
  end
end

# #410: `gori run fuzz` dropped every errored send from all output formats (the CLI showed only
# matches), so a headless run that 100%-failed looked identical to one that cleanly matched
# nothing. `emit_fuzz_result` now emits an errored row too — proven here via a whitebox wrapper.
module Gori::CLI::Run
  def self.emit_fuzz_result_for_spec(r : Gori::Fuzz::Result, buffer : Array(Gori::Fuzz::Result)) : Bool
    emit_fuzz_result(r, :json, buffer) # :json only buffers, no stdout
  end
end

private def fuzz_result(matched : Bool, error : String?) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(index: 0_i64, payloads: ["p"], position: 0, status: (matched ? 200 : nil),
    length: 0_i64, words: 0, lines: 0, duration_us: 1_i64, error: error, matched: matched,
    incomplete: false, extracted: nil)
end

describe "gori run fuzz — errored result visibility (#410)" do
  it "emits an errored send, not just a matched one" do
    buf = [] of Gori::Fuzz::Result
    # A send failure (scope-blocked / target down): matched? false, error set.
    Gori::CLI::Run.emit_fuzz_result_for_spec(fuzz_result(false, "connect failed"), buf).should be_true
    # A plain non-match with no error is still dropped (unchanged).
    Gori::CLI::Run.emit_fuzz_result_for_spec(fuzz_result(false, nil), buf).should be_false
    # A match is emitted as before.
    Gori::CLI::Run.emit_fuzz_result_for_spec(fuzz_result(true, nil), buf).should be_true
    buf.size.should eq(2) # the errored row + the match; the bare no-match was not buffered
    buf.any? { |r| r.error == "connect failed" }.should be_true
  end
end

# `gori run repeater send`'s session-replay resolution used to live in a private CLI helper
# (`build_repeater_send`). Since #356 the RESOLUTION is `Repeater::Plan.build`, asserted once
# for all three surfaces in spec/repeater/plan_spec.cr — but the row → options MAPPING is
# still CLI glue, and a spec that hand-builds its own `PlanOptions` never executes it. These
# call the real `session_plan_options`, so dropping any field from it fails here.
module Gori::CLI::Run
  def self.session_plan_options_for_spec(rec : Gori::Store::RepeaterRecord, insecure : Bool = false)
    session_plan_options(rec, insecure, nil)
  end
end

# #406: `gori run repeater send/<flow-id>/minimize` ran only the Layer-2 (Sandbox/exclude)
# gate, so a configured project scope was silently inert and there was no --allow-unscoped
# waiver — unlike fuzz/mine/sequence/discover and MCP. `repeater_out_of_scope?` is the Layer-1
# decision `abort_if_out_of_scope!` acts on; a Gate::Configured outbound must refuse an
# out-of-scope origin and a waived one must not.
module Gori::CLI::Run
  def self.repeater_out_of_scope_for_spec(ob : Gori::Outbound, plan : Gori::Repeater::Plan) : Bool
    repeater_out_of_scope?(ob, plan)
  end
end

describe "gori run repeater — Layer-1 scope gate (#406)" do
  it "refuses an out-of-scope origin under a configured scope, and honours --allow-unscoped" do
    path = File.tempname("gori-repscope", ".db")
    store = Gori::Store.open(path)
    begin
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "in.test") # 127.0.0.1 is NOT in scope
      plan = Gori::Repeater::Plan.build(
        Gori::Repeater::PlanOptions.new(["GET /x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice],
          target: "http://127.0.0.1:9/x"), Gori::Outbound.cli(scope, false))
      # Layer 1 (Gate::Configured) refuses it...
      Gori::CLI::Run.repeater_out_of_scope_for_spec(Gori::Outbound.cli(scope, false), plan).should be_true
      # ...and --allow-unscoped (the operator waiver) lets it through.
      Gori::CLI::Run.repeater_out_of_scope_for_spec(Gori::Outbound.cli(scope, true), plan).should be_false
      # An in-scope origin is never refused.
      in_plan = Gori::Repeater::Plan.build(
        Gori::Repeater::PlanOptions.new(["GET /x HTTP/1.1\r\nHost: in.test\r\n\r\n".to_slice],
          target: "http://in.test/x"), Gori::Outbound.cli(scope, false))
      Gori::CLI::Run.repeater_out_of_scope_for_spec(Gori::Outbound.cli(scope, false), in_plan).should be_false
    ensure
      store.close
      File.delete?(path); File.delete?("#{path}-wal"); File.delete?("#{path}-shm")
    end
  end
end

describe "gori run repeater send (session row → PlanOptions mapping)" do
  it "maps the session's target, http2, SNI and auto-CL toggle onto the plan" do
    rec = Gori::Store::RepeaterRecord.new(1_i64, "https://h.test:8443",
      "POST /x HTTP/1.1\r\nHost: api.test\r\nContent-Length: 999\r\n\r\nhello".to_slice,
      true, true, nil, 0, sni: "front.test") # http2=true, auto_content_length=true
    plan = Gori::Repeater::Plan.build(
      Gori::CLI::Run.session_plan_options_for_spec(rec), ungated_outbound)
    String.new(plan.bytes).should eq("POST /x HTTP/1.1\r\nHost: api.test\r\nContent-Length: 5\r\n\r\nhello")
    plan.scheme.should eq("https")
    plan.host.should eq("h.test")
    plan.port.should eq(8443)
    plan.http2?.should be_true
    plan.sni.should eq("front.test")
  end

  # The mapping a `Plan`-only spec cannot catch: if `auto_content_length:` stopped reading the
  # row, `repeater create --no-auto-cl` would have its deliberately-wrong CL overwritten on
  # every replay — the "fix #15" guarantee, silently gone.
  it "carries auto_content_length=OFF from the row, preserving a hand-set Content-Length" do
    rec = Gori::Store::RepeaterRecord.new(1_i64, "https://api.test",
      "POST /x HTTP/1.1\r\nHost: api.test\r\nContent-Length: 999\r\n\r\nhello".to_slice,
      false, false, nil, 0) # http2=false, auto_content_length=false
    plan = Gori::Repeater::Plan.build(
      Gori::CLI::Run.session_plan_options_for_spec(rec), ungated_outbound)
    String.new(plan.bytes).should eq("POST /x HTTP/1.1\r\nHost: api.test\r\nContent-Length: 999\r\n\r\nhello")
    plan.http2?.should be_false
  end

  it "maps -k/--insecure-upstream onto the plan's verify flag" do
    rec = Gori::Store::RepeaterRecord.new(1_i64, "https://api.test",
      "GET / HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice, false, true, nil, 0)
    Gori::CLI::Run.session_plan_options_for_spec(rec, insecure: false).verify?.should be_true
    Gori::CLI::Run.session_plan_options_for_spec(rec, insecure: true).verify?.should be_false
  end
end

# cli_host_overrides is private CLI glue (R2-1 parity for the fuzz/mine/sequence senders);
# reopen the module for a bare-call wrapper (same whitebox trick as the others above).
module Gori::CLI::Run
  def self.cli_host_overrides_for_spec(pn : String?, db : String?, fid : Int64?) : Gori::HostOverrides?
    cli_host_overrides(pn, db, fid)
  end
end

describe "gori run fuzz/mine/sequence — project host overrides (R2-1)" do
  it "loads a project's host overrides when --db/--project/flow-id is in play, nil otherwise" do
    path = File.tempname("gori-cliov", ".db")
    store = Gori::Store.open(path)
    closed = false
    begin
      Gori::HostOverrides.load(store).add("api.invalid", "127.0.0.1")
      store.close; closed = true # Store#close is NOT idempotent (a 2nd @done.receive blocks forever)
      ov = Gori::CLI::Run.cli_host_overrides_for_spec(nil, path, nil)
      ov.should_not be_nil
      ov.not_nil!.connect_ip("api.invalid").should eq("127.0.0.1")
      # --request/stdin with no project in play → nil (global Settings overrides still apply)
      Gori::CLI::Run.cli_host_overrides_for_spec(nil, nil, nil).should be_nil
    ensure
      store.close unless closed
      File.delete?(path); File.delete?("#{path}-wal"); File.delete?("#{path}-shm")
    end
  end
end

# `ws_out_messages` is private CLI glue (mirrors MCP send_websocket's default-messages
# fallback) — reopen the module for a bare-call wrapper.
module Gori::CLI::Run
  def self.ws_out_messages_for_spec(store : Gori::Store, id : Int64, override : Array(String)) : Array(Gori::Repeater::WsEngine::OutMsg)
    ws_out_messages(store, id, override)
  end
end

describe "gori run repeater send (WebSocket)" do
  it "uses --message overrides as text frames when given" do
    with_store do |store|
      msgs = Gori::CLI::Run.ws_out_messages_for_spec(store, 1_i64, ["ping", "pong"])
      msgs.map(&.opcode).should eq([1, 1])
      msgs.map { |m| String.new(m.payload) }.should eq(["ping", "pong"])
    end
  end

  it "falls back to the repeater's stored OUT messages when no override is given" do
    with_store do |store|
      id = store.insert_repeater("ws://x.test", "GET /ws HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.update_repeater_ws_messages(id, ["hello"])
      msgs = Gori::CLI::Run.ws_out_messages_for_spec(store, id, [] of String)
      msgs.size.should eq(1)
      String.new(msgs[0].payload).should eq("hello")
    end
  end
end

# `intercept_bridge_state` / `intercept_live?` are private CLI glue (mirror MCP's
# identically-named helpers in src/gori/mcp/tools/intercept.cr) — reopen the module
# for bare-call wrappers.
module Gori::CLI::Run
  def self.intercept_bridge_state_for_spec(store : Gori::Store) : Hash(String, JSON::Any)?
    intercept_bridge_state(store)
  end

  def self.intercept_live_for_spec(bridge : Hash(String, JSON::Any)) : Bool
    intercept_live?(bridge)
  end
end

describe "gori run intercept (bridge state)" do
  it "returns nil when no bridge has ever been published" do
    with_store do |store|
      Gori::CLI::Run.intercept_bridge_state_for_spec(store).should be_nil
    end
  end

  it "parses a published bridge and reports live for a fresh heartbeat" do
    with_store do |store|
      now = Time.utc.to_unix_ms
      store.set_intercept_bridge(%({"capturing":true,"enabled":true,"direction":"both","filter":"","session_token":"tok","heartbeat_ms":#{now}}))
      bridge = Gori::CLI::Run.intercept_bridge_state_for_spec(store)
      bridge.should_not be_nil
      Gori::CLI::Run.intercept_live_for_spec(bridge.not_nil!).should be_true
    end
  end

  it "treats a stale heartbeat as not live" do
    with_store do |store|
      stale = Time.utc.to_unix_ms - 60_000
      store.set_intercept_bridge(%({"capturing":true,"session_token":"tok","heartbeat_ms":#{stale}}))
      bridge = Gori::CLI::Run.intercept_bridge_state_for_spec(store).not_nil!
      Gori::CLI::Run.intercept_live_for_spec(bridge).should be_false
    end
  end
end
