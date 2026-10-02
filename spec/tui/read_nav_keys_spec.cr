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
      # The vim keyset's `w` and `⇧A`, through the seam the Runner routes them by.
      tab.editor_word_move(1).should be_true, name
      caret_of(tab).should eq({0, 6}), "#{name}: w"
      tab.editor_line_insert(1).should be_true, name
      tab.editor_read_mode?.should be_false, "#{name}: ⇧A enters INSERT"
      caret_of(tab).should eq({0, 10}), "#{name}: ⇧A"
      seen << name
      nil
    end

    TuiContract.with_session("read-nav-roster") do |session|
      host = TuiContract::Host.new(session)

      notes = Gori::Tui::NotesController.new(host)
      TuiContract.render(notes)
      check.call(notes, "notes")

      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      rep.current_view.not_nil!.focus_pane(:request)
      check.call(rep, "repeater request")

      fz = Gori::Tui::FuzzerController.new(host)
      fz.fuzz_new
      fz.current_view.not_nil!.focus_pane(:template)
      check.call(fz, "fuzzer template")

      pj = Gori::Tui::ProjectController.new(host)
      pj.view.focus_pane(:desc)
      check.call(pj, "project description")

      dc = Gori::Tui::DecoderController.new(host)
      dc.@sessions[dc.@idx].pane = :input
      check.call(dc, "decoder input")

      check.call(Gori::Tui::JwtController.new(host), "jwt input")
      check.call(Gori::Tui::CookieController.new(host), "cookie input")

      store = session.store
      id = store.insert_issue("SQLi", Gori::Store::Severity::High, "a.test", nil)
      store.update_issue(id, notes: "x").should be_true
      iss = Gori::Tui::IssuesController.new(host)
      iss.view.reload(store)
      iss.view.open_detail(store).should be_true
      TuiContract.render(iss)
      iss.view.focus_notes!
      check.call(iss, "issue notes")
      iss.view.detail_open?.should be_true # `h` used to fall through to `issue.close`
    end
    seen.size.should eq(8), "exercised only #{seen.join(", ")}"
  end
end
