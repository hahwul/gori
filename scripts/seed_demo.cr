# Seeds a "demo" registry project with a realistic, varied dataset so every tab in
# the TUI has something real to explore:
#
#   History / Target(Sitemap+Discover) / Issues / Notes / Scope       — captured traffic
#   Repeater / Fuzzer / Miner / Sequencer                             — pre-seeded workbench sessions
#   Rewriter                                                          — match&replace rules
#   OAST                                                              — an out-of-band listener with callbacks
#   Probe                                                             — passive scan + a custom rule
#   Decoder / JWT / Comparer                                          — data to send into the ephemeral tools
#
#   crystal run scripts/seed_demo.cr
#
# Re-runnable: it wipes any existing "demo" project first, then recreates it.
require "file_utils"
require "base64"
require "openssl/hmac"
require "uri"
require "../src/gori"
require "../src/gori/project_registry"

include Gori

alias S = Gori::Store

US_PER_MIN = 60_000_000_i64

# Build raw HTTP/1.1 wire bytes + insert one complete flow; returns its id.
def add_flow(store : S, created_at : Int64, *,
             scheme = "https", host : String, port = 443,
             method = "GET", target : String,
             req_headers = {} of String => String, req_body : String? = nil,
             status : Int32, reason : String, ctype : String? = nil,
             resp_headers = {} of String => String, resp_body : String? = nil,
             http = "HTTP/1.1", dur_us = 28_000_i64,
             state = S::FlowState::Complete) : Int64
  req_head = String.build do |b|
    b << method << ' ' << target << ' ' << http << "\r\n"
    b << "Host: " << host << "\r\n"
    b << "User-Agent: gori-demo/1.0\r\n"
    b << "Accept: */*\r\n"
    req_headers.each { |k, v| b << k << ": " << v << "\r\n" }
    if body = req_body
      b << "Content-Type: application/json\r\n"
      b << "Content-Length: " << body.bytesize << "\r\n"
    end
    b << "\r\n"
  end

  fid = store.insert_flow(S::CapturedRequest.new(
    created_at: created_at, scheme: scheme, host: host, port: port,
    method: method, target: target, http_version: http,
    head: req_head.to_slice, body: req_body.try(&.to_slice),
    body_size: req_body.try(&.bytesize.to_i64)))

  resp_head = String.build do |b|
    b << http << ' ' << status << ' ' << reason << "\r\n"
    b << "Server: nginx/1.25.3\r\n"
    b << "Date: Thu, 19 Jun 2026 09:00:00 GMT\r\n"
    b << "Content-Type: " << ctype << "\r\n" if ctype
    b << "Content-Length: " << (resp_body.try(&.bytesize) || 0) << "\r\n"
    resp_headers.each { |k, v| b << k << ": " << v << "\r\n" }
    b << "\r\n"
  end

  store.update_response(S::CapturedResponse.new(
    flow_id: fid, status: status, reason: reason, content_type: ctype,
    head: resp_head.to_slice, body: resp_body.try(&.to_slice),
    body_size: resp_body.try(&.bytesize.to_i64),
    ttfb_us: dur_us // 2, duration_us: dur_us, state: state))
  fid
end

# Lower-level inserter for flows whose heads aren't plain HTTP/1.1 JSON (WebSocket
# upgrades, HTTP/2 gRPC, SSE, SAML form posts): the caller supplies the exact
# request/response head text and raw body bytes. Returns the new flow id.
def raw_flow(store : S, created_at : Int64, *,
             scheme = "https", host : String, port = 443,
             method : String, target : String, http = "HTTP/1.1",
             req_head : String, req_body : Bytes? = nil,
             status : Int32, reason : String, ctype : String? = nil,
             resp_head : String, resp_body : Bytes? = nil, dur_us = 28_000_i64,
             h2_conn_id : Int64? = nil, h2_stream_id : Int64? = nil) : Int64
  fid = store.insert_flow(S::CapturedRequest.new(
    created_at: created_at, scheme: scheme, host: host, port: port,
    method: method, target: target, http_version: http,
    head: req_head.to_slice, body: req_body,
    h2_conn_id: h2_conn_id, h2_stream_id: h2_stream_id))

  store.update_response(S::CapturedResponse.new(
    flow_id: fid, status: status, reason: reason, content_type: ctype,
    head: resp_head.to_slice, body: resp_body,
    ttfb_us: dur_us // 2, duration_us: dur_us))
  fid
end

# Build a minimal HTTP/1.1 request string for replay/fuzz/miner seed rows.
def replay_req(method : String, host : String, target : String,
               headers = {} of String => String, body : String? = nil) : String
  String.build do |b|
    b << method << ' ' << target << " HTTP/1.1\r\n"
    b << "Host: " << host << "\r\n"
    headers.each { |k, v| b << k << ": " << v << "\r\n" }
    if body
      b << "Content-Length: " << body.bytesize << "\r\n"
      b << "\r\n" << body
    else
      b << "\r\n"
    end
  end
end

# protobuf length-delimited string field (wire type 2). Value < 256 bytes so the
# length is a single varint byte — plenty for the demo greeter messages.
def pb_string_field(field : Int32, value : String) : Bytes
  io = IO::Memory.new
  io.write_byte(((field << 3) | 2).to_u8)
  io.write_byte(value.bytesize.to_u8)
  io << value
  io.to_slice
end

# gRPC length-prefixed frame: 1-byte compressed flag + 4-byte big-endian length + message.
def grpc_frame(msg : Bytes) : Bytes
  io = IO::Memory.new
  io.write_byte(0_u8) # not compressed
  io.write_bytes(msg.size.to_u32, IO::ByteFormat::BigEndian)
  io.write(msg)
  io.to_slice
end

# base64url without padding (the JWT segment encoding).
def b64url(data : String | Bytes) : String
  Base64.urlsafe_encode(data, padding: false)
end

# Build a real, decodable HS256 JWT so the JWT tab genuinely works on this demo:
# decode shows the claims, "weak secret" cracks WEAK_SECRET, and the alg:none /
# header-inject attacks re-forge from the real header/payload. Deliberately signed
# with a guessable secret so the weak-secret attack (and the matching Issue) land.
WEAK_SECRET = "secret"

def make_jwt(secret : String) : String
  header = %({"alg":"HS256","typ":"JWT"})
  payload = %({"sub":"1","name":"alice","role":"customer","iss":"api.demo.test","iat":1718787600,"exp":1718791200})
  signing_input = "#{b64url(header)}.#{b64url(payload)}"
  sig = b64url(OpenSSL::HMAC.digest(:sha256, secret, signing_input))
  "#{signing_input}.#{sig}"
end

Paths.ensure_dirs
registry = ProjectRegistry.new(Paths.projects_dir)

# Fresh start: drop any existing "demo" project.
if existing = registry.list.find { |p| p.name == "demo" }
  registry.delete(existing)
  puts "• removed existing demo project"
end

project = registry.create("demo",
  "Demo target for exploring gori's TUI — a fictional shop + JSON API, plus a real, " \
  "replayable capture of www.hahwul.com. Captured browsing of shop.demo.test / " \
  "api.demo.test / cdn.demo.test / www.hahwul.com with planted issues; Repeater/Fuzzer/" \
  "Miner/Sequencer sessions; Rewriter rules; an OAST listener with callbacks; and entity " \
  "links tying issues and notes to related workbench items.")
store = S.open(project.db_path)
puts "• created project 'demo' at #{project.db_path}"

# The shared bearer token used across the API flows below — a REAL HS256 JWT (weakly
# signed) so the JWT tab can decode/crack/re-forge it and the Sequencer/Decoder have
# something genuine to chew on.
jwt = make_jwt(WEAK_SECRET)

# Timeline: spread flows over the last ~95 minutes so History reads like a session.
base = Time.utc.to_unix * 1_000_000_i64 - 95_i64 * US_PER_MIN
t = ->(min : Int32) { base + min.to_i64 * US_PER_MIN }

html = ->(title : String, body : String) {
  "<!doctype html>\n<html><head><title>#{title}</title></head>\n<body>#{body}</body></html>\n"
}

ids = {} of Symbol => Int64

ids[:home] = add_flow(store, t.call(0), host: "shop.demo.test", target: "/",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_body: html.call("Demo Shop", "<h1>Welcome to Demo Shop</h1><a href=/login>Sign in</a>"))

add_flow(store, t.call(1), host: "shop.demo.test", target: "/robots.txt",
  status: 200, reason: "OK", ctype: "text/plain",
  resp_body: "User-agent: *\nDisallow: /admin\nDisallow: /api/\n")

add_flow(store, t.call(2), scheme: "https", host: "cdn.demo.test", target: "/assets/app.js",
  status: 200, reason: "OK", ctype: "application/javascript",
  resp_body: "console.log('demo shop boot');\nwindow.API='https://api.demo.test/v1';\n")

add_flow(store, t.call(4), host: "shop.demo.test", target: "/login",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_body: html.call("Sign in", "<form method=post action=/api/login><input name=username><input name=password type=password></form>"))

ids[:login] = add_flow(store, t.call(6), host: "shop.demo.test", target: "/api/login",
  method: "POST", req_body: %({"username":"alice","password":"hunter2"}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_headers: {"Set-Cookie" => "sid=8f3a..; Path=/"},
  resp_body: %({"ok":true,"token":"#{jwt}","user_id":1}))

add_flow(store, t.call(9), host: "api.demo.test", target: "/v1/products",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %([{"id":42,"name":"Blue Widget","price":1999},{"id":43,"name":"Red Widget","price":2499}]))

add_flow(store, t.call(11), host: "api.demo.test", target: "/v1/products/42",
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"id":42,"name":"Blue Widget","price":1999,"stock":17,"sku":"BW-0042"}))

add_flow(store, t.call(13), host: "api.demo.test", target: "/v1/cart", method: "POST",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_body: %({"product_id":42,"qty":2}),
  status: 201, reason: "Created", ctype: "application/json",
  resp_body: %({"cart_id":9,"items":[{"product_id":42,"qty":2}],"total":3998}))

ids[:cart] = add_flow(store, t.call(15), host: "api.demo.test", target: "/v1/cart",
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"cart_id":9,"items":[{"product_id":42,"qty":2}],"total":3998}))

add_flow(store, t.call(17), host: "api.demo.test", target: "/v1/orders",
  status: 401, reason: "Unauthorized", ctype: "application/json",
  resp_body: %({"error":"missing or invalid token"}))

add_flow(store, t.call(20), host: "shop.demo.test", target: "/admin",
  status: 403, reason: "Forbidden", ctype: "text/html; charset=utf-8",
  resp_body: html.call("Forbidden", "<h1>403</h1><p>Admins only.</p>"))

add_flow(store, t.call(23), host: "shop.demo.test", target: "/search?q=widgets",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_body: html.call("Search", "<p>Results for <b>widgets</b>: 2 found</p>"))

# Reflected XSS candidate: the q value is echoed unescaped into the response.
ids[:xss] = add_flow(store, t.call(26), host: "shop.demo.test",
  target: "/search?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_body: html.call("Search", "<p>Results for <b><script>alert(1)</script></b>: 0 found</p>"))

add_flow(store, t.call(31), host: "api.demo.test", target: "/v1/users/1",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"id":1,"name":"Alice","email":"alice@demo.test","role":"customer"}))

