require "./spec_helper"

# The curl round trip (#1244): `Export::Curl` writes a captured request as a curl command, and
# `Import::Curl` reads a pasted curl command back into a request. The two are one contract seen
# from both ends, so the property is asserted here, across both subsystems: export, import, and
# the SAME BYTES come back.
#
# "The same bytes" for the shape curl itself puts on the wire — `Host:` first, `Content-Length`
# last, identity-framed. That is what every h1 client sends; the heads below deviate from it
# only where the deviation is the point (a mismatched Host, a lowercase method, an empty
# header, a traversal path, a glob, raw obs-text).
#
# Two export defects were found by holding it to this, both measured against curl 8.7.1 on a
# raw listener: a body with no Content-Type came out of the command WITH curl's default one,
# and a `/a/../b` path was collapsed by curl to `/b`. The export now writes
# `-H 'Content-Type:'` and `--path-as-is` for those, which is why they round-trip below.

private TARGET = "https://acme.test"

private def round_trip(wire : String) : Nil
  cmd = Gori::Export::Curl.text(wire, TARGET) || raise "no command for #{wire.inspect}"
  req = Gori::Import::Curl.parse_one(cmd)
  String.new(req.bytes).should eq(wire)
  req.bytes.should eq(wire.to_slice) # byte-exact, not merely equal after a scrub
  req.origin.should eq(TARGET) unless wire.includes?(":8443")
end

describe "curl export → import round trip" do
  it "reproduces a browser GET with cookies" do
    round_trip("GET /a?b=c HTTP/1.1\r\nHost: acme.test\r\nUser-Agent: Mozilla/5.0\r\n" \
               "Accept: */*\r\nCookie: s=1; t=2\r\n\r\n")
  end

  it "reproduces a JSON POST whose body and header carry single quotes" do
    round_trip("POST /api/login HTTP/1.1\r\nHost: acme.test\r\nContent-Type: application/json\r\n" \
               "X-Q: it's\r\nContent-Length: 27\r\n\r\n{\"u\":\"neo\",\"n\":\"it's fine\"}")
  end

  it "reproduces a Host that is not the URL's authority, and an empty header" do
    round_trip("GET /p HTTP/1.1\r\nHost: evil.test\r\nX-Empty:\r\n\r\n")
  end

  it "reproduces a non-default port and a body holding CR/LF bytes" do
    round_trip("PUT /x HTTP/1.1\r\nHost: acme.test:8443\r\nContent-Type: text/plain\r\n" \
               "Content-Length: 5\r\n\r\na\r\nb\n")
  end

  it "reproduces a lowercase method — a method-case bypass probe" do
    round_trip("get /admin HTTP/1.1\r\nHost: acme.test\r\n\r\n")
  end

  it "reproduces a body sent with no Content-Type at all" do
    round_trip("POST /nc HTTP/1.1\r\nHost: acme.test\r\nContent-Length: 3\r\n\r\nabc")
  end

  it "reproduces a traversal path and a glob-shaped query" do
    round_trip("GET /a/../etc/passwd HTTP/1.1\r\nHost: acme.test\r\n\r\n")
    round_trip("GET /q?f=[1-3]&g={a,b} HTTP/1.1\r\nHost: acme.test\r\n\r\n")
  end

  it "reproduces an HTTP/2 capture's head" do
    round_trip("GET /p HTTP/2\r\nHost: acme.test\r\naccept: */*\r\n\r\n")
  end

  it "reproduces a raw obs-text byte in a header value" do
    round_trip("GET /b HTTP/1.1\r\nHost: acme.test\r\nX-Bin: \xff\xfe\r\n\r\n")
  end

  it "reproduces a DELETE with a body and a GET with one" do
    round_trip("DELETE /r/1 HTTP/1.1\r\nHost: acme.test\r\nContent-Type: application/json\r\n" \
               "Content-Length: 2\r\n\r\n{}")
    round_trip("GET /search HTTP/1.1\r\nHost: acme.test\r\nContent-Type: application/json\r\n" \
               "Content-Length: 9\r\n\r\n{\"q\":\"x\"}")
  end
end
