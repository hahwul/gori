require "../spec_helper"
require "file_utils"

include Gori::Tui

# The screenshot verbs end to end: a real Runner, booted against an offscreen terminal exactly
# the way `Tui::Headless` boots one, asked for a picture of itself.
#
# What is pinned here is everything the renderers cannot be asked about on their own — WHICH
# frame gets photographed (the UI, not the palette the operator opened to reach the verb),
# where it lands, what the operator is told, and whether the project's redaction profile got
# there first. The formats themselves have their own specs under spec/screenshot/.

private SHOT_CA = File.tempname("gori-shot-ca")
Spec.after_suite { FileUtils.rm_rf(SHOT_CA) }

# A POST whose REQUEST body carries a secret long enough to earn a correlation tag: `Mask`
# fills a region narrower than `[REDACTED:xxxxxxxx]` with blocks instead, because half a tag
# reads as a truncated secret.
private SECRET = "correct-horse-battery-staple-01"

# The same secret in the shape the SCREEN draws it. `Pretty.try_form` reflows a form body to
# `key = value` and `pretty_bodies` is on at the factory, so a mask that only knew `key=value`
# found nothing here — while the copy menu, which parses the raw bytes, masked it.
private def seed_form_flow(store) : Nil
  body = "user=ada&password=#{SECRET}"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "shots.test", port: 443,
    method: "POST", target: "/session", http_version: "HTTP/1.1",
    head: "POST /session HTTP/1.1\r\nHost: shots.test\r\n" \
          "Content-Type: application/x-www-form-urlencoded\r\n\r\n".to_slice,
    body: body.to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 302,
    head: "HTTP/1.1 302 Found\r\nLocation: /home\r\n\r\n".to_slice,
    body: nil, content_type: nil))
  store.flush
end

private def seed_secret_flow(store) : Nil
  body = %({"user":"ada","password":"#{SECRET}"})
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "shots.test", port: 443,
    method: "POST", target: "/login", http_version: "HTTP/1.1",
    head: "POST /login HTTP/1.1\r\nHost: shots.test\r\nContent-Type: application/json\r\n\r\n".to_slice,
    body: body.to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
    body: %({"ok":true}).to_slice, content_type: "application/json"))
  store.flush
end

# Everything `Session.open` + `Runner.new` assign unconditionally, put back. The same list
# `Tui::Headless.with_globals` keeps, and for the same reason: this file is one of many in
# `spec/tui`, and a leaked `Env.layer` or project bind port would surface as an unrelated
# failure several files later.
private def with_runner_globals(&)
  env_layer = Gori::Env.layer
  env_vars = Gori::Settings.project_env_vars
  theme = Theme.active_name
  bell = Gori::Settings.notify_bell?
  bind_host = Gori::Settings.project_bind_host
  bind_port = Gori::Settings.project_bind_port
  upstream = Gori::Settings.project_upstream_proxy
  upstream_dest = Gori::Settings.project_upstream_destination
  upstream_auth = Gori::Settings.project_upstream_auth
  upstream_auth_error = Gori::Settings.project_upstream_auth_error
  connect_timeout = Gori::Settings.project_connect_timeout_secs
  io_timeout = Gori::Settings.project_io_timeout_secs
  capture_max = Gori::Settings.project_capture_max_mib
  # `Runner.new` hands the empty-state cards a verb registry so their chord chips resolve —
  # a module-level global with no owner but the last Runner built. Left set, every later
  # spec file that renders one of those cards gets chips it never asked for, and the cards
  # are laid out from the chip WIDTHS, so they silently degrade to their compact form.
  empty_state_registry = TrafficEmptyState.registry
  # …and the same module's `suppressed` flag, which `render_body` sets from `@overlay` on
  # EVERY frame. An example that ends with the History detail open leaves it true, and a
  # later file's empty-state card then draws nothing at all.
  empty_state_suppressed = TrafficEmptyState.suppressed?
  fmt = Gori::Settings.screenshot_format
  dir = Gori::Settings.screenshot_dir
  scale = Gori::Settings.screenshot_png_scale
  Gori::Settings.notify_bell = false # a notification here writes `\a` to whatever stdout is
  begin
    yield
  ensure
    Gori::Settings.notify_bell = bell
    Gori::Settings.project_upstream_destination = upstream_dest
    Gori::Settings.project_bind_host = bind_host
    Gori::Settings.project_bind_port = bind_port
    Gori::Settings.project_upstream_proxy = upstream
    Gori::Settings.project_upstream_auth = upstream_auth
    Gori::Settings.project_upstream_auth_error = upstream_auth_error
    Gori::Settings.project_connect_timeout_secs = connect_timeout
    Gori::Settings.project_io_timeout_secs = io_timeout
    Gori::Settings.project_capture_max_mib = capture_max
    Gori::Settings.project_env_vars = env_vars
    Gori::Settings.screenshot_format = fmt
    Gori::Settings.screenshot_dir = dir
    Gori::Settings.screenshot_png_scale = scale
    TrafficEmptyState.registry = empty_state_registry
    TrafficEmptyState.suppressed = empty_state_suppressed
    Theme.apply(theme)
    Gori::Env.layer = env_layer
    Gori::Env.bump_highlight_rev
  end
