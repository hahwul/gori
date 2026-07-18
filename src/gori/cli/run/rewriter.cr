# `gori run rewriter` — manage Match & Replace rules (list, add, rm, enable/disable, preview).
module Gori
  module CLI
    module Run
      private def self.cmd_rewriter(args : Array(String)) : Nil
        case sub = args.first?
        when "add"          then cmd_rewriter_add(args[1..])
        when "rm", "delete" then cmd_rewriter_rm(args[1..])
        when "enable"       then cmd_rewriter_set_enabled(true, args[1..])
        when "disable"      then cmd_rewriter_set_enabled(false, args[1..])
        when "preview"      then cmd_rewriter_preview(args[1..])
        when "list"         then cmd_rewriter_list(args[1..])
        when nil            then cmd_rewriter_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_rewriter_list(args)
          else
            STDERR.puts "gori run rewriter: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run rewriter [list options] | add | rm|delete <id> | enable <id> | disable <id> | preview"
            exit 1
          end
        end
      end

      # One text row for a rule: `#3 [x] REQ sub/H @host  pattern -> value`.
      private def self.rewriter_rule_row(r : Store::MatchRule) : String
        mark = r.enabled? ? "x" : " "
        side = r.target.request? ? "REQ" : "RES"
        tag = case r.op
              when .replace?    then "#{r.match_kind.regex? ? "re" : "sub"}/#{r.part.body? ? 'B' : 'H'}"
              when .add_header? then "+hdr"
              when .set_header? then "~hdr"
              else                   "-hdr"
              end
        body = r.op.remove_header? ? r.pattern : "#{r.pattern} -> #{r.replacement}"
        name = r.name.empty? ? "" : " [#{r.name}]"
        host = r.host.empty? ? "" : " @#{r.host}"
        "##{r.id} [#{mark}] #{side} #{tag.ljust(5)}#{name}#{host}  #{body}"
      end

      private def self.cmd_rewriter_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter [options]\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run rewriter add --op=replace --target=request --find=OLD --value=NEW\n" \
                     "  gori run rewriter add --op=add_header --find=X-Trace --value=on\n" \
                     "  gori run rewriter rm|delete <id> | enable <id> | disable <id> | preview ..."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          rules = store.match_rules
          if format == :json
            puts(JSON.build do |j|
              j.array do
                rules.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "enabled", r.enabled?
                    j.field "name", r.name
                    j.field "target", r.target.label
                    j.field "part", r.part.label
                    j.field "op", r.op.label
                    j.field "match", r.match_kind.label
                    j.field "host", r.host
                    j.field "pattern", r.pattern
                    j.field "replacement", r.replacement
                  end
                end
              end
            end)
          elsif rules.empty?
            puts "No Match & Replace rules configured."
          else
            rules.each { |r| puts rewriter_rule_row(r) }
          end
        ensure
          store.close
        end
      end

      # Parse the shared rule-shape flags into store enums, aborting on a bad value.
      private def self.parse_rewriter_op(s : String) : Store::RuleOp
        case s.downcase
        when "replace"       then Store::RuleOp::Replace
        when "add_header"    then Store::RuleOp::AddHeader
        when "set_header"    then Store::RuleOp::SetHeader
        when "remove_header" then Store::RuleOp::RemoveHeader
        else                      abort "gori run rewriter: invalid --op '#{s}' (replace|add_header|set_header|remove_header)"
        end
      end

      private def self.cmd_rewriter_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target_s = "request"
        part_s = "head"
        op_s = "replace"
        match_s = "literal"
        host = ""
        name = ""
        find : String? = nil
        value = ""
        disabled = false

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter add [options]\n\n" \
                     "For replace: --find is the substring/regex, --value the replacement.\n" \
                     "For a header op: --find is the header NAME, --value the value."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--target=SIDE", "request|response (default request)") { |v| target_s = v }
          p.on("--op=OP", "replace|add_header|set_header|remove_header (default replace)") { |v| op_s = v }
          p.on("--match=KIND", "literal|regex (default literal; replace only)") { |v| match_s = v }
          p.on("--part=PART", "head|body (default head; replace only)") { |v| part_s = v }
          p.on("--host=GLOB", "Scope to a host glob ('' = all; '*.example.com')") { |v| host = v }
          p.on("--name=NAME", "Optional rule label") { |v| name = v }
          p.on("-fFIND", "--find=FIND", "Match substring/regex, or header name (required)") { |v| find = v }
          p.on("-vVALUE", "--value=VALUE", "Replacement, or header value (default empty)") { |v| value = v }
          p.on("--disabled", "Create the rule disabled") { disabled = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter add: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run rewriter add: --find is required" if (f = find).nil? || f.empty?
        op = parse_rewriter_op(op_s)
        target = Store::RuleTarget.parse?(target_s) || abort("gori run rewriter add: invalid --target '#{target_s}'")
        part = Store::RulePart.parse?(part_s) || abort("gori run rewriter add: invalid --part '#{part_s}'")
        match = Store::MatchKind.parse?(match_s) || abort("gori run rewriter add: invalid --match '#{match_s}' (literal|regex)")
        if op.replace? && match.regex? && !valid_regex?(f)
          abort "gori run rewriter add: invalid regex --find (failed to compile)"
        end
        part = Store::RulePart::Head if op.header?

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          id = store.insert_rule(target, part, f, value, op, match, name, host, !disabled)
          abort "gori run rewriter add: failed to persist rule (store busy or unwritable)" if id == 0
          puts "Rule ##{id} added."
        ensure
          store.close
        end
      end

      private def self.valid_regex?(pattern : String) : Bool
        SafeRegexp.compile(pattern)
        true
      rescue
        false
      end

      private def self.cmd_rewriter_rm(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter rm|delete <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter rm: unknown option: #{f}\n#{p}" }
        end
        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)
        abort "gori run rewriter rm: missing <id>" if positional.empty?
        abort "gori run rewriter rm: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run rewriter rm: invalid rule id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          unless store.match_rules.any? { |r| r.id == id }
            store.close
            abort "gori run rewriter rm: no rule with id #{id}"
          end
          store.delete_rule(id)
          puts "Rule ##{id} deleted."
        ensure
          store.close
        end
      end

      private def self.cmd_rewriter_set_enabled(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        action = enable ? "enable" : "disable"
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter #{action} <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter #{action}: unknown option: #{f}\n#{p}" }
        end
        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)
        abort "gori run rewriter #{action}: missing <id>" if positional.empty?
        abort "gori run rewriter #{action}: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run rewriter #{action}: invalid rule id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          unless store.match_rules.any? { |r| r.id == id }
            store.close
            abort "gori run rewriter #{action}: no rule with id #{id}"
          end
          store.set_rule_enabled(id, enable)
          puts "Rule ##{id} #{enable ? "enabled" : "disabled"}."
        ensure
          store.close
        end
      end

      private def self.cmd_rewriter_preview(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target_s = "request"
        part_s = "head"
        op_s = "replace"
        match_s = "literal"
        host = ""
        find : String? = nil
        value = ""
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter preview [options]\n\n" \
                     "Estimate how many recent flows a rule WOULD affect, without creating it."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=SIDE", "request|response (default request)") { |v| target_s = v }
          p.on("--op=OP", "replace|add_header|set_header|remove_header (default replace)") { |v| op_s = v }
          p.on("--match=KIND", "literal|regex (default literal)") { |v| match_s = v }
          p.on("--part=PART", "head|body (default head)") { |v| part_s = v }
          p.on("--host=GLOB", "Scope to a host glob") { |v| host = v }
          p.on("-fFIND", "--find=FIND", "Match substring/regex, or header name (required)") { |v| find = v }
          p.on("-vVALUE", "--value=VALUE", "Replacement, or header value") { |v| value = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter preview: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)

        abort "gori run rewriter preview: --find is required" if (f = find).nil? || f.empty?
        op = parse_rewriter_op(op_s)
        target = Store::RuleTarget.parse?(target_s) || abort("gori run rewriter preview: invalid --target '#{target_s}'")
        part = Store::RulePart.parse?(part_s) || abort("gori run rewriter preview: invalid --part '#{part_s}'")
        match = Store::MatchKind.parse?(match_s) || abort("gori run rewriter preview: invalid --match '#{match_s}' (literal|regex)")
        # Validate the regex up front (like `add` does) — otherwise a bad pattern is
        # swallowed and reported as "0 flows", indistinguishable from a valid rule
        # that simply matched nothing.
        if op.replace? && match.regex? && !valid_regex?(f)
          abort "gori run rewriter preview: invalid regex --find (failed to compile)"
        end
        part = Store::RulePart::Head if op.header?

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          candidate = Store::MatchRule.new(0_i64, true, target, part, f, value, op, match, "", host)
          pv = Gori::Rules.new(store, [] of Store::MatchRule).preview(candidate)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "would_match", pv.matched
                j.field "scanned", pv.scanned
                j.field "total_flows", pv.total
                j.field "scan_capped", pv.total > pv.scanned
              end
            end)
          else
            capped = pv.total > pv.scanned ? " (of #{pv.total} total; scan capped)" : ""
            puts "Would affect #{pv.matched} of #{pv.scanned} recent flows#{capped}."
          end
        ensure
          store.close
        end
      end
    end
  end
end
