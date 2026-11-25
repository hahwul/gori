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
      ctl.body_hint(:body).should contain("^R forward · space cmds") # no marks: no "this"
      ctl.handle_body_key(char_key('i')).should be_false             # → keymap: editor.insert
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

private def ctrl_r : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::LowerR, Termisu::Input::Modifier::Ctrl)
end

# The decision an item got, or nil while it is still held. `reply` is a one-slot buffered
# channel, so a decided item has it waiting.
private def decision_of(it : Gori::Interceptor::Item) : Gori::Interceptor::Decision?
  select
  when d = it.reply.receive
    d
  else
    nil
  end
end

# Three holds /u1 /u2 /u3 with /u3 MARKED and the cursor back on /u2 — the loop.md #1 repro.
private def with_marked_u3(& : InterceptController, Array(Gori::Interceptor::Item), TuiContract::Host ->)
  TuiContract.with_session("intercept-editor-target") do |session|
    ic = session.interceptor
    ic.toggle
    %w[/u1 /u2 /u3].each do |path|
      ic.enqueue_request("GET #{path} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, method: "GET",
        target: path, host: "acme.test", port: 80, scheme: "http").should_not be_nil
    end
    host = TuiContract::Host.new(session)
    host.tab = :intercept
    ctl = InterceptController.new(host)
    ctl.on_enter
    items = ic.pending
    ctl.view.select_index(2)
    ctl.intercept_mark_toggle
    ctl.view.select_index(1)
    ctl.view.marked_ids.should eq([items[2].id])
    yield ctl, items, host
  end
end

# loop.md #1: `^R` inside the editor forwarded the MARKED hold and left the edited one held.
describe "InterceptController editor decisions over a mark set" do
  it "forwards the edited message from INS, with its edit, and leaves the marks held" do
    with_marked_u3 do |ctl, items, host|
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter)) # ↵ → INS on /u2
      ctl.view.text_insert?.should be_true
      ctl.view.edit_end
      ctl.handle_body_key(char_key('Z'))
      ctl.handle_body_key(ctrl_r).should be_true

      d = decision_of(items[1]).not_nil!
      d.action.should eq(Gori::Interceptor::Action::Forward)
      String.new(d.bytes).should start_with("GET /u2 HTTP/1.1Z")
      decision_of(items[2]).should be_nil          # the marked hold is still held…
      ctl.view.marked_ids.should eq([items[2].id]) # …and still marked
      host.statuses.last.should contain("/u2")
      host.statuses.last.should contain("1 marked still held")
    end
  end

  it "forwards the edited message from READ, by ^R and by the `f` verb" do
    with_marked_u3 do |ctl, items, _host|
      ctl.pane_advance(1) # → READ on /u2
      ctl.view.text_read?.should be_true
      ctl.handle_body_key(ctrl_r).should be_true
      decision_of(items[1]).not_nil!.action.should eq(Gori::Interceptor::Action::Forward)
      decision_of(items[2]).should be_nil
    end
    with_marked_u3 do |ctl, items, _host|
      ctl.pane_advance(1)
      ctl.intercept_forward # `f` in READ, the space menu and the palette all land here
      decision_of(items[1]).not_nil!.action.should eq(Gori::Interceptor::Action::Forward)
      decision_of(items[2]).should be_nil
    end
  end

  it "drops the edited message, not the marks, when drop is reached from the editor" do
    with_marked_u3 do |ctl, items, host|
      ctl.pane_advance(1)
      ctl.intercept_drop
      decision_of(items[1]).not_nil!.action.should eq(Gori::Interceptor::Action::Drop)
      decision_of(items[2]).should be_nil
      host.statuses.last.should contain("1 marked still held")
    end
  end

  it "keeps the queue's marks-else-cursor rule once the editor is closed" do
    with_marked_u3 do |ctl, items, host|
      ctl.intercept_forward # on the queue: the marks go
      decision_of(items[2]).not_nil!.action.should eq(Gori::Interceptor::Action::Forward)
      decision_of(items[1]).should be_nil
      host.statuses.last.should_not contain("still held")
    end
  end

  it "names the edited message, not the marks, in the hints, menu count and published selection" do
    with_marked_u3 do |ctl, items, _host|
      ctl.intercept_batch_count.should eq(1) # queue: the menu speaks for the batch
      ctl.pane_advance(1)
      ctl.body_hint(:body).should contain("forward this · 1 marked stay held")
      ctl.intercept_batch_count.should eq(0)
      ctl.marked_intercept_count.should eq(1) # Clear marks still has something to clear
      ctl.editor_enter_insert
      ctl.body_hint(:body).should contain("^R forward this")
      ctl.body_hint(:body).should contain("1 marked stay held")
      # At 80 columns the count drops before the forward key does.
      Chrome.fit_hints(ctl.body_hint(:body), 50).should contain("^R forward this")
      sel = JSON.parse(JSON.build { |j| ctl.write_mcp_selection(j) })
      sel["ids"].as_a.map(&.as_i64).should eq([items[1].id])
      sel["target_source"].as_s.should eq("detail")
      ctl.list_selection_ident.pinned.should eq(items[1].id)
    end
  end
end

