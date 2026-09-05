require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `Settings.wrap_lines?` (Preferences ▸ Appearance ▸ Display) OFF. Every pane that opted into
# soft wrap falls back to the model it carried before wrap existed: one drawn row per logical
# line, the tail off the right edge, and the caret dragging the view sideways to reach it.
#
# The panes under test are the ones that own their layout by hand — the History detail and the
# Repeater response — plus the two shared widgets every other wrapping pane is built from
# (`ReadPane`, `TextArea`). What each assertion is really pinning is that the flag reaches ALL
# of: the row generator, the draw's left slice, the caret/selection chrome, and the click
# inverse. Those four disagreeing is the whole failure mode — a pane that scrolls sideways but
# hit-tests as if it hadn't puts the caret on a column the operator never clicked.

private def detail_body_rect(rect : Gori::Tui::Rect) : Gori::Tui::Rect
  Gori::Tui::Rect.new(rect.x + 1, rect.y + 2, {rect.w - 2, 0}.max,
    {rect.bottom - (rect.y + 2), 0}.max)
end

private def resp_body_rect(rect : Gori::Tui::Rect) : Gori::Tui::Rect
  target_h = {rect.h, 3}.min
  content = Gori::Tui::Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
  half = {(content.w - 1) // 2, 1}.max
  Gori::Tui::Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 1}.max, content.h).inset(1, 1)
end

private def response_view(store, body : String) : Gori::Tui::HistoryView
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
    method: "GET", target: "/api", http_version: "HTTP/1.1",
    head: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
    body: body.to_slice, content_type: "text/plain"))
  view = Gori::Tui::HistoryView.new
  view.reload(store)
  view.open_detail(store)
  view.toggle_pane # request → response
  view.set_detail_focus(:body)
  view
end

private def loaded_repeater(body : String) : Gori::Tui::RepeaterView
  view = Gori::Tui::RepeaterView.new
  view.load_blank
  view.focus_pane(:response)
  hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
  view.apply(Gori::Repeater::Result.new(hdr.to_slice, body.to_slice, nil, 1000_i64))
  view
end

# The first BODY line in a response pane's line space (status, header, blank).
private BODY_LI = 3

private def without_wrap(&)
  prev = Gori::Settings.wrap_lines?
  Gori::Settings.wrap_lines = false
  begin
    yield
  ensure
    Gori::Settings.wrap_lines = prev
  end
end