end

# A booted Runner over a fresh project. `listen: false` keeps it socket-free (no capture lock,
# no bind) — the whole reason a TUI shell can be driven from a spec at all.
private def with_runner(*, seed = false, form = false, tab : Symbol? = nil, cols = 140, &)
  root = File.tempname("gori-shot")
  Dir.mkdir_p(root)
  FileUtils.rm_rf(Gori::Paths.screenshots_dir) # each example owns the convention dir
  project = Gori::ProjectRegistry.new(root).create("shotproj")
  if seed || form
    store = Gori::Store.open(project.db_path)
    form ? seed_form_flow(store) : seed_secret_flow(store)
    store.close
  end
  begin
    with_runner_globals do
      session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
        Gori::Proxy::Tls::CertAuthority.load_or_create(SHOT_CA),
        Gori::Verbs.registry, project, listen: false)
      begin
        runner = Runner.new(session, OffscreenTerminal.new(cols, 32))
        runner.boot(announce: false)
        if tab
          runner.focus_tab(tab, focus: :body)
          runner.settle_reads
        end
        yield runner, session
      ensure
        session.close
      end
    end
  ensure
    FileUtils.rm_rf(root)
  end
end

# The project's own "redact by default" switch, plus a pinned salt so the placeholders are
# reproducible — `Redact.salt` is process-wide and arming would otherwise mint one into the
# suite's shared settings.json (the spec/tui/copy_redaction_spec.cr idiom).
private def redacting(store, &)
  before = Gori::Redact.salt
  Gori::Redact.salt = "spec-salt"
  Gori::Redact::Policy.write_project_scope(store,
    Gori::Redact::Policy::ProjectScope.new(default: true))
  begin
    yield
  ensure
    Gori::Redact.salt = before
  end
end

private def shots : Array(String)
  return [] of String unless Dir.exists?(Gori::Paths.screenshots_dir)
  Dir.children(Gori::Paths.screenshots_dir).sort!
end

private def only_shot : String
  files = shots
  files.size.should eq(1)
  File.join(Gori::Paths.screenshots_dir, files.first)
end

# What the status strip is showing — the only public read of a toast there is.
private def status_text(runner : Gori::Tui::Runner) : String
  frame = runner.frame
  (0...frame.rows).map { |y| frame.row_text(y) }.join("\n")
end

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::None, char)
end

private def type_into(runner : Gori::Tui::Runner, text : String) : Nil
  text.each_char { |c| runner.feed(key(Termisu::Input::Key::Unknown, c)) }
