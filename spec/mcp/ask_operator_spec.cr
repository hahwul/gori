require "../spec_helper"
require "../support/mcp_harness"
require "file_utils"

# MCP `ask_operator` (#1324): a question the operator answers on a card in the TUI. The tool
# returns at once; the answer comes back later as an operator message with `in_reply_to`.
private def ask(t : Gori::MCP::Tools, args : String) : Gori::MCP::Tools::Result
  t.call("ask_operator", JSON.parse(args))
end

describe "MCP ask_operator (#1324)" do
  it "writes the question and answers at once with its id and expiry" do
    with_store do |store|
      t = tools_for(store)
      r = ask(t, %({"question":"Add api.example.com to scope?","choices":["yes","no"],"default":"no","detail":"same cookie","expires_in_minutes":5}))
      r.is_error.should be_false
      j = JSON.parse(r.text)
      j["ok"].as_bool.should be_true
      j["question"].as_s.should eq("Add api.example.com to scope?")
      j["choices"].as_a.map(&.as_s).should eq(["yes", "no"])
      j["default"].as_s.should eq("no")
      j["tui"]["unknown"].as_bool.should be_true
      j["note"].as_s.should contain("in_reply_to")
      j["note"].as_s.should contain("not an authorization")
      j["expires_at_iso"].as_s.should_not be_empty
      q = store.open_agent_questions(0_i64, 0_i64).first
      q.id.should eq(j["id"].as_i64)
      q.pid.should eq(Process.pid.to_i64)
      q.detail.should eq("same cookie")
      left = q.expires_at - Time.utc.to_unix_ms * 1000
      left.should be > 4 * 60_000_000_i64
      left.should be <= 5 * 60_000_000_i64
    end
  end

  # The one string-list rule every MCP list slot follows: a scalar entry is its text.
  it "reads scalar choices as their text, and forty columns of wide ones as fitting" do
    with_store do |store|
      r = ask(tools_for(store), %({"question":"which port?","choices":[80,443]}))
      r.is_error.should be_false
      JSON.parse(r.text)["choices"].as_a.map(&.as_s).should eq(["80", "443"])
      ask(tools_for(store), %({"question":"q","choices":["a","#{"가" * 20}"]})).is_error.should be_false
    end
  end

  it "accepts the choices as a JSON-encoded string, the way agents often send an array" do
    with_store do |store|
      r = ask(tools_for(store), %({"question":"go?","choices":"[\\"go\\",\\"stop\\"]"}))
      r.is_error.should be_false
      JSON.parse(r.text)["choices"].as_a.map(&.as_s).should eq(["go", "stop"])
    end
  end

  it "refuses what the card could not offer" do
    with_store do |store|
      t = tools_for(store)
      {
        %({"choices":["a","b"]})                            => "question",
        %({"question":"q"})                                 => "choices",
        %({"question":"q","choices":["only"]})              => "choices",
        %({"question":"q","choices":["a","b","c","d","e"]}) => "choices",
        %({"question":"q","choices":["a",""]})              => "choices",
        %({"question":"q","choices":["Yes","yes"]})         => "choices",
        %({"question":"q","choices":["a","#{"x" * 41}"]})   => "choices",
        # Twenty-one wide characters are 42 columns: the card clips them, and two that
        # differ only at the end would read the same.
        %({"question":"q","choices":["a","#{"가" * 21}"]}) => "choices",
        %({"question":"q","choices":["a",{"label":"b"}]}) => "choices",
        # A zero-width codepoint costs no column in a raw width table, but the card draws it
        # as a badge, and forty of them are forty characters besides.
        %({"question":"q","choices":["a","ok#{"\u200B" * 8}"]})           => "choices",
        %({"question":"q","choices":["a","a#{"\u0301" * 45}"]})           => "choices",
        %({"question":"q","choices":["a","b"],"default":"c"})             => "default",
        %({"question":"q","choices":["a","b"],"expires_in_minutes":0})    => "expires_in_minutes",
        %({"question":"q","choices":["a","b"],"expires_in_minutes":1441}) => "expires_in_minutes",
      }.each do |args, field|
        r = ask(t, args)
        r.is_error.should be_true
        r.field.should eq(field)
      end
      store.open_agent_questions(0_i64, 0_i64).should be_empty
    end
  end

  it "is not served by a read-only server" do
    with_store do |store|
      JSON.parse(JSON.build { |j| tools_for(store, allow_actions: false).list(j) }).as_a
        .map(&.["name"].as_s).should_not contain("ask_operator")
    end
  end

  # The asking process is the one that expires its question: with no TUI open nothing else
  # would ever tell the agent, and the row it writes goes back to it like an answer.
  it "expires its own unanswered question once its time is up, and only once" do
    with_store do |store|
      t = tools_for(store)
      id = JSON.parse(ask(t, %({"question":"q","choices":["a","b"],"expires_in_minutes":1})).text)["id"].as_i64
      t.expire_asked_questions(Time.utc.to_unix_ms * 1000).should eq(0) # not yet
      later = (Time.utc + 2.minutes).to_unix_ms * 1000
      t.expire_asked_questions(later).should eq(1)
      t.expire_asked_questions(later).should eq(0)
      m = store.agent_messages_after(id, Process.pid.to_i64, 10).rows.first
      m.in_reply_to.should eq(id)
      m.outcome.should eq("expired")
      store.events_after(0, 20).find(&.kind.==("agent_message")).not_nil!.source.should eq("agent")
    end
  end

  it "does not expire a question the operator already answered" do
    with_store do |store|
      t = tools_for(store)
      id = JSON.parse(ask(t, %({"question":"q","choices":["a","b"],"expires_in_minutes":1})).text)["id"].as_i64
      q = store.open_agent_questions(id - 1, 0_i64).first
      store.close_agent_question(q, Gori::AgentQuestion::OUTCOME_ANSWERED, "a", "operator", "tui")
      t.expire_asked_questions((Time.utc + 2.minutes).to_unix_ms * 1000).should eq(0)
      store.agent_messages_after(id, Process.pid.to_i64, 10).rows.map(&.outcome).should eq(["answered"])
    end
  end

  # The courier forgets a question as soon as it reads the answer; after that, an operator who
  # empties the feed must not turn the answered question into an "expired" one.
  it "does not expire a question the courier saw answered, even once the feed is cleared" do
    with_store do |store|
      t = tools_for(store)
      id = JSON.parse(ask(t, %({"question":"q","choices":["a","b"],"expires_in_minutes":1})).text)["id"].as_i64
      q = store.open_agent_questions(id - 1, 0_i64).first
      store.close_agent_question(q, Gori::AgentQuestion::OUTCOME_ANSWERED, "a", "operator", "tui")
      t.forget_question(id)
      store.clear_events.should be_true
      t.expire_asked_questions((Time.utc + 2.minutes).to_unix_ms * 1000).should eq(0)
      store.events_after(0, 10).should be_empty
    end
  end

  it "hands the answer to operator_messages with the question it closes" do
    with_store do |store|
      t = tools_for(store)
      id = JSON.parse(ask(t, %({"question":"q","choices":["a","b"]})).text)["id"].as_i64
      q = store.open_agent_questions(id - 1, 0_i64).first
      store.close_agent_question(q, Gori::AgentQuestion::OUTCOME_ANSWERED, "b", "operator", "tui", "history")
      msgs = JSON.parse(t.call("operator_messages", JSON.parse("{}")).text)["messages"].as_a
      msgs.size.should eq(1)
      msgs.first["text"].as_s.should eq("b")
      msgs.first["in_reply_to"].as_i64.should eq(id)
      msgs.first["outcome"].as_s.should eq("answered")
    end
  end

  it "rides the answer on the next tool result, framed as one" do
    with_store do |store|
      t = tools_for(store)
      id = JSON.parse(ask(t, %({"question":"send anyway?","choices":["send","skip"]})).text)["id"].as_i64
      q = store.open_agent_questions(id - 1, 0_i64).first
      store.close_agent_question(q, Gori::AgentQuestion::OUTCOME_DISMISSED, nil, "operator", "tui")
      note = t.pending_operator_note("list_history").not_nil!
      note.text.should contain("dismissed your ask_operator question ##{id}")
      t.release_operator_note(note)
    end
  end