# IDOR candidate: same token reads another user's record.
ids[:idor] = add_flow(store, t.call(33), host: "api.demo.test", target: "/v1/users/2",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"id":2,"name":"Bob","email":"bob@demo.test","role":"admin","phone":"+1-555-0102"}))

add_flow(store, t.call(36), host: "api.demo.test", target: "/v1/profile", method: "PUT",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_body: %({"name":"Alice A.","newsletter":true}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"id":1,"name":"Alice A.","newsletter":true}))

add_flow(store, t.call(38), host: "api.demo.test", target: "/v1/cart/9", method: "DELETE",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  status: 204, reason: "No Content")

add_flow(store, t.call(41), host: "shop.demo.test", target: "/missing-page",
  status: 404, reason: "Not Found", ctype: "text/html; charset=utf-8",
  resp_body: html.call("Not Found", "<h1>404</h1>"))

# Verbose 500 leaks a stack trace + framework version.
ids[:err500] = add_flow(store, t.call(44), host: "api.demo.test", target: "/v1/debug",
  status: 500, reason: "Internal Server Error", ctype: "text/html; charset=utf-8",
  resp_body: "<h1>RuntimeError at /v1/debug</h1><pre>NoMethodError: undefined method 'each' for nil\n  app/controllers/debug_controller.rb:14\n  rack (3.0.8) lib/rack/handler.rb:88\nDemoFramework 4.2.1</pre>")

# Blind SSRF: an "import from URL" endpoint fetches an operator-supplied URL server-side.
# The response is generic success (no reflected content), so it's confirmed OUT OF BAND —
# the OAST listener seeded below received the resulting DNS + HTTP callback (see its tab).
ids[:ssrf] = add_flow(store, t.call(43), host: "api.demo.test", target: "/v1/import", method: "POST",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_body: %({"url":"https://a1b2c3d4.oast.demo.test/hook?from=api.demo.test"}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"status":"ok","imported":true,"bytes":0}))

# Rate limiting: same products listing, second page, throttled.
add_flow(store, t.call(45), host: "api.demo.test", target: "/v1/products?page=2",
  status: 429, reason: "Too Many Requests", ctype: "application/json",
  resp_headers: {"Retry-After" => "30"},
  resp_body: %({"error":"rate limit exceeded"}))

# Stale marketing link, redirects to the current promo page.
add_flow(store, t.call(46), host: "shop.demo.test", target: "/old-promo",
  status: 301, reason: "Moved Permanently",
  resp_headers: {"Location" => "/promo"})

