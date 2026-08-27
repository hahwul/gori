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
      private def diff_projects(h) : Result
        from = str(h, "from").try(&.strip).presence
        return err("missing required 'from' (the BASELINE project — name, slug or short id)",
          "INVALID_ARGUMENT", field: "from") unless from
        # Every argument is validated BEFORE a store is opened, so a bad `verdicts` value
        # cannot leave a database handle to unwind.
        opts = diff_options(h)
        return opts if opts.is_a?(Result)
        reg = registry
        base = reg.find(from)
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
          Result.new(Gori::Diff::Render.json(report, verdicts: opts.verdicts, issues: opts.issues))
        ensure
          base_store.close
        end
      end

      # The validated argument set, so `diff_projects` reads as resolve-then-run.
      private record DiffOptions,
        filter : QL::Filter,
        verdicts : Array(Gori::Diff::Verdict),
        limit : Int32,
        issues : Bool,
        in_scope : Bool

      private def diff_options(h) : DiffOptions | Result
        filter = diff_filter(str(h, "query"))
        return filter if filter.is_a?(Result)
        verdicts = diff_verdicts(h)
        return verdicts if verdicts.is_a?(Result)
        DiffOptions.new(filter, verdicts,
          clamp(optional_int_arg(h, "limit"), 20_000, Store::ENDPOINT_OBSERVATION_MAX),
          bool_arg(h, "issues", true), bool_arg(h, "in_scope", false))
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
      private def diff_filter(query : String?) : QL::Filter | Result
        q = query.try(&.strip)
        return QL::EMPTY if q.nil? || q.empty?
        filter = QL.parse(q, scope: QL::SCOPE_SHAPE_ONLY)
        return ql_error(q) if QL.reject_empty?(q, filter)
        bad = QL.invalid_regex_terms(q)
        return ql_invalid_regex_error(q, bad) unless bad.empty?
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
        project = reg.find(to)
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
      private def diff_verdicts(h) : Array(Gori::Diff::Verdict) | Result
        raw = h["verdicts"]?
        return Gori::Diff::Render::ORDER unless raw
        names = raw.as_a?.try(&.compact_map(&.as_s?)) || raw.as_s?.try(&.split(',')) ||
                return err("invalid 'verdicts' (expected an array of #{Gori::Diff::Render::ORDER.map(&.label).join("|")})",
                  "INVALID_ARGUMENT", field: "verdicts")
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
          "Retest diff: compare two PROJECTS at endpoint scale — what is new, what is gone, " \
          "and what answers differently since the last engagement. (compare_flows is the " \
          "message-level counterpart.) Endpoints are keyed by the same folded path template " \
          "list_sitemap shows (/users/{uuid}), so captured ids don't turn every row into an " \
          "added/removed pair, and 'changed' is judged by a tolerance band rather than byte " \
          "equality, so a dynamic page is not a finding. " \
          "Returns {a,b:{label,flows,endpoints,hosts,first_seen,last_seen,scope_rules,truncated}, " \
          "counts:{added,gone,changed,unchanged,removed}, caveats[], scope_mismatch, " \
          "endpoints:[{verdict,host,method,path,a,b,changes[]}], issues:[…]}. " \
          "READ THE VERDICTS EXACTLY: 'removed' means the newer project captured NO request " \
          "to that endpoint — a coverage gap, NOT evidence it was deleted; 'gone' is the " \
          "confirmed case (the newer capture asked and got 404/410). Each side carries a " \
          "sample_flow_id, which compare_flows/get_flow take for the byte-level detail. " \
          "Pure read: no network, nothing written — re-confirming a finding is a send_request " \
          "you make deliberately." do |s|
          s.field "from", strprop("BASELINE project — the earlier engagement (name, slug or short id)"), required: true
          s.field "to", strprop("newer project (default: the project this server is bound to)")
          s.field "query", strprop("narrow BOTH sides with a QL query (host: method: path: status: …). A `scope:` term is answered as an unconfigured project — there is no single scope across two projects; use in_scope, which asks each side its own rules")
          s.field "in_scope", boolprop("only hosts inside each project's own scope rules (default false)")
          s.field "verdicts", strarrprop("only return endpoints with these verdicts: added, gone, changed, unchanged, removed (default: all)")
          s.field "issues", boolprop("include the issue retest — which endpoint each of the baseline's open issues sits on, and whether it still answers the same way (default true)")
          s.field "limit", intprop("max endpoint groups to read per side (default 20000, max #{Store::ENDPOINT_OBSERVATION_MAX})")
        end
      end
    end
  end
end