# loop.md #5: a held request is not in History until it is forwarded, so "hold it, then work it
# in Repeater" meant forwarding first. Send flow to… → Repeater takes the hold as it stands now
# and decides nothing.
describe "InterceptController Send flow to… → Repeater seed" do
  it "carries the unforwarded edit, keeps the held bytes as the baseline, and leaves the hold alone" do
    with_held do |ctl, it, host|
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter)) # ↵ → INS
      ctl.view.edit_end
      ctl.handle_body_key(char_key('Z'))

      seed = ctl.repeater_seed(it.id).as(InterceptController::HeldSeed)
      seed.text.should eq(RAW.sub(" HTTP/1.1", " HTTP/1.1Z")) # the edit, verbatim
      seed.held.should eq(RAW)                                # what the client sent: the tab's literal baseline
      seed.target.should eq("http://acme.test")
      seed.http2.should be_false
      seed.auto_cl.should be_true

      decision_of(it).should be_nil # nothing forwarded, nothing dropped
      host.session.interceptor.get(it.id).should_not be_nil
      ctl.view.held_edit_id.should eq(it.id) # the edit is still there to forward
      ctl.view.editing?.should be_true
    end
  end

  it "takes an unedited hold byte-exact, and the editor's ^L state as the tab's auto Content-Length" do
    with_held do |ctl, it, _host|
      ctl.view.toggle_content_length_sync # ^L off: a CL the operator keeps wrong stays wrong
      seed = ctl.repeater_seed(it.id).as(InterceptController::HeldSeed)
      seed.text.should eq(RAW)
      seed.auto_cl.should be_false
    end
  end

  # The forward resolves a typed name (#1416); the seed must not, or the project value would be
  # written into another tab's buffer instead of being resolved by that tab at its own send.
  it "keeps an operator-typed $ reference unresolved, so no project value lands in the tab" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      prev = Gori::Settings.project_env_vars
      prev_prefix = Gori::Settings.env_prefix
      begin
        with_held do |ctl, it, _host|
          # Set after the session opened: opening a project loads its own (empty) vars.
          Gori::Settings.env_prefix = "$"
          Gori::Settings.project_env_vars = [{"TOKEN", "secretvalue"}]
          Gori::Env.bump_highlight_rev
          ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter))
          ctl.view.edit_end
          "?t=$ENV.TOKEN".each_char { |c| ctl.handle_body_key(char_key(c)) }
          String.new(ctl.view.forward_bytes(it)).should contain("secretvalue") # the forward resolves it
          text = ctl.repeater_seed(it.id).as(InterceptController::HeldSeed).text
          text.should contain("?t=$ENV.TOKEN")
          text.should_not contain("secretvalue")
        end
      ensure
        Gori::Settings.project_env_vars = prev
        Gori::Settings.env_prefix = prev_prefix
        Gori::Env.bump_highlight_rev
      end
    end
  end

  it "reads the transport off the hold's provenance, not off the version token" do
    TuiContract.with_session("intercept-seed-h2") do |session|
      ic = session.interceptor
      ic.toggle
      h2 = ic.enqueue_request("GET /a HTTP/2\r\nHost: acme.test\r\n\r\n".to_slice, method: "GET",
        target: "/a", host: "acme.test", port: 443, scheme: "https", http2: true).not_nil!
      h1 = ic.enqueue_request("GET /b HTTP/2\r\nHost: acme.test\r\n\r\n".to_slice, method: "GET",
        target: "/b", host: "acme.test", port: 8443, scheme: "https").not_nil!
      host = TuiContract::Host.new(session)
      ctl = InterceptController.new(host)
      ctl.on_enter
      ctl.repeater_seed(h2.id).as(InterceptController::HeldSeed).http2.should be_true
      h1_seed = ctl.repeater_seed(h1.id).as(InterceptController::HeldSeed)
      h1_seed.http2.should be_false # an h1 client's `HTTP/2` is its payload, not the transport
      h1_seed.target.should eq("https://acme.test:8443")
    end
  end

  it "sends a held response's recorded request, and refuses what a Repeater tab cannot hold" do
    TuiContract.with_session("intercept-seed-kinds") do |session|
      ic = session.interceptor
      ic.toggle
      res = ic.enqueue_response("HTTP/1.1 200 OK\r\n\r\n".to_slice, flow_id: 42_i64, method: "GET",
        target: "200 OK", host: "acme.test", port: 80, scheme: "http", request_target: "/r").not_nil!
      streaming = ic.enqueue_response("HTTP/2 200\r\n\r\n".to_slice, flow_id: nil, method: "GET",
        target: "200", host: "acme.test", port: 443, scheme: "https", http2: true).not_nil!
      ws = ic.enqueue_ws("hi".to_slice, to_server: true, method: "GET", target: "/ws",
        host: "acme.test", port: 80, scheme: "http", flow_id: 7_i64, binary: false).not_nil!
      ctl = InterceptController.new(TuiContract::Host.new(session))
      ctl.on_enter
      ctl.repeater_seed(res.id).should eq(42_i64)
      ctl.repeater_seed(streaming.id).as(String).should contain("not recorded yet")
      ctl.repeater_seed(ws.id).as(String).should contain("WebSocket message, not a request")
      ctl.repeater_seed(999_i64).should eq("that message is no longer held")
      [res, streaming, ws].each { |held| decision_of(held).should be_nil }
    end
  end
end
