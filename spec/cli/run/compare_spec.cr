require "../../spec_helper"

# `gori run compare` — the two flows' lines are built the same way the TUI Comparer does
# it: REQUEST byte-faithful (no decoding — you are diffing what went on the wire) and
# RESPONSE decoded (gzip/chunked), because a diff of two compressed blobs says nothing.

private def flow_detail(request_head : String, request_body : Bytes? = nil,
                        response_head : String? = nil, response_body : Bytes? = nil)
  row = Gori::Store::FlowRow.new(
    id: 7_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "a.test", port: 443,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", request_head.to_slice, request_body,
    response_head.try(&.to_slice), response_body)
end

# `compare_lines` / `emit_compare_result` are private CLI glue (compare_lines mirrors the
# TUI Comparer's lines_for) — reopen the module for bare-call wrappers.
module Gori::CLI::Run
  def self.compare_lines_for_spec(d : Gori::Store::FlowDetail, pane : Symbol) : Array(String)
    compare_lines(d, pane)
  end
end

describe "gori run compare" do
  it "builds request lines byte-faithful (no decoding) and response lines decoded" do
    d = flow_detail("GET / HTTP/1.1\r\nHost: a.test\r\n\r\n",
      response_head: "HTTP/1.1 200 OK\r\n\r\n", response_body: "hello".to_slice)
    req_lines = Gori::CLI::Run.compare_lines_for_spec(d, :request)
    req_lines.first.should eq("GET / HTTP/1.1")
    resp_lines = Gori::CLI::Run.compare_lines_for_spec(d, :response)
    resp_lines.should contain("hello")
  end

  it "leaves a chunked request body FRAMED — the request side never decodes" do
    # Diffing two smuggling probes is the point of comparing requests: the chunk sizes and
    # the framing ARE the payload. Decoding here would erase exactly what is being compared.
    head = "POST /u HTTP/1.1\r\nHost: a.test\r\nTransfer-Encoding: chunked\r\n\r\n"
    body = "5\r\nhello\r\n0\r\n\r\n".to_slice
    lines = Gori::CLI::Run.compare_lines_for_spec(flow_detail(head, request_body: body), :request)
    lines.should contain("5") # the chunk-size line survives verbatim
    lines.should contain("hello")
    lines.should contain("0")
  end

  it "dechunks the RESPONSE body, so the diff is over content and not framing" do
    d = flow_detail("GET / HTTP/1.1\r\n\r\n",
      response_head: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      response_body: "5\r\nhello\r\n0\r\n\r\n".to_slice)
    lines = Gori::CLI::Run.compare_lines_for_spec(d, :response)
    lines.should contain("hello")
    lines.should_not contain("5") # the chunk header is framing, decoded away
  end

  it "handles a flow with no response at all (a pending or errored capture)" do
    # `compare <a> <b>` does not require either flow to have completed; a nil response
    # pane must yield no lines rather than raising.
    lines = Gori::CLI::Run.compare_lines_for_spec(flow_detail("GET / HTTP/1.1\r\n\r\n"), :response)
    lines.should be_empty
  end

  it "counts changed lines through the shared differ" do
    a = ["GET /a HTTP/1.1", "Host: x"]
    b = ["GET /b HTTP/1.1", "Host: x"]
    diff = Gori::Repeater::Diff.lines(a, b)
    Gori::Repeater::Diff.change_count(diff).should be > 0
    Gori::Repeater::Diff.change_count(Gori::Repeater::Diff.lines(a, a)).should eq(0)
  end
end

