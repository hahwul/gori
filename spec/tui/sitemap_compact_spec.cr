require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def capture(store, target, method = "GET")
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
end

private def rendered(view, w = 80, h = 20)
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h))
  (0...h).map { |y| backend.row(y) }
end

# A single-child folder chain draws as one compact row (VS Code's compact folders).
describe "SitemapView compact folder rows" do
  it "merges a single-child folder chain into one row, the host and the endpoint leaf apart" do
    with_store do |store|
      capture(store, "/api/v3/orgs/42/items")
      view = SitemapView.new
      view.reload(store)
      view.row_count.should eq(3) # acme.test, api/v3/orgs/42, items
      rows = rendered(view)
      rows.any?(&.includes?("api/v3/orgs/42")).should be_true
      rows.any? { |r| r.includes?("acme.test") && r.includes?("api") }.should be_false
      view.select_index(1)
      view.selected_url.should eq("http://acme.test/api/v3/orgs/42")
    end
  end

  it "ends the chain at a folder with its own method or a tag" do
    with_store do |store|
      capture(store, "/api")
      capture(store, "/api/v3/orgs/items")
      view = SitemapView.new
      view.reload(store)
      view.row_count.should eq(4) # acme.test, api (an endpoint), v3/orgs, items

      store.set_sitemap_tag("acme.test", "/api/v3", "memo")
      capture(store, "/b/c/d/x")
      view.reload(store)
      # ... api, v3 (tagged), orgs, items, b/c/d, x
      view.row_count.should eq(7)
    end
  end

  it "collapses a compact row as its deepest node, and marks its full path" do
    with_store do |store|
      capture(store, "/a/b/c/x")
      view = SitemapView.new
      view.reload(store)
      view.select_index(1)
      view.collapse.should be_true
      view.row_count.should eq(2)
      view.toggle_mark
      view.marked_keys.should eq([{"http://acme.test", "/a/b/c"}])
    end
  end

  it "keeps the tree guide for a sibling below a compact row" do
    with_store do |store|
      capture(store, "/a/b/x")
      capture(store, "/d/e/y")
      view = SitemapView.new
      view.reload(store)
      view.row_count.should eq(5) # acme.test, a/b, x, d/e, y
      rows = rendered(view)
      x = rows.find!(&.includes?("▪ x"))
      x[3].should eq('│') # a/b has a following sibling (d/e), so its branch continues
      y = rows.find!(&.includes?("▪ y"))
      y[3].should eq(' ')
    end
  end

  it "middle-truncates a long chain keeping the first and last segments" do
    segs = %w[api v3 organizations 8f3a1c22 workspaces marketing-emea]
    SitemapView.compact_label(segs, 80).should eq(segs.join('/'))
    SitemapView.compact_label(segs, 31).should eq("api/…/workspaces/marketing-emea")
    SitemapView.compact_label(segs, 30).should eq("api/…/marketing-emea")
  end
end
