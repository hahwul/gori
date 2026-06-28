require "./spec_helper"

private def tmp_store(&)
  path = File.tempname("gori-ql", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def capture(store, host, method, target, status = nil)
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice))
  end
  id
end

describe Gori::QL do
  it "compiles AND-ed terms with parameterised values" do
    f = Gori::QL.parse("host:acme status:>=500")
    f.sql.should eq("(lower(host) LIKE ? ESCAPE '\\' AND status >= ?)")
    f.args.should eq(["%acme%", 500])
  end

  it "compiles a status class to a range" do
    f = Gori::QL.parse("status:4xx")
    f.sql.should eq("((status >= ? AND status < ?))") # clause-wrap around the range term
    f.args.should eq([400, 500])
  end

  it "honours a comparison operator against a status class" do
    Gori::QL.parse("status:>=5xx").sql.should eq("(status >= ?)")
    Gori::QL.parse("status:>=5xx").args.should eq([500])
    Gori::QL.parse("status:<4xx").args.should eq([400])  # below the class floor
    Gori::QL.parse("status:>4xx").args.should eq([500])  # strictly above the 4xx class
    Gori::QL.parse("status:<=4xx").args.should eq([500]) # at or below the class (status < 500)
  end

  it "escapes LIKE metacharacters so % and _ match literally" do
    f = Gori::QL.parse("host:ac%e_")
    f.sql.should eq("(lower(host) LIKE ? ESCAPE '\\')")
    f.args.should eq(["%ac\\%e\\_%"]) # the user's % and _ are backslash-escaped
  end

  it "compiles OR groups and negation" do
    f = Gori::QL.parse("method:get OR -host:cdn")
    f.sql.should eq("(upper(method) = ?) OR (NOT (lower(host) LIKE ? ESCAPE '\\'))")
    f.args.should eq(["GET", "%cdn%"])
  end

  it "treats bare words as free text over method/host/path" do
    f = Gori::QL.parse("login")
    f.args.should eq(["%login%", "%login%", "%login%"])
  end

  it "matches everything for an empty query" do
    Gori::QL.parse("   ").sql.should eq("1")
  end

  it "compiles a body: term to an FTS substring (quoted-phrase) match" do
    f = Gori::QL.parse("body:token")
    f.sql.should eq("(id IN (SELECT rowid FROM flows_fts WHERE flows_fts MATCH ?))")
    f.args.should eq([%("token")])
  end

  it "strips control/NUL chars from a body: value (FTS phrase safety)" do
    f = Gori::QL.parse("body:to\u0000ke\u001fn")
    f.args.should eq([%("token")]) # control bytes removed before the phrase is built
  end

  it "falls back to a NULL-safe blob scan for a body: value below the 3-char trigram floor" do
    f = Gori::QL.parse("body:ab")
    f.sql.should eq("(((request_body IS NOT NULL AND lower(CAST(request_body AS TEXT)) LIKE ? ESCAPE '\\') " \
                    "OR (response_body IS NOT NULL AND lower(CAST(response_body AS TEXT)) LIKE ? ESCAPE '\\')))")
    f.args.should eq(["%ab%", "%ab%"])
  end

  it "compiles size: as a comparison on the TOTAL (req+resp), matching the displayed size" do
    f = Gori::QL.parse("size:>1000")
    f.sql.should eq("((request_size + COALESCE(response_size, 0)) > ?)")
    f.args.should eq([1000_i64])
    Gori::QL.parse("size:<=500").sql.should eq("((request_size + COALESCE(response_size, 0)) <= ?)")
    Gori::QL.parse("size:0").sql.should eq("((request_size + COALESCE(response_size, 0)) = ?)") # bare → equality
  end

  it "compiles reqsize: / respsize: against a single side" do
    Gori::QL.parse("reqsize:>1000").sql.should eq("(request_size > ?)")
    Gori::QL.parse("respsize:<500").sql.should eq("(response_size < ?)")
  end

  it "compiles dur: as milliseconds against duration_us, honouring ms/s suffixes" do
    Gori::QL.parse("dur:>500").sql.should eq("(duration_us > ?)")
    Gori::QL.parse("dur:>500").args.should eq([500_000_i64]) # bare magnitude = ms
    Gori::QL.parse("dur:>500ms").args.should eq([500_000_i64])
    Gori::QL.parse("dur:>2s").args.should eq([2_000_000_i64])
    Gori::QL.parse("dur:<=1.5s").sql.should eq("(duration_us <= ?)")
    Gori::QL.parse("dur:<=1.5s").args.should eq([1_500_000_i64]) # fractional seconds
  end

  it "drops a size:/dur: term whose magnitude is not numeric (match-all EMPTY)" do
    Gori::QL.parse("size:big").sql.should eq("1")
    Gori::QL.parse("dur:>fast").sql.should eq("1")
  end

  it "drops an out-of-range / non-finite dur: magnitude instead of raising OverflowError" do
    Gori::QL.parse("dur:>1e20").sql.should eq("1")           # ms-scaled (×1000) overflows Int64 µs
    Gori::QL.parse("dur:>1e16s").sql.should eq("1")          # s-scaled (×1e6) overflows
    Gori::QL.parse("dur:>nan").sql.should eq("1")            # NaN is non-finite
    Gori::QL.parse("dur:>500").args.should eq([500_000_i64]) # a sane value still compiles
  end

  it "compiles header: as a case-insensitive substring over the head bytes" do
    f = Gori::QL.parse("header:Set-Cookie")
    f.sql.should eq("((lower(CAST(request_head AS TEXT)) LIKE ? ESCAPE '\\' OR " \
                    "(response_head IS NOT NULL AND lower(CAST(response_head AS TEXT)) LIKE ? ESCAPE '\\')))")
    f.args.should eq(["%set-cookie%", "%set-cookie%"]) # lowercased, substring
  end

  it "compiles the ~ operator to a REGEXP over text fields" do
    Gori::QL.parse("host~^api\\.").sql.should eq("(host REGEXP ?)")
    Gori::QL.parse("host~^api\\.").args.should eq(["^api\\."])
    Gori::QL.parse("path~\\.json$").sql.should eq("(target REGEXP ?)")
    Gori::QL.parse("url~^https").sql.should eq("((scheme || '://' || host || target) REGEXP ?)")

    body = Gori::QL.parse("body~secret\\d+")
    body.sql.should eq("(((request_body IS NOT NULL AND CAST(request_body AS TEXT) REGEXP ?) OR " \
                       "(response_body IS NOT NULL AND CAST(response_body AS TEXT) REGEXP ?)))")
    body.args.should eq(["secret\\d+", "secret\\d+"])

    hdr = Gori::QL.parse("header~^Set-Cookie:") # `~` wins over a later ':' in the value
    hdr.sql.should eq("((CAST(request_head AS TEXT) REGEXP ? OR " \
                      "(response_head IS NOT NULL AND CAST(response_head AS TEXT) REGEXP ?)))")
    hdr.args.should eq(["^Set-Cookie:", "^Set-Cookie:"])
  end

  it "picks the first separator so a regex value may itself contain ':'" do
    Gori::QL.parse("body~https?://x").args.should eq(["https?://x", "https?://x"])
  end

  it "emits a never-matches clause for an invalid ~ regex (no raise)" do
    f = Gori::QL.parse("body~[")
    f.sql.should eq("(0)")
    f.args.should be_empty
  end

  it "free-texts a ~ token on a non-regex field instead of never-matching" do
    # `foo` is not a regex field, so `~` is not a regex operator here: the whole token
    # must fall back to a free-text LIKE search, NOT compile to the never-match clause
    # (the validity guard only applies to real regex fields).
    f = Gori::QL.parse("foo~[")
    f.sql.should eq("((lower(method) LIKE ? OR lower(host) LIKE ? OR lower(target) LIKE ?))")
    f.args.should eq(["%foo~[%", "%foo~[%", "%foo~[%"])
  end
