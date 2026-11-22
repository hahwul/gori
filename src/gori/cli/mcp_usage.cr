require "json"
require "../mcp/usage_log"
require "../plural"

# `gori mcp --usage` — the usage log (`MCP::UsageLog`) read back as a report. Reopens
# Gori::CLI; `run_mcp` in cli/mcp.cr dispatches here before it would start a server.
module Gori::CLI
  MCP_USAGE_DEFAULT_SINCE = "7d"

  MCP_USAGE_ENABLE_HINT = "switch on Preferences › AI › MCP server › Usage log, or set " \
                          "\"mcp\": {\"usage_log\": true} in settings.json " \
                          "(`gori settings --edit`), then restart the agent's gori MCP server"

  # The arguments a tool row names, most-passed first. The rest are in `--json`.
  MCP_USAGE_TOP_ARGS = 4

  # The log a `gori mcp` server is handed: one only when the operator switched it on
  # (`Settings.mcp_usage_log?`, loaded by the caller), nil otherwise — and nil is what keeps
  # the file from ever being created.
  def self.mcp_usage_log : MCP::UsageLog?
    Settings.mcp_usage_log? ? MCP::UsageLog.new : nil
  end

  # "24h" / "7d" → how far back to read; "all" → nil, the whole file.
  private def self.parse_usage_since(value : String) : Time::Span?
    return nil if value == "all"
    # .scrub: an invalid byte is a PCRE2 error, not a failed match, and would escape as a
    # backtrace instead of the usage error below (`Run.parse_duration`).
    m = value.scrub.match(/\A(\d{1,5})(h|d)\z/)
    abort "gori mcp: invalid --since '#{value}' (use e.g. 24h, 7d, or all)" unless m
    n = m[1].to_i
    abort "gori mcp: --since must be greater than 0 (got '#{value}')" if n == 0
    m[2] == "h" ? n.hours : n.days
  end

  private def self.run_mcp_usage(since : String, json : Bool) : Nil
    Settings.load
    span = parse_usage_since(since)
    summary = begin
      MCP::UsageLog::Summary.read(Paths.mcp_usage_log, span.try { |s| Time.utc - s })
    rescue ex : Gori::Error
      abort "gori mcp: #{ex.message}"
    end
    if json
      puts mcp_usage_json(summary, since, Settings.mcp_usage_log?)
    else
      print mcp_usage_text(summary, since, Settings.mcp_usage_log?)
    end
  end

  # Every tool a recorded session could have called: the union, over the profiles the
  # sessions described, of what that `--tools` spec, `--read-only` and the permission groups
  # that were switched off serve in THIS gori. A
  # spec this build cannot parse (written by a different version) contributes nothing rather
  # than failing the report. Empty when no session line survived in the window.
  def self.mcp_usage_advertised(summary : MCP::UsageLog::Summary) : Set(String)
    names = Set(String).new
    summary.profiles.each_key do |(spec, read_only, denied)|
      filter = nil.as(MCP::ToolFilter?)
      if spec
        parsed = MCP::ToolFilter.parse(spec, MCP::Tools::TOOL_NAMES, MCP::Tools::TOOL_DEPENDENCIES)
        next unless parsed.is_a?(MCP::ToolFilter)
        filter = parsed
      end
      names.concat(MCP::Tools.served_names(filter, !read_only, denied.to_set))
    end
    names
  end

  # Advertised to some recorded session, called by none.
  def self.mcp_usage_never_called(summary : MCP::UsageLog::Summary) : Array(String)
    (mcp_usage_advertised(summary) - summary.tools.keys.to_set).to_a.sort!
  end

  private def self.usage_window(since : String) : String
    since == "all" ? "everything recorded" : "last #{since}"
  end

  private def self.usage_profile(profile : MCP::UsageLog::Summary::Profile) : String
    spec, read_only, denied = profile
    notes = [] of String
    notes << "read-only" if read_only
    notes << "without #{denied.join(", ")}" unless denied.empty?
    "#{spec || "*"}#{" (#{notes.join("; ")})" unless notes.empty?}"
  end

  # "a 12 · b 2", most frequent first, ties by name so the line is stable.
  private def self.usage_tally(counts : Hash(String, Int32), joiner : String = " ", sep : String = " · ") : String
    counts.to_a.sort_by! { |(name, n)| {-n, name} }.join(sep) { |(name, n)| "#{name}#{joiner}#{n}" }
  end

  private def self.usage_size(values : Array(Int64)) : String
    return "-" unless mid = MCP::UsageLog::Summary.median(values)
    "#{Output.human_size(mid)} / #{Output.human_size(values.max)}"
  end

  # The report as text. Holds nothing a captured target or an argument value could have put
  # there (see `MCP::UsageLog`), so it can be pasted into an issue as it is printed.
  def self.mcp_usage_text(summary : MCP::UsageLog::Summary, since : String, enabled : Bool) : String
    String.build do |io|
      unless enabled
        io << "gori mcp: the usage log is off, so nothing new is being recorded — " << MCP_USAGE_ENABLE_HINT << '\n'
      end
      if summary.empty?
        io << "gori mcp usage · " << usage_window(since) << " · no sessions recorded\n" if enabled
        next
      end
      io << '\n' unless enabled
      usage_header(io, summary, since)
      usage_table(io, summary)
      usage_footer(io, summary)
    end
  end

  private def self.usage_header(io : IO, summary : MCP::UsageLog::Summary, since : String) : Nil
    io << "gori mcp usage · " << usage_window(since) << " · "
    io << Gori.plural(summary.sessions, "session")
    io << " (" << summary.idle_sessions << " made no calls)" if summary.idle_sessions > 0
    io << " · " << Gori.plural(summary.calls, "call") << '\n'
    io << "clients    " << usage_tally(summary.clients) << '\n'
    unless summary.profiles.empty?
      profiles = summary.profiles.transform_keys { |p| usage_profile(p) }
      io << "profile    " << usage_tally(profiles) << '\n'
    end
    if size = MCP::UsageLog::Summary.median(summary.catalogue_bytes)
      io << "catalogue  " << Output.human_size(size) << " per tools/list\n"
    end
  end

  private def self.usage_table(io : IO, summary : MCP::UsageLog::Summary) : Nil
    rows = summary.tools.to_a.sort_by! { |(name, stat)| {-stat.calls, name} }
    return if rows.empty?
    cells = rows.map do |(name, stat)|
      top = stat.error_codes.to_a.sort_by! { |(code, n)| {-n, code} }.first?
      args = stat.args.to_a.sort_by! { |(arg, n)| {-n, arg} }.first(MCP_USAGE_TOP_ARGS)
      [name, stat.calls.to_s, stat.errors.to_s, top ? "#{top[0]} ×#{top[1]}" : "",
       usage_size(stat.bytes), MCP::UsageLog::Summary.median(stat.ms).try(&.to_s) || "-",
       args.join(' ') { |(arg, n)| "#{arg}×#{n}" }]
    end
    head = ["TOOL", "CALLS", "ERR", "TOP ERROR", "REPLY p50 / max", "p50 ms", "ARGS"]
    right = {1, 2, 5} # the numeric columns
    widths = head.map_with_index { |h, i| cells.max_of?(&.[i].size).try { |w| {w, h.size}.max } || h.size }
    io << '\n'
    ([head] + cells).each do |row|
      line = row.map_with_index do |cell, i|
        next cell if i == row.size - 1 # the last column is not padded
        right.includes?(i) ? cell.rjust(widths[i]) : cell.ljust(widths[i])
      end
      io << line.join("  ").rstrip << '\n'
    end
  end

  private def self.usage_footer(io : IO, summary : MCP::UsageLog::Summary) : Nil
    advertised = mcp_usage_advertised(summary)
    never = mcp_usage_never_called(summary)
    lines = [] of String
    unless advertised.empty?
      lines << "never called: #{never.size} of #{advertised.size} advertised tools (--json lists them)"
    end
    lines << "not served, but asked for: #{usage_tally(summary.not_served, " ×", ", ")}" unless summary.not_served.empty?
    lines << "unknown tool names: #{usage_tally(summary.unknown, " ×", ", ")}" unless summary.unknown.empty?
    return if lines.empty?
    io << '\n'
    lines.each { |line| io << line << '\n' }
  end

  # The same report for a script. Keys are written in a fixed order and every tally is
  # sorted, so two runs over one file print the same bytes.
  def self.mcp_usage_json(summary : MCP::UsageLog::Summary, since : String, enabled : Bool) : String
    JSON.build do |j|
      j.object do
        j.field "enabled", enabled
        j.field "since", since
        j.field "sessions", summary.sessions
        j.field "idle_sessions", summary.idle_sessions
        j.field "calls", summary.calls
        j.field("clients") { usage_counts(j, summary.clients) }
        j.field("profiles") do
          j.array do
            summary.profiles.to_a.sort_by! { |(p, n)| {-n, usage_profile(p)} }.each do |((spec, read_only, denied), n)|
              j.object do
                j.field "tools", spec
                j.field "read_only", read_only
                j.field "denied", denied
                j.field "sessions", n
              end
            end
          end
        end
        j.field("catalogue_bytes") { usage_spread(j, summary.catalogue_bytes) }
        j.field("tools") do
          j.array do
            summary.tools.to_a.sort_by! { |(name, stat)| {-stat.calls, name} }.each do |(name, stat)|
              usage_tool(j, name, stat)
            end
          end
        end
        j.field "never_called", mcp_usage_never_called(summary)
        j.field("not_served") { usage_counts(j, summary.not_served) }
        j.field("unknown_tools") { usage_counts(j, summary.unknown) }
      end
    end
  end

  private def self.usage_tool(j : JSON::Builder, name : String, stat : MCP::UsageLog::Summary::ToolStat) : Nil
    j.object do
      j.field "tool", name
      j.field "calls", stat.calls
      j.field "errors", stat.errors
      j.field "undelivered", stat.undelivered
      j.field("error_codes") { usage_counts(j, stat.error_codes) }
      j.field("args") { usage_counts(j, stat.args) }
      j.field "undeclared_args", stat.extra_args
      j.field("reply_bytes") { usage_spread(j, stat.bytes) }
      j.field("ms") { usage_spread(j, stat.ms) }
    end
  end

  private def self.usage_counts(j : JSON::Builder, counts : Hash(String, Int32)) : Nil
    j.object do
      counts.to_a.sort_by! { |(name, n)| {-n, name} }.each { |(name, n)| j.field name, n }
    end
  end

  private def self.usage_spread(j : JSON::Builder, values : Array(Int64)) : Nil
    j.object do
      j.field "median", MCP::UsageLog::Summary.median(values)
      j.field "max", values.max?
    end
  end
end
