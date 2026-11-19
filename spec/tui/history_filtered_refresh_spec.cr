require "../spec_helper"

include Gori::Tui

# A History that counts how often its whole question was re-asked.
private class CountingHistory < HistoryView
  getter fetches = 0

  def fetch_search(store : Gori::Store, request : HistoryView::SearchRequest,
                   control : Gori::Store::QueryControl? = nil) : HistoryView::SearchResult
    @fetches += 1
    super
  end
end

private def fr_flow(store : Gori::Store, path : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "fr.test", port: 80, method: "GET",
    target: path, http_version: "HTTP/1.1",
    head: "GET #{path} HTTP/1.1\r\nHost: fr.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
end

private def fr_respond(store : Gori::Store, id : Int64, status : Int32) : Nil
  store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: status,
    head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice, duration_us: 1_000_i64))
end

private def fr_view(store : Gori::Store, query : String) : CountingHistory
  view = CountingHistory.new
  view.set_query(query)
  view.reload(store)
  view
end

# What the whole question answers right now: the rows a full reload shows.
private def fr_full(store : Gori::Store, query : String) : Array(Int64)
  fr_view(store, query).rows.map(&.id)
end

# The capture tick: deliver the events, then the debounced flush the Runner runs.
private def fr_flush(view : HistoryView, store : Gori::Store, events : Array({Int64, Symbol})) : Nil
  events.each { |(id, kind)| view.on_event(Gori::Store::FlowEvent.new(id, kind), store) }
  sleep HistoryView::FILTER_FLUSH_INTERVAL
  view.flush_filter(store).should be_true
end

# A filtered History under capture is brought up to date from the flow events instead of
# re-running its whole question per flush (a no-match `path:` walked the whole table up to
# 4×/s). Every example checks the list against what a full reload shows.
describe "HistoryView filtered refresh" do
  it "adds a new matching flow without re-asking, keeping the selection" do
    with_store do |store|
      a = fr_flow(store, "/hit/1")
      fr_flow(store, "/miss/1")
      b = fr_flow(store, "/hit/2")
      view = fr_view(store, "path:/hit")
      view.rows.map(&.id).should eq([b, a])
      view.select_row(1) # off the live tail: the highlight stays on its flow
      c = fr_flow(store, "/hit/3")
      fr_flush(view, store, [{c, :inserted}])
      view.fetches.should eq(1)
      view.rows.map(&.id).should eq(fr_full(store, "path:/hit"))
      view.rows.first.id.should eq(c)
      view.selected_id.should eq(a)
    end
  end

  it "ignores a new flow the filter does not match" do
    with_store do |store|
      a = fr_flow(store, "/hit/1")
      view = fr_view(store, "path:/hit")
      m = fr_flow(store, "/miss/2")
      fr_flush(view, store, [{m, :inserted}])
      view.fetches.should eq(1)
      view.rows.map(&.id).should eq([a])
    end
  end

  it "adds a flow whose response makes it match, and drops one whose response stops it" do
    with_store do |store|
      a = fr_flow(store, "/x/1")
      b = fr_flow(store, "/x/2")
      fr_respond(store, a, 500)
      view = fr_view(store, "status:500")
      view.rows.map(&.id).should eq([a])
      fr_respond(store, b, 500)
      fr_flush(view, store, [{b, :updated}])
      view.rows.map(&.id).should eq([b, a])
      fr_respond(store, a, 200) # a peer-style rewrite of the answer, as an update event
      fr_flush(view, store, [{a, :updated}])
      view.rows.map(&.id).should eq([b])
      view.fetches.should eq(1)
      view.rows.map(&.id).should eq(fr_full(store, "status:500"))
    end
  end

  it "re-asks the whole question for a change no flow event describes (a delete)" do
    with_store do |store|
      a = fr_flow(store, "/hit/1")
      b = fr_flow(store, "/hit/2")
      view = fr_view(store, "path:/hit")
      store.delete_flow(a).should be_true
      view.stale_filter # what a data_version move does
      fr_flush(view, store, [] of {Int64, Symbol})
      view.fetches.should eq(2)
      view.rows.map(&.id).should eq([b])
    end
  end

  it "stops remembering moved flows past the cap and re-asks the whole question instead" do
    with_store do |store|
      a = fr_flow(store, "/hit/1")
      view = fr_view(store, "path:/hit")
      # An off-tab History never flushes, so the set must not grow with the capture.
      (1..HistoryView::INC_MAX_UPDATES + 50).each do |i|
        view.on_event(Gori::Store::FlowEvent.new(a + i, :updated), store)
      end
      view.@inc_updated.size.should be <= HistoryView::INC_MAX_UPDATES
      sleep HistoryView::FILTER_FLUSH_INTERVAL
      view.flush_filter(store).should be_true
      view.fetches.should eq(2)
      view.rows.map(&.id).should eq([a])
    end
  end

  it "keeps the window at one page, and backfills it from the whole question when it shrinks" do
    with_store do |store|
      (1..HistoryView::PAGE + 2).each { |i| fr_respond(store, fr_flow(store, "/hit/#{i}"), 500) }
      view = fr_view(store, "status:500")
      view.rows.size.should eq(HistoryView::PAGE)
      new_ids = (1..3).map { |i| fr_flow(store, "/hit/new#{i}").tap { |id| fr_respond(store, id, 500) } }
      fr_flush(view, store, new_ids.flat_map { |id| [{id, :inserted}, {id, :updated}] })
      view.fetches.should eq(1)
      view.rows.size.should eq(HistoryView::PAGE)
      view.rows.first.id.should eq(new_ids.last)
      view.rows.map(&.id).should eq(fr_full(store, "status:500"))

      inside = view.rows[10].id
      fr_respond(store, inside, 500) # answered again, still matching: nothing to backfill
      fr_flush(view, store, [{inside, :updated}])
      view.fetches.should eq(1)
      # A row of a FULL window stops matching: the answer below the window has to move up.
      fr_respond(store, inside, 200)
      fr_flush(view, store, [{inside, :updated}])
      view.fetches.should eq(2)
      view.rows.size.should eq(HistoryView::PAGE)
      view.rows.map(&.id).should eq(fr_full(store, "status:500"))
    end
  end
end