end

# A registry home for a server bound the way `gori mcp` binds one, so switch_project works.
private def with_bound_home(tag, &)
  home = File.tempname(tag)
  saved = ENV["GORI_HOME"]?
  ENV["GORI_HOME"] = home
  begin
    yield Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
  ensure
    saved ? (ENV["GORI_HOME"] = saved) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(home)
  end
end

private def bound_tools(project) : Gori::MCP::Tools
  Gori::MCP::Tools.new(Gori::Store.open(project.db_path), true, false, project_name: project.name,
    db_path: project.db_path, selection_source: "workspace-created")
end

describe "ask_operator across switch_project" do
  # A switch opens a new Store on the same file, and the TUI offers the question again as soon
  # as this process's marker is back — so its expiry clock must survive the switch.
  it "still expires a question after a switch to the project already bound" do
    with_bound_home("gori-ask-same") do |reg|
      project = reg.create("target")
      t = bound_tools(project)
      begin
        id = JSON.parse(ask(t, %({"question":"q","choices":["a","b"],"expires_in_minutes":1})).text)["id"].as_i64
        t.call("switch_project", JSON.parse(%({"project":"target"}))).is_error.should be_false
        t.expire_asked_questions((Time.utc + 2.minutes).to_unix_ms * 1000).should eq(1)
        t.current_store.not_nil!.agent_messages_after(id, Process.pid.to_i64, 10).rows.map(&.outcome).should eq(["expired"])
      ensure
        t.release_presence
        t.current_store.try(&.close)
      end
    end
  end

  it "keeps a question's clock while bound elsewhere, and expires it on the way back" do
    with_bound_home("gori-ask-away") do |reg|
      project = reg.create("target")
      reg.create("other")
      t = bound_tools(project)
      begin
        id = JSON.parse(ask(t, %({"question":"q","choices":["a","b"],"expires_in_minutes":5})).text)["id"].as_i64
        t.call("switch_project", JSON.parse(%({"project":"other"}))).is_error.should be_false
        # A due tick while away writes nothing into the project that is bound instead.
        t.expire_asked_questions((Time.utc + 6.minutes).to_unix_ms * 1000).should eq(0)
        t.current_store.not_nil!.events_after(0, 10).count(&.kind.==("agent_message")).should eq(0)
        t.call("switch_project", JSON.parse(%({"project":"target"}))).is_error.should be_false
        t.current_store.not_nil!.open_agent_questions(0_i64, Time.utc.to_unix_ms * 1000).map(&.id).should eq([id])
        t.expire_asked_questions((Time.utc + 6.minutes).to_unix_ms * 1000).should eq(1)
      ensure
        t.release_presence
        t.current_store.try(&.close)
      end
    end
  end
