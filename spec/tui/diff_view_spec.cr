require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/diff_view"

include Gori::Tui

private def diff_facts(key : Gori::Diff::Key, *, status : Int32, size : Int64,
                       flow_id : Int64 = 1_i64) : Gori::Diff::Facts
  f = Gori::Diff::Facts.new(key)
  f.observe(Gori::Store::EndpointObservation.new(
    key.host, key.method, key.path, status, "application/json",
    1_i64, size, size, 1_i64, 1_i64, flow_id))
  f
end

private def diff_row(path : String, verdict : Gori::Diff::Verdict,
                     changes = [] of Gori::Diff::Change) : Gori::Diff::Row
  key = Gori::Diff::Key.new("acme.test", "GET", path)
  a = verdict.added? ? nil : diff_facts(key, status: 200, size: 100_i64)
  b = verdict.removed? ? nil : diff_facts(key, status: 200, size: 100_i64, flow_id: 2_i64)
  Gori::Diff::Row.new(key, verdict, a, b, changes)
end

private def coverage(label : String) : Gori::Diff::Coverage
  Gori::Diff::Coverage.new(label, "#{label}.db", 4_i64, 3, 1, 1_i64, 2_i64, false, [] of String, false)
end

private def diff_report(rows : Array(Gori::Diff::Row)) : Gori::Diff::Report
  Gori::Diff::Report.new(coverage("q1"), coverage("q3"), rows, [] of Gori::Diff::IssueRetest)
end

private def loaded_view : DiffView
  v = DiffView.new
  v.set_slot(:a, Gori::Project.new("q1", "/tmp/q1.db"))
  v.set_slot(:b, Gori::Project.new("q3", "/tmp/q3.db"))
  v.report = diff_report([
    diff_row("/new", Gori::Diff::Verdict::Added),
    diff_row("/same", Gori::Diff::Verdict::Unchanged),
    diff_row("/moved", Gori::Diff::Verdict::Changed,
      [Gori::Diff::Change.new(Gori::Diff::Axis::Auth, "not required", "required")]),
    diff_row("/never-revisited", Gori::Diff::Verdict::Removed),
  ])
  v
end

private def render_rows(v : DiffView, w = 100, h = 24) : Array(String)
  backend = MemoryBackend.new(w, h)
  v.render(Screen.new(backend), Rect.new(0, 0, w, h), focused: true)
  (0...h).map { |y| backend.row(y) }
end

describe DiffView do
  it "hides the unchanged rows by default and still counts them" do
    v = loaded_view
    # Report order is preserved verbatim — the lens narrows, it never re-sorts.
    v.rows.map(&.key.path).should eq(["/new", "/moved", "/never-revisited"])
    lines = render_rows(v).join("\n")
    lines.should contain("unchanged 1")
    lines.should_not contain("/same")
  end

  it "walks the verdict lens ring and narrows the listing" do
    v = loaded_view
    v.cycle_lens(1).should eq(Gori::Diff::Verdict::Added)
    v.rows.map(&.key.path).should eq(["/new"])
    v.cycle_lens(-1).should be_nil # back to the default findings lens
    v.rows.size.should eq(3)
  end

  it "keeps the cursor on the same endpoint across a lens change when it survives" do
    v = loaded_view
    v.select_index(v.rows.index! { |r| r.key.path == "/moved" })
    v.cycle_lens(1) # added
    v.cycle_lens(1) # gone — empty
    v.cycle_lens(1) # changed — /moved is back
    v.selected_row.try(&.key.path).should eq("/moved")
  end

  it "says WHICH lens emptied the list, not just that it is empty" do
    v = loaded_view
    v.cycle_lens(1) # added
    v.cycle_lens(1) # gone — no rows
    render_rows(v).join("\n").should contain("no gone endpoints")
  end

  it "draws the coverage-gap caveat on the header, where it cannot scroll away" do
    # The count is meaningless without it: an endpoint missing from B may simply not have
    # been visited. A footer would scroll; a toast would expire.
    render_rows(loaded_view).join("\n").should contain("coverage gap")
  end

  it "labels a not-requested endpoint 'not seen', never 'removed'" do
    lines = render_rows(loaded_view).join("\n")
    lines.should contain("not seen")
    lines.should contain("/never-revisited")
  end

  it "does not claim agreement when there was nothing to compare" do
    # "every endpoint both projects captured answers the same way" is a claim about
    # endpoints that were COMPARED. Over zero rows it is the count-of-zero lie the
    # removed/gone split exists to prevent.
    v = DiffView.new
    v.set_slot(:a, Gori::Project.new("q1", "/tmp/q1.db"))
    v.set_slot(:b, Gori::Project.new("q3", "/tmp/q3.db"))
    v.report = diff_report([] of Gori::Diff::Row)
    render_rows(v).join("\n").should contain("neither side captured anything to diff")
  end

  it "keeps its header inside the pane on a terminal too short for it" do
    # `Screen#text` clips to the SCREEN, not to the rect — so a two-row body would paint
    # its summary and caveat over the frame and the sub-tab strip below.
    v = loaded_view
    backend = MemoryBackend.new(100, 10)
    v.render(Screen.new(backend), Rect.new(0, 2, 100, 2), focused: true)
    (0...10).each do |y|
      next if y == 2 || y == 3
      backend.row(y).strip.should eq("") # nothing painted outside the two-row pane
    end
  end

  it "tells the operator what to do before a baseline is picked" do
    v = DiffView.new
    v.set_slot(:b, Gori::Project.new("q3", "/tmp/q3.db"))
    v.ready?.should be_false
    render_rows(v).join("\n").should contain("pick the BASELINE project")
  end

  it "drops the report when either slot changes — half a new pair is not a report" do
    v = loaded_view
    v.set_slot(:a, Gori::Project.new("q0", "/tmp/q0.db"))
    v.report.should be_nil
    v.rows.should be_empty
  end

  it "surfaces a read failure instead of an empty diff" do
    v = loaded_view
    v.error = "cannot open /tmp/q1.db: not a valid SQLite database"
    render_rows(v).join("\n").should contain("not a valid SQLite database")
  end
end
