require "./spec_helper"
require "file_utils"
require "socket"

# Origin that accepts a connection and reads the request head but never responds,
# so the proxy blocks on read_response_head with a Pending flow in the store.
private def start_hanging_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      sleep # hang — no response
    end
  end
  port
end

private def with_root(&)
  root = File.tempname("gori-projects")
  begin
    yield root
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe Gori::ProjectRegistry do
  it "creates a named project with a slugified directory" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("ACME Red Team!")
      p.name.should eq("ACME Red Team!") # display name preserved
      p.db_path.should eq(File.join(root, "acme-red-team", "gori.db"))
      Dir.exists?(p.dir).should be_true
      p.ephemeral?.should be_false
    end
  end

  it "finds a project by display name or directory slug" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("ACME Red Team!")
      Gori::Store.open(p.db_path).close # list/find only sees dirs with a DB file
      reg.find("ACME Red Team!").try(&.db_path).should eq(p.db_path)
      reg.find("acme-red-team").try(&.db_path).should eq(p.db_path)
      reg.find("ACME-RED-TEAM").try(&.db_path).should eq(p.db_path)
      reg.find("missing").should be_nil
    end
  end

  it "lists created projects (and ignores temp/hidden dirs)" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      a = reg.create("alpha")
      Gori::Store.open(a.db_path).close # give it a real DB file so it lists
      reg.temp("xyz")                   # hidden temp dir, must not be listed

      names = reg.list.map(&.name)
      names.should contain("alpha")
      names.should_not contain("temp")
    end
  end

  it "makes temp projects ephemeral and cleans them up" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      t = reg.temp("tok123")
      t.ephemeral?.should be_true
      Dir.exists?(t.dir).should be_true
      t.cleanup
      Dir.exists?(t.dir).should be_false
    end
  end

  it "deletes a project from disk" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("doomed")
      Gori::Store.open(p.db_path).close
      reg.delete(p)
      Dir.exists?(p.dir).should be_false
      reg.list.map(&.name).should_not contain("doomed")
    end
  end

  it "persists the verbatim display name so list doesn't revert it to the slug" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("ACME Red Team!")
      Gori::Store.open(p.db_path).close
      # A fresh registry (as on TUI restart / `gori run project`) must still show the
      # verbatim name, not the lossy directory slug "acme-red-team".
      Gori::ProjectRegistry.new(root).list.map(&.name).should contain("ACME Red Team!")
    end
  end

  it "refuses to delete a project a live instance is capturing into (no silent orphan)" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("busy")
      Gori::Store.open(p.db_path).close
      lock = Gori::CaptureLock.try(p.dir).not_nil! # simulate a live capturer holding the lock
      begin
        expect_raises(Gori::Error, /in use/) { reg.delete(p) }
        Dir.exists?(p.dir).should be_true # not wiped out from under the capturer
      ensure
        lock.close
      end
      reg.delete(p) # lock released → deletion proceeds
      Dir.exists?(p.dir).should be_false
    end
  end

  it "renames the display name without moving the project directory" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("old name")
      Gori::Store.open(p.db_path).close
      dir_before = p.dir
      renamed = reg.rename(p, "New Label!")
      renamed.name.should eq("New Label!")
      renamed.dir.should eq(dir_before) # slug stays put
      # Fresh registry (picker restart) must surface the new label, not the slug.
      Gori::ProjectRegistry.new(root).list.map(&.name).should contain("New Label!")
      Gori::ProjectRegistry.new(root).find("New Label!").try(&.dir).should eq(dir_before)
      Gori::ProjectRegistry.new(root).find("old-name").try(&.dir).should eq(dir_before) # slug still resolves
    end
  end

  it "rejects a blank rename" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("keep")
      Gori::Store.open(p.db_path).close
      expect_raises(Gori::Error, /invalid project name/) { reg.rename(p, "   ") }
      reg.find("keep").should_not be_nil
    end
  end
end

