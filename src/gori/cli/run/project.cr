# `gori run project` — list known projects, or manage project-scoped config:
# scope rules, env vars ($KEY substitution), and host overrides.
module Gori
  module CLI
    module Run
      private def self.cmd_project(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when nil
          cmd_project_list(args)
        when "-h", "--help"
          print_project_help
        when "list"
          cmd_project_list(args[1..])
        when "scope"
          cmd_project_scope(args[1..])
        when "env"
          cmd_project_env(args[1..])
        when "host-override", "host-overrides"
          cmd_project_host_override(args[1..])
        else
          # Flags only (e.g. --format json) → list projects
          if (s = sub) && s.starts_with?('-')
            cmd_project_list(args)
          else
            STDERR.puts "gori run project: unknown subcommand '#{sub}'"
            print_project_help
            exit 1
          end
        end
      end

      private def self.print_project_help : Nil
        puts <<-HELP
        gori run project — list projects, or manage project-scoped config

        Usage: gori run project [<subcommand>] [options]

        Subcommands:
          list               List known projects (default when no subcommand)
          scope              Manage scope rules (list, add, delete, enable/disable)
          env                Manage project env vars ($KEY substitution)
          host-override      Manage host overrides (list, add, update, delete)

        Examples:
          gori run project --format json
          gori run project scope add --kind=include --type=host --pattern=api.example.com
          gori run project env set TOKEN=secret
          gori run project host-override add --host=api.example.com --ip=10.0.0.1

        See 'gori run project <subcommand> --help' for more.
        HELP
      end

      private def self.cmd_project_list(args : Array(String)) : Nil
        format = :text
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project [list] [options]"
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project: missing value for #{f}" }
        end
        parser.parse(args)

        registry = ProjectRegistry.new(Paths.projects_dir)
        projects = registry.list
        if format == :json
          puts(JSON.build do |j|
            j.array do
              projects.each do |pr|
                j.object do
                  j.field "name", pr.name
                  j.field "id", registry.id_of(pr)
                  j.field "slug", registry.slug_of(pr)
                  j.field "db_path", pr.db_path
                  j.field "db_size", pr.db_size
                  j.field "last_modified", pr.last_modified.try(&.to_unix)
                  j.field "time", pr.last_modified.try(&.to_local.to_s("%Y-%m-%dT%H:%M:%S%:z"))
                end
              end
            end
          end)
        elsif projects.empty?
          STDERR.puts "no projects yet — capture some traffic (gori run capture / the TUI) first"
        else
          projects.each do |pr|
            ts = pr.last_modified.try(&.to_local.to_s("%Y-%m-%d %H:%M")) || "—"
            id = registry.id_of(pr) || "—"
            puts "#{pr.name.ljust(24)}  #{id.ljust(8)}  #{ts}  #{CLI::Output.human_size(pr.db_size)}"
          end
        end
      end

      private def self.cmd_project_scope(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "add"
          cmd_scope_add(args[1..])
        when "delete", "rm"
          cmd_scope_delete(args[1..])
        when "enable"
          cmd_scope_set_enabled(true, args[1..])
        when "disable"
          cmd_scope_set_enabled(false, args[1..])
        when "list"
          cmd_scope_list(args[1..])
        when nil
          cmd_scope_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_scope_list(args)
          else
            STDERR.puts "gori run project scope: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project scope [list options] | add | delete|rm | enable | disable"
            exit 1
          end
        end
      end

      private def self.cmd_scope_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope [options]\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project scope add --kind=include/exclude --type=host/string/regex --pattern=...\n" \
                     "  gori run project scope delete|rm <rule-id>\n" \
                     "  gori run project scope enable\n" \
                     "  gori run project scope disable"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "enabled", scope.enabled?
                j.field "rules" do
                  j.array do
                    scope.rules.each do |r|
                      j.object do
                        j.field "id", r.id
                        j.field "kind", r.kind
                        j.field "type", r.match_type
                        j.field "pattern", r.pattern
                      end
                    end
                  end
                end
              end
            end)
          else
            puts "Scope filtering: #{scope.enabled? ? "ENABLED" : "DISABLED"}"
            if scope.rules.empty?
              puts "No scope rules configured."
            else
              scope.rules.each do |r|
                puts "##{r.id}  #{r.kind.ljust(8)}  #{r.match_type.ljust(6)}  #{r.pattern}"
              end
            end
          end
        ensure
          store.close
        end
      end

      private def self.cmd_scope_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        kind = "include"
        match_type = "host"
        pattern : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope add [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-kKIND", "--kind=KIND", "Rule kind: include|exclude (default: include)") { |v| kind = v }
          p.on("-tTYPE", "--type=TYPE", "Match type: host|string|regex (default: host)") { |v| match_type = v }
          p.on("-pPATTERN", "--pattern=PATTERN", "Pattern to match (required)") { |v| pattern = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope add: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project scope add: --pattern is required" if (pat = pattern).nil? || pat.empty?
        abort "gori run project scope add: invalid kind '#{kind}' (must be include or exclude)" unless kind.in?(Scope::KINDS)
        abort "gori run project scope add: invalid type '#{match_type}' (must be host, string, or regex)" unless match_type.in?(Scope::TYPES)
        if err = Scope.validation_error(match_type, pat.strip)
          abort "gori run project scope add: #{err}"
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          unless scope.add(kind, match_type, pat)
            store.close
            abort "gori run project scope add: failed to add rule (duplicate, empty, or invalid)"
          end
          puts "Scope rule added successfully."
        ensure
          store.close
        end
      end

      private def self.cmd_scope_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope delete|rm <rule-id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope delete: missing value for #{f}" }
        end

        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)

        abort "gori run project scope delete: missing <rule-id>" if positional.empty?
        abort "gori run project scope delete: too many arguments (expected one <rule-id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project scope delete: invalid rule id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          unless scope.rules.any? { |r| r.id == id }
            store.close
            abort "gori run project scope delete: no scope rule with id #{id}"
          end
          scope.remove(id)
          puts "Scope rule ##{id} deleted successfully."
        ensure
          store.close
        end
      end

      private def self.cmd_scope_set_enabled(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        action = enable ? "enable" : "disable"

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope #{action} [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope #{action}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope #{action}: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          if enable
            scope.enable
            puts "Scope filtering enabled."
          else
            scope.disable
            puts "Scope filtering disabled."
          end
        ensure
          store.close
        end
      end

      private def self.cmd_project_env(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "set"
          cmd_env_set(args[1..])
        when "delete", "rm"
          cmd_env_delete(args[1..])
        when "list"
          cmd_env_list(args[1..])
        when nil
          cmd_env_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_env_list(args)
          else
            STDERR.puts "gori run project env: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project env [list options] | set KEY=value | delete|rm KEY"
            exit 1
          end
        end
      end

      private def self.cmd_env_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env [options]\n\n" \
                     "List project env vars used for $KEY substitution in outbound requests.\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project env set KEY=value\n" \
                     "  gori run project env set KEY value\n" \
                     "  gori run project env delete|rm KEY"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project env: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars
          if format == :json
            puts(JSON.build do |j|
              j.array do
                vars.each do |(key, val)|
                  j.object do
                    j.field "key", key
                    j.field "value", val
                  end
                end
              end
            end)
          elsif vars.empty?
            STDERR.puts "no project env vars configured"
          else
            vars.each { |(key, val)| puts "#{key}=#{val}" }
          end
        ensure
          store.close
        end
      end

      private def self.cmd_env_set(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env set KEY=value [options]\n" \
                     "       gori run project env set KEY value [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project env set: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env set: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project env set: missing KEY=value (or KEY value)" if positional.empty?
        line = positional.join(' ')
        parsed = Env.parse_line(line)
        abort "gori run project env set: invalid KEY (use [A-Za-z_][A-Za-z0-9_]*)" unless parsed
        key, val = parsed

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars.dup
          if idx = vars.index { |(k, _)| k == key }
            vars[idx] = {key, val}
          else
            vars << {key, val}
          end
          Env.save_project(store, vars)
          puts "Env var #{key} set."
        ensure
          store.close
        end
      end

      private def self.cmd_env_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env delete|rm KEY [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project env delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env delete: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project env delete: missing KEY" if positional.empty?
        abort "gori run project env delete: too many arguments (expected one KEY)" if positional.size > 1
        key = positional[0]
        abort "gori run project env delete: invalid KEY '#{key}'" unless Env.valid_key?(key)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars.dup
          before = vars.size
          vars.reject! { |(k, _)| k == key }
          if vars.size == before
            store.close
            abort "gori run project env delete: no env var named '#{key}'"
          end
          Env.save_project(store, vars)
          puts "Env var #{key} deleted."
        ensure
          store.close
        end
      end

      private def self.cmd_project_host_override(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "add"
          cmd_host_override_add(args[1..])
        when "update"
          cmd_host_override_update(args[1..])
        when "delete", "rm"
          cmd_host_override_delete(args[1..])
        when "list"
          cmd_host_override_list(args[1..])
        when nil
          cmd_host_override_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_host_override_list(args)
          else
            STDERR.puts "gori run project host-override: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project host-override [list options] | add | update | delete|rm"
            exit 1
          end
        end
      end

      private def self.cmd_host_override_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override [options]\n\n" \
                     "List project host overrides (/etc/hosts-style: dial IP for hostname).\n" \
                     "Project overrides win over global Settings: Hostnames on collision.\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project host-override add --host=api.example.com --ip=10.0.0.1\n" \
                     "  gori run project host-override add 10.0.0.1 api.example.com\n" \
                     "  gori run project host-override update <id> --host=... --ip=...\n" \
                     "  gori run project host-override delete|rm <id>"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project host-override: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          if format == :json
            puts(JSON.build do |j|
              j.array do
                ov.entries.each do |e|
                  j.object do
                    j.field "id", e.id
                    j.field "host", e.host
                    j.field "ip", e.ip
                  end
                end
              end
            end)
          elsif ov.entries.empty?
            STDERR.puts "no host overrides configured"
          else
            ov.entries.each do |e|
              puts "##{e.id}  #{e.ip.ljust(15)}  #{e.host}"
            end
          end
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        host : String? = nil
        ip : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override add --host=HOST --ip=IP [options]\n" \
                     "       gori run project host-override add IP HOST [options]\n\n" \
                     "Add a project host override (dial IP for HOST; SNI/Host header unchanged)."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--host=HOST", "Hostname to override (case-insensitive)") { |v| host = v }
          p.on("--ip=IP", "IPv4/IPv6 literal to dial") { |v| ip = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override add: missing value for #{f}" }
        end
        parser.parse(args)

        # Flags win when both are given; otherwise accept /etc/hosts-style "IP HOST".
        pair =
          if (h_flag = host) && (i_flag = ip)
            {h_flag, i_flag}
          else
            abort "gori run project host-override add: need --host and --ip, or positional IP HOST" if positional.empty?
            parsed = HostOverrides.parse_line(positional.join(' '))
            abort "gori run project host-override add: invalid entry (expected IP HOST; IP must be a literal)" unless parsed
            parsed
          end
        h, i = pair
        abort "gori run project host-override add: invalid host/ip (host hostname-shaped, ip an IPv4/IPv6 literal)" unless HostOverrides.valid?(h, i)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.add(h, i)
            store.close
            abort "gori run project host-override add: failed to add override (duplicate host, empty, or invalid)"
          end
          entry = ov.entries.find { |e| e.host == h.strip.downcase }
          if e = entry
            puts "Host override ##{e.id} added: #{e.ip} → #{e.host}"
          else
            puts "Host override added: #{i} → #{h.strip.downcase}"
          end
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_update(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        host : String? = nil
        ip : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override update <id> --host=HOST --ip=IP [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--host=HOST", "New hostname (case-insensitive)") { |v| host = v }
          p.on("--ip=IP", "New IPv4/IPv6 literal to dial") { |v| ip = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override update: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override update: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project host-override update: missing <id>" if positional.empty?
        abort "gori run project host-override update: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project host-override update: invalid id '#{positional[0]}'")
        h = host
        i = ip
        abort "gori run project host-override update: --host and --ip are both required" unless h && i
        abort "gori run project host-override update: invalid host/ip (host hostname-shaped, ip an IPv4/IPv6 literal)" unless HostOverrides.valid?(h, i)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.entries.any? { |e| e.id == id }
            store.close
            abort "gori run project host-override update: no override with id #{id}"
          end
          unless ov.update(id, h, i)
            store.close
            abort "gori run project host-override update: failed (duplicate host, empty, or invalid)"
          end
          puts "Host override ##{id} updated: #{i} → #{h.strip.downcase}"
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override delete|rm <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override delete: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project host-override delete: missing <id>" if positional.empty?
        abort "gori run project host-override delete: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project host-override delete: invalid id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.entries.any? { |e| e.id == id }
            store.close
            abort "gori run project host-override delete: no override with id #{id}"
          end
          ov.remove(id)
          puts "Host override ##{id} deleted."
        ensure
          store.close
        end
      end
    end
  end
end
