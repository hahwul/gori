require "../spec_helper"
require "../support/memory_backend"
require "../support/scripted_terminal"

include Gori::Tui

private alias Key = Termisu::Input::Key
private alias Mod = Termisu::Input::Modifier

# The tour runs its own event loop as well. It teaches the app, so it takes a paste the way the
# app does; before, a paste stepped the lessons on its own letters (`n` is next).
private class PasteTour < Tutorial
  def initialize(term : Termisu)
    super(term)
    @backend = MemoryBackend.new(120, 40).as(Backend)
  end

  def step_name : String
    @step.to_s
  end
end

private TOUR_EXIT = [Termisu::Event::Key.new(Key::LowerC, Mod::Ctrl, 'c')] of Termisu::Event::Any

describe "a bracketed paste in the tour" do
  it "does not step the lessons on its letters" do
    ref = [] of PasteTour
    step = ""
    steps = [Termisu::Event::Key.new(Key::PasteStart)] of ScriptedTerminal::Step
    "nnn".each_char { |c| steps << Termisu::Event::Key.new(Key.from_char(c), char: c) }
    steps << Termisu::Event::Key.new(Key::PasteEnd)
    steps << -> { step = ref[0].step_name; nil }
    ScriptedTerminal.load(steps, TOUR_EXIT)
    tour = PasteTour.new(ScriptedTerminal.allocate)
    ref << tour
    tour.run
    step.should eq("Welcome")
  end
end
