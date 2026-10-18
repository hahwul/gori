require "../../spec_helper"

include Gori::Tui

private SSE_HEAD  = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice
private TEXT_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice

private def live_view : {RepeaterView, Gori::Repeater::LiveBody}
  view = RepeaterView.new
  view.load_blank
  view.pretty = true
  live = Gori::Repeater::LiveBody.new
  view.inflight = true
  view.live_begin(live)
  {view, live}
end

private def event_rows(view : RepeaterView) : Array(String)
  resp_lines(view).select(&.starts_with?("▸ event"))
end

# The Repeater's live event-stream pane (#1631).
describe "Gori::Tui::RepeaterView — an event stream while it is open" do
  it "renders each new event as the stream grows" do
    view, live = live_view
    live.open(SSE_HEAD)
    live.append("id: 1\nevent: tick\ndata: one\n\n".to_slice)
    t = Time.instant
    view.live_tick(t).should be_true
    event_rows(view).should eq(["▸ event #1  type=tick  id=1"])
    resp_lines(view).should contain("    one")

    live.append("data: two\n\n".to_slice)
    view.live_tick(t + 300.milliseconds).should be_true
    event_rows(view).size.should eq(2)
    resp_lines(view).should contain("    two")
  end

  it "re-parses at most every LIVE_EVERY, and never when nothing arrived" do
    view, live = live_view
    live.open(SSE_HEAD)
    live.append("data: one\n\n".to_slice)
    t = Time.instant
    view.live_tick(t).should be_true
    view.live_tick(t + 1.second).should be_false # same size
    live.append("data: two\n\n".to_slice)
    view.live_tick(t + 100.milliseconds).should be_false # too soon
    event_rows(view).size.should eq(1)
    view.live_tick(t + RepeaterView::LIVE_EVERY).should be_true
    event_rows(view).size.should eq(2)
  end

  it "keeps the events received before a Stop once the result lands" do
    view, live = live_view
    live.open(SSE_HEAD)
    live.append("data: one\n\ndata: two\n\n".to_slice)
    view.live_tick.should be_true
    live.stop
    view.apply(Gori::Repeater::Result.new(SSE_HEAD, "data: one\n\ndata: two\n\n".to_slice, nil, 1000_i64,
      incomplete: true, bounded: "cancelled"))
    view.live.should be_nil
    event_rows(view).size.should eq(2)
  end

  it "shows the raw stream with PRETTY off" do
    view, live = live_view
    view.pretty = false
    live.open(SSE_HEAD)
    live.append("data: one\n\n".to_slice)
    view.live_tick.should be_true
    resp_lines(view).should contain("data: one")
    event_rows(view).should be_empty
  end

  it "leaves a response that is not an event stream as it was" do
    view, _ = live_view
    view.live_tick.should be_false # the engine never opens the sink for it
    view.apply(Gori::Repeater::Result.new(TEXT_HEAD, "data: one\n\n".to_slice, nil, 1000_i64))
    resp_lines(view).should contain("data: one")
    event_rows(view).should be_empty
  end

  it "shows the latest events in History's window, numbered past the older ones" do
    view, live = live_view
    live.open(SSE_HEAD)
    cap = HistoryView::DETAIL_LOG_CAP
    live.append(String.build { |io| (cap + 5).times { |i| io << "data: " << i << "\n\n" } }.to_slice)
    view.live_tick.should be_true
    lines = resp_lines(view)
    lines.should contain("— showing the latest #{cap} of #{cap + 5} events; 5 older not shown —")
    event_rows(view).size.should eq(cap)
    event_rows(view).first.should eq("▸ event #6")
  end

  it "waits longer between renders as the stream grows" do
    view, live = live_view
    live.open(SSE_HEAD)
    live.append(Bytes.new(RepeaterView::LIVE_STRETCH * 2, 'x'.ord.to_u8))
    t = Time.instant
    view.live_tick(t).should be_true
    live.append("data: one\n\n".to_slice)
    view.live_tick(t + RepeaterView::LIVE_EVERY * 2).should be_false
    view.live_tick(t + RepeaterView::LIVE_EVERY * 3).should be_true
  end

  it "copies and dumps the stream on screen, not the last send's response" do
    view, live = live_view
    view.apply(Gori::Repeater::Result.new(TEXT_HEAD, "old".to_slice, nil, 1000_i64))
    view.inflight = true
    view.live_begin(live)
    live.open(SSE_HEAD)
    live.append("data: one\n\n".to_slice)
    view.live_tick.should be_true
    view.response_parts.not_nil![1].should eq("data: one\n\n")
    view.response_wire.not_nil![1].should eq("data: one\n\n".to_slice)
  end

  it "shows each event's arrival after the first, live and once the result lands" do
    view, live = live_view
    live.open(SSE_HEAD, Gori::Sse::Arrivals.new(chunked: false))
    live.append("data: one\n\n".to_slice)
    sleep 40.milliseconds
    live.append("data: two\n\n".to_slice)
    view.live_tick.should be_true
    rows = event_rows(view)
    rows[0].should eq("▸ event #1  +0.000s")
    offset = rows[1].match(/^▸ event #2  \+(\d+\.\d{3})s$/).not_nil![1].to_f
    offset.should be >= 0.04

    view.apply(Gori::Repeater::Result.new(SSE_HEAD, "data: one\n\ndata: two\n\n".to_slice, nil, 1000_i64))
    event_rows(view).should eq(rows)
    # A duplicated tab shows the same stream with the same times.
    copy = RepeaterView.new
    copy.duplicate_from(view)
    copy.pretty = true
    event_rows(copy).should eq(rows)
    # A later send that did not stream leaves no stale times behind.
    view.apply(Gori::Repeater::Result.new(SSE_HEAD, "data: one\n\n".to_slice, nil, 1000_i64))
    event_rows(view).should eq(["▸ event #1"])
  end
end
