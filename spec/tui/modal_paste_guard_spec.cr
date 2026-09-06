require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `Overlay#takes_pasted?` — which keystrokes that arrived INSIDE A BRACKETED PASTE a modal
# takes. The shell delivers a paste over a modal one key at a time, and every pasted line
# break arrives as ↵: on a one-line form ↵ is COMMIT, so `/tmp/a.har⏎` submitted the import
# and typed what followed into the pane underneath; on a confirm card a pasted `y` answered
# it. The Runner asks this before dispatching a pasted key (`dispatch_overlay_key`).

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::None, char)
end

describe "Overlay#takes_pasted?" do
  it "lets text into a one-line form and holds back the line break" do
    prompt = NamePromptOverlay.new("SAVE CHAIN", "chain", "")
    prompt.takes_pasted?(key(Termisu::Input::Key::LowerA, 'a')).should be_true
    prompt.takes_pasted?(key(Termisu::Input::Key::Enter)).should be_false
  end

  it "lets a multi-line editor take the line break as a newline" do
    RewriterStubOverlay.new("HTTP/1.1 200 OK\r\n\r\n").takes_pasted?(key(Termisu::Input::Key::Enter)).should be_true
    DiscoverHeadersOverlay.new([] of {String, String}).takes_pasted?(key(Termisu::Input::Key::Enter)).should be_true
  end

  it "keeps a pasted answer out of a confirm card" do
    dlg = ConfirmDialog.new("DELETE", "Sure?")
    dlg.takes_pasted?(key(Termisu::Input::Key::LowerY, 'y')).should be_false
    dlg.takes_pasted?(key(Termisu::Input::Key::LowerN, 'n')).should be_false
    dlg.takes_pasted?(key(Termisu::Input::Key::Enter)).should be_false
    dlg.takes_pasted?(key(Termisu::Input::Key::Escape)).should be_false
  end
end
