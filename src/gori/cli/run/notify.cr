# `gori run notify` — put one line in front of the operator in the gori TUI (#1323). The
# script-side counterpart of MCP `reply_to_operator`: a twenty-minute `gori run fuzz` in a
# shell loop can say "done, 3 hits" where the operator is actually looking.
module Gori
  module CLI
    module Run
      @[Subcommand("notify", help: [
        {"notify <summary>", "Show the operator a line in the gori TUI (ring + Miss Ring)"},
      ])]
      private def self.cmd_notify(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        detail : String? = nil
        detail_file : String? = nil
        level = "info"
        format = :text

        positional = parse_args(args, "gori run notify") do |p|
          p.banner = "Usage: gori run notify <summary> [options]\n\n" \
                     "Show the operator one line in the gori TUI open on the project: the\n" \
                     "notification ring and Miss Ring's bubble, with the detail behind ↵.\n" \
                     "Written even when no TUI is open — the next one to open sums it up.\n" \
                     "Exits 0 either way; the output says whether a window was there to show it."
          p.on("--detail=TEXT", "The long form, opened from the ring with ↵") { |v| detail = v }
          p.on("--detail-file=PATH", "Read the detail from a file (- for STDIN)") { |v| detail_file = v }
          p.on("--level=LEVEL", "info (default) | success | warn | error") { |v| level = v }
          p.on("--project=NAME", "Project to notify (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to notify") { |v| db_path = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        if msg = notify_args_error(positional, level, detail, detail_file)
          abort msg
        end
        summary = positional.join(' ').strip
        if path = detail_file
          detail = read_input_file(path, "gori run notify", stdin: true, noun: "detail", flag: "--detail-file=-")
        end

        project = resolve_read_project(project_name, db_path)
        # Counted BEFORE the write, for the reason `AgentPresence.tui_windows?` gives.
        windows = AgentPresence.tui_windows?(project.db_path)
        store = open_store(project)
        id = begin
          store.record_script_notice(summary, detail.try(&.presence), level,
            "gori run pid #{Process.pid}", Process.pid.to_i64)
        ensure
          store.close
        end
        abort "gori run notify: project is busy (write did not commit) — try again" if id <= 0
        puts notify_output(id, project.name, AgentReply.summary_line(summary), windows, format)
      end

      # The usage refusals, split from the abort so a spec can drive them (`two_targets_error`'s
      # shape). A level outside the four is refused, not clamped: the MCP tool refuses it too,
      # and a script that typed `--level=critical` should hear that it did not get one.
      def self.notify_args_error(positional : Array(String), level : String, detail : String?,
                                 detail_file : String?) : String?
        if positional.join(' ').strip.empty?
          return "gori run notify: no summary — pass the line to show, e.g. gori run notify \"fuzz done, 3 hits\""
        end
        unless AgentReply::LEVELS.includes?(level)
          return "gori run notify: --level must be one of #{AgentReply::LEVELS.join(", ")} (got #{CLI::Output.term_safe(level).inspect})"
        end
        return "gori run notify: pass --detail or --detail-file, not both" if detail && detail_file
        nil
      end

      # What `notify` prints. The row is written whatever the answer, so every branch is a
      # success; what differs is whether anybody was shown it — the one thing a script cannot
      # find out any other way, and the reason the JSON carries `tui` in the shape MCP's
      # `reply_to_operator` and `get_current_context` use.
      def self.notify_output(id : Int64, project : String, summary : String, windows : Int32?,
                             format : Symbol) : String
        if format == :json
          return JSON.build do |j|
            j.object do
              j.field "ok", true
              j.field "id", id
              j.field "project", project
              j.field "summary", summary
              j.field("tui") { AgentPresence.tui_json(j, windows) }
            end
          end
        end
        name = CLI::Output.term_safe(project)
        case windows
        when nil
          "recorded in #{name}; cannot tell whether a gori TUI is open to show it " \
          "(if none is, the next one to open sums it up)"
        when 0
          "no gori TUI is open on #{name}, so nobody was shown this yet: the next one to open " \
          "sums it up, and the Project tab's Activity pane keeps it"
        else
          "shown in the gori TUI open on #{name} (#{windows} window#{windows == 1 ? "" : "s"})"
        end
      end
    end
  end
end