add_flow(store, t.call(47), host: "api.demo.test", target: "/v1/profile/notifications", method: "PATCH",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_body: %({"emailAlerts":false}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"emailAlerts":false}))

puts "• inserted #{ids.size} keyed + several more flows"

# --- Protocol showcase: WebSocket / gRPC / SSE / GraphQL / SAML -------------
# gori captures more than plain request/response. These flows exercise the panes
# the TUI grows for richer protocols (MESSAGES for WebSocket, FRAMES + gRPC
# message deframing for HTTP/2) and the bodies a hunter typically has to decode.

# WebSocket: a chat upgrade (101) with a bidirectional message log. The detail
# view grows a MESSAGES pane for status==101 flows (→ client→server, ← server→client).
ws_req = String.build do |b|
  b << "GET /ws/chat HTTP/1.1\r\n"
  b << "Host: api.demo.test\r\n"
  b << "User-Agent: gori-demo/1.0\r\n"
  b << "Upgrade: websocket\r\n"
  b << "Connection: Upgrade\r\n"
  b << "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
  b << "Sec-WebSocket-Version: 13\r\n"
  b << "Origin: https://shop.demo.test\r\n\r\n"
end
ws_resp = String.build do |b|
  b << "HTTP/1.1 101 Switching Protocols\r\n"
  b << "Upgrade: websocket\r\n"
  b << "Connection: Upgrade\r\n"
  b << "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
end
ids[:ws] = raw_flow(store, t.call(48), host: "api.demo.test", method: "GET", target: "/ws/chat",
  req_head: ws_req, status: 101, reason: "Switching Protocols",
  resp_head: ws_resp, dur_us: 1_200_000_i64)
ws_id = ids[:ws]

# direction "out" = client→server, "in" = server→client; opcode 1=text, 2=binary.
ws_msgs = [
  {"out", 1, %({"type":"hello","user":"alice","room":"general"})},
  {"in", 1, %({"type":"welcome","room":"general","online":42})},
  {"in", 1, %({"type":"history","messages":[{"from":"bob","text":"morning!"}]})},
  {"out", 1, %({"type":"msg","text":"hi everyone"})},
  {"in", 1, %({"type":"msg","from":"bob","text":"hey alice!"})},
  {"out", 2, ""}, # binary presence/typing blob — replaced below
  {"in", 1, %({"type":"presence","user":"carol","status":"online"})},
  {"out", 1, %({"type":"typing","state":true})},
  {"in", 1, %({"type":"msg","from":"carol","text":"what's the cart total?"})},
  {"out", 1, %({"type":"ping","t":1718787600})},
  {"in", 1, %({"type":"pong","t":1718787600})},
]
ws_msgs.each do |(dir, op, payload)|
  bytes = op == 2 ? Bytes[0x08, 0x96, 0x01, 0x12, 0x05, 0x61, 0x6c, 0x69, 0x63, 0x65] : payload.to_slice
  store.insert_ws_message(ws_id, dir, op, bytes)
end

# gRPC over HTTP/2: a unary demo.Greeter/SayHello call. The flow links to a raw
# h2 frame log (FRAMES pane) and its application/grpc body deframes into
# length-prefixed protobuf messages (shown as hex — opaque without the .proto).
greeter_conn = store.insert_h2_connection("api.demo.test", 443, "h2")
req_msg = grpc_frame(pb_string_field(1, "alice"))
resp_msg = grpc_frame(pb_string_field(1, "Hello, alice! You have 2 items in your cart."))

# A representative frame log. type: Data=0x0 Headers=0x1 Settings=0x4;
# flags: END_STREAM=0x1 END_HEADERS=0x4. HPACK/SETTINGS payloads are illustrative bytes.
store.insert_h2_frame(greeter_conn, "out", 0x4_u8, 0x0_u8, 0_u32, Bytes[0x00, 0x03, 0x00, 0x00, 0x00, 0x64])
store.insert_h2_frame(greeter_conn, "in", 0x4_u8, 0x0_u8, 0_u32, Bytes[0x00, 0x04, 0x00, 0x10, 0x00, 0x00])
store.insert_h2_frame(greeter_conn, "out", 0x8_u8, 0x0_u8, 0_u32, Bytes[0x00, 0x00, 0x00, 0xff]) # WINDOW_UPDATE
store.insert_h2_frame(greeter_conn, "out", 0x1_u8, 0x4_u8, 1_u32,
  Bytes[0x82, 0x87, 0x41, 0x8a, 0xa0, 0xe4, 0x1d, 0x13, 0x9d, 0x09, 0xb8, 0xf0, 0x1e, 0x07]) # HEADERS
store.insert_h2_frame(greeter_conn, "out", 0x0_u8, 0x1_u8, 1_u32, req_msg)                   # DATA END_STREAM
store.insert_h2_frame(greeter_conn, "in", 0x1_u8, 0x4_u8, 1_u32,
  Bytes[0x88, 0x5f, 0x10, 0x61, 0x70, 0x70, 0x6c, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6f, 0x6e]) # HEADERS
store.insert_h2_frame(greeter_conn, "in", 0x0_u8, 0x0_u8, 1_u32, resp_msg)                   # DATA
store.insert_h2_frame(greeter_conn, "in", 0x1_u8, 0x5_u8, 1_u32,
  Bytes[0x40, 0x0b, 0x67, 0x72, 0x70, 0x63, 0x2d, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x01, 0x30]) # trailers grpc-status:0
store.flush                                                                                        # fire-and-forget frames committed before any close

grpc_req_head = String.build do |b|
  b << "POST /demo.Greeter/SayHello HTTP/2\r\n"
  b << "Host: api.demo.test\r\n"
  b << "content-type: application/grpc\r\n"
  b << "te: trailers\r\n"
  b << "grpc-encoding: identity\r\n"
  b << "user-agent: grpc-demo/1.0 grpc-crystal/0.3\r\n\r\n"
end
grpc_resp_head = String.build do |b|
  b << "HTTP/2 200 OK\r\n"
  b << "content-type: application/grpc\r\n"
  b << "grpc-status: 0\r\n"
  b << "grpc-message: OK\r\n\r\n"
end
raw_flow(store, t.call(50), host: "api.demo.test", method: "POST",
  target: "/demo.Greeter/SayHello", http: "HTTP/2",
  req_head: grpc_req_head, req_body: req_msg,
  status: 200, reason: "OK", ctype: "application/grpc",
  resp_head: grpc_resp_head, resp_body: resp_msg, dur_us: 42_000_i64,
  h2_conn_id: greeter_conn, h2_stream_id: 1_i64)

# SSE: a long-lived text/event-stream. gori streams it byte-exact and stores the
# whole stream as the response body (no per-event splitting); it renders as text.
sse_req = String.build do |b|
  b << "GET /v1/stream/prices HTTP/1.1\r\n"
  b << "Host: api.demo.test\r\n"
  b << "User-Agent: gori-demo/1.0\r\n"
  b << "Accept: text/event-stream\r\n\r\n"
