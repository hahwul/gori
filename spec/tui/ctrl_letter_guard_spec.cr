require "../spec_helper"
require "../support/fake_host"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# `Termisu::Event::Key#char` falls back to `key.to_char`, and the parser decodes 0x01..0x1A as
# `(LowerA..LowerZ, Modifier::Ctrl)` — so a Ctrl+A event CARRIES the character 'a'. Every
# `c == '<letter>'` arm in a key handler therefore fires on the Ctrl form too unless something
# upstream refuses it, which is why ten of the twelve body controllers open with
# `return false if ev.ctrl? || ev.alt?`.
#
# The Rewriter and the Colormarker were the two that did not. `^A` opened ADD EXTRACT RULE /
# ADD CUSTOM COLOUR, `^E` ran the edit action, `^X` toggled. Two separate costs:
#
#   * `^E` is in `Hotkeys::CLAIMED_CTRL_LETTERS` — the global "open in $EDITOR" chord — and
#     that list's contract is that a controller may hardcode a Ctrl guard ONLY for a key
#     named there. These panes claimed it for something else.
#   * `^A` and `^X` are neither claimed nor `Verb::Reserved.reserved?`, so the hotkey editor
#     offers them; a user binding on either was silently shadowed on these panes.
#
# The assertion is `handle_body_key`'s RETURN VALUE, because that is the actual contract with
# the shell: `runner.cr` does `return if c.handle_body_key(ev)`, so `true` means "consumed,
# never show the keymap this key". The editor-open counter is the visible half of the same
# thing.
private class CountingHost < FakeHost
  getter extract_editors = 0
  getter colour_editors = 0

  def open_extract_rule_editor(rule : Gori::Store::ExtractRule?) : Nil
    @extract_editors += 1
  end

  def open_colormarker_color_editor(color : Gori::Settings::ColormarkerColor?) : Nil
    @colour_editors += 1
  end
end

private CTRL_GUARD_CA = File.tempname("gori-ctrl-guard-ca")
Spec.after_suite { FileUtils.rm_rf(CTRL_GUARD_CA) }

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

# The event a terminal actually delivers for Ctrl+<letter>: the letter key plus the Ctrl
# modifier and NO explicit char, so `#char` has to fall back — which is the whole bug.
private def ctrl(k : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::Ctrl)
end

private def with_session(name : String, &)
  root = File.tempname("gori-#{name}")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp(name)
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(CTRL_GUARD_CA), Gori::Verbs.registry, project)
  begin
    yield CountingHost.new(session)
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "Ctrl+letter must not fire a pane's bare-letter action" do
  describe "RewriterController — extract sub-tab" do
    it "takes the bare letters and defers every Ctrl form to the keymap" do
      with_session("rewriter-ctrl") do |host|
        ctl = RewriterController.new(host)
        ctl.render_body(Screen.new(MemoryBackend.new(100, 40)), Rect.new(0, 0, 100, 40), :body)
        ctl.handle_body_key(key(Termisu::Input::Key::RightBracket, char: ']')) # rules → extract
        ctl.@sub.should eq(:extract)

        # The control: bare `a` still opens the editor and still reports "consumed".
        ctl.handle_body_key(key(Termisu::Input::Key::LowerA, char: 'a')).should be_true
        host.extract_editors.should eq(1)

        # ^A / ^E / ^X fall through — no editor, no toggle, and the shell gets to try the keymap.
        {Termisu::Input::Key::LowerA, Termisu::Input::Key::LowerE,
         Termisu::Input::Key::LowerX}.each do |k|
          ctl.handle_body_key(ctrl(k)).should be_false
        end
        host.extract_editors.should eq(1) # still just the bare press
        host.statuses.should be_empty     # ^E used to reach extract_edit's "no rule selected"
      end
    end

    it "leaves the rules list alone on ^X and ^K" do
      with_session("rewriter-ctrl-list") do |host|
        ctl = RewriterController.new(host)
        ctl.render_body(Screen.new(MemoryBackend.new(100, 40)), Rect.new(0, 0, 100, 40), :body)
        ctl.@sub.should eq(:rules)
        ctl.handle_body_key(ctrl(Termisu::Input::Key::LowerX)).should be_false
        ctl.handle_body_key(ctrl(Termisu::Input::Key::LowerK)).should be_false
      end
    end
  end

  describe "ColormarkerController — custom colours pane" do
    it "takes the bare letters and defers every Ctrl form to the keymap" do
      with_session("colormarker-ctrl") do |host|
        ctl = ColormarkerController.new(host)
        # A render is what sets `@colors_shown`, and focus reaches the pane the way an operator
        # gets there: ↓ off the (empty) rule list.
        ctl.render_body(Screen.new(MemoryBackend.new(100, 40)), Rect.new(0, 0, 100, 40), :body)
        ctl.handle_body_key(key(Termisu::Input::Key::Down))
        ctl.@focus.should eq(:colors)

        ctl.handle_body_key(key(Termisu::Input::Key::LowerA, char: 'a')).should be_true
        host.colour_editors.should eq(1)

        {Termisu::Input::Key::LowerA, Termisu::Input::Key::LowerE,
         Termisu::Input::Key::LowerD}.each do |k|
          ctl.handle_body_key(ctrl(k)).should be_false
        end
        host.colour_editors.should eq(1)
        host.statuses.should be_empty
        ctl.@focus.should eq(:colors) # ^K/^J must not walk the list either
      end
    end
  end
end
