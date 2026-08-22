require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The two halves of a named GLOBAL library — NamePromptOverlay writes, LibraryPicker reads.
# One pair serves the Decoder's chain specs and the Rewriter's rule presets.
#
# These replaced per-tab inline mini-prompts that opened EMPTY and could only be driven by
# typing a remembered name, so the examples below are mostly about the two things the
# prompts could not do: seed a default, and SHOW what has been saved.
describe Gori::Tui::NamePromptOverlay do
  it "supplies the chrome the shell's collapsed title/hint ladders read" do
    ov = NamePromptOverlay.new("SAVE CHAIN", "base64-decode > gunzip", "peel")
    OverlayHarness.new(ov).assert_chrome(OverlayKind::NamePrompt, "SAVE CHAIN")
  end

  it "opens seeded with the default name, caret at the end so typing appends" do
    ov = NamePromptOverlay.new("SAVE CHAIN", "hex-encode", "myhash")
    h = OverlayHarness.new(ov)
    ov.name.should eq("myhash")
    h.rendered?("myhash").should be_true
    h.type("2")
    ov.name.should eq("myhash2")
  end

  it "renders the subject so the card says WHAT is being named" do
    h = OverlayHarness.new(NamePromptOverlay.new("SAVE CHAIN", "base64-decode > gunzip", ""))
    h.rendered?("base64-decode > gunzip").should be_true
  end

  # A rule stub's `replacement` is a whole HTTP response; the subject is one row, and a raw
  # newline in it would push the field and hint rows out from under the border.
  it "collapses a multi-line subject onto its single row" do
    h = OverlayHarness.new(NamePromptOverlay.new("SAVE RULE", "200 OK\nX: 1\n\nbody", ""))
    # A RUN of newlines collapses to ONE space (`[\r\n\t]+`), so the blank line before the
    # body does not survive as a double gap — same as ChainOverlay's preview rows.
    h.rendered?("200 OK X: 1 body").should be_true
  end

  it "↵ commits the typed name and esc cancels without committing" do
    ov = NamePromptOverlay.new("SAVE CHAIN", "hex", "")
    h = OverlayHarness.new(ov)
    h.type("nightly")
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
    ov.name.should eq("nightly")

    h2 = OverlayHarness.new(NamePromptOverlay.new("SAVE CHAIN", "hex", "seed"))
    h2.press(Termisu::Input::Key::Escape).should eq(:closed)
    h2.commits.should eq(0)
  end

  # Blank passes THROUGH on purpose — only the open-site knows what is being named, so it
  # owns the "a name is required" message (DecoderController#save_chain and
  # RewriterController#save_rule_preset both refuse it there).
  it "commits a blank name rather than validating it here" do
    ov = NamePromptOverlay.new("SAVE CHAIN", "hex", "")
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
    ov.name.should be_empty
  end

  it "strips surrounding whitespace off the committed name" do
    ov = NamePromptOverlay.new("SAVE CHAIN", "hex", "  padded  ")
    ov.name.should eq("padded")
  end
end

