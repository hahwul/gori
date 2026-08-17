require "json"
require "../../store"
require "../../colormarker"

module Gori
  module MCP
    class Tools
      # --- Colormarker rules (History row colouring) -----------------------------------
      #
      # DISPLAY ONLY: a colour rule never modifies traffic. Same two-scope model and the same
      # `{id, scope}` identity the Match & Replace tools above use, so an agent that learned
      # one has learned the other — with one axis genuinely different, and every description
      # says so: rewrite rules COMPOSE, colour rules RESOLVE (the first enabled match paints the
      # row and the rest are never consulted). That is why `move_color_rule` exists here where
      # the rewrite tools have no reorder: order is this rule set's meaning, not a tiebreak.

      # Every colour rule that applies to this project, in PRECEDENCE order: the global library
      # first, then the project's own rows.
      private def list_color_rules(h) : Result
        want = nil.as(Store::RuleScope?)
        if present?(h, "scope")
          sc = color_rule_scope(h)
          return sc if sc.is_a?(Result)
          want = sc
        end
        rules = Gori::Colormarker.merged(store)
        rules = rules.select { |r| r.scope == want } if want
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", rules.size
            j.field "rules" do
              j.array do
                rules.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "scope", r.scope.label
                    # The EFFECTIVE state here. For a global rule the library's own default may
                    # differ — this project overrode it — and both are reported so an agent can
                    # tell "off everywhere" from "off in this engagement".
                    j.field "enabled", r.enabled?
                    if r.global?
                      j.field "overridden", r.overridden?
                      j.field "default_enabled", Settings.colormarker_rules.find { |g| g.id == r.id }.try(&.enabled)
                    end
                    j.field "name", r.name
                    j.field "when", r.match_filter
                    j.field "color", r.color
                    j.field "style", r.style.label
                  end
                end
              end
            end
          end
        end)
      end

      # The `scope` argument, defaulting to this project — the safe direction. An unrecognised
      # value is REFUSED rather than clamped, because clamping "globl" to project would report
      # success for an edit the caller meant to make everywhere.
      private def color_rule_scope(h) : Store::RuleScope | Result
        s = str(h, "scope")
        return Store::RuleScope::Project if s.nil? || s.empty?
        case s.downcase
        when "project" then Store::RuleScope::Project
        when "global"  then Store::RuleScope::Global
        else                err("invalid 'scope' (expected project|global)", "INVALID_ARGUMENT", field: "scope")
        end
      end

      # A colour LABEL: one of the six built-in words, or the name of a user-defined custom
      # colour (settings.json `colormarker.colors`). An argument an agent just typed gets told it
      # was wrong, rather than clamped — the same refusal the CLI makes and the opposite of the
      # tolerant file parse.
      private def marker_color(h, dft : String) : String | Result
        s = str(h, "color")
        return dft if s.nil? || s.empty?
        key = s.downcase
        return key if Settings::COLORMARKER_COLORS.includes?(key)
        return key if Settings.colormarker_colors.any? { |c| c.name == key }
        err("invalid 'color' (expected #{(Settings::COLORMARKER_COLORS + Settings.colormarker_colors.map(&.name)).join("|")})",
          "INVALID_ARGUMENT", field: "color")
      end

      private def marker_style(h, dft : Store::MarkerStyle) : Store::MarkerStyle | Result
        s = str(h, "style")
        return dft if s.nil? || s.empty?
        return err("invalid 'style' (expected full|strip)",
          "INVALID_ARGUMENT", field: "style") unless Settings::COLORMARKER_STYLES.includes?(s.downcase)
        Store::MarkerStyle.from_label(s)
      end

      private def create_color_rule(h) : Result
        filter = str(h, "when")
        return err("missing required 'when'", "INVALID_ARGUMENT", field: "when") if filter.nil?
        # The engine owns what is legal, so the TUI form, the CLI and this surface cannot
        # disagree. All three refusals name a rule that would otherwise fail SILENTLY.
        if reason = Gori::Colormarker.unusable_reason(filter)
          return err(reason, "INVALID_ARGUMENT", field: "when")
        end
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        color = marker_color(h, "yellow")
        return color if color.is_a?(Result)
        style = marker_style(h, Store::MarkerStyle::Full)
        return style if style.is_a?(Result)
        name = str(h, "name") || ""
        # Atomic disabled creation: insert already-disabled so there is no window where a
        # just-created rule paints before a follow-up disable call.
        enabled = bool_arg(h, "enabled", true)
        id =
          if scope.global?
            Settings.add_colormarker_rule(filter, color, style.label, name, enabled)
          else
            store.insert_color_rule(filter, color, style, name, enabled)
          end
        if id == 0
          return busy(scope.global? ? "failed to persist global colour rule (settings not writable)" : "failed to persist colour rule (store busy or unwritable)")
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
            j.field "color", color
            j.field "style", style.label
            j.field "enabled", enabled
            # The advisory channel. `InterceptFilter` cannot fail to compile, so a condition
            # that will behave surprisingly cannot be caught by a parse error — these say so
            # without refusing something legitimate.
            color_rule_notes(j, filter)
          end
        end)
      end

      private def color_rule_notes(j : JSON::Builder, filter : String) : Nil
        notes = Gori::Colormarker.advise(filter)
        return if notes.empty?
        j.field "notes" { j.array { notes.each { |n| j.string n } } }
      end

      private def update_color_rule(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        existing = Gori::Colormarker.merged(store).find { |r| r.id == id && r.scope == scope }
        return not_found("no #{scope.label} colour rule with id #{id}") unless existing
        # Every field is optional: omitted means unchanged.
        filter = str(h, "when") || existing.match_filter
        if reason = Gori::Colormarker.unusable_reason(filter)
          return err(reason, "INVALID_ARGUMENT", field: "when")
        end
        color = marker_color(h, existing.color)
        return color if color.is_a?(Result)
        style = marker_style(h, existing.style)
        return style if style.is_a?(Result)
        name = str(h, "name") || existing.name
        ok =
          if scope.global?
            Settings.update_colormarker_rule(id, filter, color, style.label, name)
          else
            store.update_color_rule(id, filter, color, style, name)
          end
        return busy("colour rule NOT updated (store busy or unwritable); the row colour is unchanged") unless ok
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
            j.field "when", filter
            j.field "color", color
            j.field "style", style.label
            color_rule_notes(j, filter)
          end
        end)
      end

      # For a global rule this writes THIS PROJECT's override by default — the same meaning `x`
      # has in the Colormarker tab. `everywhere: true` changes the library's own default
      # instead, which reaches every project that has not overridden it.
      private def set_color_rule_enabled(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        enabled = optional_bool_arg(h, "enabled")
        return Result.new("missing required 'enabled' (true|false)", is_error: true) if enabled.nil?
        everywhere = bool_arg(h, "everywhere", false)
        return err("'everywhere' needs scope=global — a project rule has no default", "INVALID_ARGUMENT", field: "everywhere") if everywhere && !scope.global?
        return not_found("no #{scope.label} colour rule with id #{id}") unless color_rule_exists?(id, scope)
        ok =
          if !scope.global?
            store.set_color_rule_enabled(id, enabled)
          elsif everywhere
            Settings.set_colormarker_rule_enabled(id, enabled)
          else
            set_global_color_rule_enabled_here(id, enabled)
          end
        return busy("enable/disable NOT applied (store busy or unwritable); the row colour is unchanged") unless ok
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
            j.field "enabled", enabled
            j.field "everywhere", everywhere if scope.global?
          end
        end)
      end

      # Make a global colour rule effectively `enabled` in THIS project. Agreeing with the
      # library's default CLEARS the override instead of pinning it, so the project keeps
      # following a later change to that default — the disposition `Colormarker#toggle`
      # documents, and the third place it is spelled out (engine, CLI, here).
      private def set_global_color_rule_enabled_here(id : Int64, enabled : Bool) : Bool
        rule = Settings.colormarker_rules.find { |r| r.id == id }
        return false unless rule
        rule.enabled == enabled ? store.clear_colormarker_override(id) : store.set_colormarker_override(id, enabled)
      end

      private def delete_color_rule(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        return not_found("no #{scope.label} colour rule with id #{id}") unless color_rule_exists?(id, scope)
        ok =
          if scope.global?
            deleted = Settings.delete_colormarker_rule(id)
            # ONLY once the rule is actually gone. Existence was established above, so a false
            # here means "settings not saved" — and clearing the override then would drop this
            # project back to a default the operator explicitly overrode.
            store.clear_colormarker_override(id) if deleted
            deleted
          else
            store.delete_color_rule(id)
          end
        return busy("colour rule NOT deleted (store busy or unwritable); the row colour is unchanged") unless ok
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "scope", scope.label; j.field "deleted", true } })
      end

      # Reorder within a scope. The scope boundary is not a position: every global rule resolves
      # before every project one, so moving past the end of a block is a scope change.
      private def move_color_rule(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        scope = color_rule_scope(h)
        return scope if scope.is_a?(Result)
        dir_s = str(h, "direction")
        dir =
          case dir_s.try(&.downcase)
          when "up"   then -1
          when "down" then 1
          else             return err("invalid 'direction' (expected up|down)", "INVALID_ARGUMENT", field: "direction")
          end
        return not_found("no #{scope.label} colour rule with id #{id}") unless color_rule_exists?(id, scope)
        scoped = Gori::Colormarker.merged(store).select { |r| r.scope == scope }
        # `color_rule_exists?` above already established the id is in this scope, so the index
        # is present — but derive the bound from `index?` anyway rather than asserting it, so a
        # future caller that skips the guard gets a refusal instead of a nil dereference.
        i = scoped.index { |r| r.id == id }
        j2 = i ? i + dir : -1
        if i.nil? || j2 < 0 || j2 >= scoped.size
          return err("colour rule #{id} is already at the #{dir < 0 ? "top" : "bottom"} of the #{scope.label} block",
            "INVALID_ARGUMENT", field: "direction")
        end
        if scope.global?
          return busy("colour rule NOT moved (settings not writable)") unless Settings.move_colormarker_rule(id, dir)
        else
          return busy("colour rule NOT moved (project busy) — the precedence order is unchanged") unless store.move_color_rule(id, dir)
        end
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "scope", scope.label; j.field "moved", dir_s } })
      end

      # How many recent flows a candidate condition would MATCH, and how many it would actually
      # PAINT once the rules that already resolve ahead of it are counted. The second number is
      # the one that answers "will I see this": an earlier enabled rule may already claim the row.
      private def preview_color_rule(h) : Result
        filter = str(h, "when")
        return err("missing required 'when'", "INVALID_ARGUMENT", field: "when") if filter.nil?
        if reason = Gori::Colormarker.unusable_reason(filter)
          return err(reason, "INVALID_ARGUMENT", field: "when")
        end
        # Clamp in Int64, THEN narrow: `.to_i` is checked, so clamping after it meant
        # `{"limit": 10000000000}` — the "no limit" number an LLM reaches for — OverflowError'd
        # past the INVALID_ARGUMENT arm at `Tools#call` and came back INTERNAL, telling the
        # agent the server was broken instead of its argument. Still a CLAMP and not
        # `bounded_int_arg`: this argument has always been forgiving at both ends, and `0` is
        # the other spelling of "no limit" an agent reaches for — turning that into a hard
        # INVALID_ARGUMENT would be a second, opposite way to fail the same call.
        limit = (optional_int_arg(h, "limit") || Gori::Colormarker::PREVIEW_SCAN.to_i64).clamp(1_i64, 5000_i64).to_i
        existing = Gori::Colormarker.merged(store)
        pv = Gori::Colormarker.preview(store, filter, existing, limit)
        Result.new(JSON.build do |j|
          j.object do
            j.field "would_match", pv.matched
            j.field "would_paint", pv.painted
            j.field "scanned", pv.scanned
            j.field "total_flows", pv.total
            j.field "scan_capped", pv.total > pv.scanned
            color_rule_notes(j, filter)
          end
        end)
      end

      # --- custom colours (the global picker palette) ----------------------------------
      # A custom colour is a name + an absolute hex, offered in every project's picker on top of
      # the six built-ins. Keyed by name (no numeric id), the same identity the picker and a
      # rule's `color` use.

      private def list_custom_colors : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", Settings.colormarker_colors.size
            j.field "colors" do
              j.array do
                Settings.colormarker_colors.each do |c|
                  j.object { j.field "name", c.name; j.field "hex", c.hex }
                end
              end
            end
          end
        end)
      end

      private def create_custom_color(h) : Result
        name = str(h, "name")
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil?
        hex = str(h, "hex")
        return err("missing required 'hex'", "INVALID_ARGUMENT", field: "hex") if hex.nil?
        # The settings registry is the arbiter of name/hex legality and uniqueness — a non-nil
        # message means it refused, said the same way the CLI and TUI say it.
        if msg = Settings.add_colormarker_color(name, hex)
          return err(msg, "INVALID_ARGUMENT", field: "name")
        end
        norm = Settings.colormarker_colors.find { |c| c.name == name.strip.downcase }
        Result.new(JSON.build do |j|
          j.object do
            j.field "name", norm.try(&.name) || name.strip.downcase
            j.field "hex", norm.try(&.hex) || hex
          end
        end)
      end

      # Edit a custom colour in place. Present because `Settings.update_colormarker_color` had
      # exactly one caller — the TUI's colour editor — so an agent could add and delete a colour
      # but never recolour one, and delete + re-add is NOT the same action: between the two every
      # rule naming the colour, in this project and in every other one, paints a fallback hue.
      #
      # Both editable fields default to the current value, so `hex` alone recolours and
      # `new_name` alone renames. The registry is the arbiter of legality and uniqueness.
      private def update_custom_color(h) : Result
        name = str(h, "name")
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil?
        key = name.strip.downcase
        current = Settings.colormarker_colors.find { |c| c.name == key }
        return not_found("no custom colour named '#{key}'") unless current
        new_name = str(h, "new_name")
        hex = str(h, "hex")
        if new_name.nil? && hex.nil?
          return err("pass 'new_name' and/or 'hex' — there is nothing else to change",
            "INVALID_ARGUMENT", field: "hex")
        end
        if msg = Settings.update_colormarker_color(key, new_name || current.name, hex || current.hex)
          return err(msg, "INVALID_ARGUMENT", field: new_name ? "new_name" : "hex")
        end
        after = Settings.colormarker_colors.find { |c| c.name == (new_name || current.name).strip.downcase }
        Result.new(JSON.build do |j|
          j.object do
            j.field "name", after.try(&.name) || key
            j.field "hex", after.try(&.hex) || current.hex
            j.field "renamed_from", key if after && after.name != key
          end
        end)
      end

      private def delete_custom_color(h) : Result
        name = str(h, "name")
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil?
        key = name.strip.downcase
        return not_found("no custom colour named '#{key}'") unless Settings.colormarker_colors.any? { |c| c.name == key }
        return busy("custom colour NOT deleted (settings not writable)") unless Settings.delete_colormarker_color(key)
        Result.new(JSON.build { |j| j.object { j.field "name", key; j.field "deleted", true } })
      end

      # Whether a colour rule id exists IN THAT SCOPE. A full read (neither store has a
      # single-row fetch), but the rule set is tiny and these are low-frequency actions.
      private def color_rule_exists?(id : Int64, scope : Store::RuleScope) : Bool
        if scope.global?
          Settings.colormarker_rules.any? { |r| r.id == id }
        else
          store.color_rules.any? { |r| r.id == id }
        end
      end

      # The tools/list schemas for the Colormarker tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_color_rules_tools(j : JSON::Builder) : Nil
        tool j, "list_color_rules",
          "List the Colormarker rules for this project — which captured History rows get " \
          "COLOURED, and how. DISPLAY ONLY: a colour rule never modifies traffic. Listed in " \
          "PRECEDENCE order (GLOBAL library first, then the project's own): unlike Match & " \
          "Replace rules, which all compose, the FIRST enabled match paints a row and the rest " \
          "are never consulted — so order is the rule set's meaning, and move_color_rule " \
          "changes it. `id` is unique only within a scope, so pass both to the mutation tools. " \
          "For a global rule, `enabled` is the state in THIS project and `default_enabled` the " \
          "library's own." do |s|
          s.field "scope", strprop("show only project | global rules (default: both)")
        end

        tool j, "preview_color_rule",
          "Estimate how many recent flows a colour-rule condition would MATCH, and how many it " \
          "would actually PAINT once the rules that already resolve ahead of it are counted " \
          "(an earlier enabled rule may claim the row first), WITHOUT creating anything. " \
          "Display only — nothing here modifies traffic." do |s|
          s.field "when", strprop("the condition to test (see create_color_rule)"), required: true
          s.field "limit", intprop("recent flows to scan (default 500)")
        end

        tool j, "list_custom_colors",
          "List the GLOBAL custom colours — user-defined names the Colormarker picker offers " \
          "in every project on top of the six built-ins. Each is a name (what a rule's `color` " \
          "references) and an absolute hex. Unlike a built-in, a custom does NOT track the " \
          "active theme. Display only." do |_s|
        end

        return unless @allow_actions

        tool j, "create_color_rule",
          "Add a Colormarker rule: colour the History rows whose captured flow matches a " \
          "condition. Persisted to the project, or to the global library shared by every " \
          "project when scope=global. The FIRST enabled matching rule paints a row and the " \
          "rest are never consulted, so precedence matters — use move_color_rule to change " \
          "it. Display only — a colour rule never modifies traffic." do |s|
          s.field "when", strprop("the condition, in History QL — the SAME query language and the same fields list_history takes: host: path: url: method: scheme: proto: status: size: reqsize: respsize: dur: header: body: stub:, ~regex on host/path/url/header/body, plus AND/OR/NOT, -negation and (grouping). Matched against the captured flow. CAVEATS, each of which otherwise fails silently: `host:` is a SUBSTRING, not a DNS-label glob, so host:alpha.test also matches xalpha.test; a flow with no response yet has no status, and is painted once the response lands; and `body:` here SCANS rather than reading the trigram index list_history uses, so it reaches binary bodies that index skips, but it reads only the first 64 KiB of each side and reads the bytes AS CAPTURED, so a match past that bound — or inside a gzipped body — is not painted"), required: true
          s.field "color", strprop("red | orange | yellow | green | blue | purple (default yellow) — resolved through the active theme, so it reads correctly on light and dark alike — OR the name of a custom colour (list_custom_colors / create_custom_color), which carries an absolute hex")
          s.field "style", strprop("full (tint the whole History row) | strip (one colour cell in a narrow column ahead of TIME) — default full")
          s.field "name", strprop("optional label for the rule")
          s.field "scope", strprop("project (default) | global — a global rule lives in settings.json and applies in EVERY project")
          s.field "enabled", boolprop("create the rule already enabled (default true)")
        end

        tool j, "update_color_rule",
          "Update an existing Colormarker rule by id. Omitted fields are left unchanged. " \
          "For a global rule this edits the LIBRARY entry, which every project sees; to change " \
          "only this project's on/off answer use set_color_rule_enabled. Display only — a " \
          "colour rule never modifies traffic." do |s|
          s.field "id", intprop("rule id from list_color_rules"), required: true
          s.field "scope", strprop("which id: project (default) | global")
          s.field "when", strprop("new condition (see create_color_rule for the grammar and its caveats)")
          s.field "color", strprop("a built-in (red | orange | yellow | green | blue | purple) or a custom colour's name")
          s.field "style", strprop("full | strip")
          s.field "name", strprop("rule label")
        end

        tool j, "set_color_rule_enabled",
          "Enable or disable a Colormarker rule by id. For a GLOBAL rule this writes THIS " \
          "project's override by default; everywhere=true changes the rule's own default, which " \
          "every project that has not overridden it follows. Setting a global rule back to its " \
          "own default DROPS the override rather than pinning it, so this project keeps " \
          "following later changes to that default." do |s|
          s.field "id", intprop("rule id from list_color_rules"), required: true
          s.field "enabled", boolprop("true to enable, false to disable"), required: true
          s.field "scope", strprop("which id: project (default) | global")
          s.field "everywhere", boolprop("global rules only: change the default for every project instead of this one")
        end

        tool j, "move_color_rule",
          "Move a Colormarker rule one slot up or down in PRECEDENCE order. This changes WHICH " \
          "rule paints a row — the first enabled match wins — so it is a semantic edit, not " \
          "cosmetics. Moves within the rule's own scope only: every global rule resolves " \
          "before every project one, so the boundary is not a position." do |s|
          s.field "id", intprop("rule id from list_color_rules"), required: true
          s.field "direction", strprop("up (higher precedence) | down (lower)"), required: true
          s.field "scope", strprop("which id: project (default) | global")
        end

        tool j, "delete_color_rule",
          "Delete a Colormarker rule by id. Deleting a GLOBAL rule removes it from every " \
          "project, and takes this project's override of it along." do |s|
          s.field "id", intprop("rule id from list_color_rules"), required: true
          s.field "scope", strprop("which id: project (default) | global")
        end

        tool j, "create_custom_color",
          "Define a GLOBAL custom colour the Colormarker picker offers in every project on " \
          "top of the six built-ins. The name is what a rule's `color` references (and must " \
          "not be blank or a built-in word); the hex is an absolute #rrggbb, which does NOT " \
          "track the active theme. Display only — colours never modify traffic." do |s|
          s.field "name", strprop("the colour's name — a rule's `color` value and the picker label; unique, not a built-in word"), required: true
          s.field "hex", strprop("the colour as #rrggbb (or #rgb)"), required: true
        end

        tool j, "update_custom_color",
          "Edit a global custom colour in place, keyed by its CURRENT name. Both `new_name` " \
          "and `hex` are optional and default to the colour's current value, so `hex` alone " \
          "recolours it and `new_name` alone renames it. A RENAME leaves colour rules naming " \
          "the old colour dangling on a visible default (the same trade delete_custom_color " \
          "makes) — recolouring does not, since a rule references a colour by name." do |s|
          s.field "name", strprop("the colour's current name (from list_custom_colors)"), required: true
          s.field "new_name", strprop("rename it to this (default: unchanged); unique, not a built-in word")
          s.field "hex", strprop("recolour it to this #rrggbb (or #rgb) (default: unchanged)")
        end

        tool j, "delete_custom_color",
          "Delete a global custom colour by name. A colour rule that still names it is left " \
          "inert — its rows fall back to a visible default rather than the deletion cascading " \
          "into every project's rules." do |s|
          s.field "name", strprop("the custom colour's name (from list_custom_colors)"), required: true
        end
      end
    end
  end
end
