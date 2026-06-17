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
end
