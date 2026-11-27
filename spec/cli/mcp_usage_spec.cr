require "../spec_helper"

# `gori mcp --usage` — `MCP::UsageLog` read back as a report. The report is built from a
# file written through the real writer, so a change to a line's shape that the reader does
# not follow fails here rather than printing an empty table.

private def usage_summary(since : Time? = nil, & : String ->) : Gori::MCP::UsageLog::Summary
  dir = File.tempname("gori-usage-report")
  Dir.mkdir_p(dir)
  begin
    path = File.join(dir, "mcp-usage.jsonl")
    yield path
    Gori::MCP::UsageLog::Summary.read(path, since)
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def recorded : Gori::MCP::UsageLog::Summary
  usage_summary do |path|
    a = Gori::MCP::UsageLog.new(path, "aaaa")
    a.session(Gori::MCP::UsageLog::Session.new("claude-code", "2.1", "decode,ql_reference,ql_explain", 3, false))
    a.list(46_612, 3)
    a.call("decode", ["input", "spec"], 0, "ok", nil, 6_144, 12_i64, true)
    a.call("decode", ["spec"], 1, "INVALID_ARGUMENT", "spec", 80, 2_i64, true)
    a.call("decode", ["input"], 0, "INVALID_ARGUMENT", "spec", 90, 4_i64, true)
    a.call("ql_reference", [] of String, 0, "ok", nil, 5_359, 3_i64, false)
    a.refused("send_request", known: true)
    a.refused("search_history", known: false)
    a.refused("search_history", known: false)
    b = Gori::MCP::UsageLog.new(path, "bbbb")
    b.session(Gori::MCP::UsageLog::Session.new("codex", nil, "decode,ql_reference,ql_explain", 3, true))
  end
end

