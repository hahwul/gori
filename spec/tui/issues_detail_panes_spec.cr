require "../spec_helper"
require "file_utils"
require "../support/memory_backend"
require "../support/fake_host"

include Gori::Tui

# The Issues detail is TWO panes, and until now it neither looked like two nor navigated like
# two.
#
# RELATED was an open region — an `inner_divider`, a text heading, then the link rows — sitting
# above the closed NOTES card, which reads as containment. Nothing in that region varied with
# `@detail_focus` either: the divider took the pane-level `focused`, the row band took the
# selected INDEX, the heading was unconditional. So `esc` out of NOTES moved focus somewhere
# with no signal at all — and on an issue with NO links, which is the shape `n` creates, there
# was not even a band to notice. That is why "back doesn't work" was a fair report of a key
# that did exactly what it was written to do.
#
# The third defect is the one that actually strands the keyboard: `pane_advance` answered false
# while a detail was open, which is how a view tells `Runner#focus_advance` to hand focus to
# the TAB BAR — and the shell's `handle_detail_key` arm is gated on `@focus == :body`. One ⇥
# and the detail was still fully drawn with every key dead, back keys included.

private ISSUE_PANES_CA = File.tempname("gori-issue-panes-ca")
Spec.after_suite { FileUtils.rm_rf(ISSUE_PANES_CA) }

private def with_session(&)
  root = File.tempname("gori-issue-panes")
  Dir.mkdir_p(root)
  begin
    project = Gori::ProjectRegistry.new(root).temp("issuepanes")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(ISSUE_PANES_CA), Gori::Verbs.registry, project)
    begin
      yield FakeHost.new(session), session
    ensure
      session.close
    end
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private UP       = -> { key(Termisu::Input::Key::Up) }
private LEFT     = -> { key(Termisu::Input::Key::Left) }
private ESC      = -> { key(Termisu::Input::Key::Escape) }
private SHIFT_UP = -> { key(Termisu::Input::Key::Up, :shift) }

# An open detail on an issue with `links` related items. Zero links is the DISCRIMINATOR for
# the invisible-focus defect, so it is the default.
private def detail(store, links = 0, &)
  id = store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
  links.times do |i|
    store.add_link(Gori::Store::LinkOwnerKind::Issue, id,
      Gori::Store::LinkRefKind::Flow, (900 + i).to_i64)
  end
  store.update_issue(id, notes: "alpha\nbravo\ncharlie").should be_true
  view = IssuesView.new
  view.reload(store)
  view.open_detail(store).should be_true
  yield view, id
end

private def render(view, w = 80, h = 20, focused = true) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h), focused: focused)
  backend
end

