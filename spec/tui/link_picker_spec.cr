require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# LinkPicker is the merge of the old IssuePicker + NotePicker: ONE card holding both owner
# kinds and both create rows, so "attach this evidence" stopped being a choice of verb made
# before you can see what exists. The examples below carry the two off-by-ones that merge
# introduces — two pinned rows instead of one, and a kind that must survive the filter —
# because getting either wrong links the operator's evidence to the WRONG owner silently.
private def issue_row(id : Int64, title : String, host : String = "app.test") : LinkPicker::Row
  LinkPicker::Row.new(Gori::Store::LinkOwnerKind::Issue, id, "##{id} [high] #{title}", title,
    "#{host} · open")
end

private def note_row(id : Int64, n : Int32, title : String, detail : String) : LinkPicker::Row
  LinkPicker::Row.new(Gori::Store::LinkOwnerKind::Note, id, "#{n}:#{title}", title, detail)
end

private def sample_picker : LinkPicker
  LinkPicker.new([
    issue_row(1_i64, "Reflected XSS"),
    issue_row(2_i64, "SQL injection", "api.test"),
    note_row(10_i64, 1, "Auth flow", "token reuse"),
    note_row(11_i64, 2, "Recon", "subdomains"),
  ])
end

describe Gori::Tui::LinkPicker do
  it "pins BOTH create rows above the list and defaults onto the first real owner" do
    p = sample_picker
    p.selected.should eq(2) # 0 = new issue, 1 = new note
    p.selected_create.should be_nil
    p.selected_row.try(&.id).should eq(1_i64)
    p.entry_count.should eq(6) # 2 create + 4 owners
  end

  it "names WHICH create row the cursor is on — the two are different hand-offs" do
    p = sample_picker
    p.move(-2)
    p.selected_create.should eq(Gori::Store::LinkOwnerKind::Issue)
    p.move(1)
    p.selected_create.should eq(Gori::Store::LinkOwnerKind::Note)
    p.move(1)
    p.selected_create.should be_nil
  end

  it "never resolves a create row to an owner (Array#[]? counts backwards from the end)" do
    # @selected - CREATE_ROWS is -2 / -1 on the create rows, and `@filtered[-1]?` is the
    # LAST owner, not nil. Unguarded, ↵ on "+ New issue…" would link to a random note.
    p = sample_picker
    p.set_selected(0)
    p.selected_row.should be_nil
    p.set_selected(1)
    p.selected_row.should be_nil
  end

  it "selects create when the project has neither issues nor notes" do
    p = LinkPicker.new([] of LinkPicker::Row)
    p.selected.should eq(0)
    p.selected_create.should eq(Gori::Store::LinkOwnerKind::Issue)
    p.selected_row.should be_nil
    p.entry_count.should eq(2)
  end

  it "carries both kinds on one list, in issues-then-notes order" do
    p = sample_picker
    kinds = [] of Gori::Store::LinkOwnerKind
    (2...p.entry_count).each do |i|
      p.set_selected(i)
      kinds << p.selected_row.not_nil!.kind
    end
    kinds.should eq([Gori::Store::LinkOwnerKind::Issue, Gori::Store::LinkOwnerKind::Issue,
                     Gori::Store::LinkOwnerKind::Note, Gori::Store::LinkOwnerKind::Note])
  end

  it "filters on the kind word, so `note` narrows to notes without leaving the card" do
    p = sample_picker
    "note".each_char { |c| p.query_char(c) }
    p.entry_count.should eq(4) # 2 create + 2 notes
    p.selected_row.try(&.kind).should eq(Gori::Store::LinkOwnerKind::Note)
    p.selected_row.try(&.id).should eq(10_i64)
  end

  it "filters on the detail column too (an issue's host, a note's first line)" do
    p = sample_picker
    "api.test".each_char { |c| p.query_char(c) }
    p.entry_count.should eq(3)
    p.selected_row.try(&.id).should eq(2_i64)

    q = sample_picker
    "subdomains".each_char { |c| q.query_char(c) }
    q.selected_row.try(&.id).should eq(11_i64)
  end

  it "keeps both create rows pinned while filtering, and lands on create when nothing matches" do
    p = sample_picker
    "zzz".each_char { |c| p.query_char(c) }
    p.entry_count.should eq(2) # create rows survive ANY query — that is the point
    p.selected_create.should eq(Gori::Store::LinkOwnerKind::Issue)
    p.selected_row.should be_nil
    # The typed text is what the Runner seeds the new issue's title with.
    p.query.should eq("zzz")
  end

  it "restores the list on backspace with the selection back on the first owner" do
    p = sample_picker
    "sql".each_char { |c| p.query_char(c) }
    3.times { p.backspace }
    p.selected.should eq(2)
    p.selected_row.try(&.id).should eq(1_i64)
  end

  it "renders both create rows, and the kind badge in the same run as its own label" do
    # The badge is the ONLY thing telling the two owner kinds apart on the card, so it has
    # to be pinned against the row it belongs to. A bare contains?("issue") would not: the
    # pinned "+ New issue…" label satisfies that even with draw_row's badge deleted.
    backend = MemoryBackend.new(100, 30)
    sample_picker.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("LINK TO").should be_true
    backend.contains?("+ New issue…").should be_true
    backend.contains?("+ New note…").should be_true
    backend.contains?("issue #1 [high] Reflected XSS").should be_true
    backend.contains?("note  1:Auth flow").should be_true
  end

  it "draws the detail in its own reserved column, so a long title cannot swallow it" do
    # Label-then-whatever-is-left dropped the host/status entirely on exactly the titles
    # that need disambiguating. The column is reserved, so both survive.
    long = "Reflected XSS in the password-reset confirmation endpoint handler"
    backend = MemoryBackend.new(100, 30)
    LinkPicker.new([issue_row(7_i64, long, "shop.test"),
                    note_row(10_i64, 1, "Auth flow", "token reuse")])
      .render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("shop.test · open").should be_true
    backend.contains?("token reuse").should be_true
    backend.contains?("#7 [high] Reflected XSS in").should be_true # label truncated, not gone
  end
