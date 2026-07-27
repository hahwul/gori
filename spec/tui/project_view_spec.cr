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

describe "ProjectView DESCRIPTION insert mode" do
  # Arriving at the DESCRIPTION sub-tab must land in READ mode, where the arrows navigate;
  # only a click INSIDE the card opens the editor. That is the regression the sub-tab
  # promotion fixed — selecting the chip used to route through desc_click_to_cursor and drop
  # straight into INS, where ←/→ became caret movement with no way back out to the strip.
  it "only enters INS from a click inside its own card" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.replace_desc("one\ntwo")
      rect = Rect.new(0, 0, 120, 30)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect, focused: true)
      view.pane.should eq(:desc)
      view.desc_insert_mode?.should be_false # the tab opens on DESCRIPTION, in READ

      view.focus_pane(:scope) # another sub-tab is showing…
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect, focused: true)
      view.desc_click_to_cursor(rect, rect.x + 2, rect.y + 14)
      view.desc_insert_mode?.should be_false # …so a click in the body can't reach the editor

      view.focus_pane(:desc)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect, focused: true)
      view.desc_click_to_cursor(rect, rect.x + 2, rect.y + 14)
      view.desc_insert_mode?.should be_true
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

describe "ProjectView SCOPE list" do
  it "shows the empty-state hint (add via popup, not an inline row)" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      project = Gori::Project.new("t", File.tempname("gori-scope-empty"))
      view.reload(project, store)
      view.focus_pane(:scope)
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), Rect.new(0, 0, 120, 30), focused: true)
      b.contains?("no rules").should be_true
      b.contains?("a to add").should be_true
    end
  end
end

describe "ProjectView AT A GLANCE Technologies" do
  it "drops tech facts fingerprinted only on out-of-scope hosts once the scope lens is ON" do
    tmp_store do |store|
      store.upsert_probe_issue(
        Gori::Probe::Detection.new("tech_grpc", "tech", "a.test", "https://a.test/", "gRPC detected", Gori::Store::Severity::Info))
      store.upsert_probe_issue(
        Gori::Probe::Detection.new("tech_websocket", "tech", "b.test", "https://b.test/", "WebSocket detected", Gori::Store::Severity::Info))
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

describe "ProjectView AT A GLANCE severity" do
  # Severity bars draw from the human-confirmed `issues` table only — Probe hits
  # must not inflate the glance pane (they belong on the Probe tab).
  it "shows Issues severity and ignores Probe-only findings" do
    tmp_store do |store|
      store.insert_issue("XSS on /search", Gori::Store::Severity::Critical, "acme.test", nil)
      store.insert_issue("Verbose error", Gori::Store::Severity::Low, "acme.test", nil)
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        code: "cors_wildcard", category: "security", host: "acme.test",
        url: "http://acme.test/api", title: "cors *", severity: Gori::Store::Severity::High))
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        code: "missing_hsts", category: "security", host: "acme.test",
        url: "http://acme.test/", title: "no hsts", severity: Gori::Store::Severity::Medium))
      store.flush

      project = Gori::Project.new("t", File.tempname("gori-projview-sev"))
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.reload(project, store)
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), Rect.new(0, 0, 120, 30), focused: false)

      b.contains?("AT A GLANCE").should be_true
      b.contains?("CRIT").should be_true  # Issues Critical
      b.contains?("LOW").should be_true   # Issues Low
      b.contains?("HIGH").should be_false # Probe-only High must not appear
      b.contains?("MED").should be_false  # Probe-only Medium must not appear
    end
  end
end

