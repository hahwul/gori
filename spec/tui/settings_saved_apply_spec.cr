require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# What `Runner#apply_settings_saved` and `#confirm_preferences_reset` do after a settings save.
# `Runner` owns a terminal and is never constructed under spec/, so its half is read from source
# the way spec/tui/digit_family_spec.cr reads the dispatch order — one method body at a time,
# comment lines dropped, so a sentence ABOUT the call cannot stand in for the call.
private def runner_method(name : String) : String
  src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
  start = src.index(/^    (private )?def #{Regex.escape(name)}\b/m).not_nil!
  stop = src.index(/^    end$/m, start).not_nil!
  src[start...stop].lines.reject(&.lstrip.starts_with?("#")).join("\n")
end

describe "settings save → live apply" do
  # The editor keyset is baked into the keymap when it is built. The Keys section's save only
  # reloaded Help, so the hints advertised the new keyset while dispatch answered the old one
  # until a restart.
  it "rebuilds the keymap when the Keys section is saved" do
    runner_method("apply_keys").should contain("@keymap = Hotkeys.build_keymap(")
  end

  # `@pretty` is also the session's own `p` toggle; re-reading the default after EVERY section's
  # save (a retention edit, a network edit) flipped the operator's toggle back.
  it "re-applies the pretty-bodies default only when it moved" do
    runner_method("apply_settings_saved").should_not contain("@pretty = ")
    body = runner_method("apply_pretty_default")
    body.should contain("return if Settings.pretty_bodies_default == @pretty_default")
  end

  # The three opener resets touch no value a form holds; reloading every form threw away an
  # unsaved edit typed into another section before the ^R.
  it "re-pulls every form only for the factory reset" do
    body = runner_method("confirm_preferences_reset")
    body.should_not contain("reload_from_settings")
    body.scan(/prefs\.refresh\(section\)/).size.should eq(3)
  end
end

describe PreferencesView do
  # The polite re-pull the opener resets use: a section the operator is mid-edit on keeps the
  # edit. (The factory reset's `reload_from_settings` is the impolite one, pinned in
  # preferences_view_spec.cr.)
  it "keeps an unsaved form edit through a refresh" do
    v = PreferencesView.new
    v.open(:network)
    v.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Unknown, char: '7'))
    v.dirty?.should be_true

    v.refresh(:network)
    v.dirty?.should be_true
  end
end