end

# --- Overlay seam (issue #355, batch C4) ------------------------------------------
describe "LinkPicker — Overlay contract" do
  it "carries the chrome the Runner's ladder arms used to hard-code" do
    OverlayHarness.new(sample_picker).assert_chrome(OverlayKind::LinkPick, "LINK TO")
    # ONE hint, on the card and on the shell's bottom row: once it names the row under the
    # cursor there is nothing a separate "link / create" phrasing could add (#1038).
    sample_picker.hint.should eq("type to filter · ↑/↓ select · ↵ link · esc cancel")
    OverlayHarness.new(sample_picker).rendered?("↵ link · esc cancel").should be_true
  end

  it "keeps the two pinned create rows out of the filtered count (the off-by-two)" do
    ov = sample_picker
    OverlayHarness.new(ov).type("sql")
    ov.entry_count.should eq(3) # both create rows plus the one match
    ov.selected.should eq(2)
    ov.selected_create.should be_nil
    ov.selected_row.try(&.id).should eq(2_i64)
    ov.move(-1)
    ov.selected_create.should eq(Gori::Store::LinkOwnerKind::Note)
    ov.selected_row.should be_nil
  end

  it "↵ on an existing owner commits it to the injected closure, kind and all" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    linked = [] of {Gori::Store::LinkOwnerKind, Int64}
    h.on_commit { r = ov.selected_row.not_nil!; linked << {r.kind, r.id}; true }
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    linked.should eq([{Gori::Store::LinkOwnerKind::Issue, 1_i64}])

    note = sample_picker
    hn = OverlayHarness.new(note)
    note.set_selected(5) # 2 create rows + the 4th owner — the second note
    picked = [] of {Gori::Store::LinkOwnerKind, Int64}
    hn.on_commit { r = note.selected_row.not_nil!; picked << {r.kind, r.id}; true }
    hn.press(Termisu::Input::Key::Enter).should eq(:closed)
    picked.should eq([{Gori::Store::LinkOwnerKind::Note, 11_i64}])
  end

  it "↵ on a create row is still a plain :commit — the closure decides what create means" do
    # Runner#link_picked answers that :commit by arming on_close (the NEW ISSUE form, or the
    # blank-note + open-vs-stay confirm) and reporting TRUE so the shell drops this card
    # first; on_close then puts the next modal up. The overlay must not special-case either
    # create row — it only reports WHICH one.
    ov = LinkPicker.new([] of LinkPicker::Row)
    h = OverlayHarness.new(ov)
    created = [] of Gori::Store::LinkOwnerKind
    h.on_commit { ov.selected_create.try { |k| created << k }; true }
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    created.should eq([Gori::Store::LinkOwnerKind::Issue])

    note = LinkPicker.new([] of LinkPicker::Row)
    note.move(1)
    hn = OverlayHarness.new(note)
    picked = [] of Gori::Store::LinkOwnerKind
    hn.on_commit { note.selected_create.try { |k| picked << k }; true }
    hn.press(Termisu::Input::Key::Enter).should eq(:closed)
    picked.should eq([Gori::Store::LinkOwnerKind::Note])
  end

  it "esc cancels; a row click commits; a click away dismisses" do
    esc = OverlayHarness.new(sample_picker)
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)

    ov = sample_picker
    click = OverlayHarness.new(ov)
    click.click_in_box(3, 4).should eq(:closed) # list starts at box.y + 3 → second row
    ov.selected.should eq(1)
    ov.selected_create.should eq(Gori::Store::LinkOwnerKind::Note)
    click.commits.should eq(1)

    away = OverlayHarness.new(sample_picker)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
  end

  # ONE card now (#1038) — the LINK & FREEZE mode is gone, along with its title, its single
  # create row and its two hint constants. ↵ freezes by default where it can, so what the
  # card owes the operator is a hint that says what ↵ will do to the row UNDER THE CURSOR:
  # an issue can own the bytes, a note cannot, and a create row makes the owner first.
  it "moves the ↵ hint with the cursor when the refs carry an exchange" do
    p = LinkPicker.new([
      issue_row(1_i64, "Reflected XSS"),
      note_row(10_i64, 1, "Auth flow", "token reuse"),
    ], freezable: true)
    p.freezable?.should be_true
    p.title.should eq("LINK TO") # one title, whatever ↵ ends up doing
    p.create_rows.should eq(2)   # and both create rows, because a note is still a destination

    p.set_selected(0)
    p.enter_action.should eq("create & freeze")
    p.hint.should eq("type to filter · ↑/↓ select · ↵ create & freeze · esc cancel")
    p.set_selected(1) # + New note…
    p.enter_action.should eq("create")
    p.set_selected(2) # the issue
    p.enter_action.should eq("link & freeze")
    p.set_selected(3) # the note — a note owns no evidence
    p.enter_action.should eq("link")

    h = OverlayHarness.new(p)
    h.rendered?("+ New issue…").should be_true
    h.rendered?("+ New note…").should be_true
    h.rendered?("↵ link").should be_true
  end

  it "never promises a freeze when no ref has an exchange to copy" do
    # A fuzz/miner session, a pending flow, a never-sent Repeater tab: the link is still the
    # act, so the card opens — it must simply not say "& freeze" about bytes that do not exist.
    p = LinkPicker.new([issue_row(1_i64, "Reflected XSS")])
    p.freezable?.should be_false
    p.set_selected(0)
    p.enter_action.should eq("create")
    p.set_selected(2)
    p.enter_action.should eq("link")
    p.hint.should eq("type to filter · ↑/↓ select · ↵ link · esc cancel")

    # An empty project has no row under the cursor at all; the hint must still render.
    LinkPicker.new([] of LinkPicker::Row, freezable: true).hint.should contain("↵ create & freeze")
  end
end
