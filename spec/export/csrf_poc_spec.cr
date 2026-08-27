require "../spec_helper"

# `Gori::Export::CsrfPoc` — the request→self-submitting-HTML CSRF PoC behind the TUI's
# "Copy as → CSRF PoC" row and `gori run show <id> --format csrf`. The honesty invariant is the
# point: a header a cross-site page cannot forge must be DROPPED and NAMED, never silently
# replayed to make a false demo.

private def poc(wire : String, target : String) : String
  Gori::Export::CsrfPoc.text(wire, target).not_nil!
end

describe Gori::Export::CsrfPoc do
  it "emits a self-submitting form for a urlencoded POST, dropping Cookie/Origin with a note" do
    html = poc("POST /transfer HTTP/1.1\r\nHost: bank.test\r\n" \
               "Content-Type: application/x-www-form-urlencoded\r\nCookie: sid=abc\r\n" \
               "Origin: https://bank.test\r\nContent-Length: 19\r\n\r\namount=100&to=mallory", "https://bank.test")
    html.should contain(%(<form action="https://bank.test/transfer" method="POST">))
    html.should contain(%(<input type="hidden" name="amount" value="100">))
    html.should contain(%(<input type="hidden" name="to" value="mallory">))
    html.should contain(%(onload="document.forms[0].submit()"))
    # The forgeable-header note names Cookie and Origin, and does NOT list Content-Type (the
    # form's enctype reproduces it).
    html.should contain("CANNOT forge")
    html.should contain("Cookie")
    html.should contain("Origin")
    html.should_not contain(%(name="sid")) # the cookie is never smuggled in as an input
  end

  it "emits a GET form whose action drops the query (inputs carry it)" do
    html = poc("GET /search?q=a%20b&page=2 HTTP/1.1\r\nHost: h.test\r\n\r\n", "https://h.test")
    html.should contain(%(<form action="https://h.test/search" method="GET">))
    html.should contain(%(<input type="hidden" name="q" value="a b">)) # %20 decoded → browser re-encodes
    html.should contain(%(<input type="hidden" name="page" value="2">))
  end

  it "emits a fetch() PoC for a JSON POST with credentials include and a preflight note" do
    html = poc("POST /api HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n" \
               "Cookie: sid=abc\r\nX-CSRF: t\r\n\r\n{\"a\":1}", "https://h.test")
    html.should contain("fetch(")
    html.should contain(%(credentials: "include",))
    html.should contain(%(headers: { "Content-Type": "application/json" }))
    html.should contain(%(body: "{\\"a\\":1}",))
    html.should contain("CORS preflight")
    # Cookie and the custom header are dropped and named; neither reaches the fetch.
    html.should contain("Cookie")
    html.should contain("X-CSRF")
    html.should_not contain(%("X-CSRF":))
    html.should_not contain(%("Cookie":))
    # `mode: "no-cors"` would strip the JSON Content-Type — a false demo — so it is absent.
    html.should_not contain("no-cors")
  end

  it "builds a multipart form, carrying a text part and noting a file part it cannot pre-fill" do
    b = "----X"
    body = "--#{b}\r\nContent-Disposition: form-data; name=\"amount\"\r\n\r\n100\r\n" \
           "--#{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n\r\nhello\r\n--#{b}--\r\n"
    html = poc("POST /u HTTP/1.1\r\nHost: h.test\r\nContent-Type: multipart/form-data; boundary=#{b}\r\n\r\n#{body}", "https://h.test")
    html.should contain(%(enctype="multipart/form-data"))
    html.should contain(%(<input type="hidden" name="amount" value="100">))
    html.should contain("file part 'a.txt' (5 bytes)")
    html.should contain(%(<input type="hidden" name="file" value="">))
  end

  it "reads the multipart part name at a param boundary (not the 'name=' inside 'filename=')" do
    b = "X"
    body = "--#{b}\r\nContent-Disposition: form-data; filename=\"a.txt\"; name=\"field\"\r\n\r\nVAL\r\n--#{b}--\r\n"
    html = poc("POST /u HTTP/1.1\r\nHost: h.test\r\nContent-Type: multipart/form-data; boundary=#{b}\r\n\r\n#{body}", "https://h.test")
    # The field name is "field", not "a.txt" (which a naive index(\"name=\") inside filename= gives).
    html.should contain(%(name="field"))
    html.should contain("file part 'a.txt'")
    html.should_not contain(%(name="a.txt"))
  end

  it "keeps a multipart value's own trailing newline, stripping only the one framing newline" do
    b = "X"
    body = "--#{b}\r\nContent-Disposition: form-data; name=\"c\"\r\n\r\nline1\nline2\n\r\n--#{b}--\r\n"
    html = poc("POST /u HTTP/1.1\r\nHost: h.test\r\nContent-Type: multipart/form-data; boundary=#{b}\r\n\r\n#{body}", "https://h.test")
    # value carries its own internal + trailing \n (`line1\nline2\n`); only the framing \r\n went.
    html.should contain("value=\"line1\nline2\n\">")
  end

  it "sends a non-UTF-8 fetch-PoC body as a Uint8Array so the endpoint gets the exact bytes" do
    io = IO::Memory.new
    io << "POST /api HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/octet-stream\r\n\r\n"
    io.write(Bytes[0xff_u8, 0xfe_u8, 0x41_u8])
    html = poc(String.new(io.to_slice), "https://h.test")
    html.should contain("body: new Uint8Array([255, 254, 65]),")
    html.should_not contain(%(body: "\\xff))
  end

  it "escapes an HTML metacharacter in a form value so it cannot break out of the attribute" do
    html = poc("POST /f HTTP/1.1\r\nHost: h.test\r\n" \
               "Content-Type: application/x-www-form-urlencoded\r\n\r\nx=%22%3E%3Cscript%3E", "https://h.test")
    html.should contain(%(value="&quot;&gt;&lt;script&gt;">))
    html.should_not contain("<script>")
  end

  it "escapes < and > inside the fetch body string so a body cannot close the <script>" do
    html = poc("POST /api HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n\r\n{\"x\":\"</script>\"}", "https://h.test")
    html.should_not contain("</script>\"}")
    html.should contain("\\x3c/script\\x3e")
  end
end
