require "../spec_helper"
require "../../src/gori/agent/transcript"

private alias T = Gori::Agent::Transcript

private def with_call(t : T, id = "toolu_1") : T
  t.append("assistant", "tool_use", "Bash", payload: %({"command":"git status","description":"x"}),
    tool_name: "Bash", tool_use_id: id)
  t.append("tool", "tool_result", "a\nb\nc", tool_use_id: id)
  t
end

describe Gori::Agent::Transcript do
  it "flattens a user turn with a prompt marker and continuation indent" do
    t = T.new
    t.append("user", "text", "first\nsecond")
    t.lines.should eq(["› first", "  second"])
    t.size.should eq(2)
    t.line_at(1).should eq("  second")
  end

  it "keeps the streamed tail separate from the stable document" do
    t = T.new
    t.append("user", "text", "hi")
    v = t.version
    t.push_delta("PON")
    t.push_delta("G\nnext")
    t.tail.should eq("PONG\nnext")
    t.lines.should eq(["› hi", "PONG", "next"])
    t.version.should be > v
    t.append("assistant", "text", "PONG\nnext")
    t.tail.should be_empty
    t.lines.should eq(["› hi", "PONG", "next"])
  end

  it "folds a tool call and its result to one line each" do
    t = with_call(T.new)
    t.lines.should eq(["▸ Bash(git status)", "  ✓ 3 lines"])
    t.tool_use_id_at(0).should eq("toolu_1")
    t.tool_use_id_at(1).should eq("toolu_1")
    t.tool_use_id_at(2).should be_nil
  end

  it "expands both halves together and caps a long output" do
    t = with_call(T.new)
    t.toggle("toolu_1")
    t.expanded?("toolu_1").should be_true
    lines = t.lines
    lines[0].should eq("▾ Bash")
    lines.should contain(%(      "command": "git status",))
    lines.should contain("  ✓ ok · 3 lines")
    lines.should contain("    a")
    t.toggle("toolu_1")
    t.lines.should eq(["▸ Bash(git status)", "  ✓ 3 lines"])

    big = T.new
    big.append("assistant", "tool_use", "Read", payload: %({"file_path":"/x"}), tool_name: "Read", tool_use_id: "r")
    big.append("tool", "tool_result", (1..(T::EXPANDED_LINE_CAP + 5)).join("\n"), tool_use_id: "r")
    big.toggle("r")
    big.lines.last.should eq("    … 5 more lines")
    big.lines.size.should eq(1 + 3 + 1 + T::EXPANDED_LINE_CAP + 1) # head, 3 pretty-json lines, result head, cap, elision
  end

  it "shows an error result's first line even when folded" do
    t = T.new
    t.append("assistant", "tool_use", "Bash", payload: %({"command":"x"}), tool_name: "Bash", tool_use_id: "e")
    t.append("tool", "tool_result", "boom happened\nmore", tool_use_id: "e", is_error: true)
    t.lines[1].should eq("  ✗ error: boom happened")
  end

  it "previews the argument a human would name the call by" do
    T.preview("Bash", %({"command":"ls -la","description":"list"})).should eq("ls -la")
    T.preview("Read", %({"file_path":"/etc/hosts"})).should eq("/etc/hosts")
    T.preview("Weird", %({"a":1})).should eq(%({"a":1}))
    T.preview("Bash", %({"command":"a\\nb"})).should eq("a⏎b")
    T.preview("Bash", ("x" * 100).inspect).should end_with("…")
    T.preview("Bash", "{garbage").should eq("{garbage")
    T.preview("Bash", nil).should eq("")
  end

  it "caps a message on a character boundary and marks it" do
    t = T.new
    text = "é" * (T::MAX_MESSAGE_BYTES // 2 + 10) # 2 bytes each, crosses the cap mid-char
    m = t.append("assistant", "text", text)
    m.truncated?.should be_true
    m.text.bytesize.should be <= T::MAX_MESSAGE_BYTES
    m.text.valid_encoding?.should be_true
    m.text.ends_with?('�').should be_false
  end

  it "drops the oldest messages past the cap and rebuilds" do
    t = T.new
    (T::MAX_MESSAGES + 3).times { |i| t.append("user", "text", "m#{i}") }
    t.messages.size.should eq(T::MAX_MESSAGES)
    t.messages.first.text.should eq("m3")
    t.lines.first.should eq("› m3")
    t.next_seq.should eq(T::MAX_MESSAGES + 3)
  end

  it "loads stored rows and continues the sequence after them" do
    t = T.new
    rows = [Gori::Agent::Message.new(4, "user", "text", "old"), Gori::Agent::Message.new(5, "assistant", "text", "reply")]
    t.load(rows)
    t.lines.should eq(["› old", "reply"])
    t.append("user", "text", "new").seq.should eq(6)
  end

  it "draws the system rows" do
    t = T.new
    t.append("system", "permission", "allowed Bash for this session")
    t.append("system", "result", "")
    t.append("system", "error", "agent exited: 143")
    t.append("system", "raw", "{weird}")
    t.append("assistant", "thinking", "")
    t.lines.should eq(["⚑ allowed Bash for this session", "", "! agent exited: 143", "? {weird}"])
  end
end
