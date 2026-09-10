require "../spec_helper"
require "file_utils"
require "../support/memory_backend"
require "../support/fake_host"

include Gori::Tui

# The Issues detail under the POINTER (#1021).
#
# Two reports, one cause each. The RELATED card was mouse-dead: `handle_click`'s detail branch
# hit-tested the NOTES card and then swallowed everything else, so every cell of the pane the
# detail OPENS on — rows, gauge, border — did nothing at all, and the wheel scrolled whichever
# card held the keyboard rather than the one under the cursor. And the shell frame was gilded
# from the bare `focus == :body` while BOTH inner cards draw their own borders, so an open
# detail read as "the whole tab is focused" and the card that actually owned the keyboard had
# nothing to distinguish it.
#
# The click branch also never took focus: with the tab bar focused, a click into the detail
# placed the notes caret and then sent the typing to the tab bar.

private ISSUE_MOUSE_CA = File.tempname("gori-issue-mouse-ca")
Spec.after_suite { FileUtils.rm_rf(ISSUE_MOUSE_CA) }

private def with_session(&)
  root = File.tempname("gori-issue-mouse")
  Dir.mkdir_p(root)
  begin
    project = Gori::ProjectRegistry.new(root).temp("issuemouse")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(ISSUE_MOUSE_CA), Gori::Verbs.registry, project)
    begin
      yield FakeHost.new(session), session
    ensure
      session.close
    end
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private AREA = Rect.new(0, 0, 80, 24)

# A controller with an open detail on an issue carrying `links` related items.
private def detail_controller(host, store, links = 3, notes = "alpha\nbravo", &)
  id = store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
  links.times do |i|
    store.add_link(Gori::Store::LinkOwnerKind::Issue, id,
      Gori::Store::LinkRefKind::Flow, (900 + i).to_i64)
  end
  store.update_issue(id, notes: notes).should be_true
  ctl = IssuesController.new(host)
  ctl.view.reload(store)
  ctl.view.open_detail(store).should be_true
  render(ctl)
  yield ctl, id
end

private def render(ctl, focus : Symbol = :body) : MemoryBackend
  backend = MemoryBackend.new(AREA.w, AREA.h)
  ctl.render_body(Screen.new(backend), AREA, focus)
  backend
end

# The RELATED card / its interior, in the coordinates a click arrives in.
private def related_body(view) : Rect
  view.links_body_rect(AREA.inset(1, 1))
end

describe "clicking the Issues detail" do
  it "puts the RELATED cursor on the row that was clicked" do
    with_session do |host, session|
      detail_controller(host, session.store) do |ctl|
        body = related_body(ctl.view)
        ctl.view.focus_notes! # the click has to bring focus back, not just move the cursor

        ctl.handle_click(AREA, body.x + 2, body.y + 2).should be_true
        ctl.view.notes_focused?.should be_false
        ctl.view.selected_resolved_link.not_nil!.link.ref_id.should eq(902_i64)

        ctl.handle_click(AREA, body.x + 2, body.y).should be_true
        ctl.view.selected_resolved_link.not_nil!.link.ref_id.should eq(900_i64)
      end
    end
  end

  it "focuses RELATED from a cell with no row under it, on an issue with no links at all" do
    with_session do |host, session|
      # The shape `n` creates. There is no row to land on, so a hit-test that only answered
      # rows would leave this pane with no pointer affordance whatsoever.
      detail_controller(host, session.store, links: 0) do |ctl|
        body = related_body(ctl.view)
        ctl.view.focus_notes!
        ctl.handle_click(AREA, body.x + 1, body.y + 1).should be_true
        ctl.view.notes_focused?.should be_false
      end
    end
  end

  it "jumps the cursor from a click on the RELATED scroll gauge" do
    with_session do |host, session|
      detail_controller(host, session.store, links: 20) do |ctl|
        body = related_body(ctl.view)
        # The gauge rides the card's right border column — one OUTSIDE the row band, which is
        # why the row hit-test cannot answer it (see `gauge_row_at`, the list's twin).
        ctl.handle_click(AREA, body.right, body.bottom - 1).should be_true
        ctl.view.notes_focused?.should be_false
        ctl.view.selected_resolved_link.not_nil!.link.ref_id.should eq(919_i64)

        ctl.handle_click(AREA, body.right, body.y).should be_true
        ctl.view.selected_resolved_link.not_nil!.link.ref_id.should eq(900_i64)
      end
    end
  end

  it "leaves the NOTES body to the notes editor" do
    with_session do |host, session|
      detail_controller(host, session.store) do |ctl|
        notes = ctl.view.notes_body_rect(AREA.inset(1, 1))
        ctl.handle_click(AREA, notes.x + 1, notes.y).should be_true
        ctl.view.notes_focused?.should be_true
        ctl.view.notes_insert_mode?.should be_true
      end
    end
  end

  it "takes body focus, so the keys go where the caret went" do
    with_session do |host, session|
      detail_controller(host, session.store) do |ctl|
        before = host.focus_body_calls
        ctl.handle_click(AREA, related_body(ctl.view).x + 1, related_body(ctl.view).y)
        host.focus_body_calls.should eq(before + 1)
      end
    end
  end

  it "saves the notes on the way out of the editor, exactly as esc does" do
    with_session do |host, session|
      store = session.store
      detail_controller(host, store) do |ctl, id|
        ctl.view.enter_notes_insert!
        ctl.view.notes_insert('Z')
        body = related_body(ctl.view)
        ctl.handle_click(AREA, body.x + 1, body.y).should be_true
        ctl.view.notes_insert_mode?.should be_false
        ctl.view.notes_focused?.should be_false
        store.get_issue(id).not_nil!.notes.should start_with("Z")
      end
    end
  end

  it "opens the linked item on a double-click, and only then" do
    with_session do |host, session|
      detail_controller(host, session.store) do |ctl|
        body = related_body(ctl.view)
        # A single press only selects: `issue.open-link` crosses tabs, so it is the second
        # press that runs it (the Sitemap/Activity/Discover rule).
        ctl.handle_click(AREA, body.x + 1, body.y + 1).should be_true
        host.issue_link_opens.should eq(0)

        ctl.handle_double_click(AREA, body.x + 1, body.y + 1).should be_true
        host.issue_link_opens.should eq(1)
        ctl.view.selected_resolved_link.not_nil!.link.ref_id.should eq(901_i64)
      end
    end
  end

  it "still selects a word on a double-click in the NOTES body" do
    with_session do |host, session|
      detail_controller(host, session.store) do |ctl|
        notes = ctl.view.notes_body_rect(AREA.inset(1, 1))
        ctl.handle_double_click(AREA, notes.x + 1, notes.y).should be_true
        host.issue_link_opens.should eq(0)
      end
    end
  end

  it "does not start an edit from a double-click on the read-only meta block" do
    with_session do |host, session|
      detail_controller(host, session.store) do |ctl|
        # `notes_select_word` forces INSERT and hit-tests nothing, so the title/chips/evidence
        # rows used to drop the operator into the editor with a word selected at clamped
        # coordinates — an edit begun by a gesture on a row that cannot be edited.
        inner = AREA.inset(1, 1)
        ctl.handle_double_click(AREA, inner.x + 5, inner.y).should be_false
        ctl.view.notes_insert_mode?.should be_false
        ctl.view.notes_focused?.should be_false
      end
    end
  end

  it "consumes a double-click on the RELATED card that is not on a row" do
    with_session do |host, session|
      detail_controller(host, session.store, links: 1) do |ctl|
        body = related_body(ctl.view)
        # Below the one link row. Nothing to open — and it must not fall through to the NOTES
        # word-select the way it used to, which sat on the other side of this branch.
        ctl.handle_double_click(AREA, body.x + 1, body.bottom - 1).should be_true
        host.issue_link_opens.should eq(0)
        ctl.view.notes_insert_mode?.should be_false
      end
    end
  end
