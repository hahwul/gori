require "../spec_helper"
require "../support/memory_backend"

private def rules_store(&)
  path = File.tempname("gori-rulesview", ".db")
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

# Walk every selectable row via the view's own navigation and return them, so a test can find a
# rule row without reaching into private state.
private def all_rows(view : Gori::Tui::ProbeRulesView) : Array(Gori::Tui::ProbeRulesView::Row)
  view.move(-1000) # to the top
  rows = [] of Gori::Tui::ProbeRulesView::Row
  seen = Set(Int32).new
  loop do
    idx = view.selected_index
    break if seen.includes?(idx)
    seen << idx
    view.selected_row.try { |r| rows << r }
    view.move(1)
  end
  rows
end

private def find_row(view, title : String)
  all_rows(view).find { |r| r.title == title }
end

describe Gori::Tui::ProbeRulesView do
  it "badges the out-of-band rule 'needs OAST' until a listener exists" do
    rules_store do |store|
      view = Gori::Tui::ProbeRulesView.new
      view.reload(store)
      row = find_row(view, "Blind SSRF (out-of-band)").not_nil!
      row.enabled?.should be_true # ships enabled — nothing to opt into
      row.note.should eq("needs OAST")

      # Register a session → the badge clears (the rule can now actually mint).
      store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr", "sec", nil, nil)
      view.reload(store)
      find_row(view, "Blind SSRF (out-of-band)").not_nil!.note.should eq("")
    end
  end

  it "badges the default-off rule 'opt-in'" do
    rules_store do |store|
      view = Gori::Tui::ProbeRulesView.new
      view.reload(store)
      row = find_row(view, "HTTP request smuggling / desync (CL.TE/TE.CL/TE.TE)").not_nil!
      row.enabled?.should be_false
      row.note.should eq("opt-in")
    end
  end

  it "carries each rule's description for the footer" do
    rules_store do |store|
      view = Gori::Tui::ProbeRulesView.new
      view.reload(store)
      find_row(view, "Open redirect").not_nil!.desc.should_not be_empty
    end
  end

  it "sums the enabled active request cost in the ACTIVE header, excluding OAST until ready" do
    rules_store do |store|
      view = Gori::Tui::ProbeRulesView.new
      view.reload(store)
      backend = MemoryBackend.new(80, 40)
      view.render(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, 80, 40), true)
      active_hdr = (0...40).map { |y| backend.row(y) }.find { |line| line.includes?("ACTIVE RULES") }.not_nil!
      active_hdr.should contain("req/flow enabled")
    end
  end

  it "shows the selected rule's description in the footer" do
    rules_store do |store|
      view = Gori::Tui::ProbeRulesView.new
      view.reload(store)
      view.move(-1000) # top: first passive rule
      backend = MemoryBackend.new(80, 20)
      view.render(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, 80, 20), true)
      footer = backend.row(19)
      sel = view.selected_row.not_nil!
      footer.strip.should_not be_empty
      # the footer shows THIS rule's description (its leading words)
      footer.should contain(sel.desc[0, 12])
    end
  end
end
