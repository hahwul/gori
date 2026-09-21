require "../support/tui_contract"

include Gori::Tui

# A bracketed paste arriving at an editor pane that is in READ OPENS it (#1124), instead of
# being dropped with `PASTE_REFUSED`.
#
# This is the other half of "a click does not arm the editor". Once the pointer stopped
# entering INSERT, the panes it touches are in READ far more of the time — and Notes is the
# tab a captured response, a tool's output or a whole writeup gets pasted into. `i` then ⌘V
# was the documented recovery (`PASTE_REFUSED` names it), and it lands in exactly the state
# this does, so the change removes a keystroke from a two-step rather than inventing a
# destination for the clipboard. A paste is an explicit "put this in the buffer", which is why
# it may arm an editor that a pointer gesture deliberately may not.
#
# `Runner.new` owns a terminal and appears nowhere under spec/, so the wiring is pinned by
# reading the method bodies — the idiom spec/tui/factory_reset_apply_spec.cr and
# spec/tui/session_slots_spec.cr already use. Comments are stripped first: a comment explaining
# a rule contains the tokens the rule looks for, and asserting against the raw text would pass
# on the strength of its own prose.
private def tui_src(file : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", file))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def method_body(file : String, signature : String) : String
  body = tui_src(file)[/^\s*#{Regex.escape(signature)}$.*?^(    end|  end)$/m]?
  body.should_not be_nil
  body.not_nil!
end

describe "Runner — a paste into a READ editor" do
  # ORDER is the whole wiring: `arm_editor_for_paste` has to change the answer BOTH questions
  # get. Run after either one and the pane is still in READ when it is asked, so
  # `begin_bulk_paste?` says no and `paste_runs_as_commands?` says yes — the refusal this
  # replaces, now with a mode flip left behind it.
  it "opens the pane before either paste question is asked" do
    body = method_body("runner.cr", "private def handle(ev : Termisu::Event::Any) : Nil")
    arm = body.index("arm_editor_for_paste")
    bulk = body.index("begin_bulk_paste?")
    cmds = body.index("paste_runs_as_commands?")
    arm.should_not be_nil
    bulk.should_not be_nil
    cmds.should_not be_nil
    arm.not_nil!.should be < bulk.not_nil!
    arm.not_nil!.should be < cmds.not_nil!
  end

  # It asks the tab, not the tabs: `editor_read_mode?` / `editor_enter_insert` are the
  # `Verb::Scope::Editor` seam every editor controller already implements, so a tab that grows
  # a text pane tomorrow is covered the day it compiles.
  it "asks the editor seam rather than naming panes" do
    body = method_body("runner/paste.cr", "private def arm_editor_for_paste : Nil")
    body.should contain("editor_read_mode?")
    body.should contain("editor_enter_insert")
    # A paste into the sub-tab `/` bar belongs to the BAR. Arming the editor underneath it
    # would put the clipboard in two places at once — the bar takes the keystrokes
    # (`paste_runs_as_commands?` already returns false for it) while the pane behind it
    # silently flips to INSERT.
    body.should contain("subtab_filter_editing?")
  end
end

# The contract `arm_editor_for_paste` stands on, asserted on the controllers themselves rather
# than on the Runner it cannot build: flipping a READ editor pane through the seam is what
# makes `body_badge` say `:editor`, and `body_badge` is what BOTH paste predicates read.
describe "the editor seam a paste arms" do
  it "turns a READ editor pane into one the paste path recognises" do
    exercised = 0
    TuiContract.with_session("paste-arm") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.editor_pane?
        # Definitional, and cheap to state where it can be read: READ is "an editor pane whose
        # keys are not being captured", which is exactly what the badge reports.
        controller.editor_read_mode?.should eq(controller.body_badge != :editor)
        next unless controller.editor_read_mode?
        exercised += 1
        controller.editor_enter_insert.should be_true
        controller.body_badge.should eq(:editor)
        controller.editor_read_mode?.should be_false
      end
    end
    # A roster assertion that covers nothing is worse than none: this spec exists to walk real
    # editors, so it fails rather than passing vacuously if the roster stops producing any.
    exercised.should be > 0
  end
end

describe "NotesController — the pane a paste is most often aimed at" do
  it "takes a bulk paste once the seam has opened it" do
    TuiContract.with_session("paste-arm-notes") do |session|
      host = TuiContract::Host.new(session)
      controller = NotesController.new(host)
      host.tab = :notes
      TuiContract.render(controller)

      controller.view.insert_mode?.should be_false # a Notes tab opens in READ
      controller.accepts_bulk_paste?.should be_false
      controller.paste_text("pasted").should be_false

      controller.editor_enter_insert.should be_true # what `arm_editor_for_paste` runs
      controller.accepts_bulk_paste?.should be_true
      controller.paste_text("GET /a HTTP/1.1\nHost: x").should be_true
      controller.view.current_text.should eq("GET /a HTTP/1.1\nHost: x")
    end
  end
end
