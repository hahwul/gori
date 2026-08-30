# `gori run diff` — the retest report: diff two projects at ENDPOINT scale (the
# project-level counterpart of `gori run compare`, which diffs two flows).
#
# Reads only. Two grouped queries, one shared fold tree, no bodies and no network — see
# `Gori::Diff`, which owns the comparison and all three renderings so this command, the
# MCP `diff_projects` tool and the TUI cannot describe one comparison three ways.
module Gori
  module CLI
    module Run
      # Verdict names `--verdict` accepts, in the order a report reads them.
      DIFF_VERDICTS = Gori::Diff::Render::ORDER

      private def self.cmd_diff(args : Array(String)) : Nil
        from_name : String? = nil
        to_name : String? = nil
        from_db : String? = nil
        to_db : String? = nil
        query : String? = nil
        limit = Store::ENDPOINT_OBSERVATION_MAX
        in_scope = false
        issues = true
        verdicts : Array(Gori::Diff::Verdict)? = nil
        unchanged = false
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run diff --from <project> [--to <project>] [options]\n\n" \
                     "Diff two projects at endpoint scale — what is new, gone, or answering\n" \
                     "differently since the last engagement. Endpoints are keyed by the SAME\n" \
                     "folded path template the Sitemap tab shows (/users/{uuid}), so captured\n" \
                     "ids don't turn every row into an added/removed pair.\n\n" \
                     "Sends nothing: this diffs captured traffic. Re-confirming a finding is\n" \
                     "still a Repeater send you make deliberately."
          p.on("--from=NAME", "Baseline project — the earlier engagement (name, slug or short id)") { |v| from_name = v }
          p.on("--to=NAME", "Newer project (default: the most-recently-active one)") { |v| to_name = v }
          p.on("--from-db=PATH", "Explicit SQLite db file for the baseline side") { |v| from_db = v }
          p.on("--to-db=PATH", "Explicit SQLite db file for the newer side") { |v| to_db = v }
          p.on("-qQL", "--query=QL", "Narrow BOTH sides with a QL query (host: method: path: status: …)") { |v| query = v }
          p.on("--in-scope", "Only hosts in each project's own configured scope") { in_scope = true }
          p.on("-nN", "--limit=N", "Max endpoint groups to read per side (default #{Store::ENDPOINT_OBSERVATION_MAX})") { |v| limit = parse_count(v, "--limit") }
          p.on("--verdict=LIST", "Only list these verdicts: #{DIFF_VERDICTS.map(&.label).join(",")}") { |v| verdicts = parse_diff_verdicts(v) }
          p.on("--unchanged", "Also list the unchanged endpoints (they are always COUNTED)") { unchanged = true }
          p.on("--no-issues", "Skip the issue retest (which endpoints the baseline's open issues sit on)") { issues = false }
          p.on("--format=FMT", "Output: text (default) | json | md (a retest report section)") do |v|
            # `parse_format` folds "md" onto :markdown, so :md is not a symbol this can hold.
            format = parse_format(v, [:text, :json, :markdown])
          end
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| abort_diff_positional(before + after, p) }
          p.invalid_option { |f| abort "gori run diff: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run diff: missing value for #{f}" }
        end
        parser.parse(normalize_query_flag(args))

        abort "gori run diff: need a baseline side — pass --from NAME (or --from-db PATH)\n#{parser}" if from_name.nil? && from_db.nil?
        filter = diff_filter(query)
        # Into a fresh local first: `verdicts` is assigned inside an OptionParser block, so
        # the compiler keeps it a union and `||` cannot narrow it.
        chosen = verdicts
        verdict_list = chosen || (unchanged ? Gori::Diff::Render::ORDER : Gori::Diff::Render::LISTED)

        # Each side names its project ONE way. `resolve_read_project` refuses `--project` +
        # `--db` together, and `diff` reaches it with its own two pairs — so the refusal has to
        # be raised here, in this command's vocabulary. Without it the operator who typed
        # `--from acme --from-db baseline.db` was told to choose between `--db` and `--project`,
        # neither of which `gori run diff` accepts.
        refuse_two_targets(from_name, from_db, "gori run diff", "--from", "--from-db")
        refuse_two_targets(to_name, to_db, "gori run diff", "--to", "--to-db")
        a = resolve_read_project(from_name, from_db)
        b = resolve_read_project(to_name, to_db)
        if a.db_path == b.db_path
          abort "gori run diff: both sides resolve to the same database (#{a.db_path}) — " \
                "name two different projects with --from/--to"
        end

        report = read_diff_report(a, b, filter, limit, in_scope, issues)
        warn_unscoped_sides(report) if in_scope
        emit_diff(report, format, verdict_list, issues)
      end

      # `--in-scope` is host-level and answered by each project's OWN rules, so a side with
      # none has nothing in scope and contributes zero endpoints — which would otherwise read
      # as "that engagement captured nothing". Same note `gori run sitemap --in-scope` prints,
      # for the same silence.
      private def self.warn_unscoped_sides(report : Gori::Diff::Report) : Nil
        [report.a, report.b].each do |side|
          next unless side.scope_rules.empty?
          STDERR.puts "gori run diff: --in-scope, but '#{side.label}' has no scope rules — " \
                      "nothing on that side is in scope"
        end
      end

      # Open both stores read-only, run the comparison, close both. The stores are opened
      # one at a time and only the two grouped result sets are held — never two whole
      # projects in memory (P8).
      private def self.read_diff_report(a : Project, b : Project, filter : QL::Filter, limit : Int32,
                                        in_scope : Bool, issues : Bool) : Gori::Diff::Report
        store_a = open_store(a, read_only: true)
        store_b = begin
          open_store(b, read_only: true)
        rescue ex
          store_a.close
          raise ex
        end
        begin
          Gori::Diff.run(store_a, store_b,
            label_a: a.name, label_b: b.name,
            path_a: a.db_path, path_b: b.db_path,
            filter: filter, limit: limit, in_scope: in_scope,
            issue_limit: issues ? Gori::Diff::ISSUE_RETEST_MAX : 0,
            raise_on_error: true)
        rescue ex
          abort "gori run diff: read failed: #{ex.message}"
        ensure
          store_a.close
          store_b.close
        end
      end

      # Same QL handling as `gori run sitemap`: shape-only (both stores are still closed),
      # and a non-blank query that compiles to nothing is refused rather than silently
      # broadening the diff to every endpoint.
      private def self.diff_filter(query : String?) : QL::Filter
        return QL::EMPTY unless q = query
        return QL::EMPTY if q.strip.empty?
        filter = QL.parse(q, scope: QL::SCOPE_SHAPE_ONLY)
        Run.warn_query_terms("diff", q)
        if filter == QL::EMPTY
          abort "gori run diff: query #{q.inspect} did not match any field " \
                "(check syntax, e.g. host:example.com method:POST path:/api status:>=500)"
        end
        filter
      end

      private def self.parse_diff_verdicts(spec : String) : Array(Gori::Diff::Verdict)
        wanted = spec.split(',').map(&.strip.downcase).reject(&.empty?)
        abort "gori run diff: --verdict needs at least one of: #{DIFF_VERDICTS.map(&.label).join(", ")}" if wanted.empty?
        wanted.map do |name|
          DIFF_VERDICTS.find { |v| v.label == name } ||
            abort("gori run diff: unknown verdict '#{name}' (have: #{DIFF_VERDICTS.map(&.label).join(", ")})")
        end.uniq!
      end

      # The two sides are NAMED options, so a bare positional is a mistake worth catching —
      # `gori run diff old new` would otherwise diff the default project against itself.
      private def self.abort_diff_positional(positional : Array(String), p : OptionParser) : Nil
        return if positional.empty?
        abort "gori run diff: unexpected argument#{positional.size == 1 ? "" : "s"} " \
              "#{positional.join(" ")} — name both sides with --from/--to\n#{p}"
      end

      # `--verdict` narrows all three formats, JSON included: the flag says "only list these
      # verdicts", the MCP `verdicts` argument narrows the identical payload, and a machine
      # surface that quietly ignored the flag would disagree with its own help text. The
      # `counts` object still covers all five either way, so a narrowing can never make a
      # bucket read as empty.
      private def self.emit_diff(report : Gori::Diff::Report, format : Symbol,
                                 verdicts : Array(Gori::Diff::Verdict), issues : Bool) : Nil
        case format
        when :json     then puts Gori::Diff::Render.json(report, verdicts: verdicts, issues: issues)
        when :markdown then puts Gori::Diff::Render.markdown(report, verdicts: verdicts, issues: issues)
        else                print Gori::Diff::Render.text(report, verdicts: verdicts, issues: issues)
        end
      end
    end
  end
end
