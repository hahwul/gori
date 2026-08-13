# `gori run colormarker` — manage History row-colour rules (list, add, rm, enable/disable,
# move, preview). Display only: a colour rule never modifies traffic.
module Gori
  module CLI
    module Run
      private def self.cmd_colormarker(args : Array(String)) : Nil
        case sub = args.first?
        when "add"             then cmd_colormarker_add(args[1..])
        when "rm", "delete"    then cmd_colormarker_rm(args[1..])
        when "enable"          then cmd_colormarker_set_enabled(true, args[1..])
        when "disable"         then cmd_colormarker_set_enabled(false, args[1..])
        when "move"            then cmd_colormarker_move(args[1..])
        when "preview"         then cmd_colormarker_preview(args[1..])
        when "color", "colors" then cmd_colormarker_color(args[1..])
        when "list"            then cmd_colormarker_list(args[1..])
        when nil               then cmd_colormarker_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_colormarker_list(args)
          else
            STDERR.puts "gori run colormarker: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run colormarker [list options] | add | rm|delete <id> | enable <id> | disable <id>"
            STDERR.puts "       gori run colormarker move <id> --up|--down | preview --when=FILTER"
            STDERR.puts "       gori run colormarker color list | add --name=NAME --hex=#rrggbb | update <name> | rm <name>"
            exit 1
          end
        end
      end

      # `gori run colormarker color …` — the GLOBAL custom-colour palette (settings.json), the
      # colours the picker offers in every project on top of the six built-ins. Display-time
      # only, like the rules: a colour paints a row that is already captured.
      private def self.cmd_colormarker_color(args : Array(String)) : Nil
        case sub = args.first?
        when "add"            then cmd_colormarker_color_add(args[1..])
        when "update", "edit" then cmd_colormarker_color_update(args[1..])
        when "rm", "delete"   then cmd_colormarker_color_rm(args[1..])
        when "list", nil      then cmd_colormarker_color_list(sub.nil? ? args : args[1..])
        else
          if (s = sub) && s.starts_with?('-')
            cmd_colormarker_color_list(args)
          else
            abort "gori run colormarker color: unknown subcommand '#{sub}' (list | add | update | rm)"
          end
        end
      end

      private def self.cmd_colormarker_color_list(args : Array(String)) : Nil
        format = :text
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker color list [--format=text|json]\n\n" \
                     "The GLOBAL custom colours, offered in every project's picker alongside the\n" \
                     "six built-ins. A built-in tracks the active theme; a custom is an absolute hex."
          p.on("--format=FMT", "text (default) | json") { |v| format = v == "json" ? :json : :text }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker color list: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker color list: missing value for #{f}" }
        end
        parser.parse(args)
        colors = Settings.colormarker_colors
        if format == :json
          puts(JSON.build do |j|
            j.array { colors.each { |c| j.object { j.field "name", c.name; j.field "hex", c.hex } } }
          end)
        elsif colors.empty?
          puts "No custom colours configured."
        else
          colors.each { |c| puts "#{c.name.ljust(16)} #{c.hex}" }
        end
      end

      private def self.cmd_colormarker_color_add(args : Array(String)) : Nil
        name = ""
        hex = ""
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker color add --name=NAME --hex=#rrggbb\n\n" \
                     "Defines a global custom colour. The name is what a rule's --color references\n" \
                     "and what the picker shows; it must not be blank or one of the built-in words."
          p.on("--name=NAME", "The colour's name (the picker label + a rule's --color)") { |v| name = v }
          p.on("--hex=HEX", "The colour, as #rrggbb (or #rgb)") { |v| hex = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker color add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker color add: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run colormarker color add: --name is required" if name.strip.empty?
        abort "gori run colormarker color add: --hex is required" if hex.strip.empty?
        if err = Settings.add_colormarker_color(name, hex)
          abort "gori run colormarker color add: #{err}"
        end
        puts "Custom colour “#{name.strip.downcase}” added — it is offered in every project's picker."
      end

      # Edit a custom colour in place, keyed by its CURRENT name. Present here (and on MCP)
      # because `Settings.update_colormarker_color` existed with exactly one caller — the TUI's
      # colour editor — so a headless operator could add and delete a colour but never recolour
      # one, and had to delete + re-add instead. That is not the same action: a delete leaves
      # every rule naming the colour dangling on a fallback hue until the re-add lands, in this
      # project and in every other one.
      #
      # Both fields are optional and default to the colour's current value, so `--hex` alone is
      # a recolour and `--name` alone is a rename. A rename deliberately does NOT rewrite the
      # rules that name the old colour — same as a delete, and for the same reason: this surface
      # cannot reach every project's DB.
      private def self.cmd_colormarker_color_update(args : Array(String)) : Nil
        new_name : String? = nil
        hex : String? = nil
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker color update <name> [--name=NEW] [--hex=#rrggbb]\n\n" \
                     "Edits a global custom colour in place. Rules that name it follow the change;\n" \
                     "a RENAME leaves them naming the old colour, which then falls back to a visible\n" \
                     "default (the same trade a delete makes)."
          p.on("--name=NAME", "Rename the colour (default: unchanged)") { |v| new_name = v }
          p.on("--hex=HEX", "Recolour it, as #rrggbb (or #rgb) (default: unchanged)") { |v| hex = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker color update: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker color update: missing value for #{f}" }
        end
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)
        abort "gori run colormarker color update: missing <name>" if positional.empty?
        abort "gori run colormarker color update: too many arguments (expected one <name>)" if positional.size > 1
        old = positional[0].strip.downcase
        current = Settings.colormarker_colors.find { |c| c.name == old }
        abort "gori run colormarker color update: no custom colour named '#{old}'" unless current
        # Copied out of the OptionParser closure before use: Crystal will not narrow a variable
        # a block assigns to, so `new_name || …` would stay `String?` at the call below.
        want_name = new_name
        want_hex = hex
        if want_name.nil? && want_hex.nil?
          abort "gori run colormarker color update: pass --name and/or --hex — there is nothing else to change"
        end
        final_name = want_name || current.name
        if err = Settings.update_colormarker_color(old, final_name, want_hex || current.hex)
          abort "gori run colormarker color update: #{err}"
        end
        after = Settings.colormarker_colors.find { |c| c.name == final_name.strip.downcase }
        puts "Custom colour “#{after.try(&.name) || old}” updated (#{after.try(&.hex) || current.hex})."
        if after && after.name != old
          puts "note: rules still naming “#{old}” keep that reference and fall back to a default colour."
        end
      end

      private def self.cmd_colormarker_color_rm(args : Array(String)) : Nil
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker color rm <name>"
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker color rm: unknown option: #{f}\n#{p}" }
        end
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)
        abort "gori run colormarker color rm: missing <name>" if positional.empty?
        abort "gori run colormarker color rm: too many arguments (expected one <name>)" if positional.size > 1
        name = positional[0].strip.downcase
        abort "gori run colormarker color rm: no custom colour named '#{name}'" unless Settings.colormarker_colors.any? { |c| c.name == name }
        abort "gori run colormarker color rm: settings not writable (nothing was deleted)" unless Settings.delete_colormarker_color(name)
        # A rule that still names it is left inert — it falls back to a visible default rather
        # than this surface reaching into every project's DB to rewrite the rules.
        puts "Custom colour “#{name}” deleted."
      end

      # One text row: `G*#2 [ ] strip  yellow  [name]  status:401 OR status:403`.
      #
      # The scope letter leads because it is half of the rule's identity — the two stores
      # number independently, so `#2` alone does not say which rule the next command addresses.
      # `*` after it = this project overrides the global default.
      #
      # Public so a spec can pin the shape, the same reason `list_leftover_error` is: the
      # commands that print it end in `abort`/`exit`, which cannot be exercised from a spec.
      #
      # `color_w` is the colour column's width, measured across the rules being printed
      # (`colormarker_color_width`). It was a literal 6, which fitted the longest built-in word
      # (`orange`) and nothing else — a custom colour is an operator-typed name of any length, so
      # a single `hotpink` shifted the name and condition columns on EVERY row of the listing.
      def self.colormarker_rule_row(r : Store::ColorRule, color_w : Int32 = 6) : String
        mark = r.enabled? ? "x" : " "
        name = r.name.empty? ? "" : " [#{r.name}]"
        scope = "#{r.scope.badge}#{r.overridden? ? "*" : ""}"
        cond = r.match_filter.empty? ? "(every flow)" : r.match_filter
        "#{scope}##{r.id} [#{mark}] #{r.style.label.ljust(5)} #{r.color.ljust(color_w)}#{name}  #{cond}"
      end

      # The colour column's width for one listing: the longest colour name in it, never narrower
      # than the built-in default so a list of built-ins keeps the shape it has always had.
      def self.colormarker_color_width(rules : Array(Store::ColorRule)) : Int32
        {rules.max_of?(&.color.size) || 6, 6}.max
      end

      # `--scope` on every rule subcommand: WHICH store the id names (or, on list, which half
      # to print). Aborts rather than clamping — silently reading "globl" as "project" would
      # report success for an edit the operator meant to make everywhere.
      private def self.parse_color_scope(s : String) : Store::RuleScope
        case s.downcase
        when "project" then Store::RuleScope::Project
        when "global"  then Store::RuleScope::Global
        else                abort "gori run colormarker: invalid --scope '#{s}' (project|global)"
        end
      end

      # A colour LABEL: one of the six built-in words, or the name of a user-defined custom
      # colour (settings.json `colormarker.colors`). Aborts rather than clamping — silently
      # reading an unknown colour as yellow would paint rows the operator did not ask to.
      private def self.parse_marker_color(s : String) : String
        key = s.downcase
        return key if Settings::COLORMARKER_COLORS.includes?(key)
        return key if Settings.colormarker_colors.any? { |c| c.name == key }
        abort "gori run colormarker: invalid --color '#{s}' (#{marker_color_choices})"
      end

      # The colour vocabulary this install offers: built-ins first, then any custom colours.
      def self.marker_color_choices : String
        (Settings::COLORMARKER_COLORS + Settings.colormarker_colors.map(&.name)).join("|")
      end

      private def self.parse_marker_style(s : String) : Store::MarkerStyle
        unless Settings::COLORMARKER_STYLES.includes?(s.downcase)
          abort "gori run colormarker: invalid --style '#{s}' (full|strip)"
        end
        Store::MarkerStyle.from_label(s)
      end

      # The non-fatal notes about a condition, on STDERR so they are visible without polluting
      # a piped stdout. Same words the TUI hint and the MCP `notes` use.
      private def self.print_color_advice(filter : String) : Nil
        Colormarker.advise(filter).each { |n| STDERR.puts "note: #{n}" }
      end

      # `enabled` is the EFFECTIVE state in this project; `default_enabled` and `overridden`
      # only appear for a global rule, where the two can differ. A project rule has one state,
      # and printing two fields for it would invite the reader to look for a difference that
      # cannot exist. Public for the same reason as the row above.
      def self.colormarker_rule_json(j : JSON::Builder, r : Store::ColorRule) : Nil
        j.object do
          j.field "id", r.id
          j.field "scope", r.scope.label
          j.field "enabled", r.enabled?
          if r.global?
            j.field "overridden", r.overridden?
            j.field "default_enabled", Settings.colormarker_rules.find { |g| g.id == r.id }.try(&.enabled)
          end
          j.field "name", r.name
          # "when", the same key settings.json writes and the MCP tools accept — one vocabulary
          # across all three surfaces.
          j.field "when", r.match_filter
          j.field "color", r.color
          j.field "style", r.style.label
        end
      end

      private def self.cmd_colormarker_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        scope = nil.as(Store::RuleScope?)
        leftover = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker [list] [options]\n\n" \
                     "Rules are listed in PRECEDENCE order: the global library first, then this\n" \
                     "project's own rows. The FIRST enabled match paints a History row and the\n" \
                     "rest are never consulted. Display only — a colour rule never modifies traffic."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--scope=SCOPE", "Show only project | global rules") { |v| scope = parse_color_scope(v) }
          p.on("--format=FMT", "text (default) | json") { |v| format = v == "json" ? :json : :text }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker: missing value for #{f}" }
        end
        # BOTH halves of unknown_args: a bare word after `--` would otherwise be dropped
        # silently and a typo'd subcommand would list instead of erroring.
        parser.unknown_args { |before, after| leftover = before + after }
        parser.parse(args)
        refuse_list_leftovers(leftover, "colormarker", "add, rm/delete, enable, disable, move, preview")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          rules = Gori::Colormarker.merged(store)
          rules = rules.select { |r| r.scope == scope } if scope
          if format == :json
            puts(JSON.build do |j|
              j.array do
                rules.each { |r| colormarker_rule_json(j, r) }
              end
            end)
          elsif rules.empty?
            puts "No colour rules configured."
          else
            w = colormarker_color_width(rules)
            rules.each { |r| puts colormarker_rule_row(r, w) }
          end
        ensure
          store.close
        end
      end

      private def self.cmd_colormarker_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        color_s = "yellow"
        style_s = "full"
        name = ""
        filter : String? = nil
        disabled = false
        scope = Store::RuleScope::Project

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker add --when=FILTER [options]\n\n" \
                     "--when is a History QL condition (#{Colormarker::USEFUL_FIELDS.join(": ")}:,\n" \
                     "plus ~regex, AND/OR/NOT and -negation) — the same query the History filter\n" \
                     "bar takes, matched against the captured flow. `body:` here SCANS the stored\n" \
                     "bytes rather than the text index, so it also paints matches that same term\n" \
                     "in the filter bar misses. `host:` is a SUBSTRING, not a DNS-label glob.\n" \
                     "Display only: a colour rule never modifies traffic."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-wFILTER", "--when=FILTER", "Condition the flow must match (required)") { |v| filter = v }
          p.on("--color=NAME", "#{marker_color_choices} (default yellow)") { |v| color_s = v }
          p.on("--style=STYLE", "full (tint the whole row) | strip (one colour cell) — default full") { |v| style_s = v }
          p.on("--scope=SCOPE", "project (default) | global — a global rule applies in EVERY project") { |v| scope = parse_color_scope(v) }
          p.on("--name=NAME", "Optional rule label") { |v| name = v }
          p.on("--disabled", "Create the rule disabled") { disabled = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker add: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run colormarker add: --when is required" if (f = filter).nil?
        # The engine owns what is legal, so the CLI, the TUI form and MCP cannot disagree.
        if reason = Colormarker.unusable_reason(f)
          abort "gori run colormarker add: #{reason}"
        end
        color = parse_marker_color(color_s)
        style = parse_marker_style(style_s)

        # A global rule needs no project at all — it lives in settings.json — but resolving one
        # anyway keeps `--project` meaningful on every subcommand.
        if scope.global?
          id = Settings.add_colormarker_rule(f, color, style.label, name, !disabled)
          abort "gori run colormarker add: failed to persist rule (settings not writable)" if id == 0
          puts "Global colour rule ##{id} added — it applies in every project."
          print_color_advice(f)
          return
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          id = store.insert_color_rule(f, color, style, name, !disabled)
          if id == 0
            store.close
            abort "gori run colormarker add: project is busy (write did not commit) — try again"
          end
          puts "Colour rule ##{id} added."
          print_color_advice(f)
        ensure
          store.close
        end
      end

      private def self.cmd_colormarker_rm(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        scope = Store::RuleScope::Project
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker rm <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--scope=SCOPE", "Which <id>: project (default) | global") { |v| scope = parse_color_scope(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker rm: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker rm: missing value for #{f}" }
        end
        positional = [] of String
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)
        abort "gori run colormarker rm: missing <id>" if positional.empty?
        abort "gori run colormarker rm: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run colormarker rm: invalid rule id '#{positional[0]}'")

        # A project that had overridden this rule keeps a row pointing at the id, and this
        # surface cannot reach every project's DB to sweep it. It stays inert: global ids come
        # from a monotonic counter and are never reused, so nothing can inherit the override.
        if scope.global?
          abort "gori run colormarker rm: no global rule with id #{id}" unless Settings.colormarker_rules.any? { |r| r.id == id }
          abort "gori run colormarker rm: settings not writable (nothing was deleted)" unless Settings.delete_colormarker_rule(id)
          puts "Global colour rule ##{id} deleted — from every project."
          return
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          unless store.color_rules.any? { |r| r.id == id }
            store.close
            abort "gori run colormarker rm: no colour rule with id #{id}"
          end
          unless store.delete_color_rule(id)
            store.close
            abort "gori run colormarker rm: project is busy (write did not commit) — the row colour is unchanged"
          end
          puts "Colour rule ##{id} deleted."
        ensure
          store.close
        end
      end

      private def self.cmd_colormarker_set_enabled(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        scope = Store::RuleScope::Project
        everywhere = false
        action = enable ? "enable" : "disable"
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker #{action} <id> [options]\n\n" \
                     "With --scope=global this writes THIS project's override of the rule, the\n" \
                     "way `x` does in the Colormarker tab. --everywhere changes the rule's own\n" \
                     "default instead, which every project without an override follows."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--scope=SCOPE", "Which <id>: project (default) | global") { |v| scope = parse_color_scope(v) }
          p.on("--everywhere", "global rules only: change the default for every project") { everywhere = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker #{action}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker #{action}: missing value for #{f}" }
        end
        positional = [] of String
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)
        abort "gori run colormarker #{action}: missing <id>" if positional.empty?
        abort "gori run colormarker #{action}: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run colormarker #{action}: invalid rule id '#{positional[0]}'")
        if everywhere && !scope.global?
          abort "gori run colormarker #{action}: --everywhere needs --scope=global — a project rule has no default"
        end

        # The rule's own default, read once: `everywhere` writes it, and the per-project branch
        # below compares against it to decide between an override and dropping one.
        default = nil.as(Bool?)
        if scope.global?
          rule = Settings.colormarker_rules.find { |r| r.id == id }
          abort "gori run colormarker #{action}: no global rule with id #{id}" unless rule
          default = rule.enabled
          if everywhere
            abort "gori run colormarker #{action}: settings not writable (the rule is unchanged)" unless Settings.set_colormarker_rule_enabled(id, enable)
            puts "Global colour rule ##{id} #{enable ? "enabled" : "disabled"} by default (every project without an override)."
            return
          end
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          if scope.global?
            # Same disposition `Colormarker#toggle` writes: agreeing with the default DROPS the
            # override rather than pinning it, so this project keeps following the library.
            ok = default == enable ? store.clear_colormarker_override(id) : store.set_colormarker_override(id, enable)
            unless ok
              store.close
              abort "gori run colormarker #{action}: project is busy (write did not commit) — try again"
            end
            puts "Global colour rule ##{id} #{enable ? "enabled" : "disabled"} in project #{project.name}."
            return
          end
          unless store.color_rules.any? { |r| r.id == id }
            store.close
            abort "gori run colormarker #{action}: no colour rule with id #{id}"
          end
          unless store.set_color_rule_enabled(id, enable)
            store.close
            abort "gori run colormarker #{action}: project is busy (write did not commit) — the row colour is unchanged"
          end
          puts "Colour rule ##{id} #{enable ? "enabled" : "disabled"}."
        ensure
          store.close
        end
      end

      # Reordering exists here, unlike `gori run rewriter`, and that is not parity padding:
      # rewrite rules compose so their order is a tiebreak, while the FIRST matching colour rule
      # paints the row and the rest are skipped. Order IS the rule set's meaning, so every
      # surface that can create a rule has to be able to reorder one.
      private def self.cmd_colormarker_move(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        scope = Store::RuleScope::Project
        dir = 0
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker move <id> --up|--down [options]\n\n" \
                     "Moves the rule within its OWN scope. The scope boundary is not a position:\n" \
                     "every global rule resolves before every project one, so moving past the end\n" \
                     "of a block is a scope change, not a step."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--scope=SCOPE", "Which <id>: project (default) | global") { |v| scope = parse_color_scope(v) }
          p.on("--up", "Give the rule higher precedence") { dir = -1 }
          p.on("--down", "Give the rule lower precedence") { dir = 1 }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker move: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker move: missing value for #{f}" }
        end
        positional = [] of String
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)
        abort "gori run colormarker move: missing <id>" if positional.empty?
        abort "gori run colormarker move: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run colormarker move: invalid rule id '#{positional[0]}'")
        abort "gori run colormarker move: pass --up or --down" if dir == 0

        if scope.global?
          abort "gori run colormarker move: no global rule with id #{id}" unless Settings.colormarker_rules.any? { |r| r.id == id }
          unless Settings.move_colormarker_rule(id, dir)
            abort "gori run colormarker move: rule ##{id} is already at the #{dir < 0 ? "top" : "bottom"} of the global block"
          end
          puts "Global colour rule ##{id} moved #{dir < 0 ? "up" : "down"}."
          return
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ids = store.color_rules.map(&.id)
          i = ids.index(id)
          unless i
            store.close
            abort "gori run colormarker move: no colour rule with id #{id}"
          end
          j = i + dir
          if j < 0 || j >= ids.size
            store.close
            abort "gori run colormarker move: rule ##{id} is already at the #{dir < 0 ? "top" : "bottom"} of the project block"
          end
          unless store.move_color_rule(id, dir)
            store.close
            abort "gori run colormarker move: project is busy (write did not commit) — the precedence order is unchanged"
          end
          puts "Colour rule ##{id} moved #{dir < 0 ? "up" : "down"}."
        ensure
          store.close
        end
      end

      private def self.cmd_colormarker_preview(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        filter : String? = nil
        format = :text
        limit = Colormarker::PREVIEW_SCAN
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run colormarker preview --when=FILTER [options]\n\n" \
                     "Reports how many recent flows the condition MATCHES, and how many it would\n" \
                     "actually PAINT once the rules that already resolve ahead of it are counted.\n" \
                     "The two differ whenever an earlier enabled rule claims a row first."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-wFILTER", "--when=FILTER", "Condition to test (required)") { |v| filter = v }
          p.on("--limit=N", "Recent flows to scan (default #{Colormarker::PREVIEW_SCAN})") { |v| limit = v.to_i? || limit }
          p.on("--format=FMT", "text (default) | json") { |v| format = v == "json" ? :json : :text }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run colormarker preview: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run colormarker preview: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run colormarker preview: --when is required" if (f = filter).nil?
        if reason = Colormarker.unusable_reason(f)
          abort "gori run colormarker preview: #{reason}"
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          existing = Gori::Colormarker.merged(store)
          pv = Gori::Colormarker.preview(store, f, existing, limit)
          notes = Colormarker.advise(f)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "would_match", pv.matched
                j.field "would_paint", pv.painted
                j.field "scanned", pv.scanned
                j.field "total_flows", pv.total
                j.field "scan_capped", pv.total > pv.scanned
                j.field "notes" { j.array { notes.each { |n| j.string n } } }
              end
            end)
          else
            more = pv.total > pv.scanned ? " (of #{pv.total} total; scan capped)" : ""
            claimed = pv.matched - pv.painted
            tail = claimed > 0 ? "; #{pv.painted} would actually be painted (#{claimed} claimed by an earlier rule)" : ""
            puts "Would match #{pv.matched} of #{pv.scanned} recent flows#{more}#{tail}."
            notes.each { |n| STDERR.puts "note: #{n}" }
          end
        ensure
          store.close
        end
      end
    end
  end
end
