require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The soft-wrap marks every wrapping pane reports, seen the way a screenshot sees them.
#
# `Screenshot::Mask` cannot find a secret that a soft wrap split across two screen rows unless
# the pane SAID those rows belong together — the cell grid holds glyphs, not line structure.
# So the contract each of the nine row-draw loops signs is exactly this: a continuation row is
# marked, over the pane's CONTENT window (past the gutter, out to the content width), on every
# frame. A pane that stops reporting stops being redactable, and nothing else would notice.
#
# Asserted per PANE rather than per call site: the interesting failure is a window that names
# the wrong columns (the gutter folded in, the diff decoration's two columns subtracted), which
# shows up identically whichever loop drew the row.

# The detail body rect HistoryView derives internally — the pane chip strip and the mode row,
# then a 1-column inset each side. Mirrors `render_detail` (and spec/tui/history_wrap_spec.cr,
# which re-derives it for the same reason: a spec has to aim at a real cell).
private def detail_body_rect(rect : Gori::Tui::Rect) : Gori::Tui::Rect
  Gori::Tui::Rect.new(rect.x + 1, rect.y + 2, {rect.w - 2, 0}.max,
    {rect.bottom - (rect.y + 2), 0}.max)
end

# A flow whose RESPONSE carries `body`, opened on the response pane with the body focused.
private def response_view(store, body : String) : Gori::Tui::HistoryView
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
    method: "GET", target: "/api", http_version: "HTTP/1.1",
    head: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
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

# The gutter is a live Display preference, and it decides where the content window starts —
# so the example that asserts the window has to pin it, and put it back for the next file.
private def with_gutter(&)
  before = Gori::Settings.show_gutter
  Gori::Settings.show_gutter = true
  begin
    yield
  ensure
    Gori::Settings.show_gutter = before
  end
end

private def row_holding(b : MemoryBackend, h : Int32, needle : String) : Int32
  (0...h).find { |y| b.row(y).includes?(needle) }.not_nil!
end

describe "screenshot soft-wrap marks" do
  it "marks a wrapped ReadPane's continuation rows over its content window" do
    pane = ReadPane.new(gutter: true, wrap: true)
    pane.source(["short", "HEAD#{"." * 120}TAIL", "last"])
    # One column wider than the rect: `Frame.scroll_gauge` rides the column right of the
    # content, and a rect flush to the backend edge silently drops it (read_pane_spec).
    b = MemoryBackend.new(41, 10)
    pane.render(Screen.new(b), Rect.new(0, 0, 40, 10), true)

    gw = Gutter.width(3)
    marks = b.snapshot.not_nil!.continuations
    marks.should_not be_empty
    # PAST the gutter and out to the content width — the window `Frame#row_text(y, x0, x1)`
    # will be asked for. A mark that started at rect.x would fold the line numbers into the
    # rejoined text and put a digit in the middle of a secret.
    marks.map(&.x0).uniq!.should eq([gw])
    marks.map(&.x1).uniq!.should eq([40])

    head = row_holding(b, 10, "HEAD")
    tail = row_holding(b, 10, "TAIL")
    ys = marks.map(&.y).sort!
    ys.should_not contain(head)  # the row that STARTS the logical line carries no mark
    ys.first.should eq(head + 1) # …and the row after it does
    ys.should contain(tail)      # right through to the row the line ends on
    # The unwrapped neighbours are untouched: over-marking joins two unrelated lines, which is
    # how a rejoined "line" grows a match that was never on screen.
    ys.should_not contain(row_holding(b, 10, "short"))
    ys.should_not contain(row_holding(b, 10, "last"))
  end

  it "marks the History detail body's continuation rows over its content window" do
    with_gutter do
      with_store do |store|
        view = response_view(store, "HEAD#{"." * 140}TAIL")
        rect = Rect.new(0, 0, 80, 20)
        b = MemoryBackend.new(80, 20)
        view.render_detail(Screen.new(b), rect)

        body = detail_body_rect(rect)
        gw = Gutter.width(4) # status, header, blank, body
        marks = b.snapshot.not_nil!.continuations
        marks.should_not be_empty
        # The DETAIL's content column, not the card's: this pane is inset one column inside the
        # frame, so a mark derived from the rect rather than the body would be one column off
        # and every rejoined line would lose its first character.
        marks.map(&.x0).uniq!.should eq([body.x + gw])
        marks.map(&.x1).uniq!.should eq([body.x + body.w])

        head = row_holding(b, 20, "HEAD")
        ys = marks.map(&.y).sort!
        ys.should_not contain(head)
        ys.first.should eq(head + 1)
        ys.should contain(row_holding(b, 20, "TAIL"))
      end
    end
  end

  it "marks the Project ACTIVITY detail band's continuation rows over its content window" do
    # The tenth site, and the one that had no mark at all: the band wraps the selected event's
    # whole message with `Wrap.layout` and drew its rows without saying they belonged together,
    # so a token split across two of them was invisible to `Mask`'s second pass.
    with_store do |store|
      store.insert_event("bindings", "extract_miss", "warn", "HEAD#{"." * 200}TAIL")
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.reload(Gori::Project.new("p", "/tmp/nonexistent.db"), store)
      view.focus_pane(:activity)
      view.reload_activity(store)
      view.activity_select(0)

      rect = Rect.new(0, 0, 100, 34)
      b = MemoryBackend.new(100, 34)
      view.render(Screen.new(b), rect, focused: true)

      # The band's LAST row: the list row above truncates the message long before `TAIL`, so
      # this needle can only be the wrapped detail.
      tail = row_holding(b, 34, "TAIL")
      marks = b.snapshot.not_nil!.continuations
      # Three rows of band, the two after the first marked as continuing it.
      marks.map(&.y).sort!.should eq([tail - 1, tail])

      mark = marks.find { |s| s.y == tail }.not_nil!
      window = b.snapshot.not_nil!.row_text(tail, mark.x0, mark.x1).rstrip
      # The CONTENT columns: the card's border and its one-column inset are outside the window,
      # so a rejoined line cannot grow a `│` in the middle of a secret.
      window.should end_with("TAIL")
      window.should_not contain("│")
    end
  end

  it "leaves a pane that did not wrap unmarked" do
    # The other half of the contract: a mark means "this row continues the one above", so a
    # pane with nothing to continue must report nothing. Otherwise `Mask`'s wrap pass joins
    # two independent rows and can mask text that was never one value.
    pane = ReadPane.new(gutter: true, wrap: true)
    pane.source(["one", "two", "three"])
    b = MemoryBackend.new(41, 10)
    pane.render(Screen.new(b), Rect.new(0, 0, 40, 10), true)
    b.snapshot.not_nil!.continuations.should be_empty
  end
end
