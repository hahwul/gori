require "../spec_helper"
require "../support/tui_contract"
require "../support/fake_host"
require "../support/memory_backend"
require "file_utils"
require "../../src/gori/tui/controllers/history_controller"
require "../../src/gori/tui/controllers/issues_controller"
require "../../src/gori/tui/controllers/repeater_controller"
require "../../src/gori/tui/link_picker"
require "../../src/gori/tui/choice_picker"
require "../../src/gori/tui/confirm_dialog"
require "../../src/gori/tui/export_overlay"

include Gori::Tui

# What a measured walk through the core loop (History → Repeater → Link → Issue → export)
# found wrong, one example per finding, each pinned on the thing the operator actually reads
# or presses.
#
# Most of them are hints. A strip is the only teacher gori has for a key that has no button,
# and every one of these was a key that worked from a pane whose strip did not name it, or a
# token that named an act other than the one ↵ was about to perform. The rest are a verb that
# filled a tab without going there, and a refusal that named no way forward. They are grouped
# by finding id so the walk that found them and the example that holds them shut can be read
# together.
#
# Two of the findings live in `Runner`, which owns a terminal and appears nowhere under spec/,
# so they are read from source the way spec/tui/digit_family_spec.cr reads the dispatch order.

# History keeps the drill-in's OPEN state in the shell, so the controller has to be told.
private class DetailHost < FakeHost
  property tab : Symbol = :history

  def overlay : Symbol
    :detail
  end

  def active_tab : Symbol
    @tab
  end
end

