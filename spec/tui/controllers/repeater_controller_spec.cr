require "../../spec_helper"
require "../../support/fake_host"
require "../../support/fake_context"

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
    v.hex_move(1000, 0)
    v.hex_set_nibble('4')
    v.hex_set_nibble('5')
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
