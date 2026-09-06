require "../support/tui_contract"

include Gori::Tui

# `TabController#page_rows` — the PgUp/PgDn step is the rows the focused list DREW last frame
# (minus two of overlap), not a screenful of the whole body.
#
# The Runner's fallback page was the body height; only History corrected it. Every other list
# draws four to ten rows fewer than the body (frame, filter bar, header, divider, and only its
# share of a preview split), so each PgDn skipped rows that had never been on screen. Now the
# pane reports its own measure and the Runner asks before it pages.

private def render_at(view, w : Int32, h : Int32) : Nil
  view.render(Screen.new(MemoryBackend.new(w, h)), Rect.new(0, 0, w, h), true)
end

private def seed_issues(store, n : Int32) : Nil
  n.times { |i| store.insert_issue("issue #{i.to_s.rjust(2, '0')}", Gori::Store::Severity::Low, "a.test", nil) }
end

private def seed_probe(store, n : Int32) : Nil
  n.times do |i|
    store.upsert_probe_issue(Gori::Probe::Detection.new("missing_hsts", "headers", "h#{i}.test",
      "https://h#{i}.test/", "t", Gori::Store::Severity::Low))
  end
end

describe "Runner.page_step" do
  it "takes the pane's own measure when it has one, else a body screenful less overlap" do
    Runner.page_step(24, nil).should eq(21)
    Runner.page_step(24, 9).should eq(9)
    Runner.page_step(4, nil).should eq(3)
  end
end

describe "TabController#page_rows" do
  it "never reports more rows than the body it was drawn into, on any controller" do
    TuiContract.with_session("page-rows") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        if rows = controller.page_rows
          rows.should be >= 1
          rows.should be <= TuiContract::AREA.h
        end
      end
    end
  end

  it "tracks the drawn height of the Issues list, and steps down when the preview holds focus" do
    with_store do |store|
      seed_issues(store, 40)
      view = IssuesView.new
      view.reload(store)
      render_at(view, 80, 24)
      short = view.list_page_rows
      short.should be >= 1
      short.should be < 24 - 2 # the frame, filter bar, header and divider came off
      render_at(view, 80, 44)
      view.list_page_rows.should be > short
    end
  end

  it "tracks the drawn height of the Probe list" do
    with_store do |store|
      seed_probe(store, 40)
      view = ProbeView.new
      view.reload(store)
      render_at(view, 80, 24)
      short = view.list_page_rows
      short.should be >= 1
      short.should be < 24 - 2
      render_at(view, 80, 44)
      view.list_page_rows.should be > short
    end
  end

  it "answers nil for the Issues detail form — there is no list to page there" do
    TuiContract.with_session("page-rows-issues") do |session|
      seed_issues(session.store, 3)
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.is_a?(IssuesController)
        controller.on_enter
        TuiContract.render(controller)
        controller.page_rows.should_not be_nil
        controller.issues_open
        controller.page_rows.should be_nil
      end
    end
  end
end

describe "InterceptController#body_scroll" do
  # PgUp/PgDn/Home/End page the QUEUE — the list ↑/↓ walk, as on every other list tab. They
  # used to page the read-only preview instead, so the keys a hand learnt on History did
  # something else on the one tab whose list can be the longest under a flood.
  it "moves the queue cursor, not the preview" do
    TuiContract.with_session("page-rows-intercept") do |session|
      ic = session.interceptor
      ic.toggle unless ic.enabled?
      3.times do |i|
        p = "/p#{i}"
        spawn { ic.hold_request("GET #{p} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, method: "GET", target: p, host: "acme.test", port: 80, scheme: "http") }
      end
      Fiber.yield
      begin
        TuiContract.each_controller(session) do |controller, _host|
          next unless controller.is_a?(InterceptController)
          controller.view.reload(ic)
          TuiContract.render(controller)
          controller.view.selected_index.should eq(0)
          controller.body_scroll(1).should be_true
          controller.view.selected_index.should eq(1)
          controller.body_scroll(Runner::JUMP_ROWS).should be_true
          controller.view.selected_index.should eq(2)
          controller.page_rows.not_nil!.should be >= 1
        end
      ensure
        ic.forward_all # release the fibers parked on a decision
      end
    end
  end
end
