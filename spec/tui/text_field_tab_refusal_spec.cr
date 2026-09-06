require "../spec_helper"

include Gori::Tui

# `Key::Tab.to_char` is '\t' and `Event::Key#char` falls back to it, so a card that handed
# every printable to its field typed a TAB into a project name, a library entry, an env
# prefix. The field refuses the key (returns false) so the card can move focus with it.
describe "TextField and ⇥" do
  it "never types a tab, and declines the key so the owner can route it" do
    f = TextField.new("abc")
    f.handle_edit_key(Termisu::Event::Key.new(Termisu::Input::Key::Tab)).should be_false
    f.handle_edit_key(Termisu::Event::Key.new(Termisu::Input::Key::BackTab)).should be_false
    f.value.should eq("abc")
    f.handle_edit_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerD, Termisu::Input::Modifier::None, 'd')).should be_true
    f.value.should eq("abcd")
  end
end
