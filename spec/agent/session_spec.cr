require "../spec_helper"
require "../support/fake_claude"

# The hosted session against a fake `claude` (spec/support/fake_claude.cr) that replays the
# recorded fixtures, blocks on a control_request the way the real CLI does, hangs, or dies.
# No Runner: `drain` is pumped by hand with a deadline, which is exactly what the tick does.

private alias Ev = Gori::Agent::Event
private alias Decision = Gori::Agent::Decision

private FIXTURES = File.join(__DIR__, "..", "fixtures", "agent")

# A backend that launches the fake script instead of `claude`, and otherwise speaks Claude.
private class ScriptBackend < Gori::Agent::ClaudeBackend
  def initialize(@script : String)
  end

  def argv(config : Gori::Agent::Config, session_uuid : String, resume_uuid : String?,
           mcp_config_path : String) : Array(String)
    [@script]
  end
end

# A store AND its path: `Config` needs the db path to hand the child its MCP config.
private def with_db(&)
  path = File.tempname("gori-agent-spec", ".db")
  store = Gori::Store.open(path)
  begin
    yield store, path
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
    FileUtils.rm_rf("#{path}.agent")
  end
end

# Pump `drain` until the block is satisfied or the deadline passes. Returns whether it was.
private def pump(session : Gori::Agent::Session, timeout = 5.seconds, &) : Bool
  deadline = Time.instant + timeout
  loop do
    session.drain
    return true if yield
    return false if Time.instant >= deadline
    sleep 10.milliseconds
  end
end

private def with_session(kind : Symbol, fixture : String? = nil, &)
  fixture_path = fixture ? File.join(FIXTURES, fixture) : nil
  FakeClaude.with_script(kind, fixture_path) do |script|
    with_db do |store, path|
      session = Gori::Agent::Session.new(ScriptBackend.new(script), Gori::Agent::Config.new(db_path: path), store)
      begin
        yield session, store
      ensure
        session.stop
        # let the teardown fiber run before the store closes under it
        pump(session, 2.seconds) { session.dead? }
      end
    end
  end
end

