require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def tmp_interceptor(&)
  path = File.tempname("gori-icv", ".db")
  store = Gori::Store.open(path)
  begin
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle # enable
    yield ic
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def hold_req(ic, host, target, raw)
  spawn { ic.hold_request(raw.to_slice, method: "GET", target: target, host: host, port: 80, scheme: "http") }
  Fiber.yield
end

describe Gori::Tui::InterceptView do
  it "renders the held queue with a REQ badge and host+target" do
    tmp_interceptor do |ic|
      hold_req(ic, "acme.test", "/login", "GET /login HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      view = InterceptView.new
      view.reload(ic)
      backend = MemoryBackend.new(100, 12)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 12))
      backend.contains?("QUEUE (1)").should be_true # framed queue pane title
      backend.contains?("REQ").should be_true
      backend.contains?("acme.test/login").should be_true
    end
  end

  it "syntax-highlights the held request bytes in the detail pane" do
    tmp_interceptor do |ic|
      hold_req(ic, "acme.test", "/login", "GET /login HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      view = InterceptView.new
      view.reload(ic)
      backend = MemoryBackend.new(100, 12)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 12))
      # detail pane (right) shows the raw request with the verb coloured
      ry = (0...12).find { |y| backend.row(y).includes?("GET /login HTTP") }.not_nil!
      gx = backend.row(ry).index("GET /login HTTP").not_nil!
      backend.fg_at(gx, ry).should eq(Theme.method_color("GET"))
    end
  end

  it "shows the empty state when nothing is held" do
    tmp_interceptor do |ic|
      view = InterceptView.new
      view.reload(ic)
      backend = MemoryBackend.new(80, 8)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 8))
      backend.contains?("no held messages").should be_true
    end
  end

  it "edits a held request and forwards the edited bytes" do
    tmp_interceptor do |ic|
      hold_req(ic, "acme.test", "/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      view = InterceptView.new
      view.reload(ic)
      view.toggle_edit
      view.editing?.should be_true
      it = view.selected_item.not_nil!

      # unchanged edit round-trips byte-exact
      String.new(view.forward_bytes(it)).should eq("GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")

      ic.forward(it.id, view.forward_bytes(it))
      view.reload(ic)
      view.empty?.should be_true
    end
  end
end

describe "Intercept verbs (P1)" do
  it "binds `i` to intercept.toggle and scopes forward/drop to Intercept" do
    reg = Gori::Verbs.registry
    keymap = Gori::Verb::Keymap.build(reg)
    keymap.lookup(Gori::Verb::Chord.new("i"), Gori::Verb::Scope::Body).should eq("intercept.toggle")
    reg["intercept.forward"].scope.should eq(Gori::Verb::Scope::Intercept)
    reg["intercept.drop"].scope.should eq(Gori::Verb::Scope::Intercept)
    reg["intercept.forward-all"].scope.should eq(Gori::Verb::Scope::Intercept)
  end

  it "maps `3` to the Intercept tab after the Project (leftmost) renumber" do
    reg = Gori::Verbs.registry
    keymap = Gori::Verb::Keymap.build(reg)
    keymap.lookup(Gori::Verb::Chord.new("3"), Gori::Verb::Scope::Body).should eq("tab.intercept")
  end
end
