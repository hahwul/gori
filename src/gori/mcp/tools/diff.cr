require "json"
require "../../diff"
require "../../paths"
require "../../project_registry"
require "../../store"

module Gori
  module MCP
    class Tools
      # "What's new since last time?" — the retest diff, at ENDPOINT scale, between two
      # projects. The counterpart of `compare_flows`, which diffs two MESSAGES.
      #
      # Reads only: two grouped queries and one shared fold tree, no bodies and no
      # network. Confirming that a finding still reproduces takes a request, and that stays
      # a deliberate `send_request` — see `Gori::Diff`, which owns the whole comparison.
      DIFF_LIMIT = PageLimit.new(20_000, Store::ENDPOINT_OBSERVATION_MAX)

      @[Tool("diff_projects", unbound: true)]
      private def diff_projects(h) : Result
        from = str(h, "from").try(&.strip).presence
        return err("missing required 'from' (the BASELINE project — name, slug or short id)",
          "INVALID_ARGUMENT", field: "from") unless from
        # Every argument is validated BEFORE a store is opened, so a bad `verdicts` value
        # cannot leave a database handle to unwind.
        opts = diff_options(h)
        return opts if opts.is_a?(Result)
        reg = registry
        base = find_project(reg, from, "from")
        return base if base.is_a?(Result)
        return not_found(unknown_project(reg, "from", from)) unless base
        target = resolve_diff_target(reg, str(h, "to").try(&.strip).presence)
        return target if target.is_a?(Result)
        newer, newer_store, owns_newer = target
        begin
          return err("'from' and 'to' name the same database (#{base.db_path}) — a project " \
                     "does not differ from itself", "INVALID_ARGUMENT", field: "to") if base.db_path == newer.db_path
          run_diff(base, newer, newer_store, opts)
        ensure
          newer_store.close if owns_newer
        end
      end

      # The read itself, once both sides are resolved. The baseline store is opened and
      # closed here; `newer_store` belongs to the caller.
      private def run_diff(base : Project, newer : Project, newer_store : Store,
                           opts : DiffOptions) : Result
        base_store = begin
          open_diff_store(base)
        rescue ex
          return err("cannot open '#{base.name}': #{base.open_failure_reason(ex)}",
            "INVALID_ARGUMENT", field: "from")
        end
        begin
          report = Gori::Diff.run(base_store, newer_store,
            label_a: base.name, label_b: diff_label(newer),
            path_a: base.db_path, path_b: newer.db_path,
            filter: opts.filter, limit: opts.limit, in_scope: opts.in_scope,
            issue_limit: opts.issues ? Gori::Diff::ISSUE_RETEST_MAX : 0,
            raise_on_error: true)
          diff_page(report, opts)
        ensure
          base_store.close
        end
      end

      # The rendered report under REPLY_ROWS_BUDGET (#1649): one page of `endpoints` from
      # `offset`, then the issue retest in what the page left. The diff is recomputed per call
      # and its rows are sorted, so `offset` pages it; an issue that does not fit is named in
      # `issues_unshown_ids` (get_issue reads it), since the retest has no page of its own.
      # The report is built by the shared renderer, so the page is cut from its parsed arrays
      # and this surface's fields go on after it rather than into it.
      private def diff_page(report : Gori::Diff::Report, opts : DiffOptions) : Result
        rendered = JSON.parse(Gori::Diff::Render.json(report, verdicts: opts.verdicts, issues: opts.issues)).as_h
        listed = rendered["endpoints"].as_a
        page = offset_slice(listed, opts.offset)
        rows = fit_rows(page) { |rj, e, _| e.to_json(rj) }
        all = rendered["issues"]?.try(&.as_a)
        issues = all.try { |a| fit_rows(a, rows.sum(&.bytesize)) { |rj, e, _| e.to_json(rj) } }
        Result.new(JSON.build do |j|
          j.object do
            rendered.each do |k, v|
              case k
              when "endpoints" then j.field(k) { raw_rows(j, rows) }
              when "issues"    then j.field(k) { raw_rows(j, issues || [] of String) }
              else                  j.field(k) { v.to_json(j) }
              end
            end
            emit_offset_page(j, opts.offset, rows.size, page.size, listed.size)
            j.field "total", listed.size
            if all && issues && issues.size < all.size
              j.field "issues_unshown_ids", all[issues.size..].map(&.["id"])
            end
            emit_ignored_terms(j, opts.dropped)
          end
        end)
      end

      # The validated argument set, so `diff_projects` reads as resolve-then-run.
      private record DiffOptions,
        filter : QL::Filter,
        verdicts : Array(Gori::Diff::Verdict),
        limit : Int32,
        issues : Bool,
        in_scope : Bool,
        dropped : Array(String),
        offset : Int32

      private def diff_options(h) : DiffOptions | Result
        dropped = [] of String
        filter = diff_filter(h, str(h, "query"), dropped)
        return filter if filter.is_a?(Result)
        verdicts = diff_verdicts(h)
        return verdicts if verdicts.is_a?(Result)
        DiffOptions.new(filter, verdicts,
          clamp(optional_int_arg(h, "limit"), DIFF_LIMIT),
          bool_arg(h, "issues", true), bool_arg(h, "in_scope", false), dropped,
          clamp_nonneg(optional_int_arg(h, "offset")))
      end

      # NOT `ql_filter_or_error`, for two reasons that are really one: that helper reads the
      # BOUND project's scope lens (`Scope.ql_lens(store)`), and this tool has two projects
      # and may have no bound one at all.
      #
      #   * It is UNBOUND_SAFE — `from` and `to` can both be named — and `Tools#store` RAISES
      #     when nothing is bound, so a query on an unbound call came back as an INTERNAL
      #     "gori is broken" error for what is an ordinary, valid request.
      #   * One compiled filter is applied to BOTH stores, so a `scope:` term lensed through
      #     project B would have narrowed project A by B's rules. `SCOPE_SHAPE_ONLY` answers
      #     as an unconfigured project on both sides instead — deterministic, and the same
      #     lens `gori run diff` compiles with. Scoping a retest is `in_scope`, which asks
      #     each side its OWN rules.
      private def diff_filter(h, query : String?, dropped : Array(String)) : QL::Filter | Result
        q = query.try(&.strip)
        return QL::EMPTY if q.nil? || q.empty?
        # The one check this helper can share with `ql_filter_or_error` verbatim: naming a field
        # QL does not implement is wrong against ANY store, so it needs no lens (see there).
        if unknown = ql_unknown_field_error(h, q)
          return unknown
        end
        filter = QL.parse(q, scope: QL::SCOPE_SHAPE_ONLY)
        return ql_error(q) if QL.reject_empty?(q, filter)
        bad = QL.invalid_regex_terms(q)
        return ql_invalid_regex_error(q, bad) unless bad.empty?
        # Named on the reply like every other query tool's (`emit_ignored_terms`): a dropped term
        # diffs more endpoints than asked.
        dropped.concat(QL.analyze(q, scope: QL::SCOPE_SHAPE_ONLY).ignored)
        filter
      end

      # The NEWER side: a named project (opened read-only here, ours to close) or — when
      # `to` is omitted — the project this server is already bound to, whose store belongs
      # to the server and must NOT be closed under it.
      private def resolve_diff_target(reg : ProjectRegistry, to : String?) : {Project, Store, Bool} | Result
        unless to
          bound = @store
          path = @db_path
          return no_project unless bound && path
          return {Project.new(@project_name || File.basename(File.dirname(path)), path), bound, false}
        end
        project = find_project(reg, to, "to")
        return project if project.is_a?(Result)
        return not_found(unknown_project(reg, "to", to)) unless project
        # Naming the project this server is already bound to is the same side as omitting
        # `to`. Reuse the open store rather than taking a second connection to a database
        # a capturing TUI may hold the write lock on.
        bound = @store
        return {project, bound, false} if bound && project.db_path == @db_path
        begin
          {project, open_diff_store(project), true}
        rescue ex
          err("cannot open '#{project.name}': #{project.open_failure_reason(ex)}", "INVALID_ARGUMENT", field: "to")
        end
      end

      # A read-only, non-indexing open of a project this server is NOT bound to. Retention
      # is unlimited because nothing here writes and a prune is the last thing a read of
      # someone else's project should be able to do.
      private def open_diff_store(project : Project) : Store
        Store.open(project.db_path, retention_flows: Store::RETENTION_UNLIMITED,
          read_only: true, background_index: false)
      end

      private def diff_label(p : Project) : String
        p.name.presence || File.basename(File.dirname(p.db_path))
      end

      private def unknown_project(reg : ProjectRegistry, field : String, wanted : String) : String
        have = reg.list.map(&.name)
        "no project matching '#{wanted}' for '#{field}'#{have.empty? ? "" : " (have: #{have.join(", ")})"}"
      end

      # `verdicts: ["added","changed"]` narrows which endpoint rows come back. The COUNTS
      # always cover all five, so narrowing the list can never make a bucket read as empty.
      # Through `str_list`, so a non-string entry is refused or read as the verdict it spells:
      # `compact_map(&.as_s?)` dropped `[123]` to an empty list, which means "no filter", and
      # answered every verdict (#1563).
      private def diff_verdicts(h) : Array(Gori::Diff::Verdict) | Result
        names = str_list(h, "verdicts").flat_map(&.split(','))
        wanted = [] of Gori::Diff::Verdict
        names.each do |n|
          key = n.strip.downcase
          next if key.empty?
          v = Gori::Diff::Render::ORDER.find { |cand| cand.label == key }
          return err("unknown verdict '#{n}' (have: #{Gori::Diff::Render::ORDER.map(&.label).join(", ")})",
            "INVALID_ARGUMENT", field: "verdicts") unless v
          wanted << v unless wanted.includes?(v)
        end
        wanted.empty? ? Gori::Diff::Render::ORDER : wanted
      end

      private def list_diff_tools(j : JSON::Builder) : Nil
        tool j, "diff_projects",
          "Retest diff: compare two PROJECTS per endpoint — new, gone, and answering " \
          "differently since the last engagement. Endpoints are keyed by host + method + " \
          "folded path template (/users/{uuid}), ignoring port and scheme on purpose (a " \
          "service can move ports between engagements; list_sitemap's roots are per origin); " \
          "'changed' uses a tolerance band, not byte " \
          "equality. Returns per-side summaries `a`/`b`, `counts`, `caveats`, " \
          "`scope_mismatch` (read `caveats` first: a cut side says so there), `endpoints:[{verdict,observation,host,method,path,a,b,changes}]`, " \
          "`issues`. READ VERDICTS EXACTLY: 'removed' = the newer project captured NO request " \
          "there — a coverage gap, NOT evidence of deletion; 'gone' = confirmed (404/410). " \
          "Quote a row's 'observation' (what it IS and IS NOT evidence of) when filing an " \
          "issue. Each side's sample_flow_id feeds compare_flows/get_flow. Pure read." do |s|
          s.field "from", strprop("BASELINE project — the earlier engagement (name, slug or short id)"), required: true
          s.field "to", strprop("newer project (default: the one this server is bound to)")
          s.field "query", strprop("narrow BOTH sides with QL; a `scope:` term sees no scope (use in_scope)")
          s.field "in_scope", boolprop("only hosts inside each project's own scope rules")
          s.field "verdicts", strarrprop("only these verdicts: added, gone, changed, unchanged, removed (default all)")
          s.field "issues", boolprop("include the retest of the baseline's open issues (default true)")
          s.field "limit", limitprop("max endpoint groups to read per side", DIFF_LIMIT)
          s.field "offset", intprop("endpoint rows to skip (default 0); `has_more`/`total` say what a ~64 KB reply left")
          s.field "lenient", boolprop("free-text an unknown `field:` instead of refusing (a typo then matches nothing)")
        end
      end
    end
  end
end
