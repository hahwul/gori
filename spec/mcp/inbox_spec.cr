require "../spec_helper"
require "../../src/gori/mcp/inbox"

private alias Inbox = Gori::MCP::ClaudeInbox

# A stand-in for the CLI's inbox: accepts one connection, reads it to EOF, hands back the lines.
private def with_inbox(&)
  dir = File.tempname("gori-inbox")
  Dir.mkdir_p(dir)
  path = File.join(dir, "1.sock")
  server = UNIXServer.new(path)
  got = Channel(Array(String)).new(1)
  spawn do
    if client = server.accept?
      got.send(client.gets_to_end.lines)
      client.close
    end
  end
  begin
    yield path, got
  ensure
    server.close rescue nil
    FileUtils.rm_rf(dir)
  end
end

describe Gori::MCP::ClaudeInbox do
  it "names the socket after the parent pid, env first, both directory shapes" do
    c = Inbox.candidates(4242_i64)
    c.should contain("/tmp/cc-socks/4242.sock")
    c.any?(&.ends_with?("/4242.sock")).should be_true
    c.size.should be >= 2
  end

  it "discovers only a path that is a live socket" do
    # This spec may itself run under a Claude Code session, whose env names a real socket:
    # clear it so the pid candidates are the only ones in play, and restore it after.
    saved = ENV["CLAUDE_CODE_MESSAGING_SOCKET"]?
    ENV.delete("CLAUDE_CODE_MESSAGING_SOCKET")
    begin
      Inbox.discover(1_i64 << 40).should be_nil # no such pid, no such file
      with_inbox do |path, _|
        # the env override is trusted only when it names THIS parent pid (the fake is 1.sock):
        # a server under Codex, or under a nested Claude session, inherits the OUTER session's
        # socket and must not write there
        ENV["CLAUDE_CODE_MESSAGING_SOCKET"] = path
        Inbox.discover(1_i64).should eq(path)
        Inbox.discover(1_i64 << 40).should be_nil
      end
    ensure
      ENV.delete("CLAUDE_CODE_MESSAGING_SOCKET")
      ENV["CLAUDE_CODE_MESSAGING_SOCKET"] = saved if saved
    end
  end

  it "writes the auth line when a token is known, then the user line, and closes" do
    with_inbox do |path, got|
      Inbox.deliver(path, "hello", token: "tok").should be_nil
      lines = got.receive
      lines.size.should eq(2)
      JSON.parse(lines[0])["type"].should eq("auth")
      JSON.parse(lines[0])["token"].should eq("tok")
      u = JSON.parse(lines[1])
      u["type"].should eq("user")
      u["message"]["role"].should eq("user")
      u["message"]["content"].should eq("hello")
    end
    with_inbox do |path, got|
      Inbox.deliver(path, "no token", token: nil).should be_nil
      got.receive.size.should eq(1)
    end
  end

  it "reports a refused or missing socket instead of raising" do
    reason = Inbox.deliver("/nonexistent/gori-inbox.sock", "x", token: nil)
    reason.should_not be_nil
    reason.not_nil!.should contain("not accepting")
  end
end
