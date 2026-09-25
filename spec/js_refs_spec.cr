require "./spec_helper"
require "compress/gzip"

private alias JR = Gori::JsRefs

private CLOCK = [1_700_000_000_000_000_i64]

# One captured exchange whose RESPONSE is `body` under `ctype`. `req_headers` go after Host.
private def jr_flow(store : Gori::Store, target : String, body : String | Bytes, *,
                    host = "shop.test", ctype : String? = "application/javascript",
                    req_headers = "", resp_headers = "", status = 200) : Int64
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n#{req_headers}\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  ct = ctype ? "Content-Type: #{ctype}\r\n" : ""
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} OK\r\n#{ct}#{resp_headers}\r\n".to_slice,
    body: body.is_a?(String) ? body.to_slice : body, content_type: ctype))
  store.flush
  id
end

private def lits(text : String, kind = JR::Kind::Js) : Array(JR::Literal)
  JR.literals(text, kind)[0]
end

private def lit(text : String, value : String, kind = JR::Kind::Js) : JR::Literal
  lits(text, kind).find { |l| l.text == value } || raise "no literal #{value.inspect} in #{lits(text, kind).map(&.text)}"
end

private def refs_of(store : Gori::Store) : Array(Gori::Store::JsRefSighting)
  store.js_ref_sightings
end

private def ref_count(store : Gori::Store) : Int64
  store.@db.scalar("SELECT COUNT(*) FROM js_refs").as(Int64)
end

private def marker_count(store : Gori::Store) : Int64
  store.@db.scalar("SELECT COUNT(*) FROM js_ref_scans").as(Int64)
end

private def page(url : String) : Gori::Discover::Url::Parts
  Gori::Discover::Url.parse(url).not_nil!
end

