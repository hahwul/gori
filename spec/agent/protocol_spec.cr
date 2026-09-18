require "../spec_helper"
require "../../src/gori/agent/protocol"

# Every line of a recorded run through `parse`, in order. The fixtures are verbatim CLI
# 2.1.276 output (paths and catalogues trimmed), so a frame shape this spec pins is one the
# real child emits.
private def events_of(fixture : String) : Array(Gori::Agent::Event::Any)
  path = File.join(__DIR__, "..", "fixtures", "agent", fixture)
  File.read_lines(path).flat_map { |l| Gori::Agent::Claude::Protocol.parse(l) }
end

private macro count_of(events, type)
  {{ events }}.count { |e| e.is_a?({{ type }}) }
end

private alias Ev = Gori::Agent::Event
private alias P = Gori::Agent::Claude::Protocol

describe Gori::Agent::Claude::Protocol do
  describe "a two-turn text exchange" do
    it "yields one TurnStarted per turn, because system/init repeats" do
      evs = events_of("two_turns.ndjson")
      starts = evs.select(Ev::TurnStarted)
      starts.size.should eq(2)
      starts[0].session_id.should eq(starts[1].session_id)
      starts[0].model.should eq("claude-haiku-4-5-20251001")
      starts[0].capabilities.should contain("interrupt_receipt_v1")
    end

    it "closes each turn with the final text and no denials" do
      dones = events_of("two_turns.ndjson").select(Ev::TurnDone)
      dones.map(&.subtype).should eq(["success", "success"])
      dones[0].text.should eq("PONG1")
      dones[1].text.should eq("PONG2\nPONG1")
      dones.all? { |d| d.denials == 0 }.should be_true
      dones.all? { |d| d.cost_usd > 0 }.should be_true
    end

    it "streams deltas ahead of the complete block, and persists only the block" do
      evs = events_of("two_turns.ndjson")
      count_of(evs, Ev::TextDelta).should eq(4)
      evs.select(Ev::AssistantText).map(&.text).should eq(["PONG1", "PONG2\nPONG1"])
      evs.select(Ev::TextDelta).map(&.text).join.should eq("PONG1PONG2\nPONG1")
    end

    it "drops the frames that carry nothing to show, and raises on none" do
      evs = events_of("two_turns.ndjson")
      count_of(evs, Ev::Raw).should eq(0)
      count_of(evs, Ev::ToolUse).should eq(0)
      # thinking is redacted to a signature on the wire; the deltas are empty strings
      evs.select(Ev::ThinkingDelta).all?(&.text.empty?).should be_true
    end
  end

  describe "a gated tool call" do
    it "asks for permission with the tool, its input and the block it gates" do
      evs = events_of("permission_allow.ndjson")
      asks = evs.select(Ev::PermissionAsked)
      asks.size.should eq(1)
      ask = asks[0]
      ask.tool.should eq("Bash")
      ask.display.should eq("Bash")
      ask.request_id.should_not be_empty
      ask.input_json.should contain("mkdir -p /tmp/gori-fx-dir")
      ask.description.should eq("Create directory and verify its existence")
      use = evs.select(Ev::ToolUse).first
      use.name.should eq("Bash")
      use.id.should eq(ask.tool_use_id)
      use.input_json.should contain("mkdir -p /tmp/gori-fx-dir")
    end

    it "reports the tool result the model was fed, on allow" do
      results = events_of("permission_allow.ndjson").select(Ev::ToolResult)
      results.size.should eq(1)
      # the CLI prefixes tool output with a private-use marker glyph (U+F115); wire-faithful
      results[0].content.should end_with(" /tmp/gori-fx-dir")
      results[0].is_error.should be_false
      events_of("permission_allow.ndjson").select(Ev::TurnDone).first.denials.should eq(0)
    end

    it "reports the denial as an error result and counts it on the turn" do
      evs = events_of("permission_deny.ndjson")
      result = evs.select(Ev::ToolResult).first
      result.is_error.should be_true
      result.content.should eq("operator denied in gori")
      evs.select(Ev::TurnDone).first.denials.should eq(1)
    end
  end

  describe "lines it does not speak" do
    it "ignores an unknown type by contract" do
      P.parse(%({"type":"a_newer_frame","x":1})).should be_empty
      P.parse(%({"type":"rate_limit_event","rate_limit_info":{}})).should be_empty
      P.parse(%({"type":"system","subtype":"status"})).should be_empty
      P.parse(%({"type":"control_response","response":{}})).should be_empty
    end

    it "turns malformed JSON and non-object JSON into Raw, capped" do
      P.parse("not json at all")[0].as(Ev::Raw).line.should eq("not json at all")
      P.parse("[1,2]")[0].should be_a(Ev::Raw)
      long = "x" * (P::RAW_KEEP + 10)
      raw = P.parse(long)[0].as(Ev::Raw)
      raw.truncated.should be_true
      raw.line.bytesize.should eq(P::RAW_KEEP)
    end

    it "surfaces a control_request it cannot answer rather than dropping it" do
      line = %({"type":"control_request","request_id":"r1","request":{"subtype":"hook_callback"}})
      P.parse(line)[0].as(Ev::Raw).line.should eq(line)
    end

    it "skips a sub-agent's own stream" do
      line = %({"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"text","text":"inner"}]}})
      P.parse(line).should be_empty
    end

    it "takes the text parts of a block-array tool result" do
      line = %({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":"a"},{"type":"image"},{"type":"text","text":"b"}]}]}})
      P.parse(line)[0].as(Ev::ToolResult).content.should eq("ab")
    end
  end

  describe "outbound frames" do
    it "builds a user turn the CLI accepts" do
      j = JSON.parse(P.user_turn("hi\nthere"))
      j["type"].should eq("user")
      j["message"]["role"].should eq("user")
      j["message"]["content"][0]["text"].should eq("hi\nthere")
      P.user_turn("x").includes?('\n').should be_false
    end

    it "answers allow with the input echoed as updatedInput" do
      j = JSON.parse(P.permission_response("r1", true, %({"command":"ls"}), nil))
      j["type"].should eq("control_response")
      j["response"]["subtype"].should eq("success")
      j["response"]["request_id"].should eq("r1")
      j["response"]["response"]["behavior"].should eq("allow")
      j["response"]["response"]["updatedInput"]["command"].should eq("ls")
    end

    it "collapses a missing or non-object input to an empty object on allow" do
      JSON.parse(P.permission_response("r", true, nil, nil))["response"]["response"]["updatedInput"].as_h.should be_empty
      JSON.parse(P.permission_response("r", true, "[1]", nil))["response"]["response"]["updatedInput"].as_h.should be_empty
      JSON.parse(P.permission_response("r", true, "{oops", nil))["response"]["response"]["updatedInput"].as_h.should be_empty
    end

    it "answers deny with a message that names the refuser" do
      j = JSON.parse(P.permission_response("r2", false, nil, nil))
      j["response"]["response"]["behavior"].should eq("deny")
      j["response"]["response"]["message"].as_s.should contain("gori")
      JSON.parse(P.permission_response("r2", false, nil, "no"))["response"]["response"]["message"].should eq("no")
    end

    it "builds an interrupt request" do
      j = JSON.parse(P.interrupt("i1"))
      j["type"].should eq("control_request")
      j["request_id"].should eq("i1")
      j["request"]["subtype"].should eq("interrupt")
    end
  end
end