end
sse_resp = String.build do |b|
  b << "HTTP/1.1 200 OK\r\n"
  b << "Server: nginx/1.25.3\r\n"
  b << "Content-Type: text/event-stream; charset=utf-8\r\n"
  b << "Cache-Control: no-cache\r\n"
  b << "Connection: keep-alive\r\n\r\n"
end
sse_body = <<-SSE
  retry: 3000

  event: price
  id: 1
  data: {"sku":"BW-0042","price":1999}

  event: price
  id: 2
  data: {"sku":"RW-0043","price":2499}

  event: stock
  id: 3
  data: {"sku":"BW-0042","stock":16}

  : heartbeat

  event: ping
  data: {"t":1718787600}

  SSE
raw_flow(store, t.call(53), host: "api.demo.test", method: "GET", target: "/v1/stream/prices",
  req_head: sse_req, status: 200, reason: "OK", ctype: "text/event-stream",
  resp_head: sse_resp, resp_body: sse_body.to_slice, dur_us: 5_000_000_i64)

# GraphQL: ordinary application/json POSTs to /graphql (query, mutation, and a
# revealing introspection). No special handling — the JSON body is highlighted.
add_flow(store, t.call(56), host: "api.demo.test", target: "/graphql", method: "POST",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_body: %({"operationName":"GetProducts","query":"query GetProducts($first: Int!) { products(first: $first) { id name price } }","variables":{"first":2}}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"data":{"products":[{"id":"42","name":"Blue Widget","price":1999},{"id":"43","name":"Red Widget","price":2499}]}}))

add_flow(store, t.call(58), host: "api.demo.test", target: "/graphql", method: "POST",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_body: %({"operationName":"AddToCart","query":"mutation AddToCart($id: ID!, $qty: Int!) { addToCart(productId: $id, qty: $qty) { cartId total } }","variables":{"id":"42","qty":2}}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"data":{"addToCart":{"cartId":"9","total":3998}}}))

ids[:gql] = add_flow(store, t.call(60), host: "api.demo.test", target: "/graphql", method: "POST",
  req_body: %({"query":"query IntrospectionQuery { __schema { queryType { name } types { name kind } } }"}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"data":{"__schema":{"queryType":{"name":"Query"},"types":[{"name":"Query","kind":"OBJECT"},{"name":"Product","kind":"OBJECT"},{"name":"User","kind":"OBJECT"},{"name":"Mutation","kind":"OBJECT"},{"name":"CartItem","kind":"OBJECT"}]}}}))

# SAML: an SP-initiated SSO assertion POSTed to the ACS. The SAMLResponse is a
# url-encoded base64 XML blob — decode it in the Decoder tab: url-decode → base64-decode.
saml_xml = <<-XML
  <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="_demo123" Version="2.0" IssueInstant="2026-06-26T09:00:00Z" Destination="https://shop.demo.test/saml/acs">
    <saml:Issuer>https://idp.demo.test/metadata</saml:Issuer>
    <samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>
    <saml:Assertion ID="_assert123" Version="2.0" IssueInstant="2026-06-26T09:00:00Z">
      <saml:Issuer>https://idp.demo.test/metadata</saml:Issuer>
      <saml:Subject>
        <saml:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">alice@demo.test</saml:NameID>
      </saml:Subject>
      <saml:Conditions NotBefore="2026-06-26T09:00:00Z" NotOnOrAfter="2026-06-26T09:10:00Z"/>
      <saml:AttributeStatement>
        <saml:Attribute Name="role"><saml:AttributeValue>customer</saml:AttributeValue></saml:Attribute>
        <saml:Attribute Name="email"><saml:AttributeValue>alice@demo.test</saml:AttributeValue></saml:Attribute>
      </saml:AttributeStatement>
    </saml:Assertion>
  </samlp:Response>
  XML
saml_form = "SAMLResponse=#{URI.encode_www_form(Base64.strict_encode(saml_xml))}&RelayState=#{URI.encode_www_form("/dashboard")}"
saml_req = String.build do |b|
  b << "POST /saml/acs HTTP/1.1\r\n"
  b << "Host: shop.demo.test\r\n"
  b << "User-Agent: gori-demo/1.0\r\n"
  b << "Content-Type: application/x-www-form-urlencoded\r\n"
  b << "Origin: https://idp.demo.test\r\n"
  b << "Referer: https://idp.demo.test/sso\r\n"
  b << "Content-Length: " << saml_form.bytesize << "\r\n\r\n"
end
saml_resp = String.build do |b|
  b << "HTTP/1.1 302 Found\r\n"
  b << "Server: nginx/1.25.3\r\n"
  b << "Location: /dashboard\r\n"
  b << "Set-Cookie: session=demo-saml-9f3a; Path=/; HttpOnly; Secure\r\n"
  b << "Content-Length: 0\r\n\r\n"
end
raw_flow(store, t.call(62), host: "shop.demo.test", method: "POST", target: "/saml/acs",
  req_head: saml_req, req_body: saml_form.to_slice,
  status: 302, reason: "Found", resp_head: saml_resp, dur_us: 64_000_i64)

puts "• inserted protocol showcase: websocket(#{ws_msgs.size} msgs) + grpc + sse + 3×graphql + saml"

# --- Real target: www.hahwul.com (live — Repeater ^R genuinely hits it) ----
# Every flow below reflects an actual response captured from the real
# https://www.hahwul.com (GitHub Pages behind Fastly/Varnish) — titles, status
# codes and headers are accurate, bodies are trimmed. Unlike the fictional
# hosts above, sending one of these from Repeater really goes out over the
# network and comes back with a live response: good for trying Repeater/Diff/
# Probe against genuine traffic instead of only synthetic data.
gh_req_head = ->(method : String, target : String) {
  String.build do |b|
    b << method << ' ' << target << " HTTP/2\r\n"
    b << "host: www.hahwul.com\r\n"
    b << "user-agent: gori-demo/1.0\r\n"
    b << "accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n\r\n"
  end
}
gh_resp_head = ->(status : Int32, reason : String, ctype : String, size : Int32, etag : String, cache : String) {
  String.build do |b|
    b << "HTTP/2 " << status << ' ' << reason << "\r\n"
    b << "server: GitHub.com\r\n"
    b << "content-type: " << ctype << "\r\n"
    b << "content-length: " << size << "\r\n"
    b << "last-modified: Tue, 30 Jun 2026 14:14:45 GMT\r\n"
    b << "etag: \"" << etag << "\"\r\n"
    b << "access-control-allow-origin: *\r\n"
    b << "cache-control: max-age=600\r\n"
    b << "vary: Accept-Encoding\r\n"
    b << "via: 1.1 varnish\r\n"
    b << "x-cache: " << cache << "\r\n"
    b << "x-served-by: cache-icn1450039-ICN\r\n\r\n"
  end
}

