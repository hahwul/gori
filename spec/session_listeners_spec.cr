require "./spec_helper"
require "file_utils"

# #508: the `listeners` section is hand-edited in settings.json, so a reconcile is what makes an
# edit take effect without a restart. These examples drive the REAL sockets and connect to them —
# the question the issue settles is a lifecycle one, and a recording double would prove nothing
# about whether a socket actually came up, went down, or was left alone.

private def free_port : Int32
  s = TCPServer.new("127.0.0.1", 0)
  port = s.local_address.port
  s.close
  port
end

private def accepts?(port : Int32) : Bool
  TCPSocket.new("127.0.0.1", port, connect_timeout: 2.seconds).close
  true
rescue
  false
end

# The live `Proxy::Server` objects. Read off the ivar rather than through a getter on purpose:
# `Session` deliberately exposes only `listener_rows` (plain values) so the TUI cannot reach a
# listener's socket through a readout, and proving "this socket was not touched" needs object
# identity, which is a spec's business and nobody else's.
private def servers_of(session : Gori::Session) : Array(Gori::Proxy::Server)
  session.@extra_listeners.map(&.server)
end

# Open a real Session whose settings.json lives in a temp dir, so `disk_listeners?` reads what
# the example writes. `Settings.listeners` is seeded from the same file, exactly as a real
# startup would: the drift this issue is about only exists once the two can diverge.
private def with_reconcile_session(entries : String, &)
  root = File.tempname("gori-listen-reconcile")
  Dir.mkdir_p(root)
  cfg = File.join(root, "settings.json")
  prev_host = Gori::Settings.bind_host
  prev_port = Gori::Settings.bind_port
  prev_listeners = Gori::Settings.listeners
  begin
    Gori::Settings.path_override = cfg
    Gori::Settings.project_bind_host = nil
    Gori::Settings.project_bind_port = nil
    Gori::Settings.bind_host = "127.0.0.1"
    Gori::Settings.bind_port = 0
    File.write(cfg, %({"listeners": #{entries}}))
    Gori::Settings.listeners = Gori::Settings.disk_listeners
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
    project = Gori::ProjectRegistry.new(File.join(root, "projects")).create("reconcile")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      ca, Gori::Verbs.registry, project)
    begin
      yield session, cfg
    ensure
      session.close
    end
  ensure
    Gori::Settings.path_override = nil
    Gori::Settings.bind_host = prev_host
    Gori::Settings.bind_port = prev_port
    Gori::Settings.listeners = prev_listeners
    FileUtils.rm_rf(root)
  end
end

private def rewrite(cfg : String, entries : String) : Nil
  File.write(cfg, %({"listeners": #{entries}}))
end

describe Gori::Session, "#reconcile_listeners! (#508)" do
  it "starts a listener added to settings.json, with no restart" do
    a, b = free_port, free_port
    with_reconcile_session(%([{"host": "127.0.0.1", "port": #{a}}])) do |session, cfg|
      accepts?(a).should be_true
      accepts?(b).should be_false

      rewrite(cfg, %([{"host": "127.0.0.1", "port": #{a}}, {"host": "127.0.0.1", "port": #{b}}]))
      result = session.reconcile_listeners!
      result.should_not be_nil
      result = result.not_nil!
      result.added.should eq(1)
      result.removed.should eq(0)
      result.serving.should eq(2)
      accepts?(b).should be_true
      accepts?(a).should be_true # the one that was already there is still up
    end
  end

  it "stops a listener removed from settings.json, with no restart" do
    a, b = free_port, free_port
    with_reconcile_session(%([{"host": "127.0.0.1", "port": #{a}}, {"host": "127.0.0.1", "port": #{b}}])) do |session, cfg|
      accepts?(b).should be_true

      rewrite(cfg, %([{"host": "127.0.0.1", "port": #{a}}]))
      result = session.reconcile_listeners!.not_nil!
      result.removed.should eq(1)
      result.added.should eq(0)
      result.serving.should eq(1)
      accepts?(b).should be_false
      accepts?(a).should be_true
    end
  end

  # The requirement the issue is most explicit about: a diff, not stop-all/start-all. Asserted on
  # the SERVER OBJECT rather than on `accepts?`, because a socket that went down and came back up
  # inside one reconcile would still pass a connect test having dropped every connection on it.
  it "never touches a listener the edit did not concern" do
    a, b = free_port, free_port
    with_reconcile_session(%([{"host": "127.0.0.1", "port": #{a}}, {"host": "127.0.0.1", "port": #{b}, "mode": "reverse", "origin": "https://one.example"}])) do |session, cfg|
      untouched = servers_of(session).find { |s| s.port == a }.not_nil!

      rewrite(cfg, %([{"host": "127.0.0.1", "port": #{a}}, {"host": "127.0.0.1", "port": #{b}, "mode": "reverse", "origin": "https://two.example"}]))
      result = session.reconcile_listeners!.not_nil!
      result.retargeted.should eq(1)
      result.added.should eq(0)
      result.removed.should eq(0)

      # The same object, still listening: the untouched row's accept loop — and every connection
      # riding it — survived an edit to the row below it.
      servers_of(session).find { |s| s.port == a }.should be(untouched)
      untouched.listening?.should be_true
      # The retargeted one is a NEW socket on the SAME address, now pointed at the new origin.
      retargeted = servers_of(session).find { |s| s.port == b }.not_nil!
      retargeted.origin.should eq({"https", "two.example", 443})
      accepts?(b).should be_true
    end
  end

  it "reports a listener that cannot bind, and keeps serving the rest" do
    a = free_port
    blocker = TCPServer.new("127.0.0.1", 0)
    taken = blocker.local_address.port
    begin
      with_reconcile_session(%([{"host": "127.0.0.1", "port": #{a}}])) do |session, cfg|
        rewrite(cfg, %([{"host": "127.0.0.1", "port": #{a}}, {"host": "127.0.0.1", "port": #{taken}}]))
        result = session.reconcile_listeners!.not_nil!
        result.added.should eq(1)
        result.failed.size.should eq(1)
        result.failed.first.should start_with("127.0.0.1:#{taken} —")
        # It was never up, so this is a plain failure and not the "was serving" wording.
        result.dropped.should be_empty
        result.serving.should eq(1)
        accepts?(a).should be_true

        # And it reads exactly like a bind failure at open: one row carrying its own reason.
        row = servers_row(session, taken)
        row.listening.should be_false
        row.error.should_not be_nil
      end
    ensure
      blocker.close
    end
  end

  # A listener whose bind failed at open is retried, so a reconcile is also how an operator
  # recovers one after freeing its port — without restarting the ones that did come up.
  it "retries a listener that is configured but not serving" do
    a = free_port
    blocker = TCPServer.new("127.0.0.1", 0)
    taken = blocker.local_address.port
    begin
      entries = %([{"host": "127.0.0.1", "port": #{a}}, {"host": "127.0.0.1", "port": #{taken}}])
      with_reconcile_session(entries) do |session, _cfg|
        servers_row(session, taken).listening.should be_false
        blocker.close

        # settings.json is UNCHANGED — the fix was outside gori.
        result = session.reconcile_listeners!.not_nil!
        result.changed?.should be_false
        result.serving.should eq(2)
        accepts?(taken).should be_true
      end
    ensure
      blocker.close rescue nil
    end
  end

  it "refuses to reconcile against a settings.json it cannot parse" do
    a = free_port
    with_reconcile_session(%([{"host": "127.0.0.1", "port": #{a}}])) do |session, cfg|
      File.write(cfg, "{not json")
      session.reconcile_listeners!.should be_nil
      # Nothing was torn down over a typo somewhere else in the document.
      accepts?(a).should be_true
      session.listener_rows.size.should eq(1)
    end
  end

  it "clears the drift notice once the edit has been applied" do
    a, b = free_port, free_port
    with_reconcile_session(%([{"host": "127.0.0.1", "port": #{a}}])) do |session, cfg|
      session.listeners_changed_on_disk?.should be_false
      rewrite(cfg, %([{"host": "127.0.0.1", "port": #{b}}]))
      session.listeners_changed_on_disk?.should be_true
      session.reconcile_listeners!
      session.listeners_changed_on_disk?.should be_false
    end
  end

  # `Server#rebind`'s rule one level up: not listening means record the new set and bind nothing.
  it "records the new set without binding while capture is off" do
    a, b = free_port, free_port
    with_reconcile_session(%([{"host": "127.0.0.1", "port": #{a}}])) do |session, cfg|
      session.toggle_capture.should be_false
      accepts?(a).should be_false

      rewrite(cfg, %([{"host": "127.0.0.1", "port": #{b}}]))
      result = session.reconcile_listeners!.not_nil!
      result.capturing.should be_false
      result.serving.should eq(0)
      accepts?(b).should be_false

      # The next `c` opens the RECONCILED set, not the one gori started with.
      session.toggle_capture.should be_true
      accepts?(b).should be_true
      accepts?(a).should be_false
    end
  end
end

private def servers_row(session : Gori::Session, port : Int32) : Gori::Session::ListenerRow
  session.listener_rows.find { |r| r.port == port }.not_nil!
end

private def reconcile(added = 0, removed = 0, retargeted = 0, serving = 0,
                      failed = [] of String, dropped = [] of String,
                      capturing = true) : Gori::Session::ListenerReconcile
  Gori::Session::ListenerReconcile.new(added, removed, retargeted, serving, failed, dropped, capturing)
end

describe Gori::Session::ListenerReconcile do
  it "says nothing moved when nothing moved" do
    reconcile(serving: 2).summary
      .should eq("listeners: settings.json already matches the running sockets")
  end

  it "counts what the edit changed, and how many sockets serve after it" do
    reconcile(added: 1, removed: 1, retargeted: 1, serving: 3).summary
      .should eq("listeners: 1 added, 1 removed, 1 retargeted · 3 serving")
  end

  # A count of failures, not their addresses: each is already a row in the overlay the message
  # points at, and a message long enough to list them is one nobody reads.
  it "points a bind failure at the readout that names it" do
    reconcile(added: 1, serving: 1, failed: ["127.0.0.1:9000 — in use"]).summary
      .should eq("listeners: 1 added — 1 could not bind (see the listeners chip)")
  end

  # The one outcome the operator has to act on, and the only one where a socket they still want
  # went away: it gets its own wording and names the address rather than being counted.
  it "names a listener that was serving and did not come back" do
    reconcile(retargeted: 1, serving: 1, failed: ["127.0.0.1:9000 — in use"],
      dropped: ["127.0.0.1:9000"]).summary
      .should eq("listeners: 1 retargeted — 127.0.0.1:9000 was serving and could not rebind")
  end

  it "does not report 0 serving as a failure when capture is simply off" do
    reconcile(added: 1, capturing: false).summary
      .should eq("listeners: 1 added — capture is off, press c to start")
  end
end