describe "the Issues detail's two panes" do
  describe "geometry" do
    it "gives RELATED a closed card over exactly the rows the open region cost" do
      with_store do |store|
        detail(store) do |view|
          rel, notes = view.detail_split(Rect.new(0, 0, 80, 20))
          # THREE meta rows (title, chips, timestamps), then the card. The `flow` row that
          # used to be the fourth is gone: the primary flow is RELATED's first row now, and
          # the row it gave up went to NOTES.
          rel.y.should eq(3)
          # Frame + LINKS_VISIBLE rows: the same six the divider + heading + four rows took.
          rel.h.should eq(IssuesView::LINKS_VISIBLE + 2)
          rel.inset(1, 1).h.should eq(IssuesView::LINKS_VISIBLE)
          # NOTES picks up immediately below and keeps the rest.
          notes.y.should eq(rel.bottom)
          notes.bottom.should eq(20)
        end
      end
    end

    it "never grants RELATED a row too short to draw a card with" do
      with_store do |store|
        detail(store, links: 3) do |view|
          # `Frame.card` needs two rows for its own frame, so a granted h == 1 paints nothing
          # and just costs NOTES the row. Sweep the band where the clamp is active.
          (5..14).each do |h|
            rel, notes = view.detail_split(Rect.new(0, 0, 40, h))
            rel.h.should_not eq(1)
            notes.y.should eq(rel.bottom)
            notes.bottom.should eq(h)
          end
          # The specific height that produced it: interior of 4 rows -> avail - 3 == 1.
          # h == 7 since the meta block lost its `flow` row (it was h == 8 when the head was 4).
          rel, notes = view.detail_split(Rect.new(0, 0, 40, 7))
          rel.h.should eq(0)
          notes.h.should eq(4) # the row RELATED used to keep and never paint
        end
      end
    end

    it "is the one derivation the hit-tests read" do
      with_store do |store|
        detail(store) do |view|
          rect = Rect.new(0, 0, 80, 20)
          # `notes_card_rect` is what `IssuesController`'s four hit-tests measure against —
          # the mode-badge chip, click-to-cursor, drag and double-click. It used to re-derive
          # the arithmetic `render_detail` did, so moving one without the other put clicks on
          # the wrong rows with nothing raising.
          view.notes_card_rect(rect).should eq(view.detail_split(rect)[1])
          view.notes_body_rect(rect).should eq(view.detail_split(rect)[1].inset(1, 1))
        end
      end
    end

    it "keeps both rects inside a container too short for either card" do
      with_store do |store|
        detail(store) do |view|
          # `pane_overspill_spec`'s invariant, at the sizes `Layout.usable?` still allows.
          (5..12).each do |h|
            rect = Rect.new(0, 0, 40, h)
            rel, notes = view.detail_split(rect)
            rel.y.should be >= rect.y
            rel.bottom.should be <= rect.bottom
            notes.bottom.should be <= rect.bottom
            notes.y.should eq(rel.bottom)
            # RELATED yields its rows first — NOTES is the pane you read and type in.
            notes.h.should be >= 0
          end
        end
      end
    end
  end

  describe "the focus signal" do
    # THE regression this whole change exists for: with zero links, moving focus between the
    # two panes used to change not one cell on screen.
    it "moves the gold border between the cards, with no links at all" do
      with_store do |store|
        detail(store) do |view|
          rel, notes = view.detail_split(Rect.new(0, 0, 80, 20))
          view.notes_focused?.should be_false # opens on RELATED

          on_links = render(view)
          on_links.fg_at(0, rel.y + 1).should eq(Theme.focus_gold)
          on_links.fg_at(0, notes.y + 1).should eq(Theme.border)

          view.focus_notes!
          on_notes = render(view)
          on_notes.fg_at(0, rel.y + 1).should eq(Theme.border)
          on_notes.fg_at(0, notes.y + 1).should eq(Theme.focus_gold)
        end
      end
    end

    it "titles the card and puts the count in the border meta, not the title" do
      with_store do |store|
        detail(store, links: 2) do |view|
          backend = render(view)
          rel, _ = view.detail_split(Rect.new(0, 0, 80, 20))
          row = backend.row(rel.y)
          row.should contain("RELATED")
          # `shared_chrome_spec` keeps counts out of card titles — the title's width is what a
          # badge's `min_x` is derived from — so the count rides the right-aligned meta slot.
          row.should_not contain("RELATED (")
          row.should contain("2 · space l")
        end
      end
    end
  end
end