# `--context` (CLI), `context` (MCP) and `f` (the Comparer tab) are ONE rule, so the fold
# lives with the differ and every surface asks it the same question.
describe Gori::Repeater::Diff do
  private_lines = ->(mid : String) { (1..40).map { |i| i == 20 ? mid : "l#{i}" } }

  it "keeps `context` lines around each change and collapses the rest into counted markers" do
    diff = Gori::Repeater::Diff.lines(private_lines.call("BEFORE"), private_lines.call("AFTER"))
    folded = Gori::Repeater::Diff.fold(diff, 3)
    kept = folded.compact_map(&.line).map(&.text)
    kept.should contain("BEFORE")
    kept.should contain("AFTER")
    kept.should contain("l17") # 3 lines of context before the change
    kept.should_not contain("l16")
    kept.should contain("l23") # …and 3 after
    kept.should_not contain("l24")
    # Nothing is lost: every collapsed line is accounted for by a marker's count.
    hidden = folded.select { |f| f.line.nil? }.sum(&.hidden)
    (kept.size + hidden).should eq(diff.size)
  end

  it "leaves a one-line run alone — the marker replacing it is a row too" do
    # `x` `SAME` `y` on one side vs `X` `SAME` `Y`: the single unchanged line between two
    # changes must survive rather than becoming "1 unchanged line".
    diff = Gori::Repeater::Diff.lines(%w(a SAME b), %w(A SAME B))
    Gori::Repeater::Diff.fold(diff, 0).any? { |f| f.line.try(&.text) == "SAME" }.should be_true
  end

  it "collapses an identical pair to one marker and nothing else" do
    diff = Gori::Repeater::Diff.lines((1..20).map(&.to_s), (1..20).map(&.to_s))
    folded = Gori::Repeater::Diff.fold(diff, 3)
    folded.size.should eq(1)
    folded[0].line.should be_nil
    folded[0].hidden.should eq(20)
  end
end

describe Gori::Repeater::ExchangeMeta do
  it "states the pair's status flip, size and timing shift" do
    a = Gori::Repeater::ExchangeMeta.new(403, "403", 1234_i64, 31_000_i64)
    b = Gori::Repeater::ExchangeMeta.new(200, "200", 1250_i64, 402_000_i64)
    a.line.should eq("403 · 1.2 KB · 31 ms")
    d = Gori::Repeater::ExchangeMeta.delta(a, b).not_nil!
    d.should contain("status 403 → 200")
    d.should contain("size +16 B")
    d.should contain("time +371 ms")
  end

  # An unmeasured field is DROPPED, never zeroed: "0 B" would be a claim about the origin
  # that nothing observed, and an agent reading the JSON would have no way to tell.
  it "drops the fields a source cannot name instead of printing zeros" do
    m = Gori::Repeater::ExchangeMeta.of(nil, nil, nil, nil)
    m.line.should eq("—")
    m.size.should be_nil
    Gori::Repeater::ExchangeMeta.delta(m, m).should be_nil
  end

  it "labels an errored flow ERR rather than printing its status 0" do
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "a.test", port: 443,
      target: "/", status: 0, size: 0_i64, state: Gori::Store::FlowState::Error)
    m = Gori::Repeater::ExchangeMeta.of(row)
    m.status_text.should eq("ERR")
    m.errored?.should be_true
  end

  # #1162: a diff cut at MAX_LINES with no change in the compared part printed a bare
  # "no differences", over lines it never looked at.
  it "never gives a bare 'no differences' over a truncated comparison" do
    Gori::CLI::Run.compare_verdict(0, false).should eq("no differences")
    Gori::CLI::Run.compare_verdict(0, true).should_not eq("no differences")
    Gori::CLI::Run.compare_verdict(0, true).should contain("unknown")
    Gori::CLI::Run.compare_verdict(2, true).should eq("2 lines changed")
  end

  it "reports two same-size binary response bodies as changed" do
    a = flow_detail("GET / HTTP/1.1\r\n\r\n", response_head: "HTTP/1.1 200 OK\r\n\r\n",
      response_body: "\0ROLE=user\0\1\2".to_slice)
    b = flow_detail("GET / HTTP/1.1\r\n\r\n", response_head: "HTTP/1.1 200 OK\r\n\r\n",
      response_body: "\0ROLE=admn\0\1\2".to_slice)
    diff = Gori::Repeater::Diff.lines(Gori::CLI::Run.compare_lines_for_spec(a, :response),
      Gori::CLI::Run.compare_lines_for_spec(b, :response))
    Gori::Repeater::Diff.change_count(diff).should be > 0
  end
end
