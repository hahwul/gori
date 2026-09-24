require "../spec_helper"
require "compress/gzip"

# "Mock this response" (#1237): a captured flow → the draft of a short-circuit rule. The draft
# is a SNAPSHOT the operator edits, so what matters is that it answers what the origin sent —
# decoded into editable text — and that every flow it cannot honestly snapshot is refused
# with the reason, the same way on all three surfaces.

private def seed(store, *, target = "/api/me?x=1", method = "GET", host = "acme.test",
                 status = 200, head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
                 body : Bytes? = %({"isAdmin":false}).to_slice, truncated = false,
                 state = Gori::Store::FlowState::Complete, short_circuited = false) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    short_circuited: short_circuited, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: head.to_slice, body: body,
    body_truncated: truncated, state: state))
  id
end

private def draft(store, id)
  Gori::MockFromFlow.draft(store.get_flow(id).not_nil!)
end

private def gzip(text : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |gz| gz << text }
  io.to_slice
end

describe Gori::MockFromFlow do
  it "drafts a rule that answers this endpoint with the captured response" do
    with_store do |store|
      d = draft(store, seed(store)).as(Gori::MockFromFlow::Draft)
      d.host.should eq("acme.test")
      d.replacement.should eq("HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"isAdmin\":false}")
      Gori::RuleStub.valid?(d.replacement).should be_true
      # Anchored on the request line, up to the query: this endpoint with any query, and not
      # its neighbours.
      re = Regex.new(d.pattern)
      re.matches?("GET /api/me HTTP/1.1\r\n").should be_true
      re.matches?("GET /api/me?y=2 HTTP/1.1\r\n").should be_true
      re.matches?("GET /api/mes HTTP/1.1\r\n").should be_false
      re.matches?("GET /api/me/1 HTTP/1.1\r\n").should be_false
      re.matches?("POST /api/me HTTP/1.1\r\n").should be_false
      re.matches?("GET /x HTTP/1.1\r\nReferer: GET /api/me \r\n").should be_false
    end
  end

  it "decodes a gzip body and a chunked one into editable text, dropping their framing" do
    with_store do |store|
      gz = seed(store, head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 40\r\n\r\n",
        body: gzip(%({"flag":false})))
      d = draft(store, gz).as(Gori::MockFromFlow::Draft)
      d.replacement.should eq("HTTP/1.1 200 OK\n\n{\"flag\":false}")

      chunked = seed(store, head: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Keep: 1\r\n\r\n",
        body: "5\r\nhello\r\n0\r\n\r\n".to_slice)
      draft(store, chunked).as(Gori::MockFromFlow::Draft).replacement.should eq("HTTP/1.1 200 OK\nX-Keep: 1\n\nhello")
    end
  end

  it "reads an h2 capture's head and leaves gori's own markers out" do
    with_store do |store|
      id = seed(store, head: "HTTP/2 200\r\ncontent-type: text/plain\r\nX-Gori-Trailers: grpc-status\r\n\r\n",
        body: "ok".to_slice)
      d = draft(store, id).as(Gori::MockFromFlow::Draft)
      d.replacement.should eq("HTTP/2 200\ncontent-type: text/plain\n\nok")
      Gori::RuleStub.parse_head(d.replacement).not_nil!.status.should eq(200)
    end
  end

  it "takes the path out of an absolute-form target" do
    Gori::MockFromFlow.request_pattern("GET", "http://acme.test/api/me?x=1").should eq("\\AGET /api/me(\\?| )")
    Gori::MockFromFlow.request_pattern("GET", "http://acme.test").should eq("\\AGET /(\\?| )")
  end

  it "refuses a flow it cannot honestly snapshot, and says why" do
    with_store do |store|
      {
        {seed(store, truncated: true), Gori::MockFromFlow::TRUNCATED},
        {seed(store, short_circuited: true), Gori::MockFromFlow::STUBBED},
        {seed(store, state: Gori::Store::FlowState::Aborted, head: "", body: nil), Gori::MockFromFlow::NO_RESPONSE},
        {seed(store, status: 101, head: "HTTP/1.1 101 Switching Protocols\r\n\r\n", body: nil), Gori::MockFromFlow::INTERIM},
        {seed(store, head: "HTTP/1.1 200 OK\r\nContent-Encoding: snappy\r\n\r\n"), Gori::MockFromFlow::UNDECODABLE},
        {seed(store, head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n", body: gzip("x" * 100)[0, 20]), Gori::MockFromFlow::UNDECODABLE},
        {seed(store, body: Bytes[0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00]), Gori::MockFromFlow::BINARY},
        {seed(store, body: ("a" * (Gori::MockFromFlow::MAX_INLINE_BODY + 1)).to_slice), Gori::MockFromFlow::TOO_LARGE},
        {seed(store, head: "HTTP/1.1 200 OK\r\nX-A: 1\r\n  folded\r\n\r\n"), Gori::MockFromFlow::BAD_HEAD},
      }.each do |(id, code)|
        r = draft(store, id)
        r.should be_a(Gori::MockFromFlow::Refusal)
        r.as(Gori::MockFromFlow::Refusal).code.should eq(code)
      end
    end
  end

  it "keeps a head-only response head-only" do
    with_store do |store|
      id = seed(store, status: 204, head: "HTTP/1.1 204 No Content\r\nX-A: 1\r\n\r\n", body: nil)
      draft(store, id).as(Gori::MockFromFlow::Draft).replacement.should eq("HTTP/1.1 204 No Content\nX-A: 1")
    end
  end
end
