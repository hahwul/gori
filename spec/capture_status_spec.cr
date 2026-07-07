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

describe Gori::CaptureStatus do
  it "writes, reads, and clears the status sidecar" do
    dir = File.tempname("gori-status")
    begin
      Gori::CaptureStatus.write(dir, "127.0.0.1", 8070, true)
      File.exists?(Gori::CaptureStatus.path(dir)).should be_true

      status = Gori::CaptureStatus.read(dir)
      status.should_not be_nil
      status.not_nil!.host.should eq("127.0.0.1")
      status.not_nil!.port.should eq(8070)
      status.not_nil!.listening.should be_true

      Gori::CaptureStatus.clear(dir)
      File.exists?(Gori::CaptureStatus.path(dir)).should be_false
      Gori::CaptureStatus.read(dir).should be_nil
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "formats loopback hosts as localhost" do
    Gori::CaptureStatus.format_endpoint("127.0.0.1", 8070).should eq("localhost:8070")
    Gori::CaptureStatus.format_endpoint("::1", 9000).should eq("localhost:9000")
    Gori::CaptureStatus.format_endpoint("0.0.0.0", 8070).should eq("0.0.0.0:8070")
  end
end

describe Gori::CaptureLock do
  it "reports held? when flock is contended on the same lock file" do
    dir = File.tempname("gori-lock-held")
    begin
      Gori::CaptureLock.held?(dir).should be_false

      lock = Gori::CaptureLock.try(dir)
      lock.should_not be_nil
      Gori::CaptureLock.held?(dir).should be_true

      lock.not_nil!.close
      Gori::CaptureLock.held?(dir).should be_false
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end

describe Gori::Session, "capture status sidecar" do
  it "writes status on open and clears on close" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).create("live")
      config = Gori::Config.new(listen: "127.0.0.1", port: 0)

      session = Gori::Session.open(config, ca, registry, project)
      session.capturing?.should be_true

      status = Gori::CaptureStatus.read(project.dir)
      status.should_not be_nil
      status.not_nil!.listening.should be_true
      status.not_nil!.port.should eq(session.proxy.port)
      Gori::CaptureStatus.format_endpoint(status.not_nil!.host, status.not_nil!.port)
        .should eq("localhost:#{session.proxy.port}")

      session.close
      File.exists?(Gori::CaptureStatus.path(project.dir)).should be_false
    end
  end

  it "does not write status when opening view-only" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).temp("shared")

      held = File.open(Gori::CaptureLock.path(project.dir), "w")
      held.flock_exclusive(blocking: false)

      session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project, bind_fallback: true)
      session.capturing_lock_held?.should be_false
      Gori::CaptureStatus.read(project.dir).should be_nil
      session.close

      held.flock_unlock
      held.close
    end
  end

  it "records capture-off when the bind fails but the lock is held" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      reg = Gori::ProjectRegistry.new(root)

      first = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, reg.temp("a"))
      taken = first.proxy.port

      second = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: taken), ca, registry, reg.temp("b"))
      second.capturing?.should be_false
      second.capturing_lock_held?.should be_true

      status = Gori::CaptureStatus.read(second.project.dir)
      status.should_not be_nil
      status.not_nil!.listening.should be_false
      status.not_nil!.port.should eq(taken)

      first.close
      second.close
    end
  end

  it "updates status when capture is toggled off and on" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).temp("toggle-status")
      session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project)

      session.capturing?.should be_true
      session.toggle_capture.should be_false
      off = Gori::CaptureStatus.read(project.dir)
      off.should_not be_nil
      off.not_nil!.listening.should be_false

      session.toggle_capture.should be_true
      on = Gori::CaptureStatus.read(project.dir)
      on.should_not be_nil
      on.not_nil!.listening.should be_true
      on.not_nil!.port.should eq(session.proxy.port)

      session.close
    end
  end

  it "updates status when the proxy is rebound" do
    with_root do |root|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      registry = Gori::Verbs.registry
      project = Gori::ProjectRegistry.new(root).temp("rebind-status")
      session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0), ca, registry, project)

      session.proxy.rebind("127.0.0.1", 0)
      session.sync_capture_status!
      rebound = Gori::CaptureStatus.read(project.dir)
      rebound.should_not be_nil
      rebound.not_nil!.listening.should be_true
      rebound.not_nil!.port.should eq(session.proxy.port)

      session.toggle_capture
      session.proxy.rebind("127.0.0.1", 9150)
      session.sync_capture_status!
      paused = Gori::CaptureStatus.read(project.dir)
      paused.should_not be_nil
      paused.not_nil!.listening.should be_false
      paused.not_nil!.port.should eq(9150)

      session.close
    end
  end
end