describe "crossing the Issues detail's panes" do
  it "hands ↓ past the last RELATED row to NOTES" do
    with_session do |host, session|
      store = session.store
      id = store.insert_issue("linked", Gori::Store::Severity::Critical, "api.demo.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, id,
        Gori::Store::LinkRefKind::Flow, 901_i64)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, id,
        Gori::Store::LinkRefKind::Flow, 902_i64)
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.view.notes_focused?.should be_false
      ctl.view.links_at_bottom?.should be_false # two rows, cursor on the first

      ctl.issue_link_move(1) # row 0 -> row 1, still in RELATED
      ctl.view.notes_focused?.should be_false
      ctl.view.links_at_bottom?.should be_true
      ctl.issue_link_move(1) # off the last row -> NOTES
      ctl.view.notes_focused?.should be_true
    end
  end

  it "reaches NOTES on the first ↓ when the issue has no links" do
    with_session do |host, session|
      store = session.store
      store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      # This is the shape `n` creates, and READ-mode NOTES had no keyboard route into it at
      # all: every other way in (`i`, `↵`, `e`, a click) goes through the INSERT editor.
      ctl.issue_link_move(1)
      ctl.view.notes_focused?.should be_true
    end
  end

  it "hands ↑ on the first NOTES row back to RELATED" do
    with_session do |host, session|
      store = session.store
      store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.view.focus_notes!
      ctl.view.notes_at_top?.should be_true

      ctl.handle_detail_key(UP.call).should be_true
      ctl.view.notes_focused?.should be_false
    end
  end

  it "hands ← at the START OF THE NOTES back to RELATED" do
    with_session do |host, session|
      store = session.store
      id = store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      store.update_issue(id, notes: "alpha\nbravo").should be_true
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.view.focus_notes!
      ctl.view.notes_at_doc_start?.should be_true

      # The caret is seeded at (0, 0) whenever the pane is entered, so this is the state an
      # operator is actually in when they reach for `←` to go back.
      ctl.handle_detail_key(LEFT.call).should be_true
      ctl.view.notes_focused?.should be_false
    end
  end

  it "still moves the read caret when ← is pressed mid-line" do
    with_session do |host, session|
      store = session.store
      id = store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      store.update_issue(id, notes: "alpha\nbravo").should be_true
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.view.focus_notes!
      ctl.view.notes_read_move(0, 1)
      ctl.view.notes_at_doc_start?.should be_false

      ctl.handle_detail_key(LEFT.call).should be_true
      # Stays in the pane and walks the caret back, so `←`/`→` remain symmetric for the
      # ⇧arrow selection this pane also owns.
      ctl.view.notes_focused?.should be_true
      ctl.view.notes_at_doc_start?.should be_true
    end
  end

  # The two edges below are the ones a LINE-scoped reading of "at the start" / "at the top"
  # gets wrong, and both are the normal case rather than a corner: `←` on any note past line
  # one, and `↑` anywhere inside a wrapped paragraph.
  it "keeps ← at a line start that is not the document start, where the caret really moves" do
    with_session do |host, session|
      store = session.store
      id = store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      store.update_issue(id, notes: "alpha\nbravo").should be_true
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.view.focus_notes!
      ctl.view.notes_read_move(1, 0) # line 2, column 0
      ctl.view.notes_at_doc_start?.should be_false

      # `ReadCursor#move` clamps the column only in its SELECTING branch; a bare `←` takes
      # the branch below (`read_cursor.cr:138-147`), which WRAPS to the previous line's end.
      # So column 0 is NOT a free key here — claiming it for the crossing stole a real motion
      # on every note with more than one line.
      ctl.handle_detail_key(LEFT.call).should be_true
      ctl.view.notes_focused?.should be_true
      # It landed on line 1 at its END — the top row, but emphatically not the document start,
      # which is what makes the two predicates different questions.
      ctl.view.notes_at_top?.should be_true
      ctl.view.notes_at_doc_start?.should be_false
      # …and one more `←` walks the caret inside that line rather than leaving.
      ctl.handle_detail_key(LEFT.call).should be_true
      ctl.view.notes_focused?.should be_true
    end
  end

  it "steps ↑ one VISUAL row inside a wrapped first paragraph instead of ejecting" do
    with_session do |host, session|
      store = session.store
      id = store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      # ONE logical line, long enough to wrap several times in the NOTES card — which is what
      # an issue writeup is. `@notes.wrap = true`, and `TextReadState#move` routes `dr != 0`
      # through `TextArea#visual_row_target`, so `↑`/`↓` step drawn rows here.
      store.update_issue(id, notes: ("lorem ipsum dolor sit amet " * 12).strip).should be_true
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.view.focus_notes!
      # A render first: the wrap layout is measured while drawing, and `visual_row_target`
      # answers nil until a width exists.
      render(ctl.view, 60, 24)

      ctl.view.notes_read_move(1, 0) # down one DRAWN row, still inside logical line 0
      ctl.view.notes_at_top?.should be_false

      # Testing `cursor.cy <= 0` reported "top" for every row of this paragraph, so `↑`
      # anywhere in it left the pane rather than moving the caret.
      ctl.handle_detail_key(UP.call).should be_true
      ctl.view.notes_focused?.should be_true
      ctl.view.notes_at_top?.should be_true
    end
  end

  it "leaves a mid-build ⇧arrow selection alone instead of crossing" do
    with_session do |host, session|
      store = session.store
      id = store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      store.update_issue(id, notes: "alpha\nbravo").should be_true
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.view.focus_notes!
      ctl.view.notes_read_move(1, 0) # down one row, so ⇧↑ has something to extend over
      ctl.view.notes_at_top?.should be_false
      ctl.handle_detail_key(SHIFT_UP.call).should be_true
      ctl.view.notes_at_top?.should be_true
      ctl.view.notes_selection?.should be_true

      # At the top row now, with a selection held. A crossing arm claims only a BARE press —
      # leaving here would abandon the selection instead of extending it.
      ctl.handle_detail_key(SHIFT_UP.call).should be_true
      ctl.view.notes_focused?.should be_true
    end
  end

  it "walks ⇥ between the two panes instead of ejecting focus to the tab bar" do
    with_session do |host, session|
      store = session.store
      store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true

      # FALSE is how a view tells `Runner#focus_advance` to hand focus to the tab bar, and the
      # shell's `handle_detail_key` arm is gated on body focus — so a false here left the
      # detail drawn with every key dead. Two panes and a drill-in with its own way out, so
      # the ring wraps and always claims the key.
      ctl.pane_advance(1).should be_true
      ctl.view.notes_focused?.should be_true
      ctl.pane_advance(1).should be_true
      ctl.view.notes_focused?.should be_false
      ctl.pane_advance(-1).should be_true
      ctl.view.notes_focused?.should be_true

      # …and the keyboard is still live afterwards, which is the property that was lost.
      ctl.handle_detail_key(ESC.call).should be_true
      ctl.view.notes_focused?.should be_false
    end
  end

  it "leaves the list page's ring answering false off its ends" do
    with_session do |host, session|
      store = session.store
      store.insert_issue("standalone", Gori::Store::Severity::High, "api.demo.test", nil)
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      # No detail open: false is correct here and is what returns focus to the tab bar.
      prev = Gori::Settings.issues_preview
      begin
        Gori::Settings.issues_preview = false
        ctl.pane_advance(1).should be_false
      ensure
        Gori::Settings.issues_preview = prev
      end
    end
  end

  # Probe's detail is ONE pane, so its ring has nowhere to go — but it must not answer false
  # either: that is the same ejection, and `ProbeController#handle_body_key`'s detail arm is
  # gated on body focus exactly as Issues' is. Swallowing the key is the only answer that
  # leaves the keyboard alive.
  it "swallows ⇥ in a Probe detail rather than ejecting focus" do
    with_session do |host, session|
      store = session.store
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP",
        Gori::Store::Severity::Low))
      ctl = ProbeController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true

      ctl.pane_advance(1).should be_true
      ctl.pane_advance(-1).should be_true
      # …and the detail still answers keys afterwards.
      ctl.handle_body_key(UP.call).should be_true
    end
  end

  # …and the Rules sub-tab must not reopen the hole. `move_subtab` only moves `@sub_idx`, so a
  # detail opened on Findings is still open with Rules selected — and an arm testing the
  # sub-tab BEFORE the detail hands that state the very answer this fix exists to stop giving.
  it "swallows ⇥ in a Probe detail even with the Rules sub-tab selected" do
    with_session do |host, session|
      store = session.store
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP",
        Gori::Store::Severity::Low))
      ctl = ProbeController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.move_subtab(1)
      ctl.rules_tab?.should be_true
      ctl.view.detail_open?.should be_true

      ctl.pane_advance(1).should be_true
      ctl.handle_body_key(UP.call).should be_true
    end
  end

  it "keeps the wheel out of the focus ring" do
    with_session do |host, session|
      store = session.store
      id = store.insert_issue("linked", Gori::Store::Severity::High, "api.demo.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, id,
        Gori::Store::LinkRefKind::Flow, 901_i64)
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      # A wheel reads as "scroll the viewport", not as a focus gesture: `scroll_links_wheel`
      # shares `move_links` with the keyboard path, so the handoff lives in the controller.
      ctl.view.scroll_links_wheel(1)
      ctl.view.notes_focused?.should be_false
    end
  end
end
