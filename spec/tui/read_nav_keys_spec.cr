require "../spec_helper"
require "../support/tui_contract"

# READ-mode caret keys, across every editor pane. `h`/`j`/`k`/`l` are the four letters the
# space menu can never take (`Family::NAV_LETTERS`), so a pane that answers only the arrows
# lets the bare letter fall through to its tab scope: an issue's notes closed the issue on
# `h`, and the Fuzzer template did nothing at all on `j`/`k`. ⌥→ is a WORD step in INSERT,
# and READ stepped one character on it.
private def press(tab : Gori::Tui::TabController, ev : Termisu::Event::Key) : Nil
  if tab.is_a?(Gori::Tui::IssuesController) && tab.view.detail_open?
    return if tab.handle_detail_key(ev)
  end
  tab.handle_body_key(ev)
end

private def caret_of(tab : Gori::Tui::TabController) : {Int32, Int32}
  area, _ = tab.editor_text_buffer.not_nil!
  {area.cy, area.cx}
end

# The eight editor panes, each focused on its text buffer and in READ. Yields the pane's
# controller, a name for failure messages, and the host its focus requests land on.
private def each_editor_pane(session_name : String, & : Gori::Tui::TabController, String, TuiContract::Host ->) : Nil
  TuiContract.with_session(session_name) do |session|
    host = TuiContract::Host.new(session)

    notes = Gori::Tui::NotesController.new(host)
    TuiContract.render(notes)
    yield notes, "notes", host

    rep = Gori::Tui::RepeaterController.new(host)
    rep.repeater_new
    rep.current_view.not_nil!.focus_pane(:request)
    yield rep, "repeater request", host

    fz = Gori::Tui::FuzzerController.new(host)
    fz.fuzz_new
    fz.current_view.not_nil!.focus_pane(:template)
    yield fz, "fuzzer template", host

    pj = Gori::Tui::ProjectController.new(host)
    pj.view.focus_pane(:desc)
    yield pj, "project description", host

    dc = Gori::Tui::DecoderController.new(host)
    dc.@sessions[dc.@idx].pane = :input
    yield dc, "decoder input", host

    yield Gori::Tui::JwtController.new(host), "jwt input", host
    yield Gori::Tui::CookieController.new(host), "cookie input", host

    store = session.store
    id = store.insert_issue("SQLi", Gori::Store::Severity::High, "a.test", nil)
    store.update_issue(id, notes: "x").should be_true
    iss = Gori::Tui::IssuesController.new(host)
    iss.view.reload(store)
    iss.view.open_detail(store).should be_true
    TuiContract.render(iss)
    iss.view.focus_notes!
    yield iss, "issue notes", host
    iss.view.detail_open?.should be_true # `h` used to fall through to `issue.close`
  end
end

