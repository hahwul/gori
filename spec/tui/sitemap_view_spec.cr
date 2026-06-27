require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-sm", ".db")
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

private def capture(store, host, method, target)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

describe Gori::Tui::SitemapView do
  it "builds and renders a literal host -> path tree" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/api/users/123")
      capture(store, "acme.test", "POST", "/api/orders")
      capture(store, "acme.test", "GET", "/")

      view = SitemapView.new
      view.reload(store)

      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))

      backend.contains?("acme.test").should be_true # host node
      backend.contains?("api").should be_true       # shared segment
      backend.contains?("users").should be_true
      backend.contains?("123").should be_true # literal id (not templated)
      backend.contains?("orders").should be_true
      backend.contains?("POST").should be_true # method annotation on leaf
    end
  end

  it "collapses and expands nodes" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      view = SitemapView.new
      view.reload(store)

      # selection starts at the host node; collapsing it hides children
      view.collapse.should be_true
      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      backend.contains?("acme.test").should be_true
      backend.contains?("users").should be_false # hidden while host collapsed

      view.expand
      backend2 = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend2), Rect.new(0, 0, 70, 20))
      backend2.contains?("users").should be_true
    end
  end

  it "renders an empty-state when nothing is captured" do
    tmp_store do |store|
      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(70, 6)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 6))
      backend.contains?("no traffic captured").should be_true
    end
  end

  it "filters the tree with a QL query" do
    tmp_store do |store|
      capture(store, "api.acme.test", "GET", "/v1/users")
      capture(store, "cdn.acme.test", "GET", "/assets/app.js")

      view = SitemapView.new
      view.reload(store)
      b0 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b0), Rect.new(0, 0, 70, 20))
      b0.contains?("api.acme.test").should be_true
      b0.contains?("cdn.acme.test").should be_true

      # type `host:api` into the QL bar and re-derive the tree
      view.start_query
      "host:api".each_char { |c| view.query_insert(c) }
      view.reload(store)

      b1 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b1), Rect.new(0, 0, 70, 20))
      b1.contains?("api.acme.test").should be_true
      b1.contains?("cdn.acme.test").should be_false
    end
  end

  it "renders the filter bar: scope chip + hint, then the query prompt" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/")
      view = SitemapView.new
      view.reload(store)

      b0 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b0), Rect.new(0, 0, 70, 20))
      b0.contains?("filter").should be_true
      b0.contains?("scope:off").should be_true

      view.start_query
      "host:acme".each_char { |c| view.query_insert(c) }
      b1 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b1), Rect.new(0, 0, 70, 20))
      b1.contains?("query").should be_true
      b1.contains?("host:acme").should be_true
    end
  end

  it "completes a field name with Tab" do
    view = SitemapView.new
    view.start_query
    "met".each_char { |c| view.query_insert(c) }
    view.query_complete.should be_true
    view.querying?.should be_true

    b = MemoryBackend.new(70, 6)
    view.render(Screen.new(b), Rect.new(0, 0, 70, 6))
    b.contains?("method:").should be_true
  end

  it "marks in-scope hosts with a scope glyph even when the ⇧S lens is off" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "cdn.vendor.test", "GET", "/app.js")

      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test") # configured but NOT enabled (lens off)
      scope.active?.should be_false

      view = SitemapView.new
      view.set_scope(scope)
      view.reload(store)

      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      # Lens off ⇒ no filtering: both hosts are visible…
      backend.contains?("acme.test").should be_true
      backend.contains?("cdn.vendor.test").should be_true
      # …but only the in-scope host carries the filled-diamond marker.
      in_row = (0...20).find { |y| backend.row(y).includes?("acme.test") }.not_nil!
      out_row = (0...20).find { |y| backend.row(y).includes?("cdn.vendor.test") }.not_nil!
      backend.row(in_row).includes?('◆').should be_true
      backend.row(out_row).includes?('◆').should be_false
    end
  end

  it "shows an endpoint count on host rows" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "acme.test", "POST", "/api/orders")
      capture(store, "acme.test", "GET", "/health")

      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      backend.contains?("3 paths").should be_true
    end
  end

  it "colours method chips by verb on endpoint rows" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/users")

      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      backend.contains?("GET").should be_true
      y = (0...20).find { |yy| backend.row(yy).includes?("GET") }.not_nil!
      gx = backend.row(y).index("GET").not_nil!
      backend.fg_at(gx, y).should eq(Theme.method_color("GET")) # not muted
    end
  end

  it "draws tree guide lines for nested nodes" do
    tmp_store do |store|
      capture(store, "a.test", "GET", "/x/y") # nested + a following host ⇒ a │ guide
      capture(store, "b.test", "GET", "/z")

      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      backend.contains?("│").should be_true
    end
  end
end
