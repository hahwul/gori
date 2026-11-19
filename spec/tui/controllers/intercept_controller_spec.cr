require "../../support/tui_contract"
require "../../support/tui_probes"

include Gori::Tui

private RAW = "GET /api/x HTTP/1.1\r\nHost: acme.test\r\n\r\n"

private def char_key(c : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::Unknown, char: c)
end

private def with_held(& : InterceptController, Gori::Interceptor::Item, TuiContract::Host ->)
  TuiContract.with_session("intercept-read") do |session|
    ic = session.interceptor
    ic.toggle
    ic.enqueue_request(RAW.to_slice, method: "GET", target: "/api/x", host: "acme.test",
      port: 80, scheme: "http").should_not be_nil
    host = TuiContract::Host.new(session)
    host.tab = :intercept
    ctl = InterceptController.new(host)
    ctl.on_enter
    yield ctl, ctl.view.selected_item.not_nil!, host
  end
end

describe InterceptController do
  # A first-time walkthrough: ⇥ into REQUEST (held), press `i` as the tour and the Repeater
  # teach, and the buffer read `iGET /api/...` — the editor had opened in INS.
  it "opens the held-message editor in READ from the focus ring, where a letter is not typed" do
    with_held do |ctl, it|
      ctl.pane_advance(1).should be_true
      ctl.view.text_read?.should be_true
      ctl.editor_pane?.should be_true
      ctl.editor_read_mode?.should be_true
      ctl.body_takes_text?.should be_false
      ctl.body_hint(:body).should_not contain("type to edit")
      ctl.body_hint(:body).should contain("esc queue")
      ctl.handle_body_key(char_key('i')).should be_false # → keymap: editor.insert
      String.new(ctl.view.forward_bytes(it)).should eq(RAW)
    end
  end

  it "enters INS through the editor seam, and esc steps INS → READ → queue" do
    with_held do |ctl, it|
      ctl.pane_advance(1)
      ctl.editor_enter_insert.should be_true
      ctl.view.text_insert?.should be_true
      ctl.body_takes_text?.should be_true
      ctl.body_hint(:body).should start_with("type ·")
      ctl.handle_body_key(char_key('X')).should be_true
      String.new(ctl.view.forward_bytes(it)).should start_with("XGET /api/x")

      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape))
      ctl.view.text_read?.should be_true
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape))
      ctl.view.editing?.should be_false
    end
  end

  it "keeps ↵ / e on the queue as the direct way to edit" do
    with_held do |ctl, _it|
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter)).should be_true
      ctl.view.text_insert?.should be_true
    end
  end

  it "moves the READ caret without dirtying the hold" do
    with_held do |ctl, it|
      ctl.pane_advance(1)
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Down)).should be_true
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Right)).should be_true
      ctl.view.held_edit_id.should be_nil
      String.new(ctl.view.forward_bytes(it)).should eq(RAW)
    end
  end

  # READ edits replay through the pane's own INS path (`ReadEdit`), so the hold is marked edited
  # and the forward carries the edit — the same dirty tracking typing gets.
  it "applies a READ-mode line delete as an edit of the hold" do
    with_held do |ctl, it, _host|
      ctl.pane_advance(1)
      ctl.view.read_move(1, 0) # the Host line
      key_in = ->(ev : Termisu::Event::Key) { ctl.handle_body_key(ev); nil }
      ReadEdit.delete_line(ctl, key_in)
      ctl.view.held_edit_id.should eq(it.id)
      String.new(ctl.view.forward_bytes(it)).should_not contain("Host:")
    end
  end

  it "says a status: condition holds nothing while catch holds requests only" do
    with_held do |ctl, _it, host|
      ctl.intercept_query
      # Past the term, where the completion row (which outranks it) has nothing to offer.
      "status:500 ".each_char { |ch| ctl.handle_query_key(char_key(ch)) }
      TuiContract.render(ctl).contains?("only matches responses").should be_true
      ctl.handle_query_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter))
      host.statuses.last.should contain("`status:` only matches responses")

      ctl.intercept_cycle_direction # → responses: the note is gone
      host.statuses.last.should eq("intercept catch: responses only")
      ctl.intercept_cycle_direction # → all
      ctl.intercept_cycle_direction # → back to requests only: said again
      host.statuses.last.should contain("`status:` only matches responses")
    end
  end

  it "badges the open editor with its real mode, and the closed one with `e`" do
    with_held do |ctl, _it|
      backend = TuiContract.render(ctl)
      backend.contains?(" EDIT ").should be_true
      ctl.pane_advance(1)
      backend = TuiContract.render(ctl)
      backend.contains?(Frame.mode_badge_label(false).strip).should be_true
      backend.contains?(" EDIT ").should be_false
      ctl.editor_enter_insert
      TuiContract.render(ctl).contains?(Frame.mode_badge_label(true)).should be_true
    end
  end
end

private POST_RAW = "POST /api/x HTTP/1.1\r\nHost: acme.test\r\nContent-Length: 2\r\n\r\nhi"

# An Intercept INS editor holding POST_RAW, caret at the end of the body.
private def with_held_post(& : InterceptController, Gori::Interceptor::Item ->)
  TuiContract.with_session("intercept-paste") do |session|
    ic = session.interceptor
    ic.toggle
    ic.enqueue_request(POST_RAW.to_slice, method: "POST", target: "/api/x", host: "acme.test",
      port: 80, scheme: "http").should_not be_nil
    ctl = InterceptController.new(TuiContract::Host.new(session).tap(&.tab=(:intercept)))
    ctl.on_enter
    ctl.pane_advance(1)
    ctl.editor_enter_insert
    5.times { ctl.view.edit_move(1, 0) }
    ctl.view.edit_end
    yield ctl, ctl.view.selected_item.not_nil!
  end
end

# A paste into the held request is one edit with one Content-Length reflection (typed, it
# was one whole-buffer reflection per character), and it forwards what typing it would.
describe "InterceptController bulk paste" do
  pasted = "&a=1\n\tb=22 é"

  it "forwards the bytes and the Content-Length that typing the paste would" do
    typed = ""
    with_held_post do |ctl, it|
      pasted.each_char do |c|
        ev = c == '\n' ? Termisu::Event::Key.new(Termisu::Input::Key::Enter) : char_key(c)
        c == '\t' ? ctl.handle_editor_tab(Termisu::Event::Key.new(Termisu::Input::Key::Tab)) : ctl.handle_body_key(ev)
      end
      typed = String.new(ctl.view.forward_bytes(it))
    end
    with_held_post do |ctl, it|
      ctl.accepts_bulk_paste?.should be_true
      ctl.paste_text(pasted).should be_true
      String.new(ctl.view.forward_bytes(it)).should eq(typed)
      typed.should contain("Content-Length: #{("hi" + pasted).bytesize}\r\n")
      ctl.view.edit_undo # one step undoes the whole paste, Content-Length with it
      String.new(ctl.view.forward_bytes(it)).should eq(POST_RAW)
    end
  end

  it "is the TEXT editor in INS only" do
    with_held_post do |ctl, it|
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)) # INS → READ
      ctl.accepts_bulk_paste?.should be_false
      ctl.paste_text("x").should be_false
      String.new(ctl.view.forward_bytes(it)).should eq(POST_RAW)
    end
  end
end
