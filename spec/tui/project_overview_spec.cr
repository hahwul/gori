require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Project tab's OVERVIEW band and its DESCRIPTION empty state.
#
# The band's contract is that its ROW BUDGET CLOSES: `overview_plan` picks a fold level and
# `render_overview` paints exactly that many rows, so no fact is ever left for a `break` to
# discard. Before this, eight `label:value` lines were written into a band that is six rows
# tall at 80×24, and `break if y > max_y` silently dropped Issues and Technologies.

# A registry-shaped project: its own directory, a `gori.db` inside it, and the `.id` /
# `.workspace` sidecars the Project tab now reads. `canonical?` is true for this one.
private def registry_project(dir : String, name : String, *, id : String? = nil, workspace : String? = nil)
  File.write(File.join(dir, Gori::ProjectRegistry::ID_FILE), id) if id
  File.write(File.join(dir, Gori::ProjectRegistry::WORKSPACE_FILE), workspace) if workspace
  # Name deliberately NOT the temp directory's basename: those run ~35 characters, which is
  # itself a squeeze case and would quietly make every assertion below test the wrong thing.
  # Real project names are short slugs; the long-name squeeze gets its own example.
  Gori::Project.new(name, File.join(dir, Gori::Project::DB_FILE))
end

# A project the REGISTRY owns: `$GORI_HOME/projects/<slug>/gori.db`. The parent has to be the
# real projects root, because `load_registry_facts` requires it — a `gori.db` in some arbitrary
# directory is not a registry project even though its filename is canonical.
private def with_project(name : String = "zoanthid", *, id : String? = nil, workspace : String? = nil, &)
  home = File.tempname("gori-ov-home")
  root = File.join(home, "projects", name)
  Dir.mkdir_p(root)
  prev = ENV["GORI_HOME"]?
  ENV["GORI_HOME"] = home
  begin
    project = registry_project(root, name, id: id, workspace: workspace)
    store = Gori::Store.open(project.db_path)
    begin
      yield project, store
    ensure
      store.close
    end
  ensure
    prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(home)
  end
end

private def render_tab(view : ProjectView, w : Int32, h : Int32, *,
                       focused : Bool = false, capturing : Bool = false) : MemoryBackend
  b = MemoryBackend.new(w, h)
  view.render(Screen.new(b), Rect.new(0, 0, w, h), focused: focused, capturing: capturing)
  b
end

# Index of the first row containing `text`, or nil.
private def row_of(b : MemoryBackend, text : String) : Int32?
  (0...b.grid.size).find { |y| b.row(y).includes?(text) }
end

private def fresh_view(store) : ProjectView
  ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
end

# Whether the band carries the captured-flow count at all, in whichever form its fold level
# uses — `Flows: 1` when rows are expanded, `1 flow` once the volume group folds to one line.
# The guarantee under test is that the fact survives every band height, not that it keeps one
# shape, so asserting on a single spelling would only pin the tier the spec happened to hit.
private def carries_flow_count?(b : MemoryBackend) : Bool
  b.contains?("Flows:") || b.contains?("1 flow")
end

private def add_flow(store, host : String = "h.test")
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_700_000_000_000_000_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