end

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "gori-shot-dest-#{Process.pid}-#{rand(1_000_000)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "Runner#screenshot_capture" do
  it "writes one SVG into the screenshots convention dir, named for project and tab" do
    with_runner(tab: :history) do |runner, session|
      runner.screenshot_capture
      path = only_shot
      slug = File.basename(session.project.dir)
      File.basename(path).should match(/\A#{Regex.escape(slug)}-history-\d{8}-\d{6}\.svg\z/)
      File.read(path).should start_with("<svg")
    end
  end

  it "toasts in the export vocabulary — lowercase, with the path" do
    # Wide on purpose: the status strip truncates, and the path this asserts on is a tempdir
    # one. The toast is the subject here, so the terminal has to be big enough to show it.
    with_runner(tab: :history, cols: 260) do |runner|
      runner.screenshot_capture
      path = only_shot
      text = status_text(runner)
      text.should contain("screenshot written")
      # The PATH, not just the fact: a picture the operator cannot find is one they take again.
      text.should contain(File.basename(path))
      # Nothing ran, so nothing claims otherwise. `nil` sanitized is a different statement
      # from `0`, and this is the one the vocabulary must not invent.
      text.should_not contain("SANITIZED")
    end
  end

  it "suffixes rather than overwrites when the same second produces two captures" do
    with_runner(tab: :history) do |runner|
      runner.screenshot_capture
      runner.screenshot_capture
      # The stem carries a one-second timestamp, which is exactly why the suffix exists.
      shots.size.should eq(2)
      shots.count(&.ends_with?("-2.svg")).should eq(1)
    end
  end

  it "photographs the UI, not the palette the operator opened to reach the verb" do
    with_runner(tab: :history) do |runner|
      Gori::Tui::KeyScript.parse("C-p").each { |s| s.events.each { |ev| runner.feed(ev) } }
      runner.overlay.should eq(:palette)
      # The card really is on screen — otherwise the assertion below proves nothing.
      status_text(runner).should contain("COMMANDS")

      runner.screenshot_capture
      svg = File.read(only_shot)
      svg.should_not contain("COMMANDS")
      # …and the card is gone for good: `capture_frame` drops it rather than restoring it,
      # so the frame on disk and the frame on screen agree.
      runner.overlay.should eq(:none)
    end
  end

  it "photographs an open detail — a pane is not a menu, and only menus come down" do
    with_runner(seed: true, tab: :history) do |runner|
      runner.feed(key(Termisu::Input::Key::Enter))
      runner.settle_reads
      runner.overlay.should eq(:detail)

      runner.screenshot_capture
      svg = File.read(only_shot)
      # The request the detail is showing, not the list row behind it. A blanket
      # `leave_overlay` in `capture_frame` photographed the LIST here: the History/Issues
      # detail is an `OverlayKind` like the palette is, and it is the screen a response body
      # is actually read on.
      svg.should contain("Content-Type")
      runner.overlay.should eq(:detail) # …and taking a picture did not close it
    end
  end

  it "paints the project's redaction profile over the frame before it reaches disk" do
    with_runner(seed: true, tab: :history) do |runner, session|
      redacting(session.store) do
        # Open the flow's detail so the request body — and the secret in it — is on screen.
        runner.feed(key(Termisu::Input::Key::Enter))
        runner.settle_reads
        status_text(runner).should contain(SECRET) # the secret really is drawn

        runner.screenshot_capture
        svg = File.read(only_shot)
        svg.should_not contain(SECRET)
        # The correlation tag, not blocks: the region is wider than `Mask::TAG_WIDTH`, and the
        # tag is what makes two pictures of the same value comparable.
        svg.should contain("[REDACTED:")
        # …and the operator is told, with the count, in the same words a redacted copy uses.
        status_text(runner).should contain("SANITIZED (")
      end
    end
  end

  it "masks a form body drawn the way `pretty` reflows it, and counts it" do
    # Wide enough for the toast's own text: the count is the assertion, and the status strip
    # truncates. `pretty_bodies` is left at its factory ON, because that is the defect — the
    # screen says `password = …` and the derived form rule only knew `password=…`, so the
    # picture went to disk with the secret on it while the toast said SANITIZED (0).
    with_runner(form: true, tab: :history, cols: 200) do |runner, session|
      redacting(session.store) do
        runner.feed(key(Termisu::Input::Key::Enter))
        runner.settle_reads
        drawn = status_text(runner)
        drawn.should contain("password = ") # the PRETTY spelling really is what is drawn
        drawn.should contain(SECRET)

        runner.screenshot_capture
        svg = File.read(only_shot)
        svg.should_not contain(SECRET)
        svg.should contain("[REDACTED:")
        status_text(runner).should contain("SANITIZED (1)")
      end
    end
  end

  it "says how many of the profile's rules no frame could be asked for" do
    with_runner(form: true, tab: :history, cols: 200) do |runner, session|
      before = Gori::Redact.salt
      Gori::Redact.salt = "spec-salt"
      begin
        # A pointer names a position in a PARSED document; a screen has none. So this profile
        # masks nothing, and `SANITIZED (0)` alone would read as "checked, and clean".
        Gori::Redact::Policy.write_project_scope(session.store,
          Gori::Redact::Policy::ProjectScope.new(default: true, active: "ptr",
            profiles: [Gori::Redact::Profile.new(name: "ptr", json_pointers: ["/password"])]))
        runner.screenshot_capture
        text = status_text(runner)
        text.should contain("SANITIZED (0)")
        text.should contain("1 pointer rule not applied to a frame")
      ensure
        Gori::Redact.salt = before
      end
    end
  end

  it "writes the format settings:screenshot names" do
    with_runner(tab: :history) do |runner|
      Gori::Settings.screenshot_format = "txt"
      runner.screenshot_capture
      path = only_shot
      path.should end_with(".txt")
      # A real render, not an empty file: the tab bar gori drew is in it.
      File.read(path).should contain("History")
    end
  end

  it "reaches the PNG renderer for the png format" do
    with_runner(tab: :history) do |runner|
      Gori::Settings.screenshot_format = "png"
      Gori::Settings.screenshot_png_scale = 3 # read only on this arm
      runner.screenshot_capture
      only_shot.should end_with(".png")
      status_text(runner).should contain("screenshot written")
      # The BYTES are `Png.render`'s business and are pinned by spec/screenshot/png_spec.cr —
      # what belongs here is that the format setting routes to that renderer and names the
      # file after it.
    end
  end
end

describe "Runner#screenshot_save_as" do
  it "opens the export card prefilled with the settings default" do
    with_runner(tab: :history) do |runner|
      runner.screenshot_save_as
      runner.overlay.should eq(:export)
      # Nothing is written until the card commits.
      shots.should be_empty
      status_text(runner).should contain("EXPORT SCREENSHOT")
    end
  end

  it "writes to the operator's path, taking the format from the extension" do
    with_tmpdir do |dir|
      with_runner(tab: :history) do |runner|
        runner.screenshot_save_as
        dest = File.join(dir, "shot.txt")
        200.times { runner.feed(key(Termisu::Input::Key::Backspace)) }
        type_into(runner, dest)
        runner.feed(key(Termisu::Input::Key::Enter))
        runner.overlay.should eq(:none) # a successful write closes the card
        File.exists?(dest).should be_true
        File.read(dest).should contain("History") # the txt renderer, chosen by ".txt"
        shots.should be_empty                     # …and nothing landed in the convention dir
      end
    end
  end

  it "keeps the card up and says so when the extension names no format" do
    with_tmpdir do |dir|
      with_runner(tab: :history) do |runner|
        runner.screenshot_save_as
        dest = File.join(dir, "shot.jpeg")
        200.times { runner.feed(key(Termisu::Input::Key::Backspace)) }
        type_into(runner, dest)
        runner.feed(key(Termisu::Input::Key::Enter))
        # false from the commit closure: a mistyped extension is correctable, and making the
        # operator retype the whole directory is not the fix.
        runner.overlay.should eq(:export)
        File.exists?(dest).should be_false
        status_text(runner).should contain("unknown format")
      end
    end
  end
end