describe Gori::Agent::Session do
  it "starts idle, runs two turns with context, and persists message boundaries only" do
    with_session(:replay, "two_turns.ndjson") do |s, store|
      s.dead?.should be_true
      s.start.should be_true
      s.idle?.should be_true
      s.send("Reply with exactly the word PONG1 and nothing else.").should be_true
      s.running?.should be_true
      s.send("second while running").should be_false
      pump(s) { s.idle? }.should be_true
      s.turns.should eq(1)
      s.model.should eq("claude-haiku-4-5-20251001")
      s.can_interrupt?.should be_true
      s.transcript.lines.should contain("PONG1")

      s.send("and again").should be_true
      pump(s) { s.idle? && s.turns == 2 }.should be_true
      s.transcript.lines.should contain("PONG2")
      s.cost_usd.should be > 0

      # the store mirrors the transcript: one row per finished message, no deltas
      id = s.store_id.not_nil!
      rows = store.agent_messages(id)
      rows.map(&.kind).should eq(%w[text text result text text result])
      rows.map(&.role).should eq(%w[user assistant system user assistant system])
      rows[0].text.should eq("Reply with exactly the word PONG1 and nothing else.")
      rows[1].text.should eq("PONG1")
      row = store.agent_session(id).not_nil!
      row.title.should eq("Reply with exactly the word PONG1 and nothing else.")
      row.turns.should eq(2)
      row.cost_usd.should be > 0
      row.model.should eq("claude-haiku-4-5-20251001")
      row.session_uuid.should eq(s.session_uuid)
    end
  end

  it "queues a permission request, answers allow, and the turn completes" do
    with_session(:replay, "permission_allow.ndjson") do |s, store|
      s.start.should be_true
      s.send("run it").should be_true
      pump(s) { s.awaiting_permission? }.should be_true
      req = s.pending.first
      req.tool.should eq("Bash")
      s.running?.should be_true
      # nothing moves until an answer: the fake blocks like the CLI
      pump(s, 300.milliseconds) { s.idle? }.should be_false
      s.answer_permission(req.request_id, Decision::Allow)
      s.pending.should be_empty
      pump(s) { s.idle? }.should be_true
      lines = s.transcript.lines
      lines.should contain("⚑ allowed Bash")
      lines.should contain("▸ Bash(mkdir -p /tmp/gori-fx-dir && ls -d /tmp/gori-fx-dir)")
      lines.should contain("  ✓ 1 line")
      kinds = store.agent_messages(s.store_id.not_nil!).map(&.kind)
      kinds.should eq(%w[text tool_use permission tool_result text result])
      s.answer_permission("no-such-id", Decision::Deny) # ignored, not raised
    end
  end

  it "remembers a session grant and answers the next ask itself" do
    with_session(:replay, "permission_allow.ndjson") do |s, _store|
      s.start.should be_true
      s.send("run it")
      pump(s) { s.awaiting_permission? }.should be_true
      s.answer_permission(s.pending.first.request_id, Decision::AllowForSession)
      s.session_allow.should contain("Bash")
      pump(s) { s.idle? }.should be_true
      s.transcript.lines.should contain("⚑ allowed Bash for this session")
      # a second identical ask never reaches `pending`. The fixture holds one turn, so the
      # replay is restarted (resume keeps the grant: it lives with the Session, not the child).
      s.restart(resume: true).should be_true
      s.send("again").should be_true
      pump(s) { s.idle? }.should be_true
      s.pending.should be_empty
      s.transcript.lines.should contain("⚑ allowed Bash (session grant)")
    end
  end

  it "denies under the deny policy without asking, and records the denial" do
    FakeClaude.with_script(:replay, File.join(FIXTURES, "permission_deny.ndjson")) do |script|
      with_db do |store, path|
        cfg = Gori::Agent::Config.new(db_path: path, permission_policy: "deny")
        s = Gori::Agent::Session.new(ScriptBackend.new(script), cfg, store)
        begin
          s.start.should be_true
          s.send("run it")
          pump(s) { s.idle? }.should be_true
          s.pending.should be_empty
          s.transcript.lines.should contain("⚑ denied Bash (policy)")
          s.transcript.lines.should contain("  ✗ error: operator denied in gori")
        ensure
          s.stop
          pump(s, 2.seconds) { s.dead? }
        end
      end
    end
  end

  it "stops a hung child without blocking, and reports the orphaned permission" do
    with_session(:hang, nil) do |s, _store|
      s.start.should be_true
      s.send("hello")
      # smuggle a pending request so the death path has something to explain
      s.pending << Ev::PermissionAsked.new("r", "Bash", "Bash", "{}", "", "", "t")
      t0 = Time.instant
      s.stop
      (Time.instant - t0).should be < 200.milliseconds
      s.dead?.should be_true
      s.dead_reason.should eq("stopped")
      s.transcript.lines.should contain("! Bash was waiting for permission when the agent exited")
      s.send("after death").should be_false
    end
  end

  it "goes dead with the stderr tail when the child crashes" do
    with_session(:crash, nil) do |s, _store|
      s.start.should be_true
      pump(s) { s.dead? }.should be_true
      s.dead_reason.should contain("boom")
      s.transcript.lines.should contain("! agent exited: fake claude: boom")
    end
  end

  it "goes dead with the exit status when the child quits silently mid-turn" do
    with_session(:silent_exit, nil) do |s, store|
      s.start.should be_true
      s.send("hello")
      pump(s) { s.dead? }.should be_true
      s.dead_reason.should eq("exited")
      store.agent_session(s.store_id.not_nil!).not_nil!.ended_at.should_not be_nil
    end
  end

  it "refuses to start when the command does not exist, with a reason the tab can draw" do
    with_db do |store, path|
      s = Gori::Agent::Session.new(ScriptBackend.new("/nonexistent/claude-#{Random.rand(1 << 30)}"),
        Gori::Agent::Config.new(db_path: path), store)
      s.start.should be_false
      s.dead?.should be_true
      s.dead_reason.should end_with(": not found")
    end
  end

  it "restarts with a fresh uuid, resuming the conversation and its store row" do
    with_session(:replay, "two_turns.ndjson") do |s, store|
      s.start.should be_true
      s.send("first")
      pump(s) { s.idle? }.should be_true
      first_uuid = s.session_uuid
      id = s.store_id.not_nil!
      s.restart(resume: true).should be_true
      s.session_uuid.should_not eq(first_uuid)
      s.store_id.should eq(id)
      s.transcript.lines.should contain("PONG1") # kept
      row = store.agent_session(id).not_nil!
      row.session_uuid.should eq(s.session_uuid)
      row.resumed_from.should eq(first_uuid)

      s.restart(resume: false).should be_true
      s.store_id.should be_nil
      s.transcript.messages.should be_empty
    end
  end

  it "keeps 'awaiting permission' derived from the queue, not a flag" do
    with_session(:replay, "permission_allow.ndjson") do |s, _store|
      s.start.should be_true
      s.awaiting_permission?.should be_false
      s.send("run it")
      pump(s) { !s.pending.empty? }.should be_true
      s.awaiting_permission?.should eq(s.running? && !s.pending.empty?)
      s.answer_permission(s.pending.first.request_id, Decision::Deny)
      s.awaiting_permission?.should be_false
    end
  end
end
