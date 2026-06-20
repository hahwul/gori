require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-replays", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "Gori::Store replay tabs (v9)" do
  it "round-trips insert → load" do
    with_store do |store|
      store.replays.should be_empty
      id = store.insert_replay("https://a.test", "GET / HTTP/1.1\r\n\r\n", false, true, 7_i64, 0)
      id.should be > 0

      rows = store.replays
      rows.size.should eq(1)
      r = rows.first
      r.id.should eq(id)
      r.target.should eq("https://a.test")
      r.request.should eq("GET / HTTP/1.1\r\n\r\n")
      r.http2?.should be_false
      r.auto_content_length?.should be_true
      r.flow_id.should eq(7_i64)
      r.position.should eq(0)
    end
  end

  it "round-trips the http2 + auto_content_length flags and a NULL flow_id" do
    with_store do |store|
      id = store.insert_replay("http://h2.test", "POST / HTTP/2\r\n\r\n", true, false, nil, 0)
      r = store.replays.find!(&.id.==(id))
      r.http2?.should be_true
      r.auto_content_length?.should be_false
      r.flow_id.should be_nil
    end
  end

  it "updates a tab in place" do
    with_store do |store|
      id = store.insert_replay("https://a.test", "GET / HTTP/1.1\r\n\r\n", false, true, nil, 0)
      store.update_replay(id, "https://b.test", "PUT /x HTTP/1.1\r\n\r\n", true, false)
      r = store.replays.find!(&.id.==(id))
      r.target.should eq("https://b.test")
      r.request.should eq("PUT /x HTTP/1.1\r\n\r\n")
      r.http2?.should be_true
      r.auto_content_length?.should be_false
    end
  end

  it "deletes a tab" do
    with_store do |store|
      id = store.insert_replay("https://a.test", "GET / HTTP/1.1\r\n\r\n", false, true, nil, 0)
      store.delete_replay(id)
      store.replays.should be_empty
    end
  end

  it "orders by position then id (id breaks a position tie)" do
    with_store do |store|
      a = store.insert_replay("https://a.test", "a", false, true, nil, 2)
      b = store.insert_replay("https://b.test", "b", false, true, nil, 0)
      c = store.insert_replay("https://c.test", "c", false, true, nil, 0) # tie with b → id breaks it
      store.replays.map(&.id).should eq([b, c, a])
    end
  end
end