describe "the core-loop hints" do
  describe "F6 — the History DETAIL strip names the key that leaves for the Repeater" do
    it "says `^R repeater` at BOTH detail levels, where it has always worked" do
      TuiContract.with_session("hint-f6") do |session|
        host = DetailHost.new(session)
        ctl = HistoryController.new(host)

        # Body level: the caret is in a pane, and `^R` falls through every arm of
        # `handle_detail_body_key` to the keymap.
        ctl.view.set_detail_focus(:body)
        ctl.body_hint(:body).should contain("^R repeater")

        # Strip level: the chip ladder declines every ctrl chord, so the same key fires.
        ctl.view.set_detail_focus(:strip)
        ctl.body_hint(:body).should contain("^R repeater")
      end
    end
  end

  describe "F7 — the Issues list strip names the key the triage loop ends on" do
    it "says `⇧E export`, and leaves `⇧X clear` to the space menu" do
      TuiContract.with_session("hint-f7") do |session|
        host = TuiContract::Host.new(session)
        host.tab = :issues
        ctl = IssuesController.new(host)
        hint = ctl.body_hint(:body)
        hint.should contain("⇧E export")
        hint.should_not contain("clear")
      end
    end

    it "keeps ⇧X named in the MARKS state, where `clear ALL` is the word that disambiguates" do
      TuiContract.with_session("hint-f7-marks") do |session|
        store = session.store
        store.insert_issue("one", Gori::Store::Severity::High, "h.test", nil)
        store.flush
        host = TuiContract::Host.new(session)
        host.tab = :issues
        ctl = IssuesController.new(host)
        ctl.view.reload(store)
        ctl.view.toggle_mark
        ctl.view.mark_count.should be > 0
        ctl.body_hint(:body).should contain("⇧X clear ALL")
      end
    end
  end

  describe "F9 — the Repeater arrival hint names the digit key that lands" do
    it "advertises ⇧1-9, the primary, and never the ^1-9 alias" do
      TuiContract.with_session("hint-f9") do |session|
        host = TuiContract::Host.new(session)
        host.tab = :repeater
        ctl = RepeaterController.new(host)
        ctl.repeater_new
        arrival = host.statuses.last
        arrival.should contain("⇧1-9 switch")
        arrival.should_not contain("^1-9")
      end
    end
  end

  describe "F11 — `y` says WHICH bytes it is about to copy" do
    it "reads `y copy all` with no selection and `y copy` with one" do
      TuiContract.with_session("hint-f11") do |session|
        host = TuiContract::Host.new(session)
        host.tab = :repeater
        ctl = RepeaterController.new(host)
        ctl.repeater_new
        v = ctl.current_view.not_nil!
        v.focus_pane(:response)
        ctl.body_hint(:body).should contain("y copy all")

        v.focus_pane(:request)
        ctl.repeater_select_line # `x` — a band in READ, the state `y` copies
        ctl.repeater_selection_active?.should be_true
        hint = ctl.body_hint(:body)
        hint.should contain("y copy")
        hint.should_not contain("copy all")
      end
    end
  end

  describe "F3 — the EDITOR strip leads with the way out" do
    it "puts `esc read` and `↹ text` first, where a 132-column cut cannot reach them" do
      TuiContract.with_session("hint-f3") do |session|
        host = TuiContract::Host.new(session)
        host.tab = :repeater
        ctl = RepeaterController.new(host)
        ctl.repeater_new
        v = ctl.current_view.not_nil!
        v.focus_pane(:request)
        v.enter_request_insert!
        hint = ctl.body_hint(:body)
        hint.should start_with("esc read · ↹ text ·")
        # …and the tokens that take the `…` are the ones about editing, which is what the
        # hand is already doing.
        hint.index("esc read").not_nil!.should be < hint.index("^G goto").not_nil!
      end
    end
  end

  describe "F4 — the badge names the pane the keys are landing in" do
    it "reads `RESPONSE` / `REQUEST` / `TARGET` off the Repeater's restored focus" do
      TuiContract.with_session("hint-f4") do |session|
        host = TuiContract::Host.new(session)
        host.tab = :repeater
        ctl = RepeaterController.new(host)
        ctl.repeater_new
        v = ctl.current_view.not_nil!
        v.focus_pane(:response)
        ctl.body_pane_label.should eq("RESPONSE")
        v.focus_pane(:target)
        ctl.body_pane_label.should eq("TARGET")
      end
    end

    it "is nil on a one-body tab, which keeps the bare badge" do
      TuiContract.with_session("hint-f4-plain") do |session|
        host = TuiContract::Host.new(session)
        host.tab = :issues
        IssuesController.new(host).body_pane_label.should be_nil
      end
    end
  end

  describe "F12 — LINK TO says why a freeze is not on offer" do
    rows = [LinkPicker::Row.new(Gori::Store::LinkOwnerKind::Issue, 7_i64, "#7 [high] SQLi", "SQLi", "")]

    it "names the refusal on an issue row when nothing can be frozen" do
      lp = LinkPicker.new(rows, freezable: false,
        freeze_refusal: "repeater #3 has never been sent — send it first, then freeze the exchange")
      lp.set_selected(lp.create_rows) # the existing issue
      lp.enter_action.should start_with("link — nothing to freeze: repeater #3 has never been sent")
      lp.hint.should contain("nothing to freeze")
    end

    it "says nothing extra when the freeze IS on offer" do
      lp = LinkPicker.new(rows, freezable: true)
      lp.set_selected(lp.create_rows)
      lp.enter_action.should eq("link & freeze")
    end

    it "stays quiet on a NOTE row, which was never a freeze candidate" do
      note = [LinkPicker::Row.new(Gori::Store::LinkOwnerKind::Note, 2_i64, "2:Auth notes", "Auth notes", "")]
      lp = LinkPicker.new(note, freezable: false, freeze_refusal: "the send failed")
      lp.set_selected(lp.create_rows)
      lp.enter_action.should eq("link")
    end
  end

  describe "F16 — LINK TO opens where the common act is" do
    rows = [LinkPicker::Row.new(Gori::Store::LinkOwnerKind::Issue, 7_i64, "#7 [high] SQLi", "SQLi", "")]

    it "lands on `+ New issue…` for a ref nobody has filed against yet" do
      lp = LinkPicker.new(rows, linked: false)
      lp.selected.should eq(0)
      lp.selected_create.should eq(Gori::Store::LinkOwnerKind::Issue)
    end

    it "lands on the first existing owner once the ref has links" do
      lp = LinkPicker.new(rows, linked: true)
      lp.selected.should eq(lp.create_rows)
      lp.selected_row.try(&.id).should eq(7_i64)
    end
  end

  describe "F13 — the ISSUE CREATED card puts its keys on the buttons" do
    it "draws `[y] open` and `[n] stay`, the letters that actually press them" do
      dlg = ConfirmDialog.new("ISSUE CREATED", "issue #21 created and linked.\nOpen it now, or stay here?",
        confirm_label: "open", cancel_label: "stay", danger: false)
      backend = MemoryBackend.new(80, 20)
      screen = Screen.new(backend)
      area = Rect.new(0, 0, 80, 20)
      dlg.render(screen, area)
      backend.contains?("[y] open").should be_true
      backend.contains?("[n] stay").should be_true
    end

    it "still hit-tests the button it drew, accelerator included" do
      dlg = ConfirmDialog.new("ISSUE CREATED", "issue #21 created and linked.",
        confirm_label: "open", cancel_label: "stay", danger: false)
      area = Rect.new(0, 0, 80, 20)
      box = dlg.overlay_box(area)
      confirm_rect, cancel_rect = dlg.button_rects(box)
      dlg.button_at(box, confirm_rect.x, confirm_rect.y).should eq(:confirm)
      dlg.button_at(box, cancel_rect.right - 1, cancel_rect.y).should eq(:cancel)
    end

    it "names every key in the hint, so the strip under it is answerable" do
      dlg = ConfirmDialog.new("ISSUE CREATED", "issue #21 created and linked.",
        confirm_label: "open", cancel_label: "stay", danger: false)
      dlg.hint.should eq("←/→ choose · ↵ open · y open · n/esc stay")
    end
  end

  describe "F8 — Compare goes to the Comparer, like every sibling Send verb" do
    comparer_src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "comparer.cr"))

    it "navigates once BOTH slots are filled" do
      body = comparer_src[/private def comparer_add_pair.*?\n  end/m]
      body.should_not be_nil, "comparer_add_pair is gone — this scan rotted before the rule did"
      body.not_nil!.should contain("goto_tab(:comparer)")
    end

    it "stays put on a ONE-slot fill, where the next thing to do is mark the other flow" do
      {"comparer_add_selected", "comparer_add_repeater", "comparer_add_sitemap",
       "comparer_add_fuzz"}.each do |name|
        body = comparer_src[Regex.new("  def #{name}.*?\n  end", Regex::Options::MULTILINE)]
        body.should_not be_nil, "#{name} is gone"
        body.not_nil!.should_not contain("goto_tab"), "#{name} navigates off a half-filled diff"
      end
    end

    it "never points at the palette for a tab the Go-to picker reaches" do
      comparer_src.should_not contain("(^P)")
      comparer_src.should contain("open Comparer (0)")
    end
  end

  describe "F14/F15 — the export pair says what ↵ does" do
    it "reads `↵ export` on EXPORT ISSUES AS, which stores no preference" do
      ChoicePicker.for_export_format.hint.should contain("↵ export")
    end

    it "keeps `↵ set` on the three pickers that DO set something" do
      ChoicePicker.for_severity(2).hint.should contain("↵ set")
      ChoicePicker.for_status(0).hint.should contain("↵ set")
      ChoicePicker.for_probe_mode(1).hint.should contain("↵ set")
    end

    it "reads `↵ overwrite` once the destination card is warning about an existing file" do
      dir = File.tempname("gori-export-hint")
      Dir.mkdir_p(dir)
      begin
        path = File.join(dir, "issues.md")
        File.write(path, "old")
        ov = ExportOverlay.new(:issues_md, path)
        ov.hint.should contain("↵ write")
        # The first ↵ arms the overwrite and writes nothing — which is exactly the press that
        # reads as "nothing happened" while the strip still promises a write.
        ov.handle_key(TuiContract.key(Termisu::Input::Key::Enter)).should eq(:stay)
        ov.hint.should contain("↵ overwrite")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
