require "../spec_helper"

private def seed_count_flow(store : Gori::Store, host : String, status : Int32) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice))
  id
end

private def seed_ranked_flow(store : Gori::Store, host : String, dur_us : Int64?, size : Int32) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
  return id unless dur_us # no response yet
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: Bytes.new(size),
    body_size: size.to_i64, duration_us: dur_us))
  id
end

describe Gori::Store do
  # #1680: a row feed says why a flow failed without a `show` per errored flow — filled by
  # `with_errors`, never by `SELECT_ROW` (the list index does not carry `error`).
  it "fills an errored flow's stored error on its row, and nil on any other" do
    with_store do |store|
      ok = seed_count_flow(store, "a.test", 200)
      failed = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "b.test", port: 443,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: b.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: failed, status: 0, head: Bytes.empty, state: Gori::Store::FlowState::Error, error: "upstream connect failed: b.test:443"))
      rows = store.recent_flows(10)
      rows.find! { |r| r.id == failed }.error.should be_nil # the list read leaves it alone
      filled = store.with_errors(rows)
      filled.map(&.id).should eq(rows.map(&.id))
      filled.find! { |r| r.id == failed }.error.should eq("upstream connect failed: b.test:443")
      filled.find! { |r| r.id == ok }.error.should be_nil
      store.get_flow(failed).not_nil!.row.error.should eq("upstream connect failed: b.test:443")
    end
  end

  # #1648: `count_matching` is `search` without the rows, so the number an agent or a script
  # asks for and the pages it would otherwise walk can never disagree.
  describe "#count_matching" do
    it "counts what search would return, past any page size, and every flow for EMPTY" do
      with_store do |store|
        7.times { seed_count_flow(store, "a.test", 500) }
        3.times { seed_count_flow(store, "b.test", 200) }
        filter = Gori::QL.parse("status:500")
        store.count_matching(filter).should eq(7)
        store.count_matching(filter).should eq(store.search(filter, 100).size)
        store.count_matching(Gori::QL.parse("host:nowhere.test")).should eq(0)
        store.count_matching(Gori::QL::EMPTY).should eq(10)
      end
    end

    it "raises on a query SQLite refuses to run instead of answering 0" do
      with_store do |store|
        seed_count_flow(store, "a.test", 200)
        broken = Gori::QL::Filter.new("no_such_column = 1", [] of DB::Any)
        expect_raises(Exception) { store.count_matching(broken) }
      end
    end
  end

  # The scan's id list: what `search` matches, oldest first, without materialising a row.
  describe "#flow_ids" do
    it "lists every matching id oldest first, and every flow for nil" do
      with_store do |store|
        ids = [seed_count_flow(store, "a.test", 200), seed_count_flow(store, "b.test", 500), seed_count_flow(store, "a.test", 500)]
        store.flow_ids(nil).should eq(ids)
        filter = Gori::QL.parse("host:a.test")
        store.flow_ids(filter).should eq(store.search(filter, 10).map(&.id).reverse!)
        store.flow_ids(filter).should eq([ids[0], ids[2]])
      end
    end
  end

  describe "#ranked" do
    it "returns the top flows by duration or total size, ties newest first, unanswered last by duration" do
      with_store do |store|
        fast = seed_ranked_flow(store, "a.test", 5_000_i64, 900)
        slow = seed_ranked_flow(store, "a.test", 90_000_i64, 10)
        tie = seed_ranked_flow(store, "b.test", 90_000_i64, 20)
        pending = seed_ranked_flow(store, "a.test", nil, 0)
        store.ranked(nil, Gori::Store::Rank::Slowest, 10).map(&.id).should eq([tie, slow, fast, pending])
        store.ranked(nil, Gori::Store::Rank::Slowest, 1).map(&.id).should eq([tie])
        store.ranked(nil, Gori::Store::Rank::Largest, 1).map(&.id).should eq([fast])
        filter = Gori::QL.parse("host:a.test")
        store.ranked(filter, Gori::Store::Rank::Slowest, 2).map(&.id).should eq([slow, fast])
      end
    end

    # "largest" means what `size:` and the printed `size` mean: request + response bytes. An
    # upload with a tiny answer outranks a bigger answer to a GET, and a pending flow ranks
    # by the request bytes it has.
    it "ranks largest by the total size it prints, not the response alone" do
      with_store do |store|
        get = seed_ranked_flow(store, "a.test", 1_000_i64, 900)
        upload = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "a.test", port: 443,
          method: "POST", target: "/up", http_version: "HTTP/1.1",
          head: "POST /up HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, body: Bytes.new(5_000),
          body_size: 5_000_i64, source: Gori::FlowSource::Kind::Proxy))
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: upload, status: 201, head: "HTTP/1.1 201 Created\r\n\r\n".to_slice,
          body: Bytes.new(0), body_size: 0_i64, duration_us: 1_000_i64))
        pending = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "a.test", port: 443,
          method: "POST", target: "/slow", http_version: "HTTP/1.1",
          head: "POST /slow HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, body: Bytes.new(2_000),
          body_size: 2_000_i64, source: Gori::FlowSource::Kind::Proxy))
        rows = store.ranked(nil, Gori::Store::Rank::Largest, 10)
        rows.map(&.id).should eq([upload, pending, get])
        rows.map(&.size).should eq(rows.map(&.size).sort!.reverse!)
      end
    end
  end
