require "../spec_helper"
require "../support/memory_backend"
require "../support/tui_probes"

include Gori::Tui

# The TUI wiring of `ask_operator` questions (#1324): the `ask:N` chip and the Runner seams
# that feed it. No Runner is constructed in a spec (it owns a terminal), so the wiring is
# pinned by reading the source with comments stripped, the way agents_chip_spec.cr does.
private def src(*parts : String) : Array(String)
  File.read(File.join(__DIR__, "..", "..", "src", "gori", *parts)).lines.reject(&.lstrip.starts_with?('#'))
end

describe "the ask: chip" do
  it "is absent while no question is waiting, and counts them when some are" do
    rect = Rect.new(0, 0, 120, 1)
    off = MemoryBackend.new(120, 1)
    Chrome.render_top_bar(Screen.new(off), rect, project: "acme", scope: "scope:2", listen: "127.0.0.1:8080")
    off.row(0).should_not contain("ask:")
    on = MemoryBackend.new(120, 1)
    Chrome.render_top_bar(Screen.new(on), rect, project: "acme", scope: "scope:2", listen: "127.0.0.1:8080",
      agents: "mcp:claude-code", asks: 2)
    row = on.row(0)
    row.should contain("ask:2")
    on.fg_at(row.index("ask:").not_nil!, 0).should eq(Theme.orange)
    # Beside the agents chip: it is those agents asking.
    (row.index("ask:").not_nil! > row.index("mcp:").not_nil!).should be_true
  end

  it "is clickable, and opens the oldest question's card" do
    rect = Rect.new(0, 0, 120, 1)
    args = {scope: "scope:2", listen: "127.0.0.1:8080", agents: "mcp:claude-code", asks: 1}
    r = Chrome.top_bar_chip_rect(rect, :ask, **args).not_nil!
    Chrome.top_bar_chip_at(rect, r.x, 0, **args).should eq(:ask)
    mouse = src("tui", "runner", "mouse.cr")
    arm = mouse.index(&.includes?("when :ask ")).not_nil!
    mouse[arm].should contain("answer_agent_question")
    mouse.join('\n').should contain("asks: answerable_questions.size")
  end

  it "is fed from the chrome both render paths draw" do
    lines = src("tui", "runner.cr")
    lines.count(&.includes?("asks: answerable_questions.size")).should eq(1)
    lines.count(&.includes?("render_chrome(screen, layout)")).should eq(2) # render + render_safe_frame
  end
end

describe "the Runner's question wiring" do
  it "drains questions on the DV tick, after the presence scan it reads the askers from" do
    lines = src("tui", "runner.cr")
    presence = lines.index(&.includes?("dirty = true if refresh_agent_presence")).not_nil!
    questions = lines.index(&.includes?("dirty = true if drain_agent_questions")).not_nil!
    (questions > presence).should be_true
  end

  it "raises the answer card from the ring's on_close, not its commit" do
    body = src("tui", "runner.cr").join('\n')
    body.should match(/answerable_question_for\(note\)/)
    body.should match(/on_close = -> \{\s*if asked = question\s*open_question_card\(asked\[0\], from_ring: asked\[1\]\)/)
  end

  it "announces a question as an addressed ring note carrying its id" do
    lines = src("tui", "runner", "agent_question.cr")
    lines.join('\n').should match(/@notifications\.push\([^)]*question_line\(q\)[\s\S]*?addressed: true, question_id: q\.id\)/)
  end

  # A question never raises its own card: only the operator does (ring ↵, chip, verb).
  it "opens the card only from operator-driven paths" do
    callers = [] of String
    glob_files(__DIR__, "..", "..", "src", "gori", "**", "*.cr").each do |path|
      File.read(path).lines.reject(&.lstrip.starts_with?('#')).each do |l|
        callers << File.basename(path) if l.includes?("open_question_card(") && !l.includes?("def open_question_card")
      end
    end
    callers.sort.should eq(["agent_question.cr", "runner.cr"])
    src("tui", "runner", "agent_question.cr").count(&.includes?("open_question_card(")).should eq(2) # def + answer_agent_question
  end

  it "re-checks the asker at the side effect before writing an answer" do
    body = src("tui", "runner", "agent_question.cr").join('\n')
    body.should match(/unless attached_agents\.any\? \{ \|e\| e\.pid == q\.pid \}[\s\S]*close_agent_question/)
  end
end

describe "the Runner's question wiring after review" do
  # One presence scan that missed a marker must not retire a question for good.
  it "never settles a question as gone" do
    src("tui", "runner", "agent_question.cr").join('\n').should_not contain(":gone")
  end

  it "reads only what changed since the last scan" do
    body = src("tui", "runner", "agent_question.cr").join('\n')
    body.should contain("store.agent_questions_closed_after(floor)")
    body.should contain("store.open_agent_questions(floor, now)")
    body.should contain("@question_floor = high")
  end

  it "keeps an agent's own expiry out of the ring's delivery notes" do
    src("tui", "runner", "agent_message.cr").join('\n').should match(/next if expiry_delivery\?\(row\)/)
  end
end
