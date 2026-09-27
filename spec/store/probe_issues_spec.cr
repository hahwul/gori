require "../spec_helper"

# The `affected` rule every upsert applies, exactly as it was written before the writer kept a
# memo of it: parse the stored list (unparseable ⇒ empty), add the URL unless it is there or the
# list is at the cap, serialize. The memo may only change how often that runs, never a byte of
# what the row ends up holding.
private def reference_affected(stored : String, url : String) : String
  urls = begin
    Array(String).from_json(stored)
  rescue
    [] of String
  end
  urls << url if !urls.includes?(url) && urls.size < Gori::Store::PROBE_AFFECTED_CAP
  urls.to_json
end

private def detection(url : String, sev = Gori::Store::Severity::Low, code = "hsts_missing",
                      host = "a.test") : Gori::Probe::Detection
  Gori::Probe::Detection.new(code, "headers", host, url, "Title #{sev}", sev, "ev", 1_i64)
end

private def raw_row(store : Gori::Store, code = "hsts_missing", host = "a.test") : {String, Int64, Int32, String}
  store.@db.query_one("SELECT affected, hit_count, severity, title FROM probe_issues WHERE code = ? AND host = ?",
    code, host, as: {String, Int64, Int32, String})
end

describe "Store#upsert_probe_issues — the affected list" do
  it "holds exactly what the parse/add/serialize rule writes: new URL, present URL, at the cap" do
    with_store do |store|
      store.upsert_probe_issue(detection("https://a.test/0")) # the INSERT writes [url]
      model = ["https://a.test/0"].to_json
      raw_row(store)[0].should eq(model)

      urls = [] of String
      # new URLs up to and past the cap, with repeats of present ones interleaved, and URLs
      # whose JSON form escapes (quote, backslash, control char, non-ASCII, a `/`).
      70.times do |i|
        urls << "https://a.test/#{i}"
        urls << "https://a.test/#{i // 2}"                            # present (or new, early on)
        urls << %(https://a.test/q?x="#{i}"\\y\u0001/é) if i % 9 == 0 # escapes
      end
      hits = 1_i64
      urls.each do |url|
        store.upsert_probe_issue(detection(url))
        hits += 1
        model = reference_affected(model, url)
        row = raw_row(store)
        row[0].should eq(model)
        row[1].should eq(hits)
      end
      Array(String).from_json(model).size.should eq(Gori::Store::PROBE_AFFECTED_CAP)
    end
  end

  it "rewrites a row another writer left non-canonical or unparseable, as the full rule does" do
    with_store do |store|
      store.upsert_probe_issue(detection("https://a.test/a"))
      store.upsert_probe_issue(detection("https://a.test/b")) # the writer now holds a memo
      raw_row(store)[0].should eq(reference_affected(["https://a.test/a"].to_json, "https://a.test/b"))

      # A foreign write: same list, spaced. The memo must miss (its string differs) and the
      # full rule re-serializes it even though the URL is already present.
      spaced = %([ "https://a.test/a" , "https://a.test/b" ])
      store.@db.exec("UPDATE probe_issues SET affected = ?", spaced)
      store.upsert_probe_issue(detection("https://a.test/a"))
      model = reference_affected(spaced, "https://a.test/a")
      raw_row(store)[0].should eq(model)

      store.@db.exec("UPDATE probe_issues SET affected = ?", "{not json")
      store.upsert_probe_issue(detection("https://a.test/c"))
      model = reference_affected("{not json", "https://a.test/c")
      raw_row(store)[0].should eq(model)
      raw_row(store)[0].should eq(%(["https://a.test/c"]))

      # A foreign list PAST the cap is left as long as it is, and a present URL keeps it.
      over = (0...60).map { |i| "https://a.test/o#{i}" }.to_json
      store.@db.exec("UPDATE probe_issues SET affected = ?", over)
      store.upsert_probe_issue(detection("https://a.test/new"))
      raw_row(store)[0].should eq(reference_affected(over, "https://a.test/new"))
      store.upsert_probe_issue(detection("https://a.test/o3"))
      raw_row(store)[0].should eq(over)
    end
  end

  it "matches the rule for a URL whose bytes do not survive a JSON round trip" do
    with_store do |store|
      bad = String.new(Bytes[0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f, 0x2f, 0xff, 0x61]) # invalid UTF-8
      store.upsert_probe_issue(detection("https://a.test/ok"))
      model = ["https://a.test/ok"].to_json
      4.times do
        store.upsert_probe_issue(detection(bad))
        model = reference_affected(model, bad)
        raw_row(store)[0].should eq(model)
      end
    end
  end

  it "keeps severity, title and hit_count as before on a hit that leaves the list alone" do
    with_store do |store|
      store.upsert_probe_issue(detection("https://a.test/x", Gori::Store::Severity::Low))
      store.upsert_probe_issue(detection("https://a.test/x", Gori::Store::Severity::Low))
      store.upsert_probe_issue(detection("https://a.test/x", Gori::Store::Severity::High)) # raises
      store.upsert_probe_issue(detection("https://a.test/x", Gori::Store::Severity::Medium))
      affected, hits, sev, title = raw_row(store)
      affected.should eq(%(["https://a.test/x"]))
      hits.should eq(4)
      sev.should eq(Gori::Store::Severity::High.value)
      title.should eq("Title High")
    end
  end

  it "keeps each (code, host) group's list apart" do
    with_store do |store|
      store.upsert_probe_issues([detection("https://a.test/1"), detection("https://b.test/1", host: "b.test"),
                                 detection("https://a.test/2"), detection("https://b.test/1", host: "b.test")])
      raw_row(store)[0].should eq(%(["https://a.test/1","https://a.test/2"]))
      raw_row(store, host: "b.test")[0].should eq(%(["https://b.test/1"]))
    end
  end
end
