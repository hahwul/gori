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

# Three holds so a mark range can both grow and shrink; queue order is the hold order.
private def three_holds(ic)
  %w[/one /two /three].each do |p|
    hold_req(ic, "acme.test", p, "GET #{p} HTTP/1.1\r\nHost: acme.test\r\n\r\n")
  end
  InterceptView.new.tap(&.reload(ic))
end

# A held WebSocket message (#500 step 2). `enqueue_ws` rather than a blocking hold: the WS
# gate never blocks its pump, so nothing here waits on a decision either.
private def hold_ws(ic, payload : String | Bytes, to_server = true, binary = false)
  bytes = payload.is_a?(String) ? payload.to_slice : payload
  ic.enqueue_ws(bytes, to_server: to_server, method: "GET", target: "/ws", host: "echo.test",
    port: 80, scheme: "http", flow_id: 5_i64, binary: binary).not_nil!
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
        listen: {"127.0.0.1", 8070}, capturing: true)
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

  it "vscroll_detail scrolls a held body taller than the pane into view (PgUp/PgDn)" do
    tmp_interceptor do |ic|
      filler = (1..20).map { |i| "X-#{i}: v#{i}" }.join("\r\n")
      raw = "GET /login HTTP/1.1\r\nHost: acme.test\r\nX-Top: TOPMARK\r\n#{filler}\r\nX-Bot: BOTMARK\r\n\r\n"
      hold_req(ic, "acme.test", "/login", raw)
      view = InterceptView.new
      view.reload(ic)

      rect = Rect.new(0, 0, 100, 8) # short pane: the ~25-line held head overflows it
      backend = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend), rect)
      backend.contains?("TOPMARK").should be_true
      backend.contains?("BOTMARK").should be_false # below the fold

      30.times { view.vscroll_detail(1) } # scroll well past the end (render clamps)
      backend2 = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend2), rect)
      backend2.contains?("BOTMARK").should be_true
      backend2.contains?("TOPMARK").should be_false # scrolled off the top
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

  it "labels a held item with the EDITED method, not the stale hold-time one" do
    tmp_interceptor do |ic|
      hold_req(ic, "acme.test", "/finalcheck", "GET /finalcheck HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      view = InterceptView.new
      view.reload(ic)
      view.toggle_edit
      it = view.selected_item.not_nil!
      # change the method GET → PUT (cursor starts at 0,0)
      3.times { view.edit_move(0, 1) } # move past "GET"
      3.times { view.edit_backspace }  # delete "GET"
      "PUT".each_char { |c| view.edit_insert(c) }

      method, target = view.effective_method_target(it)
      method.should eq("PUT") # edited value (was the stale "GET")
      target.should eq("/finalcheck")
      String.new(view.forward_bytes(it)).should start_with("PUT /finalcheck") # what's actually sent
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

describe "Intercept marks (multi-select)" do
  it "marks the cursor row with `t` and steps down, so a run of `t` marks consecutive holds" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      view.mark_count.should eq(0)
      ids = [] of Int64
      2.times { ids << view.selected_id.not_nil!; view.toggle_mark }
      view.mark_count.should eq(2)
      view.marked_ids.should eq(ids)   # queue order, not toggle order
      view.selected_index.should eq(2) # stepped past both, ready for a third
    end
  end

  # The step clamps at the last row, so `t` there is a plain toggle: press it twice and the
  # mark you just placed comes back off. That is deliberate — it is the ONLY way `t` can
  # un-mark the bottom hold, and the gutter bar shows the state the whole time.
  it "re-toggles the bottom hold once the cursor has nowhere left to step" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      3.times { view.toggle_mark } # marks all three, cursor clamped on the last
      view.mark_count.should eq(3)
      view.selected_index.should eq(2)
      view.toggle_mark # a fourth press is now over an already-marked row
      view.mark_count.should eq(2)
    end
  end

  it "un-marks on a second `t` over the same hold" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      id = view.selected_id.not_nil!
      view.toggle_mark     # marks row 0, cursor → row 1
      view.select_index(0) # back onto it
      view.marked?(id).should be_true
      view.toggle_mark
      view.marked?(id).should be_false
      view.mark_count.should eq(0)
    end
  end

  it "⇧T marks the whole queue and target_ids falls back to the cursor row when clear" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      # No marks: every batch verb acts on the cursor row alone.
      view.target_ids.should eq([view.selected_id.not_nil!])
      view.mark_all
      view.mark_count.should eq(3)
      view.target_ids.should eq(view.marked_ids)
      view.clear_marks
      view.mark_count.should eq(0)
      view.target_ids.size.should eq(1)
    end
  end

  it "extends a contiguous range from the anchor, and gives rows back as it shrinks" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      view.extend_marks(1) # anchor seeds at row 0, cursor → row 1
      view.mark_count.should eq(2)
      view.extend_marks(1) # → row 2
      view.mark_count.should eq(3)
      view.extend_marks(-1) # back to row 1: the third row is handed back
      view.mark_count.should eq(2)
      view.selected_index.should eq(1)
    end
  end

  it "keeps a deliberate `t` mark that a shrinking range sweeps back off" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      view.select_index(2)
      tagged = view.selected_id.not_nil!
      view.toggle_mark # a deliberate tag on the LAST row (cursor clamps there)
      view.select_index(0)
      view.extend_marks(1)
      view.extend_marks(1) # range now covers all three, incl. the tagged row
      view.mark_count.should eq(3)
      view.extend_marks(-1)
      view.extend_marks(-1)               # range collapses back to row 0 only
      view.marked?(tagged).should be_true # the tag was never the gesture's to drop
      view.mark_count.should eq(2)
    end
  end

  it "end_mark_gesture hands back only what the ⇧arrow gesture added" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      view.select_index(2)
      view.toggle_mark # deliberate tag
      view.select_index(0)
      view.extend_marks(1) # gesture marks rows 0+1
      view.mark_count.should eq(3)
      view.end_mark_gesture.should eq(2) # …only those two go back
      view.mark_count.should eq(1)
      view.end_mark_gesture.should eq(0) # nothing left to hand back → the caller stays quiet
    end
  end

  it "prunes a mark when its hold leaves the queue (forwarded here or by a peer)" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      view.mark_all
      gone = view.marked_ids.first
      ic.forward(gone) # e.g. an MCP peer's intercept_forward
      view.reload(ic)
      view.mark_count.should eq(2)
      view.marked?(gone).should be_false
      view.item_by_id(gone).should be_nil
    end
  end

  it "renders a marked row with the fuller gutter bar and a live count chip" do
    tmp_interceptor do |ic|
      view = three_holds(ic)
      view.select_index(1)
      view.toggle_mark # mark the MIDDLE hold, so it isn't also the cursor row
      view.select_index(0)

      backend = MemoryBackend.new(100, 12)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 12))
      backend.row(0).includes?("1 marked").should be_true # chip on the filter bar
      # Queue rows start under the filter bar + the card's top border.
      backend.row(2).includes?('▎').should be_true # cursor row: the thin bar
      backend.row(3).includes?('▌').should be_true # marked row: the full bar
      backend.row(4).includes?('▌').should be_false
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

  it "Tab-completes the condition and shows a suggestion row while editing" do
    tmp_interceptor do |ic|
      view = InterceptView.new
      view.reload(ic)
      view.start_query

      # Cold start: nothing typed, so the row carries the standing field hint.
      backend = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 8))
      backend.row(1).includes?("fields:").should be_true

      "me".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should eq(["method:"])
      view.query_complete.should be_true
      view.query.should eq("method:")

      "P".each_char { |c| view.query_insert(c) }
      backend = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 8))
      backend.row(0).includes?("method:P").should be_true    # the input line
      backend.row(1).includes?("method:POST").should be_true # the ↹ row below it
      view.query_complete.should be_true
      view.query.should eq("method:POST")
    end
  end

  it "pushes the queue down by the suggestion row only while the condition is being edited" do
    # The suggestion row grows the bar, so render() and every hit-test must agree on
    # the offset — a stale FILTER_BAR_H would leave clicks selecting the wrong row.
    tmp_interceptor do |ic|
      hold_req(ic, "acme.test", "/login", "GET /login HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      view = InterceptView.new
      view.reload(ic)

      backend = MemoryBackend.new(100, 12)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 12))
      idle_row = (0...12).find { |y| backend.row(y).includes?("QUEUE (1)") }

      view.start_query
      backend = MemoryBackend.new(100, 12)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 12))
      query_row = (0...12).find { |y| backend.row(y).includes?("QUEUE (1)") }

      idle_row.should_not be_nil
      query_row.should eq(idle_row.not_nil! + 1)
      # And the click hit-test follows the same offset (row 0 of the queue card).
      view.list_row_at(Rect.new(0, 0, 100, 12), 3, query_row.not_nil! + 1).should eq(0)
    end
  end

  it "highlights the condition's operators, fields and grouping while editing" do
    tmp_interceptor do |ic|
      view = InterceptView.new
      view.reload(ic)
      view.start_query
      q = "(host:a OR host:b) -method:GET"
      q.each_char { |c| view.query_insert(c) }

      backend = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 8))
      row = backend.row(0)
      base = row.index(q).not_nil!
      at = ->(needle : String) { backend.fg_at(base + q.index(needle).not_nil!, 0) }

      at.call("(").should eq(Theme.syn_keyword)       # grouping
      at.call("OR").should eq(Theme.syn_keyword)      # operator
      at.call("-method").should eq(Theme.syn_keyword) # `-` is NOT, so it matches
      at.call("host:").should eq(Theme.syn_header)    # field prefix
      at.call("GET").should eq(Theme.text_bright)     # the value being matched
    end
  end

  it "colours by how the query PARSES, not by how it looks" do
    # A lowercase `or` and a paren inside a value are not operators, so they must not be
    # painted as any. This is the property that makes the colour trustworthy.
    tmp_interceptor do |ic|
      view = InterceptView.new
      view.reload(ic)
      view.start_query
      q = "path:/a(b) or x"
      q.each_char { |c| view.query_insert(c) }

      backend = MemoryBackend.new(100, 8)
      view.render(Screen.new(backend), Rect.new(0, 0, 100, 8))
      base = backend.row(0).index(q).not_nil!
      backend.fg_at(base + q.index("(b)").not_nil!, 0).should eq(Theme.text_bright) # part of the value
      backend.fg_at(base + q.index("or").not_nil!, 0).should eq(Theme.text_bright)  # free text, not OR
      backend.fg_at(base + q.index("path:").not_nil!, 0).should eq(Theme.syn_header)
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

  it "re-anchors selection by item id when an earlier queue entry is dropped" do
    # Index-only clamp would keep @selected=1 after dropping index 0, landing a
    # different hold. Id re-anchor keeps the same item under the cursor.
    tmp_interceptor do |ic|
      hold_req(ic, "a.test", "/first", "GET /first HTTP/1.1\r\nHost: a.test\r\n\r\n")
      hold_req(ic, "b.test", "/second", "GET /second HTTP/1.1\r\nHost: b.test\r\n\r\n")
      hold_req(ic, "c.test", "/third", "GET /third HTTP/1.1\r\nHost: c.test\r\n\r\n")
      view = InterceptView.new
      view.reload(ic)
      view.move(1) # select second
      keep_id = view.selected_id.not_nil!
      view.selected_item.not_nil!.target.should eq("/second")

      first_id = ic.pending.first.id
      ic.drop(first_id)
      view.reload(ic)

      view.selected_id.should eq(keep_id)
      view.selected_item.not_nil!.target.should eq("/second")
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

  describe "a held WebSocket message (#500 step 2)" do
    it "renders a WS badge, the socket, and the payload's first line" do
      tmp_interceptor do |ic|
        hold_ws(ic, %({"op":"subscribe"}))
        view = InterceptView.new
        view.reload(ic)
        backend = MemoryBackend.new(120, 12)
        view.render(Screen.new(backend), Rect.new(0, 0, 120, 12))
        backend.contains?("WS↑").should be_true
        backend.contains?("echo.test/ws").should be_true
        backend.contains?(%({"op":"subscribe"})).should be_true
        # NOT "RES": every Kind branch is an exhaustive `case ... in` now, which is the whole
        # reason the two members could be added — as `kind.request?` ternaries a WS message
        # compiled clean and painted itself as a response.
        backend.contains?("RES").should be_false
        backend.contains?("RESPONSE (held)").should be_false
      end
    end

    it "labels the server → client direction and its own badge" do
      tmp_interceptor do |ic|
        hold_ws(ic, "pushed", to_server: false)
        view = InterceptView.new
        view.reload(ic)
        backend = MemoryBackend.new(120, 12)
        view.render(Screen.new(backend), Rect.new(0, 0, 120, 12))
        backend.contains?("WS↓").should be_true
        backend.contains?("server→client").should be_true
      end
    end

    it "shows a binary message as its size and refuses the editor" do
      tmp_interceptor do |ic|
        hold_ws(ic, Bytes[0x00, 0xFF, 0x10, 0x82], binary: true)
        view = InterceptView.new
        view.reload(ic)
        view.read_only_selection?.should be_true
        view.toggle_edit
        view.editing?.should be_false # refused: the TextArea round trip is lossy on non-UTF-8
        backend = MemoryBackend.new(120, 12)
        view.render(Screen.new(backend), Rect.new(0, 0, 120, 12))
        backend.contains?("<binary, 4 bytes>").should be_true
        backend.contains?("READ-ONLY").should be_true
      end
    end

    it "does NOT splice a Content-Length line into an edited payload" do
      # The trap the design named first: `pending_edit` runs
      # `Fuzz::ContentLength.sync(add_when_missing: true)` on any dirty edit. A WS payload has
      # no head, so `add_when_missing` would append a header LINE into the message body.
      tmp_interceptor do |ic|
        hold_ws(ic, %({"amount":1}))
        view = InterceptView.new
        view.reload(ic)
        view.toggle_edit
        view.replace_editor(%({"amount":9999}))
        edit = view.pending_edit.not_nil!
        String.new(edit[1]).should eq(%({"amount":9999}))
        String.new(edit[1]).should_not contain("Content-Length")
      end
    end

    it "does NOT rewrite bare LF to CRLF in an edited payload" do
      # `Env.expand_wire` normalizes the HEAD's line endings, and a WS payload is all body —
      # so a pretty-printed JSON message would silently change length and content.
      tmp_interceptor do |ic|
        hold_ws(ic, "{\n  \"a\": 1\n}")
        view = InterceptView.new
        view.reload(ic)
        view.toggle_edit
        view.replace_editor("{\n  \"a\": 2\n}")
        edit = view.pending_edit.not_nil!
        String.new(edit[1]).should eq("{\n  \"a\": 2\n}")
        edit[1].should_not contain('\r'.ord.to_u8)
      end
    end

    it "leaves a $ in an edited payload alone — in a body it is a byte, not a reference" do
      tmp_interceptor do |ic|
        hold_ws(ic, %({"sig":"x"}))
        view = InterceptView.new
        view.reload(ic)
        view.toggle_edit
        view.replace_editor(%({"sig":"$NOT_A_VAR"}))
        String.new(view.pending_edit.not_nil![1]).should eq(%({"sig":"$NOT_A_VAR"}))
        view.unresolved_env.should be_empty # ... so a forward is never refused over one
      end
    end

    it "does not re-read its queue label from the edited payload's first line" do
      # `effective_method_target` parses the editor's first line as an HTTP start line. On a
      # WS message that would rewrite the row's own label from the first three
      # space-separated tokens of a JSON blob.
      tmp_interceptor do |ic|
        it_ws = hold_ws(ic, "hello world again")
        view = InterceptView.new
        view.reload(ic)
        view.toggle_edit
        view.replace_editor("DELETE /wiped HTTP/1.1")
        view.effective_method_target(it_ws).should eq({"GET", "/ws"})
      end
    end
  end
end