describe "READ caret keys in every editor pane" do
  it "moves with h/j/k/l and steps words with ⌥←/→" do
    seen = [] of String
    check = ->(tab : Gori::Tui::TabController, name : String) do
      tab.editor_read_mode?.should be_true, name
      area, read = tab.editor_text_buffer.not_nil!
      area.set_text("alpha beta\ngamma")
      area.place_cursor(0, 0)
      read.clear_selection
      read.sync_from(area)

      press(tab, TuiContract.plain('l'))
      caret_of(tab).should eq({0, 1}), "#{name}: l"
      press(tab, TuiContract.plain('h'))
      caret_of(tab).should eq({0, 0}), "#{name}: h"
      press(tab, TuiContract.key(Termisu::Input::Key::Right, :alt))
      caret_of(tab).should eq({0, 6}), "#{name}: ⌥→"
      press(tab, TuiContract.key(Termisu::Input::Key::Left, :alt))
      caret_of(tab).should eq({0, 0}), "#{name}: ⌥←"
      press(tab, TuiContract.plain('j'))
      caret_of(tab)[0].should eq(1), "#{name}: j"
      press(tab, TuiContract.plain('k'))
      caret_of(tab)[0].should eq(0), "#{name}: k"
      tab.editor_read_mode?.should be_true, "#{name}: still in READ"
      # Esc's first press drops a READ selection, and only a live one: with none it is the
      # pane's own Esc again.
      read.select_line(area)
      tab.editor_drop_read_selection.should be_true, "#{name}: esc over a selection"
      read.selection?(area).should be_false, name
      tab.editor_drop_read_selection.should be_false, "#{name}: esc with nothing selected"
      area.place_cursor(0, 0) # the line selection left the caret at its end
      read.sync_from(area)
      # The vim keyset's `w` and `⇧A`, through the seam the Runner routes them by.
      tab.editor_word_move(1).should be_true, name
      caret_of(tab).should eq({0, 6}), "#{name}: w"
      tab.editor_line_insert(1).should be_true, name
      tab.editor_read_mode?.should be_false, "#{name}: ⇧A enters INSERT"
      caret_of(tab).should eq({0, 10}), "#{name}: ⇧A"
      seen << name
      nil
    end

    each_editor_pane("read-nav-roster") { |tab, name, _host| check.call(tab, name) }
    seen.size.should eq(8), "exercised only #{seen.join(", ")}"
  end

  # A held `⇧V` grows on a plain `k`/`j` at the pane's edge, where the arrow alone would hand
  # focus to the next pane and leave the lines armed for the next `d`.
  it "keeps a held ⇧V selection in the pane at its first and last line" do
    seen = [] of String
    each_editor_pane("read-nav-line-held") do |tab, name, host|
      area, read = tab.editor_text_buffer.not_nil!
      area.set_text("one\ntwo\nthree")
      area.place_cursor(1, 0)
      read.clear_selection
      read.sync_from(area)
      read.select_line(area, line_mode: true)
      tab.editor_line_held?.should be_true, name
      asked = host.focus_requests.size
      2.times { press(tab, TuiContract.plain('k')) }
      tab.editor_text_buffer.try(&.[0]).should be(area), "#{name}: k at the top left the pane"
      read.copy_text(area).should eq("one\ntwo"), name
      # `h` at the very start does not cross either (an issue's notes hand ← to RELATED there);
      # as a sideways step it collapses the selection, as it does everywhere. Two `k`s left the
      # caret on the top line's start, which is exactly that spot.
      {area.cy, area.cx}.should eq({0, 0}), name
      press(tab, TuiContract.plain('h'))
      tab.editor_text_buffer.try(&.[0]).should be(area), "#{name}: h at the start left the pane"
      read.select_line(area, line_mode: true)
      3.times { press(tab, TuiContract.plain('j')) }
      tab.editor_text_buffer.try(&.[0]).should be(area), "#{name}: j at the bottom left the pane"
      read.copy_text(area).should eq("one\ntwo\nthree"), name
      host.focus_requests.size.should eq(asked), "#{name}: asked the host to move focus"
      # End is a caret move: it collapses the held line selection rather than reshaping it into a
      # character span a following `d` would cut.
      press(tab, TuiContract.key(Termisu::Input::Key::End))
      read.selection?(area).should be_false, "#{name}: End kept the selection"
      seen << name
    end
    seen.size.should eq(8), "exercised only #{seen.join(", ")}"
  end

  it "clears a one-line TARGET's selection on Esc" do
    TuiContract.with_session("read-nav-target-esc") do |session|
      host = TuiContract::Host.new(session)
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      v = rep.current_view.not_nil!
      v.focus_pane(:target)
      v.pane_select_line
      v.pane_selection?.should be_true
      rep.editor_drop_read_selection.should be_true
      v.pane_selection?.should be_false
      rep.editor_drop_read_selection.should be_false
    end
  end

  it "types at a one-line TARGET's edges on ⇧A / ⇧I" do
    TuiContract.with_session("read-nav-target") do |session|
      host = TuiContract::Host.new(session)
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      v = rep.current_view.not_nil!
      v.focus_pane(:target)
      rep.editor_text_buffer.should be_nil # no buffer: the shared path cannot serve it
      rep.editor_line_insert(1).should be_true
      rep.editor_read_mode?.should be_false
      rep.editor_word_move(1).should be_false # the Runner says why
    end
  end

  it "clears a selection on Esc ahead of every pane's own Esc" do
    # `Runner.new` owns a terminal, so the wiring is read off the source, comments stripped:
    # the drop runs before the open issue's detail keys, whose Esc leaves the notes.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
      .lines.reject(&.lstrip.starts_with?('#')).join('\n')
    body = src[/private def handle_key\(ev : Termisu::Event::Key\) : Nil$.*?^    end$/m]? || fail "handle_key not found"
    drop = body.index("editor_drop_read_selection") || fail "Esc never drops the selection"
    {"issues_controller.handle_detail_key", "c.handle_body_key"}.each do |later|
      (body.index(later) || fail "#{later} not found").should be > drop
    end
  end
end
