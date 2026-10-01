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
