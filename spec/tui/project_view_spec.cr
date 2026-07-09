require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Guards the Project tab DESCRIPTION scroll fix: a long description must scroll inside
# its card (mouse wheel → TextArea#scroll_view) instead of spilling past the page, and
# the wheel must hit the pane UNDER the pointer (ProjectView#pane_at, as the controller
# routes it). The core viewport-scroll mechanism is tested on TextArea directly.

private def tmp_store(&)
  path = File.tempname("gori-projview", ".db")
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

# Reset the global + per-project network layer to a known baseline (specs share Gori::Settings).
private def reset_projnet
  Gori::Settings.project_bind_host = nil
  Gori::Settings.project_bind_port = nil
  Gori::Settings.project_upstream_proxy = nil
  Gori::Settings.bind_host = "127.0.0.1"
  Gori::Settings.bind_port = 8070
  Gori::Settings.upstream_proxy = ""
end

private def render_ta(ta : TextArea, h : Int32) : MemoryBackend
  b = MemoryBackend.new(40, h)
  ta.render(Screen.new(b), Rect.new(0, 0, 40, h), cursor: false)
  b
end

# Render with a live caret into a `w`×3 grid and return the top row (for the
# horizontal-scroll assertions).
private def render_row0(ta : TextArea, w : Int32, highlight : Symbol? = nil) : String
  b = MemoryBackend.new(w, 3)
  ta.render(Screen.new(b), Rect.new(0, 0, w, 3), cursor: true, highlight: highlight)
  b.row(0)
end

describe "TextArea#scroll_view" do
  lines = (1..20).map { |i| "row%02d" % i }.join("\n")

  it "shifts the viewport immediately (independent of the cursor) and clamps both ends" do
    ta = TextArea.new(lines)
    render_ta(ta, 5).row(0).includes?("row01").should be_true # top before scrolling

    ta.scroll_view(3)                                         # one wheel notch (±3)
    render_ta(ta, 5).row(0).includes?("row04").should be_true # window jumped, cursor wasn't at the edge

    ta.scroll_view(100) # past the end → clamp to the last full window
    b = render_ta(ta, 5)
    b.row(0).includes?("row16").should be_true # 20 lines − 5 rows = scroll 15
    b.row(4).includes?("row20").should be_true # last line sits at the bottom, still inside

    ta.scroll_view(-100) # back past the top → clamp to 0
    render_ta(ta, 5).row(0).includes?("row01").should be_true
  end

  it "is a no-op before the first render (height unknown) and when the buffer already fits" do
    ta = TextArea.new(lines)
    ta.scroll_view(5) # no render yet ⇒ @last_h == 0
    render_ta(ta, 5).row(0).includes?("row01").should be_true

    short = TextArea.new("a\nb\nc")
    render_ta(short, 10) # 3 lines fit in 10 rows
    short.scroll_view(5)
    render_ta(short, 10).row(0).includes?("a").should be_true
  end
end

describe "TextArea horizontal scroll (follow_x)" do
  long = "HEAD" + ("." * 52) + "TAIL" # one 60-column line, head/tail tagged

  it "scrolls a long line sideways to keep the cursor visible, and resets when it fits" do
    ta = TextArea.new(long)
    ta.follow_x = true
    row = render_row0(ta, 20)
    row.includes?("HEAD").should be_true # caret at col 0 → window pinned to the start
    row.includes?("TAIL").should be_false

    ta.move(0, 1000) # caret to the end of the line
    row = render_row0(ta, 20)
    row.includes?("TAIL").should be_true  # tail scrolled into view next to the caret
    row.includes?("HEAD").should be_false # head scrolled off the left edge

    ta.move(0, -1000)                                    # caret back to the start
    render_row0(ta, 20).includes?("HEAD").should be_true # window slid back to 0
  end

  it "leaves long lines clipped at the start when follow_x is off (default — other editors)" do
    ta = TextArea.new(long) # follow_x defaults to false
    ta.move(0, 1000)        # caret past the right edge
    row = render_row0(ta, 20)
    row.includes?("HEAD").should be_true  # no horizontal scroll → head stays put
    row.includes?("TAIL").should be_false # legacy right-clip: tail is never reached
  end

  it "handles a wide-glyph (Hangul) line straddling the scroll boundary without drifting" do
    wide = "시작" + ("가" * 26) + "끝" # 4 + 52 + 2 = 58 columns; the cut lands mid-가
    ta = TextArea.new(wide)
    ta.follow_x = true
    ta.move(0, 1000)
    row = render_row0(ta, 20)
    row.includes?("끝").should be_true   # the trailing marker scrolled into view
    row.includes?("시작").should be_false # the leading marker scrolled off
  end

  it "keeps the markdown overlay aligned with the scrolled cells" do
    md = "# HEAD" + ("." * 50) + "TAIL" # heading line, 60 columns
    ta = TextArea.new(md)
    ta.follow_x = true
    ta.move(0, 1000)
    row = render_row0(ta, 20, highlight: :markdown)
    row.includes?("TAIL").should be_true  # styled (sliced) overlay shows the tail
    row.includes?("HEAD").should be_false # …and not the head
  end
