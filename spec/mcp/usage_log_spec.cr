require "../spec_helper"
require "../support/mcp_harness"

# `MCP::UsageLog` — what `gori mcp` records about its own use, once the operator has opted in.
#
# The property these examples hold is the one the file is allowed to exist for: a line names
# what was CALLED and never what it was called WITH. So the server examples send values that
# would be recognisable anywhere (a host, a query, an argument key made of free text) and
# search the whole file for them, rather than reading the fields that are expected to be there.

private def with_usage_file(&)
  dir = File.tempname("gori-usage")
  Dir.mkdir_p(dir)
  begin
    yield File.join(dir, "mcp-usage.jsonl")
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def usage_rows(path : String) : Array(JSON::Any)
  File.read_lines(path).map { |line| JSON.parse(line) }
end

private def usage_session(client : String? = "probe", tools : String? = nil,
                          read_only = false) : Gori::MCP::UsageLog::Session
  Gori::MCP::UsageLog::Session.new(client, "1.0", tools, 7, read_only)
end

# The server over scripted lines, with a usage log at `path`.
private def drive_with_usage(path : String, *lines, tools : String? = nil,
                             denied : Set(String)? = nil) : Array(JSON::Any)
  filter = tools.try do |spec|
    Gori::MCP::ToolFilter.parse(spec, Gori::MCP::Tools::TOOL_NAMES,
      Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
  end
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(nil, allow_actions: true, verify_upstream: true, tool_filter: filter,
    denied_permissions: denied, usage_log: Gori::MCP::UsageLog.new(path),
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

private def rpc(id : Int32, method : String, params : String = "{}") : String
  %({"jsonrpc":"2.0","id":#{id},"method":"#{method}","params":#{params}})
end

private def call(id : Int32, name : String, args : String = "{}") : String
  rpc(id, "tools/call", %({"name":#{name.to_json},"arguments":#{args}}))
end

USAGE_HANDSHAKE = %({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26",) +
                  %("clientInfo":{"name":"probe-client","version":"9.9"},"capabilities":{}}})

# A client that went away: every write fails, as a closed pipe's does.
private class UsageBrokenPipe < IO
  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("Broken pipe")
  end
end

describe Gori::MCP::UsageLog do
  describe "writing" do
    it "writes nothing until a session line is asked for" do
      with_usage_file do |path|
        log = Gori::MCP::UsageLog.new(path)
        log.started?.should be_false
        File.exists?(path).should be_false
      end
    end

    it "writes the session line once, with the client and the profile" do
      with_usage_file do |path|
        log = Gori::MCP::UsageLog.new(path, "abcd1234", -> { Time.unix(1_000) })
        log.session(usage_session(tools: "@recon", read_only: true))
        log.session(usage_session(client: "other"))
        rows = usage_rows(path)
        rows.size.should eq(1)
        row = rows.first
        row["t"].as_s.should eq("s")
        row["at"].as_i64.should eq(1_000)
        row["sid"].as_s.should eq("abcd1234")
        row["gori"].as_s.should eq(Gori::VERSION)
        row["client"].as_s.should eq("probe")
        row["client_version"].as_s.should eq("1.0")
        row["tools"].as_s.should eq("@recon")
        row["advertised"].as_i.should eq(7)
        row["read_only"].as_bool.should be_true
      end
    end

    it "leaves out a client that never named itself and a profile that was not narrowed" do
      with_usage_file do |path|
        log = Gori::MCP::UsageLog.new(path)
        log.session(Gori::MCP::UsageLog::Session.new(nil, nil, nil, 3, false))
        row = usage_rows(path).first.as_h
        row.has_key?("client").should be_false
        row.has_key?("client_version").should be_false
        row.has_key?("tools").should be_false
      end
    end

    it "writes a call's declared argument names, outcome, size and duration" do
      with_usage_file do |path|
        log = Gori::MCP::UsageLog.new(path)
        log.call("list_history", ["limit", "q"], 2, "INVALID_ARGUMENT", "q", 87, 12_i64, false)
        row = usage_rows(path).first
        row["t"].as_s.should eq("c")
        row["tool"].as_s.should eq("list_history")
        row["args"].as_a.map(&.as_s).should eq(["limit", "q"])
        row["extra"].as_i.should eq(2)
        row["result"].as_s.should eq("INVALID_ARGUMENT")
        row["field"].as_s.should eq("q")
        row["bytes"].as_i.should eq(87)
        row["ms"].as_i.should eq(12)
        row["undelivered"].as_bool.should be_true
      end
    end

    it "keeps a clean call's line to what happened" do
      with_usage_file do |path|
        Gori::MCP::UsageLog.new(path).call("get_flow", ["id"], 0, "ok", nil, 10, 1_i64, true)
        row = usage_rows(path).first.as_h
        row.has_key?("extra").should be_false
        row.has_key?("field").should be_false
        row.has_key?("undelivered").should be_false
      end
    end

    it "tells a real tool this server left out from a name nobody declared" do
      with_usage_file do |path|
        log = Gori::MCP::UsageLog.new(path)
        log.refused("send_request", known: true)
        log.refused("Search History; rm -rf /etc", known: false)
        hidden, invented = usage_rows(path)
        hidden["tool"].as_s.should eq("send_request")
        hidden["result"].as_s.should eq(Gori::MCP::UsageLog::NOT_SERVED)
        invented.as_h.has_key?("tool").should be_false
        invented["unknown"].as_s.should eq("searchhistoryrmrfetc")
        invented["result"].as_s.should eq(Gori::MCP::UsageLog::UNKNOWN_TOOL)
      end
    end

    it "creates the file private to the operator" do
      with_usage_file do |path|
        posix_only!("POSIX permission bits")
        Gori::MCP::UsageLog.new(path).list(100, 3)
        (File.info(path).permissions.value & 0o777).should eq(0o600)
      end
    end

    it "appends, so several servers share one file" do
      with_usage_file do |path|
        Gori::MCP::UsageLog.new(path, "aaaa").list(1, 1)
        Gori::MCP::UsageLog.new(path, "bbbb").list(2, 2)
        usage_rows(path).map(&.["sid"].as_s).should eq(["aaaa", "bbbb"])
      end
    end

    it "names the permission groups that were switched off, and only when some were" do
      with_usage_file do |path|
        Gori::MCP::UsageLog.new(path, "aaaa").session(usage_session)
        Gori::MCP::UsageLog.new(path, "bbbb").session(
          Gori::MCP::UsageLog::Session.new("probe", nil, nil, 7, false, ["send", "write"]))
        rows = usage_rows(path)
        rows[0]["denied"]?.should be_nil
        rows[1]["denied"].as_a.map(&.as_s).should eq(["send", "write"])
      end
    end

    it "writes a marker in place of a --tools spec too long to keep whole" do
      with_usage_file do |path|
        spec = (["get_flow"] * 400).join(',')
        Gori::MCP::UsageLog.new(path).session(usage_session(tools: spec))
        usage_rows(path).first["tools"].as_s.should eq(Gori::MCP::UsageLog::SPEC_TOO_LONG)
      end
    end

    it "switches itself off instead of raising when the file cannot be written" do
      with_usage_file do |path|
        # A DIRECTORY where the file should be: every open fails, on every platform.
        Dir.mkdir_p(path)
        log = Gori::MCP::UsageLog.new(path)
        log.session(usage_session)
        log.call("get_flow", ["id"], 0, "ok", nil, 10, 1_i64, true)
        log.list(1, 1)
        File.directory?(path).should be_true
      end
    end
  end

  describe ".token" do
    it "keeps only the alphabet a tool name is spelled in" do
      Gori::MCP::UsageLog.token("list_history").should eq("list_history")
      Gori::MCP::UsageLog.token("List-History 2").should eq("listhistory2")
      Gori::MCP::UsageLog.token("../../etc/passwd").should eq("etcpasswd")
      Gori::MCP::UsageLog.token("https://secret.example/?q=1").should eq("httpssecretexampleq1")
    end

    it "caps the length and never returns an empty name" do
      Gori::MCP::UsageLog.token("a" * 500).size.should eq(Gori::MCP::UsageLog::NAME_MAX)
      Gori::MCP::UsageLog.token("").should eq("?")
      Gori::MCP::UsageLog.token("한글 \u0000 !!").should eq("?")
    end

    it "does not raise on bytes that are not UTF-8" do
      Gori::MCP::UsageLog.token(String.new(Bytes[0xff, 0x61, 0xfe])).should eq("a")
    end
  end

  describe ".outcome" do
    it "is ok for a call that worked, and the code for one that was refused" do
      Gori::MCP::UsageLog.outcome(false, nil, "{}").should eq("ok")
      Gori::MCP::UsageLog.outcome(true, "NOT_FOUND", "no such flow").should eq("NOT_FOUND")
    end

    it "reads a failed send's code out of the envelope gori answered with" do
      envelope = %({"error":"connection refused","error_kind":"connect","error_code":"NETWORK_ERROR"})
      Gori::MCP::UsageLog.outcome(true, nil, envelope).should eq("NETWORK_ERROR")
    end

    it "keeps nothing from an envelope that is not shaped like a code" do
      Gori::MCP::UsageLog.outcome(true, nil, %({"error_code":"https://secret.example/x"})).should eq("error")
      Gori::MCP::UsageLog.outcome(true, nil, %({"error_code":7})).should eq("error")
      Gori::MCP::UsageLog.outcome(true, nil, %({"error":"no code")).should eq("error")
      Gori::MCP::UsageLog.outcome(true, nil, "plain words").should eq("error")
    end
  end

  describe ".clean" do
    it "drops control characters, collapses whitespace and caps the length" do
      Gori::MCP::UsageLog.clean("claude\u001b[31m-code\n\t x", 48).should eq("claude[31m-code x")
      Gori::MCP::UsageLog.clean("a" * 100, 48).try(&.size).should eq(48)
    end

    it "is nil when nothing printable is left" do
      Gori::MCP::UsageLog.clean(nil, 48).should be_nil
      Gori::MCP::UsageLog.clean(" \n\u0000", 48).should be_nil
    end
  end

  describe "rotation" do
    it "moves an oversized file aside before a session's first line" do
      with_usage_file do |path|
        File.write(path, "x" * (Gori::MCP::UsageLog::MAX_BYTES + 1))
        Gori::MCP::UsageLog.new(path).session(usage_session)
        File.size("#{path}.1").should eq(Gori::MCP::UsageLog::MAX_BYTES + 1)
        usage_rows(path).size.should eq(1)
      end
    end

    it "leaves a file under the bound where it is" do
      with_usage_file do |path|
        File.write(path, %({"t":"l","at":1,"sid":"old","bytes":1,"tools":1}\n))
        Gori::MCP::UsageLog.new(path).session(usage_session)
        File.exists?("#{path}.1").should be_false
        usage_rows(path).size.should eq(2)
      end
    end

    it "replaces the previous rotation, so two files are the bound" do
      with_usage_file do |path|
        File.write("#{path}.1", "older")
        File.write(path, "y" * (Gori::MCP::UsageLog::MAX_BYTES + 1))
        Gori::MCP::UsageLog.new(path).session(usage_session)
        File.read("#{path}.1").should start_with("yyy")
      end
    end

    it "rotates in the middle of a session too, and names the session again in the fresh file" do
      with_usage_file do |path|
        log = Gori::MCP::UsageLog.new(path, "aaaa")
        log.session(usage_session)
        log.call("get_flow", ["id"], 0, "ok", nil, 10, 1_i64, true)
        File.open(path, "a", &.print("z" * (Gori::MCP::UsageLog::MAX_BYTES + 1)))
        log.call("decode", ["input"], 0, "ok", nil, 10, 1_i64, true)

        File.read("#{path}.1").should contain(%("tool":"get_flow"))
        rows = usage_rows(path)
        rows.map(&.["t"].as_s).should eq(["s", "c"])
        rows[0]["client"].as_s.should eq("probe")
        rows[1]["tool"].as_s.should eq("decode")
        summary = Gori::MCP::UsageLog::Summary.read(path)
        summary.sessions.should eq(1)
        summary.clients.should eq({"probe" => 1})
      end
    end

    it "does not wait for a rotation another server is doing, and keeps writing" do
      posix_only!("flock is advisory here; Windows' lock is mandatory on the lock file itself")
      with_usage_file do |path|
        File.write(path, "y" * (Gori::MCP::UsageLog::MAX_BYTES + 1) + "\n")
        File.open("#{path}.lock", "w") do |held|
          held.flock_exclusive(blocking: false)
          Gori::MCP::UsageLog.new(path).session(usage_session)
        end
        File.exists?("#{path}.1").should be_false
        File.read_lines(path).last.should contain(%("t":"s"))
      end
    end
  end

  describe "the server" do
    it "writes nothing when no log was handed to it" do
      with_usage_file do |path|
        mcp_drive(nil, USAGE_HANDSHAKE, call(1, "ql_reference"))
        File.exists?(path).should be_false
      end
    end

    it "records the session, the catalogue and each call" do
      with_usage_file do |path|
        drive_with_usage(path, USAGE_HANDSHAKE, rpc(1, "tools/list"), call(2, "ql_reference"), tools: "@recon")
        session, listing, called = usage_rows(path)
        session["t"].as_s.should eq("s")
        session["client"].as_s.should eq("probe-client")
        session["client_version"].as_s.should eq("9.9")
        session["tools"].as_s.should eq("@recon")
        listing["t"].as_s.should eq("l")
        listing["tools"].as_i.should eq(session["advertised"].as_i)
        listing["bytes"].as_i.should be > 1_000
        called["tool"].as_s.should eq("ql_reference")
        called["result"].as_s.should eq("ok")
        called["bytes"].as_i.should be > 0
        called.as_h.has_key?("undelivered").should be_false
      end
    end

    it "never writes an argument's value, an undeclared key, or a made-up tool name as sent" do
      with_usage_file do |path|
        drive_with_usage(path, USAGE_HANDSHAKE,
          call(1, "decode", %({"input":"c2VjcmV0LXZhbHVl","zz free text/key":"leak-me"})),
          call(2, "list_history", %({"query":"host:secret.example status:500","limit":5})),
          call(3, "Steal Cookies from secret.example", %({"q":"host:secret.example"})))
        text = File.read(path)
        %w[c2VjcmV0LXZhbHVl secret.example status:500 leak-me free\ text Steal].each do |leak|
          text.should_not contain(leak)
        end
        rows = usage_rows(path).select { |r| r["t"].as_s == "c" }
        rows[0]["args"].as_a.map(&.as_s).should eq(["input"])
        rows[0]["extra"].as_i.should eq(1)
        rows[0]["result"].as_s.should eq("INVALID_ARGUMENT")
        # The argument an unknown-argument refusal blames is the caller's own spelling.
        rows[0].as_h.has_key?("field").should be_false
        rows[1]["args"].as_a.map(&.as_s).should eq(["limit", "query"])
        rows[1]["result"].as_s.should eq("NO_PROJECT")
        rows[2]["unknown"].as_s.should eq("stealcookiesfromsecretexample")
      end
    end

    it "names the declared argument an error blames" do
      with_usage_file do |path|
        drive_with_usage(path, USAGE_HANDSHAKE, call(1, "ql_explain", %({"query":"  "})))
        row = usage_rows(path).find! { |r| r["t"].as_s == "c" }
        row["result"].as_s.should eq("INVALID_ARGUMENT")
        row["field"].as_s.should eq("query")
      end
    end

    it "records a real tool the --tools filter left out as not served" do
      with_usage_file do |path|
        resp = drive_with_usage(path, USAGE_HANDSHAKE, call(1, "ql_reference"), tools: "decode")
        resp.last["error"]["code"].as_i.should eq(-32602)
        row = usage_rows(path).find! { |r| r["t"].as_s == "c" }
        row["tool"].as_s.should eq("ql_reference")
        row["result"].as_s.should eq(Gori::MCP::UsageLog::NOT_SERVED)
      end
    end

    it "names the permission groups Preferences switched off" do
      with_usage_file do |path|
        drive_with_usage(path, USAGE_HANDSHAKE, call(1, "ql_reference"), denied: Set{"send"})
        usage_rows(path).first["denied"].as_a.map(&.as_s).should eq(["send"])
      end
    end

    it "cleans what the client called itself before writing it" do
      with_usage_file do |path|
        hostile = %({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26",) +
                  %("clientInfo":{"name":"evil\\n{\\"t\\":\\"c\\"}\\u202e#{"x" * 200}","version":"1\\u0000\\t2"},"capabilities":{}}})
        drive_with_usage(path, hostile, call(1, "ql_reference"))
        File.read_lines(path).size.should eq(2)
        session = usage_rows(path).first
        session["client"].as_s.size.should eq(Gori::MCP::UsageLog::CLIENT_MAX)
        session["client"].as_s.should start_with(%(evil{"t":"c"}xxx))
        session["client_version"].as_s.should eq("12")
      end
    end

    it "answers exactly as it would without a log when the log cannot be written" do
      with_usage_file do |path|
        Dir.mkdir_p(path) # a directory where the file should be: every write fails
        lines = {USAGE_HANDSHAKE, rpc(1, "tools/list"), call(2, "ql_reference"),
                 call(3, "search_history"), call(4, "ql_explain", %({"query":"  "}))}
        with_log = drive_with_usage(path, *lines)
        without = mcp_drive(nil, *lines)
        with_log.should eq(without)
        with_log.map(&.["id"].as_i).should eq([0, 1, 2, 3, 4])
      end
    end

    it "marks an answer the client never received as undelivered" do
      with_usage_file do |path|
        input = IO::Memory.new(call(1, "ql_reference") + "\n")
        Gori::MCP::Server.new(nil, allow_actions: true, verify_upstream: true,
          usage_log: Gori::MCP::UsageLog.new(path), input: input, output: UsageBrokenPipe.new).run
        row = usage_rows(path).find! { |r| r["t"].as_s == "c" }
        row["tool"].as_s.should eq("ql_reference")
        row["undelivered"].as_bool.should be_true
      end
    end
  end

  describe Gori::MCP::UsageLog::Summary do
    it "is empty for a file that does not exist" do
      with_usage_file do |path|
        summary = Gori::MCP::UsageLog::Summary.read(path)
        summary.empty?.should be_true
        summary.calls.should eq(0)
      end
    end

    it "adds up sessions, calls, errors, arguments and sizes" do
      with_usage_file do |path|
        a = Gori::MCP::UsageLog.new(path, "aaaa")
        a.session(usage_session(client: "claude-code", tools: "@recon"))
        a.list(40_000, 39)
        a.call("list_history", ["limit", "q"], 0, "ok", nil, 6_000, 10_i64, true)
        a.call("list_history", ["q"], 0, "INVALID_ARGUMENT", "q", 80, 2_i64, true)
        a.call("list_history", ["q"], 1, "INVALID_ARGUMENT", "q", 90, 4_i64, false)
        a.call("get_flow", ["id"], 0, "ok", nil, 2_000, 1_i64, true)
        a.refused("send_request", known: true)
        a.refused("search_history", known: false)
        b = Gori::MCP::UsageLog.new(path, "bbbb")
        b.session(usage_session(client: "codex", read_only: true))
        b.list(90_000, 200)

        summary = Gori::MCP::UsageLog::Summary.read(path)
        summary.sessions.should eq(2)
        summary.idle_sessions.should eq(1)
        summary.calls.should eq(4)
        summary.clients.should eq({"claude-code" => 1, "codex" => 1})
        none = [] of String
        summary.profiles.should eq({ {"@recon", false, none, none} => 1, {nil, true, none, none} => 1 })
        summary.catalogue_bytes.should eq([40_000_i64, 90_000_i64])
        summary.not_served.should eq({"send_request" => 1})
        summary.unknown.should eq({"search_history" => 1})

        history = summary.tools["list_history"]
        history.calls.should eq(3)
        history.errors.should eq(2)
        history.undelivered.should eq(1)
        history.extra_args.should eq(1)
        history.error_codes.should eq({"INVALID_ARGUMENT:q" => 2})
        history.args.should eq({"limit" => 1, "q" => 3})
        history.bytes.should eq([6_000_i64, 80_i64, 90_i64])
        summary.tools.has_key?("send_request").should be_false
      end
    end

    it "reads the rotated file before the live one" do
      with_usage_file do |path|
        Gori::MCP::UsageLog.new("#{path}.1", "old1").call("get_flow", ["id"], 0, "ok", nil, 1, 1_i64, true)
        Gori::MCP::UsageLog.new(path, "new1").call("get_flow", ["id"], 0, "ok", nil, 2, 1_i64, true)
        Gori::MCP::UsageLog::Summary.read(path).tools["get_flow"].bytes.should eq([1_i64, 2_i64])
      end
    end

    it "counts only what falls inside the window, and still names a session that began before it" do
      with_usage_file do |path|
        now = 10_000_i64
        clock = -> { Time.unix(now) }
        log = Gori::MCP::UsageLog.new(path, "long", clock)
        now = 1_000
        log.session(usage_session(client: "claude-code"))
        log.call("get_flow", ["id"], 0, "ok", nil, 1, 1_i64, true)
        now = 9_000
        log.call("list_history", ["q"], 0, "ok", nil, 2, 1_i64, true)
        old = Gori::MCP::UsageLog.new(path, "gone", -> { Time.unix(500) })
        old.session(usage_session(client: "codex"))

        summary = Gori::MCP::UsageLog::Summary.read(path, Time.unix(5_000))
        summary.sessions.should eq(1)
        summary.clients.should eq({"claude-code" => 1})
        summary.tools.keys.should eq(["list_history"])
      end
    end

    it "skips a line that is not one of its own" do
      with_usage_file do |path|
        File.write(path, [
          %(not json at all),
          %(["an","array"]),
          %({"t":"c","sid":7,"tool":"get_flow"}),
          %({"t":"c","at":1,"sid":"ok","tool":"get_flow","bytes":99999999999999999999,"result":"ok"}),
          %({"t":"c","at":1,"sid":"ok","tool":"get_flow","args":"nope","bytes":"big","ms":"x","result":"ok"}),
          %({"t":"c","at":1,"sid":"ok","tool":"get_flow","args":["id",3],"bytes":5,"ms":1,"result":"ok"}),
          %({"t":"c","at":1,"sid":"ok","tool":"get_fl),
        ].join('\n'))
        summary = Gori::MCP::UsageLog::Summary.read(path)
        summary.sessions.should eq(1)
        summary.clients.should eq({"(unnamed)" => 1})
        stat = summary.tools["get_flow"]
        stat.calls.should eq(2)
        stat.args.should eq({"id" => 1})
        stat.bytes.should eq([5_i64])
      end
    end

    it "adds up counts no gori wrote without overflowing, and ignores negative ones" do
      with_usage_file do |path|
        File.write(path, [
          %({"t":"c","at":1,"sid":"a","tool":"get_flow","extra":2000000000,"bytes":2147483647,"ms":1,"result":"ok"}),
          %({"t":"c","at":1,"sid":"a","tool":"get_flow","extra":2000000000,"bytes":4294967296,"ms":-5,"result":"ok"}),
          %({"t":"c","at":1,"sid":"a","tool":"get_flow","extra":-3,"bytes":-1,"ms":9223372036854775807,"result":"ok"}),
          %({"t":"c","at":1,"sid":"a","tool":"get_flow","extra":9223372036854775807,"result":"ok"}),
          %({"t":"l","at":1,"sid":"a","bytes":-1,"tools":1}),
        ].join('\n'))
        summary = Gori::MCP::UsageLog::Summary.read(path)
        stat = summary.tools["get_flow"]
        stat.calls.should eq(4)
        stat.extra_args.should eq(4_000_000_000_i64)
        stat.bytes.should eq([2_147_483_647_i64])
        stat.ms.should eq([1_i64])
        summary.catalogue_bytes.should be_empty
      end
    end

    it "takes the upper median" do
      Gori::MCP::UsageLog::Summary.median([] of Int64).should be_nil
      Gori::MCP::UsageLog::Summary.median([3_i64]).should eq(3)
      Gori::MCP::UsageLog::Summary.median([9_i64, 1_i64, 5_i64]).should eq(5)
      Gori::MCP::UsageLog::Summary.median([4_i64, 1_i64]).should eq(4)
    end
  end
end
