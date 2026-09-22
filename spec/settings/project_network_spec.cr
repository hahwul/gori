require "../spec_helper"

# #1115 — the per-key planner behind `gori run project network`. The rows it plans are the
# ones the TUI's Project settings card writes, so the invariants that card keeps (credentials
# pin the upstream they were entered for, a busy store cannot split them) have to hold here too,
# while the one thing the card must do and a single-key command must not — fold a value equal
# to the global back to "inherit" — stays out.

# The globals `project_network_inherited` reads, restored so an example cannot leak its global
# upstream into the next file's routing specs.
private def with_net_globals(upstream : String = "", &)
  prev = {Gori::Settings.upstream_proxy, Gori::Settings.bind_host, Gori::Settings.bind_port,
          Gori::Settings.connect_timeout_secs, Gori::Settings.io_timeout_secs,
          Gori::Settings.capture_max_mib}
  begin
    Gori::Settings.upstream_proxy = upstream
    Gori::Settings.bind_host = "127.0.0.1"
    Gori::Settings.bind_port = 8070
    Gori::Settings.connect_timeout_secs = 30
    Gori::Settings.io_timeout_secs = 30
    Gori::Settings.capture_max_mib = 2
    yield
  ensure
    Gori::Settings.upstream_proxy = prev[0]
    Gori::Settings.bind_host = prev[1]
    Gori::Settings.bind_port = prev[2]
    Gori::Settings.connect_timeout_secs = prev[3]
    Gori::Settings.io_timeout_secs = prev[4]
    Gori::Settings.capture_max_mib = prev[5]
  end
end

private def net_key(name : String) : Gori::Settings::ProjectNetworkKey
  Gori::Settings.project_network_key(name).not_nil!
end

private def plan_set(current : Hash(String, String), name : String, value : String,
                     password : String? = nil) : {Gori::Settings::ProjectNetworkEdit?, String?}
  Gori::Settings.plan_project_network_set(current, net_key(name), value, password)
end

private def rows_of(edit : Gori::Settings::ProjectNetworkEdit?) : Array({String, String?})
  edit.not_nil!.rows
end

private AUTH_KEY     = Gori::Settings::PROJECT_UPSTREAM_AUTH_KEY
private UPSTREAM_KEY = Gori::Settings::PROJECT_UPSTREAM_KEY

