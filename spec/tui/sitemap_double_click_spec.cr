require "../support/tui_contract"

include Gori::Tui

# A double-click on a Sitemap row's LABEL folds or unfolds a folder and opens a leaf's flow —
# the universal tree gesture. Expand/collapse used to answer only on the one-column ▾/▸
# marker, where a double-click was a net no-op (the pair's first press toggled, the second
# toggled back), and `TargetController` never forwarded the gesture to the tree at all.

private def capture(store, host, method, target)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
end

private RECT = Rect.new(0, 0, 100, 30)

# The cell of visible row `idx`, found by inverting the view's own hit-test over the content
# rect the standalone click path uses — so the spec cannot disagree with `row_at`.
private def row_cell(view : SitemapView, idx : Int32, x_off : Int32) : {Int32, Int32}
  content = RECT.inset(1, 1)
  RECT.h.times do |y|
    return {content.x + x_off, y} if view.row_at(content, content.x + x_off, y) == idx
  end
  raise "row #{idx} is not on screen"
end

private def visible_count(view : SitemapView) : Int32
  n = 0
  content = RECT.inset(1, 1)
  RECT.h.times { |y| n += 1 if view.row_at(content, content.x + 6, y) }
  n
end

private def with_sitemap(&)
  TuiContract.with_session("sitemap-dclick") do |session|
    capture(session.store, "a.test", "GET", "/dir/leaf")
    capture(session.store, "a.test", "GET", "/dir/other")
    host = TuiContract::Host.new(session)
    ctl = SitemapController.new(host)
    host.tab = :target
    ctl.on_enter
    TuiContract.render(ctl)
    yield ctl, host
  end
end

describe "SitemapController double-click" do
  it "folds and unfolds a folder from its label" do
    with_sitemap do |ctl, _host|
      view = ctl.view
      before = visible_count(view)
      before.should be >= 3         # host, dir, two leaves
      mx, my = row_cell(view, 0, 6) # the host row's label, well right of its marker
      ctl.handle_click(RECT, mx, my)
      ctl.handle_double_click(RECT, mx, my).should be_true
      TuiContract.render(ctl)
      visible_count(view).should eq(1) # everything under the host folded away
      ctl.handle_click(RECT, mx, my)
      ctl.handle_double_click(RECT, mx, my).should be_true
      TuiContract.render(ctl)
      visible_count(view).should eq(before)
    end
  end

  it "opens a leaf's flow through the host" do
    with_sitemap do |ctl, host|
      view = ctl.view
      leaf = (0...visible_count(view)).find! { |i| view.leaf_at?(i) }
      mx, my = row_cell(view, leaf, 8)
      ctl.handle_click(RECT, mx, my)
      ctl.handle_double_click(RECT, mx, my).should be_true
      host.sitemap_opens.should eq(1)
    end
  end

  it "reads a pair on the marker column as ONE toggle" do
    with_sitemap do |ctl, _host|
      view = ctl.view
      visible_count(view).should be >= 3
      content = RECT.inset(1, 1)
      _, my = row_cell(view, 0, 6)
      mx = content.x + 1 # the host row's ▾ marker (depth 0)
      view.marker_hit?(content, mx, 0).should be_true
      ctl.handle_click(RECT, mx, my) # the pair's first press: toggles
      TuiContract.render(ctl)
      visible_count(view).should eq(1)
      ctl.handle_double_click(RECT, mx, my).should be_true # swallowed, not toggled back
      TuiContract.render(ctl)
      visible_count(view).should eq(1)
    end
  end

  it "declines off every row so the shell delivers the press as a click" do
    with_sitemap do |ctl, _host|
      ctl.handle_double_click(RECT, 10, RECT.bottom - 1).should be_false
    end
  end

  it "is forwarded by the Target tab to the tree" do
    TuiContract.with_session("target-dclick") do |session|
      capture(session.store, "b.test", "GET", "/x/y")
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.is_a?(TargetController)
        controller.on_enter
        TuiContract.render(controller)
        # Off every row: false, like the child. The forward is what is under test — before it
        # the base hook answered false everywhere, including on a row.
        controller.handle_double_click(TuiContract::AREA, 10, TuiContract::AREA.bottom - 1).should be_false
      end
    end
  end
end
