# `gori run issues` — list, export, create, or update issues (text, json, markdown).
module Gori
  module CLI
    module Run
      private def self.cmd_issues(args : Array(String)) : Nil
        if args.first? == "create"
          cmd_issues_create(args[1..])
          return
        elsif args.first? == "update"
          cmd_issues_update(args[1..])
          return
        end

        db_path : String? = nil
        project_name : String? = nil
        format = :text
        export_path : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run issues [options]\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run issues create [options]\n" \
                     "  gori run issues update <issue-id> [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json | markdown") { |v| format = parse_format(v, [:text, :json, :markdown]) }
          p.on("--export=PATH", "Write to PATH instead of STDOUT") { |v| export_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run issues: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run issues: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        # Build the report while the store is open (markdown resolves linked-flow
        # evidence), then close BEFORE any file I/O so a write failure can't leak the
        # connection — and so the abort below runs after a clean close.
        result = begin
          issues = store.issues
          if issues.empty? && format == :text && export_path.nil?
            STDERR.puts "no issues"
            return
          end
          content =
            case format
            when :json     then Issues::Export.json(issues, store)
            when :markdown then Issues::Export.markdown(issues, store, project.name)
            else                issues_text(issues)
            end
          {content, issues.size}
        ensure
          store.close
        end
        content, count = result

        if path = export_path
          begin
            File.write(path, content.ends_with?('\n') ? content : "#{content}\n")
          rescue ex : File::Error
            abort "gori run issues: cannot write to #{path}: #{ex.message}"
          end
          STDERR.puts "exported #{count} issue#{count == 1 ? "" : "s"} → #{path}"
        else
          puts content
        end
      end

      private def self.cmd_issues_create(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        title : String? = nil
        sev_s = "info"
        host : String? = nil
        flow_id : Int64? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run issues create [options]"
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-tTITLE", "--title=TITLE", "Issue title (required)") { |v| title = v }
          p.on("-sSEVERITY", "--severity=SEVERITY", "Severity: info|low|medium|high|critical (default: info)") { |v| sev_s = v }
          p.on("--host=HOST", "Host concerning the issue") { |v| host = v }
          p.on("--flow=ID", "Associated flow ID") { |v| flow_id = parse_flow_id(v, "gori run issues create") }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run issues create: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run issues create: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run issues create: --title is required" if (t = title).nil? || t.empty?

        severity = Store::Severity.parse?(sev_s.strip) || abort("gori run issues create: invalid severity '#{sev_s}' (info|low|medium|high|critical)")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          masked_title = Env.mask_secrets(t)
          masked_host = host.try { |h| Env.mask_secrets(h) }
          id = store.insert_issue(masked_title, severity, masked_host, flow_id)
          abort "gori run issues create: failed to persist issue (store busy or unwritable)" if id == 0
          puts "Issue ##{id} created successfully."
        ensure
          store.close
        end
      end

      private def self.cmd_issues_update(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        id : Int64? = nil
        title : String? = nil
        sev_s : String? = nil
        notes : String? = nil
        stat_s : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run issues update <issue-id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-tTITLE", "--title=TITLE", "New issue title") { |v| title = v }
          p.on("-sSEVERITY", "--severity=SEVERITY", "Severity: info|low|medium|high|critical") { |v| sev_s = v }
          p.on("-nNOTES", "--notes=NOTES", "Free-form notes") { |v| notes = v }
          p.on("--status=STATUS", "Status: open|confirmed|false-positive|resolved") { |v| stat_s = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run issues update: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run issues update: missing value for #{f}" }
        end

        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)

        abort "gori run issues update: missing <issue-id>" if positional.empty?
        abort "gori run issues update: too many arguments (expected one <issue-id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run issues update: invalid issue id '#{positional[0]}'")

        severity = sev_s.try { |s| Store::Severity.parse?(s.strip) || abort("gori run issues update: invalid severity '#{s}'") }
        status = stat_s.try do |s|
          case s.strip.downcase
          when "open"                                              then Store::Status::Open
          when "confirmed"                                         then Store::Status::Confirmed
          when "false-positive", "false_positive", "falsepositive" then Store::Status::FalsePositive
          when "resolved"                                          then Store::Status::Resolved
          else                                                          abort("gori run issues update: invalid status '#{s}' (open|confirmed|false-positive|resolved)")
          end
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          abort "gori run issues update: no issue with id #{id}" unless store.get_issue(id)

          if title.nil? && severity.nil? && notes.nil? && status.nil?
            abort "gori run issues update: no fields to update (provide at least one of --title/--severity/--notes/--status)"
          end

          masked_title = title.try { |t| Env.mask_secrets(t) }
          masked_notes = notes.try { |n| Env.mask_secrets(n) }

          store.update_issue(id, title: masked_title, severity: severity, notes: masked_notes, status: status)
          puts "Issue ##{id} updated successfully."
        ensure
          store.close
        end
      end

      private def self.issues_text(issues : Array(Store::Issue)) : String
        String.build do |io|
          issues.each do |f|
            io << '#' << f.id << "  [" << f.severity.label << '/' << f.status.label << "]  " << Issues::Export.one_line(f.title)
            if h = f.host
              io << "  (" << Issues::Export.one_line(h) << ')'
            end
            io << "  flow#" << f.flow_id if f.flow_id
            io << '\n'
          end
        end.rstrip('\n')
      end
    end
  end
end