end

describe "ProjectView DESCRIPTION scrolling" do
  it "scrolls a long description into view inside its card, staying on the page" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.replace_desc((1..40).map { |i| "desc%02d" % i }.join("\n"))
      view.focus_pane(:desc)
      rect = Rect.new(0, 0, 120, 30)

      b1 = MemoryBackend.new(120, 30)
      view.render(Screen.new(b1), rect, focused: true) # establishes the viewport height
      b1.contains?("desc01").should be_true
      b1.contains?("desc40").should be_false # the tail is below the fold

      view.desc_scroll(100) # wheel to the bottom
      b2 = MemoryBackend.new(120, 30)
      view.render(Screen.new(b2), rect, focused: true)
      b2.contains?("desc40").should be_true      # the tail scrolled into view
      b2.contains?("desc01").should be_false     # the head scrolled off
      b2.contains?("DESCRIPTION").should be_true # the card frame is intact (content stayed bounded)
    end
  end
end

describe "ProjectView created time" do
  it "shows project creation time in the local timezone" do
    path = File.tempname("gori-projview-created", ".db")
    store = Gori::Store.open(path)
    begin
      created_us = 1_700_000_000_000_000_i64
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: created_us, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      project = Gori::Project.new("t", path)
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.reload(project, store)
      expected = Time.unix(created_us // 1_000_000).to_local.to_s("%Y-%m-%d %H:%M")
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), Rect.new(0, 0, 120, 30), focused: false)
      b.contains?(expected).should be_true
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end

describe "ProjectView SCOPE add-row chips" do
  it "shows all kind and type chips on the add row" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      project = Gori::Project.new("t", File.tempname("gori-scope-chips"))
      view.reload(project, store)
      view.focus_pane(:scope)
      view.scope_add_start
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), Rect.new(0, 0, 120, 30), focused: true)
      b.contains?("incl").should be_true
      b.contains?("excl").should be_true
      b.contains?("host").should be_true
      b.contains?("string").should be_true
      b.contains?("regex").should be_true
    end
  end

  it "set_pend_type / set_pend_kind update the pending chips and commit uses them" do
    tmp_store do |store|
      scope = Gori::Scope.load(store)
      view = ProjectView.new(scope, Gori::HostOverrides.load(store))
      view.scope_add_start
      view.pend_type.should eq("host")
      view.set_pend_type("regex")
      view.pend_type.should eq("regex")
      view.set_pend_kind("exclude")
      view.pend_kind.should eq("exclude")
      "api\\..*\\.test".each_char { |c| view.scope_input(c) }
      view.scope_commit.should eq(:ok)
      rule = scope.rules.last
      rule.match_type.should eq("regex")
      rule.kind.should eq("exclude")
      rule.pattern.should eq("api\\..*\\.test")
    end
  end

  it "scope_add_chip_hit maps clicks onto kind and type chips" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      project = Gori::Project.new("t", File.tempname("gori-scope-hit"))
      view.reload(project, store)
      view.focus_pane(:scope)
      view.scope_add_start
      rect = Rect.new(0, 0, 120, 30)
      # Find the add-row y via a paint, then probe chips along the row.
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), rect, focused: true)
      y = (0...30).find { |yy| b.row(yy).includes?("add ") && b.row(yy).includes?("host") }.not_nil!
      row = b.row(y)
      # Click near the lit "host" label → stay host; "regex" → switch type.
      hx = row.index("host").not_nil!
      view.scope_add_chip_hit(rect, hx + 1, y).should eq(:type_host)
      rx = row.index("regex").not_nil!
      view.scope_add_chip_hit(rect, rx + 1, y).should eq(:type_regex)
      view.set_pend_type("regex")
      view.pend_type.should eq("regex")
      ex = row.index("excl").not_nil!
      view.scope_add_chip_hit(rect, ex + 1, y).should eq(:kind_exclude)
    end
  end
end

describe "ProjectView AT A GLANCE Technologies" do
  it "drops tech facts fingerprinted only on out-of-scope hosts once the scope lens is ON" do
    tmp_store do |store|
      store.upsert_prism_issue(
        Gori::Prism::Detection.new("tech_grpc", "tech", "a.test", "https://a.test/", "gRPC detected", Gori::Store::Severity::Info))
      store.upsert_prism_issue(
        Gori::Prism::Detection.new("tech_websocket", "tech", "b.test", "https://b.test/", "WebSocket detected", Gori::Store::Severity::Info))
      project = Gori::Project.new("t", File.tempname("gori-projview-p"))

      scope = Gori::Scope.load(store)
      scope.add("include", "host", "a.test")
      view = ProjectView.new(scope, Gori::HostOverrides.load(store))
      view.reload(project, store)
      rect = Rect.new(0, 0, 120, 30)

      b0 = MemoryBackend.new(120, 30)
      view.render(Screen.new(b0), rect, focused: false)
      b0.contains?("gRPC").should be_true
      b0.contains?("WebSocket").should be_true # lens off ⇒ every host's facts show

      scope.enable
      view.reload(project, store)
      b1 = MemoryBackend.new(120, 30)
      view.render(Screen.new(b1), rect, focused: false)
      b1.contains?("gRPC").should be_true
      b1.contains?("WebSocket").should be_false # out-of-scope host's fact dropped
    end
  end
