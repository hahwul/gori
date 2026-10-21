require "json"
require "../../store"
require "../../colormarker"
require "../serialize"

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
      @[Tool("list_color_rules")]
      private def list_color_rules(h) : Result
        want = nil.as(Store::RuleScope?)
        if present?(h, "scope")
          sc = rule_scope(h)
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
                rules.each { |r| Serialize.color_rule(j, r) }
              end
            end
          end
        end)
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
        return err("invalid 'style' (expected #{Settings::COLORMARKER_STYLES.join("|")})",
          "INVALID_ARGUMENT", field: "style") unless Settings::COLORMARKER_STYLES.includes?(s.downcase)
        Store::MarkerStyle.from_label(s)
      end

      @[Tool("create_color_rule", gated: true, agent_action: true, permission: "write")]
      private def create_color_rule(h) : Result
        filter = required_str(h, "when", blank: true)
        # The engine owns what is legal, so the TUI form, the CLI and this surface cannot
        # disagree. All three refusals name a rule that would otherwise fail SILENTLY.
        if reason = Gori::Colormarker.unusable_reason(filter)
          return err(reason, "INVALID_ARGUMENT", field: "when")
        end
        scope = rule_scope(h)
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

      @[Tool("update_color_rule", gated: true, agent_action: true, permission: "write")]
      private def update_color_rule(h) : Result
        id = required_id(h, "id")
        scope = rule_scope(h)
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
      @[Tool("set_color_rule_enabled", gated: true, agent_action: true, permission: "write")]
      private def set_color_rule_enabled(h) : Result
        id = required_id(h, "id")
        scope = rule_scope(h)
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

      @[Tool("delete_color_rule", gated: true, agent_action: true, permission: "write")]
      private def delete_color_rule(h) : Result
        id = required_id(h, "id")
        scope = rule_scope(h)
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
        Result.new({id: id, scope: scope.label, deleted: true}.to_json)
      end

      # Reorder within a scope. The scope boundary is not a position: every global rule resolves
      # before every project one, so moving past the end of a block is a scope change.
      @[Tool("move_color_rule", gated: true, agent_action: true, permission: "write")]
      private def move_color_rule(h) : Result
        id = required_id(h, "id")
        scope = rule_scope(h)
        return scope if scope.is_a?(Result)
        dir_s = str(h, "direction")
        dir =
          case dir_s.try(&.downcase)
          when "up"   then -1
          when "down" then 1
          else
            return err("#{dir_s ? "invalid 'direction' #{dir_s.inspect}" : "missing required 'direction'"} " \
                       "(expected #{MOVE_DIRS.join("|")})", "INVALID_ARGUMENT", field: "direction")
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
        Result.new({id: id, scope: scope.label, moved: dir_s}.to_json)
      end

      COLOR_PREVIEW_LIMIT = PageLimit.new(Gori::Colormarker::PREVIEW_SCAN, 5000)

      # How many recent flows a candidate condition would MATCH, and how many it would actually
      # PAINT once the rules that already resolve ahead of it are counted. The second number is
      # the one that answers "will I see this": an earlier enabled rule may already claim the row.
      @[Tool("preview_color_rule")]
      private def preview_color_rule(h) : Result
        filter = required_str(h, "when", blank: true)
        if reason = Gori::Colormarker.unusable_reason(filter)
          return err(reason, "INVALID_ARGUMENT", field: "when")
        end
        # WHICH store the rule would be created in, because that decides which existing rules
        # can claim a row from it: every global rule resolves before every project one, so a
        # project rule is never ahead of a global candidate. Previewing everything as a project
        # rule reported `would_paint: 0` for a global rule that in fact paints every row.
        scope = rule_scope(h)
        return scope if scope.is_a?(Result)
        # Clamp in Int64, THEN narrow: `.to_i` is checked, so clamping after it meant
        # `{"limit": 10000000000}` — the "no limit" number an LLM reaches for — OverflowError'd
        # past the INVALID_ARGUMENT arm at `Tools#call` and came back INTERNAL, telling the
        # agent the server was broken instead of its argument. Still a CLAMP and not
        # `bounded_int_arg`: this argument has always been forgiving at both ends, and `0` is
        # the other spelling of "no limit" an agent reaches for — turning that into a hard
        # INVALID_ARGUMENT would be a second, opposite way to fail the same call. So `0` (or a
        # negative) is read as the ceiling, not floored to a one-flow scan by the shared clamp.
        req = optional_int_arg(h, "limit")
        limit = req && req <= 0 ? COLOR_PREVIEW_LIMIT.max : clamp(req, COLOR_PREVIEW_LIMIT)
        ahead = Gori::Colormarker.rules_ahead(Gori::Colormarker.merged(store), 0_i64, scope)
        pv = Gori::Colormarker.preview(store, filter, ahead, limit)
        Result.new(JSON.build do |j|
          j.object do
            j.field "scope", scope.label
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

      @[Tool("list_custom_colors")]
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

      @[Tool("create_custom_color", gated: true, agent_action: true, permission: "write")]
      private def create_custom_color(h) : Result
        name = required_str(h, "name", blank: true)
        hex = required_str(h, "hex", blank: true)
        # The settings registry is the arbiter of name/hex legality and uniqueness — a non-nil
        # message means it refused, said the same way the CLI and TUI say it.
        if msg = Settings.add_colormarker_color(name, hex)
          return err(msg, "INVALID_ARGUMENT", field: "name")
        end
        norm = Settings.colormarker_colors.find { |c| c.name == name.strip.downcase }
        Result.new({name: norm.try(&.name) || name.strip.downcase, hex: norm.try(&.hex) || hex}.to_json)
      end

      # Edit a custom colour in place. Present because `Settings.update_colormarker_color` had
      # exactly one caller — the TUI's colour editor — so an agent could add and delete a colour
      # but never recolour one, and delete + re-add is NOT the same action: between the two every
      # rule naming the colour, in this project and in every other one, paints a fallback hue.
      #
      # Both editable fields default to the current value, so `hex` alone recolours and
      # `new_name` alone renames. The registry is the arbiter of legality and uniqueness.
      @[Tool("update_custom_color", gated: true, agent_action: true, permission: "write")]
      private def update_custom_color(h) : Result
        name = required_str(h, "name", blank: true)
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

      @[Tool("delete_custom_color", gated: true, agent_action: true, permission: "write")]
      private def delete_custom_color(h) : Result
        name = required_str(h, "name", blank: true)
        key = name.strip.downcase
        return not_found("no custom colour named '#{key}'") unless Settings.colormarker_colors.any? { |c| c.name == key }
        return busy("custom colour NOT deleted (settings not writable)") unless Settings.delete_colormarker_color(key)
        Result.new({name: key, deleted: true}.to_json)
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
          "List Colormarker rules (History row colours, DISPLAY ONLY) in " \
          "PRECEDENCE order, GLOBAL first: the FIRST enabled match paints a row, so order is " \
          "meaning (move_color_rule). id/scope/enabled/default_enabled read as in list_rules." do |s|
          s.field "scope", enumprop("only this store (default: both)", RULE_SCOPES)
        end

        tool j, "preview_color_rule",
          "Count recent flows a colour condition would MATCH and would actually PAINT (an " \
          "earlier enabled rule may claim a row first), WITHOUT creating anything." do |s|
          s.field "when", strprop("condition to test (see create_color_rule)"), required: true
          s.field "scope", enumprop("preview as a rule in this store (default project); global rules " \
                                    "resolve first (`would_paint`)", RULE_SCOPES)
          s.field "limit", limitprop("recent flows to scan", COLOR_PREVIEW_LIMIT)
        end

        tool j, "list_custom_colors",
          "List GLOBAL custom colours: name (a rule's `color`) and absolute hex (NOT theme-aware)." do |_s|
        end

        return unless @allow_actions

        tool j, "create_color_rule",
          "Add a Colormarker rule colouring History rows matching a condition (FIRST enabled match paints)." do |s|
          s.field "when", strprop("History QL, as list_history's query (ql_reference). SILENT CAVEATS: `host:` is a SUBSTRING (host:alpha.test matches xalpha.test); no status until the response lands; with NO scope rules `scope:in`/`scope:out` paint nothing; `body:` scans only the first 64 KiB of each side AS CAPTURED (gzipped bodies miss)"), required: true
          s.field "color", strprop("built-in red, orange, yellow (default), green, blue, purple, or a custom colour's name")
          s.field "style", enumprop("full tints the row; strip paints one cell ahead of TIME (default full)", Settings::COLORMARKER_STYLES)
          s.field "name", strprop("optional label")
          s.field "scope", enumprop("rule store (default project); global = settings.json, EVERY project", RULE_SCOPES)
          s.field "enabled", boolprop("default true")
        end

        tool j, "update_color_rule",
          "Update a Colormarker rule by id; omitted fields unchanged. On a global rule this " \
          "edits the LIBRARY entry (every project)." do |s|
          s.field "id", intprop("rule id"), required: true
          s.field "scope", enumprop("`id`'s store (default project)", RULE_SCOPES)
          s.field "when", strprop("new condition (grammar and caveats: create_color_rule)")
          s.field "color", strprop("built-in or custom colour name")
          s.field "style", enumprop("full row or strip cell", Settings::COLORMARKER_STYLES)
          s.field "name", strprop("label")
        end

        tool j, "set_color_rule_enabled",
          "Enable/disable a Colormarker rule. For a GLOBAL rule this writes THIS project's " \
          "override (matching the default DROPS it); everywhere=true changes the default." do |s|
          s.field "id", intprop("rule id"), required: true
          s.field "enabled", boolprop("new state"), required: true
          s.field "scope", enumprop("`id`'s store (default project)", RULE_SCOPES)
          s.field "everywhere", boolprop("global only: change the default for every project")
        end

        tool j, "move_color_rule",
          "Move a Colormarker rule one slot in PRECEDENCE (changes which rule paints a row). " \
          "Within its own scope only: global rules always precede project ones." do |s|
          s.field "id", intprop("rule id"), required: true
          s.field "direction", enumprop("up raises precedence", MOVE_DIRS), required: true
          s.field "scope", enumprop("`id`'s store (default project)", RULE_SCOPES)
        end

        tool j, "delete_color_rule",
          "Delete a Colormarker rule (a GLOBAL one, with its overrides, everywhere)." do |s|
          s.field "id", intprop("rule id"), required: true
          s.field "scope", enumprop("`id`'s store (default project)", RULE_SCOPES)
        end

        tool j, "create_custom_color",
          "Define a GLOBAL custom colour (absolute hex, NOT theme-aware)." do |s|
          s.field "name", strprop("colour name (a rule's `color`); unique, not blank or a built-in word"), required: true
          s.field "hex", strprop("#rrggbb or #rgb"), required: true
        end

        tool j, "update_custom_color",
          "Edit a global custom colour by its CURRENT name; omitted fields unchanged. A RENAME " \
          "leaves rules naming the old colour on a visible default." do |s|
          s.field "name", strprop("current name (list_custom_colors)"), required: true
          s.field "new_name", strprop("new name; unique, not a built-in word")
          s.field "hex", strprop("new #rrggbb or #rgb")
        end

        tool j, "delete_custom_color",
          "Delete a global custom colour. Rules still naming it stay, inert, on a visible default." do |s|
          s.field "name", strprop("colour name (list_custom_colors)"), required: true
        end
      end
    end
  end
end
