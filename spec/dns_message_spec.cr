require "./spec_helper"

# `example.com.` as a question name sits at offset 12, so `c00c` points back at it.
private DNS_QUESTION = "076578616d706c6503636f6d00" + "0001" + "0001"

private DNS_QUERY = ("1234" + "0100" + "0001" + "0000" + "0000" + "0000" + DNS_QUESTION).hexbytes

# qr+rd+ra, one question, three answers (CNAME, A, HTTPS), one additional (OPT).
private DNS_RESPONSE = (
  "1234" + "8180" + "0001" + "0003" + "0000" + "0001" + DNS_QUESTION +
  "c00c" + "0005" + "0001" + "0000012c" + "0006" + "03777777c00c" +
  "c00c" + "0001" + "0001" + "0000003c" + "0004" + "5db8d822" +
  "c00c" + "0041" + "0001" + "0000003c" + "0013" + "0001" + "00" +
  "0001" + "0006" + "026833026832" + "0003" + "0002" + "01bb" +
  "00" + "0029" + "04d0" + "00000000" + "0000"
).hexbytes

private def dns(data : Bytes) : JSON::Any
  r = Gori::DnsMessage.render(data)
  r.complete.should be_true
  JSON.parse(r.json)
end

describe Gori::DnsMessage do
  it "renders a query" do
    doc = dns(DNS_QUERY)
    doc["id"].should eq(0x1234)
    doc["kind"].should eq("query")
    doc["flags"].should eq(["rd"])
    doc["question"].should eq([{"name" => "example.com.", "type" => "A", "class" => "IN"}])
    doc["answer"].as_a.should be_empty
  end

  it "renders a response, following compression pointers" do
    doc = dns(DNS_RESPONSE)
    doc["kind"].should eq("response")
    doc["rcode"].should eq("NOERROR")
    doc["flags"].should eq(["rd", "ra"])
    cname, a, https = doc["answer"].as_a
    cname["name"].should eq("example.com.")
    cname["ttl"].should eq(300)
    cname["data"].should eq("www.example.com.")
    a["data"].should eq("93.184.216.34")
    https["type"].should eq("HTTPS")
    https["data"].should eq({"priority" => 1, "target" => ".", "alpn" => ["h3", "h2"], "port" => 443})
    doc["additional"].should eq([{"name" => ".", "type" => "OPT", "udp_size" => 1232, "extended_rcode" => 0,
                                  "version" => 0, "do" => false, "data" => {"$bin" => ""}}])
  end

  it "renders AAAA, TXT and a type it has no reader for" do
    body = ("0000" + "8000" + "0000" + "0003" + "0000" + "0000" +
            "00" + "001c" + "0001" + "00000000" + "0010" + "20010db8000000000000000000000001" +
            "00" + "0010" + "0001" + "00000000" + "0005" + "026869" + "0141" +
            "00" + "0063" + "0003" + "00000000" + "0002" + "beef").hexbytes
    aaaa, txt, other = dns(body)["answer"].as_a
    aaaa["data"].should eq("2001:db8::1")
    txt["data"].should eq(["hi", "A"])
    other["type"].should eq("TYPE99")
    other["class"].should eq("CLASS3")
    other["data"].should eq({"$bin" => "vu8="}) # base64, as the other readers spell `$bin`
  end

  it "keeps what a record carries that it cannot read as its type" do
    # An OPT whose TTL holds extended RCODE 1 (BADVERS) and the DO bit, an empty CNAME (an
    # RFC 2136 UPDATE deletes with these), and an HTTPS ipv4hint that is not whole addresses.
    body = ("0000" + "8000" + "0000" + "0002" + "0000" + "0001" +
            "00" + "0005" + "00ff" + "00000000" + "0000" +
            "00" + "0041" + "0001" + "00000000" + "000a" + "0001" + "00" + "0004" + "0003" + "0a0000" +
            "00" + "0029" + "04d0" + "01008000" + "0000").hexbytes
    doc = dns(body)
    cname, https = doc["answer"].as_a
    cname["data"].should eq({"$bin" => ""})
    https["data"]["ipv4hint"].should eq({"$bin" => "CgAA"})
    opt = doc["additional"][0]
    opt["extended_rcode"].should eq(1)
    opt["do"].as_bool.should be_true
  end

  it "escapes a dot or a non-ASCII octet inside a label" do
    body = ("0000" + "0000" + "0001" + "0000" + "0000" + "0000" + "03612eff00" + "0001" + "0001").hexbytes
    dns(body)["question"][0]["name"].should eq("a\\046\\255.")
  end

  it "refuses a body that is not one whole message" do
    loop_name = ("0000" + "0000" + "0001" + "0000" + "0000" + "0000" + "c00c" + "0001" + "0001").hexbytes
    # A CNAME whose RDATA goes on for 8 bytes after the name: nothing may hide behind it.
    hidden = ("0000" + "8000" + "0001" + "0001" + "0000" + "0000" + DNS_QUESTION +
              "c00c" + "0005" + "0001" + "00000000" + "000a" + "c00c" + "deadbeefcafebabe").hexbytes
    # One 255-octet name and thousands of two-byte pointers to it: megabytes once expanded.
    long_name = "0161" * 127 + "00"
    expanding = ("0000" + "0000" + "2a00" + "0000" + "0000" + "0000" +
                 long_name + "0001" + "0001" + ("c00c" + "0001" + "0001") * (0x2a00 - 1)).hexbytes
    cases = {
      "pointer loop"  => loop_name,
      "hidden rdata"  => hidden,
      "name bomb"     => expanding,
      "trailing byte" => DNS_QUERY + Bytes[0],
      "JSON"          => %({"Status":0,"Answer":[]}).to_slice,
      "oversize"      => Bytes.new(Gori::DnsMessage::MAX_SIZE + 1),
    }
    (0...DNS_RESPONSE.size).each { |n| cases["prefix #{n}"] = DNS_RESPONSE[0, n] }
    cases.each do |label, data|
      r = Gori::DnsMessage.render(data)
      {label, r.complete, r.decoded}.should eq({label, false, false})
      JSON.parse(r.json) # a refusal is still a document
    end
  end

  it "is dispatched by content type alone" do
    format, r = Gori::BinaryDocument.render(DNS_RESPONSE, "application/dns-message").not_nil!
    format.should eq("dns")
    r.complete.should be_true
    Gori::BinaryDocument.render(DNS_RESPONSE, "application/octet-stream").should be_nil
    Gori::BinaryDocument.render(%({"Status":0}).to_slice, "application/dns-message").should be_nil
    Gori::MediaType.dns_message?("application/dns-json").should be_false
    head = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n\r\n".to_slice
    Gori::Pretty.format(head, DNS_RESPONSE).not_nil!.note.should eq("decoded: dns")
  end
end
