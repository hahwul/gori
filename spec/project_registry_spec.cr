require "./spec_helper"
require "file_utils"

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

  it "opens in capture-off mode (non-fatal) when the bind port is already taken" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      reg = Gori::ProjectRegistry.new(root)

      first = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, reg.temp("a"))
      first.capturing?.should be_true
      taken = first.proxy.port

      # second session on the SAME port: the bind fails, but the project still
      # opens (capture off) — History/Replay read the store / dial directly.
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
end