end

# `body:` drives `Store#search` from `flows_fts` (see `QL::Filter#fts_driver`) instead of the
# `id IN (SELECT rowid …)` form, which materialised every match before LIMIT. The rows must be
# exactly the IN form's for every shape QL allows, so each query runs both ways: as parsed, and
# with the driver stripped (`Filter.new(sql, args)` is the SQL every caller ran before).
private def seed_fts_flow(store : Gori::Store, i : Int32) : Int64
  words = %w[alpha beta gamma]
  host = i.even? ? "a.test" : "b.test"
  method = i % 3 == 0 ? "POST" : "GET"
  req_body = method == "POST" ? "#{words[i % 3]} req #{i}" : nil
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: i.to_i64, scheme: "https", host: host, port: 443,
    method: method, target: "/p/#{i}", http_version: "HTTP/1.1",
    head: "#{method} /p/#{i} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    body: req_body.try(&.to_slice), source: i % 4 == 0 ? Gori::FlowSource::Kind::Repeater : Gori::FlowSource::Kind::Proxy))
  status = i % 5 == 0 ? 500 : 200
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice,
    body: "#{words[(i + 1) % 3]} resp #{i % 7 == 0 ? "alpha" : ""}".to_slice, content_type: "text/plain"))
  id
end

describe "Store#search driven from flows_fts" do
  it "returns the IN form's rows for every query shape, limit and cursor" do
    with_store do |store|
      ids = (1..40).map { |i| seed_fts_flow(store, i) }
      store.index_pending!
      queries = [
        "body:alpha", "resp.body:alpha", "req.body:alpha", "body:alp", "body:al",
        "body:alpha host:a.test", "host:a.test body:alpha", "body:alpha -host:a.test",
        "body:alpha method:POST status:>=500", "body:alpha body:beta", "body:alpha -body:beta",
        "body:alpha OR host:b.test", "-body:alpha", "NOT body:alpha", "NOT (body:alpha OR body:beta)",
        "host:a.test AND (body:alpha OR method:POST)", "(body:alpha host:a.test) OR status:500",
        "body:alpha AND NOT method:GET", "body:zzqx", "body:alpha host:zzqx",
      ]
      view = Gori::QL.parse("src:proxy OR src:repeater")
      cursors = [ids[10], ids[25], ids.last + 1]
      driven = 0
      queries.each do |q|
        parsed = Gori::QL.parse(q)
        [parsed, Gori::QL.and(view, parsed), Gori::QL.and(parsed, view)].each do |filter|
          driven += 1 if filter.fts_driver
          plain = Gori::QL::Filter.new(filter.sql, filter.args)
          [1, 3, 1000].each do |limit|
            store.search(filter, limit, raise_on_error: true).map(&.id)
              .should eq(store.search(plain, limit, raise_on_error: true).map(&.id)), "#{q} limit #{limit}"
            cursors.each do |c|
              store.search(filter, limit, before_id: c, raise_on_error: true).map(&.id)
                .should eq(store.search(plain, limit, before_id: c, raise_on_error: true).map(&.id)), "#{q} before #{c}"
              store.search(filter, limit, since_id: c - 20, raise_on_error: true).map(&.id)
                .should eq(store.search(plain, limit, since_id: c - 20, raise_on_error: true).map(&.id)), "#{q} since #{c - 20}"
            end
          end
        end
      end
      driven.should be > 20 # the driven path actually ran, not only the fallback
      store.search(Gori::QL.parse("body:alpha"), 1000).size.should be > 5
    end
  end
end

# What an open over the retention cap says (the sweep removes the excess later, a chunk at a time).
describe Gori::Store, "#flows_over_retention" do
  it "counts the flows past the cap this store was opened with, 0 under it or with no cap" do
    path = File.tempname("gori-spec", ".db")
    begin
      seed = Gori::Store.open(path, retention_flows: Gori::Store::RETENTION_UNLIMITED)
      5.times { |i| seed_count_flow(seed, "h#{i}.test", 200) }
      seed.flows_over_retention.should eq(0) # unlimited: nothing to say
      seed.close
      {3 => 2_i64, 5 => 0_i64, 10 => 0_i64}.each do |cap, over|
        store = Gori::Store.open(path, retention_flows: cap)
        store.flows_over_retention.should eq(over)
        store.count.should eq(5) # opening deletes nothing
        store.close
      end
    ensure
      delete_db_files(path)
    end
  end
end
