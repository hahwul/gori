require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/agent_view"

include Gori::Tui

# The Agent tab's body, drawn without a child process: `AgentView#sync` takes a `Transcript`
# and `render` takes a `Session?`, so every pane and every status word is reachable from a
# hand-built conversation (#1093).

# A backend whose spawn is `/bin/cat`: it starts, it reads its stdin forever, and it never
# says anything back — which is every state the status band needs except the ones a spec sets
# on the session directly. No `claude` on the machine, and no fixture process to maintain.
private class CatBackend < Gori::Agent::Backend
  def name : String
    "fake"
  end

  def argv(config : Gori::Agent::Config, session_uuid : String, resume_uuid : String?,
           mcp_config_path : String) : Array(String)
    ["/bin/cat"]
  end

  def parse(line : String) : Array(Gori::Agent::Event::Any)
    [] of Gori::Agent::Event::Any
  end

  def user_turn(text : String) : String
    text
  end

  def permission_response(request_id : String, allow : Bool, input_json : String?,
                          message : String?) : String
    ""
  end

  def interrupt(request_id : String) : String
    ""
  end
end

private def agent_config : Gori::Agent::Config
  Gori::Agent::Config.new(db_path: File.join(GORI_TEST_HOME, "agent-view-spec.db"))
end

private def held_permission(tool : String) : Gori::Agent::Event::PermissionAsked
  Gori::Agent::Event::PermissionAsked.new("req-#{tool}", tool, tool, "{}", "", "", "tu-#{tool}")
end

private def agent_rows(view : AgentView, transcript : Gori::Agent::Transcript?,
                       session : Gori::Agent::Session? = nil,
                       w = 80, h = 24, focused = true) : Array(String)
  view.sync(transcript) if transcript
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h), focused, session)
  (0...h).map { |y| backend.row(y) }
end

private def conversation : Gori::Agent::Transcript
  t = Gori::Agent::Transcript.new
  t.append("user", "text", "find the login endpoint")
  t.append("assistant", "tool_use", "Bash", payload: %({"command":"rg -n login"}),
    tool_name: "Bash", tool_use_id: "toolu_1")
  t.append("tool", "tool_result", "src/a.cr:12\nsrc/b.cr:44", tool_use_id: "toolu_1")
  t.append("assistant", "text",
    "The login endpoint is POST /api/v1/session and it accepts a JSON body with the " \
    "fields username and password, which the proxy captured on flow 41 earlier today.")
  t
end

describe Gori::Tui::AgentView do
  it "draws the folded tool call, the wrapped prose and the input pane" do
    view = AgentView.new
    view.set_input("what about logout?")
    view.enter_insert!
    rows = agent_rows(view, conversation)
    text = rows.join('\n')

    text.should contain("TRANSCRIPT")
    text.should contain("INPUT")
    # Folded: the call is ONE line naming the tool and its argument preview, and the result
    # beside it is a count — not the two lines of output.
    text.should contain("▸ Bash(rg -n login)")
    text.should contain("✓ 2 lines")
    text.should_not contain("src/b.cr:44")
    # The paragraph is one logical line and wraps rather than being cut at the pane edge.
    text.should contain("The login endpoint is POST /api/v1/session")
    text.should contain("username and password")
    # The draft, and the INS badge the mode paints on the input pane's border.
    text.should contain("what about logout?")
    text.should contain(Frame.mode_badge_label(true))
  end

  it "expands a tool call once it is unfolded" do
    view = AgentView.new
    t = conversation
    agent_rows(view, t)
    t.toggle("toolu_1")
    text = agent_rows(view, t).join('\n')
    text.should contain("▾ Bash")
    text.should contain("src/b.cr:44")
  end

  it "re-points the pane's source only when the transcript changed" do
    view = AgentView.new
    t = conversation
    view.sync(t)
    first = view.source_repoints
    first.should be > 0

    view.sync(t)
    view.sync(t)
    view.source_repoints.should eq(first) # same version, same object: no re-wrap

    t.append("assistant", "text", "and one more thing")
    view.sync(t)
    view.source_repoints.should eq(first + 1)
  end

  it "follows the tail until the operator scrolls up, then re-arms at the bottom" do
    view = AgentView.new
    t = Gori::Agent::Transcript.new
    60.times { |i| t.append("assistant", "text", "line #{i}") }
    rows = agent_rows(view, t, h: 24)
    view.follow?.should be_true
    rows.join('\n').should contain("line 59")

    view.handle_wheel(-30)
    view.follow?.should be_false
    t.append("assistant", "text", "line 60")
    rows = agent_rows(view, t)
    rows.join('\n').should_not contain("line 60") # the pane stayed where it was put

    # Back to the bottom re-arms it with no separate key — on the frame that proves the last
    # line fitted, which is the only thing that knows.
    view.handle_wheel(60)
    agent_rows(view, t)
    view.follow?.should be_true
    t.append("assistant", "text", "line 61")
    agent_rows(view, t).join('\n').should contain("line 61")
  end

  it "draws the guidance body when there is no session" do
    view = AgentView.new
    text = agent_rows(view, nil).join('\n')
    text.should contain("AGENT")
    text.should contain("claude")
    text.should contain("npm i -g @anthropic-ai/claude-code")
    text.should contain("agent.command")
    text.should contain("start the agent")
    text.should_not contain("TRANSCRIPT") # the panes are given up for it
  end

  it "wraps the panes' focus ring and answers at_top? per pane" do
    view = AgentView.new
    view.focus.should eq(:input)
    view.pane_advance(1).should be_true
    view.focus.should eq(:transcript)
    view.pane_advance(1).should be_true
    view.focus.should eq(:input) # wraps rather than stepping off the end
    view.pane_advance(-1).should be_true
    view.focus.should eq(:transcript)

    view.focus_first
    view.focus.should eq(:transcript)
    view.focus_last
    view.focus.should eq(:input)
    view.at_top?.should be_true # an empty draft's caret is on its first row
  end

  it "copies the whole transcript with nothing selected" do
    view = AgentView.new
    view.sync(conversation)
    copied = view.copy_text
    copied.should_not be_nil
    copied.not_nil!.should contain("› find the login endpoint")
    AgentView.new.copy_text.should be_nil # nothing at all: the caller toasts instead
  end
end

describe "Gori::Tui::AgentView.status_line" do
  it "reads the whole state machine off one session" do
    AgentView.status_line(nil).should eq(AgentView::NO_SESSION_STATUS)

    session = Gori::Agent::Session.new(CatBackend.new, agent_config, nil)
    # Never started: Dead with the reason the tab's dead band draws.
    AgentView.status_line(session).should eq("dead: not started — R to restart")

    session.start.should be_true
    AgentView.status_line(session).should eq("idle")

    session.send("hello").should be_true
    AgentView.status_line(session).should eq("running ⟳")

    # A held tool call outranks the state word: it is the one thing the operator has to act on.
    session.pending << held_permission("Bash")
    AgentView.status_line(session).should eq("⚠ 1 permission request — press p")
    session.pending << held_permission("Write")
    AgentView.status_line(session).should eq("⚠ 2 permission requests — press p")
    session.pending.clear

    session.stop
    AgentView.status_line(session).should eq("dead: stopped — R to restart")
  end
end
