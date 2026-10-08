require "../../spec_helper"
require "../../support/fake_host"
require "../../support/fake_context"
require "../../support/memory_backend"

include Gori::Tui

# RepeaterController — `^X` is the hex of the pane that has focus (#1295). The request pane
# hex-edits; the response pane toggles the hex dump, the same toggle Display…'s `Z x` runs
# there, so the one chord answers both panes and both routes refuse a transcript alike.

private REPEATER_CTL_CA = File.tempname("gori-repeater-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(REPEATER_CTL_CA) }

private def with_repeater_controller(&)
  root = File.tempname("gori-repeater-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("repeater")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(REPEATER_CTL_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield RepeaterController.new(host), host
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private HTTP_REQ = "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n"
private WS_REQ   = "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

describe "RepeaterController ^X (#1295)" do
  it "resolves ^X to the pane-aware hex verb in both panes" do
    reg = Gori::Verbs.registry
    km = Gori::Verb::Keymap.build(reg)
    ctx = FakeExecContext.new
    ctx.current_tab = :repeater
    {:request, :response}.each do |sec|
      ctx.focused_section = sec
      km.resolve(Gori::Verb::Chord.new("x", ctrl: true), Gori::Verb::Scope::Repeater, reg, ctx)
        .should eq("repeater.toggle-hex"), sec.to_s
    end
  end

  it "hex-edits the request in the request pane and dumps the response in the response pane" do
    with_repeater_controller do |ctl, _|
      ctl.repeater_from_request("https://h.test", HTTP_REQ, false, nil)
      v = ctl.current_view.not_nil!
      v.focus.should eq(:request)
      ctl.repeater_toggle_hex
      v.request_hex?.should be_true
      v.resp_hex?.should be_false
      ctl.repeater_toggle_hex # off again

      v.focus_pane(:response)
      ctl.repeater_toggle_hex
      v.resp_hex?.should be_true
      v.request_hex?.should be_false
      # …and `Z x` there is the same toggle.
      ctl.repeater_toggle_resp_hex
      v.resp_hex?.should be_false
    end
  end

  it "refuses the dump on a transcript from either route" do
    with_repeater_controller do |ctl, host|
      ctl.repeater_from_request("https://ws.test", WS_REQ, false, nil)
      v = ctl.current_view.not_nil!
      v.ws_mode?.should be_true
      v.focus_pane(:response)
      ctl.repeater_toggle_hex
      ctl.repeater_toggle_resp_hex
      v.resp_hex?.should be_false
      host.statuses.last(2).each(&.should(contain("no hex dump for a WebSocket transcript")))
    end
  end
end

# #1426: the auto-CL resync on the way out of hex is named in the toast, from `^X` and from
# `esc` alike — the resync redraws one digit, and a mismatch built in hex is corrected by it.
describe "RepeaterController leaving request hex (#1426)" do
  bodied = "POST /b HTTP/1.1\r\nHost: h.test\r\nContent-Length: 4\r\n\r\nABCD"
  grow = ->(v : RepeaterView) do
    8.times { v.hex_key(hex_ev(Termisu::Input::Key::Down)) } # ↓ clamps at the append slot
    v.hex_key(hex_ev('4'))
    v.hex_key(hex_ev('5'))
  end

  it "names the resynced Content-Length on ^X" do
    with_repeater_controller do |ctl, host|
      ctl.repeater_from_request("https://h.test", bodied, false, nil)
      v = ctl.current_view.not_nil!
      ctl.repeater_toggle_hex
      grow.call(v)
      ctl.repeater_toggle_hex
      host.statuses.last.should contain("hex edit: off — Content-Length 4 → 5")
    end
  end

  it "names it on esc, the exit that used to say nothing" do
    with_repeater_controller do |ctl, host|
      ctl.repeater_from_request("https://h.test", bodied, false, nil)
      v = ctl.current_view.not_nil!
      ctl.repeater_toggle_hex
      grow.call(v)
      n = host.statuses.size
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape, Termisu::Input::Modifier::None))
      v.request_hex?.should be_false
      host.statuses.size.should eq(n + 1)
      host.statuses.last.should contain("Content-Length 4 → 5")
    end
  end

  it "keeps the plain toast for an exit that left the length alone" do
    with_repeater_controller do |ctl, host|
      ctl.repeater_from_request("https://h.test", bodied, false, nil)
      ctl.repeater_toggle_hex
      ctl.repeater_toggle_hex
      host.statuses.last.should eq("hex edit: off")
    end
  end
