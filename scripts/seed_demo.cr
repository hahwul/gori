# Seeds a "demo" registry project with a realistic, varied dataset so the TUI
# (History / Sitemap / Findings / Notes / Scope) has something to explore.
#
#   crystal run scripts/seed_demo.cr
#
# Re-runnable: it wipes any existing "demo" project first, then recreates it.
require "file_utils"
require "base64"
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

Paths.ensure_dirs
registry = ProjectRegistry.new(Paths.projects_dir)

# Fresh start: drop any existing "demo" project.
if existing = registry.list.find { |p| p.name == "demo" }
  registry.delete(existing)
  puts "• removed existing demo project"
end

project = registry.create("demo",
  "Demo target for exploring gori's TUI — a fictional shop + JSON API. " \
  "Captured browsing of shop.demo.test / api.demo.test / cdn.demo.test with a few planted findings.")
store = S.open(project.db_path)
puts "• created project 'demo' at #{project.db_path}"

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
  resp_body: %({"ok":true,"token":"eyJhbGciOiJIUzI1NiJ9.demo.token","user_id":1}))

add_flow(store, t.call(9), host: "api.demo.test", target: "/v1/products",
  req_headers: {"Authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.demo.token"},
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %([{"id":42,"name":"Blue Widget","price":1999},{"id":43,"name":"Red Widget","price":2499}]))

add_flow(store, t.call(11), host: "api.demo.test", target: "/v1/products/42",
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"id":42,"name":"Blue Widget","price":1999,"stock":17,"sku":"BW-0042"}))

add_flow(store, t.call(13), host: "api.demo.test", target: "/v1/cart", method: "POST",
  req_headers: {"Authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.demo.token"},
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
  req_headers: {"Authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.demo.token"},
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"id":1,"name":"Alice","email":"alice@demo.test","role":"customer"}))

# IDOR candidate: same token reads another user's record.
ids[:idor] = add_flow(store, t.call(33), host: "api.demo.test", target: "/v1/users/2",
  req_headers: {"Authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.demo.token"},
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"id":2,"name":"Bob","email":"bob@demo.test","role":"admin","phone":"+1-555-0102"}))

add_flow(store, t.call(36), host: "api.demo.test", target: "/v1/profile", method: "PUT",
  req_headers: {"Authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.demo.token"},
  req_body: %({"name":"Alice A.","newsletter":true}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"id":1,"name":"Alice A.","newsletter":true}))

add_flow(store, t.call(38), host: "api.demo.test", target: "/v1/cart/9", method: "DELETE",
  req_headers: {"Authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.demo.token"},
  status: 204, reason: "No Content")

add_flow(store, t.call(41), host: "shop.demo.test", target: "/missing-page",
  status: 404, reason: "Not Found", ctype: "text/html; charset=utf-8",
  resp_body: html.call("Not Found", "<h1>404</h1>"))

# Verbose 500 leaks a stack trace + framework version.
ids[:err500] = add_flow(store, t.call(44), host: "api.demo.test", target: "/v1/debug",
  status: 500, reason: "Internal Server Error", ctype: "text/html; charset=utf-8",
  resp_body: "<h1>RuntimeError at /v1/debug</h1><pre>NoMethodError: undefined method 'each' for nil\n  app/controllers/debug_controller.rb:14\n  rack (3.0.8) lib/rack/handler.rb:88\nDemoFramework 4.2.1</pre>")

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
ws_id = raw_flow(store, t.call(48), host: "api.demo.test", method: "GET", target: "/ws/chat",
  req_head: ws_req, status: 101, reason: "Switching Protocols",
  resp_head: ws_resp, dur_us: 1_200_000_i64)

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
store.insert_h2_frame(greeter_conn, "out", 0x0_u8, 0x1_u8, 1_u32, req_msg)                    # DATA END_STREAM
store.insert_h2_frame(greeter_conn, "in", 0x1_u8, 0x4_u8, 1_u32,
  Bytes[0x88, 0x5f, 0x10, 0x61, 0x70, 0x70, 0x6c, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6f, 0x6e]) # HEADERS
store.insert_h2_frame(greeter_conn, "in", 0x0_u8, 0x0_u8, 1_u32, resp_msg)                    # DATA
store.insert_h2_frame(greeter_conn, "in", 0x1_u8, 0x5_u8, 1_u32,
  Bytes[0x40, 0x0b, 0x67, 0x72, 0x70, 0x63, 0x2d, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x01, 0x30]) # trailers grpc-status:0
store.flush # fire-and-forget frames committed before any close

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
  req_headers: {"Authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.demo.token"},
  req_body: %({"operationName":"GetProducts","query":"query GetProducts($first: Int!) { products(first: $first) { id name price } }","variables":{"first":2}}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"data":{"products":[{"id":"42","name":"Blue Widget","price":1999},{"id":"43","name":"Red Widget","price":2499}]}}))

add_flow(store, t.call(58), host: "api.demo.test", target: "/graphql", method: "POST",
  req_headers: {"Authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.demo.token"},
  req_body: %({"operationName":"AddToCart","query":"mutation AddToCart($id: ID!, $qty: Int!) { addToCart(productId: $id, qty: $qty) { cartId total } }","variables":{"id":"42","qty":2}}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"data":{"addToCart":{"cartId":"9","total":3998}}}))