hahwul_robots = "User-agent: *\nAllow: /\n\nSitemap: https://www.hahwul.com/sitemap.xml\n"
raw_flow(store, t.call(65), host: "www.hahwul.com", method: "GET", target: "/robots.txt",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/robots.txt"),
  status: 200, reason: "OK", ctype: "text/plain; charset=utf-8",
  resp_head: gh_resp_head.call(200, "OK", "text/plain; charset=utf-8", hahwul_robots.bytesize, "6a43cf48-44", "HIT"),
  resp_body: hahwul_robots.to_slice, dur_us: 165_000_i64)

hahwul_sitemap = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    <url><loc>https://www.hahwul.com/</loc></url>
    <url><loc>https://www.hahwul.com/posts/2026/rust-and-crystal/</loc><lastmod>2026-06-30</lastmod></url>
    <url><loc>https://www.hahwul.com/posts/2026/10years/</loc><lastmod>2026-02-22</lastmod></url>
    <url><loc>https://www.hahwul.com/posts/2026/traveling-with-hermes-in-japan/</loc><lastmod>2026-04-19</lastmod></url>
    <url><loc>https://www.hahwul.com/notes/claude-code/remove-co-authored-by/</loc></url>
    <url><loc>https://www.hahwul.com/about/</loc></url>
  </urlset>
  XML
raw_flow(store, t.call(68), host: "www.hahwul.com", method: "GET", target: "/sitemap.xml",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/sitemap.xml"),
  status: 200, reason: "OK", ctype: "application/xml",
  resp_head: gh_resp_head.call(200, "OK", "application/xml", hahwul_sitemap.bytesize, "6a43cf50-f19e", "MISS"),
  resp_body: hahwul_sitemap.to_slice, dur_us: 210_000_i64)

hahwul_home = html.call("Home | HAHWUL",
  "<h1>HAHWUL</h1><p>Offensive Security Engineer, Developer and H4cker.</p>" \
  "<nav><a href=/posts/>Posts</a> <a href=/notes/>Notes</a> <a href=/projects/>Projects</a> <a href=/about/>About</a></nav>")
ids[:hahwul_home] = raw_flow(store, t.call(71), host: "www.hahwul.com", method: "GET", target: "/",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/"),
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_head: gh_resp_head.call(200, "OK", "text/html; charset=utf-8", hahwul_home.bytesize, "6a43cf55-3b80", "HIT"),
  resp_body: hahwul_home.to_slice, dur_us: 145_000_i64)

hahwul_css = <<-CSS
  /* =============================================================================
     Design Tokens
     Editorial · Monotone Dark · Pretendard-driven
     ============================================================================= */
  :root {
      --bg-primary: #0b0b0c;
      --bg-secondary: #131315;
      --bg-tertiary: #1c1c1f;
  }
  CSS
raw_flow(store, t.call(74), host: "www.hahwul.com", method: "GET", target: "/assets/css/01-reset.css?v=8e9d1251",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/assets/css/01-reset.css?v=8e9d1251"),
  status: 200, reason: "OK", ctype: "text/css; charset=utf-8",
  resp_head: gh_resp_head.call(200, "OK", "text/css; charset=utf-8", hahwul_css.bytesize, "6a43cf48-1573", "MISS"),
  resp_body: hahwul_css.to_slice, dur_us: 98_000_i64)

hahwul_posts = html.call("Posts | HAHWUL",
  "<h1>Posts</h1><ul>" \
  "<li><a href=/posts/2026/rust-and-crystal/>Rust and Crystal: My Two Main Languages</a></li>" \
  "<li><a href=/posts/2026/10years/>10 years</a></li>" \
  "<li><a href=/posts/2026/traveling-with-hermes-in-japan/>Traveling with Hermes in Japan</a></li>" \
  "</ul>")
raw_flow(store, t.call(77), host: "www.hahwul.com", method: "GET", target: "/posts/",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/posts/"),
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_head: gh_resp_head.call(200, "OK", "text/html; charset=utf-8", hahwul_posts.bytesize, "6a43cf52-3b64", "HIT"),
  resp_body: hahwul_posts.to_slice, dur_us: 132_000_i64)

hahwul_post = html.call("Rust and Crystal: My Two Main Languages | HAHWUL",
  "<h1>Rust and Crystal: My Two Main Languages</h1><p>Balancing Popularity and Quiet Power</p>")
raw_flow(store, t.call(80), host: "www.hahwul.com", method: "GET", target: "/posts/2026/rust-and-crystal/",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/posts/2026/rust-and-crystal/"),
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_head: gh_resp_head.call(200, "OK", "text/html; charset=utf-8", hahwul_post.bytesize, "6a43cf55-5069", "HIT"),
  resp_body: hahwul_post.to_slice, dur_us: 118_000_i64)

hahwul_note = html.call("Remove co-authored-by when committing | HAHWUL",
  "<h1>Remove co-authored-by when committing</h1>" \
  "<p>Claude Code에서 커밋 시 co-authored-by를 남기지 않도록 설정하는 방법</p>")
raw_flow(store, t.call(83), host: "www.hahwul.com", method: "GET", target: "/notes/claude-code/remove-co-authored-by/",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/notes/claude-code/remove-co-authored-by/"),
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_head: gh_resp_head.call(200, "OK", "text/html; charset=utf-8", hahwul_note.bytesize, "6a43cf57-3e94", "MISS"),
  resp_body: hahwul_note.to_slice, dur_us: 140_000_i64)

hahwul_about = html.call("About | HAHWUL",
  "<h1>About</h1><p>Offensive Security Engineer, Developer and H4cker.</p>")
raw_flow(store, t.call(86), host: "www.hahwul.com", method: "GET", target: "/about/",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/about/"),
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_head: gh_resp_head.call(200, "OK", "text/html; charset=utf-8", hahwul_about.bytesize, "6a43cf55-561b", "HIT"),
  resp_body: hahwul_about.to_slice, dur_us: 121_000_i64)

hahwul_404 = html.call("404 Not Found | HAHWUL",
  "<h1>404</h1><p>The page you are looking for does not exist.</p>")
raw_flow(store, t.call(89), host: "www.hahwul.com", method: "GET", target: "/this-page-does-not-exist",
  http: "HTTP/2", req_head: gh_req_head.call("GET", "/this-page-does-not-exist"),
  status: 404, reason: "Not Found", ctype: "text/html; charset=utf-8",
  resp_head: gh_resp_head.call(404, "Not Found", "text/html; charset=utf-8", hahwul_404.bytesize, "6a43cf47-36ef", "HIT"),
  resp_body: hahwul_404.to_slice, dur_us: 108_000_i64)

puts "• inserted 9 real, replayable flows against www.hahwul.com"

# --- Issues (a few planted vulns, linked to the flows above) ----------------
f1 = store.insert_issue("Reflected XSS in /search `q` parameter", S::Severity::High,
  "shop.demo.test", ids[:xss])