end

# #1421: a pane the last frame did not draw takes no keystrokes. On a body too short for even
# the TARGET card there is no pane to move focus to, so the controller swallows the keys.
describe "RepeaterController on a body too short for its panes (#1421)" do
  it "does not type into a request editor the frame did not draw" do
    with_repeater_controller do |ctl, _|
      ctl.repeater_from_request("https://h.test", HTTP_REQ, false, nil)
      v = ctl.current_view.not_nil!
      v.focus.should eq(:request)
      v.enter_request_insert!
      v.render(Screen.new(MemoryBackend.new(100, 1)), Rect.new(0, 0, 100, 1))
      before = v.request_text
      "ZZZ".each_char { |c| ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::UpperZ, char: c)) }
      v.request_text.should eq(before)
      ctl.accepts_bulk_paste?.should be_false # a paste replays key by key, into the gate
    end
  end

  it "still lets READ keys out of a pane the frame did not draw" do
    with_repeater_controller do |ctl, host|
      ctl.repeater_from_request("https://h.test", HTTP_REQ, false, nil)
      v = ctl.current_view.not_nil!
      v.focus_pane(:target)
      v.render(Screen.new(MemoryBackend.new(100, 1)), Rect.new(0, 0, 100, 1))
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Up))
      host.focus_requests.should_not be_empty # ↑ left for the strip, not swallowed
    end
  end
end

# A response of numbered body lines, applied, focused and drawn once — the draw is what
# publishes the pane height every caret-following path reads.
private def jump_view(ctl : RepeaterController, body : String, rect : Rect) : RepeaterView
  ctl.repeater_from_request("https://h.test", HTTP_REQ, false, nil)
  v = ctl.current_view.not_nil!
  v.focus_pane(:response)
  hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
  v.apply(Gori::Repeater::Result.new(hdr.to_slice, body.to_slice, nil, 1000_i64))
  v.render(Screen.new(MemoryBackend.new(rect.w, rect.h)), rect)
  v
end

private def numbered_body(n : Int32) : String
  (1..n).map { |i| "L%03d" % i }.join("\n")
end

private def mod_key(key : Termisu::Input::Key, *, shift : Bool = false, alt : Bool = false) : Termisu::Event::Key
  mods = alt ? Termisu::Input::Modifier::Alt : Termisu::Input::Modifier::Ctrl
  mods |= Termisu::Input::Modifier::Shift if shift
  Termisu::Event::Key.new(key, mods, nil)
end

private def drawn(v : RepeaterView, rect : Rect) : MemoryBackend
  b = MemoryBackend.new(rect.w, rect.h)
  v.render(Screen.new(b), rect)
  b
end

