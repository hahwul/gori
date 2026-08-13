require "../spec_helper"

# `probe_issues` grows as (code x host), so a wide crawl reaches hundreds of thousands of
# rows and every row read parses its `affected` JSON. The MCP list tool wanted a hundred of
# them and was materialising all of them to slice in Crystal — 148 ms at 250k rows against
# 5.9 ms for the SQL page. Since the query changed, the gate is that the page is the SAME
# page: these compare it against the read-everything-and-slice it replaced.
private def page_store(&)
  path = File.tempname("gori-probe-page", ".db")
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

# `last_seen` is unique per row so the (severity DESC, last_seen DESC) sort is total — with
# ties, two queries may order equal rows differently and the comparison would be about
# SQLite's tie-breaking rather than about this change. `code` is unique per row too, because
# the table is UNIQUE(code, host); host and category still repeat so the filters group.
private def seed(store, n : Int32)
  n.times do |i|
    store.@db.exec(
      "INSERT INTO probe_issues (code, category, host, title, severity, status, hit_count, " \
      "affected, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?, 1, '[]', ?, ?)",
      "code#{i}", "cat#{i % 3}", "h#{i % 11}.test", "t#{i}",
      (i % 5), (i % 4), i.to_i64, (n - i).to_i64)
  end
end

describe "Store#probe_issues_page" do
  it "returns the same page the load-everything-and-slice path did" do
    page_store do |store|
      seed(store, 200)
      {% for args in [{nil, nil}, {"cat1", nil}, {nil, "h3.test"}] %}
        cat, host = {{ args[0] }}, {{ args[1] }}
        [{0, 10}, {0, 100}, {25, 10}, {195, 10}, {500, 10}].each do |(off, lim)|
          [false, true].each do |open_only|
            all = store.probe_issues(cat, host)
            all = all.select(&.status.open?) if open_only
            want = all[off, lim]? || [] of Gori::Store::ProbeIssue

            got, total = store.probe_issues_page(cat, host, open_only: open_only,
              limit: lim, offset: off)
            got.map(&.id).should eq(want.map(&.id)),
              "page differs at cat=#{cat} host=#{host} off=#{off} lim=#{lim} open=#{open_only}"
            total.should eq(all.size),
              "total differs at cat=#{cat} host=#{host} open=#{open_only}"
          end
        end
      {% end %}
    end
  end

  it "filters by min_severity the same way the unbounded read does" do
    page_store do |store|
      seed(store, 60)
      sev = Gori::Store::Severity.new(3)
      want = store.probe_issues(nil, nil, sev)
      got, total = store.probe_issues_page(nil, nil, sev, limit: 1000)
      got.map(&.id).should eq(want.map(&.id))
      total.should eq(want.size)
    end
  end

  it "reports a total that outruns the page, which is what lets a caller say N of M" do
    page_store do |store|
      seed(store, 500)
      got, total = store.probe_issues_page(limit: 25)
      got.size.should eq(25)
      total.should eq(500) # the whole matching set, not the page
    end
  end

  it "answers an empty table without raising" do
    page_store do |store|
      got, total = store.probe_issues_page(limit: 50)
      got.should be_empty
      total.should eq(0)
    end
  end
end
