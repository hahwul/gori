require "../spec_helper"

include Gori::Tui

# Multi-select on the project picker. The picker itself holds a live Termisu and can't be
# built here, which is exactly why the rule that decides WHICH project directories a
# confirmed delete wipes lives in ProjectMarks and in ProjectPicker's class methods — the
# sentence the operator reads before an `rm_rf`, and the set it is about, are pinned here.
describe Gori::Tui::ProjectMarks do
  # Three saved projects, as the picker keys them: on the directory slug, which is unique
  # and survives a rename.
  dirs = ["/p/alpha", "/p/beta", "/p/gamma"]

  it "toggles a mark on and back off" do
    m = ProjectMarks.new
    m.empty?.should be_true
    m.toggle(dirs[1])
    m.marked?(dirs[1]).should be_true
    m.size.should eq(1)
    m.toggle(dirs[1])
    m.marked?(dirs[1]).should be_false
    m.empty?.should be_true
  end

  it "marks every filtered project, unioning with what is already marked" do
    m = ProjectMarks.new
    m.toggle(dirs[2])
    m.mark_all(["/p/alpha", "/p/beta"]) # a narrowed search
    m.size.should eq(3)
    dirs.each { |d| m.marked?(d).should be_true }
  end

  it "clears everything on esc" do
    m = ProjectMarks.new
    m.mark_all(dirs)
    m.clear
    m.empty?.should be_true
  end

  describe "#extend" do
    it "marks the contiguous range from the anchor and returns the new cursor" do
      m = ProjectMarks.new
      m.extend(dirs, 0, 1).should eq(1) # ⇧↓ from the first row
      m.marked?(dirs[0]).should be_true # the anchor row is in the range
      m.marked?(dirs[1]).should be_true
      m.marked?(dirs[2]).should be_false
    end

    it "hands back what the gesture no longer covers, so ⇧↓⇧↓⇧↑ leaves two rows" do
      m = ProjectMarks.new
      cur = m.extend(dirs, 0, 1)
      cur = m.extend(dirs, cur, 1)
      m.size.should eq(3)
      cur = m.extend(dirs, cur, -1)
      cur.should eq(1)
      m.size.should eq(2)
      m.marked?(dirs[2]).should be_false
    end

    it "leaves a Tab mark alone when a range sweeps over it and back off" do
      m = ProjectMarks.new
      m.toggle(dirs[2]) # deliberate mark on the last row
      # …then walk away from it, or the range below would anchor ON gamma (toggle re-anchors)
      # and could never retreat past it — the assertion would hold no matter what @extent did.
      m.end_gesture
      cur = m.extend(dirs, 0, 1)
      cur = m.extend(dirs, cur, 1) # range now covers the Tab mark too
      m.extend(dirs, cur, -1)      # …and retreats off it
      m.marked?(dirs[2]).should be_true
      m.size.should eq(3) # gamma (deliberate) + alpha, beta (the range that stayed)
    end

    it "clamps at both ends instead of wrapping" do
      m = ProjectMarks.new
      m.extend(dirs, 0, -1).should eq(0)
      m.extend(dirs, 2, 1).should eq(2)
    end

    it "re-anchors at the cursor when the anchor fell out of the filter" do
      m = ProjectMarks.new
      m.toggle(dirs[0]) # anchors on alpha
      visible = ["/p/beta", "/p/gamma"]
      m.extend(visible, 0, 1) # alpha is gone from the list — anchor at beta
      m.marked?("/p/beta").should be_true
      m.marked?("/p/gamma").should be_true
    end
  end

  describe "#end_gesture" do
    it "gives back a range when a plain arrow ends it, and reports how many" do
      m = ProjectMarks.new
      m.extend(dirs, 0, 1)
      m.end_gesture.should eq(2)
      m.empty?.should be_true
    end

    it "keeps deliberate Tab marks — only the gesture's own rows go" do
      m = ProjectMarks.new
      m.toggle(dirs[0]) # Tab
      m.extend(dirs, 1, 1)
      m.size.should eq(3)
      m.end_gesture.should eq(2)
      m.marked?(dirs[0]).should be_true
      m.size.should eq(1)
    end

    it "re-anchors, so the next ⇧arrow starts from the cursor rather than a stale row" do
      m = ProjectMarks.new
      m.extend(dirs, 0, 1) # anchor at alpha
      m.end_gesture
      m.extend(dirs, 2, -1) # ⇧↑ from gamma: anchors there, not back at alpha
      m.marked?(dirs[0]).should be_false
      m.marked?(dirs[1]).should be_true
      m.marked?(dirs[2]).should be_true
    end
  end

  it "unmarks only what a partial delete actually removed" do
    m = ProjectMarks.new
    m.mark_all(dirs)
    m.unmark(["/p/alpha"]) # beta refused (in use), gamma refused
    m.marked?("/p/alpha").should be_false
    m.size.should eq(2)
  end

  # An UNMARKED row that is still on the list is a perfectly good place for the next ⇧arrow
  # to measure from — only the anchor's own removal invalidates it. (Tab twice to land the
  # anchor on a row that carries no mark; a rule keyed on "is the anchor still marked?"
  # instead of "did the anchor go?" drops it here for no reason.)
  it "keeps the range anchor when the delete took some other project" do
    m = ProjectMarks.new
    m.toggle(dirs[0]) # mark alpha, anchor alpha
    m.toggle(dirs[0]) # unmark it — the anchor stays on alpha
    m.unmark(["/p/gamma"])
    m.extend(dirs, 2, -1) # ⇧↑ from gamma still measures from the alpha anchor: 0..1
    m.marked?("/p/beta").should be_true
    # A dropped anchor would have re-seeded at the cursor (gamma) and swept 1..2 instead.
    m.marked?("/p/gamma").should be_false
  end

  it "drops marks whose project a peer deleted out from under us" do
    m = ProjectMarks.new
    m.mark_all(dirs)
    m.retain(["/p/alpha", "/p/beta"])
    m.size.should eq(2)
    m.marked?("/p/gamma").should be_false
  end

  describe "marks the filter is hiding" do
    it "counts them" do
      m = ProjectMarks.new
      m.mark_all(dirs)
      m.hidden_count(["/p/beta"]).should eq(2)
      m.hidden_count(dirs).should eq(0)
      ProjectMarks.new.hidden_count(dirs).should eq(0)
    end

    it "still hands them to a batch verb, visible ones first in display order" do
      m = ProjectMarks.new
      m.mark_all(dirs)
      m.ordered(["/p/gamma", "/p/beta"]).should eq(["/p/gamma", "/p/beta", "/p/alpha"])
    end
  end