end

describe "Gori::Store#search (QL)" do
  it "filters flows by a compiled query" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/", 200)
      capture(store, "acme.test", "POST", "/login", 500)
      capture(store, "other.test", "GET", "/", 200)

      by_host = store.search(Gori::QL.parse("host:acme"), 50)
      by_host.map(&.host).uniq.should eq(["acme.test"])

      errs = store.search(Gori::QL.parse("status:>=500"), 50)
      errs.map(&.status).should eq([500])

      post_login = store.search(Gori::QL.parse("method:post path:/login"), 50)
      post_login.size.should eq(1)
      post_login.first.target.should eq("/login")

      none = store.search(Gori::QL.parse("flag:reflected"), 50)
      none.should be_empty
    end
  end

  it "searches request and response bodies (body:)" do
    tmp_store do |store|
      req_match = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: "username=admin&csrf=SeCrEtToken".to_slice))

      resp_match = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: resp_match, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body: "<input name=secrettoken value=1>".to_slice))

      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 3_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/about", http_version: "HTTP/1.1",
        head: "GET /about HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: "nothing here".to_slice))

      hits = store.search(Gori::QL.parse("body:secrettoken"), 50).map(&.id).sort
      hits.should eq([req_match, resp_match].sort) # case-insensitive, req + resp

      # substring match (not just prefix): body:token finds it INSIDE "secrettoken"
      store.search(Gori::QL.parse("body:token"), 50).map(&.id).sort.should eq([req_match, resp_match].sort)
      # and a leading fragment still works too
      store.search(Gori::QL.parse("body:secret"), 50).map(&.id).sort.should eq([req_match, resp_match].sort)

      # negation must KEEP bodyless flows (NULL-safe), not drop them
      neg = store.search(Gori::QL.parse("-body:secrettoken"), 50).map(&.id)
      neg.should_not contain(req_match)
      neg.should_not contain(resp_match)
      neg.size.should eq(1) # the "/about" flow (body "nothing here") survives
    end
  end

  it "matches bodies, hosts and headers by regex (~), case-sensitively" do
    tmp_store do |store|
      secret = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "api.acme.test", port: 80,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: api.acme.test\r\n\r\n".to_slice,
        body: "username=admin&csrf=SeCrEtToken".to_slice))
      plain = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "cdn.other.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: cdn.other.test\r\n\r\n".to_slice,
        body: "nothing here".to_slice))

      # body regex is case-sensitive; an inline (?i) opts into case-insensitivity
      store.search(Gori::QL.parse("body~SeCrEt[A-Za-z]+"), 50).map(&.id).should eq([secret])
      store.search(Gori::QL.parse("body~secret[a-z]+"), 50).should be_empty
      store.search(Gori::QL.parse("body~(?i)secrettoken"), 50).map(&.id).should eq([secret])

      # host / header regex
      store.search(Gori::QL.parse("host~^api\\."), 50).map(&.id).should eq([secret])
      store.search(Gori::QL.parse("host~test$"), 50).map(&.id).sort.should eq([secret, plain].sort)
      store.search(Gori::QL.parse("header~Host:\\s"), 50).map(&.id).sort.should eq([secret, plain].sort)

      # an invalid regex matches nothing rather than raising the whole query
      store.search(Gori::QL.parse("body~["), 50).should be_empty

      # negation is NULL-safe: a bodyless flow is KEPT, the matching one dropped
      bodyless = capture(store, "no.body.test", "GET", "/", 200)
      neg = store.search(Gori::QL.parse("-body~SeCrEt"), 50).map(&.id)
      neg.should contain(bodyless)
      neg.should contain(plain)
      neg.should_not contain(secret)
    end
  end

  it "scans a binary / invalid-UTF-8 body with body~ past a NUL without crashing" do
    tmp_store do |store|
      # leading invalid-UTF-8 bytes + an embedded NUL with "ABC" AFTER it. The scan
      # must (1) not crash on the invalid UTF-8 (scrubbed) and (2) still see content
      # past the NUL — the haystack is read by its true byte length (value_bytes),
      # not the NUL-terminated value_text.
      bin = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "bin.test", port: 80,
        method: "GET", target: "/img", http_version: "HTTP/1.1",
        head: "GET /img HTTP/1.1\r\nHost: bin.test\r\n\r\n".to_slice,
        body: Bytes[0xFF, 0xFE, 0x00, 0x41, 0x42, 0x43])) # "ABC" sits after the NUL
      text = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "txt.test", port: 80,
        method: "POST", target: "/", http_version: "HTTP/1.1",
        head: "POST / HTTP/1.1\r\nHost: txt.test\r\n\r\n".to_slice,
        body: "hello ABC world".to_slice))

      # Both match now: the binary row's "ABC" after the NUL is no longer truncated.
      store.search(Gori::QL.parse("body~ABC"), 50).map(&.id).sort.should eq([bin, text].sort)
    end
  end

  it "filters by total size and duration; respsize:/dur: exclude pending rows" do
    tmp_store do |store|
      big = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/big", http_version: "HTTP/1.1",
        head: "GET /big HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: big, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body: ("A" * 20_000).to_slice, duration_us: 800_000_i64)) # 20KB, 800ms

      small = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/small", http_version: "HTTP/1.1",
        head: "GET /small HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: small, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body: "ok".to_slice, duration_us: 50_000_i64)) # 2B, 50ms

      pending = capture(store, "acme.test", "GET", "/pending") # no response → NULL size/dur

      store.search(Gori::QL.parse("size:>10000"), 50).map(&.id).should eq([big]) # total ~20KB
      store.search(Gori::QL.parse("dur:>500"), 50).map(&.id).should eq([big])    # 500ms
      store.search(Gori::QL.parse("dur:<100"), 50).map(&.id).should eq([small])  # 100ms

      # size: spans the TOTAL (incl. the request), so a pending flow matches on its
      # request bytes — consistent with the displayed `size` column.
      store.search(Gori::QL.parse("size:>=0"), 50).map(&.id).should contain(pending)
      # respsize:/dur: target a response-only column that's NULL until the response
      # lands, so a pending flow never matches them.
      store.search(Gori::QL.parse("respsize:>=0"), 50).map(&.id).should_not contain(pending)
      store.search(Gori::QL.parse("dur:>=0"), 50).map(&.id).should_not contain(pending)
    end
  end
end
