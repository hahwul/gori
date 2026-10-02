require "../spec_helper"
require "../support/tui_contract"

# src/gori/tui/read_edit.cr — the READ-mode edits (gori's `x`→`d` / `x`→`y` / `p`, vim's
# `dd` / `yy` / `p`), driven through real controllers. The point of the engine is that it
# never splices a buffer itself: it enters INSERT and replays ⌫ or a paste through the pane's
# own key path. So these examples hand it the controller's own `handle_body_key` as the key
# sink and assert on what the PANE ended up holding, including the Repeater's wire bytes.
#
# An open Issue routes its keys through `handle_detail_key` first, as `Runner#handle_key` does;
# the Runner itself hands the engine its whole `handle_key`.
private def sink(tab : Gori::Tui::TabController) : Gori::Tui::ReadEdit::KeyIn
  ->(ev : Termisu::Event::Key) do
    if tab.is_a?(Gori::Tui::IssuesController) && tab.view.detail_open?
      tab.handle_detail_key(ev) || tab.handle_body_key(ev)
    else
      tab.handle_body_key(ev)
    end
    nil
  end
end

# `Clipboard.copy` writes OSC 52 to the real terminal unless the setting is off; the register
# fills either way, which is the half these examples read.
private def without_osc52(&)
  prev = Gori::Settings.clipboard_osc52?
  Gori::Settings.clipboard_osc52 = false
  begin
    yield
  ensure
    Gori::Settings.clipboard_osc52 = prev
  end
end

private def notes_with(host, text : String) : Gori::Tui::NotesController
  notes = Gori::Tui::NotesController.new(host)
  host.tab = :notes
  TuiContract.render(notes)
  notes.view.replace_current(text)
  notes
end

# Put the READ caret at {cy, cx} with no selection.
private def caret(tab : Gori::Tui::TabController, cy : Int32, cx : Int32) : Nil
  area, read = tab.editor_text_buffer.not_nil!
  area.place_cursor(cy, cx)
  read.clear_selection
  read.sync_from(area)
end

# A READ selection {y0, x0}…{y1, x1}, made the way `esc` hands an INS selection over.
private def select_span(tab : Gori::Tui::TabController, y0 : Int32, x0 : Int32, y1 : Int32, x1 : Int32) : Nil
  area, read = tab.editor_text_buffer.not_nil!
  area.select_span(y0, x0, y1, x1)
  read.adopt_editor_selection(area).should be_true
end

