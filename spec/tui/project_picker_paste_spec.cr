require "../spec_helper"
require "../support/memory_backend"
require "../support/scripted_terminal"
require "file_utils"

include Gori::Tui

private alias Key = Termisu::Input::Key
private alias Mod = Termisu::Input::Modifier

# A paste at the project picker used to run as commands. The picker runs its own event loop,
# and none of the Runner's paste handling reached it: a copied ` deploy key` on a project row
# opened the action menu on the space, picked Delete on the `d` and confirmed on the `y`, and
# the project directory was gone.
#
# Driven through `run` itself, on a terminal that replays a script (ScriptedTerminal), so these
# examples go through the loop the operator's keys go through, the burst drain included.

# ^C leaves the list; esc first leaves a form that ^C does not.
private PICKER_EXIT = [Termisu::Event::Key.new(Key::LowerC, Mod::Ctrl, 'c'), Termisu::Event::Key.new(Key::Escape)] of Termisu::Event::Any

private class PastePicker < ProjectPicker
  def initialize(term : Termisu, registry : Gori::ProjectRegistry)
    super(term, registry)
    @backend = MemoryBackend.new(120, 34).as(Backend)
  end

  # Never phones home from a spec.
  private def start_update_check : Nil
  end

  def mode : Symbol
    @mode
  end

  def input : String
    @project_query.value
  end

  def new_name : String
    @name
  end

  def new_desc : String
    @desc
  end

  def flash : String?
    @flash
  end

  # The import-name prompt needs a prepared archive to reach by keys; the mode is what matters.
  def arm_import_name : Nil
    @archive_name_overlay = NamePromptOverlay.new("IMPORT PROJECT", "archive", "imported")
    @mode = :archive_import_name
  end
end

private def key_of(c : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Key.from_char(c), char: c)
end

private def pasted(text : String) : Array(ScriptedTerminal::Step)
  steps = [Termisu::Event::Key.new(Key::PasteStart)] of ScriptedTerminal::Step
  text.each_char { |c| steps << key_of(c) }
  steps << Termisu::Event::Key.new(Key::PasteEnd)
  steps
end

private def with_two_projects(&)
  root = File.tempname("gori-picker-paste")
  begin
    registry = Gori::ProjectRegistry.new(root)
    registry.create("demo")
    registry.create("staging")
    yield registry
  ensure
    FileUtils.rm_rf(root)
  end
end

private def drive(registry : Gori::ProjectRegistry, steps : Array(ScriptedTerminal::Step)) : PastePicker
  ScriptedTerminal.load(steps, PICKER_EXIT)
  picker = PastePicker.new(ScriptedTerminal.allocate, registry)
  picker.run.should be_nil
  picker
end

private def project_names(registry : Gori::ProjectRegistry) : Array(String)
  registry.list.map(&.name).sort!
end

