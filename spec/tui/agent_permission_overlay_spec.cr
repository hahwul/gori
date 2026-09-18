require "../spec_helper"
require "../support/overlay_harness"
require "../support/memory_backend"
require "../../src/gori/tui/agent_permission_overlay"

private alias Ev = Gori::Agent::Event
private alias Decision = Gori::Agent::Decision
private alias K = Termisu::Input::Key

private def request(input = %({"command":"mkdir -p /tmp/x && ls -d /tmp/x","description":"d"}))
  Ev::PermissionAsked.new("req-1", "Bash", "Bash", input, "Create directory and list it",
    "no rule matched", "toolu_1")
end

private def render(ov : Gori::Tui::AgentPermissionOverlay, width = 100, height = 30) : String
  backend = MemoryBackend.new(width, height)
  ov.render(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, width, height))
  (0...height).map { |y| backend.row(y) }.join('\n')
end

describe Gori::Tui::AgentPermissionOverlay do
  it "answers on the mnemonic keys, and on the selected button under enter" do
    {K::LowerA => Decision::Allow, K::LowerS => Decision::AllowForSession, K::LowerD => Decision::Deny}.each do |key, want|
      ov = Gori::Tui::AgentPermissionOverlay.new(request)
      h = OverlayHarness.new(ov)
      h.press(key).should eq(:closed)
      ov.answered.should eq(want)
      h.commits.should eq(1)
    end
    ov = Gori::Tui::AgentPermissionOverlay.new(request)
    h = OverlayHarness.new(ov)
    h.press(K::Enter).should eq(:closed)
    ov.answered.should eq(Decision::Deny) # the safe default
    ov = Gori::Tui::AgentPermissionOverlay.new(request)
    h = OverlayHarness.new(ov)
    h.press(K::Left) # deny → allow for session
    h.press(K::Left) # → allow
    h.press(K::Enter)
    ov.answered.should eq(Decision::Allow)
  end

  it "treats esc and click-away as deny, never as decide-later" do
    ov = Gori::Tui::AgentPermissionOverlay.new(request)
    h = OverlayHarness.new(ov)
    h.press(K::Escape).should eq(:closed)
    ov.answered.should eq(Decision::Deny)
    ov = Gori::Tui::AgentPermissionOverlay.new(request)
    h = OverlayHarness.new(ov)
    h.click(0, 0).should eq(:closed)
    ov.answered.should eq(Decision::Deny)
  end

  it "refuses a modified mnemonic and a pasted key" do
    ov = Gori::Tui::AgentPermissionOverlay.new(request)
    h = OverlayHarness.new(ov)
    h.press(K::LowerA, ctrl: true).should eq(:open)
    ov.answered.should be_nil
    ov.takes_pasted?(Termisu::Event::Key.new(K::LowerA)).should be_false
  end

  it "draws the command, the description, the reason and three buttons" do
    text = render(Gori::Tui::AgentPermissionOverlay.new(request))
    text.should contain("BASH WANTS TO RUN")
    text.should contain("mkdir -p /tmp/x && ls -d /tmp/x")
    text.should contain("Create directory and list it")
    text.should contain("asked because: no rule matched")
    text.should contain("[a] allow")
    text.should contain("[s] allow for session")
    text.should contain("[d] deny")
    text.should contain("for this session only")
  end

  it "shows a single-field input by its name and pretty-prints the rest" do
    render(Gori::Tui::AgentPermissionOverlay.new(request(%({"file_path":"/etc/hosts"})))).should contain("file_path: /etc/hosts")
    render(Gori::Tui::AgentPermissionOverlay.new(request(%({"a":1,"b":"two"})))).should contain(%("b": "two"))
    render(Gori::Tui::AgentPermissionOverlay.new(request("{garbage"))).should contain("{garbage")
  end

  it "clicks a button" do
    ov = Gori::Tui::AgentPermissionOverlay.new(request)
    h = OverlayHarness.new(ov)
    box = ov.overlay_box(h.area).not_nil!
    allow = ov.button_rects(box)[0]
    h.click(allow.x + 1, allow.y).should eq(:closed)
    ov.answered.should eq(Decision::Allow)
  end

  it "declines to draw or answer in an area too small for the buttons" do
    ov = Gori::Tui::AgentPermissionOverlay.new(request)
    ov.overlay_box(Gori::Tui::Rect.new(0, 0, 30, 5)).should be_nil
    render(ov, 30, 5)
    h = OverlayHarness.new(ov, area: Gori::Tui::Rect.new(0, 0, 30, 5))
    h.press(K::LowerA).should eq(:open)
    ov.answered.should be_nil
  end
end
