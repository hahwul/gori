require "../support/tui_contract"

include Gori::Tui

# `TabController#handle_wheel_at` — a wheel notch scrolls the pane UNDER THE POINTER and
# leaves keyboard focus where it is.
#
# The base delegated to the coordinate-free `handle_wheel`, which scrolls whatever pane holds
# KEYBOARD focus; only four controllers had the pointer-aware form. So scrolling over the
# Fuzzer results while the template was focused scrolled the template, and over the History
# preview it scrolled the list. Every multi-pane tab now hit-tests with the same rect its
# click does.

private def with_preview(flag : Symbol, &)
  case flag
  when :history
    prev = Gori::Settings.history_preview
    Gori::Settings.history_preview = true
    begin
      yield
    ensure
      Gori::Settings.history_preview = prev
    end
  when :issues
    prev = Gori::Settings.issues_preview
    Gori::Settings.issues_preview = true
    begin
      yield
    ensure
      Gori::Settings.issues_preview = prev
    end
  else
    prev = Gori::Settings.probe_preview
    Gori::Settings.probe_preview = true
    begin
      yield
    ensure
      Gori::Settings.probe_preview = prev
    end
  end
end

private def add_flow(store, target : String) : Int64
  body = (1..80).map { |i| "line #{i}" }.join("\n")
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: body.to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
    body: body.to_slice, content_type: "text/plain"))
  id
end

# The first cell for which `pred` holds, scanning the area top-down.
private def cell_where(area : Rect, &pred : Int32, Int32 -> Bool) : {Int32, Int32}
  area.h.times do |y|
    area.w.times do |x|
      return {x, y} if pred.call(x, y)
    end
  end
  raise "no cell matched"
end

describe "TabController#handle_wheel_at" do
  it "scrolls the History preview half under the pointer without taking focus from the list" do
    with_preview(:history) do
      TuiContract.with_session("wheel-history") do |session|
        6.times { |i| add_flow(session.store, "/f#{i}") }
        TuiContract.each_controller(session) do |controller, _host|
          next unless controller.is_a?(HistoryController)
          controller.on_enter
          TuiContract.render(controller)
          view = controller.view
          inner = TuiContract::AREA.inset(1, 1)
          mx, my = cell_where(TuiContract::AREA) { |x, y| view.preview_pane_at(inner, x, y) == :res }
          sel = view.selected_index
          controller.handle_wheel_at(3, mx, my, TuiContract::AREA).should be_true
          view.preview_scroll_res.should eq(3)
          view.preview_scroll_req.should eq(0)
          view.preview_focus.should eq(:list)
          view.selected_index.should eq(sel)
        end
      end
    end
  end

  it "scrolls the Issues preview under the pointer without taking focus from the list" do
    with_preview(:issues) do
      TuiContract.with_session("wheel-issues") do |session|
        3.times { |i| session.store.insert_issue("issue #{i}", Gori::Store::Severity::Low, "a.test", nil) }
        TuiContract.each_controller(session) do |controller, _host|
          next unless controller.is_a?(IssuesController)
          controller.on_enter
          TuiContract.render(controller)
          view = controller.view
          inner = TuiContract::AREA.inset(1, 1)
          mx, my = cell_where(TuiContract::AREA) { |x, y| view.preview_at?(inner, x, y) }
          sel = view.selected_index
          controller.handle_wheel_at(2, mx, my, TuiContract::AREA).should be_true
          view.preview_scroll.should eq(2)
          view.preview_focus.should eq(:list)
          view.selected_index.should eq(sel)
          # Off the preview it is the list that moves, still without a focus change.
          controller.handle_wheel_at(1, inner.x + 1, inner.y + 3, TuiContract::AREA)
          view.selected_index.should eq(sel + 1)
          view.preview_focus.should eq(:list)
        end
      end
    end
  end

  it "scrolls the Fuzzer pane under the pointer while another pane holds focus" do
    TuiContract.with_session("wheel-fuzzer") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.is_a?(FuzzerController)
        controller.fuzz_new
        view = controller.current_view.not_nil!
        view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n" + (1..60).map { |i| "X-#{i}: v\r\n" }.join + "\r\n", false, "")
        view.focus_pane(:target)
        TuiContract.render(controller)
        # One session: the strip is hidden below two chips and no filter bar is up, so the
        # body the click and the wheel hit-test with is the framed area under the strip row.
        body = BodyChrome.content_rect(TuiContract::AREA, strip: controller.subtab_strip_shown?,
          strip_divider: controller.subtab_strip_divider?)
        mx, my = cell_where(TuiContract::AREA) { |x, y| view.pane_at(body, x, y) == :template }
        controller.handle_wheel_at(4, mx, my, TuiContract::AREA).should be_true
        view.focus.should eq(:target)
        view.template_scroll.should be > 0
      end
    end
  end

  it "scrolls the Discover RUNS card under the pointer while FINDINGS holds focus" do
    TuiContract.with_session("wheel-discover") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.is_a?(DiscoverController)
        view = controller.view
        3.times do |i|
          run = DiscoverRun.new("http://t#{i}", Gori::Discover::Config.new)
          run.add_finding(Gori::Discover::Finding.new("http://t#{i}/a", "GET", 200, 4_i64, "text/html",
            Gori::Discover::Source::Crawled, 1, 0.95, nil))
          view.add(run)
        end
        view.focus_pane(:findings)
        TuiContract.render(controller)
        inner = TuiContract::AREA.inset(1, 1)
        mx, my = cell_where(TuiContract::AREA) { |x, y| view.pane_at(inner, x, y) == :runs }
        # `add` selects the newest run, so the notch that can move is the one going UP.
        before = view.current.not_nil!.target
        controller.handle_wheel_at(-1, mx, my, TuiContract::AREA).should be_true
        view.focus.should eq(:findings)
        view.current.not_nil!.target.should_not eq(before)
      end
    end
  end

  it "takes an off-pane notch on every controller without raising" do
    TuiContract.with_session("wheel-sweep") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        controller.handle_wheel_at(3, -1, -1, TuiContract::AREA)
        controller.handle_wheel_at(-3, TuiContract::AREA.right + 5, TuiContract::AREA.bottom + 5, TuiContract::AREA)
        TuiContract.render(controller)
      end
    end
  end
end
