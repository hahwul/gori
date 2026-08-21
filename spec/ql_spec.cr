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
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice))
  end
  id
end

describe Gori::QL do
  it "compiles url: field filters" do
    f = Gori::QL.parse("url:shop.demo.test")
    f.sql.should contain("LIKE ? ESCAPE '\\'")
    f.args.should eq(["%shop.demo.test%"])
  end

  it "compiles size: filters with byte unit suffixes (k, M, G)" do
    Gori::QL.parse("size:>10k").args.should eq([10240_i64])
    Gori::QL.parse("size:>=1M").args.should eq([1048576_i64])
  end

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
    # The OR now parenthesises as a whole rather than wrapping each side (a shape
    # change from the AST compiler; the predicate is identical). Every other clause
    # shape is byte-for-byte what the old flat parser emitted.
    f = Gori::QL.parse("method:get OR -host:cdn")
    f.sql.should eq("(upper(method) = ? OR NOT (lower(host) LIKE ? ESCAPE '\\'))")
    f.args.should eq(["GET", "%cdn%"])
  end

  it "treats bare words as free text over method/host/path" do
    f = Gori::QL.parse("login")
    f.args.should eq(["%login%", "%login%", "%login%"])
  end

  it "free-texts the WHOLE token for an unknown/typo'd field (keeps the prefix)" do
    # `hosst:acme` is a typo of `host:`. The fallback must search the full token, not
    # just the value after the ':', so the prefix isn't silently dropped (and a typo
    # surfaces as a no-match rather than masquerading as a successful host filter).
    f = Gori::QL.parse("hosst:acme.test")
    f.sql.should eq("((lower(method) LIKE ? ESCAPE '\\' OR lower(host) LIKE ? ESCAPE '\\' OR lower(target) LIKE ? ESCAPE '\\'))")
    f.args.should eq(["%hosst:acme.test%", "%hosst:acme.test%", "%hosst:acme.test%"])
  end

  it "free-texts flag: as an unknown field (no flow-flag store yet)" do
    # gori has no per-flow flag store (Store#flags_for is a stub), so `flag:` is not a
    # real field: it free-texts the whole token like any other unknown field rather
    # than compiling to a silent never-match that looks like a working-but-empty filter.
    f = Gori::QL.parse("flag:reflected")
    f.args.should eq(["%flag:reflected%", "%flag:reflected%", "%flag:reflected%"])
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

  # …and a value made ENTIRELY of control bytes strips to "", which `like("")` turns into
  # `'%%'` — matching every flow with a body, and `-body:` excluding every one. That is the
  # silent-BROADEN direction, and `QL.analyze` called the query clean so `strict:` never saw
  # it. `field_cond`'s empty guard runs before the strip, so `body:` and `body:\x01` had to be
  # made to agree: both drop the term.
  it "drops a body: term whose value is only control characters" do
    only_control = Gori::QL.parse("body:\u0001\u001f")
    only_control.args.should be_empty
    only_control.sql.should_not contain("request_body")
    only_control.sql.should_not contain("flows_fts")
    # The genuinely-empty spelling already behaved this way; now the two agree.
    only_control.sql.should eq(Gori::QL.parse("body:").sql)
    # Negated, the broadening was an EXCLUDE-everything - same fix, same term dropped.
    Gori::QL.parse("-body:\u0001").sql.should_not contain("request_body")
    # And `analyze` now REPORTS it: while the term compiled to '%%' the query read CLEAN,
    # so `strict:` / `ql_explain` said nothing about a filter that had quietly inverted.
    Gori::QL.analyze("body:\u0001").clean?.should be_false
  end

  it "falls back to a byte-wise blob scan for a body: value below the 3-char trigram floor" do
    f = Gori::QL.parse("body:ab")
    f.sql.should contain("COALESCE(instr(request_body, CAST(? AS BLOB)), 0) > 0")
    f.sql.should contain("COALESCE(instr(response_body, CAST(? AS BLOB)), 0) > 0")
    f.args.should eq(["ab", "ab", "aB", "aB", "Ab", "Ab", "AB", "AB"]) # every case spelling
  end

  # The <3-char fallback used `CAST(request_body AS TEXT)`, which SQLite truncates at the first
  # NUL — so a needle sitting AFTER a NUL byte was invisible, a monotonicity violation (a
  # shorter needle matching fewer rows) that cannot be explained to an operator. This is a tool
  # whose targets deliberately put NULs in bodies, so the short path is now byte-wise `instr`,
  # which is NUL-transparent. Asserted against a real store because the bug lived in SQLite's
  # cast, not in the SQL text. (The FTS >=3-char path's handling of a NUL is the trigram
  # tokenizer's, which varies by SQLite build, so it is deliberately not pinned here — this
  # test targets the blob fallback that the fix actually changed.)
  it "finds a short (<3-char) body: needle that sits AFTER a NUL byte" do
    tmp_store do |store|
      buried = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "POST", target: "/bin", http_version: "HTTP/1.1",
        head: "POST /bin HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: Bytes[0x68, 0x65, 0x61, 0x64, 0x00, 0x4E, 0x55, 0x4C, 0x4E, 0x45, 0x45, 0x44], source: Gori::FlowSource::Kind::Proxy))
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/other", http_version: "HTTP/1.1",
        head: "GET /other HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: "plain".to_slice, source: Gori::FlowSource::Kind::Proxy))
      store.flush

      # `NU` sits past the NUL. The <3-char blob path is byte-wise, so it finds it regardless of
      # the cast-at-NUL truncation the fix removed.
      store.search(Gori::QL.parse("body:NU"), 50).map(&.id).should eq([buried])
      store.search(Gori::QL.parse("body:nu"), 50).map(&.id).should eq([buried]) # still case-insensitive
      store.search(Gori::QL.parse("body:zz"), 50).map(&.id).should be_empty

      # `-body:x` (negation) must KEEP a bodyless flow, not drop it. `instr(NULL,…)` is NULL and
      # `NOT (NULL > 0)` is NULL, which SQLite excludes — so an un-COALESCE'd instr silently
      # narrowed the negated form. `buried` has `NU`, `bodyless` has no body at all.
      bodyless = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 3_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/none", http_version: "HTTP/1.1",
        head: "GET /none HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
      neg = store.search(Gori::QL.parse("-body:NU"), 50).map(&.id)
      neg.should contain(bodyless)   # kept — it has no body to match
      neg.should_not contain(buried) # excluded — its body does contain NU
    end
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

  it "parses the dur: ms/s suffix case-insensitively (like size:'s kb/mb)" do
    Gori::QL.parse("dur:>2S").sql.should eq("(duration_us > ?)") # not silently dropped
    Gori::QL.parse("dur:>2S").args.should eq([2_000_000_i64])
    Gori::QL.parse("dur:>=500MS").args.should eq([500_000_i64])
    Gori::QL.parse("dur:<1.5S").args.should eq([1_500_000_i64])
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
    # Long needles use a case-insensitive literal REGEXP (SafeRegexp is NUL-transparent);
    # CAST+LIKE truncated at the first NUL and missed headers stored after an embedded 0x00.
    f = Gori::QL.parse("header:Set-Cookie")
    f.sql.should eq("((CAST(request_head AS TEXT) REGEXP ? OR " \
                    "(response_head IS NOT NULL AND CAST(response_head AS TEXT) REGEXP ?)))")
    f.args.should eq(["(?i)Set\\-Cookie", "(?i)Set\\-Cookie"])
  end

  it "compiles a short header: needle via byte-wise instr (NUL-transparent)" do
    f = Gori::QL.parse("header:ab")
    # case permutations of "ab" → ab/aB/Ab/AB, each against request + response head
    f.sql.includes?("instr(request_head").should be_true
    f.sql.includes?("instr(response_head").should be_true
    f.args.size.should eq(8)
  end

  it "matches header: past an embedded NUL in the stored head bytes" do
    # CAST AS TEXT LIKE stopped at the first NUL; the REGEXP/instr path must not.
    tmp_store do |store|
      head = "HTTP/1.1 200 OK\r\nX-Trace: a\u0000b\r\nSet-Cookie: sid=1\r\n\r\n".to_slice
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: head))
      store.flush
      store.search(Gori::QL.parse("header:Set-Cookie"), 50).map(&.id).should eq([id])
      store.search(Gori::QL.parse("header:set-cookie"), 50).map(&.id).should eq([id]) # case-insensitive
    end
  end

  it "compiles the ~ operator to a REGEXP over text fields" do
    Gori::QL.parse("host~^api\\.").sql.should eq("(host REGEXP ?)")
    Gori::QL.parse("host~^api\\.").args.should eq(["^api\\."])
    Gori::QL.parse("path~\\.json$").sql.should eq("(target REGEXP ?)")
    Gori::QL.parse("url~^https").sql.should eq(
      "((CASE WHEN lower(substr(target, 1, 7)) = 'http://' OR lower(substr(target, 1, 8)) = 'https://' " \
      "THEN target ELSE (scheme || '://' || host || target) END) REGEXP ?)")

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
    f.sql.should eq("((lower(method) LIKE ? ESCAPE '\\' OR lower(host) LIKE ? ESCAPE '\\' OR lower(target) LIKE ? ESCAPE '\\'))")
    f.args.should eq(["%foo~[%", "%foo~[%", "%foo~[%"])
  end

  # gRPC reads BOTH sides' Content-Type: it is a type the request sends too, and a call
  # answered with a proxy's `text/html` 502 — or not answered at all — is still a gRPC call.
  # `Proto.classify` makes the same two-sided test, which is the point of this whole module:
  # the label the column prints and the value the filter matches cannot drift.
  #
  # `ws` reads BOTH transports for the same reason (#743): a WebSocket over HTTP/2 is an
  # RFC 8441 extended CONNECT answered `200`, so `status = 101` alone omitted every h2 socket
  # from the one filter an operator reaches for to find sockets. The token comes off the V16
  # `connect_protocol` column, by EQUALITY — `connect-udp`/`connect-ip` are extended CONNECTs
  # that are not RFC 6455 framing and must not match.
  it "compiles proto: over BOTH WS transports (grpc either side, sse by response)" do
    Gori::QL.parse("proto:ws").sql.should eq(
      "(((status IS NOT NULL AND status = 101) OR " \
      "(status IS NOT NULL AND status >= 200 AND status < 300 AND " \
      "connect_protocol IS NOT NULL AND lower(connect_protocol) = 'websocket')))")
    Gori::QL.parse("proto:websocket").sql.should eq( # alias
"(((status IS NOT NULL AND status = 101) OR " \
"(status IS NOT NULL AND status >= 200 AND status < 300 AND " \
"connect_protocol IS NOT NULL AND lower(connect_protocol) = 'websocket')))")
    Gori::QL.parse("proto:grpc").sql.should eq(
      "(((content_type IS NOT NULL AND lower(content_type) LIKE 'application/grpc%') OR " \
      "(request_content_type IS NOT NULL AND lower(request_content_type) LIKE 'application/grpc%')))")
    Gori::QL.parse("proto:sse").sql.should eq(
      "((content_type IS NOT NULL AND lower(content_type) LIKE 'text/event-stream%'))")
    Gori::QL.parse("proto:ws").args.should be_empty
  end

  it "compiles proto:http as a NULL-safe negation (pending/typeless flows count as http)" do
    Gori::QL.parse("proto:http").sql.should eq(
      "(NOT ((status IS NOT NULL AND status = 101) OR " \
      "(status IS NOT NULL AND status >= 200 AND status < 300 AND " \
      "connect_protocol IS NOT NULL AND lower(connect_protocol) = 'websocket')) " \
      "AND NOT ((content_type IS NOT NULL AND lower(content_type) LIKE 'application/grpc%') OR " \
      "(request_content_type IS NOT NULL AND lower(request_content_type) LIKE 'application/grpc%')) " \
      "AND NOT (content_type IS NOT NULL AND lower(content_type) LIKE 'text/event-stream%'))")
  end

  it "drops an unknown proto: value (match-all EMPTY, not everything)" do
    # Mirrors a bad status: — a typo like proto:htttp must not silently match all flows.
    Gori::QL.parse("proto:htttp").sql.should eq("1")
  end

  # The History PROTO column prints WSS/GRPCS/SSES/HTTPS, so those spellings have to be
  # typeable here — and they have to MEAN the transport they name. An alias that quietly
  # returned the cleartext rows too would drop exactly the signal the column was changed to
  # keep, on the query an operator writes BECAUSE they saw it in the column.
  it "compiles the transport spellings the PROTO column prints as protocol AND scheme" do
    Gori::QL.parse("proto:wss").sql.should eq(
      "((((status IS NOT NULL AND status = 101) OR " \
      "(status IS NOT NULL AND status >= 200 AND status < 300 AND " \
      "connect_protocol IS NOT NULL AND lower(connect_protocol) = 'websocket'))) " \
      "AND scheme = 'https')")
    Gori::QL.parse("proto:grpcs").sql.should eq(
      "((((content_type IS NOT NULL AND lower(content_type) LIKE 'application/grpc%') OR " \
      "(request_content_type IS NOT NULL AND lower(request_content_type) LIKE 'application/grpc%'))) " \
      "AND scheme = 'https')")
    Gori::QL.parse("proto:sses").sql.should eq(
      "(((content_type IS NOT NULL AND lower(content_type) LIKE 'text/event-stream%')) " \
      "AND scheme = 'https')")
    Gori::QL.parse("proto:wss").args.should be_empty
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

      # flag: is not a real field (no flow-flag store): it free-texts the whole token,
      # which matches none of these flows' method/host/target.
      none = store.search(Gori::QL.parse("flag:reflected"), 50)
      none.should be_empty
    end
  end

  it "url~ recognizes an ABSOLUTE-FORM target of any scheme case without doubling scheme://host" do
    tmp_store do |store|
      # Origin-form (the common case: HTTPS/CONNECT) and absolute-form (plain-HTTP
      # forward-proxy wire shape) captures of the same logical endpoint, plus an
      # upper-cased-scheme absolute-form capture (RFC 3986 §3.1: schemes are
      # case-insensitive).
      capture(store, "acme.test", "GET", "/dashboard")
      capture(store, "acme.test", "GET", "http://acme.test/dashboard")
      capture(store, "acme.test", "GET", "HTTP://acme.test/dashboard")

      # Origin-form: scheme://host gets prefixed onto the bare target.
      store.search(Gori::QL.parse("url~^http://acme\\.test/dashboard$"), 50)
        .map(&.target).should contain("/dashboard")
      # Absolute-form (lowercase scheme): target already IS the URL, used verbatim.
      store.search(Gori::QL.parse("url~^http://acme\\.test/dashboard$"), 50)
        .map(&.target).should contain("http://acme.test/dashboard")
      # Absolute-form (uppercase scheme) must ALSO be recognized and left verbatim — a
      # case-sensitive absolute-form check would instead double it into
      # "http://acme.testHTTP://acme.test/dashboard", which this anchored,
      # case-sensitive regex (matching only the un-doubled exact string) would never match.
      store.search(Gori::QL.parse("url~^HTTP://acme\\.test/dashboard$"), 50)
        .map(&.target).should contain("HTTP://acme.test/dashboard")
    end
  end

  it "filters by proto: over real captured flows (ws/grpc/sse/http, NULL-safe)" do
    tmp_store do |store|
      # WebSocket handshake (101, no content type).
      ws = capture(store, "acme.test", "GET", "/socket", 101)
      # gRPC + SSE distinguished only by Content-Type on a 200.
      grpc = capture(store, "acme.test", "POST", "/rpc")
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: grpc, status: 200, content_type: "application/grpc+proto",
        head: "HTTP/1.1 200 OK\r\nContent-Type: application/grpc+proto\r\n\r\n".to_slice))
      sse = capture(store, "acme.test", "GET", "/events")
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: sse, status: 200, content_type: "text/event-stream; charset=utf-8",
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice))
      # Plain HTTP (typed) and a still-pending flow (NULL status + NULL content_type).
      html = capture(store, "acme.test", "GET", "/", 200)
      pending = capture(store, "acme.test", "GET", "/pending")

      def_ids = ->(q : String) { store.search(Gori::QL.parse(q), 50).map(&.id).sort }
      def_ids.call("proto:ws").should eq([ws])
      def_ids.call("proto:grpc").should eq([grpc])
      def_ids.call("proto:sse").should eq([sse])
      # http = everything that is NOT ws/grpc/sse — including the NULL-column pending flow.
      def_ids.call("proto:http").should eq([html, pending].sort)
      # Negation is NULL-safe too: -proto:grpc keeps the pending (NULL content_type) flow.
      def_ids.call("-proto:grpc").includes?(pending).should be_true
    end
  end

  # H3-F3's other half, over real rows: the same protocol on the two transports, listed
  # together the way an operator triages them. `proto:ws` still means "a WebSocket"; the
  # spelling the PROTO column shows for each row selects that row and only that row.
  it "separates ws:// from wss:// on proto:, the way the PROTO column now spells them" do
    tmp_store do |store|
      cleartext = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/chat", http_version: "HTTP/1.1",
        head: "GET /chat HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(flow_id: cleartext, status: 101,
        head: "HTTP/1.1 101 Switching Protocols\r\n\r\n".to_slice))
      tls = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "https", host: "acme.test", port: 443,
        method: "GET", target: "/chat", http_version: "HTTP/1.1",
        head: "GET /chat HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(flow_id: tls, status: 101,
        head: "HTTP/1.1 101 Switching Protocols\r\n\r\n".to_slice))

      ids = ->(q : String) { store.search(Gori::QL.parse(q), 50).map(&.id).sort }
      ids.call("proto:ws").should eq([cleartext, tls].sort)
      ids.call("proto:wss").should eq([tls])
      # ... and the composed form an operator could always write means the same thing.
      ids.call("proto:ws scheme:https").should eq([tls])
      ids.call("proto:ws scheme:http").should eq([cleartext])
    end
  end

  it "searches request and response bodies (body:)" do
    tmp_store do |store|
      req_match = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: "username=admin&csrf=SeCrEtToken".to_slice, source: Gori::FlowSource::Kind::Proxy))

      resp_match = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: resp_match, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body: "<input name=secrettoken value=1>".to_slice))

      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 3_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/about", http_version: "HTTP/1.1",
        head: "GET /about HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: "nothing here".to_slice, source: Gori::FlowSource::Kind::Proxy))

      store.flush # body: reads the trigram index, which is written off-commit (Store V4)

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

  # `header:`/`body:` search BOTH sides; `req.`/`resp.` picks one. The fast path is an FTS5
  # COLUMN FILTER over `flows_fts(req, resp)` — a table that already stored the two sides apart —
  # so these pin that the filter really scopes rather than being ignored by the MATCH parser,
  # which would silently return the two-sided answer and look like it worked.
  it "scopes header:/body: to one side with a req./resp. prefix" do
    tmp_store do |store|
      req_side = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: acme.test\r\nX-Only-Req: 1\r\n\r\n".to_slice,
        body: "csrf=secrettoken".to_slice, source: Gori::FlowSource::Kind::Proxy))

      resp_side = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: resp_side, status: 200,
        head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=1\r\n\r\n".to_slice,
        body: "<input value=secrettoken>".to_slice))

      quiet = capture(store, "acme.test", "GET", "/about", 200) # no body either side
      store.flush                                               # body: reads the off-commit trigram index

      ids = ->(q : String) { store.search(Gori::QL.parse(q), 50).map(&.id).sort }

      # the two-sided spelling still finds both — the prefix ADDS a way to ask, it does not
      # change what the old one answers
      ids.call("body:secrettoken").should eq([req_side, resp_side].sort)

      ids.call("req.body:secrettoken").should eq([req_side])
      ids.call("resp.body:secrettoken").should eq([resp_side])
      ids.call("res.body:secrettoken").should eq([resp_side]) # `res.` is a synonym of `resp.`

      # a short needle takes the byte-wise `instr` path instead of the index — same scoping
      ids.call("req.body:se").should eq([req_side])
      ids.call("resp.body:se").should eq([resp_side])

      # regex (`~`) scopes too, and reaches bytes the index does not
      ids.call("req.body~secret[a-z]+").should eq([req_side])
      ids.call("resp.body~secret[a-z]+").should eq([resp_side])

      # heads: `X-Only-Req` is on the request, `Set-Cookie` on the response
      ids.call("req.header:x-only-req").should eq([req_side])
      ids.call("resp.header:x-only-req").should be_empty
      ids.call("resp.header:set-cookie").should eq([resp_side])
      ids.call("req.header:set-cookie").should be_empty
      ids.call("resp.header~(?i)set-cookie").should eq([resp_side])

      # NEGATION keeps the other side AND the flow with nothing on either — the NULL-safety the
      # two-sided spelling already had must survive the column filter (an unguarded scoped clause
      # would answer NULL for a response-less flow and SQLite would exclude it).
      neg = ids.call("-resp.body:secrettoken")
      neg.should contain(req_side)
      neg.should contain(quiet)
      neg.should_not contain(resp_side)

      neg_head = ids.call("-resp.header:set-cookie")
      neg_head.should contain(req_side) # response-less: kept, not dropped
      neg_head.should contain(quiet)
      neg_head.should_not contain(resp_side)

      # and it composes with the grammar exactly like any other term
      ids.call("NOT (req.body:secrettoken OR resp.body:secrettoken)").should eq([quiet])
    end
  end

  # --- scope: (#754) -------------------------------------------------------------------------
  # The field QL cannot answer on its own: the rules are the PROJECT's, so a surface has to hand
  # the predicate in (`QL::ScopeLens`). Every property below is one an operator would be misled
  # by if it silently went the other way.
  describe "scope:" do
    it "compiles scope:in to the lens predicate and scope:out to its negation" do
      lens = Gori::QL::ScopeLens.new(Gori::QL::Filter.new("(host = ?)", ["acme.test"] of DB::Any))
      Gori::QL.parse("scope:in", scope: lens).sql.should eq("((host = ?))")
      Gori::QL.parse("scope:in", scope: lens).args.should eq(["acme.test"])
      Gori::QL.parse("scope:out", scope: lens).sql.should eq("(NOT ((host = ?)))")
      Gori::QL.parse("scope:out", scope: lens).args.should eq(["acme.test"])
      # `-scope:in` and `scope:out` are the same question spelled two ways — WITH a lens.
      Gori::QL.parse("-scope:in", scope: lens).sql.should eq(Gori::QL.parse("scope:out", scope: lens).sql)
    end

    # The lens contributes its OWN bound values, in the middle of the query's. `tree_sql`
    # appends args depth-first to match the `?` order it emits; a scope term is the first term
    # to carry more than one, so this is where that discipline is worth pinning.
    it "keeps the lens's args in placeholder order among the other terms'" do
      lens = Gori::QL::ScopeLens.new(
        Gori::QL::Filter.new("(host = ? OR host = ?)", ["a.test", "b.test"] of DB::Any))
      f = Gori::QL.parse("method:POST scope:in status:404", scope: lens)
      f.args.should eq(["POST", "a.test", "b.test", 404])
    end

    # Nothing is in scope, so the question has no answer. NOT the complement: `NOT (0)` is every
    # flow, and `history delete -q scope:out --yes` would then empty an unconfigured project past
    # every guard there is (`reject_empty?` compares the SQL against `1`, not `NOT (0)`).
    it "matches NOTHING — both spellings — when the project has no scope rules" do
      unconf = Gori::QL::ScopeLens.new(nil)
      Gori::QL.parse("scope:in", scope: unconf).sql.should eq("(0)")
      Gori::QL.parse("scope:out", scope: unconf).sql.should eq("(0)")
      # …and the term is APPLIED, not dropped: it compiled to a real clause, so nothing here is
      # broader than what was asked and `strict:` has nothing to refuse.
      a = Gori::QL.analyze("scope:in", scope: unconf)
      a.applied.should eq(["scope:in"])
      a.clean?.should be_true
    end

    # No lens at all is a different answer from an unconfigured one: this surface cannot answer
    # the field, so the term is DROPPED — and every existing diagnostic then names it, which is
    # the loud direction. (`side_prefixed?` above takes the same road for the same reason.)
    it "DROPS the term, reported, on a surface that threads no lens" do
      %w[scope:in scope:out].each do |q|
        a = Gori::QL.analyze(q)
        a.ignored.should eq([q]), "#{q} should be reported as dropped with no lens"
        a.applied.should be_empty
        a.clean?.should be_false
        Gori::QL.reject_empty?(q, Gori::QL.parse(q)).should be_true # never match-all
      end
    end

    # A value the field does not take is dropped rather than guessed — `proto:zzz`'s rule. Under
    # a lens, so the drop is about the VALUE and not about the missing predicate.
    it "drops a value that is not in/out" do
      lens = Gori::QL::ScopeLens.new(Gori::QL::Filter.new("(1)", [] of DB::Any))
      %w[scope:true scope:yes scope:].each do |q|
        Gori::QL.analyze(q, scope: lens).applied.should be_empty, "#{q} should not compile"
      end
      Gori::QL.analyze("scope:IN", scope: lens).applied.should eq(["scope:IN"]) # case-folded
    end

    it "is offered, known, and answers uses_scope? through the compilers' own tokenizer" do
      Gori::QL::FIELDS.should contain("scope")
      Gori::QL.known_field?("scope").should be_true
      Gori::QL.uses_scope?("host:a scope:out").should be_true
      Gori::QL.uses_scope?("-scope:in").should be_true
      Gori::QL.uses_scope?("host:acme").should be_false
      # `scope` is not a REGEX field, so `scope~in` free-texts the whole token (the road
      # `size~1` takes) and names no scope predicate — every surface that WARNS about a scope
      # term must not speak about this one, or it warns about a term that is not there.
      Gori::QL.uses_scope?("scope~in").should be_false
      Gori::QL.parse("scope~in", scope: Gori::QL::ScopeLens.new(nil)).sql
        .should eq(Gori::QL.parse("zzz~in", scope: Gori::QL::ScopeLens.new(nil)).sql)
      # Quoting is NOT an escape: the grammar strips quotes before the field/value split, so
      # `"scope:in"` is still a scope term — the same reading `host:"x"` gets, and the reason
      # `field_shaped?` says a KNOWN field is a field use whatever its value holds.
      Gori::QL.uses_scope?(%q("scope:in")).should be_true
    end

    # The claim the whole design rests on: `scope:in` IS the `--in-scope` predicate, not a
    # respelling of it. Run against a real store, both ways, and compared row for row.
    it "selects exactly what Scope#filter(force: true) selects" do
      tmp_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        scope.add("exclude", "host", "cdn.acme.test")
        capture(store, "acme.test", "GET", "/x")
        capture(store, "cdn.acme.test", "GET", "/y")
        capture(store, "other.test", "GET", "/z")

        lens = scope.ql_lens
        by_term = store.search(Gori::QL.parse("scope:in", scope: lens), 50).map(&.host).sort
        by_flag = store.search(scope.filter(force: true), 50).map(&.host).sort
        by_term.should eq(by_flag)
        by_term.should eq(["acme.test"])

        out = store.search(Gori::QL.parse("scope:out", scope: lens), 50).map(&.host).sort
        out.should eq(["cdn.acme.test", "other.test"])
        # …and it composes: the term is a clause, not a lens the caller ANDs on.
        store.search(Gori::QL.parse("scope:out host:cdn", scope: lens), 50)
          .map(&.host).should eq(["cdn.acme.test"])
        store.search(Gori::QL.parse("NOT (scope:in OR host:other)", scope: lens), 50)
          .map(&.host).should eq(["cdn.acme.test"])
      end
    end
  end

  it "accepts req./resp. size synonyms and reports namespaced fields as known" do
    Gori::QL.parse("req.size:>100").sql.should eq(Gori::QL.parse("reqsize:>100").sql)
    Gori::QL.parse("resp.size:>100").sql.should eq(Gori::QL.parse("respsize:>100").sql)
    Gori::QL.parse("res.size:>100").sql.should eq(Gori::QL.parse("respsize:>100").sql)

    # `FIELDS` is the pool a surface OFFERS; `known_field?` is what it ACCEPTS. A validating
    # surface (Colormarker's unknown-field refusal) must read the wider one or it rejects a
    # spelling QL compiles.
    Gori::QL.known_field?("resp.body").should be_true
    Gori::QL.known_field?("res.body").should be_true
    Gori::QL.known_field?("req.size").should be_true
    Gori::QL.known_field?("resp.host").should be_false # single-sided field takes no prefix
    Gori::QL::FIELDS.should contain("resp.body")
    Gori::QL::FIELDS.should_not contain("res.body") # accepted, deliberately not offered

    # an invalid regex under an ALIAS is still reported — diagnosis canonicalises the way
    # compilation does, or `res.body~[bad` would compile to the never-match clause unflagged
    Gori::QL.invalid_regex_terms("res.body~[bad").should eq(["res.body~[bad"])
  end

  # Advertising a namespace invites guesses at the rest of it. `resp.status:` is not a typo the
  # way `hsot:` is — it is someone applying the rule the hint row and Help page just taught them.
  it "REPORTS a side prefix on a field that has no side, instead of free-texting it to zero" do
    %w[resp.status:200 resp.code:200 req.method:POST res.host:acme].each do |q|
      a = Gori::QL.analyze(q)
      a.ignored.should eq([q]), "#{q} should be reported as dropped"
      a.applied.should be_empty
      a.clean?.should be_false # so `strict:` refuses it and ql_explain names it
      # ...and a query that was ONLY this must not fall through to match-all.
      Gori::QL.reject_empty?(q, Gori::QL.parse(q)).should be_true
    end

    # The `~` spelling takes the same path — diagnosis and compilation cannot disagree.
    Gori::QL.analyze("resp.status~2..").ignored.should eq(["resp.status~2.."])

    # An ordinary unknown field is UNCHANGED: it still free-texts the whole token, which makes a
    # typo self-evident (it matches nothing real) and is behaviour other surfaces rely on.
    Gori::QL.analyze("hsot:acme").applied.should eq(["hsot:acme"])
    Gori::QL.analyze("time:12:00").applied.should eq(["time:12:00"])
    # A bare word that merely STARTS with a prefix is free text, not a field at all.
    Gori::QL.analyze("respond").applied.should eq(["respond"])
  end

  # A substring field folds BOTH sides — needle and haystack — and folding is only a fold if it
  # covers the whole alphabet. SQLite's built-in `lower()` is ASCII-only, so `lower(target) LIKE
  # '%überweisung%'` left the haystack's `Ü` uppercase and answered nothing; a non-ASCII needle
  # takes `gori_ci_contains` (Crystal's `downcase.includes?` as a UDF) instead.
  it "folds a non-ASCII needle on both sides for path:, url: and free text" do
    tmp_store do |store|
      id = capture(store, "acme.test", "GET", "/Überweisung")
      other = capture(store, "acme.test", "GET", "/other")

      store.search(Gori::QL.parse("path:Überweisung"), 50).map(&.id).should eq([id])
      store.search(Gori::QL.parse("path:überweisung"), 50).map(&.id).should eq([id])
      store.search(Gori::QL.parse("url:Überweisung"), 50).map(&.id).should eq([id])
      store.search(Gori::QL.parse("Überweisung"), 50).map(&.id).should eq([id])

      # Polarity: the UDF answers 0 (not NULL) for a non-match, so negation still keeps
      # exactly the other row rather than the three-valued-logic drop `NOT (NULL)` would give.
      store.search(Gori::QL.parse("-path:Überweisung"), 50).map(&.id).should eq([other])
    end
  end

  it "folds a non-ASCII needle for host: and free text too" do
    tmp_store do |store|
      id = capture(store, "Über.test", "GET", "/x")
      capture(store, "acme.test", "GET", "/x")

      store.search(Gori::QL.parse("host:Über"), 50).map(&.id).should eq([id])
      store.search(Gori::QL.parse("host:über"), 50).map(&.id).should eq([id])
      store.search(Gori::QL.parse("über.test"), 50).map(&.id).should eq([id])
    end
  end

  # The ASCII needle keeps the native `lower(col) LIKE ?` path, so the LIKE-metacharacter
  # escaping that path depends on must still hold over real rows, not just in the compiled SQL.
  it "still treats a literal % / _ in the needle literally" do
    tmp_store do |store|
      pct = capture(store, "acme.test", "GET", "/a%b")
      capture(store, "acme.test", "GET", "/axb")

      store.search(Gori::QL.parse("path:a%b"), 50).map(&.id).should eq([pct])
      store.search(Gori::QL.parse("path:a_b"), 50).map(&.id).should be_empty
    end
  end

  # Two implementations of one predicate: the SQL one here and `InterceptFilter`'s in-memory one.
  # A fold that only one of them performs black-holes a rule that the other's UI says matches.
  it "agrees with the in-memory implementation of the same predicate" do
    subject = Gori::InterceptFilter::Subject.new(
      method: "GET", host: "acme.test", target: "/Überweisung", scheme: "http")
    Gori::InterceptFilter.new("path:Überweisung").matches?(subject).should be_true

    tmp_store do |store|
      id = capture(store, "acme.test", "GET", "/Überweisung")
      store.search(Gori::QL.parse("path:Überweisung"), 50).map(&.id).should eq([id])
    end
  end

  # The pin that makes "a field is added when its explanation is added" true rather than a wish.
  # Every hint string that used to be written by hand beside a widget is generated from these two
  # now, so a field with no entry would render as a blank description column somewhere.
  describe "FIELD_HELP / SYNTAX_HELP" do
    it "explains every field the completion pool offers, and nothing it does not" do
      Gori::QL::FIELDS.each do |f|
        Gori::QL::FIELD_HELP[f]?.should_not be_nil, "FIELD_HELP is missing `#{f}:`"
      end
      (Gori::QL::FIELD_HELP.keys - Gori::QL::FIELDS).should be_empty
    end

    it "resolves help through an alias, so an accepted spelling is never undocumented" do
      Gori::QL.field_help("res.body").should eq(Gori::QL::FIELD_HELP["resp.body"])
      Gori::QL.field_help("req.size").should eq(Gori::QL::FIELD_HELP["reqsize"])
      Gori::QL.field_help("nope").should be_nil
    end

    it "keeps every line inside the one terminal column it renders in" do
      Gori::QL::FIELD_HELP.each { |name, help| help.size.should be <= 46, "#{name}: too long" }
      Gori::QL::SYNTAX_HELP.each { |(ex, why)| (ex.size + why.size).should be <= 78 }
    end

    it "documents the operators a field-name pool can never show" do
      why = Gori::QL::SYNTAX_HELP.map { |(ex, _)| ex }.join(" ")
      why.should contain("-")   # negation
      why.should contain("OR")  # boolean
      why.should contain("NOT") # group negation
      why.should contain("~")   # regex
      why.should contain("resp.")
    end
  end

  it "matches bodies, hosts and headers by regex (~), case-sensitively" do
    tmp_store do |store|
      secret = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "api.acme.test", port: 80,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: api.acme.test\r\n\r\n".to_slice,
        body: "username=admin&csrf=SeCrEtToken".to_slice, source: Gori::FlowSource::Kind::Proxy))
      plain = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "cdn.other.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: cdn.other.test\r\n\r\n".to_slice,
        body: "nothing here".to_slice, source: Gori::FlowSource::Kind::Proxy))

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
        body: Bytes[0xFF, 0xFE, 0x00, 0x41, 0x42, 0x43], source: Gori::FlowSource::Kind::Proxy)) # "ABC" sits after the NUL
      text = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "txt.test", port: 80,
        method: "POST", target: "/", http_version: "HTTP/1.1",
        head: "POST / HTTP/1.1\r\nHost: txt.test\r\n\r\n".to_slice,
        body: "hello ABC world".to_slice, source: Gori::FlowSource::Kind::Proxy))

      # Both match now: the binary row's "ABC" after the NUL is no longer truncated.
      store.search(Gori::QL.parse("body~ABC"), 50).map(&.id).sort.should eq([bin, text].sort)
    end
  end

  it "filters by total size and duration; respsize:/dur: exclude pending rows" do
    tmp_store do |store|
      big = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/big", http_version: "HTTP/1.1",
        head: "GET /big HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: big, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body: ("A" * 20_000).to_slice, duration_us: 800_000_i64)) # 20KB, 800ms

      small = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/small", http_version: "HTTP/1.1",
        head: "GET /small HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
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

  describe ".reject_empty?" do
    it "flags a non-blank query that compiles to EMPTY" do
      Gori::QL.reject_empty?("status:>=foo", Gori::QL.parse("status:>=foo")).should be_true
    end

    it "allows a blank query (caller handles separately)" do
      Gori::QL.reject_empty?("  ", Gori::QL::EMPTY).should be_false
    end

    it "allows a query with at least one valid term" do
      f = Gori::QL.parse("host:beta status:>=foo")
      Gori::QL.reject_empty?("host:beta status:>=foo", f).should be_false
    end
  end

  describe ".invalid_regex_terms" do
    it "flags a regex term whose pattern does not compile" do
      Gori::QL.invalid_regex_terms("host:h body~[bad").should eq(["body~[bad"])
    end

    it "keeps the leading '-' on a negated invalid regex term" do
      Gori::QL.invalid_regex_terms("-host~[bad").should eq(["-host~[bad"])
    end

    it "returns nothing for valid regexes and non-regex terms" do
      Gori::QL.invalid_regex_terms("host~^api\\. status:>=foo body:token").should be_empty
    end

    it "does not flag a '~' on a non-regex field (that free-texts the whole token)" do
      Gori::QL.invalid_regex_terms("foo~[bad").should be_empty
    end

    it "flags each bad term across OR groups" do
      Gori::QL.invalid_regex_terms("body~[a OR path~[b").should eq(["body~[a", "path~[b"])
    end

    it "reaches terms nested inside parentheses and NOT" do
      Gori::QL.invalid_regex_terms("(host:a OR body~[bad)").should eq(["body~[bad"])
      Gori::QL.invalid_regex_terms("NOT (path~[bad)").should eq(["path~[bad"])
    end
  end

  describe ".analyze" do
    it "reports terms as applied or silently ignored" do
      a = Gori::QL.analyze("host:beta status:>=foo")
      a.applied.should eq(["host:beta"])
      a.ignored.should eq(["status:>=foo"]) # a bad numeric is DROPPED, broadening the result
      a.clean?.should be_false
    end

    it "counts operators and grouping as structure, not as terms" do
      a = Gori::QL.analyze("(host:a AND host:b) OR NOT host:c")
      a.applied.should eq(["host:a", "host:b", "host:c"])
      a.ignored.should be_empty
      a.clean?.should be_true
    end

    it "echoes a term exactly as typed, quotes and all" do
      Gori::QL.analyze(%(-host:"my host")).applied.should eq([%(-host:"my host")])
    end
  end

  describe "dropped-term semantics under NOT/OR (R1-2)" do
    # A term the backend cannot compile is treated as if it were never typed
    # ("textual deletion"): the query is re-read with the bad token removed. This is
    # the ONLY reading under which every SURVIVING term keeps its standalone meaning,
    # and it is what the QL reference documents. Pinned so a future change is deliberate.
    it "drops a bad numeric term inside a NOT group and negates the survivor" do
      dropped = Gori::QL.parse("NOT (host:x AND size:>bogus)")
      dropped.sql.should eq("(NOT (lower(host) LIKE ? ESCAPE '\\'))")
      dropped.args.should eq(["%x%"])
      dropped.sql.should eq(Gori::QL.parse("NOT host:x").sql) # bad token vanished entirely
      # analyze still SURFACES the drop even when nested under NOT
      Gori::QL.analyze("NOT (host:x AND size:>bogus)").ignored.should eq(["size:>bogus"])
    end

    it "collapses an OR whose only other term dropped (the OR does nothing)" do
      Gori::QL.parse("host:x OR size:>bogus").sql.should eq("(lower(host) LIKE ? ESCAPE '\\')")
    end

    # The asymmetry that makes this LOOK inconsistent: an INVALID REGEX does NOT drop —
    # it compiles to a never-match "0" clause that STAYS in the tree, so under NOT it
    # inverts to match-all. Numeric-bad (dropped) and regex-bad (FALSE clause) genuinely
    # diverge here; deliberate, because the FALSE clause is what invalid_regex_terms
    # hard-errors on in the MCP layer.
    it "keeps an invalid-regex term as a never-match clause inside NOT (does not drop)" do
      f = Gori::QL.parse("NOT (host:x AND body~[bad)")
      f.sql.should eq("(NOT ((lower(host) LIKE ? ESCAPE '\\' AND 0)))")
      f.args.should eq(["%x%"])
    end
  end

  describe "boolean structure" do
    # Grouping has to change the ANSWER, not just the SQL text: without parens AND
    # binds tighter, so the two queries below are genuinely different predicates.
    it "binds AND tighter than OR unless parenthesised" do
      loose = Gori::QL.parse("host:a OR host:b status:301")
      loose.sql.should eq("(lower(host) LIKE ? ESCAPE '\\' OR " \
                          "(lower(host) LIKE ? ESCAPE '\\' AND status = ?))")
      grouped = Gori::QL.parse("(host:a OR host:b) status:301")
      grouped.sql.should eq("((lower(host) LIKE ? ESCAPE '\\' OR lower(host) LIKE ? ESCAPE '\\') " \
                            "AND status = ?)")
    end

    it "negates a whole group with NOT" do
      f = Gori::QL.parse("NOT (host:a OR host:b)")
      f.sql.should eq("(NOT ((lower(host) LIKE ? ESCAPE '\\' OR lower(host) LIKE ? ESCAPE '\\')))")
      f.args.should eq(["%a%", "%b%"])
    end

    it "spells AND explicitly for the same predicate as whitespace" do
      Gori::QL.parse("host:a AND status:301").sql.should eq(Gori::QL.parse("host:a status:301").sql)
    end

    it "keeps a quoted value in one term, spaces included" do
      f = Gori::QL.parse(%(host:"my host"))
      f.sql.should eq("(lower(host) LIKE ? ESCAPE '\\')")
      f.args.should eq(["%my host%"])
    end

    it "compiles src: to the provenance column, by token and by the SRC column's tag" do
      f = Gori::QL.parse("src:repeater")
      f.sql.should eq("(source = ?)")
      f.args.should eq(["repeater"])
      # The tag the History column prints is typeable, and normalises to the stored token.
      Gori::QL.parse("src:rptr").args.should eq(["repeater"])
      Gori::QL.parse("src:IMPRT").args.should eq(["import"])
      # `source:` is the accepted long spelling; an unknown field free-texts, so without the
      # alias it would have matched nothing and read as "no repeater flows".
      Gori::QL.parse("source:repeater").sql.should eq(f.sql)
      Gori::QL.parse("source:repeater").args.should eq(f.args)
    end

    it "compiles src:gori from the enum, so it widens as tools learn to record" do
      f = Gori::QL.parse("src:gori")
      expected = Gori::FlowSource::Kind.values.select(&.sent_by_gori?).map(&.token)
      f.args.should eq(expected)
      f.sql.should eq("(source IN (#{Array.new(expected.size, "?").join(",")}))")
      # Deliberately NOT the complement of src:proxy — an import is neither.
      f.args.should_not contain("proxy")
      f.args.should_not contain("import")
    end

    it "drops an unrecognised src: value instead of guessing, like proto:/status:" do
      Gori::QL.analyze("src:browser").ignored.should_not be_empty
      Gori::QL.parse("src:browser host:a").sql.should eq("(lower(host) LIKE ? ESCAPE '\\')")
    end

    it "matches a pre-V17 flow in NEITHER direction" do
      # The column has no default to fall back on, so an unrecorded provenance is SQL NULL and
      # both `source = 'proxy'` and `NOT (source = 'proxy')` are NULL — the same way a Pending
      # flow falls out of `status:` and `-status:`. `QL::CAVEATS` says so out loud.
      path = File.tempname("gori-ql-null-src", ".db")
      begin
        store = Gori::Store.open(path)
        recorded = capture(store, "t.test", "GET", "/recorded", 200)
        legacy = capture(store, "t.test", "GET", "/legacy", 200)
        store.close
        DB.open("sqlite3:#{path}") { |db| db.exec("UPDATE flows SET source = NULL WHERE id = ?", legacy) }

        store = Gori::Store.open(path)
        begin
          store.search(Gori::QL.parse("src:proxy"), 10).map(&.id).should eq([recorded])
          store.search(Gori::QL.parse("-src:proxy"), 10).should be_empty
          store.search(Gori::QL.parse("src:gori"), 10).should be_empty
          # It is still a flow, and everything that does not ask about provenance still finds it.
          store.search(Gori::QL.parse("path:/legacy"), 10).map(&.id).should eq([legacy])
        ensure
          store.close
        end
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end

    it "leaves a parenthesis inside a value literal (no escaping needed)" do
      # Regression guard: `path:/a(b)` parsed as one token before the grammar grew
      # parens, and must keep doing so.
      f = Gori::QL.parse("path:/a(b)")
      f.sql.should eq("(lower(target) LIKE ? ESCAPE '\\')")
      f.args.should eq(["%/a(b)%"])
    end
  end
end
