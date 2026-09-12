require "../spec_helper"
require "../support/tui_contract"

# The other half of `Verb::Scope::Editor` (the verb half is spec/verbs/editor_spec.cr): the
# eleven panes that used to answer `i` / `↵` / `x` / `y` / `b` with a hand-rolled arm in
# `handle_body_key` now DEFER those keys, and each one answers the `editor_pane?` seam the
# shell puts the Editor scope at the head of the chain for.
#
# The arm-removal half is asserted by reading the controller SOURCE. That is unusual and
# deliberate: the failure mode being guarded against is invisible from the outside. A
# re-added `when c == 'i'` arm would keep every behavioural spec green — the pane still
# enters INSERT, it just stops being rebindable, stops following a keyset, and goes back to
# shadowing whatever the keymap had for that letter. KEY_AUDIT §2d/§2e is a list of exactly
# that failure, accumulated over a year with nothing to catch it.
private CONTROLLERS = "#{__DIR__}/../../src/gori/tui/controllers"

private def controller(name : String) : String
  File.read("#{CONTROLLERS}/#{name}_controller.cr")
end

describe "Verb::Scope::Editor — the controller arms it replaced" do
  it "leaves no editor pane claiming a bare `i` for INSERT" do
    # `editor.insert` is one verb in one scope; nine files used to spell it nine times.
    %w[repeater notes decoder jwt cookie fuzzer issues project].each do |name|
      src = controller(name)
      src.should_not match(/when c == 'i'/)
      src.should_not match(/c == 'i' then/)
      src.should_not match(/key\.enter\?, c == 'i'/)
    end
  end

  it "leaves no editor pane claiming `x` (select line) or `y` (copy)" do
    # These two were never missing verbs — `repeater.select-line`, `issue.select-line`,
    # `project.select-line`, `issue.copy`, `project.copy` all carried the chord already. The
    # arms are what made the chords dead, so a rebind of any of them moved nothing.
    controller("repeater").should_not contain("key.lower_x? then view.pane_select_line")
    controller("issues").should_not contain("c == 'x' then @issues.notes_select_line")
    controller("project").should_not contain("c == 'x'")
    controller("project").should_not contain("c == 'y'")
    # The Issue notes pane KEEPS its `y` arm, and that is #1054's call rather than an
    # oversight: the arm is modifier-blind on purpose, so `^Y` — `issue.copy`'s pinned INS
    # chord — takes the same action there. The `x` beside it went, because `issue.select-line`
    # has a plain chord and a rebind of it has to move the live key.
    controller("issues").should contain("when c == 'y' then issues_notes_copy")
  end

  it "leaves no bare `b` aliasing the global ^B reveal in one Repeater pane" do
    # An undocumented single-pane alias for a global chord (KEY_AUDIT §2e) — `^B`
    # (`view.reveal-ws`) is the key, everywhere, and it works from INS too.
    controller("repeater").should_not contain("key.lower_b? then @host.toggle_reveal")
  end

  it "answers editor_pane? on exactly the panes that can enter INSERT" do
    TuiContract.with_session("editor-scope") do |session|
      host = TuiContract::Host.new(session)

      host.tab = :notes
      notes = Gori::Tui::NotesController.new(host)
      notes.editor_pane?.should be_true      # the whole Notes body IS the editor
      notes.editor_read_mode?.should be_true # …and it boots in READ
      notes.editor_enter_insert.should be_true
      notes.editor_read_mode?.should be_false # body_badge derives it — no second flag to drift
      notes.editor_exit_insert.should be_true
      notes.editor_read_mode?.should be_true

      host.tab = :decoder
      dec = Gori::Tui::DecoderController.new(host)
      dec.editor_pane?.should be_true # INPUT is focused first
      dec.editor_enter_insert.should be_true
      dec.editor_exit_insert.should be_true

      # The read-only pane beside an editor is NOT an editor pane: that is what keeps the
      # Editor scope off the chain there, so the tab's own `↵`/`x` keep their meaning and
      # `insert_key_refusal` still gets to explain the `i`.
      host.tab = :repeater
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      v = rep.current_view.not_nil!
      v.focus_pane(:request)
      rep.editor_pane?.should be_true
      v.focus_pane(:response)
      rep.editor_pane?.should be_false
      rep.insert_key_refusal.should_not be_nil
    end
  end

  it "says so when a pane has no undo rather than eating the key" do
    # `editor.undo` is new in READ (the nine ^Z guards are all INS-side), so a silent no-op
    # would read as a broken keyset instead of an empty stack / a pane without one.
    TuiContract.with_session("editor-undo") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      rep.current_view.not_nil!.focus_pane(:target) # a one-line field: no undo stack
      rep.editor_undo.should be_false
      rep.current_view.not_nil!.focus_pane(:request)
      rep.editor_undo.should be_true
    end
  end
end