describe "ProjectView OVERVIEW row budget" do
  it "keeps every group at 80x24, where the old fixed list dropped two rows" do
    with_project(id: "5a3f9c1e") do |project, store|
      add_flow(store)
      view = fresh_view(store)
      view.reload(project, store)
      # 80x24 is the terminal the band overflowed on: the viz pane still fits (band 76 cols),
      # leaving OVERVIEW one column and six interior rows for what used to be eight lines.
      b = render_tab(view, 80, 24)
      # Every group survives, folded rather than dropped. Issues and Technologies are the two
      # the old `break` discarded, so they are the load-bearing assertions here.
      b.contains?("1 flow").should be_true  # volume group (folded)
      b.contains?("issues").should be_true  # ...including Issues, which used to vanish
      b.contains?("tech").should be_true    # ...and Technologies, the other casualty
      b.contains?("created").should be_true # provenance group
      b.contains?(project.name).should be_true
      b.contains?("5a3f9c1e").should be_true # identity group carries the short id
    end
  end

  it "collapses further rather than dropping a group as the band shrinks" do
    with_project(id: "5a3f9c1e") do |project, store|
      add_flow(store)
      view = fresh_view(store)
      view.reload(project, store)
      # Every height from a one-row band upward keeps the name and the traffic count: the fold
      # levels bottom out at a single line, they never bottom out at nothing. Sweeping the range
      # is the point — a single height only proves the one tier it lands in.
      (10..40).each do |h|
        b = render_tab(view, 80, h)
        b.contains?(project.name).should be_true
        carries_flow_count?(b).should be_true
      end
    end
  end

  it "spends a long name, not the counts, when only one row is left" do
    with_project("a-very-long-engagement-name-that-will-not-fit", id: "5a3f9c1e") do |project, store|
      add_flow(store)
      view = fresh_view(store)
      view.reload(project, store)
      # A one-row band. Concatenating name + counts and letting `width:` ellipsize the result
      # pushed the numbers off the end, leaving a line that looked complete and answered
      # nothing. The name is the piece that gives, and it is still readable from the tab title.
      b = render_tab(view, 80, 10)
      carries_flow_count?(b).should be_true
      b.contains?(project.name).should be_false # elided, deliberately
      b.contains?("a-very-long").should be_true # ...but still identifiable
    end
  end

  it "deals rows into two columns on a wide band" do
    with_project(id: "5a3f9c1e", workspace: "/tmp/ws") do |project, store|
      add_flow(store)
      view = fresh_view(store)
      view.reload(project, store)
      b = render_tab(view, 160, 40)
      # Two columns means a single row carries two labels. In one column "Name:" and the
      # volume labels are on different rows, so this is the assertion that distinguishes them.
      y = row_of(b, "Name:")
      y.should_not be_nil
      row = b.row(y.not_nil!)
      row.includes?("Name:").should be_true
      # The right column starts past the midpoint, so the row holds a second label too.
      row.count(':').should be > 1
    end
  end

  it "paints every label in the expanded tier — the band is sized for all of them" do
    with_project(id: "5a3f9c1e", workspace: "/tmp/ws") do |project, store|
      add_flow(store)
      view = fresh_view(store)
      view.reload(project, store)
      b = render_tab(view, 160, 40)
      # `overview_h` sizes the band from `ov_group_sizes`, and `draw_ov_column` still carries a
      # bounds `break` that is only unreachable BECAUSE that count is right. If the count ever
      # under-reports, the band is short and the break silently drops rows again — so assert the
      # whole set, not a sample. (Sabotage check: make `ov_group_sizes` under-count a group.)
      ["Name:", "Path:", "ID:", "Workspace:", "Proxy:", "Flows:", "Captured:",
       "Issues:", "DB Size:", "Created:", "Activity:", "Technologies:"].each do |label|
        b.contains?(label).should be_true
      end
    end
  end

  it "spans Technologies across the full width, below both columns" do
    with_project(id: "5a3f9c1e", workspace: "/tmp/ws") do |project, store|
      add_flow(store)
      view = fresh_view(store)
      view.reload(project, store)
      b = render_tab(view, 160, 40)
      ty = row_of(b, "Technologies:")
      ty.should_not be_nil
      # Its own row: the longest, most variable value on the tab does not share a half-width
      # cell with a neighbour that would truncate it first.
      b.row(ty.not_nil!).count(':').should eq 1
    end
  end
end

