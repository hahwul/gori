require "./spec_helper"
require "file_utils"

# `Session.open(..., listen: false)`: open a project to READ it and nothing else.
#
# What makes this worth its own file is that "view-only" already existed as an OUTCOME (a second
# instance that lost the race for the capture lock) but never as a REQUEST. These pin the
# difference — a session that never asked for the lock must not report having lost it, must not
# leave a capture-status marker behind, and must not touch the Pending rows that belong to
# whichever process actually is capturing.
#
# Deliberately socket-free: nothing here binds, which is the whole point.

private VIEW_ONLY_CA = File.tempname("gori-view-only-ca")
Spec.after_suite { FileUtils.rm_rf(VIEW_ONLY_CA) }

# A real on-disk project (not `temp`, whose `cleanup` deletes the directory on close — these
# examples look at the sidecars and the store AFTER the session has gone).
private def with_project(&)
  root = File.tempname("gori-view-only")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).create("viewonly")
  prev_bind_host = Gori::Settings.project_bind_host
  prev_bind_port = Gori::Settings.project_bind_port
  begin
    yield project
  ensure
    Gori::Settings.project_bind_host = prev_bind_host
    Gori::Settings.project_bind_port = prev_bind_port
    FileUtils.rm_rf(root)
  end
end

private def view_only(project : Gori::Project) : Gori::Session
  Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(VIEW_ONLY_CA),
    Gori::Verbs.registry, project, listen: false)
end

describe "Gori::Session.open(listen: false)" do
  it "captures nothing, holds no lock, and reports no reason it isn't capturing" do
    with_project do |project|
      session = view_only(project)
      begin
        session.capturing?.should be_false
        session.capturing_lock_held?.should be_false
        # NOT "another gori instance already holds this database's capture lock". Nothing was
        # asked for, so nothing was refused — a render that reported a race it never entered
        # would send an operator looking for a second instance that does not exist.
        session.bind_error.should be_nil
      ensure
        session.close
      end
    end
  end

  it "leaves the capture lock free while it is open" do
    with_project do |project|
      session = view_only(project)
      begin
        # The real capturer can start at any point during the render, which is only true
        # because `CaptureLock.try_at` was never reached above.
        lock = Gori::CaptureLock.try_at(project.capture_lock_path)
        lock.should_not be_nil
        lock.try(&.close)
      ensure
        session.close
      end
      Gori::CaptureLock.try_at(project.capture_lock_path).try(&.close).should be_nil
    end
  end

  it "writes no capture-status sidecar" do
    with_project do |project|
      session = view_only(project)
      begin
        # The picker reads this marker to say where a project opened in another window is
        # listening. A reader that wrote one would advertise a port nothing is on.
        File.exists?(project.capture_status_path).should be_false
      ensure
        session.close
      end
      File.exists?(project.capture_status_path).should be_false
    end
  end

  it "does not pin a bind address into the Settings display layer" do
    with_project do |project|
      Gori::Settings.project_bind_host = "10.9.9.9"
      Gori::Settings.project_bind_port = 9999
      session = view_only(project)
      begin
        # `load_project_network(bind: false)` CLEARS the pair rather than skipping it: every
        # chip and status line reads `effective_bind_*`, and a session with no socket must not
        # inherit the previous project's address and report it as its own.
        Gori::Settings.project_bind_host.should be_nil
        Gori::Settings.project_bind_port.should be_nil
      ensure
        session.close
      end
    end
  end

  # The close-path gate. `abandon_pending!` used to run unconditionally, so ANY session closing
  # — a view-only second instance, a headless render — finalised the in-flight captures of the
  # process that actually holds the lock, writing "proxy stopped before response" over responses
  # still on the wire somewhere else.
  it "leaves another capturer's Pending rows alone on close" do
    with_project do |project|
      store = Gori::Store.open(project.db_path)
      pending = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/inflight", http_version: "HTTP/1.1",
        head: "GET /inflight HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
        body: nil, source: Gori::FlowSource::Kind::Proxy))
      store.flush
      store.get_flow(pending).not_nil!.row.state.should eq(Gori::Store::FlowState::Pending)
      store.close

      view_only(project).close

      after = Gori::Store.open(project.db_path)
      begin
        flow = after.get_flow(pending).not_nil!
        flow.row.state.should eq(Gori::Store::FlowState::Pending)
        flow.error.should be_nil
      ensure
        after.close
      end
    end
  end
end
