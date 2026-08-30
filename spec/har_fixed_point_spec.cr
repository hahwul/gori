require "./spec_helper"

private alias ImpHar = Gori::Import::Har

# Build a one-entry HAR and return the heads gori reconstructs from it. Driven through the
# real `parse` seam rather than the private normalizer, so what is pinned is what an operator
# importing a HAR actually gets.
private def import_heads(req_version : String, resp_version : String,
                         status_text : JSON::Any::Type = "OK") : {String, String}
  entry = {
    "startedDateTime" => "2026-01-01T00:00:00.000Z",
    "time"            => 1,
    "request"         => {
      "method" => "GET", "url" => "http://acme.test/x", "httpVersion" => req_version,
      "headers" => [] of Hash(String, String), "queryString" => [] of Hash(String, String),
      "cookies" => [] of Hash(String, String), "headersSize" => -1, "bodySize" => 0,
    },
    "response" => {
      "status" => 200, "statusText" => status_text, "httpVersion" => resp_version,
      "headers" => [] of Hash(String, String), "cookies" => [] of Hash(String, String),
      "content" => {"size" => 0, "mimeType" => "text/plain"},
      "redirectURL" => "", "headersSize" => -1, "bodySize" => 0,
    },
    "cache"   => {} of String => String,
    "timings" => {"send" => 0, "wait" => 1, "receive" => 0},
  }
  har = {"log" => {"version" => "1.2", "entries" => [entry]}}.to_json
  pair = parse_har(har).flows.first
  {String.new(pair.request.head), String.new(pair.response.not_nil!.head)}
end

private def parse_har(json : String) : Gori::Import::ParseResult
  path = File.tempname("gori-har", ".har")
  File.write(path, json)
  begin
    ImpHar.parse_file(path)
  ensure
    File.delete?(path)
  end
end