end

# With a real project path the server can count the gori TUI windows that would show the card.
describe "ask_operator reach" do
  it "says when no window is open that the next one will show it" do
    home = File.tempname("gori-ask-reach")
    saved = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = home
    begin
      project = Gori::ProjectRegistry.new(Gori::Paths.projects_dir).create("target")
      store = Gori::Store.open(project.db_path)
      t = Gori::MCP::Tools.new(store, true, false, project_name: project.name, db_path: project.db_path,
        selection_source: "workspace-created")
      begin
        j = JSON.parse(ask(t, %({"question":"q","choices":["a","b"]})).text)
        j["tui"]["windows"].as_i.should eq(0)
        j["note"].as_s.should contain("next gori TUI to open on it shows it")
        window = Gori::AgentPresence.announce(project.db_path, client: "gori tui", client_version: "1",
          read_only: false, selection_source: nil, kind: Gori::AgentPresence::KIND_TUI).not_nil!
        begin
          j = JSON.parse(ask(t, %({"question":"q2","choices":["a","b"]})).text)
          j["tui"]["windows"].as_i.should eq(1)
          j["note"].as_s.should contain("ask: chip")
        ensure
          window.close
        end
      ensure
        t.release_presence
        store.close
      end
    ensure
      saved ? (ENV["GORI_HOME"] = saved) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(home)
    end
  end
end
