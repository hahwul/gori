require "../spec_helper"

private def with_store(&)
  path = File.tempname("gori-oast-test", ".db")
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

describe "OAST persistence (V39)" do
  it "migrates to the current schema version with the OAST tables" do
    with_store do |store|
      store.@db.scalar("PRAGMA user_version").should eq(Gori::Store::Schema::VERSION)
      # tables exist + are queryable
      store.oast_providers.should be_empty
      store.oast_sessions.should be_empty
    end
  end

  it "round-trips providers with enable + delete" do
    with_store do |store|
      id = store.insert_oast_provider("Public Interactsh", "interactsh", "https://oast.pro", nil, true, 0)
      id.should be > 0
      store.insert_oast_provider("My BOAST", "BOAST", "https://odiss.eu:2096/events", "sekret", true, 1)
      list = store.oast_providers
      list.size.should eq(2)
      list.first.name.should eq("Public Interactsh")
      list.first.enabled?.should be_true

      store.set_oast_provider_enabled(id, false)
      store.oast_providers.find { |p| p.id == id }.not_nil!.enabled?.should be_false

      store.update_oast_provider(id, "Renamed", "interactsh", "https://oast.live", "tok", true)
      updated = store.oast_providers.find { |p| p.id == id }.not_nil!
      updated.name.should eq("Renamed")
      updated.host.should eq("https://oast.live")
      updated.token.should eq("tok")

      store.delete_oast_provider(id)
      store.oast_providers.size.should eq(1)
    end
  end

  it "persists a session incl. the RSA private key PEM and deletes with its callbacks" do
    with_store do |store|
      sid = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr20", "sec13",
        "-----BEGIN PRIVATE KEY-----\nAAA\n-----END PRIVATE KEY-----", nil)
      sid.should be > 0
      s = store.get_oast_session(sid).not_nil!
      s.kind.should eq("interactsh")
      s.correlation_id.should eq("corr20")
      s.private_key_pem.not_nil!.should contain("BEGIN PRIVATE KEY")

      store.insert_oast_callback(sid, "uid-1", "dns", "A", "1.2.3.4", "corr20abc.oast.pro",
        "raw".to_slice, nil, 1000_i64)
      store.oast_callbacks(sid).size.should eq(1)

      store.delete_oast_session(sid)
      store.get_oast_session(sid).should be_nil
      store.oast_callbacks(sid).should be_empty # cascade removed the callback
    end
  end

  it "dedups callbacks by (session_id, provider_uid) and loads incrementally" do
    with_store do |store|
      sid = store.insert_oast_session(nil, "custom-http", "https://x/log", "c", "", nil, nil)
      store.insert_oast_callback(sid, "uid-1", "http", "GET", "10.0.0.1", "x", "a".to_slice, nil, 10_i64)
      store.insert_oast_callback(sid, "uid-1", "http", "GET", "10.0.0.1", "x", "a".to_slice, nil, 11_i64) # dup
      store.insert_oast_callback(sid, "uid-2", "http", "POST", "10.0.0.2", "x", "b".to_slice, nil, 12_i64)

      all = store.oast_callbacks(sid)
      all.size.should eq(2) # the duplicate uid-1 was ignored
      all.map(&.provider_uid).should eq(["uid-1", "uid-2"])

      # incremental watermark: only rows after the first id
      first_id = all.first.id
      store.oast_callbacks(sid, since_id: first_id).map(&.provider_uid).should eq(["uid-2"])
    end
  end
end