describe Gori::Tui::ReadEdit do
  before_each { Gori::Tui::Register.clear }

  it "deletes an `x` line selection as a whole line, and `p` puts it back below the caret" do
    TuiContract.with_session("read-edit-notes-line") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "one\ntwo\nthree")
      caret(notes, 1, 1)
      notes.view.select_line # gori's `x`
      Gori::Tui::ReadEdit.line_selection?(notes).should be_true

      Gori::Tui::ReadEdit.delete_selection(notes, sink(notes)).should eq("deleted 1 line")
      notes.view.current_text.should eq("one\nthree")
      notes.view.insert_mode?.should be_false # back in READ, as `esc` would leave it
      Gori::Tui::Register.text.should eq("two")
      Gori::Tui::Register.linewise?.should be_true

      caret(notes, 1, 2) # on "three"
      Gori::Tui::ReadEdit.paste(notes, sink(notes)).should eq("pasted 1 line")
      notes.view.current_text.should eq("one\nthree\ntwo")
      area, _ = notes.editor_text_buffer.not_nil!
      area.cy.should eq(2) # on the pasted line, as vim leaves it
      area.cx.should eq(0)
    end
  end

  it "does not read a span ending at column 0 of a blank line as whole lines" do
    TuiContract.with_session("read-edit-col0") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "head\nHost: x\n\nbody")
      select_span(notes, 1, 0, 2, 0) # ⇧↓ from the line start onto the blank line
      Gori::Tui::ReadEdit.line_selection?(notes).should be_false
      Gori::Tui::ReadEdit.delete_selection(notes, sink(notes)).should eq("deleted 8 chars")
      notes.view.current_text.should eq("head\n\nbody") # the blank separator survives
      Gori::Tui::Register.linewise?.should be_false
    end
  end

  it "deletes an empty line with x then d, where x has nothing to select" do
    TuiContract.with_session("read-edit-blank") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "a\n\nb")
      caret(notes, 1, 0)
      notes.view.select_line
      Gori::Tui::ReadEdit.delete_selection(notes, sink(notes)).should eq("deleted 1 line")
      notes.view.current_text.should eq("a\nb")
      caret(notes, 0, 0) # a non-empty line with nothing selected still refuses
      Gori::Tui::ReadEdit.delete_selection(notes, sink(notes)).should eq(Gori::Tui::ReadEdit::NOTHING_SEL)
    end
  end

  it "spends an armed dd / yy on the very next key, ahead of every early return" do
    # `Runner.new` owns a terminal, so the wiring is read off the source, comments stripped
    # (the idiom spec/tui/paste_arms_editor_spec.cr uses): the arm is cleared before the quit
    # arm and the ^G/^F/^B guards, which all return before the second-press check.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
      .lines.reject(&.lstrip.starts_with?('#')).join('\n')
    body = src[/private def handle_key\(ev : Termisu::Event::Key\) : Nil$.*?^    end$/m]? || fail "handle_key not found"
    clear = body.index("@editor_op = nil") || fail "the arm is never cleared"
    {"quit_chord_claimed?", "lower_g?", "lower_f?", "lower_b?", "finish_editor_op"}.each do |later|
      (body.index(later) || fail "#{later} not found").should be > clear
    end
  end

  it "deletes the last line without leaving a blank one, and the only line down to empty" do
    TuiContract.with_session("read-edit-notes-edges") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "one\ntwo")
      caret(notes, 1, 0)
      Gori::Tui::ReadEdit.delete_line(notes, sink(notes)).should eq("deleted 1 line")
      notes.view.current_text.should eq("one")
      Gori::Tui::ReadEdit.delete_line(notes, sink(notes)).should eq("deleted 1 line")
      notes.view.current_text.should eq("")
      Gori::Tui::Register.text.should eq("one")
    end
  end

  it "deletes and pastes a span inside a line as characters, not lines" do
    TuiContract.with_session("read-edit-notes-chars") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "hello world")
      select_span(notes, 0, 5, 0, 11) # " world"
      Gori::Tui::ReadEdit.line_selection?(notes).should be_false
      Gori::Tui::ReadEdit.delete_selection(notes, sink(notes)).should eq("deleted 6 chars")
      notes.view.current_text.should eq("hello")
      Gori::Tui::Register.linewise?.should be_false

      caret(notes, 0, 1) # on the first `e`: `p` goes AFTER the character under the caret
      Gori::Tui::ReadEdit.paste(notes, sink(notes)).should eq("pasted 6 chars")
      notes.view.current_text.should eq("he worldllo")
    end
  end

  it "undoes a READ-mode delete in one step" do
    TuiContract.with_session("read-edit-notes-undo") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "a\nb\nc")
      caret(notes, 1, 0)
      Gori::Tui::ReadEdit.delete_line(notes, sink(notes))
      notes.view.current_text.should eq("a\nc")
      notes.editor_undo.should be_true
      notes.view.current_text.should eq("a\nb\nc")
    end
  end

  it "yanks the caret's line linewise (vim yy) and copies a line selection linewise" do
    without_osc52 do
      TuiContract.with_session("read-edit-yank") do |session|
        host = TuiContract::Host.new(session)
        notes = notes_with(host, "first\nsecond")
        caret(notes, 0, 3)
        Gori::Tui::ReadEdit.yank_line(notes).should start_with("yanked 1 line")
        Gori::Tui::Register.text.should eq("first")
        Gori::Tui::Register.linewise?.should be_true
        notes.view.current_text.should eq("first\nsecond") # a yank changes nothing

        caret(notes, 1, 0)
        Gori::Tui::ReadEdit.paste(notes, sink(notes))
        notes.view.current_text.should eq("first\nsecond\nfirst")
      end
    end
  end

  it "fills the register from every copy, charwise, and reports an empty one" do
    without_osc52 do
      TuiContract.with_session("read-edit-register") do |session|
        host = TuiContract::Host.new(session)
        notes = notes_with(host, "x")
        Gori::Tui::ReadEdit.paste(notes, sink(notes)).should eq(Gori::Tui::ReadEdit::EMPTY_REG)
        Gori::Tui::Clipboard.copy("copied elsewhere").should eq(0) # the setting is off…
        Gori::Tui::Register.text.should eq("copied elsewhere")     # …and the register still took it
        Gori::Tui::Register.linewise?.should be_false
      end
    end
  end

  it "says why when there is nothing selected or no buffer to edit" do
    TuiContract.with_session("read-edit-refusals") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "abc")
      caret(notes, 0, 0)
      Gori::Tui::ReadEdit.delete_selection(notes, sink(notes)).should eq(Gori::Tui::ReadEdit::NOTHING_SEL)
      notes.view.current_text.should eq("abc")

      host.tab = :repeater
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      v = rep.current_view.not_nil!
      v.focus_pane(:target) # an editor pane, but a single-line field
      rep.editor_pane?.should be_true
      Gori::Tui::ReadEdit.paste(rep, sink(rep)).should eq(Gori::Tui::ReadEdit::NO_BUFFER)
    end
  end

  it "pastes a wire copy's CRLF as line breaks, keeps a lone CR, and takes invalid UTF-8" do
    TuiContract.with_session("read-edit-wire-copy") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "one")
      Gori::Tui::Register.store("A: 1\r\nB: 2", linewise: true) # as a History detail copy holds it
      Gori::Tui::ReadEdit.paste(notes, sink(notes)).should eq("pasted 2 lines")
      notes.view.current_text.should eq("one\nA: 1\nB: 2") # no CR left inside a line

      host.tab = :repeater
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      v = rep.current_view.not_nil!
      v.focus_pane(:request)
      v.replace_edit_buffer("POST / HTTP/1.1\r\nHost: a\r\n\r\nx\ry")
      caret(rep, 3, 0) # the body line, whose lone CR is data
      Gori::Tui::ReadEdit.delete_line(rep, sink(rep))
      caret(rep, 1, 0)
      Gori::Tui::ReadEdit.paste(rep, sink(rep))
      rep.editor_text_buffer.not_nil![0].lines_snapshot.should contain("x\ry") # moved whole

      Gori::Tui::Register.store("x\xffy")
      caret(rep, 0, 0)
      Gori::Tui::ReadEdit.paste(rep, sink(rep)).should eq("pasted 3 chars")
      v.request_bytes.should_not be_empty # no raise on the send path either
    end
  end

  it "undoes a paste the way a terminal paste undoes in that pane" do
    TuiContract.with_session("read-edit-paste-undo") do |session|
      host = TuiContract::Host.new(session)
      notes = notes_with(host, "top") # takes a paste in bulk: one splice, one undo step
      Gori::Tui::Register.store("l1\nl2\nl3", linewise: true)
      caret(notes, 0, 0)
      Gori::Tui::ReadEdit.paste(notes, sink(notes)).should eq("pasted 3 lines")
      notes.editor_undo.should be_true
      notes.view.current_text.should eq("top")

      # The Project description takes a paste key by key, terminal paste included, so it
      # undoes in typing runs rather than in one step. Bounded, and it gets back to the start.
      pj = Gori::Tui::ProjectController.new(host)
      pj.view.focus_pane(:desc)
      pj.view.replace_desc("top")
      caret(pj, 0, 0)
      Gori::Tui::ReadEdit.paste(pj, sink(pj)).should eq("pasted 3 lines")
      pj.view.desc_text.should eq("top\nl1\nl2\nl3")
      steps = 0
      while pj.view.desc_text != "top" && steps < 12
        pj.editor_undo.should be_true
        steps += 1
      end
      pj.view.desc_text.should eq("top")
    end
  end

  it "edits the Repeater request through its own key path, keeping CRLF on the wire" do
    TuiContract.with_session("read-edit-repeater") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      v = rep.current_view.not_nil!
      v.focus_pane(:request)
      rep.editor_read_mode?.should be_true
      v.replace_edit_buffer("GET / HTTP/1.1\r\nHost: a\r\nX-One: 1\r\nX-Two: 2\r\n\r\n")

      caret(rep, 2, 0) # X-One
      Gori::Tui::ReadEdit.delete_line(rep, sink(rep)).should eq("deleted 1 line")
      v.edit_buffer_text.should eq("GET / HTTP/1.1\r\nHost: a\r\nX-Two: 2\r\n\r\n")

      caret(rep, 2, 0) # X-Two: put X-One back below it, as a header line
      Gori::Tui::ReadEdit.paste(rep, sink(rep)).should eq("pasted 1 line")
      # The break the paste typed is a fresh one (LF in the buffer, exactly as a typed ↵ at the
      # end of a header is); the send path promotes the head to CRLF, so the WIRE is clean.
      String.new(v.request_bytes).should eq("GET / HTTP/1.1\r\nHost: a\r\nX-Two: 2\r\nX-One: 1\r\n\r\n")
      rep.editor_read_mode?.should be_true
    end
  end
