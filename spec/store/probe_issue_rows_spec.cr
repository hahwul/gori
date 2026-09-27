require "../spec_helper"

# `Store#probe_issue_rows` is the Probe tab's list read: the same rows, in the same order, as
# `probe_issues`, with the affected-URL list replaced by a count taken in SQL. The gate is that
# the projection is the eager read minus the URLs — field for field, and with the count equal to
# the size of the list the full parse produces, including the rows that parse to nothing.
private def insert_raw(store : Gori::Store, code : String, affected : String, last_seen : Int64,
                       severity : Int32 = 2, status : Int32 = 0) : Nil
  store.@db.exec(
    "INSERT INTO probe_issues (code, category, host, title, severity, status, hit_count, " \
    "affected, sample_flow_id, evidence, first_seen, last_seen, sample_repeater_id) " \
    "VALUES (?, 'headers', 'a.test', ?, ?, ?, 3, ?, 7, 'ev', 1, ?, NULL)",
    code, "t-#{code}", severity, status, affected, last_seen)
end

describe "Store#probe_issue_rows" do
  it "matches probe_issues field for field, with the URL list reduced to its size" do
    with_store do |store|
      3.times do |i|
        store.upsert_probe_issues((0..i).map do |u|
          Gori::Probe::Detection.new("code#{i}", Gori::Probe::Category::HEADERS, "h#{i}.test",
            "https://h#{i}.test/#{u}", "Title #{i}", Gori::Store::Severity.new(i), "ev#{i}", i.to_i64)
        end)
      end
      full = store.probe_issues
      rows = store.probe_issue_rows
      rows.size.should eq(full.size)
      rows.zip(full).each do |r, f|
        {r.id, r.code, r.category, r.host, r.title, r.severity, r.status, r.hit_count,
         r.sample_flow_id, r.evidence, r.first_seen, r.last_seen, r.sample_repeater_id}
          .should eq({f.id, f.code, f.category, f.host, f.title, f.severity, f.status, f.hit_count,
                      f.sample_flow_id, f.evidence, f.first_seen, f.last_seen, f.sample_repeater_id})
        r.affected_count.should eq(f.affected.size)
      end
      rows.map(&.affected_count).sort!.should eq([1, 2, 3])
    end
  end

  it "counts a row whose affected list will not parse as 0, as the full parse does, and still reads the rest" do
    with_store do |store|
      insert_raw(store, "ok", %(["https://a.test/1","https://a.test/2"]), 5)
      insert_raw(store, "empty", "[]", 4)
      insert_raw(store, "garbage", "not json", 3)
      insert_raw(store, "object", %({"a":"b"}), 2)
      insert_raw(store, "scalar", %("https://a.test/"), 1)
      full = store.probe_issues.to_h { |i| {i.code, i.affected.size} }
      rows = store.probe_issue_rows.to_h { |i| {i.code, i.affected_count} }
      # One malformed row must not raise out of `json_array_length` and empty the whole list.
      rows.keys.sort!.should eq(%w[empty garbage object ok scalar])
      rows.should eq(full)
      rows["ok"].should eq(2)
    end
  end

  it "keeps probe_issues' order" do
    with_store do |store|
      insert_raw(store, "low-new", "[]", 9, severity: 1)
      insert_raw(store, "high-old", "[]", 1, severity: 3)
      insert_raw(store, "high-new", "[]", 8, severity: 3)
      store.probe_issue_rows.map(&.code).should eq(store.probe_issues.map(&.code))
      store.probe_issue_rows.map(&.code).should eq(%w[high-new high-old low-new])
    end
  end
end
