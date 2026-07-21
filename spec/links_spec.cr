require "./spec_helper"

# In-memory Store on a tempfile (mirrors spec/store/entity_links_spec.cr).
private def with_store(&)
  path = File.tempname("gori-links", ".db")
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

# Build an EntityLink directly — resolve only reads ref_kind + ref_id, so we can
# skip the whole issues/notes owner machinery.
private def link_for(kind : Gori::Store::LinkRefKind, ref_id : Int64) : Gori::Store::EntityLink
  Gori::Store::EntityLink.new(1_i64, Gori::Store::LinkOwnerKind::Issue, 1_i64, kind, ref_id, 1_i64)
end

# Insert a flow and return its committed id.
private def insert_flow_row(store, *, host : String, target : String, method : String = "GET",
                            scheme : String = "http", port : Int32 = 80) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: scheme, host: host, port: port, method: method,
    target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

describe Gori::Links do
  describe ".resolve (flow)" do
    it "labels a gone flow as '(gone)' and marks it stale" do
      with_store do |store|
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Flow, 777_i64))
        r.tag.should eq("hist")
        r.label.should eq("flow #777 (gone)")
        r.url.should eq("flow #777")
        r.stale?.should be_true
      end
    end

    it "labels a present flow '<method> <location>' with url == row.url and not stale" do
      with_store do |store|
        fid = insert_flow_row(store, host: "a.test", target: "/x")
        row = store.flow_row(fid).not_nil!
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Flow, fid))
        r.tag.should eq("hist")
        r.label.should eq("GET a.test/x")
        r.url.should eq("http://a.test/x")
        r.url.should eq(row.url)
        r.stale?.should be_false
      end
    end

    it "uses a target starting with 'http' verbatim as the location" do
      with_store do |store|
        fid = insert_flow_row(store, host: "a.test", target: "http://a.test:8080/abs")
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Flow, fid))
        r.label.should eq("GET http://a.test:8080/abs")
        # row.url returns absolute-form targets verbatim (no doubled authority).
        r.url.should eq("http://a.test:8080/abs")
        r.stale?.should be_false
      end
    end

    it "prefixes host to a relative target (origin-form) for the location" do
      with_store do |store|
        fid = insert_flow_row(store, host: "shop.example", target: "/cart?id=1", method: "POST")
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Flow, fid))
        r.label.should eq("POST shop.example/cart?id=1")
      end
    end

    it "treats a schemeless 'http'-prefixed target as verbatim (best-effort location)" do
      # flow_location checks starts_with?("http") loosely; a schemeless host that
      # begins with "http" is passed through as-is. Documented as best-effort.
      with_store do |store|
        fid = insert_flow_row(store, host: "a.test", target: "httpbin.org/x")
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Flow, fid))
        r.label.should eq("GET httpbin.org/x")
      end
    end

    it "preserves a multibyte/CJK target intact in the location" do
      with_store do |store|
        fid = insert_flow_row(store, host: "검색.test", target: "/검색?q=안녕")
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Flow, fid))
        r.label.should eq("GET 검색.test/검색?q=안녕")
        r.stale?.should be_false
      end
    end
  end

  describe "Resolved#line" do
    it "renders '[<tag>] <label>' exactly" do
      with_store do |store|
        fid = insert_flow_row(store, host: "a.test", target: "/x")
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Flow, fid))
        r.line.should eq("[hist] GET a.test/x")
      end
    end

    it "renders a gone flow line" do
      with_store do |store|
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Flow, 5_i64))
        r.line.should eq("[hist] flow #5 (gone)")
      end
    end
  end

  describe ".resolve (repeater)" do
    it "marks a gone repeater stale with a '(gone)' label and tag 'repeater'" do
      with_store do |store|
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, 42_i64))
        r.tag.should eq("repeater")
        r.label.should eq("repeater #42 (gone)")
        r.url.should eq("repeater #42")
        r.stale?.should be_true
        r.line.should eq("[repeater] repeater #42 (gone)")
      end
    end

    it "prefers the custom name for a present repeater" do
      with_store do |store|
        id = store.insert_repeater("https://t.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, false, nil, 0)
        store.set_repeater_name(id, "my tab")
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
        r.label.should eq("my tab")
        r.url.should eq("https://t.test")
        r.stale?.should be_false
      end
    end

    it "falls back to the request's first line when unnamed" do
      with_store do |store|
        id = store.insert_repeater("https://t.test", "GET /a HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice, false, false, nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
        r.label.should eq("GET /a HTTP/1.1")
        r.stale?.should be_false
      end
    end

    it "falls back to 'repeater #N' when unnamed and the request is all-blank" do
      with_store do |store|
        id = store.insert_repeater("https://t.test", "\r\n   \r\n\r\n".to_slice, false, false, nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
        r.label.should eq("repeater ##{id}")
      end
    end

    it "falls back to 'repeater #N' when unnamed and the request is empty" do
      with_store do |store|
        id = store.insert_repeater("https://t.test", "".to_slice, false, false, nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
        r.label.should eq("repeater ##{id}")
      end
    end
  end

  describe ".resolve (fuzz)" do
    it "marks a gone fuzz session stale with a '(gone)' label and tag 'fuzz'" do
      with_store do |store|
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Fuzz, 9_i64))
        r.tag.should eq("fuzz")
        r.label.should eq("fuzz #9 (gone)")
        r.url.should eq("fuzz #9")
        r.stale?.should be_true
      end
    end

    it "prefers the name, else the template's first line for a present session" do
      with_store do |store|
        named = store.insert_fuzz_session("https://f.test", "GET /§x§ HTTP/1.1\r\n\r\n", false, nil, "{}", nil, 0, "attack A")
        r1 = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Fuzz, named))
        r1.label.should eq("attack A")
        r1.url.should eq("https://f.test")
        r1.stale?.should be_false

        unnamed = store.insert_fuzz_session("https://f.test", "POST /login HTTP/1.1\r\nHost: f.test\r\n\r\n", false, nil, "{}", nil, 1)
        r2 = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Fuzz, unnamed))
        r2.label.should eq("POST /login HTTP/1.1")
      end
    end
  end

  describe ".resolve (miner)" do
    it "marks a gone miner session stale with a '(gone)' label and tag 'miner'" do
      with_store do |store|
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Miner, 3_i64))
        r.tag.should eq("miner")
        r.label.should eq("miner #3 (gone)")
        r.url.should eq("miner #3")
        r.stale?.should be_true
      end
    end

    it "derives the label from the byte-exact request's first line when unnamed" do
      with_store do |store|
        req = "GET /params HTTP/1.1\r\nHost: m.test\r\n\r\n".to_slice
        id = store.insert_miner_session("https://m.test", req, false, nil, "{}", nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Miner, id))
        r.label.should eq("GET /params HTTP/1.1")
        r.url.should eq("https://m.test")
        r.stale?.should be_false
      end
    end

    it "falls back to 'miner #N' when unnamed and the request bytes are empty" do
      with_store do |store|
        id = store.insert_miner_session("https://m.test", Bytes.new(0), false, nil, "{}", nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Miner, id))
        r.label.should eq("miner ##{id}")
      end
    end
  end

  describe "first_line (via label fallback)" do
    it "skips leading blank lines and returns the first non-blank line" do
      with_store do |store|
        id = store.insert_repeater("https://t.test", "\r\n\r\n   \r\nGET /deep HTTP/1.1\r\n\r\n".to_slice, false, false, nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
        r.label.should eq("GET /deep HTTP/1.1")
      end
    end

    it "strips a trailing CR from the returned line" do
      with_store do |store|
        # No trailing LF on the first line; rstrip('\r') must drop the CR.
        id = store.insert_repeater("https://t.test", "GET /x HTTP/1.1\r".to_slice, false, false, nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
        r.label.should eq("GET /x HTTP/1.1")
      end
    end

    it "preserves a multibyte/CJK first line intact" do
      with_store do |store|
        id = store.insert_repeater("https://t.test", "GET /검색 HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice, false, false, nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
        r.label.should eq("GET /검색 HTTP/1.1")
      end
    end

    it "returns an all-emoji first line intact" do
      with_store do |store|
        id = store.insert_repeater("https://t.test", "GET /🔥/世界 HTTP/1.1\r\n\r\n".to_slice, false, false, nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
        r.label.should eq("GET /🔥/世界 HTTP/1.1")
      end
    end

    it "handles a huge run of blank lines quickly (linear robustness)" do
      with_store do |store|
        req = ("\r\n" * 100_000) + "GET /late HTTP/1.1\r\n"
        id = store.insert_repeater("https://t.test", req.to_slice, false, false, nil, 0)
        elapsed = Time.measure do
          r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Repeater, id))
          r.label.should eq("GET /late HTTP/1.1")
        end
        elapsed.total_seconds.should be < 5.0
      end
    end

    it "does not raise on a miner request with invalid UTF-8 bytes" do
      with_store do |store|
        # 0xFF is never valid UTF-8; String.new lossily replaces it. Must not crash.
        req = Bytes[0x47, 0x45, 0x54, 0x20, 0xFF, 0x0D, 0x0A] # "GET \xFF\r\n"
        id = store.insert_miner_session("https://m.test", req, false, nil, "{}", nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Miner, id))
        r.stale?.should be_false
        r.label.empty?.should be_false
      end
    end

    it "returns the miner default when the request bytes are all blank lines" do
      with_store do |store|
        id = store.insert_miner_session("https://m.test", "\r\n\r\n".to_slice, false, nil, "{}", nil, 0)
        r = Gori::Links.resolve(store, link_for(Gori::Store::LinkRefKind::Miner, id))
        r.label.should eq("miner ##{id}")
      end
    end
  end

  describe ".resolve_all" do
    it "returns an empty array for an empty input" do
      with_store do |store|
        Gori::Links.resolve_all(store, [] of Gori::Store::EntityLink).should be_empty
      end
    end

    it "preserves order and per-element stale flags over a mixed present/stale array" do
      with_store do |store|
        fid = insert_flow_row(store, host: "a.test", target: "/x")
        rid = store.insert_repeater("https://t.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, false, nil, 0)

        links = [
          link_for(Gori::Store::LinkRefKind::Flow, fid),      # present
          link_for(Gori::Store::LinkRefKind::Flow, 999_i64),  # gone
          link_for(Gori::Store::LinkRefKind::Repeater, rid),  # present
          link_for(Gori::Store::LinkRefKind::Miner, 888_i64), # gone
        ]
        resolved = Gori::Links.resolve_all(store, links)

        resolved.size.should eq(4)
        resolved.map(&.stale?).should eq([false, true, false, true])
        resolved[0].label.should eq("GET a.test/x")
        resolved[1].label.should eq("flow #999 (gone)")
        resolved[2].label.should eq("GET /a HTTP/1.1")
        resolved[3].label.should eq("miner #888 (gone)")
        resolved.map(&.tag).should eq(["hist", "hist", "repeater", "miner"])
      end
    end
  end
end