store.update_issue(f1, notes: "The `q` query parameter is reflected into the HTML " \
                              "response without output encoding.\n\nPoC: /search?q=<script>alert(1)</script>\n\n" \
                              "Impact: session theft via document.cookie (token is also exposed in the login JSON — see related issue).\n" \
                              "Fix: HTML-encode user input on output; add a CSP.", status: S::Status::Confirmed)

f2 = store.insert_issue("IDOR: /v1/users/{id} exposes other users' PII", S::Severity::High,
  "api.demo.test", ids[:idor])
store.update_issue(f2, notes: "A customer token (user_id=1) can read /v1/users/2 and " \
                              "receives Bob's email, role=admin and phone.\n\nNo object-level authorization check.\n" \
                              "Fix: verify the authenticated subject owns (or may access) the requested id.", status: S::Status::Confirmed)

f3 = store.insert_issue("Verbose 500 leaks stack trace & framework version", S::Severity::Medium,
  "api.demo.test", ids[:err500])
store.update_issue(f3, notes: "/v1/debug returns a full stack trace and 'DemoFramework 4.2.1' " \
                              "in the response body. Aids targeted exploitation.\nFix: disable debug error pages in production.")

f4 = store.insert_issue("Session token returned in JSON body", S::Severity::Low,
  "shop.demo.test", ids[:login])
store.update_issue(f4, notes: "POST /api/login returns the bearer token in the JSON body in " \
                              "addition to the Set-Cookie. JS-readable tokens are exfiltratable via the XSS above.\n" \
                              "Fix: keep the session in an HttpOnly, Secure cookie only.")

store.insert_issue("Inconsistent authz: /v1/orders 401 but /v1/cart open", S::Severity::Info,
  "api.demo.test", ids[:cart])

f6 = store.insert_issue("GraphQL introspection enabled in production", S::Severity::Medium,
  "api.demo.test", ids[:gql])
store.update_issue(f6, notes: "POST /graphql answers a full `__schema` introspection query for " \
                              "anonymous clients, exposing the entire type system (queries, mutations, types).\n\n" \
                              "Impact: accelerates API mapping and discovery of hidden/abusable mutations.\n" \
                              "Fix: disable introspection in production, or gate it behind authentication.")

f7 = store.insert_issue("Blind SSRF in /v1/import `url` (confirmed via OAST)", S::Severity::High,
  "api.demo.test", ids[:ssrf])
store.update_issue(f7, notes: "POST /v1/import fetches an operator-supplied URL server-side. The response " \
                              "is generic success, so it's blind — confirmed OUT OF BAND: the OAST tab received a " \
                              "DNS lookup then an HTTP GET from the server for a1b2c3d4.oast.demo.test.\n\n" \
                              "PoC: {\"url\":\"https://<your-oast-host>/hook\"}\n" \
                              "Impact: reach internal services / cloud metadata (169.254.169.254).\n" \
                              "Fix: allowlist destination hosts; block link-local + private ranges.", status: S::Status::Confirmed)

f8 = store.insert_issue("JWT signed with a weak, guessable secret", S::Severity::High,
  "api.demo.test", ids[:login])
store.update_issue(f8, notes: "The HS256 session JWT is signed with the secret \"#{WEAK_SECRET}\".\n\n" \
                              "Reproduce in the JWT tab: send the login token there (Space → send selection to JWT), " \
                              "run the weak-secret attack — it recovers the key — then re-sign a forged {\"role\":\"admin\"} " \
                              "payload, or try the alg:none attack.\n" \
                              "Fix: use a long random secret (or RS256 with a rotated keypair).")

puts "• inserted 8 issues"

# --- Workbench sessions (Repeater / Fuzzer / Miner) -------------------------
# Pre-seed sub-tabs so entity links have repeater/fuzz/miner targets to jump to.
xss_req = replay_req("GET", "shop.demo.test",
  "/search?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")
ids[:repeater_xss] = store.insert_repeater("https://shop.demo.test", xss_req.to_slice,
  false, true, ids[:xss], 0)
store.set_repeater_name(ids[:repeater_xss], "XSS PoC")

idor_req = replay_req("GET", "api.demo.test", "/v1/users/2",
  {"Authorization" => "Bearer #{jwt}"})
ids[:repeater_idor] = store.insert_repeater("https://api.demo.test", idor_req.to_slice,
  false, true, ids[:idor], 1)
store.set_repeater_name(ids[:repeater_idor], "IDOR probe")

ssrf_req = replay_req("POST", "api.demo.test", "/v1/import",
  {"Authorization" => "Bearer #{jwt}", "Content-Type" => "application/json"},
  %({"url":"https://a1b2c3d4.oast.demo.test/hook?from=api.demo.test"}))
ids[:repeater_ssrf] = store.insert_repeater("https://api.demo.test", ssrf_req.to_slice,
  false, true, ids[:ssrf], 2)
store.set_repeater_name(ids[:repeater_ssrf], "SSRF → OAST")

hahwul_req = "GET / HTTP/2\r\nhost: www.hahwul.com\r\naccept: text/html\r\n\r\n"
ids[:repeater_hahwul] = store.insert_repeater("https://www.hahwul.com", hahwul_req.to_slice,
  true, true, ids[:hahwul_home], 3)
store.set_repeater_name(ids[:repeater_hahwul], "hahwul home")

fuzz_template = replay_req("GET", "api.demo.test", "/v1/users/§1§",
  {"Authorization" => "Bearer #{jwt}"})
ids[:fuzz_users] = store.insert_fuzz_session("https://api.demo.test", fuzz_template,
  false, nil, %({"mode":"sniper","sets":[{"kind":"numbers","value":"1-10"}]}),
  ids[:idor], 0, "user id enum")

miner_req = replay_req("GET", "api.demo.test", "/v1/users/1",
  {"Authorization" => "Bearer #{jwt}"}).to_slice
ids[:miner_users] = store.insert_miner_session("https://api.demo.test", miner_req,
  false, nil,
  %({"locations":["query"],"concurrency":4,"notify":"off","stability_rounds":2,"confirm_rounds":1,"buckets":{"query":50}}),
  ids[:idor], 0, "users path mine")

# Sequencer: analyze the randomness of the `sid` session cookie minted by /api/login.
# Collected tokens are never persisted — the session stores only the request + descriptor.
seq_req = replay_req("POST", "shop.demo.test", "/api/login",
  {"Content-Type" => "application/json"}, %({"username":"alice","password":"hunter2"})).to_slice
ids[:seq_sid] = store.insert_sequencer_session("https://shop.demo.test", seq_req,
  false, nil,
  %({"mode":"manual","kind":"cookie","selector":"sid","pos_start":0,"pos_end":0,"goal":500,"concurrency":4,"notify":"off"}),
  ids[:login], 0, "sid randomness")

puts "• inserted 4 repeater + 1 fuzz + 1 miner + 1 sequencer sessions"

