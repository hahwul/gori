require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The TUI half of agent presence (#815): the `mcp:<client>` top-bar chip, the AGENTS card
# behind it, and the poll that keeps them fresh. No Runner is ever constructed in a spec (it
# owns a terminal), so the wiring is pinned by reading the source with comments stripped — a
# comment that explains a rule holds the very tokens the rule looks for.
private def src(*parts : String) : Array(String)
  File.read(File.join(__DIR__, "..", "..", "src", "gori", *parts)).lines.reject(&.lstrip.starts_with?('#'))
end

describe "the mcp: chip" do
  it "is absent while nothing is attached" do
    rect = Rect.new(0, 0, 110, 1)
    off = MemoryBackend.new(110, 1)
    Chrome.render_top_bar(Screen.new(off), rect, project: "acme", scope: "scope:2",
      listen: "127.0.0.1:8080")
    off.row(0).should_not contain("mcp:")
  end

  it "names the client in WORDS, in the accent colour the notification center's ai tag uses" do
    rect = Rect.new(0, 0, 110, 1)
    on = MemoryBackend.new(110, 1)
    Chrome.render_top_bar(Screen.new(on), rect, project: "acme", scope: "scope:2",
      listen: "127.0.0.1:8080", agents: "mcp:claude-code")
    row = on.row(0)
    row.should contain("mcp:claude-code")
    x = row.index("mcp:").not_nil!
    on.fg_at(x, 0).should eq(Theme.accent)
  end

  it "is clickable, and resolves to its own tag at both ends" do
    rect = Rect.new(0, 0, 120, 1)
    args = {scope: "scope:2", listen: "127.0.0.1:8080", agents: "mcp:claude-code"}
    r = Chrome.top_bar_chip_rect(rect, :agents, **args).not_nil!
    Chrome.top_bar_chip_at(rect, r.x, 0, **args).should eq(:agents)
    Chrome.top_bar_chip_at(rect, r.right - 1, 0, **args).should eq(:agents)
  end

  it "opens the AGENTS card on a click, not some other chip's action" do
    mouse = src("tui", "runner", "mouse.cr")
    arm = mouse.index(&.includes?("when :agents"))
    arm.should_not be_nil, "the mcp chip lost its click handler"
    mouse[arm.not_nil!].should contain("open_agents")
  end

  it "feeds the chip its label from the render call" do
    # The render_top_bar call must pass `agents: agent_chip`, or the chip is dead no matter
    # what the poll computed.
    body = src("tui", "runner.cr").join('\n')
    call = body[/Chrome\.render_top_bar\(.*?\)/m].not_nil!
    call.should contain("agents: agent_chip")
  end
end

describe "the agent-presence poll" do
  it "runs on the DV tick but NOT inside apply_external_change" do
    # A marker appears and vanishes on the filesystem without moving data_version, so the poll
    # cannot live in the data_version branch (apply_external_change) — it must be its own line
    # on the DV_POLL_INTERVAL tick. Pinned by source: Runner.new appears nowhere under spec/.
    body = src("tui", "runner.cr").join('\n')
    tick = body[/if now - last_dv_poll >= DV_POLL_INTERVAL.*?\n            end/m].not_nil!
    tick.should contain("refresh_agent_presence")
    apply = body[/def apply_external_change.*?\n    end/m].not_nil!
    apply.should_not contain("refresh_agent_presence")
  end

  it "only reports dirty when the rendered chip string changed" do
    # The folded-field discipline: an idle project with a steady agent list must not force a
    # repaint on the timer. `refresh_agent_presence` compares agent_chip before and after.
    body = src("tui", "runner", "agent_presence.cr").join('\n')
    m = body[/def refresh_agent_presence.*?\n  end/m].not_nil!
    m.should contain("before = agent_chip")
    m.should contain("agent_chip != before")
  end
end

describe "AgentsOverlay.chip_label" do
  it "covers the five states the label can be in" do
    AgentsOverlay.chip_label([] of String?).should eq("")
    AgentsOverlay.chip_label(["claude-code"]).should eq("mcp:claude-code")
    AgentsOverlay.chip_label([nil]).should eq("mcp")
    AgentsOverlay.chip_label(["a", "b"]).should eq("mcp:a +1")
    AgentsOverlay.chip_label([nil, nil]).should eq("mcp +1")
  end
end

describe "AgentsOverlay.safe_client" do
  it "strips control characters from a hostile handshake string" do
    AgentsOverlay.safe_client("cc\u0001code").should eq("cccode")
  end

  it "collapses whitespace and trims" do
    AgentsOverlay.safe_client("  claude   code  ").should eq("claude code")
  end

  it "truncates past the display-width cap" do
    long = "x" * 40
    out = AgentsOverlay.safe_client(long).not_nil!
    out.size.should be <= AgentsOverlay::CLIENT_MAX_CELLS
    out.should end_with("…")
  end

  it "is nil for a name that is empty or all control characters" do
    AgentsOverlay.safe_client(nil).should be_nil
    AgentsOverlay.safe_client("").should be_nil
    AgentsOverlay.safe_client("\u0001\u0007").should be_nil
  end
end

private def entry(client : String?, version : String? = nil, read_only : Bool = false,
                  source : String? = "workspace-created",
                  attached_at : Time? = Time.utc) : Gori::AgentPresence::Entry
  Gori::AgentPresence::Entry.new(kind: "mcp", client: client, client_version: version,
    pid: 4242_i64, attached_at: attached_at, read_only: read_only,
    selection_source: source, path: "/tmp/x.agents/4242-a.json")
end

describe "AgentsOverlay#render" do
  it "draws each attached client's name, version, mode and source" do
    area = Rect.new(0, 0, 100, 24)
    back = MemoryBackend.new(100, 24)
    ov = AgentsOverlay.new(-> { [entry("claude-code", "9.9", read_only: false)] })
    ov.render(Screen.new(back), area)
    screen = (0...24).map { |y| back.row(y) }.join('\n')
    screen.should contain("claude-code (9.9)")
    screen.should contain("actions")
    screen.should contain("via workspace") # the source, truncated to the 76-col card
  end

  it "marks a read-only client and names an unnamed one" do
    area = Rect.new(0, 0, 100, 24)
    back = MemoryBackend.new(100, 24)
    ov = AgentsOverlay.new(-> { [entry(nil, read_only: true)] })
    ov.render(Screen.new(back), area)
    screen = (0...24).map { |y| back.row(y) }.join('\n')
    screen.should contain("(unnamed client)")
    screen.should contain("read-only")
  end

  it "shows the empty-state line with no clients attached" do
    area = Rect.new(0, 0, 100, 24)
    back = MemoryBackend.new(100, 24)
    ov = AgentsOverlay.new(-> { [] of Gori::AgentPresence::Entry })
    ov.render(Screen.new(back), area)
    screen = (0...24).map { |y| back.row(y) }.join('\n')
    screen.should contain("(no MCP client is attached to this project)")
  end

  it "falls back to a one-line message below the minimum box size" do
    area = Rect.new(0, 0, 30, 5) # under the 32x7 floor
    back = MemoryBackend.new(30, 5)
    ov = AgentsOverlay.new(-> { [entry("claude-code")] })
    ov.overlay_box(area).should be_nil
    ov.render(Screen.new(back), area)
    (0...5).map { |y| back.row(y) }.join('\n').should contain("larger wi") # truncated at 30 cols
  end

  it "clips a long client name to the card border instead of overrunning it" do
    # A hostile-length name (safe_client caps each of name and version at 24 cells) must not
    # push pid/attached/mode past the card's right border and paint over it. Every row segment
    # is width-bounded to the inner right edge; the border column and the backdrop beyond it
    # stay untouched.
    [Rect.new(0, 0, 100, 24), Rect.new(0, 0, 40, 24)].each do |area|
      back = MemoryBackend.new(area.w, area.h)
      long = "verylongclientname-#{"x" * 30}"
      ov = AgentsOverlay.new(-> { [entry(long, "9.9", source: "workspace-created")] })
      box = ov.overlay_box(area).not_nil!
      ov.render(Screen.new(back), area)
      row = back.row(box.y + 2)                           # the single agent row, one line below the card's top
      row[box.right - 1].should eq('│')                   # right border intact
      row[box.right].should eq(' ')                       # backdrop just outside the card untouched
      row.should_not contain("xxxxxxxxxxxxxxxxxxxxxxxxx") # the full un-truncated name never lands
    end
  end
end

describe "the app.agents verb" do
  it "is a Global system verb, reachable from the palette" do
    verb = Gori::Verbs.registry["app.agents"]?
    verb.should_not be_nil
    verb.not_nil!.scope.should eq(Gori::Verb::Scope::Global)
    verb.not_nil!.hidden?.should be_false
  end
end