describe "ProjectView OVERVIEW facts" do
  it "shows the proxy address with the live capture state" do
    with_project do |project, store|
      add_flow(store)
      view = fresh_view(store)
      view.reload(project, store)
      # `capturing` is a RENDER argument, not a `reload` snapshot — capture toggles while the
      # tab sits open, so the same view must answer differently on two consecutive frames.
      render_tab(view, 160, 40, capturing: true).contains?("capturing").should be_true
      render_tab(view, 160, 40, capturing: false).contains?("paused").should be_true
    end
  end

  it "counts unreviewed Probe hits beside the confirmed Issues count" do
    with_project do |project, store|
      add_flow(store)
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        code: "test.finding", category: "test", host: "h.test", url: "http://h.test/",
        title: "t", severity: Gori::Store::Severity::Low, evidence: nil))
      view = fresh_view(store)
      view.reload(project, store)
      b = render_tab(view, 160, 40)
      # The AT A GLANCE severity CHART stays `issues`-only on purpose; this is a count.
      b.contains?("probe 1").should be_true
    end
  end

  it "hides the identity of a canonical gori.db OUTSIDE the projects root" do
    home = File.tempname("gori-ov-home2")
    Dir.mkdir_p(File.join(home, "projects"))
    outside = File.join(home, "backup", "api")
    Dir.mkdir_p(outside)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = home
    begin
      # `--db ~/backup/api/gori.db`. The FILENAME is canonical, so `Project#canonical?` alone
      # says yes — and reading the sidecars there would print an id that `ProjectRegistry#find`
      # resolves to a DIFFERENT project. The guard needs the parent to be the projects root too.
      File.write(File.join(outside, Gori::ProjectRegistry::ID_FILE), "cafed00d")
      File.write(File.join(outside, Gori::ProjectRegistry::WORKSPACE_FILE), "/tmp/elsewhere")
      borrowed = Gori::Project.new("borrowed", File.join(outside, Gori::Project::DB_FILE))
      borrowed.canonical?.should be_true # the filename test on its own is not enough
      store = Gori::Store.open(borrowed.db_path)
      begin
        add_flow(store)
        view = fresh_view(store)
        view.reload(borrowed, store)
        b = render_tab(view, 160, 40)
        b.contains?("cafed00d").should be_false
        b.contains?("/tmp/elsewhere").should be_false
      ensure
        store.close
      end
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(home)
    end
  end

  it "hides the registry identity of a --db project instead of guessing it" do
    root = File.tempname("gori-ov-dbroot")
    Dir.mkdir_p(root)
    begin
      # A registry directory with real sidecars, and a SECOND database inside it reached by
      # `--db`. `slug_of`/`id_of`/`workspace_of` all key on the DIRECTORY, so an unguarded
      # read here would attribute the neighbour's identity to this project.
      File.write(File.join(root, Gori::ProjectRegistry::ID_FILE), "deadbeef")
      File.write(File.join(root, Gori::ProjectRegistry::WORKSPACE_FILE), "/tmp/not-mine")
      side = Gori::Project.new("side", File.join(root, "other.db"))
      side.canonical?.should be_false
      store = Gori::Store.open(side.db_path)
      begin
        add_flow(store)
        view = fresh_view(store)
        view.reload(side, store)
        b = render_tab(view, 160, 40)
        b.contains?("deadbeef").should be_false
        b.contains?("/tmp/not-mine").should be_false
        b.contains?("side").should be_true # its own name is still its own
      ensure
        store.close
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe "ProjectView DESCRIPTION empty state" do
  it "names its own emptiness instead of rendering a void" do
    with_project do |project, store|
      view = fresh_view(store)
      view.reload(project, store)
      view.focus_pane(:desc)
      b = render_tab(view, 100, 30, focused: true)
      b.contains?("Target, scope, credentials, rules.").should be_true
      b.contains?("PROJECT").should be_true
    end
  end

  it "steps out of the way in INSERT — the operator came here to type" do
    with_project do |project, store|
      view = fresh_view(store)
      view.reload(project, store)
      view.focus_pane(:desc)
      view.enter_desc_insert!
      b = render_tab(view, 100, 30, focused: true)
      # A "no description yet" sitting under the caret reads as text just deleted.
      b.contains?("Target, scope, credentials, rules.").should be_false
    end
  end

  it "suppresses the read caret, which would otherwise sit on the card" do
    with_project do |project, store|
      view = fresh_view(store)
      # The description must be RENDERED AS AN EDITOR FIRST. `TextReadState#paint_chrome` bails
      # on an empty `TextArea#last_rows`, and only `TextArea#render` fills that in — so on a
      # never-rendered buffer the stray caret cannot appear and asserting there proves nothing.
      # The reachable sequence is: text, drawn, then emptied (a peer write, `^E`, a reload).
      store.set_setting(ProjectView::DESC_KEY, "something")
      view.reload(project, store)
      view.focus_pane(:desc)
      render_tab(view, 100, 30, focused: true)

      store.set_setting(ProjectView::DESC_KEY, "")
      view.reload(project, store)
      b = render_tab(view, 100, 30, focused: true)
      dy = row_of(b, "DESCRIPTION")
      dy.should_not be_nil
      # `paint_chrome`'s only ink on an empty buffer is one accent-bg caret at the card's
      # interior top-left. Gating the card without gating the chrome leaves it on the art.
      b.bg_at(1, dy.not_nil! + 1).should_not eq Theme.accent_bg
    end
  end

  it "yields to the real editor as soon as there is text" do
    with_project do |project, store|
      store.set_setting(ProjectView::DESC_KEY, "engagement notes here")
      view = fresh_view(store)
      view.reload(project, store)
      view.focus_pane(:desc)
      b = render_tab(view, 100, 30, focused: true)
      b.contains?("engagement notes here").should be_true
      b.contains?("Target, scope, credentials, rules.").should be_false
    end
  end
end

describe "TrafficEmptyState :project_desc" do
  it "centres its card with no headline row, like :notes" do
    b = MemoryBackend.new(60, 24)
    TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, 60, 24), variant: :project_desc)
    b.contains?("PROJECT").should be_true
    # CENTERED variants spend no row on a headline above the card.
    b.contains?("no description yet").should be_false
  end

  it "degrades to lines, then to one hint, without ever drawing past the rect" do
    # Medium: too short for the card, wide enough for lines.
    med = MemoryBackend.new(40, 6)
    TrafficEmptyState.render(Screen.new(med), Rect.new(0, 0, 40, 6), variant: :project_desc)
    med.contains?("no description yet").should be_true

    # Minimal: one line.
    min = MemoryBackend.new(28, 3)
    TrafficEmptyState.render(Screen.new(min), Rect.new(0, 0, 28, 3), variant: :project_desc)
    min.contains?("no description").should be_true
  end
end
