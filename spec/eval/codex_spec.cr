require "spec"
require "file_utils"
require "../../eval/codex"

private def codex_stream(events : String, script = false)
  path = File.tempname("gori-codex-stream")
  File.write(path, events)
  EvalCodex.read_stream(path, script, "/repo/eval")
ensure
  File.delete(path) if path && File.exists?(path)
end

describe EvalCodex do
  it "detects global instructions independently of user config" do
    home = File.tempname("gori-codex-instructions")
    Dir.mkdir(home)
    EvalCodex.instructions_file(home).should be_nil
    File.write(File.join(home, "AGENTS.md"), "personal instructions")
    EvalCodex.instructions_file(home).should eq(File.join(home, "AGENTS.md"))
    File.write(File.join(home, "AGENTS.override.md"), "override")
    EvalCodex.instructions_file(home).should eq(File.join(home, "AGENTS.override.md"))
  ensure
    FileUtils.rm_rf(home) if home
  end

  it "counts MCP calls once, reads the final answer and does not double-count cached input" do
    stream = codex_stream(<<-JSONL)
      {"type":"item.started","item":{"id":"1","type":"mcp_tool_call","server":"gori","tool":"list_flows","arguments":{}}}
      {"type":"item.completed","item":{"id":"1","type":"mcp_tool_call","server":"gori","tool":"list_flows","arguments":{},"result":{}}}
      {"type":"item.completed","item":{"id":"2","type":"agent_message","text":"ANSWER: [3]"}}
      {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":12}}
      JSONL
    stream.calls.should eq(["list_flows"])
    stream.foreign.should eq(0)
    stream.peeked.should be_false
    stream.text.should eq("ANSWER: [3]")
    stream.input_tokens.should eq(100)
    stream.output_tokens.should eq(12)
    stream.turns.should eq(1)
    stream.error.should be_false
  end

  it "voids truncated and failed streams even if they contain an answer" do
    codex_stream("").error.should be_true
    codex_stream(%({"type":"item.completed","item":{"id":"1","type":"agent_message","text":"ANSWER: 3"}})).error.should be_true
    codex_stream(<<-JSONL).error.should be_true
      {"type":"turn.failed","error":{"message":"rate limit"}}
      {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
      JSONL
  end

  it "ignores nonfatal diagnostic items and still inspects updated call arguments" do
    stream = codex_stream(<<-JSONL)
      {"type":"item.completed","item":{"id":"0","type":"error","message":"Under-development features enabled"}}
      {"type":"item.started","item":{"id":"1","type":"mcp_tool_call","server":"gori","tool":"get_flow"}}
      {"type":"item.updated","item":{"id":"1","type":"mcp_tool_call","server":"gori","tool":"get_flow","arguments":{"path":"results.jsonl"}}}
      {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
      JSONL
    stream.calls.should eq(["get_flow"])
    stream.foreign.should eq(0)
    stream.peeked.should be_true
    stream.error.should be_false
  end

  it "allows shell only for script, flags foreign MCP calls and catches answer-key peeking" do
    events = <<-JSONL
      {"type":"item.completed","item":{"id":"1","type":"command_execution","command":"cat capture.har"}}
      {"type":"item.completed","item":{"id":"2","type":"mcp_tool_call","server":"other","tool":"read","arguments":{"path":"/repo/eval/out/ops.truth.json"}}}
      {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
      JSONL
    codex_stream(events).foreign.should eq(2)
    script = codex_stream(events, script: true)
    script.calls.should eq(["shell", "mcp__other__read"])
    script.foreign.should eq(1)
    script.peeked.should be_true
  end

  it "rejects gori calls in the script control and unrecognized external actions" do
    stream = codex_stream(<<-JSONL, script: true)
      {"type":"item.completed","item":{"id":"1","type":"mcp_tool_call","server":"gori","tool":"list_flows","arguments":{}}}
      {"type":"item.completed","item":{"id":"2","type":"web_search","query":"answer"}}
      {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
      JSONL
    stream.foreign.should eq(2)
  end

  it "passes MCP configuration as argv, disables shell and leaves the model default optional" do
    args = EvalCodex.args("prompt", nil, false, "rule", "/a b/gori", "/a b/db", "/home", ["--tools=@minimal"])
    args.first.should eq("exec")
    args.last.should eq("prompt")
    args.should contain("--ignore-user-config")
    args.should contain("project_doc_max_bytes=0")
    args.should contain("skills.include_instructions=false")
    args.should contain("features.memories=false")
    args.should contain("features.shell_tool=false")
    args.should contain("mcp_servers.gori.command=\"/a b/gori\"")
    args.should contain("mcp_servers.gori.args=[\"mcp\",\"--db\",\"/a b/db\",\"--tools=@minimal\"]")
    args.should_not contain("--model")
    script = EvalCodex.args("prompt", "test-model", true, "rule", "gori", "db", "home", [] of String)
    script.should contain("features.shell_tool=true")
    script.should contain("test-model")
    script.any?(&.starts_with?("mcp_servers.")).should be_false
  end
end