# `Export::Har` states the contract these pin: for a COMPLETE flow, "version, ordered headers
# with their framing, body bytes, status, reason, timing" survives, and export→import→export
# is a fixed point. Two of those were being rewritten on the way through.
describe "HAR round-trip fixed point" do
  # The export writes the STORED version verbatim and names the importer's normalizer as what
  # maps it back onto itself. Everything outside {1.0, 1.1, 2} used to collapse to HTTP/1.1,
  # silently rewriting an operator's version-line probe — `flow_mapper` keeps the request
  # line's token verbatim, and `Repeater::Plan` deliberately sends HTTP/9.9 unaltered.
  it "keeps an unusual but well-formed version instead of folding it to 1.1" do
    req, _ = import_heads("HTTP/0.9", "HTTP/1.1")
    req.should start_with("GET /x HTTP/0.9\r\n")

    req, _ = import_heads("HTTP/9.9", "HTTP/1.1")
    req.should start_with("GET /x HTTP/9.9\r\n")
  end

  # Chrome DevTools writes "http/2.0". Keeping it verbatim split the codebase's two h2 tests
  # against each other — `starts_with?("HTTP/2")` in the probe layer vs `== "HTTP/2"` in the
  # Repeater — so an imported h2 flow replayed over HTTP/1.1 while being scanned as h2.
  it "folds every h2 spelling to the canonical HTTP/2" do
    {"h2", "http/2", "HTTP/2", "http/2.0", "HTTP/2.0"}.each do |v|
      req, _ = import_heads(v, "HTTP/1.1")
      req.should start_with("GET /x HTTP/2\r\n")
    end
  end

  it "still folds the h2 spellings and defaults a token that is not a version" do
    req, _ = import_heads("h2", "HTTP/1.1")
    req.should start_with("GET /x HTTP/2\r\n")

    req, _ = import_heads("nonsense", "HTTP/1.1")
    req.should start_with("GET /x HTTP/1.1\r\n")
  end

  it "normalizes case without changing the version itself" do
    req, _ = import_heads("http/1.0", "HTTP/1.1")
    req.should start_with("GET /x HTTP/1.0\r\n")
  end

  # `Export::Har` writes the RESPONSE's own `httpVersion` (`resp.version`) precisely because an
  # origin may answer HTTP/1.0 to an HTTP/1.1 request, and 1.0 vs 1.1 is semantically
  # load-bearing (no default keep-alive). Only half that round trip existed: the reader rebuilt
  # the status line from the REQUEST version, so gori read its own export back with the
  # response head rewritten.
  it "keeps the response's own version rather than restating the request's" do
    _, resp = import_heads("HTTP/1.1", "HTTP/1.0")
    resp.should start_with("HTTP/1.0 200 OK\r\n")

    _, resp = import_heads("HTTP/2", "HTTP/1.1")
    resp.should start_with("HTTP/1.1 200 OK\r\n")
  end

  # The same drop split the status line against the phrase beside it: the "h2 carries no reason
  # phrase" decision already reads the RESPONSE's version, so an HTTP/1.1 request answered over
  # h2 came back as `HTTP/1.1 200` — the reason-less status line that is supposed to mean the
  # origin really sent one.
  it "does not fabricate a reason-less HTTP/1.1 status line for an h2 response" do
    _, resp = import_heads("HTTP/1.1", "HTTP/2", status_text: nil)
    resp.should start_with("HTTP/2 200\r\n")
  end

  # A HAR that states no response httpVersion at all still falls back to the request's.
  it "falls back to the request version when the response states none" do
    _, resp = import_heads("HTTP/1.0", "")
    resp.should start_with("HTTP/1.0 200 OK\r\n")
  end

  # `parse_response_head` yields reason == "" for a reason-less status line
  # (`HTTP/1.1 200\r\n`) — a real server fingerprint and a deliberate probe target. Export
  # writes `"statusText": ""`; importing that used to invent "OK", putting three bytes on the
  # head the origin never sent. ABSENT still earns a phrase; PRESENT-BUT-EMPTY does not.
  it "preserves an empty statusText rather than re-inventing a phrase" do
    _, resp = import_heads("HTTP/1.1", "HTTP/1.1", status_text: "")
    resp.should start_with("HTTP/1.1 200\r\n")
  end

  # `JSON::Any#[]?` returns JSON::Any(nil) for an EXPLICIT null, which is TRUTHY — so a
  # foreign HAR writing `"statusText": null` took the present branch and fabricated the
  # reason-less status line that is supposed to mean the origin really sent one.
  it "treats an explicit null statusText as absent, not as an empty phrase" do
    _, resp = import_heads("HTTP/1.1", "HTTP/1.1", status_text: nil)
    resp.should start_with("HTTP/1.1 200 OK\r\n")
  end

  it "still invents a phrase when statusText is absent entirely" do
    entry = {
      "startedDateTime" => "2026-01-01T00:00:00.000Z",
      "time"            => 1,
      "request"         => {
        "method" => "GET", "url" => "http://acme.test/x", "httpVersion" => "HTTP/1.1",
        "headers" => [] of Hash(String, String), "queryString" => [] of Hash(String, String),
        "cookies" => [] of Hash(String, String), "headersSize" => -1, "bodySize" => 0,
      },
      "response" => {
        "status" => 200, "httpVersion" => "HTTP/1.1",
        "headers" => [] of Hash(String, String), "cookies" => [] of Hash(String, String),
        "content" => {"size" => 0, "mimeType" => "text/plain"},
        "redirectURL" => "", "headersSize" => -1, "bodySize" => 0,
      },
      "cache"   => {} of String => String,
      "timings" => {"send" => 0, "wait" => 1, "receive" => 0},
    }
    har = {"log" => {"version" => "1.2", "entries" => [entry]}}.to_json
    pair = parse_har(har).flows.first
    String.new(pair.response.not_nil!.head).should start_with("HTTP/1.1 200 OK\r\n")
  end
end

# One 101 entry carrying Chrome's `_webSocketMessages`, parsed through the real seam.
private def ws_entry(messages, status = 101) : Gori::Import::Builder::FlowPair
  entry = {
    "startedDateTime" => "2026-01-01T00:00:00.000Z",
    "time"            => 1,
    "request"         => {
      "method" => "GET", "url" => "http://acme.test/chat", "httpVersion" => "HTTP/1.1",
      "headers" => [] of Hash(String, String), "queryString" => [] of Hash(String, String),
      "cookies" => [] of Hash(String, String), "headersSize" => -1, "bodySize" => 0,
    },
    "response" => {
      "status" => status, "statusText" => "Switching Protocols", "httpVersion" => "HTTP/1.1",
      "headers" => [] of Hash(String, String), "cookies" => [] of Hash(String, String),
      "content" => {"size" => 0, "mimeType" => ""},
      "redirectURL" => "", "headersSize" => -1, "bodySize" => 0,
    },
    "cache"              => {} of String => String,
    "timings"            => {"send" => 0, "wait" => 1, "receive" => 0},
    "_webSocketMessages" => messages,
  }
  parse_har({"log" => {"version" => "1.2", "entries" => [entry]}}.to_json).flows.first
