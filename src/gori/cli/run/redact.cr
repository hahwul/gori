# `gori run redact` — manage the safe-evidence-export profiles (#1035), and the three flags
# every command that writes SHAREABLE output carries. See `Gori::Redact` for what a profile
# does to a body and `Redact::Policy` for how the project and global scopes fold.
module Gori
  module CLI
    module Run
      # The redaction flags a command collected, in one place so `gori run show` and
      # `gori run history --format har` cannot spell them differently. A class and not a record
      # because OptionParser fills it in from callbacks.
      class RedactFlags
        # `--redact=NAME`. nil = no name was given, which is not the same as "no profile": the
        # configured active profile then decides.
        property profile : String? = nil

        # The tri-state the two flags produce — true from `--redact`, false from `--no-redact`,
        # nil when neither was given and the configuration decides.
        property mode : Bool? = nil

        # `--redact-preview`: say what would be replaced and emit no document at all.
        property? preview : Bool = false
      end

      # Add the flags to a command's parser. One helper, so the help text is identical
      # everywhere and a command cannot accidentally offer `--redact` without `--no-redact`.
      private def self.redact_options(p : OptionParser, flags : RedactFlags) : Nil
        p.on("--redact [PROFILE]",
          "Sanitize request/response BODIES before printing, using PROFILE " \
          "(default: the project's, else the global one, else the built-in `default`)") do |v|
          flags.mode = true
          flags.profile = v.presence
        end
        p.on("--no-redact", "Print bodies exactly as captured, even when redaction is the configured default") do
          flags.mode = false
        end
        p.on("--redact-preview", "List what --redact would replace and print nothing else") do
          flags.mode = true
          flags.preview = true
        end
      end

      # Resolve the flags against the open project. Deliberately returns the `Choice` rather
      # than aborting on a bad profile name: every caller here is holding an open store, and
      # `abort` skips `ensure` (see `cmd_show`), so the refusal has to happen after the close.
      private def self.redact_choice(store : Store?, flags : RedactFlags) : Redact::Policy::Choice
        Redact::Policy.resolve(store, flags.profile, flags.mode)
      end

      # Everything a sanitized artifact has to SAY, on STDERR — never mixed into the document on
      # STDOUT, the rule this file already holds for every other caveat.
      # Nil-tolerant: the caller is a command that may or may not have redacted, and pushing
      # that question in here keeps the branch out of every call site.
      private def self.redact_notes(report : Redact::Report?, command : String,
                                    salt_persisted : Bool = true, io : IO = STDERR) : Nil
        return unless report
        io.puts "gori run #{command}: #{report.summary}"
        if report.decoded?
          io.puts "gori run #{command}: a body was content-decoded to be read, so the sanitized " \
                  "head drops Content-Encoding/Transfer-Encoding and carries the new Content-Length"
        end
        report.pattern_errors.each do |err|
          io.puts "gori run #{command}: redaction pattern skipped, it does not compile — #{err}"
        end
        unless salt_persisted
          io.puts "gori run #{command}: the placeholder salt could not be saved to #{Settings.path}, " \
                  "so these tags are consistent within this export and will NOT match another session's"
        end
      end

      # `--redact-preview`: the replacements, one per line, as `side  path  rule`. The
      # PLACEHOLDER is printed too — it is not a secret and it is what an operator greps the
      # finished artifact for to confirm a value really went.
      private def self.print_redact_preview(report : Redact::Report, command : String,
                                            io : IO = STDOUT, notes_io : IO = STDERR) : Nil
        rows = report.replacements
        if rows.empty?
          io.puts "no body values match profile #{report.profile.name.inspect} in this flow"
        else
          side_w = rows.max_of { |(side, _)| side.size }
          path_w = rows.max_of { |(_, hit)| Output.cell_width(Output.term_safe(hit.path)) }
          rule_w = rows.max_of { |(_, hit)| Output.cell_width(Output.term_safe(hit.rule)) }
          rows.each do |(side, hit)|
            io.puts "#{Output.pad(side, side_w)}  #{Output.pad(Output.term_safe(hit.path), path_w)}  " \
                    "#{Output.pad(Output.term_safe(hit.rule), rule_w)}  #{hit.placeholder}"
          end
        end
        # On STDERR, like every caveat this file reports, so `--redact-preview > rows.txt`
        # captures the rows and nothing else.
        redact_notes(report, command, io: notes_io)
      end

      # The same two reports for a MULTI-flow export (`gori run history --format har`), where
      # the count is a total and the flow id is part of every row's address.
      private def self.emit_har_redact_notes(reports : Array({Int64, Redact::Report}),
                                             choice : Redact::Policy::Choice,
                                             command : String = "history",
                                             io : IO = STDERR) : Nil
        profile = choice.matcher.try(&.profile) || return
        total = reports.sum { |(_, r)| r.count }
        touched = reports.count { |(_, r)| r.redacted? }
        io.puts "gori run #{command}: sanitized with profile #{profile.name.inspect}: " \
                "#{total} value#{total == 1 ? "" : "s"} redacted from request/response bodies " \
                "across #{touched} of #{reports.size} flow#{reports.size == 1 ? "" : "s"} " \
                "(heads, URLs and query strings are NOT redacted)"
        if reports.any? { |(_, r)| r.decoded? }
          io.puts "gori run #{command}: a body was content-decoded to be read, so its entry's " \
                  "head drops Content-Encoding/Transfer-Encoding and carries the new Content-Length"
        end
        # Every report carries the SAME matcher's errors, so report them once.
        reports.first?.try(&.[1].pattern_errors).try &.each do |err|
          io.puts "gori run #{command}: redaction pattern skipped, it does not compile — #{err}"
        end
        unless choice.salt_persisted
          io.puts "gori run #{command}: the placeholder salt could not be saved to #{Settings.path}, " \
                  "so these tags are consistent within this export and will NOT match another session's"
        end
      end

      private def self.emit_har_redact_preview(reports : Array({Int64, Redact::Report}),
                                               choice : Redact::Policy::Choice,
                                               command : String = "history",
                                               io : IO = STDOUT,
                                               notes_io : IO = STDERR) : Nil
        rows = [] of {Int64, String, Redact::Hit}
        reports.each { |(id, report)| report.replacements.each { |(side, hit)| rows << {id, side, hit} } }
        if rows.empty?
          io.puts "no body values match in these flows"
        else
          id_w = rows.max_of { |(id, _, _)| id.to_s.size }
          side_w = rows.max_of { |(_, side, _)| side.size }
          path_w = rows.max_of { |(_, _, hit)| Output.cell_width(Output.term_safe(hit.path)) }
          rule_w = rows.max_of { |(_, _, hit)| Output.cell_width(Output.term_safe(hit.rule)) }
          rows.each do |(id, side, hit)|
            io.puts "##{Output.pad(id.to_s, id_w)}  #{Output.pad(side, side_w)}  " \
                    "#{Output.pad(Output.term_safe(hit.path), path_w)}  " \
                    "#{Output.pad(Output.term_safe(hit.rule), rule_w)}  #{hit.placeholder}"
          end
        end
        emit_har_redact_notes(reports, choice, command, notes_io)
      end

      # --- the subcommand ------------------------------------------------------

      @[Subcommand("redact", help: [
        {"redact", "Manage safe-export redaction profiles (profiles, use, default, set, rm)"},
      ])]
      private def self.cmd_redact(args : Array(String)) : Nil
        case sub = args.first?
        when "profiles", "list", nil then cmd_redact_profiles(args.empty? ? args : args[1..])
        when "use"                   then cmd_redact_use(args[1..])
        when "default"               then cmd_redact_default(args[1..])
        when "set"                   then cmd_redact_set(args[1..])
        when "rm", "delete"          then cmd_redact_rm(args[1..])
        else
          if (s = sub) && s.starts_with?('-')
            cmd_redact_profiles(args)
          else
            STDERR.puts "gori run redact: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run redact [profiles] | use <name>|--none | default on|off"
            STDERR.puts "       gori run redact set <name> [--json-field F]… | rm <name>"
            exit 1
          end
        end
      end

      private def self.cmd_redact_profiles(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run redact profiles [options]\n\n" \
                     "Lists every redaction profile available here — the project's own first,\n" \
                     "then settings.json's, then the built-ins — and says which one a safe\n" \
                     "export would use."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run redact profiles: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run redact profiles: missing value for #{f}" }
        end
        parse_no_positionals(parser, args, "gori run redact profiles",
          "`profiles` takes no positional arguments; to pick one use `gori run redact use <name>`")

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        scope, profiles, choice = begin
          {Redact::Policy.project_scope(store), Redact::Policy.profiles(store),
           Redact::Policy.resolve(store, nil, true)}
        ensure
          store.close
        end
        project_names = scope.profiles.map(&.name)
        global_names = Settings.redaction_profiles.map(&.name)
        active = choice.matcher.try(&.profile.name)
        if format == :json
          puts redact_profiles_json(profiles, project_names, global_names, active,
            Redact::Policy.default_on?(scope))
          return
        end
        if profiles.empty?
          puts "no redaction profiles"
          return
        end
        name_w = profiles.max_of { |p| Output.cell_width(p.name) }
        profiles.each do |p|
          scope_label = if project_names.includes?(p.name)
                          "project"
                        elsif global_names.includes?(p.name)
                          "global"
                        else
                          "built-in"
                        end
          mark = p.name == active ? "*" : " "
          puts "#{mark} #{Output.pad(Output.term_safe(p.name), name_w)}  #{Output.pad(scope_label, 8)}  " \
               "#{redact_rule_counts(p)}#{p.description.empty? ? "" : "  #{Output.term_safe(p.description)}"}"
        end
        puts
        puts "* = what a safe export uses here. Redaction #{Redact::Policy.default_on?(scope) ? "is ON by default" : "applies only with --redact"}."
      end

      private def self.redact_rule_counts(p : Redact::Profile) : String
        parts = [] of String
        parts << "#{p.json_fields.size} field#{p.json_fields.size == 1 ? "" : "s"}" unless p.json_fields.empty?
        parts << "#{p.json_pointers.size} pointer#{p.json_pointers.size == 1 ? "" : "s"}" unless p.json_pointers.empty?
        parts << "#{p.form_keys.size} form key#{p.form_keys.size == 1 ? "" : "s"}" unless p.form_keys.empty?
        parts << "#{p.patterns.size} pattern#{p.patterns.size == 1 ? "" : "s"}" unless p.patterns.empty?
        parts.empty? ? "no rules" : parts.join(", ")
      end

      private def self.redact_profiles_json(profiles : Array(Redact::Profile),
                                            project_names : Array(String),
                                            global_names : Array(String),
                                            active : String?, default_on : Bool) : String
        JSON.build do |j|
          j.object do
            j.field "active", active
            j.field "default", default_on
            j.field "profiles" do
              j.array do
                profiles.each do |p|
                  j.object do
                    j.field "name", p.name
                    j.field "scope", project_names.includes?(p.name) ? "project" : (global_names.includes?(p.name) ? "global" : "builtin")
                    j.field "description", p.description
                    {"json_fields" => p.json_fields, "json_pointers" => p.json_pointers,
                     "form_keys" => p.form_keys, "patterns" => p.patterns}.each do |key, values|
                      j.field key do
                        j.array { values.each { |v| j.string v } }
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def self.cmd_redact_use(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        global = false
        none = false
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run redact use <name> [options]\n\n" \
                     "Picks the profile a safe export uses. Writes the PROJECT by default, so\n" \
                     "the choice stays with this engagement; --global writes settings.json."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("--global", "Write settings.json instead of this project") { global = true }
          p.on("--none", "Clear the choice at this scope (fall back to the wider one)") { none = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run redact use", "profile name") }
          p.invalid_option { |f| abort "gori run redact use: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run redact use: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run redact use: name a profile, or pass --none\n#{parser}" if positional.empty? && !none
        abort "gori run redact use: --none takes no profile name" if none && !positional.empty?
        name = positional.first? || ""

        if global
          redact_use_global(name, none)
        else
          redact_use_project(project_name, db_path, name, none)
        end
      end

      private def self.redact_use_global(name : String, none : Bool) : Nil
        if !none && (err = Settings.redaction_profile_error(name))
          abort "gori run redact use: #{err}"
        end
        Settings.redaction_active = none ? "" : name
        abort "gori run redact use: could not write #{Settings.path}" unless Settings.save
        puts none ? "cleared the global redaction profile" : "global redaction profile: #{name}"
      end

      private def self.redact_use_project(project_name : String?, db_path : String?,
                                          name : String, none : Bool) : Nil
        store = open_store(resolve_read_project(project_name, db_path))
        # The refusal travels back rather than aborting in place: `abort` skips `ensure`, so a
        # typo'd profile name would leave the project handle open.
        ok, refusal = begin
          if !none && Redact::Policy.profile(store, name).nil?
            {false, Redact::Policy.unknown(store, name)}
          else
            scope = Redact::Policy.project_scope(store)
            {Redact::Policy.write_project_scope(store,
              Redact::Policy::ProjectScope.new(none ? "" : name, scope.default, scope.profiles)), nil}
          end
        ensure
          store.close
        end
        abort "gori run redact use: #{refusal}" if refusal
        abort "gori run redact use: the project is busy — the choice was not saved" unless ok
        puts none ? "cleared this project's redaction profile" : "this project's redaction profile: #{name}"
      end

      private def self.cmd_redact_default(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        global = false
        clear = false
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run redact default on|off [options]\n\n" \
                     "Whether shareable output is sanitized WITHOUT --redact. Off at the factory;\n" \
                     "once on, --no-redact is the explicit path back to the captured bytes.\n" \
                     "Writes the PROJECT by default; --global writes settings.json."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("--global", "Write settings.json instead of this project") { global = true }
          p.on("--none", "Clear this project's answer and inherit the global one") { clear = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run redact default", "`on` or `off`") }
          p.invalid_option { |f| abort "gori run redact default: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run redact default: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run redact default: --none is a project-scope answer, not a global one" if clear && global
        value = if clear
                  nil
                else
                  case positional.first?
                  when "on", "true", "yes"  then true
                  when "off", "false", "no" then false
                  when nil                  then abort "gori run redact default: say `on` or `off`\n#{parser}"
                  else                           abort "gori run redact default: expected `on` or `off`, got #{positional.first.inspect}"
                  end
                end

        if global
          Settings.redaction_default = !!value
          abort "gori run redact default: could not write #{Settings.path}" unless Settings.save
          puts "global: redaction #{value ? "applies by default" : "applies only with --redact"}"
        else
          redact_default_project(project_name, db_path, value)
        end
      end

      private def self.redact_default_project(project_name : String?, db_path : String?,
                                              value : Bool?) : Nil
        store = open_store(resolve_read_project(project_name, db_path))
        ok = begin
          scope = Redact::Policy.project_scope(store)
          Redact::Policy.write_project_scope(store,
            Redact::Policy::ProjectScope.new(scope.active, value, scope.profiles))
        ensure
          store.close
        end
        abort "gori run redact default: the project is busy — nothing was saved" unless ok
        if value.nil?
          puts "this project now inherits the global default"
        else
          puts "this project: redaction #{value ? "applies by default" : "applies only with --redact"}"
        end
      end

      private def self.cmd_redact_set(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        global = false
        description = ""
        fields = [] of String
        pointers = [] of String
        form_keys = [] of String
        patterns = [] of String
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run redact set <name> [--json-field F]… [options]\n\n" \
                     "Creates or REPLACES a profile. Every rule flag repeats. Writes the PROJECT\n" \
                     "by default (field names that describe one target belong to one engagement);\n" \
                     "--global writes settings.json."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("--global", "Write settings.json instead of this project") { global = true }
          p.on("--description=TEXT", "What this profile is for") { |v| description = v }
          p.on("--json-field=NAME", "A JSON member name, matched at any depth (repeatable)") { |v| fields << v }
          p.on("--json-pointer=PTR", "An RFC 6901 pointer; `-` means any array index (repeatable)") { |v| pointers << v }
          p.on("--form-key=KEY", "An x-www-form-urlencoded key (repeatable)") { |v| form_keys << v }
          p.on("--pattern=REGEX", "A regex over body text; group 1 is replaced if present (repeatable)") { |v| patterns << v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run redact set", "profile name") }
          p.invalid_option { |f| abort "gori run redact set: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run redact set: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run redact set: name the profile\n#{parser}" if positional.empty?
        name = positional.first
        profile = Redact::Profile.new(name: name, description: description, json_fields: fields,
          json_pointers: pointers, form_keys: form_keys, patterns: patterns)
        if profile.empty?
          abort "gori run redact set: a profile with no rules would sanitize nothing — " \
                "pass at least one of --json-field / --json-pointer / --form-key / --pattern"
        end
        # Compile now, so a regex that cannot compile is refused HERE rather than reported on
        # every export the profile is later used for.
        errs = Redact::Matcher.new(profile).pattern_errors
        abort "gori run redact set: #{errs.join("; ")}" unless errs.empty?

        if global
          Settings.redaction_profiles = Settings.redaction_profiles.reject(&.name.==(name)) << profile
          abort "gori run redact set: could not write #{Settings.path}" unless Settings.save
          puts "global profile #{name.inspect}: #{redact_rule_counts(profile)}"
          return
        end
        store = open_store(resolve_read_project(project_name, db_path))
        ok = begin
          scope = Redact::Policy.project_scope(store)
          Redact::Policy.write_project_scope(store, Redact::Policy::ProjectScope.new(
            scope.active, scope.default, scope.profiles.reject(&.name.==(name)) << profile))
        ensure
          store.close
        end
        abort "gori run redact set: the project is busy — nothing was saved" unless ok
        puts "project profile #{name.inspect}: #{redact_rule_counts(profile)}"
      end

      private def self.cmd_redact_rm(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        global = false
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run redact rm <name> [options]\n\n" \
                     "Deletes a profile from this project, or from settings.json with --global.\n" \
                     "A built-in profile cannot be deleted; define one of the same name to replace it."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("--global", "Write settings.json instead of this project") { global = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run redact rm", "profile name") }
          p.invalid_option { |f| abort "gori run redact rm: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run redact rm: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run redact rm: name the profile\n#{parser}" if positional.empty?
        name = positional.first

        if global
          kept = Settings.redaction_profiles.reject(&.name.==(name))
          abort "gori run redact rm: no global profile named #{name.inspect}" if kept.size == Settings.redaction_profiles.size
          Settings.redaction_profiles = kept
          abort "gori run redact rm: could not write #{Settings.path}" unless Settings.save
          puts "removed global profile #{name.inspect}"
          return
        end
        store = open_store(resolve_read_project(project_name, db_path))
        ok, missing = begin
          scope = Redact::Policy.project_scope(store)
          kept = scope.profiles.reject(&.name.==(name))
          if kept.size == scope.profiles.size
            {false, true}
          else
            {Redact::Policy.write_project_scope(store,
              Redact::Policy::ProjectScope.new(scope.active, scope.default, kept)), false}
          end
        ensure
          store.close
        end
        abort "gori run redact rm: no profile named #{name.inspect} in this project" if missing
        abort "gori run redact rm: the project is busy — nothing was saved" unless ok
        puts "removed project profile #{name.inspect}"
      end
    end
  end
end