describe "ProjectView#pane_at" do
  # The body is now ONE card under a chip strip, not five tiles. The pane the strip selects is
  # the pane the body belongs to — that mapping is what these pin.
  it "gives the whole body to the active sub-tab" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      rect = Rect.new(0, 0, 120, 30)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect, focused: false)

      view.pane_at(rect, rect.x + 1, rect.y).should eq(:overview)
      # DESCRIPTION is the first chip, so it's active by default: both edges of the body
      # belong to it, where the old tiling would have answered :scope on the left.
      body_y = rect.y + 14
      view.pane_at(rect, rect.x + 1, body_y).should eq(:desc)
      view.pane_at(rect, rect.right - 2, body_y).should eq(:desc)

      view.focus_pane(:settings)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect, focused: false)
      view.pane_at(rect, rect.x + 1, body_y).should eq(:settings)
      view.pane_at(Rect.new(0, 0, 0, 0), 0, 0).should be_nil
    end
  end

  # ENV used to drop OUT OF THE RING below a height threshold, so on a short terminal it was
  # simply unreachable. Panes no longer share the body, so the ring is now height-independent —
  # that is the behaviour worth pinning, not a pixel offset. DESCRIPTION leads the order.
  it "walks every sub-tab from the first chip, regardless of height" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      rect = Rect.new(0, 0, 120, 14) # short enough that the old layout hid ENV
      view.render(Screen.new(MemoryBackend.new(120, 14)), rect, focused: false)

      view.pane.should eq(:desc) # the strip opens on DESCRIPTION
      visited = [view.pane]
      while view.pane_advance(1)
        visited << view.pane
      end
      visited.should eq(Gori::Tui::ProjectView::PANES)
      view.pane_advance(1).should be_false # the strip clamps at the last chip, it does not wrap
    end
  end

  # The strip is how the mouse reaches a pane that is not currently drawn.
  it "selects a sub-tab from a click on the chip strip" do
    tmp_store do |store|
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      rect = Rect.new(0, 0, 160, 30)
      view.render(Screen.new(MemoryBackend.new(160, 30)), rect, focused: true)
      # Find the strip by scanning down for the row where more than one pane is addressable —
      # that only happens on the chip row, since the body belongs to a single pane.
      hits = [] of Symbol
      strip_y = -1
      (rect.y...rect.bottom).each do |y|
        row = (rect.x...rect.right).compact_map { |x| view.pane_at(rect, x, y) }.uniq
        next unless row.size > 1
        hits = row
        strip_y = y
        break
      end
      # Every pane is addressable from the strip, including ones the body is not showing.
      hits.should contain(:scope)
      hits.should contain(:settings)
      hits.should contain(:env)

      # strip_chip_at is the narrower question the controller asks: "is this a CHIP click?" —
      # it must answer only on the strip row, so a body click can never be mistaken for a
      # sub-tab switch (and a chip click never opens the DESCRIPTION editor).
      chips = (rect.x...rect.right).compact_map { |x| view.strip_chip_at(rect, x, strip_y) }.uniq
      chips.should eq(hits)
      view.strip_chip_at(rect, rect.x + 1, rect.y + 14).should be_nil # inside the card
      view.strip_chip_at(rect, rect.x + 1, rect.y).should be_nil      # OVERVIEW band
      view.strip_chip_at(Rect.new(0, 0, 0, 0), 0, 0).should be_nil    # empty layout
    end
  end
end

describe "ProjectView NETWORK pane" do
  it "renders the scope-lens + sandbox toggles + the three network fields with an inherit marker" do
    tmp_store do |store|
      reset_projnet
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.refresh_settings
      view.focus_pane(:settings) # the body shows one card at a time now
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), Rect.new(0, 0, 120, 30), focused: true)
      b.contains?("NETWORK").should be_true
      b.contains?("ENV").should be_true # the chip strip still names every sub-tab
      b.contains?("Scope lens").should be_true
      b.contains?("Sandbox").should be_true
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
      view.focus_pane(:settings)
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

      view.set_row_at(rect, rect.x + 4, rect.y + 16).should_not be_nil # a row in the (now full-width) settings card
      view.settings_dirty?.should be_false                             # fresh, inherited pane

      view.select_setting(3) # Bind Port (row 0 lens, 1 sandbox, 2 bind IP, 3 bind port)
      view.settings_scope_row?.should be_false
      view.settings_sandbox_row?.should be_false
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