end

describe Gori::Tui::ProjectPicker do
  describe ".space_entries" do
    it "offers single-project archive actions when nothing is marked" do
      ProjectPicker.space_entries(0).map(&.label).should eq([
        "Open", "Rename", "Compress", "Export (cursor)", "Import archive", "Delete",
      ])
    end

    # The AC of a batch menu: a delete opened over 3 marks must say it is about 3, and the
    # single-target verbs must say they are not.
    it "says what Delete will take, and marks the others cursor-only" do
      labels = ProjectPicker.space_entries(3).map(&.label)
      labels.should eq([
        "Open (cursor)", "Rename (cursor)", "Compress (cursor)", "Export (cursor)",
        "Delete 3 projects", "Import archive", "Clear marks",
      ])
    end

    it "keeps the mnemonics for archive actions and marks clear distinct" do
      ProjectPicker.space_entries(2).map(&.key).should eq(['o', 'r', 'c', 'e', 'd', 'i', 'n'])
      ProjectPicker.space_entries(2).map(&.action).should eq([
        :open, :rename, :compress, :archive_export, :delete, :archive_import, :mark_clear,
      ])
    end

    it "offers import from the empty picker search row" do
      ProjectPicker::IMPORT_ONLY_ENTRIES.map(&.action).should eq([:archive_import])
    end

    it "does not pluralise a single mark" do
      ProjectPicker.space_entries(1).map(&.label).should contain("Delete 1 project")
    end
  end

  describe ".space_menu_box" do
    # Frame.card ellipsizes a title past `w - 4`. The real menu's labels happen to be wide
    # enough today, so this drives the rule itself with short ones: the box is sized off the
    # title too, or a menu that grew a shorter verb would silently truncate the "· 3 MARKED"
    # count that is the whole reason it looks different.
    it "is sized to fit the banner even when every label is shorter than it" do
      short = [ProjectPicker::SpaceEntry.new('d', "Delete", :delete)]
      title = "SPACE · 12 MARKED"
      box = ProjectPicker.space_menu_box(120, 40, short, title)
      (box.w - 4).should be >= Screen.display_width(title)
    end

    it "fits the marked menu it actually draws" do
      entries = ProjectPicker.space_entries(3)
      title = "SPACE · 3 MARKED"
      box = ProjectPicker.space_menu_box(120, 40, entries, title)
      (box.w - 4).should be >= Screen.display_width(title)
      (box.w - 6).should be >= entries.max_of { |e| Screen.display_width(e.label) }
      box.h.should eq(entries.size + 2)
    end

    # A narrow terminal must clamp rather than draw a card off the right edge.
    it "never exceeds the terminal it is drawn on" do
      entries = ProjectPicker.space_entries(3)
      ProjectPicker.space_menu_box(30, 20, entries, "SPACE · 3 MARKED").w.should be <= 30
      ProjectPicker.space_menu_box(20, 12, entries, "SPACE · 3 MARKED").w.should be <= 20
    end
  end

  describe ".delete_confirm_body" do
    it "quotes the one project by name" do
      body = ProjectPicker.delete_confirm_body(["shop"], 0, 0)
      body.should eq(%(Delete "shop"?\nThis permanently removes all of its captured data.))
    end

    it "names a small batch, so 'delete' is never a count with no referent" do
      body = ProjectPicker.delete_confirm_body(["shop", "api"], 0, 0)
      body.lines.first.should eq(%(Delete "shop", "api"?))
      body.should contain("all of their captured data")
    end

    it "falls back to the count once there are more names than it lists" do
      ProjectPicker.delete_confirm_body(["a", "b", "c", "d"], 0, 0).lines.first.should eq("Delete 4 projects?")
    end

    # THE reason the fallback is by width and not by count alone: ConfirmDialog caps its card
    # at 60 columns and draws each line at `box.w - 6`, so a longer head is ELLIPSIZED — and
    # a truncated head on THIS dialog means confirming an irreversible wipe having read
    # `Delete "acme-staging-01", "acme-stagi…`, with a project and the "?" cut off.
    it "falls back to the count when three names would be ellipsized" do
      names = ["acme-staging-01", "acme-staging-02", "acme-staging-03"]
      ProjectPicker.delete_confirm_body(names, 0, 0).lines.first.should eq("Delete 3 projects?")
      # …and every line it does emit fits the dialog's text column.
      ProjectPicker.delete_confirm_body(names, 2, 1).each_line do |line|
        Screen.display_width(line).should be <= ProjectPicker::NAMED_DELETE_WIDTH
      end
    end

    # The head names one project whatever it costs — "Delete 1 project?" names nothing, and a
    # long single name is ellipsized the same way its list row is.
    it "always names a single project" do
      ProjectPicker.delete_confirm_body(["a-very-long-project-name-that-will-not-fit-in-the-card"], 0, 0)
        .lines.first.should start_with(%(Delete "a-very-long))
    end

    it "keeps the hidden line singular when there is one project" do
      body = ProjectPicker.delete_confirm_body(["shop"], 1, 0)
      body.should contain("It is hidden by the current search.")
      body.should_not contain("them")
    end

    # The one thing the list itself cannot show: marks survive the fuzzy filter, so a set
    # assembled across two searches reaches projects that are not on screen.
    it "spells out the marks the current search is hiding" do
      body = ProjectPicker.delete_confirm_body(["a", "b", "c", "d"], 2, 0)
      body.should contain("2 of them are hidden by the current search.")
      ProjectPicker.delete_confirm_body(["a", "b", "c", "d"], 1, 0).should contain("1 of them is hidden")
    end

    it "says what it is keeping because it is in use" do
      ProjectPicker.delete_confirm_body(["a"], 0, 1).should contain("1 more is in use and will be kept.")
      ProjectPicker.delete_confirm_body(["a"], 0, 2).should contain("2 more are in use and will be kept.")
    end
  end

  describe ".delete_result_flash" do
    # A clean single delete is its own report — the row is gone. The notice row it would
    # otherwise take belongs to the open error, the only trace that a project failed to open.
    it "stays silent when one project deleted cleanly" do
      ProjectPicker.delete_result_flash(1, [] of String, nil).should be_nil
    end

    it "reports a clean batch" do
      ProjectPicker.delete_result_flash(3, [] of String, nil).should eq("deleted 3 projects")
    end

    it "reports a partial delete rather than letting the refusals pass as success" do
      ProjectPicker.delete_result_flash(2, ["api"], nil).should eq(%(deleted 2 projects — kept "api"))
      ProjectPicker.delete_result_flash(1, ["api", "shop"], nil).should eq("deleted 1 project — kept 2")
    end

    it "passes the registry's own refusal through when a single delete is refused" do
      msg = "project is open in another gori instance — close it there first"
      ProjectPicker.delete_result_flash(0, ["api"], msg).should eq(msg)
      ProjectPicker.delete_result_flash(0, ["api"], nil).not_nil!.should contain(%("api"))
    end

    # A batch's refusals can be a mix of in-use and filesystem failures, so the line names no
    # cause: "kept 2 in use" sent an operator hunting for a second gori that was never there
    # when the real reason was an unwritable directory.
    it "claims no cause it cannot know on a batch line" do
      ProjectPicker.delete_result_flash(0, ["api", "shop"], "…").should eq("deleted nothing — kept 2")
      ProjectPicker.delete_result_flash(2, ["api", "shop"], "…").not_nil!.should_not contain("in use")
    end
  end

  it "names a blocked delete that never reached the confirm" do
    ProjectPicker.delete_blocked_flash(["api"]).should contain(%(can't delete "api"))
    ProjectPicker.delete_blocked_flash(["api", "shop"]).should contain("can't delete 2 projects")
  end

  describe ".mark_chip" do
    it "draws nothing at all with an empty mark set" do
      ProjectPicker.mark_chip(0, 0).should eq("")
    end

    it "carries the count, and how much of it the search is hiding" do
      ProjectPicker.mark_chip(3, 0).should eq(" · 3 marked")
      ProjectPicker.mark_chip(3, 1).should eq(" · 3 marked (1 hidden)")
    end
  end
end
