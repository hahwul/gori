require "./spec_helper"

# Payload values read from captured project data (#1352). What these pin: the descriptor
# grammar, a STRICT query (a term QL would drop broadens the selection), bounded and
# deterministic output, that values are kept as captured (P7) while secrets are withheld by
# default and only by an explicit, reported opt-in, and that nothing here writes or sends.
private alias PF = Gori::PayloadFrom
private alias Loc = Gori::Miner::Location

private CLOCK = [1_700_000_000_000_000_i64]

private def pf_flow(store : Gori::Store, target : String, *, host = "api.test", method = "GET",
                    req_headers = "", body : (String | Bytes)? = nil,
                    resp_body : String | Bytes = "", resp_headers = "", status = 200) : Int64
  CLOCK[0] += 1000
  b = body.is_a?(String) ? body.to_slice : body
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n#{req_headers}\r\n".to_slice,
    body: b, source: Gori::FlowSource::Kind::Proxy))
  rb = resp_body.is_a?(String) ? resp_body.to_slice : resp_body
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} OK\r\n#{resp_headers}\r\n".to_slice, body: rb))
  id
end

private def resolve(store, descriptor : String, policy : PF::Policy = PF::Policy.new, **opts) : PF::Resolved
  PF.resolve(store, PF.parse(descriptor).apply(policy), **opts)
end

private def values(store, descriptor : String, policy : PF::Policy = PF::Policy.new) : Array(String)
  resolve(store, descriptor, policy).values
end

private def refuses(pattern : Regex, &)
  yield
  fail "expected PayloadFrom::Error matching #{pattern.inspect}"
rescue ex : PF::Error
  ex.message.to_s.should match(pattern)
end