end

# `Export::Har` writes a captured socket's transcript into Chrome's `_webSocketMessages` and
# states that it imports back into `ws_messages`. These pin the reader's half of that, at the
# parse seam — before a store is involved — because the direction/opcode/time decisions are
# what make the messages come back as the ones that were captured rather than as new ones.
describe "HAR _webSocketMessages round trip" do
  it "reads Chrome's send/receive back as the store's out/in" do
    pair = ws_entry([
      {"type" => "send", "time" => 1_780_000_000.5, "opcode" => 1, "data" => "up"},
      {"type" => "receive", "time" => 1_780_000_000.75, "opcode" => 1, "data" => "down"},
    ])
    pair.ws_messages.map(&.direction).should eq(["out", "in"])
    pair.ws_messages.map { |m| String.new(m.payload) }.should eq(["up", "down"])
    pair.ws_messages.map(&.opcode).should eq([1, 1])
  end

  # Every surface that seeds a WebSocket repeater from a capture replays the `out` rows, so an
  # unlabelled message defaulted the other way would be sent to the application under test as
  # one the operator never authored. Inbound is the direction that cannot do that.
  it "defaults an unlabelled or unrecognised type to INBOUND, never to a replayable one" do
    pair = ws_entry([
      {"time" => 1_780_000_000.0, "opcode" => 1, "data" => "no type"},
      {"type" => "nonsense", "time" => 1_780_000_000.0, "opcode" => 1, "data" => "bad type"},
    ])
    pair.ws_messages.map(&.direction).should eq(["in", "in"])
  end

  # `time` is a Unix timestamp in SECONDS and the store keeps micros. Rounding THROUGH
  # milliseconds is what makes it exact: a Float64 near 1.8e9 has an ulp of ~0.5µs, so
  # multiplying the seconds straight out sheds a microsecond and a re-export stops matching.
  it "restores each message's own time rather than stamping the import instant" do
    pair = ws_entry([
      {"type" => "send", "time" => 1_780_000_000.123, "opcode" => 1, "data" => "a"},
      {"type" => "receive", "time" => 1_780_000_042.456, "opcode" => 1, "data" => "b"},
    ])
    pair.ws_messages.map(&.created_at)
      .should eq([1_780_000_000_123_000_i64, 1_780_000_042_456_000_i64])
  end

  # A time that is absent, negative, or not a number is the spec's "not available" — the
  # message is still the operator's evidence, so it keeps its place in the stream at the
  # entry's own start rather than being dropped or filed at the epoch.
  it "falls back to the entry's startedDateTime for an unusable time" do
    started = Time.parse_rfc3339("2026-01-01T00:00:00.000Z").to_unix_ms * 1_000
    pair = ws_entry([
      {"type" => "send", "opcode" => 1, "data" => "a"},
      {"type" => "send", "time" => -1, "opcode" => 1, "data" => "b"},
    ])
    pair.ws_messages.map(&.created_at).should eq([started, started])
  end

  # `encoding` beside `data` is gori's marker for the base64 branch — Chrome base64s a binary
  # frame with no marker at all, which is not a thing a reader can invert. A marked payload
  # comes back byte-exact; an unmarked one is taken as the literal text it claims to be.
  it "decodes a base64-marked payload and leaves an unmarked one alone" do
    pair = ws_entry([
      {"type" => "send", "time" => 1_780_000_000.0, "opcode" => 2,
       "data" => "AP/+", "encoding" => "base64"},
      {"type" => "send", "time" => 1_780_000_000.0, "opcode" => 1, "data" => "AP/+"},
    ])
    pair.ws_messages[0].payload.should eq(Bytes[0x00, 0xff, 0xfe])
    pair.ws_messages[1].payload.should eq("AP/+".to_slice)
  end

  # This used to be "ignores a transcript on an entry whose status is not 101", justified as
  # "the same question every other surface asks to decide 'is this a socket'" — and that was
  # the trap. #733 gave gori a socket with no 101 in it (RFC 8441 extended CONNECT, answered
  # `200`), #742 re-pointed every reader at the ROWS, and `Export::Har` now writes that entry
  # with its real CONNECT/200 handshake. The gate would have dropped the transcript of a HAR
  # gori had just written itself. The entry carrying `_webSocketMessages` is the question.
  it "keeps a transcript on an entry whose status is not 101 (a socket over h2)" do
    msgs = ws_entry([{"type" => "send", "time" => 1_780_000_000.0, "opcode" => 1, "data" => "x"}],
      status: 200).ws_messages
    msgs.map(&.direction).should eq(["out"])
    msgs.map { |m| String.new(m.payload) }.should eq(["x"])
  end

  it "leaves an ordinary entry with no transcript at all" do
    entry = {
      "startedDateTime" => "2026-01-01T00:00:00.000Z",
      "time"            => 1,
      "request"         => {
        "method" => "GET", "url" => "http://acme.test/x", "httpVersion" => "HTTP/1.1",
        "headers" => [] of Hash(String, String), "queryString" => [] of Hash(String, String),
        "cookies" => [] of Hash(String, String), "headersSize" => -1, "bodySize" => 0,
      },
      "response" => {
        "status" => 200, "statusText" => "OK", "httpVersion" => "HTTP/1.1",
        "headers" => [] of Hash(String, String), "cookies" => [] of Hash(String, String),
        "content" => {"size" => 0, "mimeType" => "text/plain"},
        "redirectURL" => "", "headersSize" => -1, "bodySize" => 0,
      },
      "cache"   => {} of String => String,
      "timings" => {"send" => 0, "wait" => 1, "receive" => 0},
    }
    har = {"log" => {"version" => "1.2", "entries" => [entry]}}.to_json
    parse_har(har).flows.first.ws_messages.should be_empty
  end