# ⌃Home/⌃End and ⌃PgUp/⌃PgDn on the response's text used to defer with every other modified
# chord and reach `body_scroll`, which moved the viewport alone: ⌃End drew the last line at
# the TOP with blanks below, and the next ↓ — stepping from the caret still on line 1 —
# snapped back to line 2 (#1425). Driven through `handle_body_key`, the route the key takes.
describe "RepeaterController ⌃Home/⌃End on the response (#1425)" do
  it "takes the caret to the last line with that line on the pane's bottom row" do
    with_repeater_controller do |ctl, _|
      rect = Rect.new(0, 0, 80, 20)
      v = jump_view(ctl, numbered_body(60), rect)
      size, line_at = v.resp_line_source
      last = size - 1

      ctl.handle_body_key(mod_key(Termisu::Input::Key::End)).should be_true
      v.resp_cursor.cy.should eq(last)
      v.resp_cursor.cx.should eq(line_at.call(last).size) # the buffer's end, as in the request editor

      b = drawn(v, rect)
      y = (0...rect.h).find { |r| b.row(r).includes?("L060") }.not_nil!
      b.row(y + 1).should contain("╰") # the pane's bottom row, not the top with blanks below
      b.row(y - 1).should contain("L059")

      v.resp_move(1, 0) # the next arrow stays at the end instead of snapping to line 2
      v.resp_cursor.cy.should eq(last)
    end
  end

  it "takes the caret to the first line's start, and ⌥ is the same key" do
    with_repeater_controller do |ctl, _|
      rect = Rect.new(0, 0, 80, 20)
      v = jump_view(ctl, numbered_body(60), rect)
      v.resp_move(40, 0) # caret mid-body, the view scrolled after it
      drawn(v, rect).contains?("HTTP/1.1 200 OK").should be_false
      ctl.handle_body_key(mod_key(Termisu::Input::Key::Home, alt: true)).should be_true
      v.resp_cursor.cy.should eq(0)
      v.resp_cursor.cx.should eq(0)
      drawn(v, rect).contains?("HTTP/1.1 200 OK").should be_true # and the view came back up
    end
  end

  it "lands on the last visual row of a wrapped last line" do
    with_repeater_controller do |ctl, _|
      rect = Rect.new(0, 0, 80, 20)
      v = jump_view(ctl, "#{numbered_body(40)}\nHEAD#{"." * 200}TAIL", rect)
      ctl.handle_body_key(mod_key(Termisu::Input::Key::End)).should be_true
      b = drawn(v, rect)
      y = (0...rect.h).find { |r| b.row(r).includes?("TAIL") }.not_nil!
      b.row(y + 1).should contain("╰")
    end
  end

  # ⇧ extends, as ⇧Home/⇧End and ⇧PgDn do: the selection the operator built survives.
  it "extends the selection under ⇧" do
    with_repeater_controller do |ctl, _|
      rect = Rect.new(0, 0, 80, 20)
      v = jump_view(ctl, numbered_body(60), rect)
      v.resp_move(5, 0)
      v.resp_move(1, 0, selecting: true)
      ctl.handle_body_key(mod_key(Termisu::Input::Key::End, shift: true)).should be_true
      v.resp_cursor.selection?.should be_true
      v.resp_copy_text.should end_with("L060")
      ctl.handle_body_key(mod_key(Termisu::Input::Key::PageUp, shift: true)).should be_true
      v.resp_cursor.selection?.should be_true

      ctl.handle_body_key(mod_key(Termisu::Input::Key::Home)).should be_true
      v.resp_cursor.selection?.should be_false # unshifted, a jump drops it
    end
  end

  it "pages the caret by the pane's own page, as the bare key does" do
    with_repeater_controller do |ctl, _|
      rect = Rect.new(0, 0, 80, 20)
      v = jump_view(ctl, numbered_body(60), rect)
      ctl.handle_body_key(mod_key(Termisu::Input::Key::PageDown)).should be_true
      v.resp_cursor.cy.should eq(v.resp_page_rows)
    end
  end

  # The hex dump has no caret: the modified key is not claimed, and the shell's ±JUMP_ROWS
  # reaches `body_scroll`, which jumps the dump.
  it "leaves the hex dump to the shell's buffer jump" do
    with_repeater_controller do |ctl, _|
      rect = Rect.new(0, 0, 80, 20)
      v = jump_view(ctl, numbered_body(60), rect)
      v.toggle_resp_hex
      ctl.handle_body_key(mod_key(Termisu::Input::Key::End)).should be_false
      v.at_top?.should be_true
      ctl.body_scroll(Runner::JUMP_ROWS).should be_true
      v.at_top?.should be_false
    end
  end
end

describe "RepeaterController race / timing members" do
  # The plan takes the ANCHOR tab's provenance (`evidence:` + literal set), so a captured tab
  # marked beside a hand-written draft was sent under the other's rules — its capture
  # `$BIND`-expanded, or the draft's tokens sent literally. A mixed group is refused instead.
  it "refuses a group that mixes a captured tab with a draft" do
    root = File.tempname("gori-repeater-ctl")
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("repeater")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(REPEATER_CTL_CA), Gori::Verbs.registry, project)
    begin
      req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice
      session.store.insert_repeater("http://127.0.0.1:1/", req, false, true, 1_i64, 0) # captured
      session.store.insert_repeater("http://127.0.0.1:1/", req, false, true, nil, 1)   # draft
      host = FakeHost.new(session)
      ctl = RepeaterController.new(host)
      ctl.toggle_subtab_mark(0)
      ctl.toggle_subtab_mark(1)

      ctl.prepare_timing_pair.should be_nil
      host.statuses.last.should contain("provenance")
      ctl.repeater_send_race
      host.statuses.last.should contain("provenance")
    ensure
      session.try(&.close)
      FileUtils.rm_rf(root) if Dir.exists?(root)
    end
  end
end