describe Gori::JsRefs do
  describe ".literals" do
    it "finds quoted paths and absolute URLs in a minified bundle, with byte offsets and lines" do
      js = %(!function(){var a="application/json",r=/foo\\/bar/g;\nfetch("/api/v1/users").then(x=>x);\n) +
           %(axios.get('/api/orders');var u="https://api.shop.test/v2/cart";d=2026/07/19})
      found = lits(js)
      found.map(&.text).should eq(["/api/v1/users", "/api/orders", "https://api.shop.test/v2/cart"])
      users = found[0]
      # The offset is the opening quote's BYTE, so a reader can land on it.
      js.byte_slice(users.offset, 15).should eq(%("/api/v1/users"))
      users.line.should eq(2)
      found[2].line.should eq(3)
      found.none?(&.in_comment).should be_true
    end

    it "keeps a template literal's shape past its interpolation instead of cutting to the directory" do
      l = lit(%(fetch(`/api/users/${user.id}/orders?x=1`)), "/api/users/{expr}/orders")
      l.templated.should be_true
      # Nested braces inside the interpolation are balanced, not the end of it.
      lit(%(`/api/t/${fn({a:1})}/x`), "/api/t/{expr}/x").templated.should be_true
      # The URL branch runs through `${`, so it is cut inside the value.
      lit(%(`https://api.shop.test/v2/${ver}/items`), "https://api.shop.test/v2/{expr}/items").templated.should be_true
      # `${` in a QUOTED string is text, not an interpolation.
      lit(%("/api/users/${id}"), "/api/users/").templated.should be_false
      # An interpolation that never closes still marks the reference as templated.
      lit(%(`/api/q/${never), "/api/q/{expr}").templated.should be_true
    end

    it "flags a literal in a comment, and prefers the code occurrence of the same literal" do
      l = lit(%(// fetch("/api/old")\nvar x = 1;), "/api/old")
      l.in_comment.should be_true
      lit(%(/* "/api/block" */), "/api/block").in_comment.should be_true
      both = lit(%(// "/api/twice"\nfetch("/api/twice")), "/api/twice")
      both.in_comment.should be_false
      both.line.should eq(2)
      # A `//` inside a string is not a comment.
      lit(%(var u = "http://x.test/a"; fetch("/api/live")), "/api/live").in_comment.should be_false
    end

    it "answers comment membership by character on a non-ASCII script" do
      js = %(// 한글 주석 "/api/ko-old"\nconst 이름 = "값"; fetch("/api/ko-live"))
      old = lit(js, "/api/ko-old")
      old.in_comment.should be_true
      live = lit(js, "/api/ko-live")
      live.in_comment.should be_false
      js.byte_slice(live.offset, 13).should eq(%("/api/ko-live))
      live.line.should eq(2)
    end

    it "keeps comment membership aligned after a comment that blanked multi-byte characters" do
      # Each blanked 3-byte character shrinks the comment-stripped copy by two bytes, so a byte
      # offset read straight across lands 40 bytes late — past the short comment, in code.
      js = %(// #{"가" * 20}\n// "/api/a2"\nfetch("/api/code-after");)
      lit(js, "/api/a2").in_comment.should be_true
      lit(js, "/api/code-after").in_comment.should be_false
    end

    it "reads only an HTML page's inline executable scripts, offsets into the whole page" do
      html = %(<html><head><script src="/static/app.js"></script>) +
             %(<script type="application/json">{"u":"/json-island"}</script></head>) +
             %(<body><a href="/declared-link">x</a><script>fetch("/api/inline")</script></body></html>)
      found = lits(html, JR::Kind::Html)
      found.map(&.text).should eq(["/api/inline"])
      html.byte_slice(found[0].offset, 12).should eq(%("/api/inline))
    end

    it "stops at MAX_REFS and says so" do
      js = String.build { |io| (JR::MAX_REFS + 5).times { |i| io << %("/api/r#{i}";) } }
      found, capped = JR.literals(js, JR::Kind::Js)
      found.size.should eq(JR::MAX_REFS)
      capped.should be_true
    end
  end

  describe ".kind" do
    it "scans JS and HTML types, and a .js path only when untyped or text/plain" do
      JR.kind("application/javascript; charset=utf-8", "/a").should eq(JR::Kind::Js)
      JR.kind("text/ecmascript", "/a").should eq(JR::Kind::Js)
      JR.kind("text/html", "/").should eq(JR::Kind::Html)
      JR.kind(nil, "/static/main.mjs?v=2").should eq(JR::Kind::Js)
      JR.kind("text/plain", "/app.js").should eq(JR::Kind::Js)
      JR.kind("application/json", "/app.js").should be_nil
      JR.kind("image/png", "/x.png").should be_nil
      JR.kind(nil, "/api/users").should be_nil
    end
  end

  describe ".resolve (P7: page-authored bytes)" do
    base = page("https://shop.test/app/")

    it "percent-encodes a separator and refuses a framing octet" do
      ok = JR.resolve(JR::Literal.new("/my file", 0, 1, false, false), base, JR::Base::Page)
      ok.should be_a(Gori::Store::JsRef)
      ok.as(Gori::Store::JsRef).path.should eq("/my%20file")
      ok.as(Gori::Store::JsRef).target.should_not contain(' ')
      JR.resolve(JR::Literal.new("/a\r\nX-Evil: 1", 0, 1, false, false), base, JR::Base::Page)
        .should eq(JR::Drop::Unsafe)
    end

    it "drops the bare root and static assets, and names absolute references as such" do
      JR.resolve(JR::Literal.new("/", 0, 1, false, false), base, JR::Base::Page).should eq(JR::Drop::Filtered)
      JR.resolve(JR::Literal.new("/img/logo.png", 0, 1, false, false), base, JR::Base::Page).should eq(JR::Drop::Filtered)
      JR.resolve(JR::Literal.new("mailto:x@y.z", 0, 1, false, false), base, JR::Base::Page).should eq(JR::Drop::Unresolvable)
      abs = JR.resolve(JR::Literal.new("//API.Other.test/v1/", 0, 1, false, false), base, JR::Base::Referer)
      abs = abs.as(Gori::Store::JsRef)
      abs.host.should eq("api.other.test")
      abs.path.should eq("/v1") # the node path: trailing slash dropped, as the tree does
      abs.base.should eq("absolute")
    end

    it "keys on the query-less node path and keeps the query for a replay" do
      r = JR.resolve(JR::Literal.new("/api/search?q=", 0, 1, false, false), base, JR::Base::Page).as(Gori::Store::JsRef)
      r.path.should eq("/api/search")
      r.target.should eq("/api/search?q=")
    end
  end

  describe ".scan" do
    it "resolves an external bundle against the page its Referer names, else guesses its own origin" do
      with_store do |store|
        bundle = %(fetch("/api/cart");)
        jr_flow(store, "/assets/app.js", bundle, host: "cdn.test", req_headers: "Referer: https://shop.test/checkout\r\n")
        jr_flow(store, "/assets/other.js", %(fetch("/api/lonely");), host: "cdn.test")
        report = JR.scan(store)
        report.flows_scanned.should eq(2)
        report.refs.should eq(2)
        report.new_endpoints.should eq(2)
        cart = refs_of(store).find! { |r| r.path == "/api/cart" }
        cart.host.should eq("shop.test")
        cart.base.should eq("referer")
        cart.source_url.should eq("https://cdn.test/assets/app.js")
        lonely = refs_of(store).find! { |r| r.path == "/api/lonely" }
        lonely.host.should eq("cdn.test")
        lonely.base.should eq("guessed")
      end
    end

    it "resolves an inline script against the page, honouring <base href>" do
      with_store do |store|
        jr_flow(store, "/docs/page", %(<head><base href="https://app.shop.test/"></head><script>fetch("/api/p")</script>),
          ctype: "text/html")
        refs_of(store).should be_empty
        JR.scan(store)
        r = refs_of(store).first
        r.host.should eq("app.shop.test")
        r.base.should eq("page")
      end
    end

    it "refuses a <base href> that frames, and marks the page origin as a guess (P7)" do
      with_store do |store|
        jr_flow(store, "/p", %(<head><base href="https://evil.test/x&#10;y/"></head><script>fetch("/api/b")</script>),
          ctype: "text/html")
        JR.scan(store)
        r = refs_of(store).first
        r.host.should eq("shop.test")
        r.base.should eq("guessed")
        refs_of(store).none? { |s| s.target.includes?('\n') || s.host.includes?('\n') }.should be_true
      end
    end

    it "keeps the code occurrence when two different literals land on one endpoint" do
      with_store do |store|
        jr_flow(store, "/d.js", %(// fetch("/api/dup/")\nfetch("/api/dup")))
        JR.scan(store)
        r = refs_of(store).first
        r.flags.should eq(0)
        r.literal.should eq("/api/dup")
      end
    end

    it "reads a gzip-encoded bundle through its decoded entity" do
      with_store do |store|
        io = IO::Memory.new
        Compress::Gzip::Writer.open(io) { |gz| gz << %(fetch("/api/zipped")) }
        jr_flow(store, "/z.js", io.to_slice, resp_headers: "Content-Encoding: gzip\r\n")
        JR.scan(store)
        refs_of(store).map(&.path).should eq(["/api/zipped"])
      end
    end

    it "is incremental: a second run reads nothing new, `rescan` reads it again" do
      with_store do |store|
        jr_flow(store, "/a.js", %(fetch("/api/a")))
        JR.scan(store).flows_scanned.should eq(1)
        again = JR.scan(store)
        again.flows_scanned.should eq(0)
        again.new_endpoints.should eq(0)
        JR.scan(store, JR::ScanOptions.new(rescan: true)).flows_scanned.should eq(1)
        ref_count(store).should eq(1)
      end
    end

    it "caps the flows one run reads and says unscanned ones remain" do
      with_store do |store|
        3.times { |i| jr_flow(store, "/c#{i}.js", %(fetch("/api/c#{i}"))) }
        first = JR.scan(store, JR::ScanOptions.new(max_flows: 2))
        first.flows_scanned.should eq(2)
        first.truncated.should be_true
        second = JR.scan(store, JR::ScanOptions.new(max_flows: 2))
        second.flows_scanned.should eq(1)
        second.truncated.should be_false
      end
    end

    it "skips a body that is not JS or HTML, and a pending flow" do
      with_store do |store|
        jr_flow(store, "/data", %({"u":"/api/json"}), ctype: "application/json")
        CLOCK[0] += 1000
        store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: CLOCK[0], scheme: "https", host: "shop.test", port: 443, method: "GET",
          target: "/pending.js", http_version: "HTTP/1.1",
          head: "GET /pending.js HTTP/1.1\r\nHost: shop.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
        failed = jr_flow(store, "/failed.js", "", ctype: nil)
        store.update_response(Gori::Store::CapturedResponse.new(flow_id: failed, status: 0,
          head: Bytes.empty, state: Gori::Store::FlowState::Error, error: "reset"))
        store.flush
        JR.scan(store).flows_scanned.should eq(0)
        marker_count(store).should eq(0) # a pending or failed flow is NOT marked done
      end
    end

    it "flags a body longer than MAX_SCAN as capped and reads its head" do
      with_store do |store|
        body = %(fetch("/api/head");) + (" " * JR::MAX_SCAN) + %(fetch("/api/tail");)
        jr_flow(store, "/big.js", body)
        report = JR.scan(store)
        report.bodies_capped.should eq(1)
        refs_of(store).map(&.path).should eq(["/api/head"])
      end
    end

    it "scans a reused flow id after a history clear (no watermark to fall behind)" do
      with_store do |store|
        first = jr_flow(store, "/a.js", %(fetch("/api/before")))
        JR.scan(store)
        store.clear_flows.should be_true
        ref_count(store).should eq(0)
        marker_count(store).should eq(0)
        reused = jr_flow(store, "/b.js", %(fetch("/api/after")))
        reused.should eq(first) # SQLite hands the rowid out again
        JR.scan(store).flows_scanned.should eq(1)
        refs_of(store).map(&.path).should eq(["/api/after"])
      end
    end
  end

  describe "deleted with their source flow" do
    it "on delete_flow and delete_flows" do
      with_store do |store|
        a = jr_flow(store, "/a.js", %(fetch("/api/a")))
        b = jr_flow(store, "/b.js", %(fetch("/api/b")))
        c = jr_flow(store, "/c.js", %(fetch("/api/c")))
        JR.scan(store)
        store.delete_flow(a).should be_true
        refs_of(store).map(&.path).sort.should eq(["/api/b", "/api/c"])
        store.delete_flows([b, c]).should be_true
        ref_count(store).should eq(0)
        marker_count(store).should eq(0)
      end
    end

    it "on the retention sweep" do
      path = File.tempname("gori-jsrefs-retention", ".db")
      db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
      Gori::Store::Schema.migrate!(db)
      store = Gori::Store.new(db, nil, retention_flows: 2, prune_interval: 1)
      begin
        old = jr_flow(store, "/old.js", %(fetch("/api/old")))
        JR.scan(store)
        refs_of(store).map(&.flow_id).should eq([old])
        3.times { |i| jr_flow(store, "/n#{i}", "x", ctype: "text/css") }
        store.flow_row(old).should be_nil
        ref_count(store).should eq(0)
        marker_count(store).should eq(0)
      ensure
        store.close
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end

    it "on compact's keep_flows" do
      path = File.tempname("gori-jsrefs-compact", ".db")
      begin
        store = Gori::Store.open(path)
        begin
          jr_flow(store, "/old.js", %(fetch("/api/old")))
          JR.scan(store)
          2.times { |i| jr_flow(store, "/n#{i}", "x", ctype: "text/css") }
        ensure
          store.close
        end
        Gori::Store.compact(path, Gori::Store::CompactPlan.new(keep_flows: 2)).not_nil!
        store = Gori::Store.open(path)
        begin
          ref_count(store).should eq(0)
          marker_count(store).should eq(0)
        ensure
          store.close
        end
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end
  end

  describe ".list" do
    it "lists only unrequested references by default, and says which are requested when asked" do
      with_store do |store|
        jr_flow(store, "/api/users", "[]", ctype: "application/json")
        jr_flow(store, "/app.js", %(fetch("/api/users");fetch("/api/admin/");))
        JR.scan(store)
        report = JR.list(store)
        report.endpoints.map(&.path).should eq(["/api/admin"])
        report.endpoints[0].requested.should be_false
        all = JR.list(store, JR::ListOptions.new(include_requested: true))
        all.endpoints.map { |e| {e.path, e.requested} }.should eq([{"/api/admin", false}, {"/api/users", true}])
        report.scanned_flows.should eq(1)
      end
    end

    it "hides a host the project never captured unless a scope include names it" do
      with_store do |store|
        jr_flow(store, "/app.js", %(var ns="http://www.w3.org/2000/svg";fetch("https://api.shop.test/v1/me")))
        JR.scan(store)
        report = JR.list(store)
        report.endpoints.should be_empty
        report.hidden_hosts.should eq(2)
        store.add_scope_rule("include", "host", "*.shop.test")
        scoped = JR.list(store, JR::ListOptions.new, Gori::Scope.load(store))
        scoped.endpoints.map(&.host).should eq(["api.shop.test"])
        JR.list(store, JR::ListOptions.new(all_hosts: true)).endpoints.size.should eq(2)
      end
    end

    it "counts distinct referencing flows and keeps a commented-only reference flagged" do
      with_store do |store|
        jr_flow(store, "/a.js", %(fetch("/api/shared")))
        jr_flow(store, "/b.js", %(fetch("/api/shared");// "/api/dead"))
        JR.scan(store)
        report = JR.list(store)
        shared = report.endpoints.find! { |e| e.path == "/api/shared" }
        shared.flows.should eq(2)
        dead = report.endpoints.find! { |e| e.path == "/api/dead" }
        dead.in_comment.should be_true
        JR.list(store, JR::ListOptions.new(include_comments: false)).endpoints.map(&.path).should eq(["/api/shared"])
      end
    end
  end
end

describe "Gori::Sitemap.attach_js_refs!" do
  it "adds a count to a captured node and grows unrequested nodes, leaving endpoint counts traffic-only" do
    hosts = Gori::Sitemap.build([{"Shop.test", "GET", "/api/users"}])
    before = Gori::Sitemap.endpoint_count(hosts[0])
    refs = [
      Gori::Store::JsRefNode.new("https", "shop.test", 443, "/api/users", 2),
      Gori::Store::JsRefNode.new("https", "shop.test", 443, "/api/admin/keys", 1),
      Gori::Store::JsRefNode.new("https", "other.test", 443, "/x", 1),
    ]
    Gori::Sitemap.attach_js_refs!(hosts, refs) { |r| r.host == "allowed.test" }
    hosts.map(&.label).should eq(["Shop.test"]) # other.test refused by the block
    api = hosts[0].children.find!(&.label.==("api"))
    users = api.children.find!(&.label.==("users"))
    users.js_refs.should eq(2)
    users.unrequested.should be_false
    users.js_only?.should be_false
    admin = api.children.find!(&.label.==("admin"))
    admin.unrequested.should be_true
    keys = admin.children.find!(&.label.==("keys"))
    keys.path.should eq("/api/admin/keys")
    keys.js_only?.should be_true
    keys.methods.should be_empty
    Gori::Sitemap.endpoint_count(hosts[0]).should eq(before)
  end

  it "adds a host the block allows, flagged unrequested" do
    hosts = Gori::Sitemap.build([{"shop.test", "GET", "/"}])
    Gori::Sitemap.attach_js_refs!(hosts, [Gori::Store::JsRefNode.new("https", "api.shop.test", 443, "/v1/me", 1)]) { true }
    api = hosts.find!(&.label.==("api.shop.test"))
    api.unrequested.should be_true
    api.children.first.children.first.path.should eq("/v1/me")
  end
end
