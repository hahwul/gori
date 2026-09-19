require "../spec_helper"

include Gori::Tui

# The operator→agent channel's TUI half (#1090): the target picker's row label and the
# notification a courier's reply becomes. `Runner.new` owns a terminal and is never built in a
# spec, so both strings live in `tui/agent_message_notes.cr` as pure functions and are pinned
# here; the Runner WIRING (where the drain is called, where its cursor is seeded) is pinned by
# reading the source with comments stripped, the way agents_chip_spec.cr does.
private def src(*parts : String) : Array(String)
  File.read(File.join(__DIR__, "..", "..", "src", "gori", *parts)).lines.reject(&.lstrip.starts_with?('#'))
end

private def mcp_entry(client : String? = "claude-code", pid : Int64? = 48_213_i64,
                      attached_at : Time? = nil) : Gori::AgentPresence::Entry
  Gori::AgentPresence::Entry.new(
    kind: Gori::AgentPresence::KIND_MCP, client: client, client_version: nil, pid: pid,
    attached_at: attached_at, read_only: false, selection_source: nil,
    path: "/tmp/acme.db.agents/#{pid}-abcd.json")
end

private def delivery(via : String = "socket", ok : Bool = true, reason : String? = nil,
                     target_label : String = "claude-code") : Gori::AgentDelivery
  Gori::AgentDelivery.new(id: 7_i64, message_id: 3_i64, via: via, target_label: target_label,
    ok: ok, reason: reason, created_at: 0_i64)
end

private def agents_overlay(entries) : Gori::Tui::AgentsOverlay
  Gori::Tui::AgentsOverlay.new(-> { entries })
end

private def tkey(mods : Termisu::Input::Modifier = :none) : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::LowerT, mods, 't')
end

describe AgentTargets do
  describe ".label" do
    it "names the client, its pid and how long it has been attached" do
      now = Time.utc(2026, 9, 19, 12, 0, 0)
      entry = mcp_entry(attached_at: now - 3.minutes)
      AgentTargets.label(entry, now).should eq("claude-code · pid 48213 · attached 3m ago")
    end

    it "keeps a row for a marker that answers neither question" do
      now = Time.utc(2026, 9, 19, 12, 0, 0)
      # A body that would not parse still means "someone is attached" (agent_presence.cr), so
      # the picker has to be able to draw that row rather than drop the agent off the list.
      AgentTargets.label(mcp_entry(client: nil, pid: nil), now)
        .should eq("(unnamed client) · pid ? · attached ?")
    end

    it "strips a hostile client name before it reaches the card" do
      now = Time.utc(2026, 9, 19, 12, 0, 0)
      # Control characters are DROPPED (not turned into spaces) and runs of whitespace fold —
      # `AgentsOverlay.safe_client`'s rule, the same one the AGENTS card's rows go through.
      label = AgentTargets.label(mcp_entry(client: "cla\u0007ude  code", attached_at: now), now)
      label.should eq("claude code · pid 48213 · attached just now")
    end
  end

  describe ".target_for" do
    it "addresses one agent by the pid its marker reports" do
      AgentTargets.target_for(mcp_entry).should eq("pid:48213")
    end

    it "refuses to address a marker with no pid rather than widening to everybody" do
      AgentTargets.target_for(mcp_entry(pid: nil)).should be_nil
    end
  end

  it "spells the broadcast target the way the store contract does" do
    AgentTargets::ALL.should eq("all")
  end
end

describe AgentMessageNotes do
  describe ".line" do
    it "reports a delivered message with the transport that carried it" do
      AgentMessageNotes.line(delivery(via: "socket"))
        .should eq({:success, "→ claude-code got it (socket)"})
    end

    it "calls a poll hand-off left, not delivered — and a pickup picked up" do
      # `poll` means the courier wrote the line into a table its session reads when it next
      # looks (which may be never); `picked_up` is that read happening.
      AgentMessageNotes.line(delivery(via: "poll"))
        .should eq({:info, "left for claude-code to pick up (operator_messages)"})
      AgentMessageNotes.line(delivery(via: "picked_up"))
        .should eq({:success, "→ claude-code picked it up (operator_messages)"})
    end

    it "reports a refusal with the courier's reason" do
      AgentMessageNotes.line(delivery(ok: false, reason: "session is busy"))
        .should eq({:warn, "claude-code: session is busy"})
    end

    it "still says something when the courier failed without saying why" do
      AgentMessageNotes.line(delivery(ok: false)).should eq({:warn, "claude-code: delivery failed"})
    end

    it "reads ok BEFORE via, so a failed poll is not reported as still on its way" do
      level, message = AgentMessageNotes.line(delivery(via: "poll", ok: false, reason: "no queue"))
      level.should eq(:warn)
      message.should_not contain("left for")
    end

    it "scrubs the label a foreign process wrote" do
      line = AgentMessageNotes.line(delivery(target_label: "clau\u0000de  code"))
      line.should eq({:success, "→ claude code got it (socket)"})
    end

    it "keeps a note when the foreign process named nobody at all" do
      AgentMessageNotes.line(delivery(target_label: "")).should eq({:success, "→ agent got it (socket)"})
    end
  end
end

describe "the delivery drain's wiring" do
  it "runs beside the presence scan, OUTSIDE the data_version branch" do
    lines = src("tui", "runner.cr")
    presence = lines.index(&.includes?("dirty = true if refresh_agent_presence")).not_nil!
    drain = lines.index(&.includes?("dirty = true if drain_agent_deliveries")).not_nil!
    # Same indentation ⇒ same block. The presence poll's placement is the documented one
    # (a marker moves no data_version); the drain sits with it because its cursor, not the
    # DB version, is what keeps it from announcing a reply twice.
    lines[drain][/\A\s*/].should eq(lines[presence][/\A\s*/])
    (drain - presence).should be < 10
  end

  it "seeds its cursor at NOW, so opening a project does not replay old replies" do
    seeded = src("tui", "runner.cr").any? do |l|
      l.includes?("@agent_delivery_cursor = @session.store.last_agent_delivery_id")
    end
    seeded.should be_true
  end
end

describe Gori::Tui::AgentsOverlay, "tell affordance (#1090)" do
  it "hands the selected entry to on_tell on bare t, and closes nothing itself" do
    a = mcp_entry("claude-code", 1_i64)
    b = mcp_entry("codex", 2_i64)
    ov = agents_overlay([a, b])
    told = [] of Gori::AgentPresence::Entry
    ov.on_tell = ->(e : Gori::AgentPresence::Entry) { told << e; nil }
    ov.handle_key(tkey).should eq(:stay)
    told.map(&.pid).should eq([1_i64]) # the first row, where the cursor rests
    ov.hint.should contain("t tell")
  end

  it "ignores t when nothing is attached or the chord is modified" do
    ov = agents_overlay([] of Gori::AgentPresence::Entry)
    told = 0
    ov.on_tell = ->(_e : Gori::AgentPresence::Entry) { told += 1; nil }
    ov.handle_key(tkey)
    ov.selected_entry.should be_nil
    told.should eq(0)
    one = agents_overlay([mcp_entry])
    one.on_tell = ->(_e : Gori::AgentPresence::Entry) { told += 1; nil }
    one.handle_key(tkey(:ctrl))
    told.should eq(0) # ^T is not the mnemonic
  end
end
