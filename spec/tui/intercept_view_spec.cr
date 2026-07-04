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
      backend = MemoryBackend.new(80, 14)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 14),
        listen: "127.0.0.1:8070", capturing: true)
      backend.contains?("no held messages").should be_true
      backend.contains?("INTERCEPT").should be_true
      backend.contains?("i:CATCH").should be_true
    end
  end

  it "hscroll_detail scrolls a long held-request header sideways into view (shift+←/→)" do
    tmp_interceptor do |ic|
      long_header = "X-Long: HEAD" + ("." * 80) + "TAIL"
      hold_req(ic, "acme.test", "/login", "GET /login HTTP/1.1\r\nHost: acme.test\r\n#{long_header}\r\n\r\n")
      view = InterceptView.new
      view.reload(ic)

      rect = Rect.new(0, 0, 100, 12)
      backend = MemoryBackend.new(100, 12)
      view.render(Screen.new(backend), rect)
      backend.contains?("HEAD").should be_true
      backend.contains?("TAIL").should be_false # off the right edge, clipped

      20.times { view.hscroll_detail(1) } # scroll well past the line's width
      backend2 = MemoryBackend.new(100, 12)
      view.render(Screen.new(backend2), rect)
      backend2.contains?("TAIL").should be_true
      backend2.contains?("HEAD").should be_false # scrolled off the left edge
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

  it "forwards a viewed-but-unedited held body byte-exact (no LF→CRLF rewrite)" do
    tmp_interceptor do |ic|
      raw = "POST /e HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\nline1\nline2" # bare LF in body
      hold_req(ic, "h", "/e", raw)
      view = InterceptView.new
      view.reload(ic)
      it = view.selected_item.not_nil!

      view.toggle_edit # OPEN the editor (view only — no keystroke)
      view.editing?.should be_true
      # Opening to inspect then forwarding must be byte-exact: the bare LF stays a
      # bare LF (the TextArea round-trip would otherwise rewrite it to CRLF).
      String.new(view.forward_bytes(it)).should eq(raw)

      # An actual edit DOES send the edited bytes (line-ending normalization there is
      # an accepted text-editor limitation).
      view.edit_insert('X')
      String.new(view.forward_bytes(it)).should_not eq(raw)
    end
  end

  it "recomputes Content-Length when an edited held body is forwarded (adds one to a GET)" do
    tmp_interceptor do |ic|
      hold_req(ic, "h", "/", "GET / HTTP/1.1\r\nHost: h\r\n\r\n") # no body, no Content-Length
      view = InterceptView.new
      view.reload(ic)
      it = view.selected_item.not_nil!
      view.toggle_edit
      view.edit_move(99, 0) # down to the (empty) body line
      "BODY".each_char { |c| view.edit_insert(c) }

      out = String.new(view.forward_bytes(it))
      out.should contain("Content-Length: 4") # synthesized so the added body is framed
      out.should end_with("\r\n\r\nBODY")
    end
  end
end

describe "Intercept filter bar" do
  it "shows the catch-direction chip and the condition hint" do
    tmp_interceptor do |ic|
      view = InterceptView.new
      view.reload(ic)
      backend = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 8))
      backend.row(0).includes?("c:ALL").should be_true   # default direction chip (c cycles it)
      backend.row(0).includes?("i:CATCH").should be_true # master catch toggle badge
      backend.contains?("/ condition").should be_true    # field hint
    end
  end

  it "reflects the interceptor's catch direction after a cycle" do
    tmp_interceptor do |ic|
      ic.cycle_direction # Both → RequestOnly
      view = InterceptView.new
      view.reload(ic)
      backend = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 8))
      backend.row(0).includes?("c:REQ").should be_true
    end
  end

  it "edits the condition query inline" do
    tmp_interceptor do |ic|
      view = InterceptView.new
      view.reload(ic)
      view.start_query
      view.querying?.should be_true
      "host:acme".each_char { |c| view.query_insert(c) }
      view.query.should eq("host:acme")
      view.query_backspace
      view.query.should eq("host:acm")

      backend = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 8))
      backend.contains?("catch ›").should be_true # editing prompt
      backend.contains?("host:acm").should be_true

      view.cancel_query
      view.querying?.should be_false
      view.query.should eq("")
    end
  end

  it "keeps the queue rendered below the filter bar" do
    tmp_interceptor do |ic|
      hold_req(ic, "acme.test", "/login", "GET /login HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      view = InterceptView.new
      view.reload(ic)
      backend = MemoryBackend.new(100, 12)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 12))
      backend.row(0).includes?("c:ALL").should be_true # bar on the top row
      backend.contains?("QUEUE (1)").should be_true    # queue card still drawn below
      backend.contains?("acme.test/login").should be_true
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

  it "maps `3` to the positional jump verb (Nth visible tab — Intercept by default)" do
    reg = Gori::Verbs.registry
    keymap = Gori::Verb::Keymap.build(reg)
    # Number keys are positional now (digit N → Nth visible tab), handled by nav.pos*; the
    # Runner resolves N to the actual tab. With the default layout the 3rd visible is Intercept.
    keymap.lookup(Gori::Verb::Chord.new("3"), Gori::Verb::Scope::Body).should eq("nav.pos3")
  end
end