ids[:gql] = add_flow(store, t.call(60), host: "api.demo.test", target: "/graphql", method: "POST",
  req_body: %({"query":"query IntrospectionQuery { __schema { queryType { name } types { name kind } } }"}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"data":{"__schema":{"queryType":{"name":"Query"},"types":[{"name":"Query","kind":"OBJECT"},{"name":"Product","kind":"OBJECT"},{"name":"User","kind":"OBJECT"},{"name":"Mutation","kind":"OBJECT"},{"name":"CartItem","kind":"OBJECT"}]}}}))

# SAML: an SP-initiated SSO assertion POSTed to the ACS. The SAMLResponse is a
# url-encoded base64 XML blob — decode it in the Convert tab: url-decode → base64-decode.
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

# --- Findings (a few planted vulns, linked to the flows above) -------------
f1 = store.insert_finding("Reflected XSS in /search `q` parameter", S::Severity::High,
  "shop.demo.test", ids[:xss])
store.update_finding(f1, notes: "The `q` query parameter is reflected into the HTML " \
  "response without output encoding.\n\nPoC: /search?q=<script>alert(1)</script>\n\n" \
  "Impact: session theft via document.cookie (token is also exposed in the login JSON — see related finding).\n" \
  "Fix: HTML-encode user input on output; add a CSP.")

f2 = store.insert_finding("IDOR: /v1/users/{id} exposes other users' PII", S::Severity::High,
  "api.demo.test", ids[:idor])
store.update_finding(f2, notes: "A customer token (user_id=1) can read /v1/users/2 and " \
  "receives Bob's email, role=admin and phone.\n\nNo object-level authorization check.\n" \
  "Fix: verify the authenticated subject owns (or may access) the requested id.")

f3 = store.insert_finding("Verbose 500 leaks stack trace & framework version", S::Severity::Medium,
  "api.demo.test", ids[:err500])
store.update_finding(f3, notes: "/v1/debug returns a full stack trace and 'DemoFramework 4.2.1' " \
  "in the response body. Aids targeted exploitation.\nFix: disable debug error pages in production.")

f4 = store.insert_finding("Session token returned in JSON body", S::Severity::Low,
  "shop.demo.test", ids[:login])
store.update_finding(f4, notes: "POST /api/login returns the bearer token in the JSON body in " \
  "addition to the Set-Cookie. JS-readable tokens are exfiltratable via the XSS above.\n" \
  "Fix: keep the session in an HttpOnly, Secure cookie only.")

store.insert_finding("Inconsistent authz: /v1/orders 401 but /v1/cart open", S::Severity::Info,
  "api.demo.test", ids[:cart])

f6 = store.insert_finding("GraphQL introspection enabled in production", S::Severity::Medium,
  "api.demo.test", ids[:gql])
store.update_finding(f6, notes: "POST /graphql answers a full `__schema` introspection query for " \
  "anonymous clients, exposing the entire type system (queries, mutations, types).\n\n" \
  "Impact: accelerates API mapping and discovery of hidden/abusable mutations.\n" \
  "Fix: disable introspection in production, or gate it behind authentication.")

puts "• inserted 6 findings"

# --- Notes doc -------------------------------------------------------------
store.set_setting("notes", <<-NOTES)
# Demo engagement — recon notes

## Hosts
- shop.demo.test  — storefront (HTML)
- api.demo.test   — JSON API (/v1)
- cdn.demo.test   — static assets

## Auth
- POST /api/login -> bearer token (ALSO leaked in JSON body, not just cookie)
- token used as `Authorization: Bearer ...` on /v1/*

## Leads
- [x] reflected XSS on /search?q=
- [x] IDOR on /v1/users/{id}  (customer token reads admin's PII)
- [x] verbose 500 on /v1/debug
- [ ] check /admin (403) for auth bypass / header tricks
- [ ] enumerate /v1/users/{id} range

## Protocols on this target
- **WebSocket** GET /ws/chat (101) — open it and switch to the MESSAGES pane (→ sent, ← received).
- **gRPC** POST /demo.Greeter/SayHello (HTTP/2) — FRAMES pane shows the raw h2 frame log;
  the application/grpc body deframes into length-prefixed protobuf messages (hex — opaque without the .proto).
- **SSE** GET /v1/stream/prices (text/event-stream) — captured as one streamed body, not split per event.
- **GraphQL** POST /graphql — plain JSON (query / mutation / introspection). Introspection is ON (see findings).
- **SAML** POST /saml/acs — SAMLResponse is url-encoded base64 XML.
  Decode in the Convert tab: url-decode → base64-decode (→ XML assertion for alice@demo.test).

## Notes
Token is the same JWT across requests — replayable in Replay (^R).
NOTES

# --- Scope (seed patterns, left OFF so History shows everything) ------------
store.add_scope_rule("include", "host", "shop.demo.test")
store.add_scope_rule("include", "host", "api.demo.test")

store.close
puts "• notes + 2 scope patterns written"
puts "\n✓ demo project ready — launch ./bin/gori and pick 'demo'."