end

describe "ProjectView#pane_at" do
  it "hides the ENV pane on short terminals" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      rect = Rect.new(0, 0, 120, 14)
      view.render(Screen.new(MemoryBackend.new(120, 14)), rect, focused: false)
      view.env_pane_enabled?.should be_false
      content_y = rect.y + 5
      view.pane_at(rect, rect.x + 1, content_y).should eq(:scope)
      view.pane_at(rect, rect.x + 1, rect.y + 10).should eq(:overrides)
      (content_y...rect.y + rect.h).each do |y|
        pane = view.pane_at(rect, rect.x + 1, y)
        pane.should_not eq(:env) if pane
      end
    end
  end

  it "splits the body into overview + SCOPE/OVERRIDES/ENV (left) / DESCRIPTION over NETWORK (right)" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      rect = Rect.new(0, 0, 120, 30)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect, focused: false)

      view.pane_at(rect, rect.x + 1, rect.y).should eq(:overview)
      content_y = rect.y + 12
      view.pane_at(rect, rect.x + 1, content_y).should eq(:scope)
      view.pane_at(rect, rect.x + 1, rect.y + 20).should eq(:overrides)
      view.pane_at(rect, rect.x + 1, rect.y + 26).should eq(:env)
      view.pane_at(rect, rect.right - 2, content_y).should eq(:desc)
      view.pane_at(rect, rect.right - 2, rect.y + 26).should eq(:settings)
      view.pane_at(Rect.new(0, 0, 0, 0), 0, 0).should be_nil
    end
  end
end

describe "ProjectView NETWORK pane" do
  it "renders the scope-lens toggle + the three network fields with an inherit marker" do
    tmp_store do |store|
      reset_projnet
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.refresh_settings
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), Rect.new(0, 0, 120, 30), focused: true)
      b.contains?("NETWORK").should be_true
      b.contains?("ENVIRONMENT").should be_true
      b.contains?("Scope lens").should be_true
      b.contains?("Bind IP").should be_true
      b.contains?("Bind Port").should be_true
      b.contains?("Upstream proxy").should be_true
      b.contains?("127.0.0.1").should be_true # inherited global bind host
      b.contains?("· global").should be_true  # no override yet → inheriting
    ensure
      reset_projnet
    end
  end

  it "marks a field · project when a per-project override is active" do
    tmp_store do |store|
      reset_projnet
      Gori::Settings.project_bind_port = 9100
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.refresh_settings
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), Rect.new(0, 0, 120, 30), focused: true)
      b.contains?("9100").should be_true
      b.contains?("· project").should be_true
    ensure
      reset_projnet
    end
  end

  it "hit-tests a settings row and edits a text field (dirty-tracked)" do
    tmp_store do |store|
      reset_projnet
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.refresh_settings
      view.focus_pane(:settings)
      rect = Rect.new(0, 0, 120, 30)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect, focused: true) # establish geometry

      view.set_row_at(rect, rect.right - 4, rect.y + 26).should_not be_nil # a row in the settings band
      view.settings_dirty?.should be_false                                 # fresh, inherited pane

      view.select_setting(2) # Bind Port
      view.settings_scope_row?.should be_false
      view.settings_text_row?.should be_true
      view.set_input('9')
      view.set_input('9')
      _, port, _ = view.settings_values
      port.should eq("807099") # inserted at the caret (field end)
      view.settings_dirty?.should be_true

      view.set_backspace
      view.settings_values[1].should eq("80709")
    ensure
      reset_projnet
    end
  end

  # Regression: settings_dirty? must diff the LOAD-TIME baseline, not live effective_*.
  # A global settings:network save (or a startup port-fallback) changes effective under an
  # untouched pane; if that read as "dirty", the next tab-leave `commit` would persist the
  # stale snapshot as a phantom per-project override, silently reverting the global edit.
  it "an untouched pane stays clean after a global edit moves effective (no phantom override)" do
    tmp_store do |store|
      reset_projnet
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.refresh_settings # baseline = inherited global (8070)
      view.settings_dirty?.should be_false

      Gori::Settings.bind_port = 9090      # a global settings:network save, no project override
      view.settings_dirty?.should be_false # the user never touched the pane → not dirty
    ensure
      reset_projnet
    end
  end
end
