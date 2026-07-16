require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/comparer_view"

include Gori::Tui

private def flow(method, target, host = "h.test")
  row = Gori::Store::FlowRow.new(
    1_i64, 1_i64, "https", method, host, 443, target,
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/plain")
  head = "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice
  resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nbody".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, resp, "body".to_slice)
end

describe ComparerView do
  it "builds auto labels from slots and prefers a custom name" do
    v = ComparerView.new
    v.label.should eq("empty")
    v.add_flow(flow("GET", "/a"))
    v.label.should contain("GET")
    v.add_flow(flow("POST", "/b"))
    v.label.should contain("⇄")
    v.name = "login vs register"
    v.label.should eq("login vs register")
  end

  it "duplicates slots and appends copy to a custom name" do
    v = ComparerView.new
    v.name = "pair"
    a = flow("GET", "/a")
    b = flow("POST", "/b")
    v.set_slot(:a, a)
    v.set_slot(:b, b)
    v.toggle_pane # request mode
    d = v.duplicate
    d.name.should eq("pair copy")
    d.both_set?.should be_true
    d.pane.should eq(:request)
    d.same?(v).should be_false
  end

  it "reset! clears slots and name" do
    v = ComparerView.new
    v.name = "x"
    v.add_flow(flow("GET", "/z"))
    v.reset!
    v.name.should be_nil
    v.both_set?.should be_false
    v.label.should eq("empty")
  end

  it "projects a sub-tab filter subject across both A/B slots (name + host/method)" do
    v = ComparerView.new
    v.set_slot(:a, flow("GET", "/orders", "app.test"))
    v.set_slot(:b, flow("POST", "/login", "api.test"))
    v.name = "auth pair"
    s = v.filter_subject
    s.name.should eq("auth pair")
    s.target.should contain("app.test")
    s.target.should contain("api.test")
    # End-to-end through the matcher: host:/method: narrow either side; free text hits summary.
    Gori::Repeater::SubtabFilter.parse("host:api").matches?(s).should be_true
    Gori::Repeater::SubtabFilter.parse("method:post").matches?(s).should be_true
    Gori::Repeater::SubtabFilter.parse("login").matches?(s).should be_true
    Gori::Repeater::SubtabFilter.parse("host:nope").matches?(s).should be_false
  end

  # Regression: the REQ/RES divider chips were hit-tested one column off the cells
  # they were drawn on — the RES chip's left edge was a dead click and a phantom
  # clickable column sat one past it. render + pane_chip_at now share one geometry
  # helper, so every drawn chip column maps back to its pane.
  it "pane_chip_at lands on exactly the drawn REQ/RES chip columns" do
    w, h = 80, 20
    backend = MemoryBackend.new(w, h)
    rect = Rect.new(0, 0, w, h)
    v = ComparerView.new
    v.render(Screen.new(backend), rect, focused: true)

    divider_y = rect.y + 1
    row = backend.row(divider_y)
    req = row.index("REQ").not_nil!
    res = row.index("RES").not_nil!

    # " REQ " / " RES " each span one leading + 3 letters + one trailing column.
    (req - 1..req + 3).each do |c|
      v.pane_chip_at(rect, c, divider_y).should eq(:request)
    end
    (res - 1..res + 3).each do |c|
      v.pane_chip_at(rect, c, divider_y).should eq(:response)
    end
    # No phantom hit one column past the RES chip.
    v.pane_chip_at(rect, res + 4, divider_y).should be_nil
    # Wrong row never hits.
    v.pane_chip_at(rect, req, divider_y + 1).should be_nil
  end
end
