require "../support/tui_contract"

include Gori::Tui

# The Sitemap `/` bar's reload runs its store reads on a worker fiber (`QueryControl`, the
# History #967 shape): typing never waits behind the DISTINCT scan over the flow table, a
# superseded read is cancelled and its answer dropped, and the tree is rebuilt on the main
# fiber from what the worker brought back.
private def seed(store : Gori::Store, host : String, target : String) : Nil
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
end

# Spin the tick's drain until the worker's answer lands (bounded, so a wedge fails loudly).
private def settle(controller : SitemapController) : Nil
  200.times do
    return if controller.drain_search
    sleep 5.milliseconds
  end
  fail "the sitemap worker never answered"
end

describe SitemapController, "async `/` filter" do
  it "reads on a worker and lands the filtered tree on drain" do
    TuiContract.with_session("sitemap-async") do |session|
      seed(session.store, "acme.test", "/api/one")
      seed(session.store, "other.test", "/api/two")
      host = TuiContract::Host.new(session)
      controller = SitemapController.new(host)
      host.tab = :sitemap
      controller.reload
      TuiContract.render(controller).contains?("other.test").should be_true

      controller.sitemap_query
      "host:acme".each_char { |c| controller.handle_query_key(TuiContract.plain(c)) }
      # The debounce has not elapsed: nothing flushed, the old tree stands.
      controller.flush_query_reload_if_due(Time.instant).should be_false
      controller.flush_query_reload_if_due(Time.instant + 1.second).should be_true
      controller.view.searching?.should be_true
      settle(controller)
      controller.view.searching?.should be_false
      be = TuiContract.render(controller)
      be.contains?("acme.test").should be_true
      be.contains?("other.test").should be_false
    end
  end

  it "drops a superseded read's answer — a synchronous reload after it wins" do
    TuiContract.with_session("sitemap-async-2") do |session|
      seed(session.store, "acme.test", "/api/one")
      seed(session.store, "other.test", "/api/two")
      host = TuiContract::Host.new(session)
      controller = SitemapController.new(host)
      host.tab = :sitemap
      controller.sitemap_query
      "host:acme".each_char { |c| controller.handle_query_key(TuiContract.plain(c)) }
      controller.flush_query_reload_if_due(Time.instant + 1.second).should be_true
      # Esc clears the filter and reloads in place; the in-flight `host:acme` read must not
      # land on top of the full tree afterwards.
      controller.handle_query_key(TuiContract.key(Termisu::Input::Key::Escape))
      controller.view.searching?.should be_false
      200.times do
        break if controller.drain_search
        sleep 5.milliseconds
      end
      be = TuiContract.render(controller)
      be.contains?("other.test").should be_true
    end
  end
end