describe "Gori::Settings project network keys (#1115)" do
  # The table is the ONE list the headless surface reads. A key `load_project_network` starts
  # reading without an entry here would be a setting no command can reach — the exact state
  # #1115 was filed about — so the constants in network.cr are the reference, read off the source.
  it "lists exactly the net.* keys network.cr declares" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "settings", "network.cr"))
    declared = src.scan(/(?m)^\s*PROJECT_[A-Z_]+_KEY\s*=\s*"(net\.[a-z_]+)"/).map(&.[1]).to_set
    declared.size.should eq(8)
    Gori::Settings::PROJECT_NETWORK_KEYS.map(&.key).to_set.should eq(declared)
    Gori::Settings::PROJECT_NETWORK_KEYS.map { |k| {k.key, "net.#{k.name}"} }.each { |(row, want)| row.should eq(want) }
  end

  it "finds a key by its short name or its row name, in any case" do
    net_key("upstream_proxy").key.should eq(UPSTREAM_KEY)
    net_key("net.upstream_proxy").key.should eq(UPSTREAM_KEY)
    net_key(" NET.Capture_Max_MiB ").key.should eq(Gori::Settings::PROJECT_CAPTURE_MAX_KEY)
    Gori::Settings.project_network_key("upstream").should be_nil
    Gori::Settings.project_network_key("network.upstream_proxy").should be_nil
  end

  describe "set upstream_proxy" do
    it "pins a valid proxy URI as written" do
      with_net_globals do
        edit, err = plan_set({} of String => String, "upstream_proxy", " http://proxy.corp.test:3128 ")
        err.should be_nil
        rows_of(edit).should eq([{UPSTREAM_KEY, "http://proxy.corp.test:3128"}])
        edit.not_nil!.audit.should contain("http://proxy.corp.test:3128")
      end
    end

    it "refuses a URI carrying credentials, and never writes it" do
      with_net_globals do
        edit, err = plan_set({} of String => String, "upstream_proxy", "http://bob:hunter2@proxy.test:8080")
        edit.should be_nil
        err.not_nil!.should contain("credentials")
      end
    end

    it "refuses an unsupported scheme" do
      with_net_globals do
        _, err = plan_set({} of String => String, "upstream_proxy", "ftp://proxy.test:21")
        err.should_not be_nil
      end
    end

    # The fold the TUI card has to make would turn this into "inherit" whenever the global is
    # blank too — and inheriting lets upstream_rules and HTTPS_PROXY route the project through a
    # proxy, the opposite of what an empty pin asks for.
    it "pins an EMPTY value as a direct route even when the global is blank" do
      with_net_globals(upstream: "") do
        edit, err = plan_set({} of String => String, "upstream_proxy", "")
        err.should be_nil
        rows_of(edit).should eq([{UPSTREAM_KEY, ""}])
        edit.not_nil!.notes.join.should contain("direct")
      end
    end

    it "pins a value equal to the global, and says that it did" do
      with_net_globals(upstream: "http://g.test:8080") do
        edit, _ = plan_set({} of String => String, "upstream_proxy", "http://g.test:8080")
        rows_of(edit).should eq([{UPSTREAM_KEY, "http://g.test:8080"}])
        edit.not_nil!.notes.join.should contain("pinned anyway")
      end
    end

    # Credentials follow the address in the SAME task, re-derived for it: the proxy kind decides
    # the method, exactly as the Project settings card re-derives them on save.
    it "moves stored credentials to the new upstream in the same edit, re-deriving the method" do
      with_net_globals do
        auth = Gori::Settings::ProjectProxyAuth.new("basic", "alice", "s3cret")
        current = {UPSTREAM_KEY => "http://old.test:8080", AUTH_KEY => auth.to_json}
        edit, err = plan_set(current, "upstream_proxy", "socks5://new.test:1080")
        err.should be_nil
        rows = rows_of(edit)
        rows.map(&.[0]).should eq([UPSTREAM_KEY, AUTH_KEY])
        moved = Gori::Settings::ProjectProxyAuth.parse?(rows[1][1].not_nil!).not_nil!
        moved.method.should eq("socks5")
        moved.username.should eq("alice")
        moved.password.should eq("s3cret")
        # …and the audit line carries neither half of the credential.
        edit.not_nil!.audit.should_not contain("s3cret")
        edit.not_nil!.audit.should_not contain("alice")
      end
    end

    it "refuses a direct pin while credentials are pinned to the upstream" do
      with_net_globals do
        auth = Gori::Settings::ProjectProxyAuth.new("basic", "alice", "s3cret")
        edit, err = plan_set({UPSTREAM_KEY => "http://p.test:8080", AUTH_KEY => auth.to_json},
          "upstream_proxy", "")
        edit.should be_nil
        err.not_nil!.should contain("unset upstream_auth")
      end
    end

    it "refuses to move credentials that no longer parse" do
      with_net_globals do
        edit, err = plan_set({UPSTREAM_KEY => "http://p.test:8080", AUTH_KEY => %({"method":"basic"})},
          "upstream_proxy", "http://q.test:8080")
        edit.should be_nil
        err.not_nil!.should contain("malformed")
      end
    end
  end

  describe "set upstream_auth" do
    it "needs a password" do
      with_net_globals(upstream: "http://g.test:8080") do
        edit, err = plan_set({} of String => String, "upstream_auth", "alice")
        edit.should be_nil
        err.not_nil!.should contain("password")
      end
    end

    it "refuses when the project would dial direct" do
      with_net_globals(upstream: "") do
        edit, err = plan_set({} of String => String, "upstream_auth", "alice", "pw")
        edit.should be_nil
        err.not_nil!.should contain("requires an upstream proxy")
      end
    end

    # An inherited upstream is PINNED alongside the credentials, so a later global edit cannot
    # carry the password to a proxy it was never entered for.
    it "pins the inherited global upstream in the same edit" do
      with_net_globals(upstream: "http://g.test:8080") do
        edit, err = plan_set({} of String => String, "upstream_auth", "alice", "pw")
        err.should be_nil
        rows = rows_of(edit)
        rows[0].should eq({UPSTREAM_KEY, "http://g.test:8080"})
        auth = Gori::Settings::ProjectProxyAuth.parse?(rows[1][1].not_nil!).not_nil!
        {auth.method, auth.username, auth.password}.should eq({"basic", "alice", "pw"})
        edit.not_nil!.notes.join.should contain("pinned")
      end
    end

    it "validates against the project's own upstream when it has one" do
      with_net_globals(upstream: "http://g.test:8080") do
        edit, err = plan_set({UPSTREAM_KEY => "socks5h://s.test:1080"}, "upstream_auth", "alice", "pw")
        err.should be_nil
        rows = rows_of(edit)
        rows[0].should eq({UPSTREAM_KEY, "socks5h://s.test:1080"})
        Gori::Settings::ProjectProxyAuth.parse?(rows[1][1].not_nil!).not_nil!.method.should eq("socks5")
      end
    end

    it "refuses a Basic username carrying ':'" do
      with_net_globals(upstream: "http://g.test:8080") do
        _, err = plan_set({} of String => String, "upstream_auth", "a:b", "pw")
        err.not_nil!.should contain(":")
      end
    end
  end

  describe "set upstream_destination_host" do
    it "stores a host pattern" do
      edit, err = plan_set({} of String => String, "upstream_destination_host", "*.corp.test")
      err.should be_nil
      rows_of(edit).should eq([{Gori::Settings::PROJECT_UPSTREAM_DESTINATION_KEY, "*.corp.test"}])
    end

    # An absent row IS `*`, so `*` clears the row rather than storing a second spelling of it.
    it "clears the row for *" do
      edit, _ = plan_set({} of String => String, "upstream_destination_host", "*")
      rows_of(edit).should eq([{Gori::Settings::PROJECT_UPSTREAM_DESTINATION_KEY, nil}])
    end

    it "refuses a URL" do
      _, err = plan_set({} of String => String, "upstream_destination_host", "https://corp.test")
      err.should_not be_nil
    end
  end

  describe "the numeric and bind keys" do
    it "stores a whole number normalized, so it reads back the way it prints" do
      with_net_globals do
        edit, _ = plan_set({} of String => String, "connect_timeout_secs", "007")
        rows_of(edit).should eq([{Gori::Settings::PROJECT_CONNECT_TIMEOUT_KEY, "7"}])
      end
    end

    it "refuses zero, a fraction, junk, and a capture cap past the Int32-safe ceiling" do
      with_net_globals do
        plan_set({} of String => String, "io_timeout_secs", "0")[1].should_not be_nil
        plan_set({} of String => String, "io_timeout_secs", "1.5")[1].should_not be_nil
        plan_set({} of String => String, "connect_timeout_secs", "12abc")[1].should_not be_nil
        plan_set({} of String => String, "capture_max_mib",
          (Gori::Settings::MAX_CAPTURE_MAX_MIB + 1).to_s)[1].should_not be_nil
        plan_set({} of String => String, "capture_max_mib",
          Gori::Settings::MAX_CAPTURE_MAX_MIB.to_s)[1].should be_nil
      end
    end

    it "accepts the bind port range the Project settings card accepts" do
      with_net_globals do
        plan_set({} of String => String, "bind_port", "0")[1].should be_nil
        plan_set({} of String => String, "bind_port", "65535")[1].should be_nil
        plan_set({} of String => String, "bind_port", "65536")[1].should_not be_nil
      end
    end

    it "refuses an empty or malformed bind host" do
      with_net_globals do
        plan_set({} of String => String, "bind_host", " ")[1].not_nil!.should contain("unset")
        plan_set({} of String => String, "bind_host", "999.999.1.1")[1].should_not be_nil
        plan_set({} of String => String, "bind_host", "0.0.0.0")[1].should be_nil
      end
    end

    it "pins a value equal to the global and says so, rather than folding it to inherit" do
      with_net_globals do
        edit, _ = plan_set({} of String => String, "capture_max_mib", "2")
        rows_of(edit).should eq([{Gori::Settings::PROJECT_CAPTURE_MAX_KEY, "2"}])
        edit.not_nil!.notes.join.should contain("unset capture_max_mib")
      end
    end
  end

  describe "unset" do
    it "drops the row" do
      edit, err = Gori::Settings.plan_project_network_unset(
        {Gori::Settings::PROJECT_IO_TIMEOUT_KEY => "9"}, net_key("io_timeout_secs"))
      err.should be_nil
      rows_of(edit).should eq([{Gori::Settings::PROJECT_IO_TIMEOUT_KEY, nil}])
    end

    it "is not an error for a key that is not set — it already inherits" do
      edit, err = Gori::Settings.plan_project_network_unset({} of String => String, net_key("bind_port"))
      err.should be_nil
      rows_of(edit).should be_empty
      edit.not_nil!.notes.join.should contain("already inherits")
    end

    it "refuses to drop the upstream pin out from under stored credentials" do
      auth = Gori::Settings::ProjectProxyAuth.new("basic", "alice", "s3cret")
      edit, err = Gori::Settings.plan_project_network_unset(
        {UPSTREAM_KEY => "http://p.test:8080", AUTH_KEY => auth.to_json}, net_key("upstream_proxy"))
      edit.should be_nil
      err.not_nil!.should contain("unset upstream_auth first")
    end

    it "drops credentials and says the pin they held stays" do
      auth = Gori::Settings::ProjectProxyAuth.new("basic", "alice", "s3cret")
      edit, _ = Gori::Settings.plan_project_network_unset(
        {UPSTREAM_KEY => "http://p.test:8080", AUTH_KEY => auth.to_json}, net_key("upstream_auth"))
      rows_of(edit).should eq([{AUTH_KEY, nil}])
      edit.not_nil!.notes.join.should contain("stays")
    end
  end

  describe ".apply_project_network_edit" do
    it "writes the credential pair in one task, loads back as the live route, and audits without the secret" do
      with_net_globals(upstream: "http://g.test:8080") do
        with_store do |store|
          edit, _ = plan_set(Gori::Settings.project_network_rows(store), "upstream_auth", "alice", "s3cret")
          Gori::Settings.apply_project_network_edit(store, edit.not_nil!).should be_true
          store.setting(UPSTREAM_KEY).should eq("http://g.test:8080")
          Gori::Settings.project_network_rows(store).keys.to_set.should eq({UPSTREAM_KEY, AUTH_KEY}.to_set)

          # The rows are the ones every surface's loader reads, so the next open dials through them.
          begin
            Gori::Settings.load_project_network(store, bind: false)
            Gori::Settings.effective_upstream_proxy.should eq("http://g.test:8080")
            Gori::Settings.project_upstream_auth.not_nil!.username.should eq("alice")
          ensure
            Gori::Settings.project_upstream_proxy = nil
            Gori::Settings.project_upstream_auth = nil
            Gori::Settings.project_upstream_auth_error = nil
          end

          store.flush
          rows = store.events_recent(20, source: Gori::ConfigLog::SOURCE).rows
          rows.map(&.kind).should contain("network")
          rows.each do |r|
            r.message.should_not contain("s3cret")
            r.message.should_not contain("alice")
          end
        end
      end
    end

    it "records nothing for an edit with no rows" do
      with_store do |store|
        edit, _ = Gori::Settings.plan_project_network_unset({} of String => String, net_key("bind_host"))
        Gori::Settings.apply_project_network_edit(store, edit.not_nil!).should be_true
        store.flush
        store.events_recent(20, source: Gori::ConfigLog::SOURCE).rows.should be_empty
      end
    end
  end
end