describe Gori::Session do
  it "opens a project store + proxy and captures, then cleans up a temp project" do
    with_root do |root|
      ca_dir = File.join(root, "ca")
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
      registry = Gori::Verbs.registry
      config = Gori::Config.new(listen: "127.0.0.1", port: 0)
      project = Gori::ProjectRegistry.new(root).temp("sess")

      session = Gori::Session.open(config, ca, registry, project)
      session.capturing?.should be_true
      session.proxy.port.should be > 0
      session.store.count.should eq(0)
      dir = project.dir
      session.close # stops proxy, closes store, removes temp dir
      Dir.exists?(dir).should be_false
    end
  end

  it "flips upstream TLS verification live across config, tunnel, and probe" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      config = Gori::Config.new(listen: "127.0.0.1", port: 0) # insecure_upstream defaults false → verify on
      project = Gori::ProjectRegistry.new(root).temp("verify")

      session = Gori::Session.open(config, ca, registry, project)
      begin
        # Baseline: verify on everywhere the toggle reaches.
        session.config.insecure_upstream?.should be_false
        session.tunnel.verify_upstream?.should be_true
        session.probe.verify_upstream?.should be_true

        session.set_verify_upstream(false)
        session.config.insecure_upstream?.should be_true # repeater/fuzzer/miner read this per send
        session.tunnel.verify_upstream?.should be_false  # next CONNECT skips verification
        session.probe.verify_upstream?.should be_false   # next active probe skips verification

        session.set_verify_upstream(true) # and back on
        session.config.insecure_upstream?.should be_false
        session.tunnel.verify_upstream?.should be_true
        session.probe.verify_upstream?.should be_true
      ensure
        session.close
      end
    end
  end

  it "opens in capture-off mode (non-fatal) when the bind port is already taken" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      reg = Gori::ProjectRegistry.new(root)

      first = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, reg.temp("a"))
      first.capturing?.should be_true
      taken = first.proxy.port

      # second session on the SAME port: the bind fails, but the project still
      # opens (capture off) — History/Repeater read the store / dial directly.
      second = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: taken), ca, registry, reg.temp("b"))
      second.bind_error.should_not be_nil
      second.capturing?.should be_false
      second.store.count.should eq(0) # the store is fully usable

      first.close
      second.close
    end
  end

  it "opens VIEW-ONLY when another instance already holds the project capture lock" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).temp("shared")

      # Simulate another LIVE instance holding the lock (a separate open fd → a
      # distinct OFD, which flock treats independently and so denies us).
      held = File.open(Gori::CaptureLock.path(project.dir), "w")
      held.flock_exclusive(blocking: false)

      s = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project, bind_fallback: true)
      s.capturing?.should be_false # did NOT bind a 2nd listener
      s.bind_error.should_not be_nil
      s.capturing_lock_held?.should be_false # view-only: we do not own the lock
      s.store.count.should eq(0)             # the store is fully usable
      s.close

      held.flock_unlock
      held.close
    end
  end

  it "captures when the lock is free, releasing it on close so a later open can take over" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).create("free") # persistent: dir survives close

      a = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project)
      a.capturing?.should be_true
      a.capturing_lock_held?.should be_true
      a.close # releases the lock (dir kept — not ephemeral)

      b = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project)
      b.capturing?.should be_true # the lock was freed on a.close
      b.capturing_lock_held?.should be_true
      b.close
    end
  end

  it "auto-falls-back to a free port for a DIFFERENT project when the configured port is taken" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      reg = Gori::ProjectRegistry.new(root)

      first = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, reg.temp("a"))
      first.capturing?.should be_true
      taken = first.proxy.port

      # Different project (own dir → own lock), same port, WITH fallback → its own port.
      second = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: taken), ca, registry, reg.temp("b"), bind_fallback: true)
      second.capturing?.should be_true       # acquired its own lock + bound
      second.proxy.port.should_not eq(taken) # fell back to a free port

      first.close
      second.close
    end
  end

  it "toggle_capture takes over the project lock once the prior holder releases" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).temp("toggle")

      held = File.open(Gori::CaptureLock.path(project.dir), "w")
      held.flock_exclusive(blocking: false)

      s = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project, bind_fallback: true)
      s.capturing?.should be_false
      s.toggle_capture.should be_false # lock still held by `held` → refused, no bind

      held.flock_unlock
      held.close

      s.toggle_capture.should be_true # now acquires the freed lock and starts
      s.capturing?.should be_true
      s.close
    end
  end

  it "abandons orphan Pending flows when the session closes" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).create("abandon") # persistent: dir survives close

      session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project)
      pending_id = session.store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h", port: 80, method: "GET", target: "/hang",
        http_version: "HTTP/1.1", head: "GET /hang HTTP/1.1\r\nHost: h\r\n\r\n".to_slice))
      session.close

      store = Gori::Store.open(project.db_path)
      begin
        detail = store.get_flow(pending_id).not_nil!
        detail.row.state.should eq(Gori::Store::FlowState::Error)
        detail.error.should eq("proxy stopped before response")
      ensure
        store.close
      end
    end
  end

  it "abandons a live Pending capture when the session closes during an upstream hang" do
    with_root do |root|
      origin_port = start_hanging_origin
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).create("hang-close")

      session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project)
      proxy_port = session.proxy.port

      spawn do
        client = TCPSocket.new("127.0.0.1", proxy_port)
        client << "GET /hang HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
        client.flush
        client.close
      rescue
      end

      pending_id = nil.as(Int64?)
      40.times do
        session.store.recent_flows(5).each do |row|
          if row.state == Gori::Store::FlowState::Pending
            pending_id = row.id
            break
          end
        end
        break if pending_id
        sleep 0.05.seconds
      end
      pending_id.should_not be_nil

      session.close

      store = Gori::Store.open(project.db_path)
      begin
        detail = store.get_flow(pending_id.not_nil!).not_nil!
        detail.row.state.should eq(Gori::Store::FlowState::Error)
        detail.error.should eq("proxy stopped before response")
      ensure
        store.close
      end
    end
  end
end
