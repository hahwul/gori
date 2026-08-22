require "./ql"
require "./store"
require "./settings"

module Gori
  # A **view** is a named History query applied as a LENS: it ANDs over whatever is in the
  # filter bar rather than replacing it, exactly the way the ⇧S scope lens does. That is the
  # whole point of the feature (#776) — `src:proxy` stops being a query the operator retypes
  # every session and becomes a mode that survives the next `/`.
  #
  # Three scopes, one record:
  #
  #   * BUILTIN — shipped in code, present in every project, never editable (`BUILTINS`).
  #   * GLOBAL  — settings.json `saved_views.views`, reusable across every project.
  #   * PROJECT — this project's `saved_views` table (schema V18).
  #
  # `merged` folds all three into the runtime list the picker renders and the CLI/MCP resolve
  # names against. The two-scope halves are modelled on `Probe.custom_rules` and
  # `Oast.provider_configs` — same duality, same `"#{scope[0]}_#{id}"` key — and deliberately
  # NOT on `Colormarker.merged`, which additionally carries a per-project enable-override map.
  # A view has no enabled state for a project to disagree about: it is either the one you
  # picked or it is not.
  #
  # There is likewise no `position`/`move`. Colour rules need ordering because order IS their
  # meaning (the first enabled match paints the row); views RESOLVE BY PICK, so order is
  # display-only and is derived here instead of stored.
  module SavedViews
    # The project's active view, as a `View#key`. Lives in the project DB rather than
    # settings.json for the same reason `scope_enabled` does (`Scope::SETTING_ENABLED`): "what
    # am I looking at in THIS engagement" is a property of the engagement, not of the install.
    ACTIVE_KEY = "history_view"

    # A view as every surface sees it, whichever scope it came from.
    #
    # `id` is a String because the three scopes number themselves independently — a builtin
    # carries a token, a global carries its settings id, a project carries its row id — and a
    # single type keeps the picker, the CLI and MCP from each growing a union.
    record View,
      id : String,
      name : String,
      query : String,   # History QL; "" means "no narrowing" (the All builtin)
      scope : String do # "builtin" | "global" | "project"
      # Unique across all three scopes: a project row id and a global settings id can both be
      # 3. Mirrors `Oast::ProviderConfig#key` and `Probe::CustomRule#code`.
      #
      # Split back with `split('_', 2)` — a builtin id may itself contain '_'.
      def key : String
        "#{scope[0]}_#{id}"
      end

      def builtin? : Bool
        scope == "builtin"
      end

      def global? : Bool
        scope == "global"
      end

      def project? : Bool
        scope == "project"
      end

      # The DB row id, when this view is project-scoped (nil otherwise — a global view has no
      # row in this project's database). Mirrors `Oast::ProviderConfig#project_id`.
      def project_id : Int64?
        project? ? id.to_i64? : nil
      end

      # The settings id, when this view is global-scoped.
      def global_id : Int64?
        global? ? id.to_i64? : nil
      end

      # One-character scope badge for a list column: `·` builtin, `G` global, `P` project.
      # The G/P pair is the spelling `gori run colormarker` already prints.
      def badge : String
        case scope
        when "global"  then "G"
        when "project" then "P"
        else                "·"
        end
      end

      # Does narrowing by this view actually change the list? False for All, whose query is
      # empty — which is what lets "All" be an ordinary row rather than a special case.
      def narrowing? : Bool
        !query.blank?
      end
    end

    # The views every project has. `All` is not a special case in the code — it is a view whose
    # query is "", which compiles to `QL::EMPTY`, which `QL.and` folds away — so "clear the
    # view" and "pick a view" are the same code path.
    #
    # Two axes, deliberately kept apart. The SOURCE views answer "is this evidence about the
    # target, or something gori did?"; the PROTOCOL ones answer "which conversation am I
    # reading?". They are not combined — a view named `WebSocket` that quietly also excluded an
    # imported socket would be lying about its own name, and the axes compose for free anyway:
    # a view ANDs over the filter bar, so `History + Repeater` plus a typed `proto:ws` is the
    # intersection without either built-in having to anticipate the other.
    #
    # `History` is `src:proxy` and NOT `-src:gori`: those are different sets. An imported flow
    # is neither traffic gori observed nor traffic gori sent (see `QL.src_cond`), so the
    # negative spelling would quietly pull somebody else's capture into "History".
    #
    # The protocol trio use the BARE spellings (`proto:ws`, not `proto:wss`), which match the
    # cleartext and TLS rows alike — the transport is a separate question from "is this a
    # socket", and `proto:wss` is one keystroke away in the bar for when it is not.
    ALL_ID     = "all"
    DEFAULT_ID = "proxy+repeater"

    BUILTINS = [
      View.new(ALL_ID, "All", "", "builtin"),
      View.new("proxy", "History", "src:proxy", "builtin"),
      View.new(DEFAULT_ID, "History + Repeater", "src:proxy OR src:repeater", "builtin"),
      View.new("ws", "WebSocket", "proto:ws", "builtin"),
      View.new("grpc", "gRPC", "proto:grpc", "builtin"),
      View.new("sse", "SSE", "proto:sse", "builtin"),
      View.new("errors", "Errors", "status:>=400", "builtin"),
    ]

    # The All builtin — what every degraded path lands on. All rather than the DEFAULT, and the
    # difference matters: a view the operator picked has just gone missing, and on a security
    # proxy the safe direction is to hide nothing rather than to quietly apply a different
    # filter they did not choose.
    def self.all_view : View
      BUILTINS[0]
    end

    # What a project looks through before anyone picks anything.
    #
    # `History + Repeater` rather than `All`: the flows gori's own crawler, fuzzer and importer
    # wrote are not evidence about the target, and a default that mixes them into the list is
    # the defect `src:` was added to fix — it just fixes it for people who remember to type the
    # term. Repeater is IN because a resend is the tester's own deliberate act on a real
    # endpoint, and reading its response beside the captured one is the point of the tab.
    #
    # EXCEPT on a project captured before gori recorded provenance, where `src:` matches those
    # rows in neither direction (`QL::CAVEATS`) — so this default would open an old engagement
    # on an empty list, however much traffic it holds. Answered by a single rowid seek, not a
    # scan; see `Store#pre_provenance_flows?`.
    def self.default_view(store : Store) : View
      return all_view if store.pre_provenance_flows?
      BUILTINS.find { |v| v.id == DEFAULT_ID } || all_view
    end

    # Every view available in this project: builtins, then the global library, then this
    # project's own. Global-before-project mirrors `Probe.custom_rules` / `Oast.provider_configs`;
    # here the order is display order only, since selection keys off `key`.
    def self.merged(store : Store) : Array(View)
      out = BUILTINS.dup
      Settings.saved_views.each do |v|
        out << View.new(v.id.to_s, v.name, v.query, "global")
      end
      store.saved_views.each do |v|
        out << View.new(v.id.to_s, v.name, v.query, "project")
      end
      out
    end

    # The view a `key` names, or nil when it no longer exists — a peer may have deleted it, or
    # the key may be a `p_` from a project the operator has since switched away from. Callers
    # must treat nil as "fall back to All and SAY so": a filter silently applied by a view that
    # is gone, or silently dropped, are both worse than a sentence.
    def self.find(store : Store, key : String) : View?
      merged(store).find { |v| v.key == key }
    end

    # Resolve a view by NAME — the address the CLI's `--view` and MCP's `view` take, because a
    # scope-qualified key is not something a person types.
    #
    # Names are unique WITHIN a scope and may collide ACROSS scopes, so precedence is
    # project > global > builtin: the most specific store wins, the same rule
    # `Env.effective_vars` and the host overrides already apply. Case-insensitive, since the
    # name is a label rather than an identifier.
    def self.resolve_by_name(store : Store, name : String) : View?
      want = name.strip.downcase
      return nil if want.empty?
      views = merged(store)
      views.find { |v| v.project? && v.name.downcase == want } ||
        views.find { |v| v.global? && v.name.downcase == want } ||
        views.find { |v| v.builtin? && v.name.downcase == want }
    end

    # Every view name, for an error message that names what IS available rather than only what
    # is not (a refusal an agent cannot act on is a refusal that gets retried verbatim).
    def self.names(store : Store) : Array(String)
      merged(store).map(&.name)
    end

    # --- validation ------------------------------------------------------------------------

    # The longest a view name may be. Long enough for a phrase, short enough that the filter-row
    # chip and the picker's name column stay readable.
    NAME_MAX = 40

    # Why this name cannot be used, or nil when it can. Shared by all three write surfaces so a
    # name the TUI refuses is not one `gori run views add` accepts.
    def self.unusable_name_reason(name : String) : String?
      n = name.strip
      return "enter a name" if n.empty?
      return "name is longer than #{NAME_MAX} characters" if n.size > NAME_MAX
      return "name contains a control character" if control_char?(n)
      # A name that collides with a builtin would be unreachable by `--view`, since resolution
      # prefers the saved one and the operator loses the builtin instead.
      if BUILTINS.any? { |b| b.name.downcase == n.downcase }
        return "#{n.inspect} is a built-in view — pick another name"
      end
      nil
    end

    # Why this query cannot be saved as a view, or nil when it can. The single validator every
    # write path goes through, mirroring `Colormarker.unusable_reason` and
    # `Probe::CustomRule.valid_pattern?`.
    #
    # This has to refuse rather than warn, and the reason is the one `QL.reject_empty?` was
    # written for: a query whose every term was dropped compiles to `QL::EMPTY`, `QL.and` folds
    # `EMPTY` away, and the result is a view that narrows NOTHING while a `v:` chip on the
    # filter row asserts it does. On a security proxy the direction that matters is the one
    # where a list looks filtered and is not.
    #
    # `SCOPE_SHAPE_ONLY` for the same reason Colormarker uses it: whether the project has scope
    # rules right now is not a property of the view being written, and both questions asked here
    # answer identically under either lens.
    def self.unusable_query_reason(query : String) : String?
      return "enter a query" if query.blank?
      return "query contains a control character" if control_char?(query)
      if bad = unknown_fields(query).first?
        return "unknown field `#{bad}:` — see the query language reference"
      end
      if bad = QL.invalid_regex_terms(query).first?
        return "`#{bad}` is not a valid regex — it would match nothing"
      end
      shape = QL.parse(query, fts: false, scope: QL::SCOPE_SHAPE_ONLY)
      return "this query matches every flow — it would narrow nothing" if QL.reject_empty?(query, shape)
      if bad = QL.analyze(query, scope: QL::SCOPE_SHAPE_ONLY).ignored.first?
        return "`#{bad}` is not a value that field takes — it would be dropped, and the view would show more"
      end
      nil
    end

    # A C0 control or DEL anywhere in the string.
    #
    # Both halves of a view are TEXT THAT GETS PRINTED — the name into the `v:` chip, the picker,
    # every toast and `gori run views list`; the query into the picker's detail column and the
    # activation toast. The TUI's grid substitutes a control cell with a space (`Screen::ASCII_CELL`),
    # but a terminal written to directly does not: an ESC in a name emits its own sequence out of
    # `gori run views list`, and a newline breaks that listing's one-line-per-view contract, which
    # is the shape a script reading it depends on.
    #
    # Refused rather than escaped at each of the five print sites, for exactly the reason this
    # validator exists: the TUI's name prompt cannot type a control character, but
    # `gori run views add`, MCP `create_view` and a hand-edited settings.json all can, and a rule
    # only one of the three enforces is not a rule. Existing rows are left alone — the tolerant
    # parsers keep them loadable, so this narrows what can be WRITTEN, not what can be read.
    private def self.control_char?(s : String) : Bool
      s.each_char.any? { |c| c.ord < 0x20 || c.ord == 0x7f }
    end

    # Field names a view's query uses that QL does not know. `QL.known_field?` rather than
    # `QL::FIELDS.includes?` for the reason `Colormarker.unknown_fields` spells out: FIELDS is
    # the pool a surface OFFERS, and QL compiles spellings it does not offer (`res.body`,
    # `req.size`).
    def self.unknown_fields(query : String) : Array(String)
      QL.fields_used(query).map(&.name).uniq!.reject! { |n| QL.known_field?(n) }
    end

    # --- applying --------------------------------------------------------------------------

    # The view's contribution to a History search, or `QL::EMPTY` when it narrows nothing.
    #
    # `scope:` is threaded in for the same reason `HistoryView#reload` threads it into the bar's
    # parse: a `scope:in` term inside a view has to mean what `scope:in` means when typed, or
    # the same words answer two questions depending on where they were written.
    #
    # A view whose query compiles to EMPTY is REFUSED here, not applied — `unusable_query_reason`
    # guards every write path, but a view can still reach this from a peer's settings.json or a
    # hand edit, and applying it would silently un-filter the list. nil = "this view is broken";
    # the caller shows an empty list and says why, the way `reload` already does for the bar.
    def self.filter(view : View?, *, fts : Bool = true, scope : QL::ScopeLens? = nil) : QL::Filter?
      return QL::EMPTY unless view && view.narrowing?
      f = QL.parse(view.query, fts: fts, scope: scope)
      QL.reject_empty?(view.query, f) ? nil : f
    end

    # --- the active view -------------------------------------------------------------------

    # This project's active view. Falls back to `default_view` for an absent key — nobody has
    # chosen yet — and returns nil for a key that no longer resolves, so the caller can tell "no
    # view" from "the view you had is gone" and say the second one out loud.
    def self.active(store : Store) : View?
      key = store.setting(ACTIVE_KEY)
      return default_view(store) if key.nil? || key.empty?
      find(store, key)
    end

    # Persist the active view. Returns whether the write committed — the same contract every
    # project mutator here has.
    #
    # nil means All, and it is written EXPLICITLY (`b_all`) rather than by clearing the key:
    # an absent key means "nobody has chosen", which `default_view` answers with a narrowing
    # view. A caller that lands here has chosen — or has had a choice taken away — and either
    # way must not be handed a filter on the next open.
    def self.set_active(store : Store, view : View?) : Bool
      v = view || all_view
      store.set_setting(ACTIVE_KEY, v.key)
    end

    # --- scope-aware CRUD --------------------------------------------------------------------
    # Each dispatches on the {id, scope} pair the key carries, so no caller needs to know which
    # of the two stores a view lives in. Every answer is a COMMIT answer: false/0 means the
    # write did not reach disk and the caller must not report it as applied.

    # Add a view to `scope` ("global" | "project"). Returns the new view, or nil when the write
    # did not commit.
    def self.add(store : Store, name : String, query : String, scope : String) : View?
      n = name.strip
      if scope == "global"
        id = Settings.add_saved_view(n, query)
        id.zero? ? nil : View.new(id.to_s, n, query, "global")
      else
        id = store.insert_saved_view(n, query)
        id.zero? ? nil : View.new(id.to_s, n, query, "project")
      end
    end

    def self.update(store : Store, view : View, name : String, query : String) : Bool
      return false if view.builtin?
      n = name.strip
      if view.global?
        (gid = view.global_id) ? Settings.update_saved_view(gid, n, query) : false
      else
        (pid = view.project_id) ? store.update_saved_view(pid, n, query) : false
      end
    end

    def self.remove(store : Store, view : View) : Bool
      return false if view.builtin?
      if view.global?
        (gid = view.global_id) ? Settings.delete_saved_view(gid) : false
      else
        (pid = view.project_id) ? store.delete_saved_view(pid) : false
      end
    end

    # Re-home a view to the other scope, optionally under a new name/query. DESTINATION FIRST,
    # then remove the source — the order `Colormarker#set_scope` established, and for the same
    # reason: a source removed against a destination write that then fails loses the view
    # outright, while the reverse leaves a duplicate the operator can see and delete.
    #
    # `name`/`query` are applied AS PART OF the destination write rather than as an edit
    # afterwards. A move-and-rename that inserted under the OLD name first would be checked for
    # availability under one name and written under another — which the project store answers
    # with a dropped write (UNIQUE) and settings.json, which enforces nothing, answers with two
    # global views sharing a name that `resolve_by_name` then picks between forever.
    #
    # Returns the moved view, or nil when either half refused (the source is left intact).
    def self.set_scope(store : Store, view : View, dest : String,
                       name : String = view.name, query : String = view.query) : View?
      return nil if view.builtin? || view.scope == dest
      moved = add(store, name, query, dest)
      return nil unless moved
      unless remove(store, view)
        # The destination copy committed and the source did not go. Undo the copy rather than
        # leave two views with one name in two scopes, where `resolve_by_name` would silently
        # prefer one of them forever.
        remove(store, moved)
        return nil
      end
      moved
    end

    # Whether `name` is already taken in `scope`. Checked before a write at every surface, since
    # neither store can express "unique within this scope" for the settings half.
    def self.name_taken?(store : Store, name : String, scope : String, except : View? = nil) : Bool
      want = name.strip.downcase
      merged(store).any? do |v|
        v.scope == scope && v.name.downcase == want && v.key != except.try(&.key)
      end
    end
  end
end
