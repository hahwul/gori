require "../spec_helper"
require "file_utils"

include Gori::Tui

# `Headless.render`: boot a real Runner against an offscreen terminal and hand back the frame.
#
# Two halves worth pinning. The frame really is the shipping UI drawn against the store (so a
# seeded flow appears under the tab it belongs to, and the too-small guard still fires), and the
# render is an OBSERVATION — no lock, no socket, no sidecar, no active-project pointer, and
# every process global put back the way it was found. The second half is the one that bites: a
# Runner is a full TUI shell, and the `Env` layer it binds is read by `gori mcp` for the life of
# that process.
#
# Socket-free throughout: `listen: false` is what makes that true.

private HEADLESS_CA = File.tempname("gori-headless-ca")
Spec.after_suite { FileUtils.rm_rf(HEADLESS_CA) }

# A stand-in for whatever binding table the calling process had bound, so "was it put back?" can
# be asked by object identity rather than by value.
private class HeadlessSentinelLayer < Gori::Env::Layer
  def declared : Array(String)
    ["SENTINEL"]
  end

  def values : Hash(String, String)
    {"SENTINEL" => "kept"}
  end

  def rev : UInt64
    1_u64
  end
end

private def with_seeded_project(&)
  root = File.tempname("gori-headless")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).create("shotproj")
  store = Gori::Store.open(project.db_path)
  3.times do |i|
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64 + i, scheme: "https", host: "shots.test", port: 443,
      method: "GET", target: "/widgets/#{i}", http_version: "HTTP/1.1",
      head: "GET /widgets/#{i} HTTP/1.1\r\nHost: shots.test\r\n\r\n".to_slice,
      body: nil, source: Gori::FlowSource::Kind::Proxy))
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: 200,
      head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
      body: "<html>ok</html>".to_slice, content_type: "text/html"))
  end
  store.flush
  store.close
  begin
    yield project
  ensure
    FileUtils.rm_rf(root)
  end
end

private def shoot(project : Gori::Project, **args) : Gori::Screenshot::Frame
  Headless.render(project, Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(HEADLESS_CA),
    Gori::Verbs.registry, **args)
end

private def rows_of(frame : Gori::Screenshot::Frame) : Array(String)
  (0...frame.rows).map { |y| frame.row_text(y) }
end

