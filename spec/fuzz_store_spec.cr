require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-fuzz-test", ".db")
  store = Gori::Store.open(path, retention_flows: 0)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "Gori::Store fuzz persistence" do
  it "round-trips a fuzz session" do
    with_store do |store|
      id = store.insert_fuzz_session("http://h", "GET /?x=§1§ HTTP/1.1\r\n\r\n", false, nil,
        %({"mode":"sniper"}), 42_i64, 0, "s1")
      (id > 0).should be_true

      s = store.fuzz_sessions.first
      s.target.should eq("http://h")
      s.template.should contain("§1§")
      s.config.should eq(%({"mode":"sniper"}))
      s.flow_id.should eq(42_i64)
      s.http2?.should be_false
      s.name.should eq("s1")

      store.update_fuzz_session(id, "http://h2", "GET / HTTP/1.1\r\n\r\n", true, "sni.example",
        %({"mode":"clusterbomb"}), "renamed")
      s2 = store.fuzz_sessions.first
      s2.target.should eq("http://h2")
      s2.http2?.should be_true
      s2.sni.should eq("sni.example")
      s2.name.should eq("renamed")

      store.delete_fuzz_session(id)
      store.fuzz_sessions.should be_empty
    end
  end

  it "set_fuzz_session_name sets/clears the custom name without touching the template" do
    with_store do |store|
      id = store.insert_fuzz_session("http://h", "GET /?x=§1§ HTTP/1.1\r\n\r\n", false, nil,
        %({"mode":"sniper"}), nil, 0)
      store.fuzz_sessions.first.name.should be_nil

      store.set_fuzz_session_name(id, "auth fuzz")
      s = store.fuzz_sessions.first
      s.name.should eq("auth fuzz")
      s.template.should contain("§1§") # the rename must not rewrite the template/config
      s.config.should eq(%({"mode":"sniper"}))

      store.set_fuzz_session_name(id, nil) # blank clears the custom name
      store.fuzz_sessions.first.name.should be_nil
    end
  end

  it "round-trips a run + its results, with paging" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "http://h", "sniper", 3_i64)
      (run > 0).should be_true
      3.times do |i|
        store.insert_fuzz_result(run, i.to_i64, %(["p#{i}"]), 200, 10_i64, 2, 1, 1000_i64,
          nil, i == 1, i == 1 ? "tok" : nil)
      end
      store.update_fuzz_run(run, 3_i64, 1_i64, 0_i64, "done", 999_i64)

      r = store.fuzz_runs.first
      r.sent.should eq(3)
      r.matched.should eq(1)
      r.status.should eq("done")
      r.finished_at.should eq(999_i64)
      r.total.should eq(3_i64)

      all = store.fuzz_results(run)
      all.map(&.idx).should eq([0_i64, 1, 2])
      all[1].matched?.should be_true
      all[1].extracted.should eq("tok")

      store.fuzz_results(run, limit: 2, offset: 1).map(&.idx).should eq([1_i64, 2])
    end
  end

  it "captures optional response bytes for kept results" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "http://h", "sniper", 1_i64)
      store.insert_fuzz_result(run, 0_i64, %(["x"]), 500, 4_i64, 1, 1, 50_i64, nil, true, nil,
        request: "GET / HTTP/1.1\r\n\r\n".to_slice,
        response_head: "HTTP/1.1 500\r\n\r\n".to_slice,
        response_body: "boom".to_slice)
      r = store.fuzz_results(run).first
      r.request.should_not be_nil
      String.new(r.response_body.as(Bytes)).should eq("boom")
    end
  end
end
