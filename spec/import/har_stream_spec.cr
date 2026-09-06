require "../spec_helper"

# `Har.each_flow` walks a HAR's entries off the file one at a time (`JSON::PullParser`), so a
# browser-session HAR of hundreds of MB is never in memory as one tree and a TUI import
# keeps drawing while it runs. `parse_file` is the same walk plus an array, so what these pin
# is the walk: the shape errors the whole-file parse raised, found where the pull parser
# meets them; keys around `entries` skipped; a stop where the caller asks for one; and the
# streamed `import_file`, which writes a chunk at a time and says so when the file breaks
# after entries it already wrote.
private def har_entry(i : Int32) : String
  %({"startedDateTime":"2026-06-01T12:00:00.000Z","time":1,"request":{"method":"GET","url":"https://s.test/p/#{i}","httpVersion":"HTTP/1.1","headers":[]},"response":{"status":200,"statusText":"OK","httpVersion":"HTTP/1.1","headers":[],"content":{"mimeType":"text/plain","text":"ok"}}})
end

private def with_har(body : String, &)
  path = File.tempname("gori-har-stream", ".har")
  File.write(path, body)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

private def stream_store(&)
  path = File.tempname("gori-har-stream", ".db")
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

describe "Import::Har.each_flow" do
  it "yields every entry in order, skipping the keys around `entries` and counting malformed ones" do
    body = %({"log":{"version":"1.2","creator":{"name":"x","version":"1"},"pages":[{"id":"p"}],"entries":[#{har_entry(1)},{"request":{"method":"GET","url":""}},#{har_entry(2)}],"comment":"tail"},"extra":[1,2,{"a":null}]})
    with_har(body) do |path|
      seen = [] of String
      skipped = Gori::Import::Har.each_flow(path) { |pair| seen << pair.request.target }
      seen.should eq(["/p/1", "/p/2"])
      skipped.should eq(1)
      whole = Gori::Import::Har.parse_file(path)
      whole.flows.map(&.request.target).should eq(seen)
      whole.skipped.should eq(1)
    end
  end

  it "raises the same shape errors the whole-file parse did, where it meets them" do
    with_har("[1, 2]") do |path|
      expect_raises(Gori::Error, /not a JSON object/) { Gori::Import::Har.each_flow(path) { } }
    end
    with_har(%({"version": "1.2"})) do |path|
      expect_raises(Gori::Error, /missing log object/) { Gori::Import::Har.each_flow(path) { } }
    end
    with_har(%({"log": []})) do |path|
      expect_raises(Gori::Error, /missing log object/) { Gori::Import::Har.each_flow(path) { } }
    end
    with_har(%({"log": {"version": "1.2"}})) do |path|
      expect_raises(Gori::Error, /has no entries/) { Gori::Import::Har.each_flow(path) { } }
    end
    with_har(%({"log": {"entries": {}}})) do |path|
      expect_raises(Gori::Error, /has no entries/) { Gori::Import::Har.each_flow(path) { } }
    end
    with_har("not json {{{") do |path|
      expect_raises(Gori::Error, /not valid JSON/) { Gori::Import::Har.each_flow(path) { } }
    end
  end

  it "stops where the caller cancels, without reading the rest of the file" do
    body = %({"log":{"entries":[#{har_entry(1)},#{har_entry(2)},#{har_entry(3)}]}})
    with_har(body) do |path|
      seen = 0
      stop = false
      Gori::Import::Har.each_flow(path, cancelled: -> { stop }) do |_pair|
        seen += 1
        stop = true
      end
      seen.should eq(1)
    end
  end
end

describe "Import.import_file streams a HAR" do
  it "writes a chunk at a time and reports a running count with no total" do
    n = Gori::Import::IMPORT_CHUNK + 5
    body = String.build do |io|
      io << %({"log":{"entries":[)
      n.times { |i| io << "," if i > 0; io << har_entry(i) }
      io << "]}}"
    end
    with_har(body) do |path|
      stream_store do |store|
        seen = [] of {Int32, Int32?}
        result = Gori::Import.import_file(store, :har, path,
          progress: ->(done : Int32, total : Int32?) { seen << {done, total} })
        result.count.should eq(n)
        result.attempted.should eq(n)
        result.short?.should be_false
        seen.should eq([{Gori::Import::IMPORT_CHUNK, nil}, {n, nil}])
        store.count.should eq(n.to_i64)
      end
    end
  end

  it "names the flows it wrote when the file turns out to be invalid JSON after them" do
    n = Gori::Import::IMPORT_CHUNK + 1
    body = String.build do |io|
      io << %({"log":{"entries":[)
      n.times { |i| io << "," if i > 0; io << har_entry(i) }
      io << %(, {"request": {"method": "GET" "url": "broken"}}]}}) # a missing comma
    end
    with_har(body) do |path|
      stream_store do |store|
        ex = expect_raises(Gori::Error, /not valid JSON/) { Gori::Import.import_file(store, :har, path) }
        ex.message.not_nil!.should contain("#{Gori::Import::IMPORT_CHUNK} flows from the entries before it were written")
        store.count.should eq(Gori::Import::IMPORT_CHUNK.to_i64)
      end
    end
  end

  it "stops after the chunk in flight once cancelled, and reports a short import" do
    n = Gori::Import::IMPORT_CHUNK * 2 + 1
    body = String.build do |io|
      io << %({"log":{"entries":[)
      n.times { |i| io << "," if i > 0; io << har_entry(i) }
      io << "]}}"
    end
    with_har(body) do |path|
      stream_store do |store|
        stop = false
        result = Gori::Import.import_file(store, :har, path,
          cancelled: -> { stop },
          progress: ->(_done : Int32, _total : Int32?) { stop = true })
        result.count.should eq(Gori::Import::IMPORT_CHUNK)
        store.count.should eq(Gori::Import::IMPORT_CHUNK.to_i64)
      end
    end
  end

  it "still reports an all-malformed file with its count" do
    with_har(%({"log":{"entries":[{"request":{"method":"GET","url":""}},{"request":{"method":"GET","url":""}}]}})) do |path|
      stream_store do |store|
        expect_raises(Gori::Error, /all 2 entries were skipped as malformed/) { Gori::Import.import_file(store, :har, path) }
      end
    end
  end
end