describe "wrap_lines off" do
  # The Burp-style wrap numbers the FIRST visual row of a line and blanks the gutter on its
  # continuations. With wrap off there are no continuations at all: the row under a long line
  # is the NEXT line, so it carries a number of its own.
  it "draws one row per logical line in the History detail, and clips the tail" do
    without_wrap do
      with_store do |store|
        view = response_view(store, "HEAD#{"." * 100}TAIL")
        rect = Rect.new(0, 0, 80, 20)
        b = MemoryBackend.new(80, 20)
        view.render_detail(Screen.new(b), rect)
        body = detail_body_rect(rect)
        gw = Gutter.width(4) # status, header, blank, body
        head_row = (0...20).find { |y| b.row(y).includes?("HEAD") }.not_nil!
        b.row(head_row)[body.x, gw].should_not eq(" " * gw)
        # No continuation row was drawn, so nothing is left below the body line to number —
        # and the tail is off the right edge rather than one row down.
        b.row(head_row + 1).strip.should eq("")
        b.contains?("TAIL").should be_false
      end
    end
  end

  # …and the only way to it. This pane has never had an h-scroll binding: ⇧←/→ extends the
  # read selection, so the caret is what pans the view (`ensure_detail_visible_x`).
  it "pans the History detail sideways as the caret walks into the clipped tail" do
    without_wrap do
      with_store do |store|
        view = response_view(store, "HEAD#{"." * 100}TAIL")
        rect = Rect.new(0, 0, 80, 20)
        view.render_detail(Screen.new(MemoryBackend.new(80, 20)), rect)
        BODY_LI.times { view.detail_move(1, 0) }
        view.detail_read.cy.should eq(BODY_LI)
        108.times { view.detail_move(0, 1) } # to the end of "HEAD…TAIL"
        b = MemoryBackend.new(80, 20)
        view.render_detail(Screen.new(b), rect)
        b.contains?("TAIL").should be_true # scrolled into view
        b.contains?("HEAD").should be_false
      end
    end
  end

  # The click inverse has to consume the same offset the draw did. Without that it lands
  # `xscroll` columns early — the caret sits on a character the operator did not point at.
  it "round-trips a click on a sideways-panned History detail row" do
    without_wrap do
      with_store do |store|
        view = response_view(store, "0123456789" * 15) # 150 chars, one body line
        rect = Rect.new(0, 0, 80, 20)
        view.render_detail(Screen.new(MemoryBackend.new(80, 20)), rect)
        body = detail_body_rect(rect)
        gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
        cw = body.w - gw
        BODY_LI.times { view.detail_move(1, 0) }
        149.times { view.detail_move(0, 1) } # drag the view to the line's end
        view.render_detail(Screen.new(MemoryBackend.new(80, 20)), rect)
        xs = 150 - cw # the caret's column minus one screenful
        view.detail_click_to_cursor(body, body.x + gw + 2, body.y + BODY_LI, focused: true)
        view.detail_read.cy.should eq(BODY_LI)
        view.detail_read.cx.should eq(xs + 2)
      end
    end
  end

  # ↓ steps a VISUAL row under wrap; with wrap off a visual row IS a logical line, so the same
  # press must move a whole line — not stall on a continuation row that is no longer drawn.
  it "steps the History detail caret by logical lines" do
    without_wrap do
      with_store do |store|
        view = response_view(store, "#{"z" * 400}\nSENTINEL")
        rect = Rect.new(0, 0, 80, 14)
        view.render_detail(Screen.new(MemoryBackend.new(80, 14)), rect)
        BODY_LI.times { view.detail_move(1, 0) }
        view.detail_read.cy.should eq(BODY_LI)
        view.detail_move(1, 0)
        view.detail_read.cy.should eq(BODY_LI + 1) # SENTINEL, one press away
      end
    end
  end

  it "draws one row per logical line in the Repeater response, and pans to the tail" do
    without_wrap do
      view = loaded_repeater("HEAD#{"." * 80}TAIL")
      rect = Rect.new(0, 0, 80, 20)
      b = MemoryBackend.new(80, 20)
      view.render(Screen.new(b), rect)
      body = resp_body_rect(rect)
      head_row = (0...20).find { |y| b.row(y).includes?("HEAD") }.not_nil!
      b.row(head_row + 1)[body.x, body.w].strip.should eq("")
      b.contains?("TAIL").should be_false
      # The caret pans it in, exactly as in the History detail.
      BODY_LI.times { view.resp_move(1, 0) }
      88.times { view.resp_move(0, 1) }
      b2 = MemoryBackend.new(80, 20)
      view.render(Screen.new(b2), rect)
      b2.contains?("TAIL").should be_true
    end
  end

  it "round-trips a click on a sideways-panned Repeater response row" do
    without_wrap do
      view = loaded_repeater("0123456789" * 12) # 120 chars, one body line
      rect = Rect.new(0, 0, 80, 20)
      view.render(Screen.new(MemoryBackend.new(80, 20)), rect)
      body = resp_body_rect(rect)
      gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
      cw = body.w - gw
      BODY_LI.times { view.resp_move(1, 0) }
      119.times { view.resp_move(0, 1) }
      view.render(Screen.new(MemoryBackend.new(80, 20)), rect)
      xs = 120 - cw
      view.resp_click_to_cursor(rect, body.x + gw + 2, body.y + BODY_LI)
      view.resp_cursor.cy.should eq(BODY_LI)
      view.resp_cursor.cx.should eq(xs + 2)
    end
  end

  # `ReadPane` is what the Decoder output, the Intercept preview, Probe AFFECTED, the OAST
  # callback detail and the Rewriter preview are all built from — one flag, five panes.
  it "gives a ReadPane one row per line and a caret-following h-scroll" do
    pane = ReadPane.new(gutter: true, wrap: true)
    pane.source(["HEAD#{"." * 60}TAIL", "second"])
    rect = Rect.new(0, 0, 40, 6)
    without_wrap do
      b = MemoryBackend.new(40, 6)
      pane.render(Screen.new(b), rect, focused: true)
      pane.last_rows.size.should eq(2) # one per LINE, not per wrapped row
      pane.xscroll.should eq(0)
      b.contains?("TAIL").should be_false
      68.times { pane.move(0, 1) } # walk the caret to the line's end
      b2 = MemoryBackend.new(40, 6)
      pane.render(Screen.new(b2), rect, focused: true)
      pane.xscroll.should be > 0
      b2.contains?("TAIL").should be_true
    end
    # Back on, the same pane re-wraps and drops the offset it was holding.
    b3 = MemoryBackend.new(40, 6)
    pane.render(Screen.new(b3), rect, focused: true)
    pane.xscroll.should eq(0)
    pane.last_rows.size.should be > 2
  end

  # An END-OF-LINE caret sits one column past the last char, and the pane has to keep a cell for
  # it in BOTH modes. It survived neither at first: a per-frame clamp against the widest visible
  # row capped the offset at `widest - cw`, one column short, so pressing End on the longest line
  # on screen scrolled the caret off the pane and painted nothing. `ensure_*_visible_x` is the
  # only writer of the offset now, for exactly that reason.
  it "keeps the block caret on screen at end-of-line in both modes" do
    with_store do |store|
      view = response_view(store, "HEAD#{"." * 100}TAIL")
      rect = Rect.new(0, 0, 80, 20)
      {true, false}.each do |wrap|
        prev = Gori::Settings.wrap_lines?
        Gori::Settings.wrap_lines = wrap
        begin
          view.goto_detail_line(1)
          view.render_detail(Screen.new(MemoryBackend.new(80, 20)), rect)
          BODY_LI.times { view.detail_move(1, 0) }
          view.detail_line_edge(1) # End
          b = MemoryBackend.new(80, 20)
          view.render_detail(Screen.new(b), rect)
          body = detail_body_rect(rect)
          carets = 0
          (body.y...20).each do |y|
            (body.x...80).each { |x| carets += 1 if b.bg_at(x, y) == Theme.accent_bg }
          end
          carets.should eq(1) # exactly one block caret, and it is inside the pane
        ensure
          Gori::Settings.wrap_lines = prev
        end
      end
    end
  end

  # The ^F overdraw on a line whose `¦chain` is concealed. The h-scrolled branch used to mark
  # the RAW line while the draw had DELETED the concealed run, so every hit past a marker was
  # painted a second time, `run.size` columns right of the real one. It was unreachable while
  # wrap was a per-editor constant (both editors with conceal wrap); the Display toggle sends
  # them down that branch, and both branches now go through the one conceal-aware marker.
  it "does not paint a phantom search hit past a concealed run with wrap off" do
    area = TextArea.new("PRE§v¦base64-encode§POST")
    area.wrap = true
    area.conceal_spans = [{5, 19}] # ¦base64-encode
    area.search_hl = "POST"
    without_wrap do
      b = MemoryBackend.new(60, 3)
      area.render(Screen.new(b), Rect.new(0, 0, 60, 3), cursor: false, highlight: :request)
      row = b.row(0).rstrip
      row.should eq("PRE§v§POST")                                       # the chain is hidden
      (0...60).count { |x| b.bg_at(x, 0) == Theme.yellow }.should eq(4) # exactly one "POST"
      (6...10).each { |x| b.bg_at(x, 0).should eq(Theme.yellow) }       # …at the drawn columns
    end
  end

  # `TextArea`'s wrapping editors (the Repeater request, the Fuzzer template, Notes, the
  # Project description, Issue notes) each REPLACED a `follow_x` pan when they started
  # wrapping, and the h-scroll bindings went with it. With wrap off, follow_x has to come back
  # unasked or the tail of a long line is unreachable in both models at once.
  it "restores a wrapping TextArea's caret-following h-scroll" do
    area = TextArea.new
    area.wrap = true
    area.set_text("HEAD#{"." * 60}TAIL")
    rect = Rect.new(0, 0, 30, 4)
    without_wrap do
      area.end_of_line
      b = MemoryBackend.new(30, 4)
      area.render(Screen.new(b), rect, cursor: true)
      area.last_rows.size.should eq(1)
      b.contains?("TAIL").should be_true
      b.contains?("HEAD").should be_false
    end
    b2 = MemoryBackend.new(30, 4)
    area.render(Screen.new(b2), rect, cursor: true)
    area.last_rows.size.should be > 1 # wrapped again
    b2.contains?("HEAD").should be_true
  end
end
