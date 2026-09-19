require "../spec_helper"
require "../support/mcp_harness"
require "../../src/gori/mcp/codex_queue"

private alias CQ = Gori::MCP::CodexQueue

# A `codex` on PATH that is a shell script: it records the argv and the CODEX_HOME it was
# given, and exits with the code the caller asked for. The real CLI's contract is exactly
# this much — argv in, exit code and a sentence out — so a stand-in pins the half gori owns.
private def with_fake_codex(exit_code : Int32 = 0, stderr : String = "", &)
  dir = File.tempname("gori-codex-bin")
  Dir.mkdir_p(dir)
  log = File.join(dir, "argv.txt")
  File.write(File.join(dir, "codex"), <<-SH)
    #!/bin/sh
    printf '%s\\n' "$@" > #{log}
    printf 'CODEX_HOME=%s\\n' "$CODEX_HOME" >> #{log}
    #{stderr.empty? ? "" : "echo #{stderr.inspect} >&2"}
    exit #{exit_code}
    SH
  File.chmod(File.join(dir, "codex"), 0o755)
  saved = ENV["PATH"]
  ENV["PATH"] = "#{dir}:#{saved}"
  begin
    yield log
  ensure
    ENV["PATH"] = saved
    FileUtils.rm_rf(dir)
  end
end

describe Gori::MCP::CodexQueue do
  it "claims the codex client family by prefix, and nothing else" do
    CQ.client?("codex-mcp-client").should be_true
    CQ.client?("Codex").should be_true
    CQ.client?("claude-code").should be_false
    CQ.client?("antigravity").should be_false
    CQ.client?(nil).should be_false
  end

  it "reads the thread id and the CODEX_HOME out of the writer lock's path" do
    s = CQ.session_in(["/dev/null",
                       "/Users/x/.codex/thread-writer-locks/01a0b92e-f7d0-77d3-8ba9-61e53e67a768.lock"])
    s.should_not be_nil
    s.not_nil!.thread.should eq("01a0b92e-f7d0-77d3-8ba9-61e53e67a768")
    # Both halves come from the one path: queuing into the DEFAULT home would miss a session
    # started with its own.
    s.not_nil!.home.should eq("/Users/x/.codex")
  end

  it "refuses a lock whose name is not a uuid — the id goes onto a command line" do
    CQ.session_in(["/Users/x/.codex/thread-writer-locks/--message.lock"]).should be_nil
    CQ.session_in(["/Users/x/.codex/thread-writer-locks/01a0b92e.lock"]).should be_nil
    CQ.session_in(["/Users/x/.codex/sessions/01a0b92e-f7d0-77d3-8ba9-61e53e67a768.lock"]).should be_nil
    CQ.session_in([] of String).should be_nil
  end

  it "finds a live lock through the platform's open-file list" do
    # Against THIS process, which is the same question `discover` asks about its parent — and
    # the only way to pin the `/proc` and `lsof` halves on the platform that runs them.
    dir = File.tempname("gori-codex-home")
    locks = File.join(dir, "thread-writer-locks")
    Dir.mkdir_p(locks)
    thread = "01a0b92e-f7d0-77d3-8ba9-61e53e67a768"
    path = File.join(locks, "#{thread}.lock")
    File.write(path, "")
    file = File.open(path, "r")
    begin
      session = CQ.session_in(CQ.open_files(Process.pid.to_i64))
      session.should_not be_nil
      session.not_nil!.thread.should eq(thread)
      # `File.tempname` can hand back a symlinked prefix (/var → /private/var on macOS), which
      # the kernel's own answer resolves; compare on the part that cannot drift.
      session.not_nil!.home.should end_with(File.basename(dir))
    ensure
      file.close
      FileUtils.rm_rf(dir)
    end
  end

  it "hands the line to `codex queue` with the thread's own home" do
    with_fake_codex do |log|
      session = CQ::Session.new("01a0b92e-f7d0-77d3-8ba9-61e53e67a768", "/tmp/some-codex-home")
      CQ.deliver(session, "[gori] look at flow 12").should be_nil
      argv = File.read(log).lines
      argv[0].should eq("queue")
      argv[1].should eq("--thread")
      argv[2].should eq("01a0b92e-f7d0-77d3-8ba9-61e53e67a768")
      argv[3].should eq("--message")
      argv[4].should eq("[gori] look at flow 12")
      argv.last.should eq("CODEX_HOME=/tmp/some-codex-home")
    end
  end

  it "reports what the CLI said when it refuses, rather than claiming a delivery" do
    with_fake_codex(exit_code: 1, stderr: "no rollout found for thread id 01a0b92e") do |_|
      session = CQ::Session.new("01a0b92e-f7d0-77d3-8ba9-61e53e67a768", "/tmp/h")
      reason = CQ.deliver(session, "hi")
      reason.should_not be_nil
      # The child's own words are the whole diagnosis; `failure` carries them after the code.
      reason.not_nil!.should contain("no rollout found")
    end
  end

  it "says so when there is no codex to run, instead of raising into the courier" do
    saved = ENV["PATH"]
    ENV["PATH"] = "/nonexistent-#{Random.rand(1_000_000)}"
    begin
      reason = CQ.deliver(CQ::Session.new("01a0b92e-f7d0-77d3-8ba9-61e53e67a768", "/tmp/h"), "hi")
      reason.should eq("codex is not on this server's PATH")
    ensure
      ENV["PATH"] = saved
    end
  end
end