end

describe "the Issues detail's wheel" do
  it "scrolls the card under the pointer and leaves the keyboard where it is" do
    with_session do |host, session|
      detail_controller(host, session.store, links: 12, notes: (1..60).map { |i| "line #{i}" }.join("\n")) do |ctl|
        ctl.view.focus_notes!
        rel = ctl.view.links_card_rect(AREA.inset(1, 1))
        ctl.handle_wheel_at(2, rel.x + 1, rel.y + 1, AREA).should be_true
        # The RELATED cursor moved; the keyboard stayed in NOTES.
        ctl.view.selected_resolved_link.not_nil!.link.ref_id.should eq(902_i64)
        ctl.view.notes_focused?.should be_true

        ctl.view.focus_links!
        notes = ctl.view.notes_card_rect(AREA.inset(1, 1))
        ctl.handle_wheel_at(3, notes.x + 1, notes.y + 2, AREA).should be_true
        ctl.view.selected_resolved_link.not_nil!.link.ref_id.should eq(902_i64) # untouched
        ctl.view.notes_focused?.should be_false
      end
    end
  end
end

describe "the Issues detail's shell frame" do
  it "stands down while a detail is open, so only the focused card is gold" do
    with_session do |host, session|
      detail_controller(host, session.store) do |ctl|
        rel, notes = ctl.view.detail_split(AREA.inset(1, 1))
        on_links = render(ctl)
        # THE report: the shell outline was gilded from the bare body focus while both cards
        # draw their own, so every border on screen was the same colour.
        on_links.fg_at(0, 1).should eq(Theme.border)
        on_links.fg_at(rel.x, rel.y + 1).should eq(Theme.focus_gold)
        on_links.fg_at(notes.x, notes.y + 1).should eq(Theme.border)

        ctl.view.focus_notes!
        on_notes = render(ctl)
        on_notes.fg_at(0, 1).should eq(Theme.border)
        on_notes.fg_at(notes.x, notes.y + 1).should eq(Theme.focus_gold)
      end
    end
  end

  it "keeps the gold on the LIST page, where the shell IS the list's border" do
    with_session do |host, session|
      detail_controller(host, session.store) do |ctl|
        ctl.view.close_detail
        # Neither the list nor its preview draws a card of its own — drop the gold here and
        # the tab would have no focus signal at all.
        render(ctl).fg_at(0, 1).should eq(Theme.focus_gold)
        render(ctl, :menu).fg_at(0, 1).should eq(Theme.border)
      end
    end
  end
end
