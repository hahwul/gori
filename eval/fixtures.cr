# Builds the eval fixture databases and their answer keys:
#
#   crystal run eval/fixtures.cr        (or `just eval-fixtures`)
#
# Each fixture is a plain gori database under eval/out/fixtures/, served to the agent with
# `gori mcp --db`. The answer key is written by the same code that inserts the flows, so a
# task's expected answer is whatever id the store actually handed back — never a number
# typed into a task file that drifts when a flow is added above it.
require "file_utils"
require "json"
require "../src/gori"

include Gori

alias S = Gori::Store

OUT = File.join(__DIR__, "out", "fixtures")

def add_flow(store : S, at : Int64, *, host : String, target : String, method = "GET",
             status = 200, ctype = "application/json", body = "{}",
             resp_headers = [] of {String, String}) : Int64
  req_head = "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\nUser-Agent: eval/1.0\r\nAccept: */*\r\n\r\n"
  fid = store.insert_flow(S::CapturedRequest.new(
    created_at: at, scheme: "https", host: host, port: 443, method: method, target: target,
    http_version: "HTTP/1.1", head: req_head.to_slice, body: nil, body_size: nil,
    source: FlowSource::Kind::Proxy))
  resp_head = String.build do |b|
    b << "HTTP/1.1 " << status << " OK\r\n"
    b << "Content-Type: " << ctype << "\r\n"
    b << "Content-Length: " << body.bytesize << "\r\n"
    resp_headers.each { |(k, v)| b << k << ": " << v << "\r\n" }
    b << "\r\n"
  end
  store.update_response(S::CapturedResponse.new(
    flow_id: fid, status: status, reason: "OK", content_type: ctype,
    head: resp_head.to_slice, body: body.to_slice, body_size: body.bytesize.to_i64,
    ttfb_us: 10_000_i64, duration_us: 20_000_i64, state: S::FlowState::Complete))
  fid
end

# A small storefront: ~110 flows. The facts the tasks ask about are planted among
# ordinary browsing so a lazy read of the first page gets them wrong.
def build_shop(path : String) : Hash(String, JSON::Any)
  store = S.open(path)
  t = 1_780_000_000_000_000_i64
  tick = -> { t += 1_000_000_i64 }
  api = "api.shop.test"
  orders = [] of Int64
  no_httponly = [] of Int64

  # t1-pagination-count: 70 order reads spread across the whole capture, so a newest-first
  # page of 50 (list_history's default) holds only some of them and says has_more.
  70.times do |i|
    orders << add_flow(store, tick.call, host: api, target: "/api/v1/orders/#{1000 + i}",
      body: %({"id":#{1000 + i},"status":"shipped"}))
    add_flow(store, tick.call, host: "cdn.shop.test", target: "/assets/img/p#{i}.webp",
      ctype: "image/webp", body: "RIFF") if i.even?
  end

  # t0-cookie-httponly: which responses set a cookie WITHOUT HttpOnly. The traps are a
  # lowercase `httponly` (has it), a response with two Set-Cookie lines where only one is
  # flagged (counts), and a request that merely SENDS a cookie (does not count).
  add_flow(store, tick.call, host: "shop.test", target: "/auth/login", method: "POST",
    resp_headers: [{"Set-Cookie", "session=9f2c; Path=/; Secure; HttpOnly; SameSite=Lax"}])
  no_httponly << add_flow(store, tick.call, host: "shop.test", target: "/",
    ctype: "text/html", body: "<html>home</html>",
    resp_headers: [{"Set-Cookie", "tracking_id=u-51; Path=/; Max-Age=31536000"}])
  no_httponly << add_flow(store, tick.call, host: api, target: "/api/v1/cart",
    resp_headers: [{"Set-Cookie", "cart=c-77; Path=/; Secure"}])
  add_flow(store, tick.call, host: "shop.test", target: "/prefs",
    resp_headers: [{"Set-Cookie", "theme=dark; Path=/; httponly"}])
  no_httponly << add_flow(store, tick.call, host: "shop.test", target: "/locale",
    resp_headers: [{"Set-Cookie", "lang_sig=a1; Path=/; HttpOnly"}, {"Set-Cookie", "lang=ko; Path=/"}])

  # t0-deep-body: the answer sits ~100 KB into one response, past get_flow's default inline
  # cut and past body_mode:"full"'s 64 KB too.
  features = (1..1500).map { |i| %({"key":"feature_#{i}","enabled":#{i.odd?}}) }.join(',')
  config = add_flow(store, tick.call, host: api, target: "/api/v1/config",
    body: %({"features":[#{features}],"build_id":"b-7f3a91c2e4"}))

  20.times do |i|
    add_flow(store, tick.call, host: api, target: "/api/v1/products?page=#{i + 1}",
      body: %({"items":[],"page":#{i + 1}}))
  end

  store.close
  {
    "t0-cookie-httponly"  => JSON::Any.new(no_httponly.map { |id| JSON::Any.new(id) }),
    "t0-deep-body"        => JSON::Any.new("b-7f3a91c2e4"),
    "t1-pagination-count" => JSON::Any.new(orders.size.to_i64),
    "_config_flow"        => JSON::Any.new(config),
  }
end

# A telemetry-heavy capture (~700 flows) for the traps the shop's 110 flows cannot set:
# more matches than one list_history page can hold, a shape outlier no QL field names,
# and a host search whose substring match returns the wrong hosts.
def build_events(path : String) : Hash(String, JSON::Any)
  store = S.open(path)
  t = 1_780_000_000_000_000_i64
  tick = -> { t += 1_000_000_i64 }
  api = "api.shop.test"

  # t1-deep-paging: 620 matches, past list_history's 500-row maximum, so one call cannot
  # see them all and an answer of 500 means has_more was ignored.
  events = Array.new(620) do |i|
    add_flow(store, tick.call, host: "telemetry.shop.test", target: "/v1/events/#{i}",
      method: "POST", status: 204, body: "")
  end

  # t0-shape-outlier: forty profile reads whose bodies differ only in their values, and one
  # with two extra fields — a few hundred bytes larger, not an obvious size outlier.
  outlier = 0_i64
  40.times do |i|
    extra = i == 27 ? %(,"legacy_role":"support","flags":["beta_ui","export"]) : ""
    id = add_flow(store, tick.call, host: api, target: "/api/v1/profile",
      body: %({"id":#{200 + i},"name":"user#{200 + i}","plan":"#{i.even? ? "free" : "pro"}"#{extra}}))
    outlier = id if i == 27
  end

  # t1-host-near-miss: no flow went to admin.shop.test itself; `host:admin.shop.test` is a
  # substring match and returns these instead.
  %w[static.admin.shop.test admin.shop.test.cdn.test].each do |h|
    3.times { |i| add_flow(store, tick.call, host: h, target: "/a#{i}.js", ctype: "text/javascript", body: "0") }
  end

  store.close
  {
    "t1-deep-paging"    => JSON::Any.new(events.size.to_i64),
    "t0-shape-outlier"  => JSON::Any.new([JSON::Any.new(outlier)]),
    "t1-host-near-miss" => JSON::Any.new([] of JSON::Any),
  }
end

FileUtils.mkdir_p(OUT)
{"shop" => ->build_shop(String), "events" => ->build_events(String)}.each do |name, build|
  db = File.join(OUT, "#{name}.db")
  Dir.glob("#{db}*").each { |f| File.delete(f) }
  truth = build.call(db)
  File.write(File.join(OUT, "#{name}.truth.json"), truth.to_pretty_json)
  puts "• #{name}: #{db}"
end