# --- Rewriter (Match & Replace rules applied to in-flight traffic) -----------
# A few illustrative rules — the security-hardening two are ON; the rest are OFF so
# they don't silently alter traffic, but are one keystroke (toggle) from live so you
# can flip one on and re-send from Repeater to watch it take effect.
store.insert_rule(S::RuleTarget::Response, S::RulePart::Head, "X-Frame-Options", "DENY",
  op: S::RuleOp::AddHeader, name: "Add X-Frame-Options", enabled: true)
store.insert_rule(S::RuleTarget::Response, S::RulePart::Head, "Server", "",
  op: S::RuleOp::RemoveHeader, name: "Strip Server banner", enabled: true)
store.insert_rule(S::RuleTarget::Request, S::RulePart::Head, "Bearer [A-Za-z0-9._-]+", "Bearer «redacted»",
  op: S::RuleOp::Replace, match_kind: S::MatchKind::Regex, name: "Redact bearer token (regex)", enabled: false)
store.insert_rule(S::RuleTarget::Response, S::RulePart::Body,
  "Welcome to Demo Shop", "Welcome to Demo Shop [rewritten by gori]",
  op: S::RuleOp::Replace, match_kind: S::MatchKind::Literal,
  name: "Brand tag (body-rewrite proof)", host: "shop.demo.test", enabled: false)
puts "• inserted 4 rewriter rules (2 active, 2 staged)"

# --- OAST (out-of-band listener) — provider + session + received callbacks ---
# Seeded to prove the SSRF above out of band. Polling never auto-resumes (see the
# OAST controller), so these are inert historical rows: the tab opens showing the
# two callbacks the server made when it fetched our payload host.
oast_provider = store.insert_oast_provider("Demo OAST (oast.demo.test)",
  Oast::ProviderKind::CustomHttp.label, "https://oast.demo.test", nil, true, 0)
oast_session = store.insert_oast_session(oast_provider,
  Oast::ProviderKind::CustomHttp.label, "https://oast.demo.test",
  "demo7a3f9c2b41d", "s3cr3t-demo-oast", nil, nil)

oast_dns_req = "a1b2c3d4.oast.demo.test.  IN  A\n; recursive lookup from 203.0.113.10 (api.demo.test egress)\n"
store.insert_oast_callback(oast_session, "cb-dns-0001", "dns", nil, "203.0.113.10",
  "a1b2c3d4.oast.demo.test", oast_dns_req.to_slice, nil, t.call(43))

oast_http_req = String.build do |b|
  b << "GET /hook?from=api.demo.test HTTP/1.1\r\n"
  b << "Host: a1b2c3d4.oast.demo.test\r\n"
  b << "User-Agent: DemoFramework/4.2.1 (url-import)\r\n"
  b << "Accept: */*\r\n\r\n"
end
oast_http_resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
store.insert_oast_callback(oast_session, "cb-http-0002", "http", "GET", "203.0.113.10",
  "a1b2c3d4.oast.demo.test", oast_http_req.to_slice, oast_http_resp.to_slice, t.call(43) + 900_000_i64)
store.flush
puts "• inserted OAST provider + session + 2 callbacks (dns, http)"

# --- Hostname overrides (per-project /etc/hosts) ----------------------------
# The fictional .test hosts resolve to loopback (they don't exist in real DNS); this
# documents that and shows the override feature. www.hahwul.com is left untouched so
# its flows stay genuinely replayable.
store.add_host_override("shop.demo.test", "127.0.0.1")
store.add_host_override("api.demo.test", "127.0.0.1")
store.add_host_override("cdn.demo.test", "127.0.0.1")

# --- Sitemap tags (persisted per (host, path)) ------------------------------
store.set_sitemap_tag("shop.demo.test", "/search", "xss")
store.set_sitemap_tag("shop.demo.test", "/admin", "authz")
store.set_sitemap_tag("api.demo.test", "/v1/debug", "leak")
store.set_sitemap_tag("api.demo.test", "/v1/import", "ssrf")
store.set_sitemap_tag("api.demo.test", "/graphql", "introspection")

# --- Probe custom rule (project-scoped) — folded into the passive scan below --
store.insert_probe_custom_rule("Framework version banner",
  "Detects the DemoFramework version string leaked in response bodies.",
  "response", "body", "regex", "DemoFramework \\d+\\.\\d+\\.\\d+", S::Severity::Low)
puts "• inserted 3 host overrides + 5 sitemap tags + 1 custom probe rule"

# --- Entity links (issues + notes → history / repeater / fuzz / miner) ------
# insert_issue already auto-links the primary flow_id; add cross-workbench refs.
store.add_link(S::LinkOwnerKind::Issue, f1, S::LinkRefKind::Repeater, ids[:repeater_xss])
store.add_link(S::LinkOwnerKind::Issue, f1, S::LinkRefKind::Fuzz, ids[:fuzz_users])
store.add_link(S::LinkOwnerKind::Issue, f1, S::LinkRefKind::Flow, ids[:login])

store.add_link(S::LinkOwnerKind::Issue, f2, S::LinkRefKind::Repeater, ids[:repeater_idor])
store.add_link(S::LinkOwnerKind::Issue, f2, S::LinkRefKind::Fuzz, ids[:fuzz_users])
store.add_link(S::LinkOwnerKind::Issue, f2, S::LinkRefKind::Miner, ids[:miner_users])

store.add_link(S::LinkOwnerKind::Issue, f4, S::LinkRefKind::Repeater, ids[:repeater_xss])

store.add_link(S::LinkOwnerKind::Issue, f6, S::LinkRefKind::Flow, ws_id)

store.add_link(S::LinkOwnerKind::Issue, f7, S::LinkRefKind::Repeater, ids[:repeater_ssrf])
store.add_link(S::LinkOwnerKind::Issue, f7, S::LinkRefKind::Flow, ids[:ssrf])

NOTE_MAIN  = 1_i64 # stable note id (entity_links.owner_id)
NOTE_LINKS = 2_i64

store.add_link(S::LinkOwnerKind::Note, NOTE_MAIN, S::LinkRefKind::Repeater, ids[:repeater_xss])
store.add_link(S::LinkOwnerKind::Note, NOTE_MAIN, S::LinkRefKind::Fuzz, ids[:fuzz_users])
store.add_link(S::LinkOwnerKind::Note, NOTE_MAIN, S::LinkRefKind::Flow, ids[:cart])

store.add_link(S::LinkOwnerKind::Note, NOTE_LINKS, S::LinkRefKind::Repeater, ids[:repeater_idor])
store.add_link(S::LinkOwnerKind::Note, NOTE_LINKS, S::LinkRefKind::Miner, ids[:miner_users])
store.add_link(S::LinkOwnerKind::Note, NOTE_LINKS, S::LinkRefKind::Flow, ws_id)
store.add_link(S::LinkOwnerKind::Note, NOTE_LINKS, S::LinkRefKind::Repeater, ids[:repeater_hahwul])

puts "• inserted entity links on issues + notes"

