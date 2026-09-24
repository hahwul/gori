require "../spec_helper"

# Every expected head below was measured: the same flags run through curl 8.7.1 against a raw
# listener, with curl's own `User-Agent: curl/…` and `Accept: */*` taken out — those describe
# the client that ran the command, not the request it describes (see `Import::Curl`).

private def one(text : String) : Gori::Import::Curl::Request
  Gori::Import::Curl.parse_one(text, boundary: "BOUND")
end

private def wire(text : String) : String
  one(text).text
end

describe Gori::Import::Curl do
  describe "headers" do
    it "keeps each -H line as typed, in argv order, with Host synthesized first" do
      wire(%q(curl 'http://h:8080/a' -H 'X-B: 2' -H 'X-A:  two  spaces ')).should eq(
        "GET /a HTTP/1.1\r\nHost: h:8080\r\nX-B: 2\r\nX-A:  two  spaces \r\n\r\n")
    end

    it "puts a -H Host in the operator's slot and synthesizes none" do
      wire(%q(curl http://h/p -H 'A: 1' -H 'Host: evil' -H 'B: 2')).should eq(
        "GET /p HTTP/1.1\r\nA: 1\r\nHost: evil\r\nB: 2\r\n\r\n")
    end

    it "reads -H 'N:' as curl's \"do not send N\" and -H 'N;' as N sent empty" do
      wire(%q(curl http://h/a -H 'X-Empty;' -H 'X-Rm: ' -H 'Host:')).should eq(
        "GET /a HTTP/1.1\r\nX-Empty:\r\n\r\n")
    end

    it "drops a -H word with neither a colon nor a trailing ;, as curl does, and says so" do
      req = one(%q(curl http://h/p -H 'NoColon'))
      req.text.should eq("GET /p HTTP/1.1\r\nHost: h\r\n\r\n")
      req.notes.join.should contain("NoColon")
    end

    it "sends a CR/LF inside a -H value as written — curl does, and it is the operator's payload" do
      wire(%q(curl http://h/p -H $'X: a\r\nY: b')).should eq(
        "GET /p HTTP/1.1\r\nHost: h\r\nX: a\r\nY: b\r\n\r\n")
    end

    it "maps -b (a cookie — never a body) -u -A -e --compressed -r --oauth2-bearer, in flag order" do
      wire(%q(curl http://h/a -b 'k=v' -u u:p -A ua -e 'ref;auto' --compressed -r 0-9 -b 'z=1')).should eq(
        "GET /a HTTP/1.1\r\nHost: h\r\nCookie: k=v;z=1\r\nAuthorization: Basic dTpw\r\n" \
        "User-Agent: ua\r\nReferer: ref\r\nAccept-Encoding: deflate, gzip\r\nRange: bytes=0-9\r\n\r\n")
      wire(%q(curl http://h/a --oauth2-bearer tok)).should eq(
        "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer tok\r\n\r\n")
    end

    it "lets a -H override the header a flag implies" do
      wire(%q(curl http://h/p -u u:p -H 'Authorization: Bearer t' -A x -H 'User-Agent: y')).should eq(
        "GET /p HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer t\r\nUser-Agent: y\r\n\r\n")
    end

    it "treats -b without = as a cookie-jar file, not a cookie" do
      req = one(%q(curl http://h/p -b cookies.txt))
      req.text.should_not contain("Cookie")
      req.notes.join.should contain("cookie-jar")
    end

    it "turns URL userinfo into Basic auth, and lets -u win over it" do
      wire(%q(curl 'http://u:p@h/x')).should eq("GET /x HTTP/1.1\r\nHost: h\r\nAuthorization: Basic dTpw\r\n\r\n")
      wire(%q(curl 'http://u:p@h/x' -u a:b)).should contain("Basic YTpi")
    end

    it "encodes a password-less -u with an empty password, and says curl would prompt" do
      req = one(%q(curl http://h/ -u admin))
      req.text.should contain("Authorization: Basic YWRtaW46\r\n")
      req.notes.join.should contain("prompt")
    end
  end

  describe "bodies" do
    it "joins -d parts with &, defaults to POST, and adds curl's Content-Type after Content-Length" do
      wire(%q(curl http://h/a -d 'a=1' -d 'b=2' -H 'Z: z')).should eq(
        "POST /a HTTP/1.1\r\nHost: h\r\nZ: z\r\nContent-Length: 7\r\n" \
        "Content-Type: application/x-www-form-urlencoded\r\n\r\na=1&b=2")
    end

    it "keeps a stated Content-Type where the operator put it and adds none" do
      wire(%q(curl http://h/p -d x -H 'Content-Type: text/plain' -H 'A: 1')).should eq(
        "POST /p HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nA: 1\r\nContent-Length: 1\r\n\r\nx")
    end

    it "honours -H 'Content-Type:' — the body goes out with no Content-Type at all" do
      wire(%q(curl http://h/a -d 'a=1' -H 'Content-Type:')).should eq(
        "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\na=1")
    end

    it "sends an empty -d as a framed empty POST" do
      wire(%q(curl http://h/p -d '')).should eq(
        "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n")
    end

    it "keeps a stated Content-Length verbatim beside a longer body — the desync the operator typed" do
      wire(%q(curl http://h/p -H 'Content-Length: 1' -d abc)).should eq(
        "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nabc")
    end

    it "keeps the -X method verbatim, case and all" do
      wire(%q(curl -X post http://h/p -d x)).should start_with("post /p HTTP/1.1\r\n")
      wire(%q(curl -XPUT http://h/p)).should start_with("PUT /p HTTP/1.1\r\n")
    end

    it "takes --data-raw's @ literally and refuses -d/--data-binary @file" do
      wire(%q(curl http://h/p --data-raw @lit)).should end_with("\r\n\r\n@lit")
      expect_raises(Gori::Error, /local file/) { one(%q(curl http://h/p -d @body.json)) }
      expect_raises(Gori::Error, /local file/) { one(%q(curl http://h/p --data-binary @x)) }
    end

    it "encodes --data-urlencode's shapes the way curl does" do
      wire(%q(curl http://h/p --data-urlencode 'k=é~-._*!' --data-urlencode '=y z' --data-urlencode 'raw')).should end_with(
        "\r\n\r\nk=%C3%A9~-._%2A%21&y+z&raw")
      expect_raises(Gori::Error, /local file/) { one(%q(curl http://h/p --data-urlencode name@f.txt)) }
    end

    it "moves the data into the query with -G, as a GET" do
      wire(%q(curl http://h/a -G -d 'q=1' --data-urlencode 'x=a b&c' --data-urlencode '=y z')).should eq(
        "GET /a?q=1&x=a+b%26c&y+z HTTP/1.1\r\nHost: h\r\n\r\n")
    end

    it "joins --json parts with nothing and adds its two headers" do
      wire(%q(curl http://h/p --json '{"a":1}' --json '{"b":2}')).should eq(
        "POST /p HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nAccept: application/json\r\n" \
        "Content-Length: 14\r\n\r\n{\"a\":1}{\"b\":2}")
    end

    it "builds a -F multipart body in curl's shape" do
      req = one(%q(curl http://h/p -F 'n=v' -F 'm="q;uo\"te";type=t/t;filename=f.txt'))
      body = "--BOUND\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\nv\r\n" \
             "--BOUND\r\nContent-Disposition: form-data; name=\"m\"; filename=\"f.txt\"\r\nContent-Type: t/t\r\n\r\nq;uo\"te\r\n" \
             "--BOUND--\r\n"
      req.text.should eq("POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: #{body.bytesize}\r\n" \
                         "Content-Type: multipart/form-data; boundary=BOUND\r\n\r\n#{body}")
    end

    it "drops an unquoted -F value's text after ; as curl does, and names it" do
      req = one(%q(curl http://h/p -F 'n=a;b'))
      req.text.should contain("name=\"n\"\r\n\r\na\r\n")
      req.notes.join.should contain(";b")
    end

    it "refuses a -F file reference and -d mixed with -F" do
      expect_raises(Gori::Error, /local file/) { one(%q(curl http://h/p -F f=@a.png)) }
      expect_raises(Gori::Error, /local file/) { one(%q(curl http://h/p -F 'f=<a.txt')) }
      expect_raises(Gori::Error, /-d and -F/) { one(%q(curl http://h/p -d a -F b=c)) }
    end

    it "gives a boundary to a stated multipart Content-Type that lacks one" do
      wire(%q(curl http://h/p -H 'Content-Type: multipart/form-data' -F n=v)).should contain(
        "Content-Type: multipart/form-data; boundary=BOUND\r\n")
    end
  end

  describe "the URL and the request line" do
    it "defaults a scheme-less URL to http:// inside a curl command, as curl does" do
      req = one(%q(curl h.test:8080/p))
      req.origin.should eq("http://h.test:8080")
      req.target.should eq("/p")
    end

    it "drops the fragment and keeps the path as written, dot segments included" do
      req = one(%q(curl 'http://h/a/../etc/passwd?x=1#frag'))
      req.target.should eq("/a/../etc/passwd?x=1")
      req.notes.join.should contain("--path-as-is")
      one(%q(curl 'http://h/a/../b' --path-as-is)).notes.join.should_not contain("path-as-is")
    end

    it "keeps an IPv6 literal bracketed on the wire and bare in the host" do
      req = one(%q(curl 'http://[::1]:9/x'))
      req.host.should eq("::1")
      req.text.should contain("Host: [::1]:9\r\n")
      req.origin.should eq("http://[::1]:9")
    end

    it "refuses what curl refuses in a URL, and points at --request-target" do
      expect_raises(Gori::Error, /request-target/) { one(%q(curl 'http://h/a b')) }
      expect_raises(Gori::Error, /unsupported scheme/) { one(%q(curl ftp://h/f)) }
      expect_raises(Gori::Error, /port/) { one(%q(curl http://h:99999/)) }
    end

    it "sends --request-target verbatim" do
      wire(%q(curl http://h/p -X OPTIONS --request-target '*')).should start_with("OPTIONS * HTTP/1.1\r\n")
    end

    it "maps -I to HEAD and the version flags to the request line" do
      wire(%q(curl -I http://h/p)).should start_with("HEAD /p HTTP/1.1\r\n")
      wire(%q(curl -0 http://h/p)).should start_with("GET /p HTTP/1.0\r\n")
      req = one(%q(curl --http2 https://h/p))
      req.text.should start_with("GET /p HTTP/2\r\n")
      req.http2?.should be_true
      one(%q(curl --http3 https://h/p)).notes.join.should contain("HTTP/3")
    end
  end

  describe "options curl uses to RUN, not to describe the request" do
    it "ignores transport flags, names each, and does not mistake their value for the URL" do
      req = one(%q(curl -sSLk --max-time 5 -x http://proxy:8080 --resolve h:443:1.2.3.4 https://h/p -o out.html))
      req.url.should eq("https://h/p")
      notes = req.notes.join("\n")
      notes.should contain("-s, -S, -L, -k, --max-time, -x, --resolve, -o")
      notes.should contain("redirects are not followed")
    end

    it "names an unknown option instead of failing" do
      one(%q(curl --frobnicate http://h/p)).notes.join.should contain("--frobnicate")
    end

    it "refuses the options that read a local file" do
      expect_raises(Gori::Error, /local file/) { one(%q(curl -T up.bin http://h/p)) }
      expect_raises(Gori::Error, /local file/) { one(%q(curl -K cfg http://h/p)) }
      expect_raises(Gori::Error, /local file/) { one(%q(curl -H @headers.txt http://h/p)) }
    end
  end

  describe ".parse" do
    it "returns one request per URL, per --next group and per command" do
      parsed = Gori::Import::Curl.parse("curl http://h/1 http://h/2 --next -d x http://h/3 ;\ncurl http://h/4 | jq .")
      parsed.requests.map(&.target).should eq(%w[/1 /2 /3 /4])
      parsed.requests[2].method.should eq("POST")
      parsed.requests[0].method.should eq("GET")
      parsed.notes.join.should contain("jq")
    end

    it "skips a refused command and keeps the rest" do
      parsed = Gori::Import::Curl.parse("curl http://h/ok\ncurl -d @f http://h/bad")
      parsed.requests.size.should eq(1)
      parsed.skipped.first.should contain("local file")
    end

    it "reads a lone URL or bare host as a GET, https:// by default" do
      Gori::Import::Curl.parse("https://acme.test/p?q=1").requests.first.url.should eq("https://acme.test/p?q=1")
      Gori::Import::Curl.parse("acme.test").requests.first.url.should eq("https://acme.test/")
    end

    it "strips a pasted shell prompt" do
      Gori::Import::Curl.parse("$ curl http://h/p").requests.first.url.should eq("http://h/p")
    end

    it "refuses text that is not a curl command, and Windows cmd syntax by name" do
      expect_raises(Gori::Error, /not a curl command/) { Gori::Import::Curl.parse("wget http://h/ -O x") }
      expect_raises(Gori::Error, /cmd syntax/) { Gori::Import::Curl.parse("curl ^\"http://h/^\" ^\n  -H ^\"A: 1^\"") }
    end
  end

  describe ".parse_one" do
    it "refuses a paste holding more than one request" do
      expect_raises(Gori::Error, /2 requests/) { Gori::Import::Curl.parse_one("curl http://h/1 http://h/2") }
    end

    it "refuses when any command was refused, with that reason" do
      expect_raises(Gori::Error, /local file/) { Gori::Import::Curl.parse_one("curl http://h/1; curl -T f http://h/2") }
    end
  end

  describe ".command?" do
    it "recognizes curl, a path to it, curl.exe and a prompt" do
      Gori::Import::Curl.command?("curl http://h").should be_true
      Gori::Import::Curl.command?("  /usr/bin/curl -s x").should be_true
      Gori::Import::Curl.command?("curl.exe x").should be_true
      Gori::Import::Curl.command?("$ curl x").should be_true
      Gori::Import::Curl.command?("GET / HTTP/1.1").should be_false
    end
  end
end
