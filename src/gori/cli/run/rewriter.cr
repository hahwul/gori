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
        when "extract"      then cmd_rewriter_extract(args[1..])
        when "bindings"     then cmd_rewriter_bindings(args[1..])
        when nil            then cmd_rewriter_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_rewriter_list(args)
          else
            STDERR.puts "gori run rewriter: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run rewriter [list options] | add | rm|delete <id> | enable <id> | disable <id> | preview"
            STDERR.puts "       gori run rewriter extract [list|add|rm|enable|disable] | bindings"
            exit 1
          end
        end
      end

      # --- session bindings, the READ half (#501) ------------------------------
      #
      # `gori run rewriter extract ...` mirrors the Rewriter tab's `extract` sub-tab and the
      # MCP `*_extract_rule` tools, one CRUD for one table. It lives UNDER `rewriter` rather
      # than beside it because it is half of one workflow: an extract rule writes `$SESSION`
      # and a Match & Replace rule reads it, and splitting them into two top-level commands
      # would hide that.

      private def self.cmd_rewriter_extract(args : Array(String)) : Nil
        case sub = args.first?
        when "add"          then cmd_extract_add(args[1..])
        when "rm", "delete" then cmd_extract_rm(args[1..])
        when "enable"       then cmd_extract_set_enabled(true, args[1..])
        when "disable"      then cmd_extract_set_enabled(false, args[1..])
        when "list"         then cmd_extract_list(args[1..])
        when nil            then cmd_extract_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_extract_list(args)
          else
            STDERR.puts "gori run rewriter extract: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run rewriter extract [list] | add | rm|delete <id> | enable <id> | disable <id>"
            exit 1
          end
        end
      end

      # `#3 [x] $SESSION <- status:200 AND path:/login <- cookie "sid" @acme.test`
      private def self.extract_rule_row(r : Store::ExtractRule) : String
        mark = r.enabled? ? "x" : " "
        host = r.host.empty? ? "" : " @#{r.host}"
        cond = r.match_filter.empty? ? "any message" : r.match_filter
        "##{r.id} [#{mark}] $#{r.name} <- #{cond} <- #{r.token_loc.label}#{host}"
      end

      private def self.cmd_extract_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        leftover = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter extract [list] [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run rewriter extract: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter extract: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "rewriter extract", "add, rm/delete, enable, disable")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          rules = store.extract_rules
          if format == :json
            puts(JSON.build { |j| j.array { rules.each { |r| extract_rule_json(j, r) } } })
          elsif rules.empty?
            puts "No extract rules configured."
          else
            rules.each { |r| puts extract_rule_row(r) }
          end
        ensure
          store.close
        end
      end

      private def self.extract_rule_json(j : JSON::Builder, r : Store::ExtractRule) : Nil
        j.object do
          j.field "id", r.id
          j.field "enabled", r.enabled?
          j.field "name", r.name
          j.field "when", r.match_filter
          j.field "host", r.host
          j.field "kind", r.kind.label
          j.field "selector", r.selector
          j.field "pos_start", r.pos_start
          j.field "pos_end", r.pos_end
        end
      end

      private def self.cmd_extract_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        name = ""
        when_s = ""
        host = ""
        kind_s = "cookie"
        selector = ""
        range_s = ""
        disabled = false

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter extract add --name=SESSION --kind=cookie --selector=sid [options]\n\n" \
                     "The rule OBSERVES a response and binds one named value in memory; a Match &\n" \
                     "Replace rule then injects it with `--value='$SESSION'`. The value itself is\n" \
                     "never persisted — see `gori run rewriter bindings`."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--name=NAME", "Binding name, without the $ (required)") { |v| name = v }
          p.on("--when=FILTER", "Which messages to read, in intercept-filter syntax ('' = any)") { |v| when_s = v }
          p.on("--host=GLOB", "Scope to a host glob ('' = all; '*.example.com')") { |v| host = v }
          p.on("--kind=KIND", "cookie|header|regex|position|jsonpath (default cookie)") { |v| kind_s = v }
          p.on("--selector=SEL", "Cookie/header name, regex, or JSON path") { |v| selector = v }
          p.on("--range=A:B", "position only: a half-open byte range of the decoded body") { |v| range_s = v }
          p.on("--disabled", "Create the rule disabled") { disabled = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter extract add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter extract add: missing value for #{f}" }
        end
        parser.parse(args)

        kind = Gori::ExtractKind.parse?(kind_s) ||
               abort("gori run rewriter extract add: invalid --kind '#{kind_s}' (cookie|header|regex|position|jsonpath)")
        a, b = parse_extract_range(range_s)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          # Through `Bindings`, not `store.insert_extract_rule`, so the CLI gets the SAME
          # refusals the TUI and MCP do — one name one writer, a valid key, a regex that
          # compiles — rather than a UNIQUE-constraint failure that reads as "store busy".
          bindings = Bindings.new(store, store.extract_rules)
          if err = bindings.add(name, when_s, kind, selector, a, b, host)
            abort "gori run rewriter extract add: #{err}"
          end
          id = store.extract_rules.find { |r| r.name == name }.try(&.id) || 0_i64
          abort "gori run rewriter extract add: failed to persist rule (store busy or unwritable)" if id == 0
          # The disable's own answer, not a fire-and-forget: dropping it reported success
          # while leaving an ENABLED rule that immediately starts binding from live proxy
          # traffic — the opposite of what was asked, at exit 0. MCP's
          # `apply_created_extract_state` already refuses this way.
          if disabled && !store.set_extract_rule_enabled(id, false)
            abort "gori run rewriter extract add: rule ##{id} was created but the disable did not persist " \
                  "(store busy or unwritable) — it is ENABLED and already binding; retry the disable"
          end
          puts "Extract rule ##{id} added — $#{name} binds from #{kind.label}."
        ensure
          store.close
        end
      end

      private def self.parse_extract_range(raw : String) : {Int32, Int32}
        return {0, 0} if raw.empty?
        a, _, b = raw.partition(':')
        ai = a.to_i32?
        bi = b.to_i32?
        abort "gori run rewriter extract: invalid --range '#{raw}' (expected A:B)" if ai.nil? || bi.nil? || bi <= ai
        {ai, bi}
      end

      private def self.cmd_extract_rm(args : Array(String)) : Nil
        id, store = extract_target(args, "rm|delete")
        begin
          abort "gori run rewriter extract rm: no rule ##{id}" unless store.extract_rules.any?(&.id.==(id))
          abort "gori run rewriter extract rm: failed to delete (store busy or unwritable)" unless store.delete_extract_rule(id)
          puts "Extract rule ##{id} deleted."
        ensure
          store.close
        end
      end

      private def self.cmd_extract_set_enabled(enabled : Bool, args : Array(String)) : Nil
        verb = enabled ? "enable" : "disable"
        id, store = extract_target(args, verb)
        begin
          abort "gori run rewriter extract #{verb}: no rule ##{id}" unless store.extract_rules.any?(&.id.==(id))
          abort "gori run rewriter extract #{verb}: failed to persist (store busy or unwritable)" unless store.set_extract_rule_enabled(id, enabled)
          puts "Extract rule ##{id} #{enabled ? "enabled" : "disabled"}."
        ensure
          store.close
        end
      end

      # The shared `<id> [--project|--db]` parse for rm/enable/disable.
      private def self.extract_target(args : Array(String), verb : String) : {Int64, Store}
        db_path : String? = nil
        project_name : String? = nil
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter extract #{verb} <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter extract #{verb}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter extract #{verb}: missing value for #{f}" }
        end
        rest = [] of String
        parser.unknown_args { |before, after| rest = before + after }
        parser.parse(args)
        id = rest.first?.try(&.to_i64?) || abort("gori run rewriter extract #{verb}: expected a rule id")
        {id, open_store(resolve_read_project(project_name, db_path))}
      end

      # The `bindings` readout. A binding VALUE lives only in the memory of the gori instance
      # that observed it — nothing writes one to `settings.json`, the project DB, the event
      # feed, an issue, a note or a log line. So from another process this can honestly report
      # only which names are DECLARED and by what, and it says so rather than printing an
      # empty "value" column that would read like "not bound".
      private def self.cmd_rewriter_bindings(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter bindings [options]\n\n" \
                     "Lists the names extract rules declare. Values are held in memory by the\n" \
                     "running gori and are never written anywhere, so another process cannot\n" \
                     "read them — open the Rewriter tab's `bindings` sub-tab for the live table."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter bindings: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter bindings: missing value for #{f}" }
        end
        parser.parse(args)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          rules = store.extract_rules
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "values_readable", false
                j.field "note", "binding values live in the running gori's memory and are never persisted"
                j.field "bindings" { j.array { rules.each { |r| extract_rule_json(j, r) } } }
              end
            end)
          elsif rules.empty?
            puts "No bindings declared — add an extract rule with `gori run rewriter extract add`."
          else
            rules.each do |r|
              puts "$#{r.name}#{r.enabled? ? "" : " (rule disabled)"} <- #{r.token_loc.label}#{r.host.empty? ? "" : " @#{r.host}"}"
            end
            puts
            puts "Values are held in memory by the running gori and are never persisted."
          end
        ensure
          store.close
        end
      end

      # One text row for a rule: `G#3 [x] REQ sub/H @host  pattern -> value`. The scope letter
      # leads because it is half of the rule's identity — the two stores number independently,
      # so `#3` on its own does not say which rule the next command would address.
      # `*` after it = this project overrides the global default (see Store#rewriter_overrides).
      private def self.rewriter_rule_row(r : Store::MatchRule) : String
        mark = r.enabled? ? "x" : " "
        side = r.target.request? ? "REQ" : "RES"
        name = r.name.empty? ? "" : " [#{r.name}]"
        host = r.host.empty? ? "" : " @#{r.host}"
        scope = "#{r.scope.badge}#{r.overridden? ? "*" : ""}"
        "#{scope}##{r.id} [#{mark}] #{side} #{rewriter_op_tag(r).ljust(5)}#{name}#{host}  #{rewriter_rule_body(r)}"
      end

      # `--scope` on every rule subcommand: WHICH store the id names (or, on list, which half
      # to print). Same vocabulary as the MCP tools and the TUI's `scope:` row.
      private def self.parse_rule_scope(s : String) : Store::RuleScope
        case s.downcase
        when "project" then Store::RuleScope::Project
        when "global"  then Store::RuleScope::Global
        else                abort "gori run rewriter: invalid --scope '#{s}' (project|global)"
        end
      end

      private def self.rewriter_op_tag(r : Store::MatchRule) : String
        case r.op
        when .replace?       then "#{r.match_kind.regex? ? "re" : "sub"}/#{r.part.badge}"
        when .add_header?    then "+hdr"
        when .set_header?    then "~hdr"
        when .short_circuit? then "stub"
        else                      "-hdr"
        end
      end

      # `=>` rather than `->` for a stub: it answers instead of forwarding, so the row should
      # not read like the four rewrite ops.
      private def self.rewriter_rule_body(r : Store::MatchRule) : String
        case r.op
        when .remove_header? then r.pattern
        when .short_circuit? then "#{r.pattern} => #{RuleStub.summary(r.replacement, r.body_file)}"
        else                      "#{r.pattern} -> #{r.replacement}"
        end
      end

      private def self.cmd_rewriter_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        scope : Store::RuleScope? = nil
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter [options]\n\n" \
                     "Lists the rules that apply to this project: the global library first,\n" \
                     "then the project's own — the order the proxy applies them in.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run rewriter add --op=replace --target=request --find=OLD --value=NEW\n" \
                     "  gori run rewriter add --op=add_header --find=X-Trace --value=on --scope=global\n" \
                     "  gori run rewriter rm|delete <id> | enable <id> | disable <id> | preview ..."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--scope=SCOPE", "Show only project|global rules (default: both)") { |v| scope = parse_rule_scope(v) }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run rewriter: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "rewriter", "add, rm/delete, enable, disable, preview, extract, bindings")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          rules = Gori::Rules.merged(store)
          rules = rules.select { |r| r.scope == scope } if scope
          if format == :json
            puts(JSON.build do |j|
              j.array do
                rules.each { |r| rewriter_rule_json(j, r) }
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

      # `enabled` is the EFFECTIVE state in this project; `default_enabled` and `overridden`
      # only appear for a global rule, where the two can differ. A project rule has one state
      # and printing two fields for it would invite the reader to look for a difference.
      private def self.rewriter_rule_json(j : JSON::Builder, r : Store::MatchRule) : Nil
        j.object do
          j.field "id", r.id
          j.field "scope", r.scope.label
          j.field "enabled", r.enabled?
          if r.global?
            j.field "overridden", r.overridden?
            j.field "default_enabled", Settings.rewriter_rules.find { |g| g.id == r.id }.try(&.enabled)
          end
          j.field "name", r.name
          j.field "target", r.target.label
          j.field "part", r.part.label
          j.field "op", r.op.label
          j.field "match", r.match_kind.label
          j.field "host", r.host
          j.field "pattern", r.pattern
          j.field "replacement", r.replacement
          j.field "body_file", r.body_file
        end
      end

      # Parse the shared rule-shape flags into store enums, aborting on a bad value.
      private def self.parse_rewriter_op(s : String) : Store::RuleOp
        case s.downcase
        when "replace"       then Store::RuleOp::Replace
        when "add_header"    then Store::RuleOp::AddHeader
        when "set_header"    then Store::RuleOp::SetHeader
        when "remove_header" then Store::RuleOp::RemoveHeader
        when "short_circuit" then Store::RuleOp::ShortCircuit
        else                      abort "gori run rewriter: invalid --op '#{s}' (replace|add_header|set_header|remove_header|short_circuit)"
        end
      end

      # `--value` for a short-circuit rule is the whole canned response, which is multi-line
      # and awkward to pass on a command line. `--response-file` reads it from a file instead
      # (`-` reads stdin), so `gori run rewriter add --op=short_circuit --find=/admin
      # --response-file=stub.http` is the natural spelling. Distinct from `--body-file`, which
      # points at the BODY the live proxy reads per request; this one is read ONCE, now.
      private def self.read_stub_response(path : String) : String
        path == "-" ? STDIN.gets_to_end : File.read(path)
      rescue ex : File::Error
        abort "gori run rewriter: cannot read --response-file '#{path}': #{ex.message}"
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
        body_file = ""
        response_file : String? = nil
        scope = Store::RuleScope::Project

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter add [options]\n\n" \
                     "For replace: --find is the substring/regex, --value the replacement.\n" \
                     "For a header op: --find is the header NAME, --value the value.\n" \
                     "For short_circuit: --find matches the request head and --value (or\n" \
                     "--response-file) is the canned response gori answers with — nothing is\n" \
                     "sent upstream. --body-file replaces the response BODY, read per request."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--target=SIDE", "request|response (default request)") { |v| target_s = v }
          p.on("--op=OP", "replace|add_header|set_header|remove_header|short_circuit (default replace)") { |v| op_s = v }
          p.on("--match=KIND", "literal|regex (default literal; replace/short_circuit only)") { |v| match_s = v }
          p.on("--part=PART", "head|body|ws (default head; replace only; ws = a WebSocket message)") { |v| part_s = v }
          p.on("--host=GLOB", "Scope to a host glob ('' = all; '*.example.com')") { |v| host = v }
          p.on("--scope=SCOPE", "project (default) | global — a global rule applies in EVERY project") { |v| scope = parse_rule_scope(v) }
          p.on("--name=NAME", "Optional rule label") { |v| name = v }
          p.on("-fFIND", "--find=FIND", "Match substring/regex, or header name (required)") { |v| find = v }
          p.on("-vVALUE", "--value=VALUE", "Replacement, header value, or canned response (default empty)") { |v| value = v }
          p.on("--response-file=PATH", "short_circuit: read the canned response from PATH ('-' = stdin)") { |v| response_file = v }
          p.on("--body-file=PATH", "short_circuit: serve PATH as the response BODY (re-read when it changes)") { |v| body_file = v }
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
        if match.regex? && !op.header? && !valid_regex?(f)
          abort "gori run rewriter add: invalid regex --find (failed to compile)"
        end
        value = check_short_circuit_args(op, value, response_file, body_file)
        check_ws_part(op, part, "add")
        target, part = Gori::Rules.normalize_shape(op, target, part)

        # A global rule needs no project at all — it lives in settings.json — but resolving one
        # anyway keeps `--project` meaningful on every subcommand and costs a store open that
        # the surrounding surface already pays for.
        if scope.global?
          id = Settings.add_rewriter_rule(target.label, part.label, f, value, op.label,
            match.label, name, host, body_file, !disabled)
          abort "gori run rewriter add: failed to persist rule (settings not writable)" if id == 0
          puts "Global rule ##{id} added — it applies in every project."
          return
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          id = store.insert_rule(target, part, f, value, op, match, name, host, !disabled, body_file: body_file)
          abort "gori run rewriter add: failed to persist rule (store busy or unwritable)" if id == 0
          puts "Rule ##{id} added."
        ensure
          store.close
        end
      end

      # Validate the short-circuit-only flags and resolve --response-file into the stub text.
      # A stub that cannot be parsed would answer every matching request with gori's own 502
      # and never reach the origin, so it is refused here rather than discovered from live
      # traffic; --body-file on any other op is refused too, since storing an ignored path
      # would leave the operator believing a body source is configured.
      private def self.check_short_circuit_args(op : Store::RuleOp, value : String,
                                                response_file : String?, body_file : String) : String
        unless op.short_circuit?
          abort "gori run rewriter add: --response-file is only meaningful with --op=short_circuit" if response_file
          abort "gori run rewriter add: --body-file is only meaningful with --op=short_circuit" unless body_file.empty?
          return value
        end
        value = read_stub_response(response_file) if response_file
        unless RuleStub.valid?(value)
          abort "gori run rewriter add: the canned response is not parseable " \
                "(expected a status line such as '200 OK', then headers, then a blank line and the body)"
        end
        value
      end

      # Only `replace` acts on a WebSocket message: a header op names a header and a WS
      # message has none, and a short-circuit rule answers a request that a WS message is
      # not. Refused rather than normalized — `Rules.normalize_shape` would coerce the part
      # to `head`, which does not narrow the rule but moves it to a different PROTOCOL: the
      # operator asked to rewrite WebSocket frames and would have got a rule rewriting HTTP
      # request heads, with nothing on screen to say so.
      private def self.check_ws_part(op : Store::RuleOp, part : Store::RulePart, verb : String) : Nil
        return unless part.ws? && !op.replace?
        abort "gori run rewriter #{verb}: --op=#{op.label} cannot use --part=ws — only replace " \
              "rewrites a WebSocket message; use --part=head for an HTTP header or short-circuit rule"
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
        scope = Store::RuleScope::Project
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter rm|delete <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--scope=SCOPE", "Which <id>: project (default) | global") { |v| scope = parse_rule_scope(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter rm: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter rm: missing value for #{f}" }
        end
        positional = [] of String
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)
        abort "gori run rewriter rm: missing <id>" if positional.empty?
        abort "gori run rewriter rm: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run rewriter rm: invalid rule id '#{positional[0]}'")

        # A project that had overridden this rule keeps a row pointing at the id, and this
        # surface cannot reach every project's DB to sweep it. It stays inert: global ids come
        # from a monotonic counter and are never reused, so nothing can inherit the override.
        if scope.global?
          abort "gori run rewriter rm: no global rule with id #{id}" unless Settings.rewriter_rules.any? { |r| r.id == id }
          abort "gori run rewriter rm: settings not writable (nothing was deleted)" unless Settings.delete_rewriter_rule(id)
          puts "Global rule ##{id} deleted — from every project."
          return
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          unless store.match_rules.any? { |r| r.id == id }
            store.close
            abort "gori run rewriter rm: no rule with id #{id}"
          end
          unless store.delete_rule(id)
            store.close
            abort "gori run rewriter rm: project is busy (write did not commit) — try again"
          end
          puts "Rule ##{id} deleted."
        ensure
          store.close
        end
      end

      private def self.cmd_rewriter_set_enabled(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        scope = Store::RuleScope::Project
        everywhere = false
        action = enable ? "enable" : "disable"
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter #{action} <id> [options]\n\n" \
                     "With --scope=global this writes THIS project's override of the rule,\n" \
                     "the way `x` does in the Rewriter tab. --everywhere changes the rule's\n" \
                     "own default instead, which every project without an override follows."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--scope=SCOPE", "Which <id>: project (default) | global") { |v| scope = parse_rule_scope(v) }
          p.on("--everywhere", "global rules only: change the default for every project") { everywhere = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter #{action}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter #{action}: missing value for #{f}" }
        end
        positional = [] of String
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)
        abort "gori run rewriter #{action}: missing <id>" if positional.empty?
        abort "gori run rewriter #{action}: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run rewriter #{action}: invalid rule id '#{positional[0]}'")
        if everywhere && !scope.global?
          abort "gori run rewriter #{action}: --everywhere needs --scope=global — a project rule has no default"
        end

        # The rule's own default, read once: `everywhere` writes it, and the per-project branch
        # below compares against it to decide between an override and dropping one.
        default = nil.as(Bool?)
        if scope.global?
          rule = Settings.rewriter_rules.find { |r| r.id == id }
          abort "gori run rewriter #{action}: no global rule with id #{id}" unless rule
          default = rule.enabled
          if everywhere
            abort "gori run rewriter #{action}: settings not writable (the rule is unchanged)" unless Settings.set_rewriter_rule_enabled(id, enable)
            puts "Global rule ##{id} #{enable ? "enabled" : "disabled"} by default (every project without an override)."
            return
          end
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          if scope.global?
            # Same disposition `Rules#toggle` writes: agreeing with the default DROPS the
            # override rather than pinning it, so this project keeps following the library.
            ok = default == enable ? store.clear_rewriter_override(id) : store.set_rewriter_override(id, enable)
            unless ok
              store.close
              abort "gori run rewriter #{action}: project is busy (write did not commit) — try again"
            end
            puts "Global rule ##{id} #{enable ? "enabled" : "disabled"} in project #{project.name}."
            return
          end
          unless store.match_rules.any? { |r| r.id == id }
            store.close
            abort "gori run rewriter #{action}: no rule with id #{id}"
          end
          unless store.set_rule_enabled(id, enable)
            store.close
            abort "gori run rewriter #{action}: project is busy (write did not commit) — try again"
          end
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
          p.on("--op=OP", "replace|add_header|set_header|remove_header|short_circuit (default replace)") { |v| op_s = v }
          p.on("--match=KIND", "literal|regex (default literal)") { |v| match_s = v }
          p.on("--part=PART", "head|body|ws (default head)") { |v| part_s = v }
          p.on("--host=GLOB", "Scope to a host glob") { |v| host = v }
          p.on("-fFIND", "--find=FIND", "Match substring/regex, or header name (required)") { |v| find = v }
          p.on("-vVALUE", "--value=VALUE", "Replacement, or header value") { |v| value = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter preview: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter preview: missing value for #{f}" }
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
        if match.regex? && !op.header? && !valid_regex?(f)
          abort "gori run rewriter preview: invalid regex --find (failed to compile)"
        end
        check_ws_part(op, part, "preview")
        target, part = Gori::Rules.normalize_shape(op, target, part)

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