describe "a bracketed paste at the project picker" do
  it "types into the search instead of opening the menu, picking Delete and confirming" do
    with_two_projects do |registry|
      mode, input = :none, ""
      ref = [] of PastePicker
      steps = pasted(" deploy key")
      steps << -> { mode, input = ref[0].mode, ref[0].input; nil }
      ScriptedTerminal.load(steps, PICKER_EXIT)
      picker = PastePicker.new(ScriptedTerminal.allocate, registry)
      ref << picker
      picker.run.should be_nil

      project_names(registry).should eq(["demo", "staging"])
      mode.should eq(:list)
      input.should eq(" deploy key")
    end
  end

  it "is refused by an open space menu, so a pasted letter picks no row" do
    with_two_projects do |registry|
      mode = :none
      ref = [] of PastePicker
      steps = [key_of(' ')] of ScriptedTerminal::Step
      steps += pasted("dy")
      flash = nil.as(String?)
      steps << -> { mode, flash = ref[0].mode, ref[0].flash; nil }
      ScriptedTerminal.load(steps, PICKER_EXIT)
      picker = PastePicker.new(ScriptedTerminal.allocate, registry)
      ref << picker
      picker.run.should be_nil

      project_names(registry).should eq(["demo", "staging"])
      mode.should eq(:space)
      flash.should eq(PasteGate::IGNORED)
    end
  end

  it "is not an answer to the delete confirm" do
    with_two_projects do |registry|
      mode = :none
      ref = [] of PastePicker
      steps = [Termisu::Event::Key.new(Key::LowerD, Mod::Ctrl, 'd')] of ScriptedTerminal::Step
      steps += pasted("y")
      steps << -> { mode = ref[0].mode; nil }
      ScriptedTerminal.load(steps, PICKER_EXIT)
      picker = PastePicker.new(ScriptedTerminal.allocate, registry)
      ref << picker
      picker.run.should be_nil

      project_names(registry).should eq(["demo", "staging"])
      mode.should eq(:confirm)
    end
  end

  it "takes a form field's first line and stops at the line break" do
    with_two_projects do |registry|
      ref = [] of PastePicker
      steps = [Termisu::Event::Key.new(Key::LowerN, Mod::Ctrl, 'n')] of ScriptedTerminal::Step
      steps += pasted("acme\r\nmore")
      flash = nil.as(String?)
      steps << -> { flash = ref[0].flash; nil }
      ScriptedTerminal.load(steps, PICKER_EXIT)
      picker = PastePicker.new(ScriptedTerminal.allocate, registry)
      ref << picker
      picker.run.should be_nil

      picker.new_name.should eq("acme")
      # The ↵ would have moved to the description and typed the second line there.
      picker.new_desc.should eq("")
      flash.should eq(PasteGate::LINE_BREAK)
      project_names(registry).should eq(["demo", "staging"])
    end
  end

  it "types a comma rather than opening Settings" do
    with_two_projects do |registry|
      picker = drive(registry, pasted(",x"))
      picker.input.should eq(",x")
    end
  end

  it "hands the keys back once the paste ends" do
    with_two_projects do |registry|
      mode = :none
      ref = [] of PastePicker
      steps = pasted("sta") + [Termisu::Event::Key.new(Key::Down), Termisu::Event::Key.new(Key::Space, char: ' ')] of ScriptedTerminal::Step
      steps << -> { mode = ref[0].mode; nil }
      ScriptedTerminal.load(steps, PICKER_EXIT)
      picker = PastePicker.new(ScriptedTerminal.allocate, registry)
      ref << picker
      picker.run.should be_nil
      # ↓ from the search row lands on a project row, and a pressed space opens its menu.
      mode.should eq(:space)
    end
  end

  it "retires its refusal note when the operator leaves the screen it was refused on" do
    with_two_projects do |registry|
      ref = [] of PastePicker
      seen = [] of {Symbol, String?}
      record = -> { seen << {ref[0].mode, ref[0].flash}; nil }
      steps = [Termisu::Event::Key.new(Key::Comma, Mod::Ctrl, ',')] of ScriptedTerminal::Step
      steps += pasted("\r")
      steps << Termisu::Event::Key.new(Key::Escape) # leaves Settings
      steps << record
      steps << key_of(' ') # the space menu on the project row
      steps += pasted("d")
      steps << Termisu::Event::Key.new(Key::Escape)
      steps << record
      ScriptedTerminal.load(steps, PICKER_EXIT)
      picker = PastePicker.new(ScriptedTerminal.allocate, registry)
      ref << picker
      picker.run.should be_nil

      seen.should eq([{:list, nil}, {:list, nil}])
    end
  end

  it "takes no esc from a paste over the export path card" do
    with_two_projects do |registry|
      ref = [] of PastePicker
      mode, input = :none, "?"
      steps = [key_of(' '), key_of('E')] of ScriptedTerminal::Step
      steps << Termisu::Event::Key.new(Key::PasteStart)
      steps << Termisu::Event::Key.new(Key::Escape, char: '\e')
      steps << key_of('a')
      steps << Termisu::Event::Key.new(Key::PasteEnd)
      steps << -> { mode, input = ref[0].mode, ref[0].input; nil }
      ScriptedTerminal.load(steps, PICKER_EXIT)
      picker = PastePicker.new(ScriptedTerminal.allocate, registry)
      ref << picker
      picker.run.should be_nil

      # The esc cancelled the card and the rest of the clipboard went into the search.
      mode.should eq(:archive_export_path)
      input.should eq("")
    end
  end

  it "does not quit from the import-name prompt on a pasted 0x03" do
    with_two_projects do |registry|
      ref = [] of PastePicker
      mode = :none
      steps = [-> { ref[0].arm_import_name; nil }] of ScriptedTerminal::Step
      steps << Termisu::Event::Key.new(Key::PasteStart)
      steps << Termisu::Event::Key.new(Key::LowerC, Mod::Ctrl, 'c')
      steps << key_of('x')
      steps << Termisu::Event::Key.new(Key::PasteEnd)
      steps << -> { mode = ref[0].mode; nil }
      ScriptedTerminal.load(steps, PICKER_EXIT)
      picker = PastePicker.new(ScriptedTerminal.allocate, registry)
      ref << picker
      picker.run.should be_nil

      mode.should eq(:archive_import_name)
    end
  end
end
