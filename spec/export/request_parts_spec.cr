require "../spec_helper"

# `Gori::Export::RequestParts.sendable` — the headers and body the Python/fetch/Go/httpie/CSRF
# serializers hand their HTTP library. Only a final `chunked` coding is the library's to re-add.

private def sendable(wire : String) : Gori::Export::RequestParts::Sendable
  Gori::Export::RequestParts.sendable(Gori::Export::RequestParts.from_wire(wire, "http://h").not_nil!)
end

private def te_of(s : Gori::Export::RequestParts::Sendable) : Array(String)
  s.headers.select { |(n, _)| n.downcase == "transfer-encoding" }.map(&.[1])
end

describe Gori::Export::RequestParts do
  # `Curl.unchunk`'s nil ("nothing peeled") was read as "chunked was the only coding", so a
  # smuggling probe's `xchunked` vanished from every generated client while curl kept it.
  it "keeps a Transfer-Encoding whose final coding is not chunked, as captured" do
    {"xchunked", "gzip", "identity", "chunked, x"}.each do |te|
      s = sendable("POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: #{te}\r\n\r\nabc")
      te_of(s).should eq([te])
      s.body.should eq("abc")
    end
  end

  it "peels a final chunked coding off the body and the header" do
    s = sendable("POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip, chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
    te_of(s).should eq(["gzip"])
    s.body.should eq("abc")
    te_of(sendable("POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")).should be_empty
  end

  # Declared chunked over bytes that are not chunk-framed: the bytes ride as captured, and the
  # `chunked` token still drops because the library frames them itself.
  it "drops the chunked token over a body that is not chunk-framed" do
    s = sendable("POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\nhello")
    te_of(s).should be_empty
    s.body.should eq("hello")
  end
end