describe Gori::Tui::LibraryPicker do
  private_rows = [
    LibraryPicker::Row.new(0, "peel", "base64-decode > gunzip"),
    LibraryPicker::Row.new(1, "hash", "sha256"),
    LibraryPicker::Row.new(2, "urlx", "url-decode > url-decode"),
  ]

  it "supplies the chrome the shell's collapsed title/hint ladders read" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    OverlayHarness.new(lp).assert_chrome(OverlayKind::LibraryPick, "LOAD CHAIN")
  end

  # THE point of the card: the old prompt could only be driven by a name you already
  # remembered, so a saved chain you had forgotten was unreachable from the UI.
  it "lists every entry with its spec beside the name" do
    h = OverlayHarness.new(LibraryPicker.new("LOAD CHAIN", private_rows, "chain"))
    mb = h.render
    mb.contains?("peel").should be_true
    mb.contains?("base64-decode > gunzip").should be_true
    mb.contains?("hash").should be_true
    mb.contains?("sha256").should be_true
  end

  it "filters on the name AND on the spec, and hands back the library index" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    h = OverlayHarness.new(lp)
    h.type("gunzip") # matches `peel` only through its SPEC
    lp.entry_count.should eq(1)
    lp.selected_index.should eq(0)
    h.rendered?("hash").should be_false
  end

  it "↑/↓ move the cursor and ↵ commits the highlighted row" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    h = OverlayHarness.new(lp)
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::Down)
    lp.selected_index.should eq(2)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
  end

  it "a row click selects and picks it in one gesture" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    h = OverlayHarness.new(lp)
    h.click_in_box(3, FilterPickerOverlay::LIST_OFFSET + 1).should eq(:closed)
    lp.selected_index.should eq(1)
    h.commits.should eq(1)
  end

  # An empty LIBRARY and an empty FILTER are different dead ends with different exits, so
  # they never share a message — and the empty-library one names which library it is.
  it "distinguishes an empty library from a filter that matched nothing" do
    empty = OverlayHarness.new(LibraryPicker.new("LOAD CHAIN", [] of LibraryPicker::Row, "chain"))
    empty.rendered?("no saved chain yet").should be_true

    h = OverlayHarness.new(LibraryPicker.new("LOAD CHAIN", private_rows, "chain"))
    h.type("zzz")
    h.rendered?("no saved chain matches").should be_true
  end

  # selected_index is nil, so the open-site's `if (i = lp.selected_index)` guard is what
  # keeps ↵ on an empty library from loading a neighbour.
  it "reports no selection when nothing matches" do
    lp = LibraryPicker.new("LOAD CHAIN", [] of LibraryPicker::Row, "chain")
    lp.selected_index.should be_nil
  end

  it "names the ↵ verb the open-site chose, in the hint" do
    LibraryPicker.new("LOAD RULE", private_rows, "rule", action: "add").hint.should contain("↵ add")
    LibraryPicker.new("LOAD CHAIN", private_rows, "chain").hint.should contain("↵ load")
  end

  # ^X, not a bare `d`: every printable key belongs to the filter here, so a letter cannot
  # be an action. ^C/^D never reach a modal (the shell's quit-arm claims them first).
  it "^X hands the highlighted entry's library index to on_delete and stays open" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    deleted = [] of Int32
    lp.on_delete = ->(i : Int32) { deleted << i; nil }
    h = OverlayHarness.new(lp)
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true).should eq(:open)
    deleted.should eq([1])
    h.commits.should eq(0) # deleting is not loading
  end

  # The index is the LIBRARY position, not the filtered-row position — off-by-one here
  # deletes a neighbour, silently and unrecoverably.
  it "^X reports the library index even when a filter has narrowed the list" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    deleted = [] of Int32
    lp.on_delete = ->(i : Int32) { deleted << i; nil }
    h = OverlayHarness.new(lp)
    h.type("urlx")
    lp.entry_count.should eq(1)
    h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true)
    deleted.should eq([2])
  end

  # ^E (#776) — the History view picker's "edit this one", which for a view means loading its
  # query back into the filter bar. `:cancel`, not `:commit`: editing an entry is not also
  # picking it, and `:commit` would have run `on_commit` on the way out.
  it "^E hands the highlighted entry's library index to on_edit and takes the card down" do
    lp = LibraryPicker.new("HISTORY VIEW", private_rows, "view", action: "activate")
    edited = [] of Int32
    lp.on_edit = ->(i : Int32) { edited << i; nil }
    h = OverlayHarness.new(lp)
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::LowerE, 'e', ctrl: true).should eq(:closed)
    edited.should eq([1])
    h.commits.should eq(0) # editing is not picking
  end

  it "^E is inert, and unadvertised, on a library with no editor wired" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    lp.hint.should_not contain("^E")
    OverlayHarness.new(lp).press(Termisu::Input::Key::LowerE, 'e', ctrl: true).should eq(:open)

    with_edit = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    with_edit.on_edit = ->(_i : Int32) { nil }
    with_edit.hint.should contain("^E edit")
  end

  # A SENTINEL row — the view picker's `+ Save current filter…` carries -1 so it can never
  # collide with a position in the library array — reaches the hook as -1, and must. Crystal's
  # `Array#[]?` WRAPS a negative index (`views[-1]?` is the LAST view), so the open-site's guard
  # is the only thing between this and ^E silently editing an unrelated entry. Pinned here
  # because the picker is where the contract lives.
  it "^E and ^X pass a sentinel row's negative index through rather than clamping it" do
    rows = private_rows + [LibraryPicker::Row.new(-1, "+ Save current filter…", "status:200")]
    lp = LibraryPicker.new("HISTORY VIEW", rows, "view", action: "activate")
    seen = [] of Int32
    lp.on_edit = ->(i : Int32) { seen << i; nil }
    lp.on_delete = ->(i : Int32) { seen << i; nil }
    h = OverlayHarness.new(lp)
    3.times { h.press(Termisu::Input::Key::Down) }
    lp.selected_index.should eq(-1)
    h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true)
    seen.should eq([-1])

    # ^E takes the card down, so it needs its own picker to answer on.
    lp2 = LibraryPicker.new("HISTORY VIEW", rows, "view", action: "activate")
    edited = [] of Int32
    lp2.on_edit = ->(i : Int32) { edited << i; nil }
    h2 = OverlayHarness.new(lp2)
    3.times { h2.press(Termisu::Input::Key::Down) }
    h2.press(Termisu::Input::Key::LowerE, 'e', ctrl: true)
    edited.should eq([-1])
  end

  it "does not type ^E into the filter query" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    lp.on_edit = ->(_i : Int32) { nil }
    h = OverlayHarness.new(lp)
    h.press(Termisu::Input::Key::LowerE, 'e', ctrl: true)
    lp.entry_count.should eq(3) # an 'e' in the query would have narrowed to peel/urlx
  end

  it "^X is inert, and unadvertised, on a library with no deleter wired" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    lp.hint.should_not contain("^X")
    h = OverlayHarness.new(lp)
    h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true).should eq(:open)

    with_del = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    with_del.on_delete = ->(_i : Int32) { nil }
    with_del.hint.should contain("^X delete")
  end

  # ^X must not leak into the filter: the base FilterPickerOverlay routes printables to
  # `query_char`, and 'x' arrives WITH its char attached even under ctrl.
  it "does not type ^X into the filter query" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    lp.on_delete = ->(_i : Int32) { nil }
    h = OverlayHarness.new(lp)
    h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true)
    lp.entry_count.should eq(3) # an 'x' in the query would have narrowed to `urlx`
  end

  # The open-site refreshes the card in place after a delete. The query survives (the
  # operator filtered their way here) and the cursor holds its slot, so a second ^X takes
  # the next entry instead of jumping back to the top.
  it "set_rows keeps the filter and the cursor position" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    h = OverlayHarness.new(lp)
    h.type("a") # peel(gunzip)/hash — `urlx` has no 'a' in name or detail
    lp.entry_count.should eq(2)
    h.press(Termisu::Input::Key::Down)
    lp.selected.should eq(1)

    remaining = [
      LibraryPicker::Row.new(0, "peel", "base64-decode > gunzip"),
      LibraryPicker::Row.new(1, "urlx", "url-decode > url-decode"),
    ]
    lp.set_rows(remaining)
    lp.entry_count.should eq(1) # the filter still applies — only `peel` matches "a"
    lp.selected.should eq(0)    # clamped onto what is left
    lp.selected_index.should eq(0)
  end

  it "set_rows on an emptied library falls back to the empty-library message" do
    lp = LibraryPicker.new("LOAD CHAIN", private_rows, "chain")
    h = OverlayHarness.new(lp)
    lp.set_rows([] of LibraryPicker::Row)
    lp.selected_index.should be_nil
    h.rendered?("no saved chain yet").should be_true
  end

  # A short-circuit preset's summary carries the stub body, newlines and all; one entry must
  # stay exactly one row or every row below it shifts.
  it "collapses a multi-line detail onto its row" do
    rows = [LibraryPicker::Row.new(0, "stub", "stub  /admin ⇥ 200 OK\nX: 1")]
    h = OverlayHarness.new(LibraryPicker.new("LOAD RULE", rows, "rule"))
    h.rendered?("200 OK X: 1").should be_true
  end
end