# --- Notes doc (multi-tab, stable ids for entity_links) --------------------
NOTE_TOOLS = 3_i64

note_main = <<-NOTES
# Demo engagement — recon notes

## Hosts
- shop.demo.test  — storefront (HTML)
- api.demo.test   — JSON API (/v1)
- cdn.demo.test   — static assets
- www.hahwul.com  — REAL, live site (replayable)

## Auth
- POST /api/login -> bearer token (ALSO leaked in JSON body, not just cookie)
- token used as `Authorization: Bearer ...` on /v1/*
- the token is a real HS256 JWT — weakly signed (see the JWT lead below)

## Leads
- [x] reflected XSS on /search?q=
- [x] IDOR on /v1/users/{id}  (customer token reads admin's PII)
- [x] blind SSRF on POST /v1/import  (confirmed out-of-band, see OAST tab)
- [x] JWT signed with a guessable secret  (crack + re-forge in the JWT tab)
- [x] verbose 500 on /v1/debug
- [ ] check /admin (403) for auth bypass / header tricks
- [ ] enumerate /v1/users/{id} range (Fuzzer session "user id enum" is staged)

## Protocols on this target
- **WebSocket** GET /ws/chat (101) — open it and switch to the MESSAGES pane (→ sent, ← received).
- **gRPC** POST /demo.Greeter/SayHello (HTTP/2) — FRAMES pane shows the raw h2 frame log;
  the application/grpc body deframes into length-prefixed protobuf messages (hex — opaque without the .proto).
- **SSE** GET /v1/stream/prices (text/event-stream) — captured as one streamed body, not split per event.
- **GraphQL** POST /graphql — plain JSON (query / mutation / introspection). Introspection is ON (see Issues).
- **SAML** POST /saml/acs — SAMLResponse is url-encoded base64 XML.
  Decode in the Decoder tab: url-decode → base64-decode (→ XML assertion for alice@demo.test).

## Live target (real, replayable)
- **www.hahwul.com** is a real, live site (unlike the shop/api hosts above) — every
  captured flow is a genuine response, so Repeater (^R) actually re-sends it over the
  network and gets a live response back. Good for trying Repeater/Diff/Probe against
  real traffic instead of only synthetic data.
- Recon flow: /robots.txt -> /sitemap.xml -> / -> a css asset -> /posts/ -> an
  article -> a note -> /about/, plus one guessed path that 404s.

## Entity links
- **Issue detail** → Space → `l` opens the links overlay; `↵` opens the selected ref
  (`↑/↓`·`j/k` navigate the RELATED list). The RELATED pane lists cross-links
  (repeater/fuzz/miner/history) beyond the primary evidence flow.
- **Notes sub-tab** → Space → `l` opens links for the active note (preview strip at the bottom).
- **History / Repeater / Fuzzer / Miner** → Space → `k` link to an issue, `u` link to a note.
- This demo project already has links seeded — try the XSS or SSRF issue, or switch to the
  "Workbench cross-links" note sub-tab.
NOTES

note_links = <<-NOTES2
# Workbench cross-links

Pointers to the repeater/fuzz/miner/sequencer sessions tied to this engagement.
Space → `l` (links) on this sub-tab opens the overlay; `↵`/`o` jumps to the linked session or flow.

- **XSS PoC** repeater — re-send the reflected /search payload
- **IDOR probe** repeater — GET /v1/users/2 with the customer token
- **SSRF → OAST** repeater — POST /v1/import with an OAST payload host
- **user id enum** fuzz — sweep /v1/users/{id} (positions marked §1§)
- **users path mine** — hidden-parameter probe on /v1/users/
- **sid randomness** sequencer — grade the /api/login session-cookie entropy
- **WebSocket chat** flow — MESSAGES pane for the 101 upgrade
- **hahwul home** repeater — live, replayable traffic against www.hahwul.com
NOTES2

note_tools = <<-NOTES3
# Tooling cheatsheet

Which tab does what on this demo (send a selection to a tool with Space → the tool's key).

- **Rewriter** — 4 match&replace rules are seeded. Two are ON (add `X-Frame-Options`,
  strip the `Server` banner); two are staged OFF (redact `Bearer …` via regex; a
  body-rewrite proof on shop.demo.test). Toggle one on, then re-send from Repeater.
- **OAST** — the out-of-band listener. It holds the DNS + HTTP callbacks the server made
  when it fetched our payload host (proof of the blind SSRF). Polling is paused on load.
- **Sequencer** — the "sid randomness" session re-collects the login cookie and grades
  its entropy (collected tokens are never persisted).
- **JWT** — send the login token here: decode the claims, run the weak-secret attack
  (it recovers the key), then re-forge `{"role":"admin"}` or try alg:none.
- **Decoder** — chain encoders/decoders. Try the SAMLResponse (url-decode → base64-decode)
  or the JWT (base64url-decode each segment).
- **Comparer** — diff two flows side by side (e.g. /v1/users/1 vs /v1/users/2 for the IDOR).
- **Probe** — passive scan results (incl. a project custom rule catching the DemoFramework
  banner). Mode is Passive; active probing needs live traffic.
- **Target** — Sitemap (a few paths tagged: xss / authz / leak / ssrf / introspection) + Discover.
- **Settings → network** — 3 hostname overrides point the fictional .test hosts at loopback.
NOTES3

store.set_setting(Notes::DOCS_KEY, Notes.serialize(0, [
  Notes::NoteEntry.new(NOTE_MAIN, note_main),
  Notes::NoteEntry.new(NOTE_LINKS, note_links),
  Notes::NoteEntry.new(NOTE_TOOLS, note_tools),
], 4_i64))

# --- Scope (seed patterns, left OFF so History shows everything) ------------
store.add_scope_rule("include", "host", "shop.demo.test")
store.add_scope_rule("include", "host", "api.demo.test")
store.add_scope_rule("include", "host", "www.hahwul.com")

# --- Probe passive scan: run the analyzer (built-ins + this project's custom rule) over
# every seeded flow so the Probe tab opens populated (and the Project tab shows the
# detected technologies). This mirrors what the live Probe::Analyzer does on captured
# traffic — no extra requests. MODE is left at the safe default (Passive); active
# reflected-param probing needs live traffic.
custom_rules = Probe.custom_rules(store)
store.recent_flows(1000).each do |row|
  if detail = store.get_flow(row.id)
    Probe::Passive.analyze(detail, custom: custom_rules).each { |d| store.upsert_probe_issue(d) }
  end
end
store.set_probe_mode(Probe::Mode::Passive)
puts "• probe: #{store.count_probe_issues} passive issues; tech=#{store.probe_tech_summary.join(", ")}"

store.close
puts "• notes (3 tabs, stable ids) + 3 scope patterns written"
puts "\n✓ demo project ready — launch ./bin/gori and pick 'demo'."
puts "  Try: SSRF issue → OAST tab; JWT lead → JWT tab (weak-secret attack); Notes → 'Tooling cheatsheet'."
