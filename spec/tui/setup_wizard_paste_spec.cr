require "../spec_helper"
require "../support/memory_backend"
require "../support/scripted_terminal"

include Gori::Tui

private alias Key = Termisu::Input::Key

# The setup wizard runs its own event loop too, and a paste reached it as keystrokes: each
# pasted line break is a ↵, which moves BIND from the IP to the port and then on through the
# steps, and ↵ on REVIEW is `finish`, which persists the bind address.
private class PasteWizard < SetupWizard
  getter? finished = false

  def initialize(term : Termisu, *, port : Int32 = 0)
    super(term)
    # The ordinary wizard specs should reach Appearance regardless of local listeners.
    @ip = "127.0.0.1"
    @port = port.to_s
    @cursor = @ip.size
    @backend = MemoryBackend.new(120, 40).as(Backend)
  end

  def step_name : String
    @step.to_s
  end

  def ip : String
    @ip
  end

  def status : String?
    @status
  end

  # Neither touches settings.json from a spec: recorded, and the loop ends.
  private def finish : Nil
    @finished = true
    @running = false
  end

  private def skip : Nil
    @running = false
  end
end

private def pasted(text : String) : Array(ScriptedTerminal::Step)
  steps = [Termisu::Event::Key.new(Key::PasteStart)] of ScriptedTerminal::Step
  text.each_char { |c| steps << Termisu::Event::Key.new(Key.from_char(c), char: c) }
  steps << Termisu::Event::Key.new(Key::PasteEnd)
  steps
end

# Two esc presses skip the wizard (see SetupWizard#handle_escape).
private WIZARD_EXIT = [Termisu::Event::Key.new(Key::Escape)] of Termisu::Event::Any

describe "a bracketed paste at the setup wizard" do
  it "types into the BIND field and never walks the steps to finish" do
    ref = [] of PasteWizard
    step, ip, status = "", "", nil.as(String?)
    steps = pasted("0.0.0.0\r\n\r\n\r\n\r\n\r\n")
    steps << -> { w = ref[0]; step, ip, status = w.step_name, w.ip, w.status; nil }
    ScriptedTerminal.load(steps, WIZARD_EXIT)
    wizard = PasteWizard.new(ScriptedTerminal.allocate)
    ref << wizard
    before = wizard.ip
    wizard.run

    wizard.finished?.should be_false
    step.should eq("Bind")
    ip.should eq(before + "0.0.0.0")
    status.should eq(PasteGate::LINE_BREAK)
  end

  it "refuses a paste on a step that only takes choices" do
    ref = [] of PasteWizard
    step = ""
    # ↵ ↵ (pressed) reach Appearance; the paste must not press on to Review and finish.
    steps = [Termisu::Event::Key.new(Key::Enter, char: '\r'), Termisu::Event::Key.new(Key::Enter, char: '\r')] of ScriptedTerminal::Step
    steps += pasted("\r\r\r")
    steps << -> { step = ref[0].step_name; nil }
    ScriptedTerminal.load(steps, WIZARD_EXIT)
    wizard = PasteWizard.new(ScriptedTerminal.allocate)
    ref << wizard
    wizard.run

    wizard.finished?.should be_false
    step.should eq("Appearance")
  end

  it "drops its note when the caret moves on to the next field" do
    ref = [] of PasteWizard
    status = "?".as(String?)
    steps = pasted("10.0.0.1\r")
    steps << Termisu::Event::Key.new(Key::Enter, char: '\r') # pressed: IP → Port
    steps << -> { status = ref[0].status; nil }
    ScriptedTerminal.load(steps, WIZARD_EXIT)
    wizard = PasteWizard.new(ScriptedTerminal.allocate)
    ref << wizard
    wizard.run

    status.should be_nil
  end

  it "never hides an armed busy-port warning" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    begin
      ref = [] of PasteWizard
      status = nil.as(String?)
      # ↵ ↵ pressed: to the port, then the busy warning that the next ↵ would answer.
      steps = [Termisu::Event::Key.new(Key::Enter, char: '\r'), Termisu::Event::Key.new(Key::Enter, char: '\r')] of ScriptedTerminal::Step
      steps += pasted("\r")
      steps << -> { status = ref[0].status; nil }
      ScriptedTerminal.load(steps, WIZARD_EXIT)
      wizard = PasteWizard.new(ScriptedTerminal.allocate, port: port)
      ref << wizard
      wizard.run

      status.should eq("port #{port} busy · ↵ keep")
    ensure
      server.close
    end
  end
end