describe "gori mcp --usage" do
  describe "the text report" do
    it "says the log is off and how to switch it on, and nothing else, when nothing was recorded" do
      text = Gori::CLI.mcp_usage_text(Gori::MCP::UsageLog::Summary.new, "7d", false)
      text.lines.size.should eq(1)
      text.should contain("the usage log is off")
      text.should contain(%("mcp": {"usage_log": true}))
    end

    it "says no sessions were recorded when the log is on and empty" do
      text = Gori::CLI.mcp_usage_text(Gori::MCP::UsageLog::Summary.new, "7d", true)
      text.should eq("gori mcp usage · last 7d · no sessions recorded\n")
    end

    it "still prints what an earlier session recorded after the log was switched off" do
      text = Gori::CLI.mcp_usage_text(recorded, "all", false)
      text.lines.first.should contain("the usage log is off")
      text.should contain("gori mcp usage · everything recorded · 2 sessions (1 made no calls) · 4 calls")
    end

    it "heads the report with the sessions, clients, profiles and catalogue size" do
      lines = Gori::CLI.mcp_usage_text(recorded, "7d", true).lines
      lines[0].should eq("gori mcp usage · last 7d · 2 sessions (1 made no calls) · 4 calls")
      lines[1].should eq("clients    claude-code 1 · codex 1")
      lines[2].should eq("profile    decode,ql_reference,ql_explain 1 · decode,ql_reference,ql_explain (read-only) 1")
      lines[3].should eq("catalogue  45.5kB per tools/list")
    end

    it "lists each tool, most-called first, with its commonest error and arguments" do
      lines = Gori::CLI.mcp_usage_text(recorded, "7d", true).lines
      head = lines.index!(&.starts_with?("TOOL"))
      lines[head].should eq("TOOL          CALLS  ERR  TOP ERROR                 REPLY p50 / max  p50 ms  ARGS")
      lines[head + 1].should eq("decode            3    2  INVALID_ARGUMENT:spec ×2  90B / 6.0kB           4  input×2 spec×2")
      lines[head + 2].should eq("ql_reference      1    0                            5.2kB / 5.2kB         3")
    end

    it "closes with what was never called, asked for but not served, and made up" do
      text = Gori::CLI.mcp_usage_text(recorded, "7d", true)
      text.should contain("never called: 1 of 3 advertised tools (--json lists them)")
      text.should contain("not served, but asked for: send_request ×1")
      text.should contain("unknown tool names: search_history ×2")
    end
  end

  describe "the JSON report" do
    it "carries every tally, sorted, under stable keys" do
      doc = JSON.parse(Gori::CLI.mcp_usage_json(recorded, "7d", true))
      doc["enabled"].as_bool.should be_true
      doc["since"].as_s.should eq("7d")
      doc["sessions"].as_i.should eq(2)
      doc["idle_sessions"].as_i.should eq(1)
      doc["calls"].as_i.should eq(4)
      doc["clients"].as_h.keys.should eq(["claude-code", "codex"])
      doc["profiles"].as_a.map(&.["read_only"].as_bool).should eq([false, true])
      doc["catalogue_bytes"]["median"].as_i.should eq(46_612)
      doc["never_called"].as_a.map(&.as_s).should eq(["ql_explain"])
      doc["not_served"].as_h.should eq({"send_request" => JSON::Any.new(1_i64)})
      doc["unknown_tools"]["search_history"].as_i.should eq(2)

      decode = doc["tools"].as_a.first
      decode["tool"].as_s.should eq("decode")
      decode["calls"].as_i.should eq(3)
      decode["errors"].as_i.should eq(2)
      decode["undelivered"].as_i.should eq(0)
      decode["error_codes"]["INVALID_ARGUMENT:spec"].as_i.should eq(2)
      decode["args"].as_h.keys.should eq(["input", "spec"])
      decode["undeclared_args"].as_i.should eq(1)
      decode["reply_bytes"]["median"].as_i.should eq(90)
      decode["reply_bytes"]["max"].as_i.should eq(6_144)
      doc["tools"].as_a.last["undelivered"].as_i.should eq(1)
    end

    it "prints nulls, not a failure, for an empty log" do
      doc = JSON.parse(Gori::CLI.mcp_usage_json(Gori::MCP::UsageLog::Summary.new, "all", false))
      doc["enabled"].as_bool.should be_false
      doc["sessions"].as_i.should eq(0)
      doc["catalogue_bytes"]["median"].raw.should be_nil
      doc["tools"].as_a.should be_empty
      doc["never_called"].as_a.should be_empty
    end
  end

  describe "the log a server is handed" do
    it "is nil unless the operator switched the usage log on" do
      prev = Gori::Settings.mcp_usage_log?
      begin
        Gori::Settings.mcp_usage_log = false
        Gori::CLI.mcp_usage_log.should be_nil
        Gori::Settings.mcp_usage_log = true
        Gori::CLI.mcp_usage_log.try(&.path).should eq(Gori::Paths.mcp_usage_log)
      ensure
        Gori::Settings.mcp_usage_log = prev
      end
    end
  end

  describe "advertised tools" do
    it "is the union of what each recorded profile serves in this build" do
      summary = usage_summary do |path|
        Gori::MCP::UsageLog.new(path, "aaaa").session(
          Gori::MCP::UsageLog::Session.new("a", nil, "decode", 1, false))
        Gori::MCP::UsageLog.new(path, "bbbb").session(
          Gori::MCP::UsageLog::Session.new("b", nil, "ql_reference", 1, false))
      end
      Gori::CLI.mcp_usage_advertised(summary).should eq(Set{"decode", "ql_reference"})
    end

    it "takes an unnarrowed session as the whole catalogue, less what --read-only withholds" do
      full = usage_summary do |path|
        Gori::MCP::UsageLog.new(path).session(Gori::MCP::UsageLog::Session.new("a", nil, nil, 1, false))
      end
      Gori::CLI.mcp_usage_advertised(full).size.should eq(Gori::MCP::Tools::TOOL_NAMES.size)
      gated = usage_summary do |path|
        Gori::MCP::UsageLog.new(path).session(Gori::MCP::UsageLog::Session.new("a", nil, nil, 1, true))
      end
      Gori::CLI.mcp_usage_advertised(gated).should eq(Gori::MCP::Tools.served_names(nil, false).to_set)
    end

    it "leaves out what a switched-off permission group withheld" do
      summary = usage_summary do |path|
        Gori::MCP::UsageLog.new(path).session(
          Gori::MCP::UsageLog::Session.new("a", nil, nil, 1, false, ["send"]))
      end
      advertised = Gori::CLI.mcp_usage_advertised(summary)
      advertised.should eq(Gori::MCP::Tools.served_names(nil, true, Set{"send"}).to_set)
      advertised.should_not contain("send_request")
      Gori::CLI.mcp_usage_text(summary, "7d", true).should contain("profile    * (without send) 1")
      JSON.parse(Gori::CLI.mcp_usage_json(summary, "7d", true))["profiles"][0]["denied"]
        .as_a.map(&.as_s).should eq(["send"])
    end

    it "skips a spec this build cannot parse instead of failing the report" do
      summary = usage_summary do |path|
        Gori::MCP::UsageLog.new(path).session(
          Gori::MCP::UsageLog::Session.new("a", nil, "no_such_tool_in_this_build", 1, false))
      end
      Gori::CLI.mcp_usage_advertised(summary).should be_empty
      Gori::CLI.mcp_usage_text(summary, "7d", true).should_not contain("never called")
    end
  end

  # Lines no gori wrote: the file is the operator's, but the report trusts nothing it reads.
  describe "a file gori did not write" do
    it "reports a session with a --tools spec longer than gori ever writes quickly" do
      summary = usage_summary do |path|
        File.write(path, %({"t":"s","at":#{Time.utc.to_unix},"sid":"x","tools":"#{"q" * 200_000}",) +
                         %("advertised":1,"read_only":false}\n))
      end
      started = Time.instant
      text = Gori::CLI.mcp_usage_text(summary, "7d", true)
      Gori::CLI.mcp_usage_json(summary, "7d", true)
      (Time.instant - started).total_seconds.should be < 3.0
      text.should contain("profile    #{Gori::MCP::UsageLog::SPEC_TOO_LONG} 1")
    end

    it "prints no control character and only valid UTF-8 from what it read back" do
      summary = usage_summary do |path|
        File.open(path, "w") do |f|
          f << %({"t":"s","at":#{Time.utc.to_unix},"sid":"x","client":"a\\u001b[2Jb",) <<
            %("tools":"decode\\u0007","advertised":1,"read_only":false,"denied":["se\\u001bnd"]}\n)
          f << %({"t":"c","at":#{Time.utc.to_unix},"sid":"x","tool":")
          f.write(Bytes[0xff, 0xfe])
          f << %(\\u001b[31m","args":["in\\u0000put"],"result":"BAD\\u001b","field":"sp\\u009bec"}\n)
          f << %({"t":"c","at":#{Time.utc.to_unix},"sid":"x","unknown":"Search\\u001b[0m History","result":"UNKNOWN_TOOL"}\n)
        end
      end
      text = Gori::CLI.mcp_usage_text(summary, "7d", true)
      json = Gori::CLI.mcp_usage_json(summary, "7d", true)
      {text, json}.each do |report|
        report.valid_encoding?.should be_true
        report.should_not match(/[\x00-\x09\x0b-\x1f\x7f\x{80}-\x{9f}]/)
      end
      parsed = JSON.parse(json)
      parsed["clients"].as_h.keys.should eq(["a[2Jb"])
      parsed["profiles"][0]["tools"].as_s.should eq("decode")
      parsed["profiles"][0]["denied"].as_a.map(&.as_s).should eq(["send"])
      tool = parsed["tools"][0]
      tool["tool"].as_s.should eq("\u{FFFD}\u{FFFD}[31m")
      tool["args"].as_h.keys.should eq(["input"])
      tool["error_codes"].as_h.keys.should eq(["BAD:spec"])
      parsed["unknown_tools"].as_h.keys.should eq(["search0mhistory"])
    end
  end
end
