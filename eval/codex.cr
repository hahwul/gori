require "json"
require "set"

# Codex exec's JSONL has no init tool inventory or USD cost. Count called tools and
# keep cost absent rather than turning an unreported price into a free run.
module EvalCodex
  record Stream, calls : Array(String), foreign : Int32, peeked : Bool,
    text : String, input_tokens : Int64, output_tokens : Int64, turns : Int64, error : Bool

  # --ignore-user-config and project_doc_max_bytes do not suppress global AGENTS files.
  def self.instructions_file(home : String = ENV["CODEX_HOME"]? || File.join(Path.home, ".codex")) : String?
    %w[AGENTS.override.md AGENTS.md].map { |name| File.join(home, name) }.find { |path| File.exists?(path) }
  end

  def self.args(prompt : String, model : String?, script : Bool, rule : String,
                binary : String, db : String, home : String, profile_args : Array(String)) : Array(String)
    args = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
            "--ignore-rules", "--sandbox", "read-only", "-c", "approval_policy=\"never\""]
    args += ["--model", model] if model
    settings = {
      "project_doc_max_bytes"       => "0",
      "features.memories"           => "false",
      "web_search"                  => "\"disabled\"",
      "agents.enabled"              => "false",
      "features.multi_agent_v2"     => "false",
      "skills.include_instructions" => "false",
      "features.apps"               => "false",
      "features.plugins"            => "false",
      "features.tool_search"        => "false",
      "features.code_mode"          => "false",
      "features.shell_tool"         => script.to_s,
      "features.view_image"         => "false",
      "developer_instructions"      => rule.to_json,
    }
    unless script
      settings["mcp_servers.gori.command"] = binary.to_json
      settings["mcp_servers.gori.args"] = (["mcp", "--db", db] + profile_args).to_json
      settings["mcp_servers.gori.env.GORI_HOME"] = home.to_json
      settings["mcp_servers.gori.required"] = "true"
    end
    settings.each { |key, value| args += ["-c", "#{key}=#{value}"] }
    args + [prompt]
  end

  def self.read_stream(path : String, script : Bool, eval_dir : String) : Stream
    Reader.new(script, eval_dir).read(path)
  end

  private class Reader
    @calls = [] of String
    @seen = Set(String).new
    @foreign = 0
    @peeked = false
    @text = ""
    @input = 0_i64
    @output = 0_i64
    @turns = 0_i64
    @failed = false

    def initialize(@script : Bool, @eval_dir : String)
    end

    def read(path : String) : Stream
      File.each_line(path) do |line|
        ev = JSON.parse(line) rescue next
        event(ev)
      end
      Stream.new(@calls, @foreign, @peeked, @text, @input, @output, @turns, @failed || @turns.zero?)
    end

    private def event(ev : JSON::Any)
      case ev["type"]?.try(&.as_s?)
      when "turn.completed"
        @turns += 1
        # Codex input_tokens already includes cached_input_tokens.
        @input += ev.dig?("usage", "input_tokens").try(&.as_i64?) || 0_i64
        @output += ev.dig?("usage", "output_tokens").try(&.as_i64?) || 0_i64
      when "turn.failed", "error"
        @failed = true
      when "item.started", "item.updated", "item.completed"
        item(ev) if ev["item"]?
      end
    end

    private def item(ev : JSON::Any)
      item = ev["item"]
      type = item["type"]?.try(&.as_s?)
      if type == "agent_message"
        @text = item["text"]?.try(&.as_s?) || "" if ev["type"] == "item.completed"
        return
      end
      # Item errors are nonfatal diagnostics, not tool calls; fatal errors are events.
      return if {"reasoning", "todo_list", "error"}.includes?(type)
      call, allowed, input = action(item, type)
      # Completion/update events may carry arguments absent from the start event.
      @peeked ||= input.includes?("truth.json") || input.includes?(@eval_dir) || input.includes?("results.jsonl")
      id = item["id"]?.try(&.as_s?)
      return unless id && @seen.add?(id)
      @calls << call
      @foreign += 1 unless allowed
    end

    private def action(item : JSON::Any, type : String?) : {String, Bool, String}
      case type
      when "mcp_tool_call"
        server = item["server"]?.try(&.as_s?) || ""
        tool = item["tool"]?.try(&.as_s?) || "unknown"
        call = server == "gori" ? tool : "mcp__#{server}__#{tool}"
        {call, !@script && server == "gori", item["arguments"]?.to_json}
      when "command_execution"
        {"shell", @script, item["command"]?.to_json}
      else
        {type || "unknown", false, item.to_json}
      end
    end
  end
end
