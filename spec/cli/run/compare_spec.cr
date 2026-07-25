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
