require "../spec_helper"
require "json"

# #1090 layer four's second half: a pending operator message rides back on the next gori tool
# result, for the clients that have no live route at all (grok, pi, hermes, Antigravity, Claude
# Desktop — surveyed, none has a door a server can knock on). The poll tool still exists; this
# is what makes the poll layer work when the model never remembers to call it.
#
# The load-bearing parts are the ones that decide whether a message can be LOST or REPEATED:
# the floor (nothing said before this session is replayed), the cursor (nothing is attached
# twice), the CARRIED filter (a socket delivery retires it here too), and the addressing (a
# message for another session's pid is not this session's to read).

private def tools_for(store, allow_actions = true) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions, false)
end

private def deliveries(store, since = 0_i64) : Array(Gori::AgentDelivery)
  store.agent_deliveries_after(since, 100).rows
end

describe "MCP operator messages on a tool result" do
  it "carries a pending message back on the next tool call, once, and records the route" do
    with_store do |store|
      tools = tools_for(store)
      id = store.post_agent_message("check the login flow", "all", "history", [7_i64, 9_i64])

      note = tools.pending_operator_note("list_history").not_nil!
      tools.commit_operator_note(note)
      note.text.should contain("check the login flow")
      # Everything the row holds that the agent cannot get back once the route retires it:
      # where it was sent from, what was marked, and which message to answer.
      note.text.should contain("from the history tab")
      note.text.should contain("7, 9")
      note.text.should contain("in_reply_to #{id}")

      d = deliveries(store, id).find { |row| row.message_id == id }.not_nil!
      d.via.should eq(Gori::AgentDelivery::VIA_TOOL_RESULT)
      d.ok.should be_true
      d.pid.should eq(Process.pid.to_i64)

      # The next tool call must not re-attach it — the cursor moved and the row is CARRIED.
      tools.pending_operator_note("list_issues").should be_nil
    end
  end

  it "never replays what the operator said before this session bound the project" do
    with_store do |store|
      store.post_agent_message("said before you attached", "all", nil)
      tools = tools_for(store)
      tools.pending_operator_note("list_history").should be_nil
    end
  end

  it "leaves the poll tool's own call alone" do
    with_store do |store|
      tools = tools_for(store)
      store.post_agent_message("hi", "all", nil)
      # `operator_messages` answers with these rows itself and marks them; attaching them to
      # its own result would hand the same line over twice in one response.
      tools.pending_operator_note("operator_messages").should be_nil
    end
  end

  it "does not carry a message a confirmed route already delivered to this session" do
    with_store do |store|
      tools = tools_for(store)
      id = store.post_agent_message("already in the socket", "all", nil)
      store.record_agent_delivery(id, Gori::AgentDelivery::VIA_SOCKET, "claude-code", true,
        pid: Process.pid.to_i64)
      tools.pending_operator_note("list_history").should be_nil
    end
  end

  it "does not carry a message addressed to another session" do
    with_store do |store|
      tools = tools_for(store)
      store.post_agent_message("for the other agent", "pid:#{Process.pid + 1}", nil)
      tools.pending_operator_note("list_history").should be_nil
    end
  end

  # A `--read-only` server has no writer fiber, so nothing can record that this landed. The
  # message still goes out (the agent is the point), the poll tool may hand it over again, and
  # the cursor is what keeps it from riding on every result for the rest of the session.
  it "still carries the message on a read-only server, without a delivery row or a repeat" do
    path = File.tempname("gori-spec-ro", ".db")
    Gori::Store.open(path).close
    store = Gori::Store.open(path, read_only: true)
    writer = Gori::Store.open(path)
    begin
      tools = tools_for(store, allow_actions: false)
      id = writer.post_agent_message("read-only all the same", "all", nil)
      ro = tools.pending_operator_note("list_history").not_nil!
      tools.commit_operator_note(ro)
      ro.text.should contain("read-only all the same")
      deliveries(writer, id).select { |d| d.message_id == id }.should be_empty
      tools.pending_operator_note("list_history").should be_nil
    ensure
      store.close
      writer.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  # The other half of the read/commit split: a response that never went out (a cancelled
  # request, a client that vanished mid-call) must leave the message exactly where it was.
  # Marking at READ time meant the ring said "got it" for a line nothing carried, and the
  # cursor had already moved past it — a silent loss with a success row on top of it.
  it "retires nothing until the response it rode on was actually emitted" do
    with_store do |store|
      tools = tools_for(store)
      id = store.post_agent_message("only if you got it", "all", nil)

      first = tools.pending_operator_note("list_history").not_nil!
      first.text.should contain("only if you got it")
      # The frame was never emitted, so nothing is committed.
      deliveries(store, id).select { |d| d.message_id == id }.should be_empty

      second = tools.pending_operator_note("list_issues").not_nil!
      second.ids.should eq([id])
      tools.commit_operator_note(second)
      deliveries(store, id).count { |d| d.message_id == id }.should eq(1)
    end
  end

  # A backlog longer than one page: the cursor may only advance past what was SCANNED, and the
  # note has to say that it is holding some back — nothing else will tell the model.
  it "carries one page, says more is waiting, and hands the rest over next call" do
    with_store do |store|
      tools = tools_for(store)
      ids = (1..7).map { |n| store.post_agent_message("line #{n}", "all", nil) }

      first = tools.pending_operator_note("list_history").not_nil!
      tools.commit_operator_note(first)
      first.ids.size.should eq(Gori::MCP::Tools::TOOL_RESULT_MESSAGES)
      first.ids.should eq(ids.first(5))
      first.text.should contain("More operator messages are waiting")
      first.text.should contain("line 5")
      first.text.should_not contain("line 6")

      second = tools.pending_operator_note("list_history").not_nil!
      tools.commit_operator_note(second)
      second.ids.should eq(ids.last(2))
      second.text.should_not contain("More operator messages are waiting")
      tools.pending_operator_note("list_history").should be_nil
    end
  end

  # Over the wire: the note is its OWN content block. Mixed into the tool's text it would break
  # `structuredContent` parsing and rewrite an answer the agent asked for.
  it "arrives as a second content block beside the tool's own answer" do
    with_store do |store|
      reader, to_server = IO.pipe
      from_server = IO::Memory.new
      server = Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
        input: reader, output: from_server)
      done = Channel(Nil).new(1)
      spawn do
        server.run
        done.send(nil)
      end
      begin
        # Posted AFTER the server bound (its floor is the feed's end at construction) and
        # BEFORE the call it should ride back on — the lines are read in order.
        store.post_agent_message("stop fuzzing that host", "all", "issues")
        to_server.puts(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_info","arguments":{}}}))
        to_server.close
        done.receive?
        resp = JSON.parse(from_server.to_s.each_line.reject(&.strip.empty?).first)
        content = resp["result"]["content"].as_a
        content.size.should eq(2)
        # The tool's own answer is untouched and still parses as what it was.
        JSON.parse(content[0]["text"].as_s)["read_only"].as_bool.should be_false
        content[1]["text"].as_s.should contain("stop fuzzing that host")
        resp["result"]["isError"].as_bool.should be_false
      ensure
        to_server.close rescue nil
        reader.close rescue nil
      end
    end
  end
end
