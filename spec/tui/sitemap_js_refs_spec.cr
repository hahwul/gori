require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Sitemap tab's side of #1243: after a scan, the paths captured JavaScript references and no
# request reached are drawn as their own `js` rows; `o`/`r` on one resolve to where it was read,
# not to a representative flow (there is none). The engine is spec/js_refs_spec.cr.

private CLOCK = [1_700_000_000_000_000_i64]

private def sj_flow(store, target, body = "", *, host = "shop.test", ctype = "application/json") : Int64
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Type: #{ctype}\r\n\r\n".to_slice,
    body: body.to_slice, content_type: ctype))
  store.flush
  id
end

private def draw(view : SitemapView, w = 70, h = 20) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h))
  backend
end

private def row_with(b : MemoryBackend, text : String, h = 20) : String
  (0...h).map { |y| b.row(y) }.find(&.includes?(text)) || raise "no row with #{text.inspect}"
end

# Put the cursor on the first row whose label is `label`.
private def select_label(view : SitemapView, label : String) : Nil
  draw(view) # the flattened rows are built by a render
  view.row_count.times do |i|
    view.select_index(i)
    return if view.selected_js_ref.try(&.[:path].ends_with?("/#{label}")) || view.selected_endpoint.try(&.[:target].ends_with?("/#{label}"))
  end
  raise "no row #{label}"
end

describe "SitemapView — JavaScript references" do
  it "draws an unrequested path with a js aside, and nothing until a scan ran" do
    with_store do |store|
      sj_flow(store, "/api/users", "[]")
      sj_flow(store, "/app.js", %(fetch("/api/users");fetch("/api/admin")), ctype: "application/javascript")
      view = SitemapView.new
      view.reload(store)
      draw(view).contains?("admin").should be_false
      Gori::JsRefs.scan(store)
      view.reload(store)
      b = draw(view)
      row_with(b, "admin").should end_with(" js ")
      # The captured endpoint keeps its methods and gains no js aside; the host's count is traffic.
      row_with(b, "users").should contain("GET")
      row_with(b, "shop.test").should contain("2 paths")
    end
  end

  it "hides them behind the toggle" do
    with_store do |store|
      sj_flow(store, "/app.js", %(fetch("/api/admin")), ctype: "application/javascript")
      Gori::JsRefs.scan(store)
      view = SitemapView.new
      view.toggle_js_refs
      view.js_refs?.should be_false
      view.reload(store)
      draw(view).contains?("admin").should be_false
    end
  end

  it "answers selected_js_ref only on a path no request reached" do
    with_store do |store|
      sj_flow(store, "/api/users", "[]")
      sj_flow(store, "/app.js", %(fetch("/api/users");fetch("/api/admin")), ctype: "application/javascript")
      Gori::JsRefs.scan(store)
      view = SitemapView.new
      view.reload(store)
      select_label(view, "admin")
      view.selected_js_ref.should eq({host: "shop.test", path: "/api/admin"})
      select_label(view, "users")
      view.selected_js_ref.should be_nil
    end
  end

  it "adds a host only a scope include names, and none while a query narrows the tree" do
    with_store do |store|
      sj_flow(store, "/app.js", %(fetch("https://api.shop.test/v1/me");var n="http://www.w3.org/2000/svg"), ctype: "application/javascript")
      Gori::JsRefs.scan(store)
      store.add_scope_rule("include", "host", "*.shop.test")
      scope = Gori::Scope.load(store)
      view = SitemapView.new
      view.set_scope(scope)
      view.reload(store)
      b = draw(view)
      b.contains?("api.shop.test").should be_true
      b.contains?("www.w3.org").should be_false
      row_with(b, "api.shop.test").should contain(" js ")
      view.start_query
      "path:/app".each_char { |c| view.query_insert(c) }
      view.stop_query
      view.reload(store)
      draw(view).contains?("api.shop.test").should be_false
    end
  end

  it "filters references through the scope lens, which never saw them as flows" do
    with_store do |store|
      sj_flow(store, "/app.js", %(fetch("/api/in");fetch("/private/out")), ctype: "application/javascript")
      Gori::JsRefs.scan(store)
      store.add_scope_rule("include", "host", "shop.test")
      store.add_scope_rule("exclude", "string", "shop.test/private")
      scope = Gori::Scope.load(store)
      scope.toggle unless scope.active?
      view = SitemapView.new
      view.set_scope(scope)
      view.reload(store)
      b = draw(view)
      b.contains?(" in ").should be_true
      b.contains?("private").should be_false
    end
  end
end

# `Runner.new` owns a terminal and appears nowhere under spec/, so the Runner's branching is read
# off the source with comments stripped — the convention issues_primary_flow_spec uses.
private def sitemap_runner_method(name : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "sitemap.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')[/(private )?def #{Regex.escape(name)}\b.*?\n  end/m].not_nil!
end

describe "Runner — `o`/`r` on a JavaScript-only row" do
  it "asks for the reference before the representative flow a js row cannot have" do
    {"sitemap_open_flow", "sitemap_repeater"}.each do |m|
      body = sitemap_runner_method(m)
      js = body.index("selected_js_ref").not_nil!
      ep = body.index("selected_endpoint").not_nil!
      (js < ep).should be_true, "#{m} must try the JavaScript reference first"
    end
  end

  it "builds a BARE GET: no captured credential rides to a URL nobody visited" do
    body = sitemap_runner_method("sitemap_repeater_js")
    body.should contain(%("GET",\n      [] of {String, String}, nil, expand: false))
    body.should_not contain("Cookie")
    body.should_not contain("Authorization")
  end
end

describe "SitemapController.js_scan_toast" do
  it "names new endpoints, caps, failures and a partial run" do
    r = Gori::JsRefs::ScanReport.new(4, 12, 3, 1, 0, 0, 2, true)
    t = SitemapController.js_scan_toast(r)
    t.should start_with("JS scan: 4 responses, 3 new endpoints")
    t.should contain("1 read only to 2 MiB")
    t.should contain("2 NOT recorded")
    t.should contain("more unscanned")
  end
end
