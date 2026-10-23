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
    # ↹ moves a form to its next field, where the rest of the clipboard landed.
    prompt.takes_pasted?(key(Termisu::Input::Key::Tab)).should be_false
    prompt.takes_pasted?(key(Termisu::Input::Key::BackTab)).should be_false
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

  # A digit on the approval card is an answer (`1` = Once), a ChoicePicker mnemonic commits its
  # row (Android `s` runs the system-CA setup), and the ring's `c` wipes it: none of them is a
  # paste's to press.
  it "keeps a pasted key off the cards whose letters are decisions" do
    now = Time.utc.to_unix_ms * 1000
    q = Gori::AgentQuestion.new(7_i64, "approve?", nil, ["Once", "Deny"], "Deny", "claude-code pid 42", 42_i64,
      now + 60_000_000_i64, now, approval: true)
    AgentQuestionOverlay.new(q, "claude-code").takes_pasted?(key(Termisu::Input::Key::Num1, '1')).should be_false
    picker = ChoicePicker.new("PICK", [ChoicePicker::Choice.new("setup", 's', Theme.text, 0)], 0, :android)
    picker.takes_pasted?(key(Termisu::Input::Key::LowerS, 's')).should be_false
    NotificationsOverlay.new(Notifications.new).takes_pasted?(key(Termisu::Input::Key::LowerC, 'c')).should be_false
  end
end

private def runner_src(file : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", file))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def runner_body(signature : String) : String
  runner_src("runner.cr")[/^\s*#{Regex.escape(signature)}$.*?^    end$/m]?.not_nil!
end

# `Runner.new` owns a terminal, so the wiring is pinned by reading the method bodies (the idiom
# of spec/tui/paste_arms_editor_spec.cr).
describe "Runner — the rest of a paste after a refusal" do
  it "refuses the whole remainder once a modal holds a pasted key back" do
    body = runner_body("private def dispatch_overlay_key(ov : Overlay, ev : Termisu::Event::Key) : Nil")
    guard = body[/if @paste_newline\.pasting\? && !ov\.takes_pasted\?\(ev\).*?return/m]?
    guard.should_not be_nil
    guard.not_nil!.should contain("refuse_modal_paste(ev)")
    runner_body("private def refuse_modal_paste(ev : Termisu::Event::Key) : Nil").should contain("@paste_dropped = true")
  end

  it "re-asks after each pasted key whether the rest would now run as commands" do
    body = runner_body("private def handle(ev : Termisu::Event::Any) : Bool")
    tail = body[/handle_key\(ev\)\n.*?when Termisu::Event::Mouse/m]?
    tail.should_not be_nil
    tail.not_nil!.should contain("cut_paste_at_commands")
    cut = runner_src("runner/paste.cr")[/private def cut_paste_at_commands : Nil.*?^  end$/m]?.not_nil!
    cut.should contain("paste_runs_as_commands?")
    cut.should contain("@paste_dropped = true")
    # …and it owes its toast, rather than saying it: a copied line's trailing ↵ that commits
    # the `/` bar is the paste's LAST key, and nothing was dropped.
    cut.should_not contain("@toast")
  end

  # The Issues/Probe `/` bars and the Rewriter/Colormarker filters take text with no `:editor`
  # badge; asked by the badge alone, a paste into them was refused whole.
  it "lets a paste into a bar that takes text but reports no editor badge" do
    body = runner_src("runner/paste.cr")[/private def paste_runs_as_commands\? : Bool.*?^  end$/m]?.not_nil!
    body.should contain("body_takes_text?")
  end
end