end

# One RFC 8441 extended CONNECT entry — the shape `Export::Har` writes for a WebSocket
# captured over HTTP/2: `CONNECT` answered `200`, with the `:protocol` carried as the
# `X-Gori-Protocol` marker line and no 101 anywhere.
private def h2_connect_entry(protocol : String?) : Gori::Import::Builder::FlowPair
  headers = protocol ? [{"name" => "X-Gori-Protocol", "value" => protocol}] : [] of Hash(String, String)
  entry = {
    "startedDateTime" => "2026-01-01T00:00:00.000Z",
    "time"            => 1,
    "request"         => {
      "method" => "CONNECT", "url" => "https://acme.test/ws", "httpVersion" => "HTTP/2",
      "headers" => headers, "queryString" => [] of Hash(String, String),
      "cookies" => [] of Hash(String, String), "headersSize" => -1, "bodySize" => 0,
    },
    "response" => {
      "status" => 200, "statusText" => "", "httpVersion" => "HTTP/2",
      "headers" => [] of Hash(String, String), "cookies" => [] of Hash(String, String),
      "content" => {"size" => 0, "mimeType" => ""},
      "redirectURL" => "", "headersSize" => -1, "bodySize" => 0,
    },
    "cache"   => {} of String => String,
    "timings" => {"send" => 0, "wait" => 1, "receive" => 0},
  }
  parse_har({"log" => {"version" => "1.2", "entries" => [entry]}}.to_json).flows.first
end

# The `connect_protocol` COLUMN (V16) is what `Proto.classify` and `QL`'s `proto:ws` read, and
# the store takes it from its caller rather than deriving it off the head the way it derives
# `request_content_type`. So an import that did not carry it made the export→import round trip
# lossy on the ONE fact that makes an h2 socket a socket: gori could write the HAR, read it
# straight back, print the whole transcript — and still show `HTTPS` in the PROTO column and
# miss the flow with `proto:ws`.
describe "HAR extended-CONNECT round trip" do
  it "recovers the :protocol from the marker line gori itself wrote" do
    req = h2_connect_entry("websocket").request
    req.connect_protocol.should eq("websocket")
    Gori::Proto.websocket_connect?(200, req.connect_protocol).should be_true
  end

  # Verbatim, not folded to a boolean (V16): `connect-udp` (RFC 9298) and `connect-ip`
  # (RFC 9484) are extended CONNECTs that are NOT RFC 6455 framing, and the column is what
  # keeps that distinction on disk.
  it "keeps a non-WebSocket extended CONNECT's token, and does not call it a socket" do
    req = h2_connect_entry("connect-udp").request
    req.connect_protocol.should eq("connect-udp")
    Gori::Proto.websocket_connect?(200, req.connect_protocol).should be_false
    Gori::Proto.classify(200, nil, nil, req.connect_protocol).should eq(Gori::Proto::Kind::Http)
  end

  # NULL means "not recorded", never "this was not one" — an ordinary entry must not acquire
  # a column value it never had.
  it "leaves an entry with no marker line alone" do
    h2_connect_entry(nil).request.connect_protocol.should be_nil
  end
end
