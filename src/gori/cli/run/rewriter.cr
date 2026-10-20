# `gori run rewriter` — manage Match & Replace rules (list, add, rm, enable/disable, preview).
module Gori
  module CLI
    module Run
      @[Subcommand("rewriter", help: [
        {"rewriter", "Manage Match & Replace rules (list, add, rm, enable/disable, preview, extract, bindings)"},
        {"rewriter preset", "Built-in rule presets: list them, or add one by name"},
      ])]
      private def self.cmd_rewriter(args : Array(String)) : Nil
        case sub = args.first?
        when "add"          then cmd_rewriter_add(args[1..])
        when "rm", "delete" then cmd_rewriter_rm(args[1..])
        when "enable"       then cmd_rewriter_set_enabled(true, args[1..])
        when "disable"      then cmd_rewriter_set_enabled(false, args[1..])
        when "preview"      then cmd_rewriter_preview(args[1..])
        when "preset"       then cmd_rewriter_preset(args[1..])
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
            STDERR.puts "       gori run rewriter preset [list | add <name>]"
            STDERR.puts "       gori run rewriter extract [list|add|rm|enable|disable] | bindings"
            exit 1
          end
        end
      end

      # --- response-modification presets (#821) --------------------------------
      #
      # `gori run rewriter preset list` / `preset add <name>` mirror the Rewriter tab's
      # preset picker and the MCP `create_rule_from_preset` tool over the ONE catalog
      # (`Gori::RulePresets`), so a preset means the identical rule set on every surface. A
      # preset installs ordinary editable rules — nothing the CLI writes here is different
      # from a hand-authored `rewriter add`, which is the point (P1/P4).

      private def self.cmd_rewriter_preset(args : Array(String)) : Nil
        case sub = args.first?
        when "list", nil then cmd_rewriter_preset_list(args[1..]? || [] of String)
        when "add"       then cmd_rewriter_preset_add(args[1..])
        else
          if (s = sub) && s.starts_with?('-')
            cmd_rewriter_preset_list(args)
          else
            STDERR.puts "gori run rewriter preset: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run rewriter preset [list] | add <name>"
            exit 1
          end
        end
      end

      private def self.cmd_rewriter_preset_list(args : Array(String)) : Nil
        format = :text
        parse_no_positionals(args, "gori run rewriter preset list",
          "`preset list` takes no positional arguments; to install one use " \
          "`gori run rewriter preset add <name>`") do |p|
          p.banner = "Usage: gori run rewriter preset list\n\n" \
                     "Lists the response-modification presets. Install one with\n" \
                     "  gori run rewriter preset add <name>"
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        presets = Gori::RulePresets.all
        if format == :json
          puts(JSON.build do |j|
            j.array do
              presets.each do |ps|
                j.object do
                  j.field "key", ps.key
                  j.field "name", ps.name
                  j.field "description", ps.description
                  j.field "rules", ps.rules.size
                end
              end
            end
          end)
        else
          presets.each do |ps|
            puts "#{ps.key}  (#{ps.summary})"
            puts "  #{ps.name} — #{ps.description}"
          end
        end
      end

      private def self.cmd_rewriter_preset_add(args : Array(String)) : Nil
        proj = ProjectFlags.new
        disabled = false
        scope = Store::RuleScope::Project
        format = :text

        leftover = one_positional_list(args, "gori run rewriter preset add", "<preset-name>") do |p|
          p.banner = "Usage: gori run rewriter preset add <name> [options]\n\n" \
                     "Installs a preset's rules as ordinary Match & Replace rules — visible,\n" \
                     "editable and disable-able like any other. Run `preset list` for names."
          project_options(p, proj, "update")
          p.on("--scope=SCOPE", "project (default) | global — a global rule applies in EVERY project") { |v| scope = parse_rule_scope(v) }
          p.on("--disabled", "Install the rules disabled, to review before they touch traffic") { disabled = true }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        name = leftover.first?
        abort "gori run rewriter preset add: a preset name is required (see `preset list`)" if name.nil? || name.empty?
        preset = Gori::RulePresets.find(name) ||
                 abort("gori run rewriter preset add: unknown preset '#{name}' (available: #{Gori::RulePresets.keys.join(", ")})")

        # A global rule needs no project — it lives in settings.json — but one is resolved for
        # BOTH scopes, because `Gori::Rules` is where the write and its audit line live and it
        # is built over a store. See `cmd_rewriter_add` for the whole argument.
        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          ids = Gori::Rules.load(store).add_preset(preset, scope: scope, enabled: !disabled)
          if ids.empty?
            abort "gori run rewriter preset add: failed to persist rules " \
                  "(#{scope.global? ? "settings not writable" : "store busy or unwritable"})"
          end
          if format == :json
            puts MCP::Serialize.preset_install(preset, scope, !disabled, ids)
            next
          end
          committed = ids.size
          suffix = committed == 1 ? "" : "s"
          state = disabled ? " (disabled)" : ""
          if scope.global?
            puts "Installed preset \"#{preset.name}\": #{committed} global rule#{suffix}#{state} — they apply in every project."
          else
            puts "Installed preset \"#{preset.name}\": #{committed} rule#{suffix}#{state} added."
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
      # Filter, selector and host are rule text an agent or a peer instance may have written (#1677).
      private def self.extract_rule_row(r : Store::ExtractRule) : String
        mark = r.enabled? ? "x" : " "
        host = r.host.empty? ? "" : " @#{CLI::Output.term_safe(r.host)}"
        cond = r.match_filter.empty? ? "any message" : CLI::Output.term_safe(r.match_filter)
        "##{r.id} [#{mark}] #{Env.spell(r.name, Env::Namespace::Bind)} <- #{cond} <- #{CLI::Output.term_safe(r.token_loc.label)}#{host}"
      end

      private def self.cmd_extract_list(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text
        leftover = parse_args(args, "gori run rewriter extract") do |p|
          p.banner = "Usage: gori run rewriter extract [list] [options]"
          project_options(p, proj, "read")
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        refuse_list_leftovers(leftover, "rewriter extract", "add, rm/delete, enable, disable")

        with_store(resolve_read_project(proj.name, proj.db), read_only: true) do |store|
          rules = store.extract_rules
          if format == :json
            puts(JSON.build { |j| j.array { rules.each { |r| MCP::Serialize.extract_rule(j, r) } } })
          elsif rules.empty?
            puts "No extract rules configured."
          else
            rules.each { |r| puts extract_rule_row(r) }
          end
        end
      end

      private def self.cmd_extract_add(args : Array(String)) : Nil
        proj = ProjectFlags.new
        name = ""
        when_s = ""
        host = ""
        kind_s = "cookie"
        selector = ""
        range_s = ""
        disabled = false
        format = :text

        parse_no_positionals(args, "gori run rewriter extract add",
          "pass the binding as --name NAME and --selector SEL") do |p|
          p.banner = "Usage: gori run rewriter extract add --name=SESSION --kind=cookie --selector=sid [options]\n\n" \
                     "The rule OBSERVES a response and binds one named value in memory; a Match &\n" \
                     "Replace rule then injects it with `--value='$BIND.SESSION'`\n" \
                     "(`--value='$SESSION'` under the legacy bare syntax). The value itself is\n" \
                     "never persisted — see `gori run rewriter bindings`."
          project_options(p, proj, "update")
          p.on("--name=NAME", "Binding name, without the sigil or namespace (required)") { |v| name = v }
          p.on("--when=FILTER", "Which messages to read, in intercept-filter syntax ('' = any)") { |v| when_s = v }
          p.on("--host=GLOB", "Scope to a host glob ('' = all; '*.example.com')") { |v| host = v }
          p.on("--kind=KIND", "cookie|header|regex|position|jsonpath (default cookie)") { |v| kind_s = v }
          p.on("--selector=SEL", "Cookie/header name, regex, or JSON path") { |v| selector = v }
          p.on("--range=A:B", "position only: a half-open byte range of the decoded body") { |v| range_s = v }
          p.on("--disabled", "Create the rule disabled") { disabled = true }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        kind = Gori::ExtractKind.parse?(kind_s) ||
               abort("gori run rewriter extract add: invalid --kind '#{kind_s}' (cookie|header|regex|position|jsonpath)")
        a, b = parse_extract_range(range_s)

        with_store(resolve_read_project(proj.name, proj.db)) do |store|
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
          puts extract_added_output(store, id, name, kind, format)
        end
      end

      # What `extract add` prints once the insert (and any `--disabled`) committed.
      # `--format json` (#1117) is the rule's `rewriter extract list --format json` object,
      # through the same `MCP::Serialize.extract_rule`, read back AFTER the disable so `enabled` is the
      # state that landed. A rule a peer removed in that instant has no row, and the command
      # refuses rather than print one the listing never shows.
      private def self.extract_added_output(store : Store, id : Int64, name : String,
                                            kind : Gori::ExtractKind, format : Symbol) : String
        unless format == :json
          return "Extract rule ##{id} added — #{Env.spell(name, Env::Namespace::Bind)} binds from #{kind.label}."
        end
        rule = store.extract_rules.find(&.id.==(id)) ||
               abort_closing(store, "gori run rewriter extract add: rule ##{id} was created, but it was gone before it could be read back")
        JSON.build { |j| MCP::Serialize.extract_rule(j, rule) }
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
        proj = ProjectFlags.new
        rest = one_positional_list(args, "gori run rewriter extract #{verb}", "<id>") do |p|
          p.banner = "Usage: gori run rewriter extract #{verb} <id> [options]"
          project_options(p, proj, "update")
        end
        id = rest.first?.try(&.to_i64?) || abort("gori run rewriter extract #{verb}: expected a rule id")
        {id, open_store(resolve_read_project(proj.name, proj.db))}
      end

      # The `bindings` readout. A binding VALUE lives only in the memory of the gori instance
      # that observed it — nothing writes one to `settings.json`, the project DB, the event
      # feed, an issue, a note or a log line. So from another process this can honestly report
      # only which names are DECLARED and by what, and it says so rather than printing an
      # empty "value" column that would read like "not bound".
      private def self.cmd_rewriter_bindings(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text
        parse_no_positionals(args, "gori run rewriter bindings",
          "`rewriter bindings` takes no positional arguments; the project is named with --project") do |p|
          p.banner = "Usage: gori run rewriter bindings [options]\n\n" \
                     "Lists the names extract rules declare. Values are held in memory by the\n" \
                     "running gori and are never written anywhere, so another process cannot\n" \
                     "read them — open the Rewriter tab's `bindings` sub-tab for the live table."
          project_options(p, proj, "read")
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        with_store(resolve_read_project(proj.name, proj.db), read_only: true) do |store|
          rules = store.extract_rules
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "values_readable", false
                j.field "note", "binding values live in the running gori's memory and are never persisted"
                j.field "bindings" { j.array { rules.each { |r| MCP::Serialize.extract_rule(j, r) } } }
              end
            end)
          elsif rules.empty?
            puts "No bindings declared — add an extract rule with `gori run rewriter extract add`."
          else
            rules.each { |r| puts binding_row(r) }
            puts
            puts "Values are held in memory by the running gori and are never persisted."
          end
        end
      end

      # `$BIND.SESSION <- cookie "sid" @acme.test`, with the same rule text badged as in
      # `extract_rule_row` (#1677).
      private def self.binding_row(r : Store::ExtractRule) : String
        host = r.host.empty? ? "" : " @#{CLI::Output.term_safe(r.host)}"
        "#{Env.spell(r.name, Env::Namespace::Bind)}#{r.enabled? ? "" : " (rule disabled)"} <- #{CLI::Output.term_safe(r.token_loc.label)}#{host}"
      end

      # One text row for a rule: `G#3 [x] REQ sub/H @host  pattern -> value`. The scope letter
      # leads because it is half of the rule's identity — the two stores number independently,
      # so `#3` on its own does not say which rule the next command would address.
      # `*` after it = this project overrides the global default (see Store#rewriter_overrides).
      private def self.rewriter_rule_row(r : Store::MatchRule) : String
        mark = r.inert? ? "?" : (r.enabled? ? "x" : " ")
        side = r.target.request? ? "REQ" : "RES"
        # Rule text comes from agents (MCP `create_rule`) and shared settings files (#1677).
        name = r.name.empty? ? "" : " [#{CLI::Output.term_safe(r.name)}]"
        host = r.host.empty? ? "" : " @#{CLI::Output.term_safe(r.host)}"
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
        Gori::Rules.op_tag(r)
      end

      # `=>` rather than `->` for a stub: it answers instead of forwarding, so the row should
      # not read like the four rewrite ops.
      private def self.rewriter_rule_body(r : Store::MatchRule) : String
        CLI::Output.term_safe(rewriter_rule_text(r))
      end

      private def self.rewriter_rule_text(r : Store::MatchRule) : String
        return r.inert_reason || "unknown rule" if r.inert?
        case r.op
        when .remove_header?, .json_remove? then r.pattern
        when .json_set?                     then "#{r.pattern} = #{r.replacement}"
        when .short_circuit?                then "#{r.pattern} => #{RuleStub.summary(r)}"
          # `<>` rather than `->`: the text on the right is the COMMAND, not the bytes it puts
          # on the wire. Same distinction `Rules.describe` draws with `⇄` in the TUI.
        when .pipe? then "#{r.pattern} <> #{r.replacement}"
        else             "#{r.pattern} -> #{r.replacement}"
        end
      end

      private def self.cmd_rewriter_list(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text
        scope : Store::RuleScope? = nil

        leftover = parse_args(args, "gori run rewriter") do |p|
          p.banner = "Usage: gori run rewriter [options]\n\n" \
                     "Lists the rules that apply to this project: the global library first,\n" \
                     "then the project's own — the order the proxy applies them in.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run rewriter add --op=replace --target=request --find=OLD --value=NEW\n" \
                     "  gori run rewriter add --op=add_header --find=X-Trace --value=on --scope=global\n" \
                     "  gori run rewriter rm|delete <id> | enable <id> | disable <id> | preview ..."
          project_options(p, proj, "read")
          p.on("--scope=SCOPE", "Show only project|global rules (default: both)") { |v| scope = parse_rule_scope(v) }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        refuse_list_leftovers(leftover, "rewriter", "add, rm/delete, enable, disable, preview, extract, bindings")

        project = resolve_read_project(proj.name, proj.db)
        with_store(project, read_only: true) do |store|
          rules = Gori::Rules.merged(store)
          rules = rules.select { |r| r.scope == scope } if scope
          if format == :json
            puts(JSON.build do |j|
              j.array do
                rules.each { |r| MCP::Serialize.match_rule(j, r) }
              end
            end)
          elsif rules.empty?
            puts "No Match & Replace rules configured."
          else
            rules.each { |r| puts rewriter_rule_row(r) }
          end
        end
      end

      private OP_CHOICES = Store::RuleOp.values.join('|', &.label)

      # Parse the shared rule-shape flags into store enums, aborting on a bad value.
      private def self.parse_rewriter_op(s : String) : Store::RuleOp
        Store::RuleOp.from_label?(s.downcase) || abort "gori run rewriter: invalid --op '#{s}' (#{OP_CHOICES})"
      end

      # `--value` for a short-circuit rule is the whole canned response, which is multi-line
      # and awkward to pass on a command line. `--response-file` reads it from a file instead
      # (`-` reads stdin), so `gori run rewriter add --op=short_circuit --find=/admin
      # --response-file=stub.http` is the natural spelling. Distinct from `--body-file`, which
      # points at the BODY the live proxy reads per request; this one is read ONCE, now.
      #
      # Read through `read_input_file` rather than here: a canned response is raw HTTP, so a
      # `-` (or a `/dev/stdin` path) typed at a terminal would echo it and then not end on one
      # `^D` (#1034) — and `File.read` on a DIRECTORY raises a bare `IO::Error` that the
      # `File::Error` rescue this method used to carry could not catch, so `--response-file`
      # pointed at one printed a backtrace where every sibling flag prints a sentence. Only
      # `cmd_rewriter_add` reaches here, so the refusals say `gori run rewriter add`, not the
      # bare `gori run rewriter` that dispatches to the LIST subcommand.
      private def self.read_stub_response(path : String) : String
        read_input_file(path, "gori run rewriter add", stdin: true,
          noun: "canned response", flag: "--response-file=-")
      end

      # The #1237 flags: where a short-circuit rule's answer comes from. A class so the option
      # parser's blocks can fill it; read by `mock_respond` and `apply_flow_draft`, which keep
      # `cmd_rewriter_add` itself under the complexity bar the lint gate holds.
      private class MockFlags
        property map_dir : String? = nil
        property strip_prefix : String = ""
        property? fallthrough : Bool = false
        property fault : String? = nil
        property delay_ms : Int32 = 0
        property hang_ms : Int32? = nil
        property from_flow : Int64? = nil

        def given? : Bool
          !@map_dir.nil? || !@strip_prefix.empty? || @fallthrough || !@fault.nil? ||
            @delay_ms != 0 || !@hang_ms.nil? || !@from_flow.nil?
        end
      end

      private def self.parse_wait_ms(v : String, flag : String) : Int32
        n = v.to_i?
        max = Store::RespondArgs::MAX_WAIT_MS
        abort "gori run rewriter add: invalid #{flag} '#{v}' (milliseconds, 0-#{max})" unless n && 0 <= n <= max
        n
      end

      # {respond, respond_args} for the flags, refusing a combination that names two answers.
      private def self.mock_respond(op : Store::RuleOp, mock : MockFlags,
                                    body_file : String) : {Store::RespondKind, String}
        unless op.short_circuit?
          abort "gori run rewriter add: --map-dir, --fault, --delay and --from-flow need --op=short_circuit" if mock.given?
          return {Store::RespondKind::Inline, ""}
        end
        abort "gori run rewriter add: --map-dir and --fault are two different answers — pick one" if mock.map_dir && mock.fault
        if mock.map_dir && !body_file.empty?
          abort "gori run rewriter add: --map-dir serves a directory; --body-file is for a single-file stub"
        end
        fault = mock.fault.try do |f|
          Store::FaultKind.from_label?(f.downcase) || abort("gori run rewriter add: invalid --fault '#{f}' (close|reset|hang)")
        end
        respond =
          if mock.map_dir
            Store::RespondKind::Dir
          elsif fault
            Store::RespondKind::Fault
          else
            Store::RespondKind.implied(body_file)
          end
        args = Store::RespondArgs.new(mock.strip_prefix, mock.fallthrough?, fault, mock.delay_ms,
          mock.hang_ms || Store::RespondArgs::DEFAULT_HANG_MS)
        {respond, args.to_stored}
      end

      # `--from-flow`: the flow's snapshot fills whatever the flags left unsaid — the match, the
      # host, the response — so `--find`/`--host`/`--value` still override it (P4). Returns
      # {find, match, host, value}.
      private def self.apply_flow_draft(store : Store, flow_id : Int64, find : String?,
                                        match : Store::MatchKind, host : String?,
                                        value : String?) : {String, Store::MatchKind, String, String}
        detail = store.get_flow(flow_id) || abort_closing(store, "gori run rewriter add: no flow ##{flow_id} in this project")
        draft = MockFromFlow.draft(detail)
        if draft.is_a?(MockFromFlow::Refusal)
          abort_closing(store, "gori run rewriter add: cannot mock flow ##{flow_id}: #{draft.message}")
        end
        {find || draft.pattern, find ? match : Store::MatchKind::Regex, host || draft.host, value || draft.replacement}
      end

      # The `--find` a rule is created with. A map-dir rule without one claims its prefix on the
      # REQUEST LINE, anchored — a bare substring would also match a Referer carrying it; a
      # `--from-flow` rule may leave it to the flow's draft (`add_fill`).
      private def self.add_find(op : Store::RuleOp, respond : Store::RespondKind, mock : MockFlags,
                                find : String?, match : Store::MatchKind) : {String?, Store::MatchKind}
        if find.nil? && respond.dir? && !mock.strip_prefix.empty?
          return {"\\A\\S+ #{Regex.escape(mock.strip_prefix)}", Store::MatchKind::Regex}
        end
        if find.try(&.empty?) || (find.nil? && mock.from_flow.nil?)
          abort "gori run rewriter add: --find is required"
        end
        if find && match.regex? && !op.header? && !op.json? && !valid_regex?(find)
          abort "gori run rewriter add: invalid regex --find (failed to compile)"
        end
        {find, match}
      end

      # Everything that needs the open store: the `--from-flow` draft, then the one validator
      # every surface shares (`RuleStub.respond_error`). Returns {find, match, host, value}.
      private def self.add_fill(store : Store, op : Store::RuleOp, mock : MockFlags,
                                respond : Store::RespondKind, respond_args : String, body_file : String,
                                find : String?, match : Store::MatchKind, host : String?,
                                value : String?) : {String, Store::MatchKind, String, String}
        if flow_id = mock.from_flow
          find, match, host, value = apply_flow_draft(store, flow_id, find, match, host, value)
        end
        if op.short_circuit? && (err = RuleStub.respond_error(respond, value || "", body_file, respond_args))
          abort_closing(store, "gori run rewriter add: #{err}")
        end
        if host && (err = Gori::Rules.host_error(host))
          abort_closing(store, "gori run rewriter add: #{err}")
        end
        {find || abort_closing(store, "gori run rewriter add: --find is required"), match, host || "", value || ""}
      end

      # #1711: a plain-HTTP proxy flow is stored with its absolute-form line, but rules run on
      # the origin-form head the proxy forwards (`Rules#live_request_head`).
      ORIGIN_FORM_NOTE = "A request-head rule matches the origin-form line the proxy forwards\n" \
                         "(GET /path), not the absolute form (GET http://host/path) History\n" \
                         "stores for a plain-HTTP proxy flow."

      private def self.warn_absolute_form(target : Store::RuleTarget, part : Store::RulePart, find : String?) : Nil
        return unless target.request? && part.head? && find.try(&.matches?(/\A(?:\^|\\A)?[A-Za-z]+ [A-Za-z][A-Za-z0-9+.\-]*:\/\//))
        STDERR.puts "gori run rewriter add: warning: --find names an absolute-form request line, " \
                    "which a rule never sees; match the origin form (#{find.try(&.lchop("\\A").lchop('^').split(' ', 2).first)} /path)"
      end

      private def self.cmd_rewriter_add(args : Array(String)) : Nil
        proj = ProjectFlags.new
        target_s = "request"
        part_s = nil.as(String?)
        op_s = "replace"
        match_s = "literal"
        match_given = false
        host : String? = nil
        name = ""
        find : String? = nil
        value : String? = nil
        disabled = false
        body_file = ""
        response_file : String? = nil
        scope = Store::RuleScope::Project
        format = :text
        mock = MockFlags.new

        parse_no_positionals(args, "gori run rewriter add",
          "pass the match as --find FIND and the replacement as --value VALUE — quote them, a value " \
          "with spaces is one argument") do |p|
          p.banner = "Usage: gori run rewriter add [options]\n\n" \
                     "For replace: --find is the substring/regex, --value the replacement.\n" \
                     "For a header op: --find is the header NAME, --value the value.\n" \
                     "For short_circuit: --find matches the request head and --value (or\n" \
                     "--response-file) is the canned response gori answers with — nothing is\n" \
                     "sent upstream. --body-file replaces the response BODY, read per request.\n" \
                     "For pipe: --find selects the region and --value is a COMMAND, run with\n" \
                     "no shell, fed the matched bytes on stdin; its stdout replaces them. It\n" \
                     "runs with YOUR privileges. On timeout, non-zero exit or a failed spawn\n" \
                     "the bytes pass through unchanged and a notice is written.\n" \
                     "For json_set / json_remove: --find is a JSON path ($.user.role,\n" \
                     "$.items[-1]) and --value the new value as JSON (\"admin\", true, 42);\n" \
                     "only that value's bytes change. --part defaults to body.\n\n" \
                     "Mocking (short_circuit): --map-dir serves files from a directory by path,\n" \
                     "--fault answers with a close/reset/hang instead of a response, --delay\n" \
                     "waits first, and --from-flow copies a captured response into the rule.\n\n" \
                     "#{ORIGIN_FORM_NOTE}"
          project_options(p, proj, "update")
          p.on("--side=SIDE", "request|response (default request)") { |v| target_s = v }
          # `--side` is the name that does not collide (#1389): `--target` is a URL on every
          # other command. Kept, so no script breaks.
          p.on("--target=SIDE", "Alias for --side") { |v| target_s = v }
          p.on("--op=OP", "#{OP_CHOICES} (default replace)") { |v| op_s = v }
          p.on("--match=KIND", "literal|regex (default literal; replace/pipe/short_circuit only)") { |v| match_s = v; match_given = true }
          p.on("--part=PART", "head|body|ws (default head, body for a json op; replace/pipe/json only; ws = a WebSocket message)") { |v| part_s = v }
          p.on("--host=GLOB", "Scope to a host glob ('' = all; '*.example.com')") { |v| host = v }
          p.on("--scope=SCOPE", "project (default) | global — a global rule applies in EVERY project") { |v| scope = parse_rule_scope(v) }
          p.on("--name=NAME", "Optional rule label") { |v| name = v }
          p.on("-fFIND", "--find=FIND", "Match substring/regex, or header name (required)") { |v| find = v }
          p.on("-vVALUE", "--value=VALUE", "Replacement, header value, canned response, or (--op=pipe) the COMMAND (default empty)") { |v| value = v }
          p.on("--response-file=PATH", "short_circuit: read the canned response from PATH ('-' = stdin, which needs a pipe or a redirect — a terminal is refused)") { |v| response_file = v }
          p.on("--body-file=PATH", "short_circuit: serve PATH as the response BODY (re-read when it changes)") { |v| body_file = v }
          p.on("--map-dir=DIR", "short_circuit: serve the file the request path names from DIR (--value is an optional head template)") { |v| mock.map_dir = v }
          p.on("--strip-prefix=PATH", "--map-dir: the URL prefix to strip before the path is joined under DIR (e.g. /static/)") { |v| mock.strip_prefix = v }
          p.on("--fallthrough", "--map-dir: let a request whose file is MISSING reach the origin (off: gori answers 502)") { mock.fallthrough = true }
          p.on("--fault=KIND", "short_circuit: answer with no response — close | reset | hang") { |v| mock.fault = v }
          p.on("--delay=MS", "short_circuit: wait MS milliseconds before answering (max #{Store::RespondArgs::MAX_WAIT_MS})") { |v| mock.delay_ms = parse_wait_ms(v, "--delay") }
          p.on("--hang=MS", "--fault=hang: how long to hold before closing (default #{Store::RespondArgs::DEFAULT_HANG_MS})") { |v| mock.hang_ms = parse_wait_ms(v, "--hang") }
          p.on("--from-flow=ID", "short_circuit: copy flow ID's captured response into the rule (--find/--host/--value override)") { |v| mock.from_flow = parse_flow_id(v, "gori run rewriter add") }
          p.on("--disabled", "Create the rule disabled") { disabled = true }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        op = parse_rewriter_op(op_s)
        target = Store::RuleTarget.parse?(target_s) || abort("gori run rewriter add: invalid --target/--side '#{target_s}' (request|response)")
        part = parse_rule_part(op, part_s, "add")
        match = Store::MatchKind.parse?(match_s) || abort("gori run rewriter add: invalid --match '#{match_s}' (literal|regex)")
        # The `--from-flow` draft's pattern is a regex; an explicit `--match literal` over it
        # was overridden unsaid. Refused by name, as MCP refuses `match` beside `from_flow_id`.
        if mock.from_flow && find.nil? && match_given && match.literal?
          abort "gori run rewriter add: the pattern drafted from --from-flow is a regex — omit --match, or pass --find"
        end
        respond, respond_args = mock_respond(op, mock, body_file)
        body_file = mock.map_dir || body_file
        find_arg, match = add_find(op, respond, mock, find, match)
        value_arg = value
        host_arg = host
        # ABOVE the read: `check_short_circuit_args` is where `--response-file` is drained, and
        # both of these are knowable from argv alone. `--op=short_circuit --part=ws
        # --response-file=-` used to consume the whole generator — or, at a terminal, earn the
        # stdin refusal — before saying that the op and the part cannot be paired at all, so
        # the operator fixed the pipe and only then learned the flags were wrong. Same
        # ordering, and same reason, as `repeater create` and `issues create` (#1034).
        check_ws_part(op, part, "add")
        warn_absolute_form(target, part, find_arg)
        check_pipe_value(op, value_arg || "", "add")
        check_json_rule(op, part, find_arg, value_arg, "add")
        value_arg = check_short_circuit_args(op, value_arg, response_file, body_file)
        target, part = Gori::Rules.normalize_shape(op, target, part)

        # A global rule needs no project at all — it lives in settings.json — but one is
        # resolved for both scopes, and it is not only that `--project` stays meaningful on
        # every subcommand. `Gori::Rules` is the ONE write path (AGENTS.md §2), and it is where
        # `ConfigLog` is recorded — at the MODEL, so that one site covers TUI, CLI and MCP
        # (see the ConfigLog header, which names the CLI as the surface that gets forgotten).
        # Writing straight at `Settings`/`Store` from here skipped it, so `rule_add` was an
        # event no headless surface ever emitted: installing a rule that strips an
        # `Authorization` header, or one that answers an endpoint without ever dialling it,
        # left the project's config feed with nothing to show for it. The model needs a store
        # to write that line into, so a global add resolves one too.
        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          f, match, rule_host, rule_value = add_fill(store, op, mock, respond, respond_args, body_file,
            find_arg, match, host_arg, value_arg)
          id = Gori::Rules.load(store).create(target, part, f, rule_value, op, match, name, rule_host,
            body_file, scope: scope, enabled: !disabled, respond: respond, respond_args: respond_args)
          if id == 0
            abort "gori run rewriter add: failed to persist rule " \
                  "(#{scope.global? ? "settings not writable" : "store busy or unwritable"})"
          end
          puts rewriter_added_output(store, id, scope, format)
        end
      end

      # What `rewriter add` prints once the write committed. `--format json` (#1117) is the
      # rule's `gori run rewriter --format json` object, through the same `MCP::Serialize.match_rule`,
      # read back through `Rules.merged` — the listing's own read — so `enabled`, `scope` and
      # the normalized target/part are what the listing will say, not what the flags said. A
      # rule a peer removed in that instant has no row, and the command refuses rather than
      # print one the listing never shows. Its own method because `cmd_rewriter_add` is at the
      # complexity bar the lint gate holds.
      private def self.rewriter_added_output(store : Store, id : Int64, scope : Store::RuleScope,
                                             format : Symbol) : String
        unless format == :json
          return scope.global? ? "Global rule ##{id} added — it applies in every project." : "Rule ##{id} added."
        end
        rule = Gori::Rules.merged(store).find { |r| r.scope == scope && r.id == id } ||
               abort_closing(store, "gori run rewriter add: rule ##{id} was created, but it was gone before it could be read back")
        JSON.build { |j| MCP::Serialize.match_rule(j, rule) }
      end

      # Validate the short-circuit-only flags and resolve --response-file into the stub text.
      # A stub that cannot be parsed would answer every matching request with gori's own 502
      # and never reach the origin, so it is refused here rather than discovered from live
      # traffic; --body-file on any other op is refused too, since storing an ignored path
      # would leave the operator believing a body source is configured.
      #
      # Returns nil when no response was given at all, so `--from-flow` can still fill it; the
      # whole shape is then judged by `RuleStub.respond_error`, the validator every surface
      # shares (#1237), once the flow's draft is in.
      private def self.check_short_circuit_args(op : Store::RuleOp, value : String?,
                                                response_file : String?, body_file : String) : String?
        unless op.short_circuit?
          abort "gori run rewriter add: --response-file is only meaningful with --op=short_circuit" if response_file
          abort "gori run rewriter add: --body-file is only meaningful with --op=short_circuit" unless body_file.empty?
          return value
        end
        response_file ? read_stub_response(response_file) : value
      end

      # Only `replace` acts on a WebSocket message: a header op names a header and a WS
      # message has none, and a short-circuit rule answers a request that a WS message is
      # not. Refused rather than normalized — `Rules.normalize_shape` would coerce the part
      # to `head`, which does not narrow the rule but moves it to a different PROTOCOL: the
      # operator asked to rewrite WebSocket frames and would have got a rule rewriting HTTP
      # request heads, with nothing on screen to say so.
      private def self.check_ws_part(op : Store::RuleOp, part : Store::RulePart, verb : String) : Nil
        return unless part.ws? && !(op.replace? || op.pipe? || op.json?)
        abort "gori run rewriter #{verb}: --op=#{op.label} cannot use --part=ws — only replace, " \
              "pipe and the json ops rewrite a WebSocket message; use --part=head for an HTTP header or short-circuit rule"
      end

      # `--part`, defaulting to the body for a JSON op — the one part it can edit — and the head
      # for everything else, as it always has.
      private def self.parse_rule_part(op : Store::RuleOp, part_s : String?, verb : String) : Store::RulePart
        return (op.json? ? Store::RulePart::Body : Store::RulePart::Head) unless part_s
        Store::RulePart.parse?(part_s) || abort("gori run rewriter #{verb}: invalid --part '#{part_s}'")
      end

      # `--find` is a JSON path and `--value` a JSON value for the json ops (#1599); the same
      # validator the TUI editor and the MCP tools call (`Rules.json_rule_error`).
      private def self.check_json_rule(op : Store::RuleOp, part : Store::RulePart, find : String?,
                                       value : String?, verb : String) : Nil
        if why = Gori::Rules.json_rule_error(op, part, find || "", value || "")
          abort "gori run rewriter #{verb}: #{why}"
        end
      end

      # A pipe rule's --value is the ARGV, so an unparseable one is a rule that matches live
      # traffic and then does nothing at all. Refused here for the reason the stub check above
      # is: the alternative is discovering it from traffic that silently went out untouched.
      # `Rules.pipe_argv_error` is the same validator the TUI editor and the MCP tools call.
      private def self.check_pipe_value(op : Store::RuleOp, value : String, verb : String) : Nil
        return unless op.pipe?
        if why = Gori::Rules.pipe_argv_error(op, value)
          abort "gori run rewriter #{verb}: --value is the command to run and #{why} " \
                "(it is exec'd directly — there is no shell, so quote arguments, not pipelines)"
        end
      end

      private def self.valid_regex?(pattern : String) : Bool
        SafeRegexp.compile(pattern)
        true
      rescue
        false
      end

      private def self.cmd_rewriter_rm(args : Array(String)) : Nil
        proj = ProjectFlags.new
        scope = Store::RuleScope::Project
        positional = parse_args(args, "gori run rewriter rm") do |p|
          p.banner = "Usage: gori run rewriter rm|delete <id> [options]"
          project_options(p, proj, "update")
          p.on("--scope=SCOPE", "Which <id>: project (default) | global") { |v| scope = parse_rule_scope(v) }
        end
        id = take_id(positional, "gori run rewriter rm", "<id>", "rule id")

        # Both scopes go through `Gori::Rules` and therefore resolve a project — see
        # `cmd_rewriter_add` for why the model owns the write. For a GLOBAL rule the model also
        # sweeps THIS project's `rewriter_overrides` entry once the rule is really gone; ANOTHER
        # project that had overridden it keeps a row pointing at the id, which this surface
        # cannot reach. That one stays inert: global ids come from a monotonic counter and are
        # never reused, so nothing can inherit it.
        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          exists =
            if scope.global?
              Settings.rewriter_rules.any? { |r| r.id == id }
            else
              store.match_rules.any? { |r| r.id == id }
            end
          exists || abort_closing(store, "gori run rewriter rm: no #{scope.global? ? "global " : ""}rule with id #{id}")
          Gori::Rules.load(store).remove(id, scope) || abort_closing(store, scope.global? ? "gori run rewriter rm: settings not writable (nothing was deleted)" \
                                                                                             : "gori run rewriter rm: project is busy (write did not commit) — try again")
          puts scope.global? ? "Global rule ##{id} deleted — from every project." : "Rule ##{id} deleted."
        end
      end

      private def self.cmd_rewriter_set_enabled(enable : Bool, args : Array(String)) : Nil
        proj = ProjectFlags.new
        scope = Store::RuleScope::Project
        everywhere = false
        action = enable ? "enable" : "disable"
        positional = parse_args(args, "gori run rewriter #{action}") do |p|
          p.banner = "Usage: gori run rewriter #{action} <id> [options]\n\n" \
                     "With --scope=global this writes THIS project's override of the rule,\n" \
                     "the way `x` does in the Rewriter tab. --everywhere changes the rule's\n" \
                     "own default instead, which every project without an override follows."
          project_options(p, proj, "update")
          p.on("--scope=SCOPE", "Which <id>: project (default) | global") { |v| scope = parse_rule_scope(v) }
          p.on("--everywhere", "global rules only: change the default for every project") { everywhere = true }
        end
        id = take_id(positional, "gori run rewriter #{action}", "<id>", "rule id")
        if everywhere && !scope.global?
          abort "gori run rewriter #{action}: --everywhere needs --scope=global — a project rule has no default"
        end

        if scope.global? && !Settings.rewriter_rules.any? { |r| r.id == id }
          abort "gori run rewriter #{action}: no global rule with id #{id}"
        end

        # Both scopes resolve a project, `--everywhere` included: `Gori::Rules` owns the write
        # and its audit line, and it is built over a store. See `cmd_rewriter_add`.
        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          rules = Gori::Rules.load(store)
          if enable && (rule = rules.rules.find { |r| r.id == id && r.scope == scope }) && rule.inert?
            abort "gori run rewriter #{action}: #{rule.inert_reason} — cannot enable this rule with this gori; use a newer version or delete it"
          end
          if everywhere
            # The library's own default. `set_default`, not `set_enabled`: the latter writes
            # THIS project's override, and agreeing with the default drops it rather than
            # pinning it — the disposition the Rewriter tab's `x` has.
            rules.set_default(id, enable) || abort_closing(store, "gori run rewriter #{action}: settings not writable (the rule is unchanged)")
            puts "Global rule ##{id} #{enable ? "enabled" : "disabled"} by default (every project without an override)."
            return
          end
          scope.global? || store.match_rules.any? { |r| r.id == id } || abort_closing(store, "gori run rewriter #{action}: no rule with id #{id}")
          rules.set_enabled(id, enable, scope) || abort_closing(store, "gori run rewriter #{action}: project is busy (write did not commit) — try again")
          if scope.global?
            puts "Global rule ##{id} #{enable ? "enabled" : "disabled"} in project #{CLI::Output.term_safe(project.name)}."
          else
            puts "Rule ##{id} #{enable ? "enabled" : "disabled"}."
          end
        end
      end

      private def self.cmd_rewriter_preview(args : Array(String)) : Nil
        proj = ProjectFlags.new
        target_s = "request"
        part_s = nil.as(String?)
        op_s = "replace"
        match_s = "literal"
        host = ""
        find : String? = nil
        value = ""
        format = :text

        parse_no_positionals(args, "gori run rewriter preview",
          "pass the match as --find FIND and the replacement as --value VALUE — quote them, a value " \
          "with spaces is one argument") do |p|
          p.banner = "Usage: gori run rewriter preview [options]\n\n" \
                     "Estimate how many recent flows a rule WOULD affect, without creating it.\n\n" \
                     "#{ORIGIN_FORM_NOTE}"
          project_options(p, proj, "read")
          p.on("--side=SIDE", "request|response (default request)") { |v| target_s = v }
          # `--side` is the name that does not collide (#1389): `--target` is a URL on every
          # other command. Kept, so no script breaks.
          p.on("--target=SIDE", "Alias for --side") { |v| target_s = v }
          p.on("--op=OP", "#{OP_CHOICES} (default replace)") { |v| op_s = v }
          p.on("--match=KIND", "literal|regex (default literal)") { |v| match_s = v }
          p.on("--part=PART", "head|body|ws (default head, body for a json op)") { |v| part_s = v }
          p.on("--host=GLOB", "Scope to a host glob") { |v| host = v }
          p.on("-fFIND", "--find=FIND", "Match substring/regex, or header name (required)") { |v| find = v }
          p.on("-vVALUE", "--value=VALUE", "Replacement, or header value") { |v| value = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        abort "gori run rewriter preview: --find is required" if (f = find).nil? || f.empty?
        op = parse_rewriter_op(op_s)
        target = Store::RuleTarget.parse?(target_s) || abort("gori run rewriter preview: invalid --target/--side '#{target_s}' (request|response)")
        part = parse_rule_part(op, part_s, "preview")
        match = Store::MatchKind.parse?(match_s) || abort("gori run rewriter preview: invalid --match '#{match_s}' (literal|regex)")
        # Validate the regex up front (like `add` does) — otherwise a bad pattern is
        # swallowed and reported as "0 flows", indistinguishable from a valid rule
        # that simply matched nothing.
        if match.regex? && !op.header? && !op.json? && !valid_regex?(f)
          abort "gori run rewriter preview: invalid regex --find (failed to compile)"
        end
        check_pipe_value(op, value, "preview")
        check_json_rule(op, part, f, value, "preview")
        check_ws_part(op, part, "preview")
        target, part = Gori::Rules.normalize_shape(op, target, part)

        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          candidate = Store::MatchRule.new(0_i64, true, target, part, f, value, op, match, "", host)
          pv = Gori::Rules.new(store, [] of Store::MatchRule).preview(candidate)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "would_match", pv.matched
                j.field "scanned", pv.scanned
                j.field "total_flows", pv.total
                j.field "skipped", pv.skipped
                j.field "scan_capped", pv.capped
              end
            end)
          else
            capped = pv.capped ? " (of #{pv.total} total; scan capped)" : ""
            skipped = pv.skipped > 0 ? " #{pv.skipped} skipped: body too large to preview." : ""
            puts "Would affect #{pv.matched} of #{pv.scanned} recent flows#{capped}.#{skipped}"
          end
        end
      end
    end
  end
end