describe Gori::Tui::Headless do
  it "draws the real History tab against the real store" do
    with_seeded_project do |project|
      frame = shoot(project, tab: :history, cols: 100, rows: 30)
      frame.cols.should eq(100)
      frame.rows.should eq(30)
      text = rows_of(frame)
      # The chrome gori actually ships…
      text.any?(&.includes?("History")).should be_true
      # …and the rows the store actually holds. `focus_tab` is what reloads the controller;
      # a tab entered any other way would draw an empty pane over a full database.
      text.any?(&.includes?("shots.test")).should be_true
      text.any?(&.includes?("/widgets/")).should be_true
    end
  end

  it "draws the too-small guard on a terminal the layout cannot use" do
    with_seeded_project do |project|
      # Layout.usable? is w >= 40 && h >= 8.
      frame = shoot(project, cols: 30, rows: 6)
      frame.row_text(0).should contain("terminal too small")
    end
  end

  it "stamps a title onto the frame without redrawing it" do
    with_seeded_project do |project|
      plain = shoot(project, tab: :history, cols: 80, rows: 20)
      titled = shoot(project, tab: :history, cols: 80, rows: 20, title: "widgets")
      plain.title.should be_nil
      titled.title.should eq("widgets")
      rows_of(titled).should eq(rows_of(plain))
    end
  end

  it "refuses a tab name that is not on the bar" do
    with_seeded_project do |project|
      expect_raises(Gori::Error, /no such tab: nope/) { shoot(project, tab: :nope) }
    end
  end

  it "feeds a key script to the shipping key path" do
    with_seeded_project do |project|
      # `/` opens the History query bar; typing lands in it. The assertion is only that the
      # keys reached the Runner and changed the frame — which branch of the UI they drove is
      # the TUI's own specs' business.
      quiet = shoot(project, tab: :history, cols: 100, rows: 30)
      typed = shoot(project, tab: :history, cols: 100, rows: 30,
        keys: Gori::Tui::KeyScript.parse(%(/ "status:200")))
      rows_of(typed).should_not eq(rows_of(quiet))
      rows_of(typed).any?(&.includes?("status:200")).should be_true
    end
  end

  # ── A render is an observation ─────────────────────────────────────────────────────────

  it "takes no capture lock and leaves no capture-status sidecar" do
    with_seeded_project do |project|
      shoot(project, tab: :history, cols: 80, rows: 20)
      File.exists?(project.capture_status_path).should be_false
      # Free afterwards, which is only true because it was never taken.
      lock = Gori::CaptureLock.try_at(project.capture_lock_path)
      lock.should_not be_nil
      lock.try(&.close)
    end
  end

  it "does not repoint the active project" do
    with_seeded_project do |project|
      before = Gori::Paths.read_active_project
      shoot(project, tab: :history, cols: 80, rows: 20)
      # `Runner#run` writes this; `boot` deliberately does not. Drawing a picture of a project
      # is not a decision to work in it — `gori mcp --use-active-project` follows this pointer.
      Gori::Paths.read_active_project.should eq(before)
    end
  end

  it "puts the caller's Env layer back, by identity" do
    with_seeded_project do |project|
      previous = Gori::Env.layer
      sentinel = HeadlessSentinelLayer.new
      Gori::Env.layer = sentinel
      begin
        shoot(project, tab: :history, cols: 80, rows: 20)
        # `Session#close` nils the layer it bound. Inside `gori mcp` the Tools object binds
        # this ONCE at construction, so losing it here would leave every later `$BIND.NAME`
        # unresolvable for the rest of that process.
        Gori::Env.layer.should be(sentinel)
      ensure
        Gori::Env.layer = previous
      end
    end
  end

  it "puts the theme and the bell back" do
    with_seeded_project do |project|
      theme_before = Theme.active_name
      bell_before = Gori::Settings.notify_bell?
      Gori::Settings.notify_bell = true
      begin
        frame = shoot(project, tab: :history, cols: 80, rows: 20, theme: "goriday")
        frame.theme.should eq("goriday")
        Theme.active_name.should eq(theme_before)
        Gori::Settings.notify_bell?.should be_true
      ensure
        Gori::Settings.notify_bell = bell_before
        Theme.apply(theme_before)
      end
    end
  end

  it "puts the project-network globals back" do
    with_seeded_project do |project|
      host_before = Gori::Settings.project_bind_host
      port_before = Gori::Settings.project_bind_port
      upstream_before = Gori::Settings.project_upstream_proxy
      begin
        Gori::Settings.project_bind_host = "10.9.9.9"
        Gori::Settings.project_bind_port = 9999
        Gori::Settings.project_upstream_proxy = "http://jump.test:3128"
        shoot(project, tab: :history, cols: 80, rows: 20)
        # `load_project_network` assigns all nine unconditionally, nil included; a render that
        # left them where it put them would send the next dial somewhere else.
        Gori::Settings.project_bind_host.should eq("10.9.9.9")
        Gori::Settings.project_bind_port.should eq(9999)
        Gori::Settings.project_upstream_proxy.should eq("http://jump.test:3128")
      ensure
        Gori::Settings.project_bind_host = host_before
        Gori::Settings.project_bind_port = port_before
        Gori::Settings.project_upstream_proxy = upstream_before
      end
    end
  end

  it "leaves the store closed and the flows untouched" do
    with_seeded_project do |project|
      shoot(project, tab: :history, cols: 80, rows: 20)
      store = Gori::Store.open(project.db_path)
      begin
        # Reopenable at all means the render's own store was closed; three Complete rows means
        # neither the retention sweep nor the close-path Pending sweep ran over them.
        rows = store.recent_flows(10)
        rows.size.should eq(3)
        rows.all? &.state.complete?.should be_true
      ensure
        store.close
      end
    end
  end
end
