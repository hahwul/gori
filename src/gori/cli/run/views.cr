# `gori run views` — manage History views (list, add, rm, rename, set, scope).
#
# A view is a named QL query the History list ANDs over its filter bar, the way the ⇧S scope
# lens does; `gori run history --view NAME` is the headless half. Like colour rules they live in
# TWO stores — settings.json (`--scope global`, every project) and this project's `saved_views`
# table (`--scope project`, the default) — and `SavedViews.merged` folds them together.
#
# A view is addressed by NAME here, not by id: it is what `--view` takes, what MCP takes and
# what the picker shows, so an id would be a fourth spelling of one thing. Names are unique
# WITHIN a scope, which is why every mutator also takes `--scope`.
module Gori
  module CLI
    module Run
      @[Subcommand("views", help: [
        {"views", "Manage History views — named QL filters (list, add, rm, rename, set, scope)"},
      ])]
      private def self.cmd_views(args : Array(String)) : Nil
        case sub = args.first?
        when "add"          then cmd_views_add(args[1..])
        when "rm", "delete" then cmd_views_rm(args[1..])
        when "rename"       then cmd_views_rename(args[1..])
        when "set"          then cmd_views_set(args[1..])
        when "scope"        then cmd_views_scope(args[1..])
        when "list"         then cmd_views_list(args[1..])
        when nil            then cmd_views_list(args)
        else
          if verb_token?(sub)
            STDERR.puts "gori run views: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run views [list options] | add <name> --query=QL | rm <name>"
            STDERR.puts "       gori run views rename <name> --to=NAME | set <name> --query=QL"
            STDERR.puts "       gori run views scope <name> --to=project|global"
            exit 1
          else
            cmd_views_list(args)
          end
        end
      end

      # `--scope` on every subcommand: WHICH store the name lives in. Aborts rather than
      # clamping, for the reason `parse_color_scope` states — silently reading "globl" as
      # "project" would report success for an edit the operator meant to make everywhere.
      # The listing's `--scope`, where `builtin` IS a legal answer. Refuses like its mutator
      # twin below rather than clamping: `--scope globl` printing "No views match." reads as
      # "you have no global views", which is the silent-wrong-answer this whole surface argues
      # against.
      private def self.parse_view_list_scope(s : String) : String
        case s.downcase
        when "project", "global", "builtin" then s.downcase
        else                                     abort "gori run views: invalid --scope '#{s}' (builtin|project|global)"
        end
      end

      private def self.parse_view_scope(s : String) : String
        case s.downcase
        when "project" then "project"
        when "global"  then "global"
        else                abort "gori run views: invalid scope '#{s}' (project|global)"
        end
      end

      private def self.cmd_views_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        scope : String? = nil
        format = :text
        leftover = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run views [list] [options]\n\n" \
                     "History views: named QL queries the list narrows to, ANDed over the filter\n" \
                     "bar rather than replacing it. Built-ins come first, then the global library,\n" \
                     "then this project's own. `gori run history --view NAME` applies one."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--scope=SCOPE", "Show only builtin | project | global views") { |v| scope = parse_view_list_scope(v) }
          p.on("--format=FMT", "text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run views: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run views: missing value for #{f}" }
        end
        parser.unknown_args { |before, after| leftover = before + after }
        parser.parse(args)
        refuse_list_leftovers(leftover, "views", "add, rm/delete, rename, set, scope")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project, read_only: true)
        begin
          views = SavedViews.merged(store)
          views = views.select { |v| v.scope == scope } if scope
          active = SavedViews.active(store)
          if format == :json
            puts(JSON.build { |j| j.array { views.each { |v| view_json(j, v, active) } } })
          elsif views.empty?
            puts "No views match."
          else
            w = {views.max_of?(&.name.size) || 4, 4}.max
            views.each { |v| puts view_row(v, active, w) }
          end
        ensure
          store.close
        end
      end

      # `G`/`P`/`·` then `●` for the project's active view — the same two facts the TUI picker
      # answers at a glance, and the same G/P spelling `gori run colormarker` prints.
      #
      # Public (like `colormarker_rule_row`) because the commands themselves end in
      # `abort`/`exit` and cannot be driven from a spec: the printed shape is what an operator
      # reads, so it is what a spec can pin.
      def self.view_row(view : SavedViews::View, active : SavedViews::View?, w : Int32) : String
        mark = (active ? active.key == view.key : view.key == SavedViews.all_view.key) ? "●" : " "
        query = view.narrowing? ? view.query : "(everything — no source term)"
        "#{mark} #{view.badge} #{view.name.ljust(w)}  #{query}"
      end

      # Public for the same reason as the row above.
      def self.view_json(j : JSON::Builder, view : SavedViews::View, active : SavedViews::View?) : Nil
        j.object do
          j.field "name", view.name
          j.field "query", view.query
          j.field "scope", view.scope
          j.field "key", view.key
          j.field "active", active ? active.key == view.key : view.key == SavedViews.all_view.key
        end
      end

      private def self.cmd_views_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        scope = "project"
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run views add <name> --query=QL [options]\n\n" \
                     "--query is a History QL query — the same language the filter bar and\n" \
                     "`gori run history -q` take. It is validated here rather than at apply time:\n" \
                     "a query whose every term drops would narrow NOTHING while a `v:` chip on the\n" \
                     "filter row claims it does."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "The view's query (required)") { |v| query = v }
          p.on("--scope=SCOPE", "project (default) | global — a global view appears in EVERY project") { |v| scope = parse_view_scope(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.missing_option { |f| abort "gori run views add: missing value for #{f}" }
        end
        name = views_one_positional(parser, args, "add", "<name>")
        abort "gori run views add: --query is required" if (q = query).nil?
        views_refuse_bad_name(name, "add")
        views_refuse_bad_query(q, "add")

        with_views_store(project_name, db_path) do |store|
          if SavedViews.name_taken?(store, name, scope)
            abort "gori run views add: a #{scope} view named '#{name}' already exists — use `set` to change its query"
          end
          unless created = SavedViews.add(store, name, q, scope)
            abort "gori run views add: failed to persist the view (#{views_write_hint(scope)})"
          end
          puts scope == "global" ? "Global view '#{created.name}' added — it appears in every project." : "View '#{created.name}' added."
        end
      end

      private def self.cmd_views_rm(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        scope = "project"
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run views rm <name> [--scope=project|global]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--scope=SCOPE", "Which <name>: project (default) | global") { |v| scope = parse_view_scope(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.missing_option { |f| abort "gori run views rm: missing value for #{f}" }
        end
        name = views_one_positional(parser, args, "rm", "<name>")

        with_views_store(project_name, db_path) do |store|
          view = views_find_or_abort(store, name, scope, "rm")
          unless SavedViews.remove(store, view)
            abort "gori run views rm: failed to delete the view (#{views_write_hint(scope)})"
          end
          # A project pointing at this view keeps a `history_view` key naming it. THIS project's
          # is cleared below; another project's stays inert, because ids come from monotonic
          # counters and are never reused — the same reasoning `colormarker rm` records.
          views_clear_active_if(store, view)
          puts scope == "global" ? "Global view '#{view.name}' deleted — from every project." : "View '#{view.name}' deleted."
        end
      end

      private def self.cmd_views_rename(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        scope = "project"
        to : String? = nil
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run views rename <name> --to=NAME [--scope=project|global]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--to=NAME", "The new name (required)") { |v| to = v }
          p.on("--scope=SCOPE", "Which <name>: project (default) | global") { |v| scope = parse_view_scope(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.missing_option { |f| abort "gori run views rename: missing value for #{f}" }
        end
        name = views_one_positional(parser, args, "rename", "<name>")
        abort "gori run views rename: --to is required" if (dest = to).nil?
        views_refuse_bad_name(dest, "rename")

        with_views_store(project_name, db_path) do |store|
          view = views_find_or_abort(store, name, scope, "rename")
          if SavedViews.name_taken?(store, dest, scope, except: view)
            abort "gori run views rename: a #{scope} view named '#{dest}' already exists"
          end
          unless SavedViews.update(store, view, dest, view.query)
            abort "gori run views rename: failed to rename the view (#{views_write_hint(scope)})"
          end
          puts "View '#{view.name}' renamed to '#{dest.strip}'."
        end
      end

      private def self.cmd_views_set(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        scope = "project"
        query : String? = nil
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run views set <name> --query=QL [--scope=project|global]\n\n" \
                     "Replace a view's query, keeping its name."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "The view's new query (required)") { |v| query = v }
          p.on("--scope=SCOPE", "Which <name>: project (default) | global") { |v| scope = parse_view_scope(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.missing_option { |f| abort "gori run views set: missing value for #{f}" }
        end
        name = views_one_positional(parser, args, "set", "<name>")
        abort "gori run views set: --query is required" if (q = query).nil?
        views_refuse_bad_query(q, "set")

        with_views_store(project_name, db_path) do |store|
          view = views_find_or_abort(store, name, scope, "set")
          unless SavedViews.update(store, view, view.name, q)
            abort "gori run views set: failed to update the view (#{views_write_hint(scope)})"
          end
          puts "View '#{view.name}' now matches #{q}."
        end
      end

      # Re-home a view between the two stores. The TUI reaches the same operation by saving an
      # existing name into the other scope; here it is its own verb because a CLI has no filter
      # bar to save FROM.
      private def self.cmd_views_scope(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        from = "project"
        to : String? = nil
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run views scope <name> --to=project|global [--scope=project|global]\n\n" \
                     "Move a view to the other store. A `src:` view belongs in every project; a\n" \
                     "`host:api.acme.test` one belongs in this engagement."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--to=SCOPE", "Destination: project | global (required)") { |v| to = parse_view_scope(v) }
          p.on("--scope=SCOPE", "Which <name>: project (default) | global") { |v| from = parse_view_scope(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.missing_option { |f| abort "gori run views scope: missing value for #{f}" }
        end
        name = views_one_positional(parser, args, "scope", "<name>")
        abort "gori run views scope: --to is required (project|global)" if (dest = to).nil?

        with_views_store(project_name, db_path) do |store|
          view = views_find_or_abort(store, name, from, "scope")
          abort "gori run views scope: '#{view.name}' is already #{dest}" if view.scope == dest
          if SavedViews.name_taken?(store, view.name, dest)
            abort "gori run views scope: a #{dest} view named '#{view.name}' already exists"
          end
          unless moved = SavedViews.set_scope(store, view, dest)
            abort "gori run views scope: failed to move the view (#{views_write_hint(dest)}); it was left where it was"
          end
          # The move minted a new id in the destination store, so a `history_view` key naming
          # the OLD one is now dangling. Re-point it rather than leaving the project to fall
          # back to All on the next open.
          views_repoint_active(store, view, moved)
          puts "View '#{moved.name}' moved to #{dest}."
        end
      end

      # --- shared helpers ---------------------------------------------------------------

      # Exactly one positional, which is the view's name. Both halves of `unknown_args` for the
      # reason the colormarker list does it: a bare word after `--` would otherwise vanish.
      private def self.views_one_positional(parser : OptionParser, args : Array(String),
                                            sub : String, what : String) : String
        positional = [] of String
        parser.unknown_args { |before, after| positional = before + after }
        parser.invalid_option { |f| abort "gori run views #{sub}: unknown option: #{f}" }
        parser.parse(args)
        abort "gori run views #{sub}: missing #{what}" if positional.empty?
        abort "gori run views #{sub}: too many arguments (expected one #{what})" if positional.size > 1
        positional[0]
      end

      # The engine owns what is legal, so the CLI, the TUI and MCP cannot disagree.
      private def self.views_refuse_bad_name(name : String, sub : String) : Nil
        (reason = SavedViews.unusable_name_reason(name)) && abort("gori run views #{sub}: #{reason}")
      end

      private def self.views_refuse_bad_query(query : String, sub : String) : Nil
        (reason = SavedViews.unusable_query_reason(query)) && abort("gori run views #{sub}: #{reason}")
      end

      private def self.views_write_hint(scope : String) : String
        scope == "global" ? "settings not writable" : "project is busy — try again"
      end

      # A global view needs no project at all — it lives in settings.json — but a project is
      # resolved for every subcommand anyway, so `--project` means the same thing throughout and
      # `merged`/`name_taken?` can see both halves.
      private def self.with_views_store(project_name : String?, db_path : String?, &) : Nil
        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          yield store
        ensure
          store.close
        end
      end

      # Resolve BY SCOPE, not through `resolve_by_name` — that one is for `--view`, where the
      # operator names a view and gori picks the most specific. A mutator must touch the one the
      # operator said, so the two stores stay independently addressable.
      private def self.views_find_or_abort(store : Store, name : String, scope : String,
                                           sub : String) : SavedViews::View
        want = name.strip.downcase
        views = SavedViews.merged(store)
        found = views.find { |v| v.scope == scope && v.name.downcase == want }
        return found if found
        # Named BEFORE the cross-scope hint: a built-in does live in "another scope", but
        # `--scope builtin` is not an answer this command takes — nothing can write a view that
        # ships in code — so pointing there would send the operator at a dead end.
        if views.any? { |v| v.builtin? && v.name.downcase == want }
          abort "gori run views #{sub}: '#{name}' is a built-in view — it can't be edited or deleted"
        end
        if views.any? { |v| v.name.downcase == want }
          abort "gori run views #{sub}: no #{scope} view named '#{name}' (it exists in another scope — pass --scope)"
        end
        abort "gori run views #{sub}: no view named '#{name}'"
      end

      private def self.views_clear_active_if(store : Store, view : SavedViews::View) : Nil
        return unless store.setting(SavedViews::ACTIVE_KEY) == view.key
        SavedViews.set_active(store, nil)
      end

      private def self.views_repoint_active(store : Store, from : SavedViews::View,
                                            to : SavedViews::View) : Nil
        return unless store.setting(SavedViews::ACTIVE_KEY) == from.key
        SavedViews.set_active(store, to)
      end
    end
  end
end
