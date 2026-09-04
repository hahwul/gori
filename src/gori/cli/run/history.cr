# `gori run history` (alias ls) and `gori run show <id>` — list / QL-query captured
# flows, and print one flow's request/response (text, json, raw bytes, or HAR).
module Gori
  module CLI
    module Run
      # `delete`/`clear`/`show` are reserved as the first positional (same convention as
      # `gori run probe`); a QL query starting with one goes through --query. `history show
      # <id>` is the top-level `gori run show <id>`, spelled the way the History tab reads.
      private def self.cmd_history(args : Array(String)) : Nil
        case args.first?
        when "delete", "rm" then cmd_history_delete(args[1..])
        when "clear"        then cmd_history_clear(args[1..])
        when "show"         then cmd_show(args[1..])
        else                     cmd_history_list(args)
        end
      end

      # Hard-delete captured flows: ONE by id, or EVERY flow a QL query names.
      #
      # The id form is single and explicit, so it needs no extra confirmation. The `-q` form
      # is not: the operator typed a QUERY and the set it names is whatever the store says it
      # is, which is why it requires --yes exactly as `clear` does — without it we print the
      # count and refuse, so the query can be tried before it is run.
      #
      # Neither an id nor `-q` is refused rather than treated as "all": that command is
      # `history clear --yes`, and a delete that quietly widened to the whole project because
      # an argument went missing from a script is the one failure this file must not have.
      private def self.cmd_history_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        yes = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run history delete <id>\n" \
                     "       gori run history delete -q QL --yes\n\n" \
                     "Hard-delete one captured flow, or every flow a QL query matches. " \
                     "This can't be undone."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Delete every flow matching this QL query (host: status:>=500 method: …)") { |v| query = v }
          p.on("--yes", "Actually delete the query's matches (required — there is no interactive prompt here)") { yes = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run history delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run history delete: missing value for #{f}" }
        end
        # Same two pre-passes the listing runs, for the same reason: `-q` with a separate
        # value, and QL negation terms ("-status:200"), which OptionParser would otherwise
        # abort as unknown options before they could join the query.
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        query, dropped = Run.compose_history_query(query, [] of String, neg_terms)
        Run.warn_dropped_query_terms("history delete", dropped)

        if err = delete_selector_error(positional, query)
          abort "gori run history delete: #{err}"
        end
        if q = query
          delete_by_query(q, yes, project_name, db_path)
        else
          delete_by_id(positional, project_name, db_path)
        end
      end

      # Why this invocation names no deletable set, or nil when it names exactly one.
      #
      # "Neither" is a refusal and not a synonym for "all": that command is
      # `history clear --yes`, and a delete that quietly widened to the whole project because
      # an argument went missing from a script is the one failure this file must not have.
      # "Both" is a refusal because the two selectors disagree about scope and there is no
      # reading of the pair that is obviously what was meant — an id is one flow, a query is
      # however many match.
      private def self.delete_selector_error(positional : Array(String), query : String?) : String?
        if q = query
          return nil if positional.empty?
          "name a flow id OR a -q query, not both (got the id#{positional.size == 1 ? "" : "s"} " \
          "#{positional.join(" ").inspect} beside #{q.inspect})"
        else
          return nil unless positional.empty?
          "nothing selected — give a flow id, or -q QL to delete every match. " \
          "To delete EVERY flow: `gori run history clear --yes`"
        end
      end

      # `history delete <id>` — the single, explicit form.
      private def self.delete_by_id(positional : Array(String), project_name : String?,
                                    db_path : String?) : Nil
        # `take_flow_id`, not a hand-rolled `first?`: it supplies the too-many-arguments abort
        # this one path was missing, so `history delete 1 2 3` no longer deletes ONLY flow #1
        # and exits 0 with nothing said about #2 and #3. The TUI has multi-select delete and the
        # store exposes `delete_flows`, so trying the list form is natural — and an operator who
        # believes three captures are gone when two are still on disk has been told a lie by a
        # destructive command. Every sibling id-taking delete (project, scope, env,
        # host-override, `history show`) already goes through this helper.
        id = take_flow_id(positional, "history delete")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          # flow_row is the row-only read; get_flow would materialize both BLOBs to answer
          # "does this exist?" — a 40 MB response would be read and discarded.
          abort "gori run history delete: no flow with id #{id}" unless store.flow_row(id)
          abort "gori run history delete: flow ##{id} NOT deleted (project busy) — try again" unless store.delete_flow(id)
          puts "Flow ##{id} deleted."
        ensure
          store.close
        end
      end

      # `history delete -q QL [--yes]` — every flow the query names.
      private def self.delete_by_query(q : String, yes : Bool, project_name : String?,
                                       db_path : String?) : Nil
        # BEFORE the store is opened, so a refusal costs nothing and cannot be confused with
        # a store error. The listing only WARNS about these; a delete must not.
        if err = delete_query_error(q)
          abort "gori run history delete: #{err}"
        end

        store = open_store(resolve_read_project(project_name, db_path))
        # Compiled only now, because a `scope:` term needs the project's scope rules and they
        # live in the store this just opened. The shape checks above stay where they are: they
        # answer identically under either lens (see `QL::SCOPE_SHAPE_ONLY`), and a refusal that
        # costs no store open is worth keeping.
        lens = Scope.ql_lens(store)
        if err = delete_scope_error(q, lens)
          store.close
          abort "gori run history delete: #{err}"
        end
        filter = QL.parse(q, scope: lens)
        # A `body:`/free-text delete drains the trigram index first, because an under-reporting
        # query here means SILENTLY SPARING flows the operator asked to delete — and refuses the
        # whole delete when the drain did not finish. Under-deleting while printing a count is
        # the one direction this command cannot degrade in.
        if err = fts_backlog_error(store, filter,
             "#{q.inspect} cannot see all of them and this delete would silently spare some. " \
             "NOTHING was deleted;")
          store.close
          abort "gori run history delete: #{err}"
        end
        ids = begin
          matching_flow_ids(store, filter)
        rescue ex
          store.close
          abort "gori run history delete: query #{q.inspect} failed: #{ex.message}"
        end

        begin
          if ids.empty?
            STDERR.puts "gori run history delete: no flows match #{q.inspect} — nothing deleted"
            return
          end
          if err = delete_confirmation_error(q, ids.size, yes)
            abort "gori run history delete: #{err}"
          end
          deleted = 0
          # Batched, not one transaction for the whole match set: a query can name every flow
          # in the project, and `clear` is the command for that. Each chunk that commits is
          # counted, so a mid-run failure reports what actually went rather than all-or-nothing.
          ids.each_slice(DELETE_BATCH) do |chunk|
            unless store.delete_flows(chunk)
              abort "gori run history delete: stopped after #{deleted} flow#{deleted == 1 ? "" : "s"} " \
                    "(project busy) — the rest are still there; re-run to continue"
            end
            deleted += chunk.size
          end
          puts "Deleted #{deleted} flow#{deleted == 1 ? "" : "s"} matching #{q.inspect}."
        ensure
          store.close
        end
      end

      # The refusal a `-q` delete owes an operator whose query asks about a scope the project does
      # not have — the one guard that cannot be part of `delete_query_error`, because it needs the
      # store that guard deliberately runs before opening.
      #
      # `scope:in` there compiles to a never-match and would delete nothing, which is harmless.
      # `-scope:in` is that never-match NEGATED, which is EVERY flow, and it passes every other
      # guard: the match-all test compares the compiled SQL against `1`, and `NOT (0)` is not
      # that string. So a project's whole history could go over a term that had nothing to answer
      # with. Refused rather than narrowed, because which of the two the operator meant is not
      # knowable from here — and this is the command that cannot be undone.
      private def self.delete_scope_error(q : String, lens : QL::ScopeLens) : String?
        return nil unless QL.uses_scope?(q) && !lens.configured?
        "query #{q.inspect} asks about scope, but this project has NO scope rules — nothing is in " \
        "scope, so a scope term matches nothing and a NEGATED one matches every flow. " \
        "Add scope rules (`gori run project scope add`) or drop the term."
      end

      # The refusal a `-q` delete owes an operator who did not pass --yes, or nil when they did.
      # Separate from the delete itself so the COUNT is in the sentence: the whole point of the
      # gate is that the query can be tried before it is run, and "refusing to delete 4812
      # flows" is the number that stops a hand from moving. Mirrors `history clear`'s gate,
      # which is the same decision one scope wider.
      private def self.delete_confirmation_error(q : String, count : Int32, yes : Bool) : String?
        return nil if yes
        "refusing to delete #{count} flow#{count == 1 ? "" : "s"} matching #{q.inspect} without --yes"
      end

      # Drain the off-commit trigram index for a `body:`/free-text query, and return the refusal
      # the operator is owed when the drain did not finish — nil when the query is safe to run
      # (including every query that never touches the index at all).
      #
      # Trigram indexing runs off the capture commit (Store V4), so draining is what makes a
      # one-shot answer exact instead of "whatever happened to be indexed". `drain_fts!`, not
      # a bare `index_pending!`: that one reports a batch that lost SQLite's single writer slot
      # to a capturing peer as "0 indexed" and returns NORMALLY with rows still dirty, so every
      # caller read it as success and printed a short answer with no marker on it. `drain_fts!`
      # answers what is still dirty and RETRIES a contended attempt first, which is what keeps
      # this from refusing a query for a collision that was over a millisecond later.
      #
      # `consequence` is the caller's own sentence for what a partial index would do to ITS
      # answer — a listing omits rows, a delete spares flows, a tree loses endpoints, and those
      # are three different things to be warned about. The head is shared so the cause is worded
      # once. Lives in this file, with the other `*_error` guards, because two of its three call
      # sites are here; `cmd_sitemap_tree` is the third (same `Run` module).
      private def self.fts_backlog_error(store : Store, filter : QL::Filter,
                                         consequence : String) : String?
        return nil unless filter.uses_fts?
        pending = store.drain_fts!
        return nil if pending.zero?
        "#{pending} flow#{pending == 1 ? "" : "s"} could not be indexed for free-text search " \
        "(this project's writer is busy — another gori is capturing it), so #{consequence} " \
        "Retry in a moment."
      end

      # Flows per delete transaction. Big enough that a routine cleanup is one or two fsyncs,
      # small enough that "delete everything on this host" doesn't build one transaction the
      # size of the project (P6 — never stall the data path; live capture shares this writer).
      DELETE_BATCH = 500

      # Rows are paged, not fetched with one enormous LIMIT, for the same reason the delete is
      # batched: the match set is the operator's to choose and can be the whole table. Only the
      # ids are kept — a `FlowRow` per match would be the projection of every row in the project
      # held at once, and nothing here reads a field off them.
      #
      # `before_id` (not OFFSET) is the cursor: it is stable while live capture appends, and
      # nothing is deleted until the whole set is known, so no page can shift under the walk.
      private def self.matching_flow_ids(store : Store, filter : QL::Filter) : Array(Int64)
        ids = [] of Int64
        cursor : Int64? = nil
        loop do
          page = store.search(filter, DELETE_BATCH, before_id: cursor, raise_on_error: true)
          break if page.empty?
          page.each { |r| ids << r.id }
          break if page.size < DELETE_BATCH
          cursor = page.last.id
        end
        ids
      end

      # Why a `history delete -q` query must not be run, or nil when it is safe to.
      #
      # The listing WARNS about these and carries on, which is right there: a broader or
      # narrower result set on screen costs a second look. Here the same query is a
      # destructive SELECTOR, so each one is a refusal instead — and they point in opposite
      # directions, which is why none of them can be left to the operator to notice:
      #
      #   * an unknown field (`methd:GET`, a typo of `method:`) is not dropped and is not an
      #     error — BOTH compilers free-text the whole token, so it becomes a literal
      #     substring search over method/host/target. The delete then quietly matches
      #     NOTHING and exits 0, against a query the operator believes they ran. Nothing in
      #     `analyze` reports it (the term compiled — to the wrong thing), which is why this
      #     check is `QL.fields_used` + `QL.known_field?`, the same pair
      #     `Colormarker.unknown_fields` refuses a colour rule with.
      #   * an invalid regex compiles to a never-match clause: silently nothing, again.
      #   * a term QL DROPS (`status:>=foo`, `proto:zzz`) folds out of an AND-chain, so the
      #     delete is BROADER than what was typed — and a query that is ONLY such a term
      #     collapses to the match-all filter, i.e. every flow in the project.
      #
      # Ordered worst-consequence-first among the ones a single query can trip together, so
      # the sentence the operator reads names the thing that would actually have happened.
      private def self.delete_query_error(q : String) : String?
        return "empty -q query — to delete EVERY flow use `gori run history clear --yes`" if q.strip.empty?
        # `known_field?`, not `QL::FIELDS.includes?`: FIELDS is the pool the surfaces OFFER,
        # and QL accepts spellings it does not offer (`res.body`, `req.size` — FIELD_ALIASES).
        unknown = QL.fields_used(q).map(&.name).uniq!.reject! { |n| QL.known_field?(n) }
        unless unknown.empty?
          return "unknown field#{unknown.size == 1 ? "" : "s"} #{unknown.map { |n| "`#{n}:`" }.join(", ")} — " \
                 "QL free-texts a field it does not know (or drops it, under a `req.`/`resp.` prefix), " \
                 "so this would delete something other than what the query says " \
                 "(fields: #{QL::FIELDS.join(" ")})"
        end
        unless (bad = QL.invalid_regex_terms(q)).empty?
          return "invalid regex in #{bad.map(&.inspect).join(", ")} — that term matches nothing, " \
                 "so this would delete nothing while reporting a query that ran"
        end
        # Compiled the way the delete compiles it, so what is judged match-all is what would RUN.
        # BEFORE the dropped-term check, so a query whose EVERY term was dropped names the worse
        # consequence: it selects the whole project, not merely one term fewer.
        #
        # `SCOPE_SHAPE_ONLY` because the real lens lives in a store this guard runs before
        # opening, and the two answer identically for every question asked here. Without it a
        # `scope:` term reads as DROPPED, so `scope:in` folded to match-all and this refused
        # `delete -q scope:in` — on a project whose scope rules would have answered it perfectly
        # — with "matches EVERY flow". What no lens can catch is `-scope:in` on a project with no
        # rules, which really IS every flow; `delete_scope_error` has it, once there is a store.
        if QL.reject_empty?(q, QL.parse(q, scope: QL::SCOPE_SHAPE_ONLY))
          return "query #{q.inspect} matches EVERY flow — to delete every flow use `gori run history clear --yes`"
        end
        unless (dropped = QL.analyze(q, scope: QL::SCOPE_SHAPE_ONLY).ignored).empty?
          return "#{dropped.map(&.inspect).join(", ")} is not a value that field takes — QL drops what " \
                 "it cannot compile, so this would delete MORE than the query asks for"
        end
        nil
      end

      # Wipe EVERY captured flow in the project. The TUI puts a danger confirm in front of
      # this; headless, --yes is that confirm — without it we print the count and refuse, so
      # a mistyped command can't empty a capture session.
      private def self.cmd_history_clear(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        yes = false
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run history clear --yes\n\n" \
                     "Delete ALL captured flows in the project. This can't be undone."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--yes", "Actually do it (required — there is no interactive prompt here)") { yes = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run history clear: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run history clear: missing value for #{f}" }
        end
        parser.parse(args)
        unless leftover.empty?
          abort "gori run history clear: unexpected argument#{leftover.size == 1 ? "" : "s"} " \
                "#{leftover.join(" ").inspect} — this deletes ALL flows, not those ids. " \
                "To delete one flow: `gori run history delete <id>`"
        end

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          n = store.count?
          abort "gori run history clear: could not count the flows (project busy) — nothing deleted" unless n
          unless yes
            abort "gori run history clear: refusing to delete #{n} flow#{n == 1 ? "" : "s"} without --yes"
          end
          abort "gori run history clear: NOT cleared (project busy) — every flow is still there" unless store.clear_flows
          puts "Deleted #{n} flow#{n == 1 ? "" : "s"}."
        ensure
          store.close
        end
      end

      private def self.cmd_history_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        limit = 50
        format = :text
        lenient = false
        in_scope = false
        view_name : String? = nil
        column_specs = [] of String
        no_columns = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run history [QL query] [options]   (alias: ls)\n\n" \
                     "Subcommands: history show <id> · history delete <id> · history clear --yes"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Filter with a QL query (host: status:>=500 size:>10000 dur:>500 header: body~rx …)") { |v| query = v }
          p.on("-nN", "--limit=N", "Max rows, newest first (default 50)") { |v| limit = parse_count(v, "--limit") }
          p.on("--view=NAME", "Apply a saved History view — ANDed with -q, like the TUI's `v` picker (see `gori run views`)") { |v| view_name = v }
          p.on("--in-scope", "Only flows in the project's configured scope (the TUI's ⇧S lens; capture still records everything)") { in_scope = true }
          p.on("--lenient", "Don't refuse a query naming an unknown field — search that token as text (old behaviour)") { lenient = true }
          p.on("--column=SPEC", "Show an extracted value per row: [LABEL=][req|res:]kind:selector — e.g. header:x-request-id, RID=jsonpath:data.id, position:0:32 (repeatable; replaces this project's configured History columns)") { |v| column_specs << v }
          p.on("--no-columns", "Don't draw this project's configured History columns (see the TUI's Columns… on the History tab)") { no_columns = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl (both emit JSON-Lines) | har (one HAR 1.2 log)") do |v|
            format = parse_format(v, [:text, :json, :jsonl, :har])
            format = :json if format == :jsonl # this listing's json IS JSON-Lines; accept the standard name too
          end
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run history: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run history: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        # `--project=X delete 42` lands here because the dispatcher keys on args.first?.
        # `delete` is not QL; it is the discarded verb. Refuse it rather than search
        # for the free-text "delete 42" and exit 0 with the flow still on disk.
        if err = Run.reserved_query_verb_error(positional, "history",
             ["delete", "rm", "clear", "show"], "delete/rm, clear, show")
          abort err
        end
        # Accept a positional QL too ("gori run history status:404" / "-status:404"),
        # mirroring the TUI's `/` bar — otherwise a positional query was silently dropped
        # and EVERY flow dumped.
        query, dropped = Run.compose_history_query(query, positional, neg_terms)
        Run.warn_dropped_query_terms("history", dropped)
        # BEFORE the store is opened: `abort` skips ensure blocks, so a refused query must not
        # leave a handle behind (the EMPTY-filter abort below has to `store.close` for exactly
        # that reason, and this one has nothing to close).
        Run.refuse_unknown_query_fields("history", query, lenient)
        # BEFORE the store is opened, for the same reason the query refusal above is: `abort`
        # skips ensure blocks, so a refused `--column` must not leave a handle behind.
        # Refused, not resolved by declaration order: the two flags state opposite intentions,
        # and this command aborts on an unknown query field and on a malformed `--column` spec
        # one line down rather than picking one reading of a contradictory command line.
        if !column_specs.empty? && no_columns
          abort "gori run history: --column and --no-columns contradict each other — pass one"
        end
        ad_hoc = DisplayColumns.parse_specs(column_specs)
        abort "gori run history: #{ad_hoc}" if ad_hoc.is_a?(String)

        # `body:` drains FTS, which is a write. Everything else is a read (#752).
        #
        # A `--view` forces the writable open even when `-q` needs nothing: the view's own query
        # can contain `body:`, and it is not knowable until the store is open (a PROJECT view
        # lives in this database). Opening read-only and discovering that afterwards would leave
        # the listing silently short of whatever the off-commit index had not caught up on —
        # exactly what `fts_backlog_error` refuses to let a one-shot answer do.
        store = open_store(resolve_read_project(project_name, db_path),
          read_only: !query_uses_fts?(query) && view_name.nil?)
        begin
          # The scope lens, opt-in and independent of the persisted ⇧S flag — the same per-flow
          # include/exclude filter the TUI History lens applies, so `--in-scope` here shows the
          # same set. Capture is untouched; this narrows only the VIEW. Empty (nothing in scope)
          # when no scope rules are configured, matching `sitemap --in-scope`.
          # The `scope:` lens is read whether or not `--in-scope` was passed: the flag is a lens
          # over the whole listing, the term is one clause of the query, and an operator can ask
          # for either or both. Hoisted out of the query branch below so the VIEW compiles under
          # the same lens the bar does — a `scope:in` written inside a view has to mean what
          # `scope:in` means when typed.
          lens = Scope.ql_lens(store)

          # `--view NAME`: a saved query ANDed over everything else, exactly as the TUI's `v`
          # picker ANDs it over the filter bar. Resolved project > global > builtin, the same
          # precedence `SavedViews.resolve_by_name` gives every surface.
          view_filter = QL::EMPTY
          # The RESOLVED name of a view that actually narrowed, for the empty-listing message
          # below. Resolved rather than as-typed (`--view errors` is the `Errors` view), and nil
          # for `All`, whose query is empty: naming a lens that excluded nothing would send an
          # operator looking at a view for an answer the view had no part in.
          view_label : String? = nil
          if vn = view_name
            unless view = SavedViews.resolve_by_name(store, vn)
              known = SavedViews.names(store).join(", ")
              store.close
              abort "gori run history: no view named #{vn.inspect} (known: #{known})"
            end
            # A view whose query compiles to nothing is REFUSED, not applied. `QL.and` folds an
            # EMPTY side away, so applying it would list EVERY flow while the command line says
            # a view is narrowing — the same failure the query refusal below exists to stop.
            unless f = SavedViews.filter(view, scope: lens)
              store.close
              abort "gori run history: view #{view.name.inspect} is not a usable query (#{view.query.inspect}) — fix it with `gori run views set`"
            end
            view_filter = f
            view_label = view.name if view.narrowing?
          end

          scope_unconfigured = false
          scope_filter = QL::EMPTY
          if in_scope
            scope = Scope.load(store)
            if scope.configured?
              scope_filter = scope.filter(force: true)
            else
              STDERR.puts "gori run history: --in-scope, but no scope rules are configured — nothing is in scope"
              scope_unconfigured = true
            end
          end
          rows =
            if scope_unconfigured
              [] of Store::FlowRow
            elsif q = query
              filter = QL.parse(q, scope: lens)
              Run.warn_query_terms("history", q)
              # Two states where a `scope:` query runs CLEAN and lists nothing; an empty listing
              # cannot say which. Worded once, in `Run`, so the next surface to want them cannot
              # word them differently.
              Run.scope_query_notes(q, lens, in_scope).each { |n| STDERR.puts "gori run history: #{n}" }
              # A query that fails to compile to ANY clause (e.g. `status:>=foo`)
              # yields the match-all EMPTY filter — silently dumping every flow,
              # the opposite of what the user asked. Refuse it instead.
              if !q.strip.empty? && filter == QL::EMPTY
                store.close
                abort "gori run history: query #{q.inspect} did not match any field (check syntax, e.g. status:>=500 host:example.com method:POST)"
              end
              combined = QL.and(QL.and(scope_filter, view_filter), filter)
              # Trigram indexing is off-commit (Store V4), so a `body:`/free-text query run
              # right after a capture — or against a db a killed process left behind — would
              # under-report until the backlog drains. A one-shot answer must be exact, so
              # wait for it here rather than silently returning fewer rows.
              #
              # And a drain that did not FINISH is a refusal, not a short listing: see
              # `fts_backlog_error`. Refused rather than warned, because this listing IS the
              # answer — a caveat on STDERR is gone the moment the rows are piped to a file.
              if err = fts_backlog_error(store, combined,
                   "#{q.inspect} would silently omit them. Nothing was listed;")
                store.close
                abort "gori run history: #{err}"
              end
              begin
                store.search(combined, limit, raise_on_error: true)
              rescue ex
                store.close
                abort "gori run history: query #{q.inspect} failed: #{ex.message}"
              end
            elsif in_scope || view_filter != QL::EMPTY
              # `view_filter` belongs in this condition and not only in the AND above: without
              # it a `--view` with no `-q` and no `--in-scope` falls through to `recent_flows`,
              # which takes no filter at all — the command would accept the view and list
              # everything.
              combined = QL.and(scope_filter, view_filter)
              # Same drain-or-refuse the query branch runs, for the same reason: a view is free
              # to use `body:`, and this listing IS the answer.
              if err = fts_backlog_error(store, combined,
                   "the #{view_name.inspect} view would silently omit them. Nothing was listed;")
                store.close
                abort "gori run history: #{err}"
              end
              # Same rescue the query branch has: a view can hold a regex or an OR chain that
              # PARSES but SQLite still refuses to run (hand-edited settings.json, a peer's
              # write), and a raw Crystal backtrace is not an answer an operator can act on.
              begin
                store.search(combined, limit, raise_on_error: true)
              rescue ex
                store.close
                abort "gori run history: view #{view_name.inspect} failed: #{ex.message}"
              end
            else
              store.recent_flows(limit)
            end
          # Ad-hoc `--column` specs REPLACE the project's set rather than adding to it: the flag
          # is the operator saying "this listing, these values", and a set half-configured in
          # the TUI and half on the command line is a row whose meaning depends on a file the
          # reader of the output cannot see.
          columns =
            if !ad_hoc.empty?
              ad_hoc.map_with_index { |sp, i| sp.to_column(i) }
            elsif no_columns
              [] of Store::DisplayColumn
            else
              # The project's configured set by DEFAULT, so a headless listing shows what the
              # TUI's History tab shows — which is the whole of the parity ask. `--no-columns`
              # is the way back to the plain listing.
              DisplayColumns.load(store)
            end
          prepared = DisplayColumns.prepare(columns)
          if format == :har
            # Said out loud rather than dropped: a HAR log has no per-row field to carry an
            # extracted value, and a `--column` that silently did nothing is the shape of silent
            # failure this CLI refuses everywhere else.
            #
            # Keyed off the FLAG and not off `prepared`, which also holds the project's
            # configured set: naming a flag the operator never passed would print this on every
            # `--format har` run in any project that has a column, which is stderr noise in a
            # script rather than a warning about anything they did.
            STDERR.puts "gori run history: --column is not carried by --format har (the values are in each entry's headers/content)" unless column_specs.empty?
            emit_har(store, rows, query, view_label, limit)
          elsif format == :json
            # The same sentence the text and HAR branches print, on the same channel. JSON-Lines
            # answered an empty listing with ZERO bytes and a silent STDERR — so "I saw no
            # traffic" and "a standing --view/--in-scope lens excluded all of it" read identically
            # to the one consumer that cannot see the flags it was invoked with. STDOUT stays a
            # pure stream either way (this is STDERR), so a pipe is unaffected.
            STDERR.puts empty_listing_note(query, view_label, in_scope) if rows.empty?
            # One extra read per row for the head the projection does not carry — that is what
            # buys `url` and `headers` on the JSON-Lines row (`Output.flow_row_fields`). Heads
            # are small and this streams row by row, so a large `-n` costs queries, not memory.
            rows.each { |r| puts CLI::Output.flow_row_json(r, store.request_head(r.id), row_columns(store, r, prepared)) }
          elsif rows.empty?
            STDERR.puts empty_listing_note(query, view_label, in_scope)
          else
            rows.each { |r| puts CLI::Output.flow_row_text(r, row_columns(store, r, prepared)) }
          end
        ensure
          store.close
        end
      end

      # One row's user-column values as `{label, value}` pairs, or nil when no column is defined.
      #
      # ONE capped read per PRINTED row and none at all for a set that reads only heads — the
      # same P8 discipline the TUI row loop keeps, applied to a listing that is already bounded
      # by `--limit`. A flow a peer deleted between the search and this read yields blanks rather
      # than dropping the row: the row matched, and the listing has to say so.
      private def self.row_columns(store : Store, row : Store::FlowRow,
                                   prepared : DisplayColumns::Prepared) : Array({String, String})?
        return nil if prepared.empty?
        detail = store.get_flow(row.id, body_max: prepared.body_scoped? ? DisplayColumns::BODY_CAP : 0)
        values = detail ? prepared.values(detail) : Array.new(prepared.size, "")
        prepared.columns.map_with_index { |c, i| {c.label, values[i]? || ""} }
      end

      # The sentence an empty listing prints. It names EVERY lens that narrowed the answer, not
      # just the query: a `--view` that matched nothing used to print a bare "no flows", so the
      # one surface with a channel for WHY stayed silent about the newest reason a listing can
      # be short — while `--in-scope` right beside it said so, and while the TUI's empty state
      # names the view outright. "I saw no traffic" and "a standing filter excluded it" must not
      # read the same on a security proxy.
      #
      # `view` is the RESOLVED name and is nil for `All`, whose query is empty — naming a lens
      # that excluded nothing would send an operator looking at a view for an answer it had no
      # part in.
      #
      # Public for the reason `view_row` is: the command ends in `exit`, so the printed shape is
      # the only part of it a spec can pin.
      def self.empty_listing_note(query : String?, view : String?, in_scope : Bool) : String
        scoped = in_scope ? " in scope" : ""
        viewed = view ? " in the #{view.inspect} view" : ""
        "no flows#{query ? " match #{query.inspect}" : ""}#{scoped}#{viewed}"
      end

      # The HAR half of the same sentence — parenthesised rather than prose because it trails a
      # `gori run history:` prefix, and both lenses for the same reason as above: an export that
      # is empty because a standing view excluded everything must not read like one taken against
      # a project with no traffic.
      def self.empty_har_note(query : String?, view : String?) : String
        why = [query ? "query #{query.inspect}" : nil, view ? "view #{view.inspect}" : nil].compact
        "no flows written to the HAR#{why.empty? ? "" : " (#{why.join(", ")})"}"
      end

      # The whole QL result set as ONE HAR 1.2 log (#495).
      #
      # Flows are materialized one at a time — a HAR needs the head/body BLOBs an `ls` row
      # deliberately doesn't carry — so a large `-n` streams instead of holding every body in
      # memory at once. OLDEST first: the listing is newest-first for reading, but a HAR log's
      # entries are chronological, which is what every reader assumes when it renders a
      # waterfall.
      #
      # STDOUT stays a pure HAR document (pipe it straight to a file); every caveat — flows
      # skipped, bodies capped — goes to STDERR, because a silently short export is exactly
      # the failure this file keeps having to fix.
      private def self.emit_har(store : Store, rows : Array(Store::FlowRow), query : String?,
                                view : String?, limit : Int32) : Nil
        details = rows.reverse.each.compact_map { |r| store.get_flow(r.id) }
        # The transcript lookup. `Export::Har.log` calls this for EVERY flow, including the
        # ones that are plainly HTTP — deliberately, and it is the point of #742: "does this
        # flow have a transcript" is a question only the rows can answer, and the status test
        # that used to gate the call is exactly what went blind to WebSocket-over-h2 (an RFC
        # 8441 extended CONNECT is answered `200`, so the lookup was never made and #733's
        # frames never reached a HAR).
        #
        # What that costs, measured (5k/20k HTTP-only flows, --release, warm cache): the
        # lookup is a COVERING-index point read (`idx_ws_messages_flow`), ~1.2–1.6 µs per
        # flow. On 20k flows the whole export step goes 162 ms → 195 ms; on 5k, 41 ms → 47 ms.
        # It is linear and it is next to a `get_flow` per flow (the BLOBs, above) that this
        # command already pays, plus the JSON encoding, which dominates both.
        #
        # `count_ws_messages` first and a fetch only when non-zero was the obvious way to buy
        # it back, and it does not pay: the count is the same index read, 3.6 ms of that 32 ms
        # on 20k flows, and it costs a SECOND query for every flow that IS a socket. One
        # unconditional query is both cheaper overall and the shape with no predicate in it.
        report = Export::Har.log(STDOUT, details, ws: ->(id : Int64) { store.ws_messages(id) })
        STDOUT.puts
        report.notes.each { |n| STDERR.puts "gori run history: #{n}" }
        if report.written == 0
          STDERR.puts "gori run history: #{empty_har_note(query, view)}"
        elsif rows.size >= limit
          # A file handed to someone else must not quietly be the newest 50 of 5000. The
          # listing formats share this default, but there a short page is obvious on screen
          # and in a HAR it is not, so say it out loud.
          STDERR.puts "gori run history: stopped at the --limit of #{limit} flow#{limit == 1 ? "" : "s"}; raise -n to export more"
        end
      end

      # --- show --------------------------------------------------------------

      private def self.cmd_show(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        req_only = false
        resp_only = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run show <flow-id> [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json | raw (exact bytes) | har (a one-entry HAR 1.2 log) | curl | python | fetch | go | httpie (the request as runnable client code) | csrf (a self-submitting HTML CSRF PoC)") { |v| format = parse_format(v, [:text, :json, :raw, :har, :curl, :python, :fetch, :go, :httpie, :csrf]) }
          p.on("--request-only", "Only the request side") { req_only = true }
          p.on("--response-only", "Only the response side") { resp_only = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run show: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run show: missing value for #{f}" }
        end
        parser.parse(args)
        if err = show_side_error(format, req_only, resp_only)
          abort "gori run show: #{err}"
        end
        id = take_flow_id(positional, "show")

        # Close the store before any abort (abort/exit skip ensure blocks); get_flow
        # has already loaded the BLOBs we need. A WebSocket flow also carries a ws_messages
        # log — fetch it now while the store is open (`show_ws_messages`).
        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        detail, ws_msgs = begin
          d = store.get_flow(id)
          {d, show_ws_messages(store, d)}
        ensure
          store.close
        end
        abort "gori run show: no flow ##{id}" unless detail

        show_request = !resp_only
        show_response = !req_only
        case format
        when :raw    then show_raw(detail, show_request, show_response)
        when :har    then show_har(detail, ws_msgs)
        when :curl   then show_curl(detail, ws_msgs)
        when :python then show_code(detail, ws_msgs, :python)
        when :fetch  then show_code(detail, ws_msgs, :fetch)
        when :go     then show_code(detail, ws_msgs, :go)
        when :httpie then show_code(detail, ws_msgs, :httpie)
        when :csrf   then show_code(detail, ws_msgs, :csrf)
        when :json   then puts show_json(detail, show_request, show_response, ws_msgs)
        else              show_text(detail, show_request, show_response, ws_msgs)
        end
      end

      # The flow's REQUEST as a runnable `curl` command — headless "Copy as → cURL".
      #
      # `Export::Curl`, the very same serializer the TUI copy menu calls: a second curl
      # writer here would drift from the clipboard's the first time either learned a flag,
      # and the shell-quoting it does is the part that must not be re-derived (a captured
      # body is arbitrary bytes, and every naive quoting of those is wrong in a way that
      # only shows up on the operator's terminal).
      #
      # Body included, so the command reproduces the request rather than a GET-shaped sketch of
      # it — with every caveat reported on STDERR, never mixed into the command on STDOUT: a body
      # cut at the capture cap would be re-sent SHORT, and a SOCKET flow's command is the upgrade
      # handshake and none of the frames (`socket_curl_note`). The caveats the BYTES impose are
      # the serializer's and travel inside the command as `#` comments, so a paste still runs: a
      # NUL no shell argument can carry (`Export::Curl.data_argument` / `nul_header_note`), and
      # the chunk framing curl would otherwise apply a second time.
      private def self.show_curl(detail : Store::FlowDetail, ws_msgs : Array(Store::WsMessage),
                                 io : IO = STDOUT) : Nil
        row = detail.row
        command = curl_command_for(detail)
        unless command
          abort "gori run show: flow ##{row.id} has no request line to build a URL from — " \
                "its captured head is empty (use --format raw to see the bytes)"
        end
        io.puts command
        if note = socket_curl_note(detail, ws_msgs)
          STDERR.puts "gori run show: #{note}"
        end
        if detail.request_body_truncated?
          STDERR.puts "gori run show: flow ##{row.id}'s request body was truncated at the capture cap — " \
                      "this command sends the SHORT body"
        end
      end

      # The flow's REQUEST serialized as client code — the headless twin of the TUI's
      # "Copy as → Python / fetch / Go / httpie / CSRF PoC" rows, and the same surface-neutral
      # `Export::*` serializers those rows call (so the CLI output is byte-identical to the
      # clipboard). Same shape as `show_curl`: the caveats travel on STDERR, never mixed into the
      # code on STDOUT. A socket flow's snippet is the upgrade handshake and none of the frames
      # (`socket_curl_note`, phrased once for every request-code format).
      private def self.show_code(detail : Store::FlowDetail, ws_msgs : Array(Store::WsMessage),
                                 format : Symbol, io : IO = STDOUT) : Nil
        row = detail.row
        wire = String.new(request_wire_bytes(detail))
        target = Repeater::FlowRequest.build_target(row.scheme, row.host, row.port)
        code = case format
               when :python then Export::PythonRequests.text(wire, target)
               when :fetch  then Export::JsFetch.text(wire, target)
               when :go     then Export::GoHttp.text(wire, target)
               when :httpie then Export::Httpie.text(wire, target)
               when :csrf   then Export::CsrfPoc.text(wire, target)
               end
        unless code
          # `from_wire` refuses for TWO reasons and this used to name only one of them, so a
          # flow whose request line gori cannot frame was reported as having an EMPTY head —
          # a diagnosis that sends the operator after the wrong thing. Ask the same predicate
          # the serializers did, so the sentence matches the refusal.
          request_line = Export::Curl.split_lines(
            Export::Curl.split_message(wire)[0]).first? || ""
          if refusal = Export::Curl.request_line_refusal(request_line)
            abort "gori run show: flow ##{row.id} has no runnable #{format} snippet: #{refusal}"
          end
          abort "gori run show: flow ##{row.id} has no request line to build a URL from — " \
                "its captured head is empty (use --format raw to see the bytes)"
        end
        io.puts code
        if note = socket_curl_note(detail, ws_msgs)
          STDERR.puts "gori run show: #{note}"
        end
        if detail.request_body_truncated?
          STDERR.puts "gori run show: flow ##{row.id}'s request body was truncated at the capture cap — " \
                      "this #{format} snippet carries the SHORT body"
        end
      end

      # What a curl command for a SOCKET flow leaves out, or nil when the flow is plain HTTP.
      #
      # curl speaks the upgrade handshake and nothing after it, so for a 101 the command on STDOUT
      # is a true reproduction of a request that is not what the operator was looking at: the
      # frames are the capture. Every sibling here says so — `show_har` refuses a transcript-less
      # socket by name, the TUI's copy menu offers a separate `wscat` row — while this format
      # printed the handshake with an empty STDERR, which reads as "this is the flow".
      #
      # Judged on the TRANSCRIPT first and the handshake shape second, the way `Har.skip_reason`
      # is: a flow with captured messages is a socket whatever its status line says (#742's
      # WebSocket-over-h2), and `FlowDetail#websocket?` answers for the one that has none.
      #
      # Public for the reason `empty_listing_note` is: the command ends in output, so the sentence
      # is the only part of it a spec can pin.
      def self.socket_curl_note(detail : Store::FlowDetail, ws_msgs : Array(Store::WsMessage)) : String?
        return nil unless ws_msgs.size > 0 || detail.websocket?
        carried = ws_msgs.empty? ? "no messages were captured for it" \
                                    : "the #{ws_msgs.size} captured message#{ws_msgs.size == 1 ? "" : "s"} #{ws_msgs.size == 1 ? "is" : "are"} not in it"
        "flow ##{detail.row.id} is a WebSocket flow — this command reproduces the UPGRADE " \
        "HANDSHAKE only, and #{carried}. Replaying the socket needs a WebSocket client " \
        "(the TUI's copy menu has a wscat row); --format json or raw carries the transcript"
      end

      # The curl command for a stored flow, or nil when its head carries no request line to
      # resolve a URL from — an EMPTY captured head included, which used to resolve to the flow's
      # own target base and hand back `curl 'https://h.test'`, a request nobody made.
      # Split from `show_curl` so the serialization is reachable without the abort/IO around it.
      private def self.curl_command_for(detail : Store::FlowDetail) : String?
        row = detail.row
        Export::Curl.text(String.new(request_wire_bytes(detail)),
          Repeater::FlowRequest.build_target(row.scheme, row.host, row.port))
      end

      # request head + body as one buffer — the "wire" `Export::Curl` parses, and what the
      # TUI's copy menu feeds it (`HistoryView#request_wire`).
      private def self.request_wire_bytes(detail : Store::FlowDetail) : Bytes
        body = detail.request_body
        return detail.request_head if body.nil? || body.empty?
        head = detail.request_head
        buf = Bytes.new(head.size + body.size)
        head.copy_to(buf)
        body.copy_to(buf + head.size)
        buf
      end

      # Why the one-sided flags and this --format cannot be asked for together, or nil.
      #
      # Both formats below write a shape that is not per-side, so a silently ignored flag would
      # hand back a document the operator did not ask for and has no way to tell apart from the
      # one they did.
      private def self.show_side_error(format : Symbol, req_only : Bool, resp_only : Bool) : String?
        return "--request-only and --response-only are mutually exclusive" if req_only && resp_only
        # A HAR entry is a request AND its response; there is no half-entry shape to emit.
        if format == :har && (req_only || resp_only)
          return "--format har writes a whole entry — --request-only/--response-only don't apply"
        end
        # `--format curl` (and the code/PoC serializers) are the REQUEST, always: there is no
        # curl command — nor Python/fetch/Go/httpie snippet, nor CSRF PoC — for a response.
        # `--request-only` is therefore redundant-but-honest and allowed; `--response-only`
        # asks for something that does not exist, so say so rather than print the request the
        # operator explicitly excluded.
        if REQUEST_CODE_FORMATS.includes?(format) && resp_only
          return "--format #{format} writes the REQUEST as code — --response-only has nothing to emit"
        end
        nil
      end

      # The `--format` values that serialize the REQUEST into another tool's shape — curl, the
      # four client-code snippets, and the CSRF PoC. All are request-only (see `show_side_error`)
      # and all share the socket caveat (see `show_code`).
      REQUEST_CODE_FORMATS = [:curl, :python, :fetch, :go, :httpie, :csrf]

      # The captured WebSocket transcript `show` renders (text, `--format json` and the HAR
      # entry's `_webSocketMessages` all read it), fetched while the store is still open.
      #
      # UNCONDITIONAL, and that is the whole content of this method (#742). It used to read
      # `d && d.row.status == 101 ? store.ws_messages(id) : []` — the HTTP/1.1 handshake's
      # status standing in for "is this a socket". An RFC 8441 extended CONNECT (#733) is
      # answered `200`, so `gori run show` on a WebSocket captured over h2 printed the CONNECT
      # exchange and not one of the frames sitting in the table beside it. `ws_messages`
      # already answers with an empty array for a flow that is not a socket, so the gate only
      # ever bought one query — and cost the feature.
      def self.show_ws_messages(store : Store, detail : Store::FlowDetail?) : Array(Store::WsMessage)
        detail ? store.ws_messages(detail.row.id) : [] of Store::WsMessage
      end

      # One flow as a one-entry HAR 1.2 log. A flow HAR cannot represent is an ERROR here,
      # not an empty log: the listing can skip and count, but `show <id> --format har` named
      # this flow, so silently handing back `entries: []` would answer a different question.
      # `ws_msgs` is already in hand: `cmd_show` fetches it before closing the store, because a
      # socket's messages are what the entry is mostly FOR.
      private def self.show_har(detail : Store::FlowDetail,
                                ws_msgs : Array(Store::WsMessage)) : Nil
        # The refusal names the REAL cause where the store has one: a flow gori itself
        # refused to send carries it in `error` ("request framing rejected: …"), and
        # "has no captured response" alone reads like the origin's fault.
        because = detail.error.presence.try { |e| " (#{e})" } || ""
        case Export::Har.skip_reason(detail, ws_msgs.size)
        in Export::Har::Skip::WebSocket
          abort "gori run show: flow ##{detail.row.id} is a WebSocket flow with no captured messages — " \
                "the entry would carry the handshake and no traffic (use --format json or raw)"
        in Export::Har::Skip::NoResponse
          abort "gori run show: flow ##{detail.row.id} has no captured response — a HAR entry requires one#{because}"
        in Export::Har::Skip::Incomplete
          abort "gori run show: flow ##{detail.row.id} did not complete — HAR cannot record a partial response, " \
                "so the entry would read as a successful exchange#{because} (use --format json or raw)"
        in Nil
          # exportable
        end
        report = Export::Har.log(STDOUT, [detail], ws: ->(_id : Int64) { ws_msgs })
        STDOUT.puts
        report.notes.each { |n| STDERR.puts "gori run show: #{n}" }
      end

      # `raw` is the format whose whole promise is that the bytes ARE the message ("exact
      # bytes" in the --format help), which is what makes a body the capture cap cut short
      # invisible HERE and nowhere else: nothing in the octets says they stop early, and the
      # head above them still declares the length the origin sent, so the shortfall reads as
      # the origin's. Every sibling format already says so — `show_text` inline, `show_har`
      # and the code formats on STDERR — and this one is the one an operator pipes into a
      # file and diffs. On STDERR, like those, so STDOUT stays byte-pure.
      private def self.show_raw(detail : Store::FlowDetail, req : Bool, resp : Bool) : Nil
        if req
          STDOUT.write(detail.request_head)
          if b = detail.request_body
            STDOUT.write(b)
          end
        end
        if resp
          if h = detail.response_head
            STDOUT.write(h)
          end
          if b = detail.response_body
            STDOUT.write(b)
          end
        end
        STDOUT.flush
        raw_truncation_notes(detail, req, resp).each { |n| STDERR.puts "gori run show: #{n}" }
      end

      # What `--format raw` left out, one line per side, or empty when the bytes are whole.
      # A separate function for the same reason `socket_curl_note` is one: the sentence is the
      # part worth pinning down, and it is testable without capturing STDERR.
      #
      # Keyed on the side actually PRINTED — `--request-only` on a flow whose response was
      # capped must not warn about bytes it did not write.
      private def self.raw_truncation_notes(detail : Store::FlowDetail, req : Bool, resp : Bool) : Array(String)
        notes = [] of String
        {"request"  => req && detail.request_body_truncated?,
         "response" => resp && detail.response_body_truncated?}.each do |side, capped|
          next unless capped
          notes << "flow ##{detail.row.id}'s #{side} body was truncated at the capture cap — " \
                   "these bytes are the stored prefix, not the whole body " \
                   "(--format json reports the true size)"
        end
        notes
      end

      private def self.show_text(detail : Store::FlowDetail, req : Bool, resp : Bool,
                                 ws_msgs : Array(Store::WsMessage)) : Nil
        # FIRST, above the bytes it is about: what gori DID to this exchange that the bytes
        # cannot show — a Match&Replace rule it could not run, a request the origin invented.
        # The WebSocket half of this has been readable here since #518 (`[gori] …` rows in the
        # message list); an HTTP flow now carries the same statement on the row itself.
        advisories = detail.row.advisories
        unless advisories.empty?
          puts "=== GORI ADVISORY ==="
          advisories.each { |a| puts "! #{CLI::Output.term_safe_multiline(a)}" }
          puts ""
        end
        if req
          puts "=== REQUEST (#{detail.http_version}) ==="
          print_message_text(detail.request_head, display_body(detail.request_head, detail.request_body), detail.request_body)
          puts "  [request body truncated]" if detail.request_body_truncated?
        end
        if resp
          puts "" if req
          puts "=== RESPONSE ==="
          if err = detail.error
            puts "error: #{err}"
          end
          if h = detail.response_head
            print_message_text(h, display_body(h, detail.response_body), detail.response_body)
            puts "  [response body truncated]" if detail.response_body_truncated?
          elsif detail.error.nil?
            puts "(no response captured)"
          end
          unless ws_msgs.empty?
            puts ""
            puts "=== WEBSOCKET MESSAGES (#{ws_msgs.size}) ==="
            ws_msgs.each { |m| puts ws_message_text(m) }
          end
          if (events = sse_events_of(detail)) && !events.empty?
            puts ""
            puts "=== SSE EVENTS (#{events.size}) ==="
            events.each_with_index { |e, i| puts sse_event_text(e, i) }
          end
        end
        print_decoded_text(detail, req, resp, ws_msgs)
      end

      # Parsed SSE events when the response is a text/event-stream, else nil. Like
      # the TUI EVENTS pane, this is a derived view over the decoded response body.
      private def self.sse_events_of(detail : Store::FlowDetail) : Array(Sse::Event)
        Sse.from_response(detail.response_head, detail.response_body)
      end

      private def self.sse_event_text(e : Sse::Event, idx : Int32) : String
        String.build do |io|
          io << "#" << (idx + 1)
          io << " type=" << e.type if e.type
          io << " id=" << e.id if e.id
          io << " retry=" << e.retry if e.retry
          e.data.each_line { |l| io << "\n  " << CLI::Output.term_safe_multiline(l.scrub) }
        end
      end

      # Decoded-protocol sections (SAML / JWT / GraphQL / form params) — derived views
      # over the stored bytes, mirroring the History decoded panes. Printed after the
      # request/response so `gori run show` surfaces the same decodes as the TUI. Scans
      # only the side(s) the `req`/`resp` flags include (so --request-only doesn't leak
      # a response-side token); the query is request-side, so it's gated under `req`.
      private def self.print_decoded_text(detail : Store::FlowDetail, req : Bool, resp : Bool,
                                          ws_msgs : Array(Store::WsMessage) = [] of Store::WsMessage) : Nil
        tgt = req ? detail.row.target : ""
        rh, rb = req ? detail.request_head : nil, req ? detail.request_body : nil
        sh, sb = resp ? detail.response_head : nil, resp ? detail.response_body : nil
        if doc = Saml.from_flow(tgt, rh, rb, sh, sb)
          puts ""
          puts "=== SAML (#{Saml.summary(doc)}) ==="
          puts CLI::Output.term_safe_multiline(Saml.pretty_xml(doc.xml).scrub)
        end
        jwts = Jwt.from_flow(tgt, rh, rb, sh, sb)
        unless jwts.empty?
          puts ""
          puts "=== JWT (#{jwts.size}) ==="
          jwts.each do |f|
            puts "▸ #{f.location}#{(b = f.brief) ? " · #{b}" : ""}"
            puts CLI::Output.term_safe_multiline(f.decoded.scrub)
          end
        end
        if op = Graphql.from_flow(tgt, rh, rb)
          puts ""
          # The parse-failure heading also names the capture cap when that is what cut the
          # body — `detail` knows it and `Graphql` (which sees only bytes) cannot.
          if note = op.note
            capped = detail.request_body_truncated? ? "; body truncated at the capture cap" : ""
            puts CLI::Output.term_safe("=== GRAPHQL (parse failed: #{note}#{capped}) ===")
          else
            puts "=== GRAPHQL ==="
          end
          puts CLI::Output.term_safe_multiline(Graphql.display(op).scrub)
        end
        # A subscription's document travels in a FRAME, not in a body — so the section that
        # names the flow's GraphQL has to be fed from the transcript for a 101 flow, or a
        # WebSocket carrying GraphQL prints exactly what one carrying none prints.
        ws_ops = GraphqlWs.from_messages(ws_msgs)
        unless ws_ops.empty?
          puts ""
          puts CLI::Output.term_safe("=== GRAPHQL over WEBSOCKET (#{GraphqlWs.summary(ws_ops)}) ===")
          puts CLI::Output.term_safe_multiline(GraphqlWs.display(ws_ops).scrub)
        end
        if fields = FormData.from_flow(tgt, rh, rb)
          puts ""
          puts "=== PARAMS (#{fields.size}) ==="
          fields.each { |f| puts CLI::Output.term_safe_multiline("#{f.source == :query ? "?" : " "} #{f.name} = #{(n = f.note) ? "(#{n})" : f.value}".scrub) }
        end
      end

      # The JSON counterpart of print_decoded_text — emits `saml` / `jwt` / `graphql` /
      # `form_params` onto the open flow object via the shared DecodedView emitter (so
      # CLI and MCP stay in lockstep). Scans only the req/resp-included side(s); unclipped
      # (a script can read whole values, unlike the LLM-bounded MCP path).
      private def self.emit_decoded_json(j : JSON::Builder, detail : Store::FlowDetail, req : Bool, resp : Bool,
                                         ws_msgs : Array(Store::WsMessage) = [] of Store::WsMessage) : Nil
        DecodedView.emit_json(j, target: req ? detail.row.target : "",
          req_head: req ? detail.request_head : nil, req_body: req ? detail.request_body : nil,
          resp_head: resp ? detail.response_head : nil, resp_body: resp ? detail.response_body : nil,
          ws_messages: ws_msgs)
      end

      # Schema-less protobuf tree for an application/grpc body. Framed by
      # `Proxy::H2::Grpc.messages`, then each non-trailer / non-compressed payload
      # is decoded by `Gori::Protobuf`. Compressed payloads stay opaque (not
      # protobuf until inflated); grpc-web trailer frames become header maps.
      # Omitted entirely when the head is not gRPC — so ordinary HTTP flows stay free of an
      # empty shell. A gRPC head whose body does NOT frame is a different thing and is now
      # reported: the guard used to be `msgs.empty?`, so a deliberately-wrong length prefix
      # (one of the standard gRPC parser tests) made the whole object VANISH, which reads
      # identically to "this flow is not gRPC". A trailing partial frame went the same way,
      # with no count of what was left over. The raw body was stored correctly either way
      # (P7) — this was only the report the operator reads.
      #
      # `target`/`request` opt into the `.proto` lens (#823) when the project has a descriptor
      # set loaded: the flow's `/package.Service/Method` names the message type, and each
      # payload then carries a `schema` object ALONGSIDE its raw `protobuf` tree — never
      # instead of it. With no schema loaded the output is byte-identical to before.
      private def self.emit_grpc_messages_json(j : JSON::Builder, head : Bytes?, body : Bytes?,
                                               target : String? = nil, request : Bool = true) : Nil
        return if head.nil? || body.nil? || body.empty?
        ct = MediaType.of(head)
        return unless Proxy::H2::Grpc.grpc?(ct)
        # `scan_body`: grpc-web-text carries the frames base64-encoded on the wire.
        msgs, residual = Proxy::H2::Grpc.scan_body(ct, body)
        return if msgs.empty? && residual == 0
        binding = Protobuf::Schemas.resolve(target, request: request)
        j.field "grpc_messages" do
          j.object do
            j.field "count", msgs.size
            if b = binding
              j.field "schema_method", b.method.path
              j.field "schema_message", b.type.full_name
            end
            if residual > 0
              j.field "residual_bytes", residual
              j.field "framing_error",
                "the last #{residual} byte#{residual == 1 ? "" : "s"} are not a complete gRPC frame — " \
                "a length prefix claiming more than arrived, or a body cut short"
            end
            j.field "messages" do
              j.array do
                msgs.each_with_index do |m, i|
                  j.object do
                    j.field "index", i
                    j.field "compressed", m.compressed
                    j.field "trailer", m.trailer
                    j.field "size", m.data.size
                    if m.trailer
                      # grpc-web TRAILER frame: ASCII headers, not protobuf.
                      j.field "headers" do
                        j.object do
                          Proxy::H2::Grpc.trailer_headers(m.data).each do |k, v|
                            j.field k, v.scrub
                          end
                        end
                      end
                    elsif m.compressed
                      # Honour the 0x01 flag: compressed bytes are not a protobuf
                      # message until the caller inflates them (encoding is named
                      # by grpc-encoding, not by us).
                      j.field "note", "compressed payload — not decoded as protobuf"
                      j.field "bytes", Base64.strict_encode(m.data)
                    else
                      decoded = Protobuf.decode(m.data)
                      j.field "protobuf" do
                        decoded.to_json(j)
                      end
                      # The lens, beside the raw tree and never over it (P7): `protobuf` stays
                      # the octet-level report that names every reading a payload fits, and
                      # `schema` is what one `.proto` says about the same bytes.
                      if b = binding
                        j.field "schema" do
                          Protobuf::Lens.emit_json(j, decoded, b.schema, b.type)
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      # "→ out" (client→server) / "← in" (server→client). Text frames print their
      # (scrubbed) payload; binary frames print a size + short hex preview.
      private def self.ws_message_text(m : Store::WsMessage) : String
        arrow = m.direction == "out" ? "→" : "←"
        # `Store::WsMessage#shape_note` / `#control_detail`, not a local copy: the TUI's History
        # pane reads the same two, and a helper it calls cannot live under `CLI::`. `term_safe`
        # stays HERE because it is this surface's question — these bytes are about to be written
        # to a real terminal.
        shape = m.shape_note
        if m.control?
          "#{arrow} #{shape} #{Output.term_safe(m.control_detail)}"
        elsif m.text?
          "#{arrow}#{shape.empty? ? "" : " #{shape}"} #{CLI::Output.term_safe_multiline(String.new(m.payload).scrub)}"
        else
          preview = m.payload[0, {m.payload.size, 16}.min].hexstring
          "#{arrow}#{shape.empty? ? "" : " #{shape}"} [binary #{m.payload.size}B] #{preview}#{m.payload.size > 16 ? "…" : ""}"
        end
      end

      private def self.show_json(detail : Store::FlowDetail, req : Bool, resp : Bool,
                                 ws_msgs : Array(Store::WsMessage)) : String
        JSON.build do |j|
          j.object do
            j.field "flow" do
              CLI::Output.flow_row_fields(j, detail.row)
            end
            j.field "http_version", detail.http_version
            # `Serialize.flow_detail` wraps this same field in `text()`; here it was raw. A
            # capture failure's text quotes bytes the origin sent (a malformed status line, a
            # header the codec refused), so it is captured data — see `Output.json_captured`.
            CLI::Output.json_captured(j, "error", detail.error)
            emit_decoded_json(j, detail, req, resp, ws_msgs)
            if req
              j.field "request" do
                j.object do
                  j.field "head", scrub(detail.request_head)
                  emit_body_json(j, "body", detail.request_head, detail.request_body, detail.request_body_truncated?)
                  emit_grpc_messages_json(j, detail.request_head, detail.request_body,
                    detail.row.target, request: true)
                end
              end
            end
            if resp
              j.field "response" do
                j.object do
                  j.field "head", scrub(detail.response_head)
                  emit_body_json(j, "body", detail.response_head, detail.response_body, detail.response_body_truncated?)
                  emit_grpc_messages_json(j, detail.response_head, detail.response_body,
                    detail.row.target, request: false)
                end
              end
              unless ws_msgs.empty?
                j.field "ws_messages" do
                  j.object do
                    j.field "count", ws_msgs.size
                    j.field "truncated", false
                    j.field "messages" do
                      j.array do
                        ws_msgs.each do |m|
                          j.object do
                            j.field "direction", m.direction
                            j.field "opcode", m.opcode
                            m.emit_shape_json(j)
                            if m.text?
                              j.field "text", String.new(m.payload).scrub
                              # See emit_ws_result: JSON cannot carry a byte that is not valid
                              # UTF-8, and those bytes are the §8.1/§5.6 test case.
                              j.field "base64", Base64.strict_encode(m.payload) unless String.new(m.payload).valid_encoding?
                            else
                              j.field "binary", true
                              j.field "size", m.payload.size
                              j.field "base64", Base64.strict_encode(m.payload)
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
              if (events = sse_events_of(detail)) && !events.empty?
                j.field "sse_events" do
                  j.object do
                    j.field "count", events.size
                    # Same cap/expression as the MCP serializer (mcp/serialize.cr
                    # `emit_sse_events`) — was hardcoded `false` here, so a caller
                    # reading only `sse_events` (the point of --format json) had no
                    # signal the array was clipped.
                    j.field "truncated", events.size > MCP::Serialize::SSE_EVENTS_MAX
                    j.field "events" do
                      j.array do
                        events.each do |e|
                          j.object do
                            j.field "type", e.type
                            j.field "id", e.id
                            j.field "retry", e.retry
                            j.field "data", e.data.scrub
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
