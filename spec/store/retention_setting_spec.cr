require "../spec_helper"
require "file_utils"

private def sample_request(target = "/")
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64,
    scheme: "http",
    host: "acme.test",
    port: 80,
    method: "GET",
    target: target,
    http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    body: nil,
  )
end

private def with_temp_home(&)
  dir = File.tempname("gori-retention-home")
  Dir.mkdir_p(dir)
  prev = ENV["GORI_HOME"]?
  prev_cap = Gori::Settings.retention_max_flows
  begin
    ENV["GORI_HOME"] = dir
    yield dir
  ensure
    prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
    Gori::Settings.retention_max_flows = prev_cap
    FileUtils.rm_rf(dir)
  end
end

describe "retention settings" do
  # Retention was NOT new — Store has swept since long before this section. What was missing is
  # any way to see or change the cap, so the first thing to pin is that the exposed default is
  # the number that was already in force, not a new policy.
  it "defaults to the cap Store was already enforcing" do
    Gori::Settings::DEFAULT_RETENTION_FLOWS.should eq(Gori::Store::RETENTION_DEFAULT)
    Gori::Settings.retention_max_flows.should eq(Gori::Store::RETENTION_DEFAULT)
  end

  it "reports the configured cap through retention_flows" do
    Gori::Settings.retention_max_flows = 250
    Gori::Settings.retention_flows.should eq(250)
  ensure
    Gori::Settings.retention_max_flows = Gori::Settings::DEFAULT_RETENTION_FLOWS
  end

  # 0 is the documented "unlimited", and Store's sweep tests `<= 0`. A hand-edited negative must
  # read the same way rather than reaching the sweep as a strange value.
  it "treats 0 and a negative value alike as unlimited" do
    Gori::Settings.retention_max_flows = 0
    Gori::Settings.retention_flows.should eq(0)
    Gori::Settings.retention_max_flows = -5
    Gori::Settings.retention_flows.should eq(0)
  ensure
    Gori::Settings.retention_max_flows = Gori::Settings::DEFAULT_RETENTION_FLOWS
  end

  describe "persistence" do
    it "round-trips a changed cap and clamps a negative on load" do
      with_temp_home do |dir|
        Gori::Settings.retention_max_flows = 5_000
        Gori::Settings.save.should be_true
        File.read(Gori::Settings.path).should contain(%("retention"))

        Gori::Settings.retention_max_flows = Gori::Settings::DEFAULT_RETENTION_FLOWS
        Gori::Settings.load
        Gori::Settings.retention_max_flows.should eq(5_000)

        File.write(File.join(dir, "settings.json"), %({"retention":{"max_flows":-3}}))
        Gori::Settings.load
        Gori::Settings.retention_max_flows.should eq(0) # clamped, not stored as -3
      end
    end

    # Same discipline as the other optional sections: an untouched install writes no key for a
    # value nobody chose.
    it "omits the section at the factory default" do
      with_temp_home do
        Gori::Settings.retention_max_flows = Gori::Settings::DEFAULT_RETENTION_FLOWS
        Gori::Settings.save.should be_true
        File.read(Gori::Settings.path).should_not contain(%("retention"))
      end
    end
  end

  describe ".retention_error" do
    it "accepts a whole number and 0" do
      Gori::Settings.retention_error("100000").should be_nil
      Gori::Settings.retention_error("0").should be_nil
      Gori::Settings.retention_error(" 42 ").should be_nil
    end

    it "rejects a non-number and a negative" do
      Gori::Settings.retention_error("lots").to_s.should contain("whole number")
      Gori::Settings.retention_error("").to_s.should contain("whole number")
      Gori::Settings.retention_error("-1").to_s.should contain("cannot be negative")
    end
  end

  # The sweep itself is Store's, and store_spec already covers it. What matters here is that the
  # value an operator sets is the value the sweep uses — the link that did not exist before.
  describe "the configured cap reaches the sweep" do
    it "keeps only the newest max_flows flows when a capture-owning store passes it" do
      path = File.tempname("gori-retention", ".db")
      db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
      Gori::Store::Schema.migrate!(db)
      # A capture owner passes Settings.retention_flows; prune_interval is squeezed so the sweep
      # fires within the example rather than after 2000 inserts.
      Gori::Settings.retention_max_flows = 5
      store = Gori::Store.new(db, nil, retention_flows: Gori::Settings.retention_flows, prune_interval: 10)
      begin
        (1..12).each { |i| store.insert_flow(sample_request(target: "/#{i}")) }
        # The sweep fired after the 10th insert (cutoff = 10 - 5), keeping ids 6-10; 11 and 12
        # landed afterwards. The operator's 5 — not Store::RETENTION_DEFAULT — set that window.
        store.count.should eq(7_i64)
      ensure
        store.close
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
        Gori::Settings.retention_max_flows = Gori::Settings::DEFAULT_RETENTION_FLOWS
      end
    end
  end
end