describe Gori::PayloadFrom do
  describe ".parse" do
    it "splits the QL from the projection, which is the last word" do
      s = PF.parse("host:api.example method:POST param-names")
      s.query.should eq("host:api.example method:POST")
      s.projection.should eq(PF::Projection::ParamNames)
      s.rule.should be_nil
      s.label.should eq("host:api.example method:POST param-names")
    end

    it "reads a lone projection as every flow" do
      s = PF.parse("  path-segments ")
      s.query.should eq("")
      s.projection.should eq(PF::Projection::PathSegments)
      s.label.should eq("path-segments")
    end

    it "keeps a QL value with spaces when it is quoted" do
      PF.parse(%(path:"/a b" c:d param-values)).query.should eq(%(path:"/a b" c:d))
    end

    it "does not take a projection word inside a quoted phrase for the projection" do
      refuses(/does not end in a projection/) { PF.parse(%(body:"asks for param-names")) }
    end

    it "names one extract rule with extracted:NAME" do
      s = PF.parse("host:x extracted:csrf")
      s.projection.should eq(PF::Projection::Extracted)
      s.rule.should eq("csrf")
      s.label.should eq("host:x extracted:csrf")
      PF.parse("extracted").rule.should be_nil
    end

    it "refuses a missing or unknown projection and says what is expected" do
      refuses(/expected `<QL> <projection>`.*param-names, param-values, path-segments, js-endpoints, extracted/) { PF.parse("host:api") }
      refuses(/does not end in a projection/) { PF.parse("host:api params") }
      refuses(/empty payload source/) { PF.parse("   ") }
      refuses(/needs the name of an extract rule/) { PF.parse("extracted:") }
      refuses(/only `extracted` takes a `:name`/) { PF.parse("param-names:x") }
    end

    it "is case-insensitive about the projection only" do
      PF.parse("Host:Api PARAM-NAMES").projection.should eq(PF::Projection::ParamNames)
    end
  end

  describe "the selection" do
    it "reads the flows the QL picks" do
      with_store do |store|
        pf_flow(store, "/a?apple=1", host: "one.test")
        pf_flow(store, "/b?berry=1", host: "two.test")
        values(store, "host:one.test param-names").should eq(["apple"])
        values(store, "host:two.test param-names").should eq(["berry"])
        values(store, "param-names").sort!.should eq(["apple", "berry"])
      end
    end

    it "refuses a field QL does not have, rather than free-texting it into a wider run" do
      with_store do |store|
        pf_flow(store, "/a?apple=1")
        refuses(/unknown field `methd:` — did you mean `method:`/) { values(store, "methd:GET param-names") }
        refuses(/unknown field `hsot~`/) { values(store, "hsot~x param-names") }
      end
    end

    it "refuses a term QL would silently drop, and a regex that would match nothing" do
      with_store do |store|
        pf_flow(store, "/a?apple=1")
        # every term dropped: refused as matching nothing
        refuses(/matched no QL term/) { values(store, "status:>=oops param-names") }
        # one applied, one dropped: the drop would BROADEN the selection to the whole host
        refuses(/silently drop and so select MORE flows than written: status:>=oops/) { values(store, "host:api.test status:>=oops param-names") }
        refuses(/regex term\(s\) failed to compile/) { values(store, "path~[bad param-names") }
      end
    end

    it "answers a `scope:` term through the project's own scope rules" do
      with_store do |store|
        pf_flow(store, "/a?inscope=1", host: "in.test")
        pf_flow(store, "/b?outscope=1", host: "out.test")
        store.add_scope_rule("include", "host", "in.test")
        values(store, "scope:in param-names").should eq(["inscope"])
        values(store, "scope:out param-names").should eq(["outscope"])
      end
    end

    it "is deterministic: newest flow first, first sighting keeps its place" do
      with_store do |store|
        pf_flow(store, "/a?zeta=1&alpha=1")
        pf_flow(store, "/b?mid=1&zeta=2")
        pf_flow(store, "/c?newest=1")
        first = values(store, "param-names")
        first.should eq(["newest", "mid", "zeta", "alpha"])
        values(store, "param-names").should eq(first)
      end
    end

    it "drains the search index first by default, and a live surface that will not gets the backlog on the report" do
      with_store do |store|
        store.pause_background_index # otherwise the idle indexer races the example
        pf_flow(store, "/a?apple=1", resp_body: "the needle is here")
        store.fts_backlog.should be >= 1
        # the TUI's way: no drain, so the unindexed flow is invisible to `body:` — and SAID to be
        live = resolve(store, "body:needle param-names", drain_fts: false)
        live.values.should be_empty
        live.report.fts_backlog.should be >= 1
        live.report.summary.should contain("search index is")
        # the one-shot way: drain, then read
        drained = resolve(store, "body:needle param-names")
        drained.values.should eq(["apple"])
        drained.report.fts_backlog.should eq(0)
      end
    end

    it "refuses, rather than answer from a partial index, when a read-only project cannot drain" do
      path = File.tempname("gori-pf-ro", ".db")
      begin
        rw = Gori::Store.open(path)
        rw.pause_background_index
        pf_flow(rw, "/a?apple=1", resp_body: "the needle is here")
        rw.close
        ro = Gori::Store.open(path, read_only: true)
        begin
          ro.fts_backlog.should be >= 1
          refuses(/not yet indexed for the free-text term/) { values(ro, "body:needle param-names") }
          values(ro, "param-names").should eq(["apple"]) # a selection that does not read the index is unaffected
        ensure
          ro.close
        end
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end

    it "reads a body: query through the drained search index" do
      with_store do |store|
        pf_flow(store, "/a?apple=1", resp_body: "the needle is here")
        pf_flow(store, "/b?berry=1", resp_body: "nothing")
        values(store, "body:needle param-names").should eq(["apple"])
      end
    end
  end

  describe "param-names" do
    it "reads query, form, JSON and multipart names by default, JSON as its leaf member" do
      with_store do |store|
        pf_flow(store, "/q?qa=1&qb=2")
        pf_flow(store, "/f", method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n", body: "fa=1&fb=2")
        pf_flow(store, "/j", method: "POST", req_headers: "Content-Type: application/json\r\n",
          body: %({"user":{"email":"a@b.c","id":7},"tags":["x"]}))
        names = values(store, "param-names")
        %w[qa qb fa fb email id].each { |n| names.should contain(n) }
        names.should_not contain("user.email") # the leaf, what Miner's Json location injects
      end
    end

    it "leaves cookies and headers out by default, and reads them when a policy names them" do
      with_store do |store|
        pf_flow(store, "/a?q=1", req_headers: "Cookie: sid=abc; theme=dark\r\nX-Tenant: acme\r\nAccept: */*\r\n")
        names = values(store, "param-names")
        names.should eq(["q"])
        wide = values(store, "param-names", PF::Policy.new(locations: [Loc::Query, Loc::Cookies, Loc::Headers]))
        wide.should contain("sid") # a cookie NAME is not a secret, whatever its value is
        wide.should contain("theme")
        wide.should contain("x-tenant")
        wide.should_not contain("accept") # a browser's own header is no application input
      end
    end

    it "does not withhold a credential-named field's NAME: a name is not a value" do
      with_store do |store|
        pf_flow(store, "/login", method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
          body: "username=me&password=hunter2")
        r = resolve(store, "param-names")
        r.values.should contain("password")
        r.report.skipped_sensitive.should eq(0)
      end
    end

    it "skips an empty name" do
      with_store do |store|
        pf_flow(store, "/a?=1&real=2")
        values(store, "param-names").should eq(["real"])
      end
    end
  end

  describe "param-values" do
    it "returns values decoded as Params reads them, so a position's rule encodes them once" do
      with_store do |store|
        pf_flow(store, "/s?q=hello%20world&tag=a%2Fb")
        values(store, "param-values").sort!.should eq(["a/b", "hello world"])
      end
    end

    it "keeps a value exactly: padding, a leading #, non-ASCII, invalid UTF-8" do
      with_store do |store|
        pf_flow(store, "/s?a=%20padded%20&b=%23hash&c=%ED%95%9C&d=%FF%FE")
        got = values(store, "param-values")
        got.should contain(" padded ")
        got.should contain("#hash")
        got.should contain("한")
        got.any? { |v| v.to_slice == Bytes[0xff, 0xfe] }.should be_true
      end
    end

    it "keeps a value holding CR, LF or NUL and COUNTS it — dropping it would decide for the operator" do
      with_store do |store|
        pf_flow(store, "/s?a=x%0d%0aInjected%3a%201&b=plain&c=n%00ul")
        r = resolve(store, "param-values")
        r.values.should contain("x\r\nInjected: 1")
        r.values.should contain("n\0ul")
        r.report.framing_values.should eq(2)
      end
    end

    it "skips empty values and multipart file parts" do
      with_store do |store|
        boundary = "BOUNDARY"
        body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhello\r\n" \
               "--#{boundary}\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.bin\"\r\n" \
               "Content-Type: application/octet-stream\r\n\r\nBINARY\r\n--#{boundary}--\r\n"
        pf_flow(store, "/u?blank=&q=1", method: "POST",
          req_headers: "Content-Type: multipart/form-data; boundary=#{boundary}\r\n", body: body)
        got = values(store, "param-values")
        got.sort.should eq(["1", "hello"])
      end
    end

    it "withholds credential-named fields, JWT-shaped values, cookies and credential headers by default, and counts them" do
      with_store do |store|
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        pf_flow(store, "/login?next=/home&session=zzz&ref=#{jwt}", method: "POST",
          req_headers: "Cookie: sid=cookievalue\r\nAuthorization: Bearer headertoken\r\nContent-Type: application/x-www-form-urlencoded\r\n",
          body: "user=me&password=hunter2&token=abc123")
        r = resolve(store, "param-values", PF::Policy.new(locations: [Loc::Query, Loc::Form, Loc::Cookies, Loc::Headers]))
        r.values.sort!.should eq(["/home", "me"])
        r.report.skipped_sensitive.should be >= 5 # password, token, session, the JWT, cookie, header
        r.report.include_sensitive.should be_false
        r.report.policy.should eq("sensitive-excluded")
        r.report.summary.should contain("sensitive skipped")
        r.report.summary.should_not contain("hunter2")
      end
    end

    it "includes them only under the explicit opt-in, and says so" do
      with_store do |store|
        pf_flow(store, "/login?next=/home", method: "POST",
          req_headers: "Cookie: sid=cookievalue\r\nContent-Type: application/x-www-form-urlencoded\r\n",
          body: "user=me&password=hunter2")
        r = resolve(store, "param-values", PF::Policy.new(locations: [Loc::Query, Loc::Form, Loc::Cookies], include_sensitive: true))
        r.values.sort!.should eq(["/home", "cookievalue", "hunter2", "me"])
        r.report.include_sensitive.should be_true
        r.report.policy.should eq("sensitive-included")
        r.report.summary.should contain("SENSITIVE INCLUDED")
        r.report.skipped_sensitive.should eq(0)
      end
    end

    it "skips a value over the length limit and counts it" do
      with_store do |store|
        pf_flow(store, "/s?big=#{"x" * 5000}&ok=fine")
        r = resolve(store, "param-values")
        r.values.should eq(["fine"])
        r.report.skipped_oversize.should eq(1)
      end
    end

    it "de-duplicates, judging each distinct value once" do
      with_store do |store|
        5.times { pf_flow(store, "/s?q=same&r=other") }
        r = resolve(store, "param-values")
        r.values.sort!.should eq(["other", "same"])
        r.report.flows_scanned.should eq(5)
      end
    end
  end

  describe "path-segments" do
    it "reads the path's segments as captured, cutting the query" do
      with_store do |store|
        pf_flow(store, "/api/v1/users/my%20file?x=1")
        pf_flow(store, "https://api.test/api/v2/orders/")
        got = values(store, "path-segments")
        got.sort.should eq(["api", "my%20file", "orders", "users", "v1", "v2"])
        got.should_not contain("x=1")
      end
    end

    it "withholds a segment shaped like a credential unless opted in" do
      with_store do |store|
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        pf_flow(store, "/reset/#{jwt}")
        r = resolve(store, "path-segments")
        r.values.should eq(["reset"])
        r.report.skipped_sensitive.should eq(1)
        values(store, "path-segments", PF::Policy.new(include_sensitive: true)).should contain(jwt)
      end
    end
  end

  describe "js-endpoints" do
    it "reads the stored references of the selected flows, newest source first, and reads nothing else" do
      with_store do |store|
        a = pf_flow(store, "/static/a.js", host: "cdn.test")
        b = pf_flow(store, "/static/b.js", host: "cdn.test")
        other = pf_flow(store, "/other.js", host: "elsewhere.test")
        ref = ->(path : String) { Gori::Store::JsRef.new("https", "api.test", 443, path, path, path, 0, 1, 0, "absolute") }
        store.record_js_scan(a, [ref.call("/api/old"), ref.call("/api/shared")], 1).should be_true
        store.record_js_scan(b, [ref.call("/api/new"), ref.call("/api/shared")], 1).should be_true
        store.record_js_scan(other, [ref.call("/api/unrelated")], 1).should be_true
        r = resolve(store, "host:cdn.test js-endpoints")
        r.values.should eq(["/api/new", "/api/shared", "/api/old"])
        r.report.flows_scanned.should eq(2)
        values(store, "js-endpoints").should contain("/api/unrelated")
      end
    end

    it "says when nothing is stored instead of scanning" do
      with_store do |store|
        pf_flow(store, "/static/a.js", host: "cdn.test")
        r = resolve(store, "js-endpoints")
        r.values.should be_empty
        r.report.note.to_s.should contain("gori run sitemap js --scan")
      end
    end

    # A bundle can hard-code a token into a path. `path-segments` withholds that shape and the
    # docs promise credential material stays out unless asked, so this projection holds to it.
    it "withholds an endpoint with a credential-shaped segment unless opted in" do
      with_store do |store|
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        a = pf_flow(store, "/static/a.js", host: "cdn.test")
        ref = ->(path : String) { Gori::Store::JsRef.new("https", "api.test", 443, path, path, path, 0, 1, 0, "absolute") }
        store.record_js_scan(a, [ref.call("/api/users"), ref.call("/api/reset/#{jwt}")], 1).should be_true
        r = resolve(store, "js-endpoints")
        r.values.should eq(["/api/users"])
        r.report.skipped_sensitive.should eq(1)
        r.report.policy.should eq("sensitive-excluded")
        values(store, "js-endpoints", PF::Policy.new(include_sensitive: true)).should contain("/api/reset/#{jwt}")
      end
    end

    it "honors a stop before it reads, and reports it as a cut read" do
      with_store do |store|
        a = pf_flow(store, "/static/a.js", host: "cdn.test")
        ref = Gori::Store::JsRef.new("https", "api.test", 443, "/api/x", "/api/x", "/api/x", 0, 1, 0, "absolute")
        store.record_js_scan(a, [ref], 1).should be_true
        r = resolve(store, "js-endpoints", stop: -> { true })
        r.values.should be_empty
        r.report.capped_by.should eq(PF::Cap::Flows)
      end
    end

    # The store reads at most JS_REF_READ_MAX references in one query. A cap the read cannot
    # exceed would never see the extra row that proves "there was more", so the report would
    # call a cut list complete; the cap applied is one below, and the report says so.
    it "reports the cap it applied when the store's read limit is below the one asked for" do
      with_store do |store|
        a = pf_flow(store, "/static/a.js", host: "cdn.test")
        ref = Gori::Store::JsRef.new("https", "api.test", 443, "/api/x", "/api/x", "/api/x", 0, 1, 0, "absolute")
        store.record_js_scan(a, [ref], 1).should be_true
        asked = resolve(store, "js-endpoints", PF::Policy.new(max_values: PF::MAX_VALUES))
        asked.report.max_values.should eq(Gori::Store::JS_REF_READ_MAX - 1)
        asked.report.note.to_s.should contain("read #{Gori::Store::JS_REF_READ_MAX - 1} at a time")
        plain = resolve(store, "js-endpoints", PF::Policy.new(max_values: 100))
        plain.report.max_values.should eq(100)
        plain.report.note.should be_nil
      end
    end
  end

  describe ".value_cap" do
    it "is what was asked for, except for js-endpoints, which the store's read limit bounds" do
      asked = PF::Policy.new(max_values: PF::MAX_VALUES)
      PF.value_cap(PF.parse("param-names").apply(asked)).should eq(PF::MAX_VALUES)
      PF.value_cap(PF.parse("path-segments").apply(asked)).should eq(PF::MAX_VALUES)
      js = PF.value_cap(PF.parse("js-endpoints").apply(asked))
      js.should eq(Gori::Store::JS_REF_READ_MAX - 1)
      # The one-past-the-cap row that proves truncation must fit in a single store read.
      (js + 1).should be <= Gori::Store::JS_REF_READ_MAX
      PF.value_cap(PF.parse("js-endpoints").apply(PF::Policy.new(max_values: 5))).should eq(5)
    end
  end

  describe "extracted" do
    it "is refused without the sensitive opt-in, and that is the rule, not a suggestion" do
      with_store do |store|
        store.insert_extract_rule("csrf", "", Gori::ExtractKind::Regex, "token=([a-z0-9]+)")
        pf_flow(store, "/form", resp_body: "token=abc123")
        refuses(/refused unless you say you want them/) { values(store, "extracted") }
      end
    end

    it "re-applies the stored rules to stored responses: regex, header and cookie descriptors" do
      with_store do |store|
        store.insert_extract_rule("csrf", "", Gori::ExtractKind::Regex, "csrf=([a-z0-9]+)")
        store.insert_extract_rule("reqid", "", Gori::ExtractKind::Header, "x-request-id")
        store.insert_extract_rule("sid", "", Gori::ExtractKind::Cookie, "sid")
        pf_flow(store, "/a", resp_body: "csrf=aaa111", resp_headers: "X-Request-Id: r-1\r\nSet-Cookie: sid=s-1; Path=/\r\n")
        pf_flow(store, "/b", resp_body: "csrf=bbb222", resp_headers: "X-Request-Id: r-2\r\n")
        got = values(store, "extracted", PF::Policy.new(include_sensitive: true))
        got.sort.should eq(["aaa111", "bbb222", "r-1", "r-2", "s-1"])
      end
    end

    it "honours a rule's host glob and its own condition, as a live rule does" do
      with_store do |store|
        store.insert_extract_rule("login", "path:/login status:200", Gori::ExtractKind::Regex, "tok=(\\w+)", host: "*.acme.test")
        pf_flow(store, "/login", host: "app.acme.test", resp_body: "tok=hit1")
        pf_flow(store, "/other", host: "app.acme.test", resp_body: "tok=wrongpath")
        pf_flow(store, "/login", host: "app.other.test", resp_body: "tok=wronghost")
        pf_flow(store, "/login", host: "app.acme.test", resp_body: "tok=wrongstatus", status: 500)
        values(store, "extracted", PF::Policy.new(include_sensitive: true)).should eq(["hit1"])
      end
    end

    it "narrows to one rule with extracted:NAME and refuses an unknown or missing rule" do
      with_store do |store|
        pf_flow(store, "/a", resp_body: "a=one b=two")
        refuses(/no enabled extract rule/) { values(store, "extracted", PF::Policy.new(include_sensitive: true)) }
        store.insert_extract_rule("a", "", Gori::ExtractKind::Regex, "a=(\\w+)")
        store.insert_extract_rule("b", "", Gori::ExtractKind::Regex, "b=(\\w+)")
        values(store, "extracted:b", PF::Policy.new(include_sensitive: true)).should eq(["two"])
        refuses(/no enabled extract rule named "nope"/) { values(store, "extracted:nope", PF::Policy.new(include_sensitive: true)) }
      end
    end

    it "ignores a disabled rule and only reads the selected flows" do
      with_store do |store|
        id = store.insert_extract_rule("off", "", Gori::ExtractKind::Regex, "x=(\\w+)", enabled: false)
        id.should be > 0
        store.insert_extract_rule("on", "", Gori::ExtractKind::Regex, "y=(\\w+)")
        pf_flow(store, "/keep", host: "keep.test", resp_body: "x=nope y=yes")
        pf_flow(store, "/skip", host: "skip.test", resp_body: "y=notselected")
        values(store, "host:keep.test extracted", PF::Policy.new(include_sensitive: true)).should eq(["yes"])
      end
    end

    it "never touches the live binding table" do
      with_store do |store|
        store.insert_extract_rule("tok", "", Gori::ExtractKind::Regex, "t=(\\w+)")
        pf_flow(store, "/a", resp_body: "t=secretvalue")
        bindings = Gori::Bindings.load(store)
        values(store, "extracted", PF::Policy.new(include_sensitive: true)).should eq(["secretvalue"])
        bindings.values.should be_empty
        bindings.bound?("tok").should be_false
      end
    end
  end

  describe "bounds" do
    it "stops at the value cap and reports it" do
      with_store do |store|
        20.times { |i| pf_flow(store, "/s?p#{i}=1") }
        r = resolve(store, "param-names", PF::Policy.new(max_values: 5))
        r.values.size.should eq(5)
        r.report.capped_by.should eq(PF::Cap::Values)
        r.report.truncated?.should be_true
        r.report.summary.should contain("stopped at 5 values")
      end
    end

    it "reads only the newest flows up to the flow cap and reports it" do
      with_store do |store|
        10.times { |i| pf_flow(store, "/s?p#{i}=1") }
        r = resolve(store, "param-names", PF::Policy.new(max_flows: 3))
        r.values.should eq(["p9", "p8", "p7"])
        r.report.flows_scanned.should eq(3)
        r.report.capped_by.should eq(PF::Cap::Flows)
      end
    end

    it "reports no cap for a source that ran out of flows first" do
      with_store do |store|
        pf_flow(store, "/s?a=1")
        r = resolve(store, "param-names")
        r.report.capped_by.should be_nil
        r.report.truncated?.should be_false
      end
    end

    it "clamps a policy's caps into the supported range" do
      spec = PF.parse("param-names").apply(PF::Policy.new(max_flows: 999_999_999, max_values: 0))
      spec.max_flows.should eq(PF::MAX_FLOWS)
      spec.max_values.should eq(1)
    end

    it "stops on a `stop` callback and reports the read as cut" do
      with_store do |store|
        5.times { |i| pf_flow(store, "/s?p#{i}=1") }
        n = 0
        r = resolve(store, "param-names", stop: -> { (n += 1) > 2 })
        r.report.capped_by.should eq(PF::Cap::Flows)
        r.values.size.should be < 5
      end
    end
  end

  it "reports what it did without carrying a value" do
    with_store do |store|
      pf_flow(store, "/s?q=needle-value")
      r = resolve(store, "host:api.test param-values")
      s = r.report
      s.source.should eq("host:api.test param-values")
      s.values.should eq(1)
      s.locations.should eq(%w[query form multipart json])
      s.summary.should start_with("host:api.test param-values → 1 value from 1 flow")
      s.summary.should_not contain("needle-value")
    end
  end

  it "makes no request and writes nothing to the project" do
    with_store do |store|
      pf_flow(store, "/s?q=1")
      before = store.count?
      values(store, "param-values")
      values(store, "param-names")
      values(store, "path-segments")
      store.count?.should eq(before)
    end
  end
end
