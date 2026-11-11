require "../spec_helper"

private alias Picker = Gori::Tui::ProjectPicker
private alias Key = Termisu::Input::Key
private alias Mod = Termisu::Input::Modifier

private def key(k : Key, mods : Mod = Mod::None, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

describe "ProjectPicker.settings_key?" do
  it "is ctrl-comma, whatever the search holds" do
    Picker.settings_key?(key(Key::Comma, Mod::Ctrl), "").should be_true
    Picker.settings_key?(key(Key::Comma, Mod::Ctrl), "api").should be_true
  end

  # tmux with extended-keys off delivers Ctrl+comma as a bare comma.
  it "takes a bare comma on an empty search" do
    Picker.settings_key?(key(Key::Comma, Mod::None, ','), "").should be_true
  end

  it "leaves a comma inside a search as text" do
    Picker.settings_key?(key(Key::Comma, Mod::None, ','), "a").should be_false
  end

  # A terminal that reports modifiers on text keys sends Shift+comma as this key with `<`.
  it "takes no modified comma but ctrl's" do
    Picker.settings_key?(key(Key::Comma, Mod::Shift, '<'), "").should be_false
    Picker.settings_key?(key(Key::Comma, Mod::Meta, ','), "").should be_false
    Picker.settings_key?(key(Key::Comma, Mod::Alt, ','), "").should be_false
  end

  it "is no other key" do
    Picker.settings_key?(key(Key::Period, Mod::None, '.'), "").should be_false
    Picker.settings_key?(key(Key::LowerS, Mod::Ctrl), "").should be_false
  end

  # The picker holds a live Termisu and cannot be built here, so the order of its key ladder
  # is read off the source: below the printable arm, the bare comma is typed into the search.
  it "is asked before a printable key is typed into the search" do
    source = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "project_picker.cr"))
      .lines.reject(&.lstrip.starts_with?('#')).join('\n')
    ladder = source[/private def handle_list\b.*?\n    end/m].not_nil!
    asked = ladder.index("ProjectPicker.settings_key?(ev, @query)").not_nil!
    asked.should be < ladder.index("LineEdit.typed_char(ev)").not_nil!
  end
end
