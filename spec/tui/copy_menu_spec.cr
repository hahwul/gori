require "../spec_helper"

include Gori::Tui

private def opt(opts : Array(CopyMenu::Option), key : Char) : CopyMenu::Option?
  opts.find { |o| o.key == key }
end

describe Gori::Tui::CopyMenu do
  describe ".request_options" do
    wire = "POST /api/login?next=/home HTTP/1.1\r\n" \
           "Host: example.com\r\n" \
           "Content-Type: application/json\r\n" \
           "Cookie: sid=abc; theme=dark\r\n" \
           "Content-Length: 21\r\n" \
           "\r\n" \
           "{\"user\":\"neo\"}"
    target = "https://example.com"

    it "resolves the full URL from an origin-form request line + target" do
      opt(CopyMenu.request_options(wire, target), 'u').not_nil!.text.should eq("https://example.com/api/login?next=/home")
    end

    it "copies the header block only (no request line, no body)" do
      headers = opt(CopyMenu.request_options(wire, target), 'h').not_nil!.text
      headers.should contain("Host: example.com")
      headers.should contain("Content-Type: application/json")
      headers.should_not contain("POST /api/login")
      headers.should_not contain("neo")
    end

    it "copies the body" do
      opt(CopyMenu.request_options(wire, target), 'b').not_nil!.text.should eq("{\"user\":\"neo\"}")
    end

    it "extracts the cookie value" do
      opt(CopyMenu.request_options(wire, target), 'c').not_nil!.text.should eq("sid=abc; theme=dark")
    end

    it "builds a shell-safe curl dropping Host/Content-Length, with method + body" do
      curl = opt(CopyMenu.request_options(wire, target), 'l').not_nil!.text
      curl.should contain("curl 'https://example.com/api/login?next=/home'")
      curl.should contain("-X POST")
      curl.should contain("-H 'Content-Type: application/json'")
      curl.should_not contain("-H 'Host:")
      curl.should_not contain("-H 'Content-Length:")
      curl.should contain("--data-raw '{\"user\":\"neo\"}'")
    end

    it "keeps the raw request verbatim" do
      opt(CopyMenu.request_options(wire, target), 'r').not_nil!.text.should eq(wire)
    end

    it "omits body/cookie rows when the request has neither (GET, no cookie)" do
      get = "GET /health HTTP/1.1\r\nHost: h\r\n\r\n"
      opts = CopyMenu.request_options(get, "http://h")
      opt(opts, 'b').should be_nil
      opt(opts, 'c').should be_nil
      opt(opts, 'u').not_nil!.text.should eq("http://h/health")
      # a GET curl carries no -X and no --data-raw
      curl = opt(opts, 'l').not_nil!.text
      curl.should_not contain("-X")
      curl.should_not contain("--data-raw")
      opt(opts, 'w').should be_nil
    end

    it "builds a shell-safe wscat command for a WebSocket Replay" do
      upgrade = "GET /gateway?bot=1 HTTP/1.1\r\n" \
                "Host: socket.example:8443\r\n" \
                "Connection: keep-alive, Upgrade\r\n" \
                "Upgrade: websocket\r\n" \
                "Sec-WebSocket-Key: stale-key\r\n" \
                "Sec-WebSocket-Version: 13\r\n" \
                "Sec-WebSocket-Extensions: permessage-deflate\r\n" \
                "Sec-WebSocket-Protocol: chat, superchat\r\n" \
                "Origin: https://app.example\r\n" \
                "Authorization: Bearer test-token\r\n" \
                "Cookie: sid=abc\r\n" \
                "X-Note: it's here\r\n\r\n"
      messages = [%({"op":1}), %({"text":"it's"})]
      wscat = opt(CopyMenu.request_options(upgrade, "https://socket.example:8443",
        websocket_messages: messages), 'w').not_nil!.text

      wscat.should contain("wscat -c 'wss://socket.example:8443/gateway?bot=1'")
      wscat.should contain("--host 'socket.example:8443'")
      wscat.should contain("-o 'https://app.example'")
      wscat.should contain("-s 'chat'")
      wscat.should contain("-s 'superchat'")
      wscat.should contain("-H 'Authorization: Bearer test-token'")
      wscat.should contain("-H 'Cookie: sid=abc'")
      wscat.should contain("-H 'X-Note: it'\\''s here'")
      wscat.should contain(%(-x '{"op":1}'))
      wscat.should contain(%(-x '{"text":"it'\\''s"}'))
      wscat.should contain("-w -1")
      wscat.should_not contain("Sec-WebSocket-Key")
      wscat.should_not contain("Sec-WebSocket-Version")
      wscat.should_not contain("Sec-WebSocket-Extensions")
      wscat.should_not contain("Connection:")
      wscat.should_not contain("Upgrade:")
    end

    it "offers interactive wscat without execute/wait flags when no messages exist" do
      upgrade = "GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      wscat = opt(CopyMenu.request_options(upgrade, "ws://h",
        websocket_messages: [] of String), 'w').not_nil!.text
      wscat.should contain("wscat -c 'ws://h/ws'")
      wscat.should_not contain("-x")
      wscat.should_not contain("-w")
    end

    it "uses an absolute-form request line as the URL directly" do
      abs = "GET http://plain.test/x HTTP/1.1\r\nHost: plain.test\r\n\r\n"
      opt(CopyMenu.request_options(abs, ""), 'u').not_nil!.text.should eq("http://plain.test/x")
    end

    it "keeps -X GET on a GET that carries a body (curl would else promote it to POST)" do
      req = "GET /q HTTP/1.1\r\nHost: h\r\n\r\nbodydata"
      curl = opt(CopyMenu.request_options(req, "http://h"), 'l').not_nil!.text
      curl.should contain("-X GET")
      curl.should contain("--data-raw 'bodydata'")
    end

    it "strips a path pasted into the target base so the request path isn't doubled" do
      req = "GET /real/path HTTP/1.1\r\nHost: h\r\n\r\n"
      opt(CopyMenu.request_options(req, "https://h:8443/leftover"), 'u').not_nil!.text
        .should eq("https://h:8443/real/path")
    end

    it "falls back to the Host header when no target base is set" do
      req = "GET /p HTTP/1.1\r\nHost: fromhost.test\r\n\r\n"
      opt(CopyMenu.request_options(req, ""), 'u').not_nil!.text.should eq("http://fromhost.test/p")
    end

    it "shell-escapes an embedded single quote in curl" do
      req = "GET /p HTTP/1.1\r\nHost: h\r\nX-Note: it's here\r\n\r\n"
      curl = opt(CopyMenu.request_options(req, "http://h"), 'l').not_nil!.text
      curl.should contain("-H 'X-Note: it'\\''s here'")
    end
  end

  describe ".response_options" do
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"
    body = "<h1>hi</h1>"

    it "copies status+headers with the trailing blank line stripped" do
      h = opt(CopyMenu.response_options(head, body), 'h').not_nil!.text
      h.should eq("HTTP/1.1 200 OK\r\nContent-Type: text/html")
    end

    it "copies the body" do
      opt(CopyMenu.response_options(head, body), 'b').not_nil!.text.should eq("<h1>hi</h1>")
    end

    it "rejoins head+body with exactly one separator for raw" do
      opt(CopyMenu.response_options(head, body), 'r').not_nil!.text
        .should eq("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<h1>hi</h1>")
    end

    it "omits the body row for an empty body" do
      opt(CopyMenu.response_options(head, ""), 'b').should be_nil
    end

    it "omits the Raw response row for an empty body (it would duplicate Status + headers)" do
      opts = CopyMenu.response_options(head, "")
      opt(opts, 'r').should be_nil
      opt(opts, 'h').not_nil!.text.should eq("HTTP/1.1 200 OK\r\nContent-Type: text/html")
    end
  end
end
