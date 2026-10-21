require "json"
require "../../store"
require "../../saved_views"

module Gori
  module MCP
    class Tools
      # --- History views (#776) ---------------------------------------------------------
      #
      # A view is a named History QL query, applied as a LENS: `list_history{view}` ANDs it over
      # `query` rather than replacing it, exactly as the TUI's `v` picker ANDs it over the filter
      # bar and `gori run history --view` ANDs it over `-q`.
      #
      # Same two-scope model as the colour-rule tools above — a global library in settings.json
      # plus this project's own rows — but addressed by NAME rather than by `{id, scope}`. The
      # name is what `list_history{view}` takes and what the picker shows, so an id would be a
      # second spelling of one thing; `scope` is still carried on every mutation because names
      # are unique only WITHIN a scope.

      # Every view available in this project: the built-ins, then the global library, then the
      # project's own.
      @[Tool("list_views")]
      private def list_views(h) : Result
        want = view_scope_filter(h)
        return want if want.is_a?(Result)
        views = SavedViews.merged(store)
        views = views.select { |v| v.scope == want } if want
        active = SavedViews.active(store)
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", views.size
            j.field "views" do
              j.array do
                views.each do |v|
                  j.object do
                    j.field "name", v.name
                    j.field "query", v.query
                    j.field "scope", v.scope
                    # Which view the TUI is showing this project through. It does NOT apply to
                    # `list_history`, which filters only by the `view` it is passed — a stored
                    # UI preference must never silently drop rows from a headless answer, the
                    # same line `--in-scope` draws against the persisted `s` lens. Reported so an
                    # agent can offer the operator's own scoping, not so it is assumed.
                    j.field "active", active ? active.key == v.key : v.key == SavedViews.all_view.key
                    j.field "editable", !v.builtin?
                  end
                end
              end
            end
          end
        end)
      end

      # The `scope` argument on a MUTATION, defaulting to this project — the safe direction, the
      # same default `create_color_rule` takes. `builtin` is not accepted: it names views that
      # ship in code and no surface can write.
      private def view_write_scope(h) : String | Result
        return "project" unless present?(h, "scope")
        case str(h, "scope").try(&.downcase)
        when "project" then "project"
        when "global"  then "global"
        when "builtin"
          err("built-in views cannot be edited", "INVALID_ARGUMENT", field: "scope")
        else
          # Refused rather than clamped, for the reason `label_arg` states: reading
          # "globl" as "project" would report success for an edit meant for every project.
          err("invalid scope (project | global)", "INVALID_ARGUMENT", field: "scope")
        end
      end

      # The `scope` argument on the LISTING, where `builtin` IS a legal answer and absent means
      # "all three".
      private def view_scope_filter(h) : String? | Result
        return nil unless present?(h, "scope")
        case s = str(h, "scope").try(&.downcase)
        when "project", "global", "builtin" then s
        else                                     err("invalid scope (builtin | project | global)", "INVALID_ARGUMENT", field: "scope")
        end
      end

      # Resolve a view a mutation names, WITHIN the scope it was given. Deliberately not
      # `SavedViews.resolve_by_name` — that one picks the most specific match and is right for
      # `list_history{view}`, where the caller is choosing a lens; a mutator has to touch the one
      # the caller said, or the two stores stop being independently addressable.
      private def find_view(name : String, scope : String) : SavedViews::View | Result
        want = name.strip.downcase
        views = SavedViews.merged(store)
        if found = views.find { |v| v.scope == scope && v.name.downcase == want }
          return found
        end
        # Named BEFORE the cross-scope hint: a built-in does live "in another scope", but telling
        # a caller to pass `scope: builtin` sends them at an answer that does not exist —
        # `view_write_scope` refuses that value, because nothing can write a view that ships in
        # code. Say the real reason instead.
        if views.any? { |v| v.builtin? && v.name.downcase == want }
          return err("#{name.inspect} is a built-in view — it cannot be edited or deleted",
            "INVALID_ARGUMENT", field: "name")
        end
        if views.any? { |v| v.name.downcase == want }
          return not_found("no #{scope} view named #{name.inspect} — it exists in another scope, pass that scope")
        end
        not_found("no view named #{name.inspect}")
      end

      @[Tool("create_view", gated: true, agent_action: true, permission: "write")]
      private def create_view(h) : Result
        name = required_str(h, "name", blank: true)
        query = required_str(h, "query", blank: true)
        scope = view_write_scope(h)
        return scope if scope.is_a?(Result)
        # The engine owns what is legal, so the TUI, the CLI and this surface cannot disagree.
        # Both refusals name a view that would otherwise fail SILENTLY — a query whose every term
        # drops narrows NOTHING while every surface shows a chip claiming it does.
        if bad = unusable_view_fields(name, query, scope)
          return bad
        end
        created = SavedViews.add(store, name, query, scope)
        unless created
          return busy(scope == "global" ? "failed to persist global view (settings not writable)" : "failed to persist view (store busy or unwritable)")
        end
        view_result(created, "created")
      end

      # Rename, re-query, or both. Omitted fields are left unchanged, the same contract
      # `update_color_rule` has.
      @[Tool("update_view", gated: true, agent_action: true, permission: "write")]
      private def update_view(h) : Result
        name = required_str(h, "name", blank: true)
        scope = view_write_scope(h)
        return scope if scope.is_a?(Result)
        found = find_view(name, scope)
        return found if found.is_a?(Result)

        new_name = str(h, "new_name") || found.name
        new_query = str(h, "query") || found.query
        if bad = unusable_view_fields(new_name, new_query, scope, except: found)
          return bad
        end

        # A scope change is a MOVE between two stores, not a field edit, so it is its own path.
        dest = str(h, "new_scope").try(&.downcase)
        if dest && dest != scope
          return move_view(found, new_name, new_query, dest)
        end

        unless SavedViews.update(store, found, new_name, new_query)
          return busy(scope == "global" ? "failed to update global view (settings not writable)" : "failed to update view (store busy or unwritable)")
        end
        view_result(SavedViews::View.new(found.id, new_name, new_query, scope), "updated")
      end

      @[Tool("delete_view", gated: true, agent_action: true, permission: "write")]
      private def delete_view(h) : Result
        name = required_str(h, "name", blank: true)
        scope = view_write_scope(h)
        return scope if scope.is_a?(Result)
        found = find_view(name, scope)
        return found if found.is_a?(Result)
        # THIS project's pointer is kept off it (see `SavedViews.delete`). Only a GLOBAL view can
        # be named from another project, and that pointer stays inert: global ids come from a
        # monotonic counter and are never reused. A project view's id is a rowid and is not.
        warning = nil.as(String?)
        case SavedViews.delete(store, found)
        in SavedViews::DeleteOutcome::NotDeleted
          return busy("failed to reset the project's active view, so the view was NOT deleted (store busy or unwritable); retry")
        in SavedViews::DeleteOutcome::RemoveRefused
          what = scope == "global" ? "failed to delete global view (settings not writable)" : "failed to delete view (store busy or unwritable)"
          return busy("#{what}; if it was the project's active view, that is All now")
        in SavedViews::DeleteOutcome::PointerLeft
          warning = VIEW_POINTER_LEFT
        in SavedViews::DeleteOutcome::Deleted
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "deleted", found.name
            j.field "scope", found.scope
            j.field "warning", warning if warning
          end
        end)
      end

      # The three ways a name/query pair is not writable, as one answer. Shared by create and
      # update so neither can drift from the other, and split out for the complexity bar.
      # `except` exempts the view being edited from its own name check.
      private def unusable_view_fields(name : String, query : String, scope : String, *,
                                       except : SavedViews::View? = nil) : Result?
        # An unchanged name is not being chosen, so it is not re-judged: a view saved before a
        # built-in took its name could otherwise never have its query edited.
        if except.try(&.name) != name && (reason = SavedViews.unusable_name_reason(name))
          return err(reason, "INVALID_ARGUMENT", field: except ? "new_name" : "name")
        end
        if reason = SavedViews.unusable_query_reason(query)
          return err(reason, "INVALID_ARGUMENT", field: "query")
        end
        if SavedViews.name_taken?(store, name, scope, except: except)
          return err("a #{scope} view named #{name.inspect} already exists#{except ? "" : " — use update_view"}",
            "INVALID_ARGUMENT", field: except ? "new_name" : "name")
        end
        nil
      end

      # Re-home a view, carrying the (possibly edited) name and query with it. Split out of
      # `update_view` for the complexity bar, and it reads better apart anyway: everything here
      # is about the two STORES, while the caller is about the fields.
      #
      # Through `SavedViews.set_scope`, which writes the destination first and undoes it if the
      # source will not go — a source removed against a destination write that then failed loses
      # the view outright, while the reverse leaves a duplicate the operator can see and delete.
      private def move_view(view : SavedViews::View, name : String, query : String,
                            dest : String) : Result
        unless dest == "project" || dest == "global"
          return err("invalid new_scope (project | global)", "INVALID_ARGUMENT", field: "new_scope")
        end
        if SavedViews.name_taken?(store, name, dest)
          return err("a #{dest} view named #{name.inspect} already exists",
            "INVALID_ARGUMENT", field: "new_name")
        end
        # Name and query travel WITH the move — see `SavedViews.set_scope`. Writing them as a
        # follow-up edit would insert under the view's old name, which is not the name that was
        # just checked for availability in the destination.
        moved = SavedViews.set_scope(store, view, dest, name, query)
        return busy("failed to move view to #{dest} — it was left where it was") unless moved
        # The move minted a new id in the destination store, so a `history_view` pointer naming
        # the old one is now dangling.
        # The move itself committed, so a refused re-point is a warning on the success, never a
        # retryable error: the same call would now find the view already moved.
        warning = SavedViews.repoint_active_if(store, view, moved) ? nil : MOVE_POINTER_WARNING
        view_result(moved, "moved", warning)
      end

      private VIEW_POINTER_LEFT = "the view was deleted, but another gori made it the project's active view meanwhile " \
                                  "and that pointer could not be reset (store busy or unwritable): it names the deleted " \
                                  "id, which the next project view created can take and turn on"

      private MOVE_POINTER_WARNING = "the view moved, but the project's active view was NOT re-pointed to it " \
                                     "(store busy or unwritable) and still names its old id, which the next " \
                                     "project view created can take and turn on"

      private def view_result(view : SavedViews::View, action : String, warning : String? = nil) : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field action, view.name
            j.field "name", view.name
            j.field "query", view.query
            j.field "scope", view.scope
            j.field "warning", warning if warning
          end
        end)
      end

      # Schema. The `@allow_actions` gate sits INSIDE this method, between the read tool and the
      # write tools, for the reason `list_color_rules_tools` records: a new write tool cannot
      # then be added on the wrong side of it by landing in the wrong place in a long method.
      private def list_saved_views_tools(j : JSON::Builder) : Nil
        tool j, "list_views",
          "List History VIEWS: named History QL queries used as a LENS (list_history{view} ANDs " \
          "one over `query`). Built-ins #{SavedViews::BUILTINS.join(", ", &.name)} first, then GLOBAL " \
          "(settings.json), then the project's. `active` marks only the TUI's current view: " \
          "list_history filters by nothing but the `view` you pass. Names are unique per scope." do |s|
          s.field "scope", enumprop("only this store (default: all three)", VIEW_SCOPES_R)
        end

        return unless @allow_actions

        tool j, "create_view",
          "Save a named History view (a QL query the History list narrows to). The query is " \
          "VALIDATED: one whose every term drops, narrowing nothing, is refused." do |s|
          s.field "name", strprop("view name (list_history{view} addresses it); unique in its scope, not a built-in name"), required: true
          s.field "query", strprop("History QL, same language and fields as list_history's `query`"), required: true
          s.field "scope", enumprop("view store (default project); global = EVERY project", RULE_SCOPES)
        end

        tool j, "update_view",
          "Update a saved view; omitted fields unchanged. Built-ins cannot be edited." do |s|
          s.field "name", strprop("view to update (list_views)"), required: true
          s.field "scope", enumprop("`name`'s store (default project)", RULE_SCOPES)
          s.field "new_name", strprop("rename")
          s.field "query", strprop("new query")
          s.field "new_scope", enumprop("move to the other store", RULE_SCOPES)
        end

        tool j, "delete_view",
          "Delete a saved view (not a built-in). A project looking through it falls back to All." do |s|
          s.field "name", strprop("view to delete"), required: true
          s.field "scope", enumprop("`name`'s store (default project)", RULE_SCOPES)
        end
      end
    end
  end
end
