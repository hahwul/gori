# `gori run compare` — diff two flows' request or response (the CLI counterpart of
# the TUI's Comparer tab). Reuses Repeater::MessageLines (decode/split) and
# Repeater::Diff (LCS line diff) so the comparison matches the TUI exactly.
module Gori
  module CLI
    module Run
      private def self.cmd_compare(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        pane = :response
        changes_only = false
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run compare <id-a> <id-b> [options]\n\n" \
                     "Diff two flows' request or response (default: response)."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--pane=PANE", "What to diff: request | response (default: response)") do |v|
            pane = case v.strip.downcase
                   when "request"  then :request
                   when "response" then :response
                   else                 abort "gori run compare: --pane must be request or response"
                   end
          end
          p.on("--changes-only", "Only print added/removed lines (omit unchanged context)") { changes_only = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run compare: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run compare: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run compare: need two flow ids\n#{parser}" if positional.size < 2
        abort "gori run compare: too many arguments (expected two flow ids, got: #{positional.join(" ")})" if positional.size > 2
        id_a = positional[0].to_i64? || abort("gori run compare: invalid flow id '#{positional[0]}'")
        id_b = positional[1].to_i64? || abort("gori run compare: invalid flow id '#{positional[1]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        detail_a, detail_b = begin
          {store.get_flow(id_a), store.get_flow(id_b)}
        ensure
          store.close
        end
        abort "gori run compare: no flow ##{id_a}" unless detail_a
        abort "gori run compare: no flow ##{id_b}" unless detail_b

        lines_a = compare_lines(detail_a, pane)
        lines_b = compare_lines(detail_b, pane)
        truncated = lines_a.size > Repeater::Diff::MAX_LINES || lines_b.size > Repeater::Diff::MAX_LINES
        full_diff = Repeater::Diff.lines(lines_a, lines_b)
        change_count = Repeater::Diff.change_count(full_diff)
        diff = changes_only ? full_diff.reject { |dl| dl.kind == Repeater::DiffKind::Same } : full_diff

        emit_compare_result(id_a, id_b, pane, diff, change_count, truncated, format)
      end

      private def self.compare_lines(d : Store::FlowDetail, pane : Symbol) : Array(String)
        if pane == :request
          Repeater::MessageLines.of(d.request_head, d.request_body, decode: false)
        else
          Repeater::MessageLines.of(d.response_head, d.response_body, decode: true)
        end
      end

      private def self.emit_compare_result(id_a : Int64, id_b : Int64, pane : Symbol,
                                           diff : Array(Repeater::DiffLine), change_count : Int32,
                                           truncated : Bool, format : Symbol) : Nil
        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "flow_id_a", id_a
              j.field "flow_id_b", id_b
              j.field "pane", pane.to_s
              j.field "changed_lines", change_count
              j.field "truncated", truncated
              j.field "diff" do
                j.array do
                  diff.each do |dl|
                    j.object do
                      j.field "kind", dl.kind.to_s.downcase
                      j.field "text", dl.text
                    end
                  end
                end
              end
            end
          end)
        else
          STDERR.puts "— #{pane} diff: flow ##{id_a} vs ##{id_b} —"
          print_diff(diff)
          STDERR.puts "(truncated to #{Repeater::Diff::MAX_LINES} lines/side)" if truncated
          STDERR.puts(change_count == 0 ? "no differences" : "#{change_count} line#{change_count == 1 ? "" : "s"} changed")
        end
      end
    end
  end
end
