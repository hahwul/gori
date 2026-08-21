require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-hv-cm", ".db")
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

private def add_flow(store, method = "GET", target = "/search", status : Int32? = 200,
                     content_type : String? = "application/json", host = "h.test")
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\nbody".to_slice,
      body: "body".to_slice, content_type: content_type))
  end
  id
end

# The global rule library is process-wide (Settings), so restore what we found.
private def with_globals(&)
  before = Gori::Settings.colormarker_rules
  counter = Gori::Settings.colormarker_next_rule_id
  begin
    Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
    Gori::Settings.colormarker_next_rule_id = 1_i64
    yield
  ensure
    Gori::Settings.colormarker_rules = before
    Gori::Settings.colormarker_next_rule_id = counter
  end
end

private RED   = "red" # a rule's colour is a label string now, not the MarkerColor enum
private FULL  = Gori::Store::MarkerStyle::Full
private STRIP = Gori::Store::MarkerStyle::Strip

describe "History — Colormarker row marks" do
  # The regression fence for the CONDITIONAL swatch column. Every HistoryView constructed
  # without an engine — which is every construction site outside HistoryController, and every
  # existing History spec — must render exactly as it did before this feature existed.
  it "reserves no column and paints nothing when there is no engine" do
    tmp_store do |store|
      add_flow(store)
      view = HistoryView.new
      view.reload(store)
      backend = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
      # TIME sits at rect.x + 1, unshifted.
      backend.grid[1][1, 4].join.should eq("TIME")
    end
  end

  it "reserves no column when the only enabled rule is a full-row one" do
    with_globals do
      tmp_store do |store|
        add_flow(store)
        cm = Gori::Colormarker.load(store)
        cm.add("host:h.test", RED, FULL)
        view = HistoryView.new
        view.set_colormarker(cm)
        view.reload(store)
        backend = MemoryBackend.new(80, 12)
        view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
        backend.grid[1][1, 4].join.should eq("TIME")
      end
    end
  end

  it "shifts the fixed left block by two and paints a swatch for a strip rule" do
    with_globals do
      tmp_store do |store|
        add_flow(store)
        cm = Gori::Colormarker.load(store)
        cm.add("host:h.test", RED, STRIP)
        view = HistoryView.new
        view.set_colormarker(cm)
        view.reload(store)
        backend = MemoryBackend.new(80, 12)
        view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))

        backend.grid[1][3, 4].join.should eq("TIME") # header moved with the column
        row_y = 3                                    # QL bar, header, divider, first row
        backend.grid[row_y][1].should eq('█')
        backend.fg_grid[row_y][1].should eq(Theme.mark_color("red"))
        # The swatch column is its own cell: TIME still starts at +3, not over the block.
        backend.grid[row_y][2].should eq(' ')
      end
    end
  end

  # The cross-layer loop: a rule whose colour is a user-defined CUSTOM name paints the row with
  # that colour's absolute hex, resolved through the render-side mark map.
  it "paints a row with a custom colour's absolute hex" do
    with_globals do
      begin
        Theme.set_custom_marks({"coral" => "#ff6b6b"})
        tmp_store do |store|
          add_flow(store)
          cm = Gori::Colormarker.load(store)
          cm.add("host:h.test", "coral", STRIP) # a custom name, not a built-in word
          view = HistoryView.new
          view.set_colormarker(cm)
          view.reload(store)
          backend = MemoryBackend.new(80, 12)
          view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))

          row_y = 3
          backend.grid[row_y][1].should eq('█')
          backend.fg_grid[row_y][1].should eq(Gori::Tui::Color.from_hex("#ff6b6b"))
        end
      ensure
        Theme.set_custom_marks({} of String => String)
      end
    end
  end

  # The widened `fill` guard. A tint that reached only the cells passing an explicit bg would
  # leave the GAPS between columns on the canvas — a striped row rather than a band, and the
  # easiest bug in the feature to ship.
  it "fills the whole row for a full-row rule, gaps included" do
    with_globals do
      tmp_store do |store|
        add_flow(store)
        add_flow(store) # row 0 is always the cursor row; assert on the one below it
        cm = Gori::Colormarker.load(store)
        cm.add("host:h.test", RED, FULL)
        view = HistoryView.new
        view.set_colormarker(cm)
        view.reload(store)
        backend = MemoryBackend.new(80, 12)
        view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))

        row_y = 4  # QL bar, header, divider, cursor row, then this one
        gap_x = 15 # TIME is "MM-DD HH:MM:SS" at x=1..14; METHOD starts at 16
        tint = Theme.row_tint(Theme.mark_color("red"), Theme.bg)
        backend.grid[row_y][gap_x].should eq(' ') # genuinely a gap, not a glyph cell
        backend.bg_grid[row_y][gap_x].should eq(tint)
        backend.bg_grid[row_y][0].should eq(tint) # the gutter cell too
        backend.contains?("GET").should be_true   # the row still says what it said
        backend.contains?("200").should be_true
      end
    end
  end

  # A display feature may never make the cursor harder to find: the band and the hue COMPOSE,
  # so a selected coloured row reads as both rather than as one or the other.
  it "mixes the hue into the selection band rather than replacing it" do
    with_globals do
      tmp_store do |store|
        add_flow(store)
        cm = Gori::Colormarker.load(store)
        cm.add("host:h.test", RED, FULL)
        view = HistoryView.new
        view.set_colormarker(cm)
        view.reload(store)
        backend = MemoryBackend.new(80, 12)
        view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12), focused: true)

        row_y = 3
        painted = backend.bg_grid[row_y][12]
        painted.should_not eq(Theme.bg)        # not the plain canvas
        painted.should_not eq(Theme.accent_bg) # not the bare selection band either
        painted.should eq(Theme.row_tint(Theme.mark_color("red"), Theme.accent_bg))
        backend.grid[row_y][0].should eq('▎') # and the cursor bar is still there
      end
    end
  end

  it "keeps the mark bar on a marked coloured row" do
    with_globals do
      tmp_store do |store|
        id = add_flow(store)
        cm = Gori::Colormarker.load(store)
        cm.add("host:h.test", RED, FULL)
        view = HistoryView.new
        view.set_colormarker(cm)
        view.reload(store)
        view.toggle_mark
        view.marked?(id).should be_true

        backend = MemoryBackend.new(80, 12)
        # unfocused, so the cursor band and the mark band are the same dim — the glyph is
        # what distinguishes them, and the tint must not eat it
        view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
        backend.grid[3][0].should eq('▌')
      end
    end
  end

  # The memo-eviction fence. An in-flight row has no status, so `status:>=500` genuinely
  # answers differently once the response lands — without the `on_event(:updated)` eviction the
  # row would keep its pending colour for the rest of the session.
  it "re-asks a row's colour when its response lands" do
    with_globals do
      tmp_store do |store|
        id = add_flow(store, status: nil)
        add_flow(store) # newer, so it takes the cursor row and leaves the pending one plain
        cm = Gori::Colormarker.load(store)
        cm.add("status:>=500", RED, FULL)
        view = HistoryView.new
        view.set_colormarker(cm)
        view.reload(store)

        backend = MemoryBackend.new(80, 12)
        view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
        backend.bg_grid[4][15].should eq(Color.default) # pending: no status, no colour, no fill

        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 503, head: "HTTP/1.1 503 X\r\n\r\n".to_slice, body: nil))
        view.on_event(Gori::Store::FlowEvent.new(id, :updated), store)

        after = MemoryBackend.new(80, 12)
        view.render_list(Screen.new(after), Rect.new(0, 0, 80, 12))
        after.bg_grid[4][15].should eq(Theme.row_tint(Theme.mark_color("red"), Theme.bg))
      end
    end
  end

  # A rule edited on the Colormarker tab (or by an external process, arriving through
  # `Runner#apply_external_change`) repaints History with no cross-tab callback: the engine's
  # revision counter IS the notification.
  it "repaints from a rule change with no explicit invalidation" do
    with_globals do
      tmp_store do |store|
        add_flow(store)
        add_flow(store)
        cm = Gori::Colormarker.load(store)
        view = HistoryView.new
        view.set_colormarker(cm)
        view.reload(store)

        before = MemoryBackend.new(80, 12)
        view.render_list(Screen.new(before), Rect.new(0, 0, 80, 12))
        before.bg_grid[4][15].should eq(Color.default)

        cm.add("host:h.test", RED, FULL) # nobody tells the view

        after = MemoryBackend.new(80, 12)
        view.render_list(Screen.new(after), Rect.new(0, 0, 80, 12))
        after.bg_grid[4][15].should eq(Theme.row_tint(Theme.mark_color("red"), Theme.bg))
      end
    end
  end

  # The strip column is the only thing that moves the layout, so the narrow-pane behaviour the
  # existing spec pins has to survive it being armed.
  it "keeps PATH legible at 65 columns with the swatch column armed" do
    with_globals do
      tmp_store do |store|
        add_flow(store)
        cm = Gori::Colormarker.load(store)
        cm.add("host:h.test", RED, STRIP)
        view = HistoryView.new
        view.set_colormarker(cm)
        view.reload(store)

        backend = MemoryBackend.new(65, 8)
        view.render_list(Screen.new(backend), Rect.new(3, 0, 59, 8))
        backend.contains?("STA").should be_true
        backend.contains?("PATH").should be_true
        backend.contains?("PSTA").should be_false
        backend.contains?("/search").should be_true
      end
    end
  end
end
