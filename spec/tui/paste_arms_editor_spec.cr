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
    body = method_body("runner.cr", "private def handle(ev : Termisu::Event::Any) : Bool")
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

# The workbench inputs a token or a body gets pasted into. Key by key, each character re-ran
# the tab's whole derivation (the Decoder chain, the JWT decode / encode, the cookie decode /
# forge) over the whole buffer, so a paste cost its length squared — 160 KB was ~15 s of the
# scheduler the proxy shares. In bulk it is one splice, one derivation and one undo step, and
# the buffer is what the key path would have typed: ↵ a newline, ↹ a tab.
describe "workbench inputs take a paste in bulk" do
  pasted = "line one\n\tline two"

  it "Decoder INPUT: only in INSERT, one splice, the chain re-run once" do
    TuiContract.with_session("paste-bulk-decoder") do |session|
      host = TuiContract::Host.new(session)
      controller = DecoderController.new(host)
      host.tab = :decoder
      TuiContract.render(controller)
      s = controller.@sessions[controller.@idx]
      s.pane = :input
      controller.accepts_bulk_paste?.should be_false # READ
      controller.paste_text("x").should be_false

      controller.editor_enter_insert.should be_true
      controller.accepts_bulk_paste?.should be_true
      controller.paste_text(pasted).should be_true
      s.input.text.should eq(pasted)
      String.new(s.result.input).should eq(pasted) # the chain saw the whole paste
      s.input.undo
      s.input.text.should eq("") # one undo step, not one per character

      s.pane = :chain # the single-line spec keeps the key path
      controller.accepts_bulk_paste?.should be_false
    end
  end

  it "JWT: INPUT in INSERT and the HEADER / PAYLOAD editors, each re-derived once" do
    TuiContract.with_session("paste-bulk-jwt") do |session|
      host = TuiContract::Host.new(session)
      controller = JwtController.new(host)
      host.tab = :jwt
      TuiContract.render(controller)
      s = controller.@sessions[controller.@idx]
      s.pane = :input
      controller.accepts_bulk_paste?.should be_false # READ
      controller.editor_enter_insert.should be_true
      token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
      controller.paste_text(token).should be_true
      s.input.text.should eq(token)
      s.decoded.should contain("HS256")

      s.pane = :payload
      controller.accepts_bulk_paste?.should be_true
      before = s.output
      s.payload.set_text("")
      controller.paste_text(%({"sub":\t"y"})).should be_true
      s.payload.text.should eq(%({"sub":\t"y"}))
      s.output.should_not eq(before)

      s.pane = :secret
      controller.accepts_bulk_paste?.should be_false
      controller.paste_text("k").should be_false
    end
  end

  it "Cookie: INPUT in INSERT and the PAYLOAD editor, each re-derived once" do
    TuiContract.with_session("paste-bulk-cookie") do |session|
      host = TuiContract::Host.new(session)
      controller = CookieController.new(host)
      host.tab = :cookie
      TuiContract.render(controller)
      s = controller.@sessions[controller.@idx]
      s.pane = :input
      controller.accepts_bulk_paste?.should be_false # READ
      controller.editor_enter_insert.should be_true
      controller.paste_text(pasted).should be_true
      s.input.text.should eq(pasted)
      s.decoded.should_not be_empty # decoded (or its error) for the pasted text

      s.pane = :payload
      controller.accepts_bulk_paste?.should be_true
      controller.paste_text("{}").should be_true
      s.payload.text.should end_with("{}")

      s.pane = :secret
      controller.accepts_bulk_paste?.should be_false
    end
  end
end

# A key a paste in progress absorbs changes nothing on screen until the paste closes, so the
# run loop must not render a frame for it: a 1 MB bulk paste is ~32k ticks, and rendering the
# same frame on each was 63% of the main thread the proxy shares. `handle` says whether an
# event could have changed the frame, and the loop dirties the tick on that answer alone.
describe "Runner — a paste in progress does not re-render per key" do
  it "reports buffered, dropped and mid-paste-swallowed input as not changing the frame" do
    body = method_body("runner.cr", "private def handle(ev : Termisu::Event::Any) : Bool")
    body.should contain("return false if buffer_bulk_paste(ev)")
    body.should contain("return false if @paste_dropped")
    # A swallowed event is inert only strictly INSIDE a paste: the markers themselves (and a
    # PasteStart that closed an abandoned paste) are transitions that flush, toast or arm.
    body.should contain("return !(was_pasting && @paste_newline.pasting?) if swallowed")
    body.should match(/handle_mouse\(ev\).*\n\s+true\n\s+end\z/m)
  end

  it "dirties the tick from those answers, first event and burst alike" do
    src = tui_src("runner.cr")
    src.should contain("dirty = handle(ev)")
    src.should contain("dirty ||= burst_changed")
    src.should_not match(/handle\(ev\)\n\s+dirty = true/)
    method_body("runner.cr", "private def drain_burst : {Int32, Bool}")
      .should contain("changed = true if handle(more)")
  end

  it "still feeds the stall guard every drained key (PasteStall is unchanged)" do
    tui_src("runner.cr").should contain("@paste_stall.saw(Time.instant, keys_drained)")
  end
end

describe "Runner — a paste while the space menu or a picker is up" do
  # They are not containers: the paste's first key runs a row or closes them and the rest
  # reached the tab's keymap — `Space`, then a pasted `zc`, closed the menu and stopped capture.
  # So a paste there is refused like one at the tab bar, before anything else is asked.
  it "is refused rather than run as commands" do
    body = method_body("runner/paste.cr", "private def paste_runs_as_commands? : Bool")
    body.should contain("return true if @space_menu_open || copy_as_shown? || send_to_shown?")
    body.should_not contain("return false if @space_menu_open")
    body.index!("return true if @space_menu_open").should be < body.index!("@goto_open")
  end
end