end

# The wiring the engine stands on, across every editor pane: each one hands its buffer over,
# and in READ none of them answers `d` / `p` / `y` in its own `handle_body_key`, which runs
# AHEAD of the keymap. A pane that claimed one there would leave the Editor verb dead in it
# while every other pane worked, the drift `contract_editor_noop_spec` exists for.
describe "the READ-mode edit keys reach the keymap in every editor pane" do
  it "covers all eight panes" do
    seen = [] of String
    check = ->(tab : Gori::Tui::TabController, name : String) do
      tab.editor_read_mode?.should be_true, name
      tab.editor_text_buffer.should_not be_nil, name
      {'d', 'p', 'y'}.each do |c|
        tab.handle_body_key(TuiContract.plain(c)).should be_false, "#{name} claims #{c}"
        # An open Issue's detail answers ahead of the body (`Runner#handle_key`).
        if tab.is_a?(Gori::Tui::IssuesController)
          tab.handle_detail_key(TuiContract.plain(c)).should be_false, "#{name} detail claims #{c}"
        end
      end
      seen << name
      nil
    end
    TuiContract.with_session("read-edit-roster") do |session|
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

      jw = Gori::Tui::JwtController.new(host)
      check.call(jw, "jwt input")

      ck = Gori::Tui::CookieController.new(host)
      check.call(ck, "cookie input")

      store = session.store
      id = store.insert_issue("SQLi", Gori::Store::Severity::High, "a.test", nil)
      store.update_issue(id, notes: "alpha\nbravo").should be_true
      iss = Gori::Tui::IssuesController.new(host)
      iss.view.reload(store)
      iss.view.open_detail(store).should be_true
      TuiContract.render(iss)
      iss.view.focus_notes!
      check.call(iss, "issue notes")
      # Entering INSERT re-seeds an Issue's notes from the store; unchanged text is not a
      # reload, so the delete goes through rather than being refused as one.
      caret(iss, 0, 0)
      Gori::Tui::ReadEdit.delete_line(iss, sink(iss)).should eq("deleted 1 line")
      iss.editor_text_buffer.not_nil![0].text.should eq("bravo")
      # …and leaving INSERT saved it, as `esc` there does: a READ-mode `dd` is not left as
      # unsaved text for the next INSERT-and-`esc` to write.
      iss.editor_read_mode?.should be_true
      store.get_issue(id).not_nil!.notes.should eq("bravo")
    end
    seen.size.should eq(8), "exercised only #{seen.join(", ")}"
  end
end
