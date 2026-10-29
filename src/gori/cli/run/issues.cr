# `gori run issues` — list, export, create, or update issues (text, json, markdown).
module Gori
  module CLI
    module Run
      # Subcommand dispatch only — the listing/export body lives in cmd_issues_list so this
      # `case` can grow without pushing the (already large) list command over the
      # cyclomatic-complexity bar.
      @[Subcommand("issues", help: [
        {"issues [query]", "List, filter, export, create, update, or delete issues (text, json, markdown, sarif)"},
        {"issues show <id>", "One issue in full: notes, related links, frozen evidence"},
      ])]
      private def self.cmd_issues(args : Array(String)) : Nil
        case sub = args.first?
        when "create"       then cmd_issues_create(args[1..])
        when "update"       then cmd_issues_update(args[1..])
        when "delete", "rm" then cmd_issues_delete(args[1..])
        when "show"         then cmd_issues_show(args[1..])
        when "list"         then cmd_issues_list(args[1..])
        else
          if err = issues_verb_error(sub)
            abort err
          end
          cmd_issues_list(args)
        end
      end

      ISSUES_VERBS      = %w[create update delete rm show list]
      ISSUES_VERBS_HELP = "create, update, delete/rm, show, list"

      # The listing takes a positional query (`issues status:open`), as `history` does, but a
      # first BARE word is still refused as a verb (see `verb_token?`): `issues remove 1` must
      # not exit 0 having deleted nothing. A field term or a group opens a query; free text
      # goes through `-q`, where it cannot be mistaken for a verb.
      def self.issues_verb_error(sub : String?) : String?
        return nil unless verb_token?(sub) && sub
        return nil if sub.includes?(':') || sub.starts_with?('(') || sub == "NOT"
        "gori run issues: unknown subcommand '#{sub}' (#{ISSUES_VERBS_HELP}) — " \
        "to search titles and hosts, pass -q '#{sub}'"
      end

      # SARIF is the one format that carries header VALUES structurally: text and json have
      # none, and markdown's evidence blocks are the captured head as a whole. Inert elsewhere,
      # and said so rather than silently ignored (the `history --include-sensitive` rule).
      private def self.warn_inert_include_sensitive(format : Symbol) : Nil
        return if format == :sarif
        STDERR.puts "gori run issues: --include-sensitive only changes --format sarif"
      end

      private def self.cmd_issues_list(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text
        export_path : String? = nil
        include_sensitive = false
        query : String? = nil
        count_only = false
        lenient = false

        # The two pre-passes `history` runs: `-q` with a separate value, and negated terms
        # (`-status:fp`), which OptionParser would otherwise abort as unknown options.
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        positional = parse_args(opt_args, "gori run issues") do |p|
          p.banner = "Usage: gori run issues [query] [options]\n\n" \
                     "The query is the TUI's / bar: status:open sev:>=high host:api cvss:>=7 -status:fp\n" \
                     "(status:closed = any non-open state). It narrows every --format and --export.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run issues show <issue-id> [options]\n" \
                     "  gori run issues create [options]\n" \
                     "  gori run issues update <issue-id>… [options]\n" \
                     "  gori run issues delete <issue-id>… --yes\n\n" \
                     "#{EVIDENCE_LINK_HELP}\n"
          project_options(p, proj, "read")
          p.on("-qQUERY", "--query=QUERY", "Filter the issues (the TUI's / bar; a bare word searches title and host)") { |v| query = once(query, v, "-q/--query") }
          p.on("--count", "Print how many issues match instead of listing them") { count_only = true }
          p.on("--lenient", "Don't refuse a query naming an unknown field — search that token as text, as the TUI bar does") { lenient = true }
          format_flag(p, [:text, :json, :markdown, :sarif], "Output: text (default) | json | markdown | sarif") { |f| format = f }
          p.on("--export=PATH", "Write to PATH instead of STDOUT") { |v| export_path = v }
          p.on("--include-sensitive", "Emit Authorization/Cookie/Set-Cookie/API-key values in --format sarif's webRequest/webResponse headers instead of [REDACTED]") { include_sensitive = true }
        end
        query = issues_list_query(positional, query, neg_terms, lenient)
        if count_only && (err = issues_count_clash(format, export_path, include_sensitive))
          abort "gori run issues: #{err}"
        end

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project, read_only: true)
        warn_inert_include_sensitive(format) if include_sensitive
        # Build the report while the store is open (markdown resolves linked-flow
        # evidence), then close BEFORE any file I/O so a write failure can't leak the
        # connection — and so the abort below runs after a clean close.
        result = begin
          issues = store.issues
          if q = query
            issues = Issues::Filter.parse(q).apply(issues)
          end
          if count_only
            puts format == :json ? {count: issues.size}.to_json : issues.size
            return
          end
          # `text` to STDOUT only: every other format has a meaningful empty document (an empty
          # JSON array, a header-only report, a SARIF log with `results: []` — which is how a CI
          # gate learns the scan RAN and found nothing), and an --export always writes a file.
          if issues.empty? && format == :text && export_path.nil?
            STDERR.puts query.try { |qq| "no issues match #{qq.inspect}" } || "no issues"
            return
          end
          {issues_report(issues, store, project.name, format, include_sensitive), issues.size}
        ensure
          store.close
        end
        content, count = result
        write_issues_report(content, count, export_path)
      end

      # The listing's query: positional terms or `-q` (history's composition), refused before
      # the store opens when a reserved verb landed among them or the filter cannot match. The
      # dispatcher's bare-word rule is asked again here, because a flag in front of the word
      # (`issues --format=json remove 1`) or a leading `list` reaches this without passing it.
      private def self.issues_list_query(positional : Array(String), query : String?,
                                         neg_terms : Array(String), lenient : Bool) : String?
        positional.shift if positional[0]? == "list"
        if err = reserved_query_verb_error(positional, "issues", ISSUES_VERBS, ISSUES_VERBS_HELP) ||
                 issues_verb_error(positional[0]?)
          abort err
        end
        query, dropped = Run.compose_history_query(query, positional, neg_terms)
        Run.warn_dropped_query_terms("issues", dropped)
        if (q = query) && (why = Issues::Filter.refusal(q, lenient: lenient))
          abort "gori run issues: #{why}"
        end
        query
      end

      private def self.issues_report(issues : Array(Store::Issue), store : Store, project_name : String,
                                     format : Symbol, include_sensitive : Bool) : String
        case format
        when :json     then Issues::Export.json(issues, store)
        when :markdown then Issues::Export.markdown(issues, store, project_name, Redact::Policy.ambient(store))
        when :sarif
          Issues::Export.sarif(issues, store, project_name, include_sensitive,
            include_sensitive ? nil : Redact::Policy.ambient(store))
        else issues_text(issues)
        end
      end

      private def self.write_issues_report(content : String, count : Int32, export_path : String?) : Nil
        if path = export_path
          begin
            File.write(path, content.ends_with?('\n') ? content : "#{content}\n")
          rescue ex : IO::Error
            abort "gori run issues: cannot write to #{path}: #{ex.message}"
          end
          STDERR.puts "exported #{Gori.plural(count, "issue")} → #{path}"
        else
          # Neutralize terminal escape sequences before writing to STDOUT/a TTY: the markdown
          # report embeds attacker-controlled evidence bodies (proxied traffic) and free-text
          # notes that can carry raw ESC/OSC/BEL — a bare `puts` would let them drive the
          # terminal (window-title spoof, OSC 52 clipboard write). Newlines/tabs are preserved,
          # so structure is intact. File export (above) keeps the bytes verbatim — a saved file
          # is not a live terminal, and stripping would corrupt captured evidence.
          puts Issues::Export.scrub_controls(content)
        end
      end

      # `--count` prints a number; a report format, a file or a sensitive-header switch all
      # shape a document it does not write.
      def self.issues_count_clash(format : Symbol, export_path : String?, include_sensitive : Bool) : String?
        return "--count prints a number, so --export does not apply" if export_path
        return "--count prints a number, so --include-sensitive does not apply" if include_sensitive
        return "--count prints a number — use --format text or json" unless format.in?(:text, :json)
        nil
      end

      # `gori run issues show <id>` — one issue in full, as `history show` / `evidence show`
      # print one row: the report's Markdown block (notes, related links, frozen evidence and
      # the filing flow's exchange), or the object `--format json` lists.
      private def self.cmd_issues_show(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text
        positional = parse_args(args, "gori run issues show") do |p|
          p.banner = "Usage: gori run issues show <issue-id> [options]"
          project_options(p, proj, "read")
          format_flag(p, [:text, :json], "Output: text (default, the report's Markdown block) | json") { |f| format = f }
        end
        id = take_id(positional, "gori run issues show", "<issue-id>", "issue id")

        store = open_store(resolve_read_project(proj.name, proj.db), read_only: true)
        content = begin
          issue = store.get_issue(id) || abort_closing(store, "gori run issues show: no issue with id #{id}")
          if format == :json
            Issues::Export.issue_json(issue, store)
          else
            Issues::Export.issue_markdown(issue, store, Redact::Policy.ambient(store)).lstrip('\n')
          end
        ensure
          store.close
        end
        # The block embeds captured bytes and free-text notes: scrubbed for the terminal, as the
        # listing's STDOUT is.
        puts Issues::Export.scrub_controls(content)
      end

      # `notes_sources` / `notes_source_error` / `notes_content` are PUBLIC for the same reason
      # `request_sources` and `issue_flow_error` are: they are split from the `abort` so a spec
      # can pin both the condition and the wording, and `cmd_issues_create`/`cmd_issues_update`
      # each open a store and end in `abort`, which a spec process cannot survive.
      #
      # The notes sources both subcommands accept, in the parser's order, filtered to the ones
      # actually given. ONE list, built once by the caller and read by both the
      # mutual-exclusion gate and the "was there a body at all?" test — asking those two
      # questions of separately maintained expressions is how a source gets refused in one
      # place and silently overwritten in the other (see `request_sources`).
      def self.notes_sources(*, notes : String?, file : String?, stdin : Bool) : Array(String)
        sources = [] of String
        sources << "--notes" if notes
        sources << "--notes-file" if file
        sources << "--notes-stdin" if stdin
        sources
      end

      # nil when `sources` names at most one notes source; the sentence to `abort` with
      # otherwise. The over-specified case is not hypothetical — `notes_content` is an
      # `if/elsif` chain, so without this `--notes-file report.md --notes-stdin` would store the
      # FILE and never mention the pipe (which it would not even drain). Two sources cannot both
      # be the body, and picking one by parser order is a guess made silently. Unlike
      # `request_source_error` there is no "at least one" arm: notes are optional on both
      # subcommands, and `update` has its own "no fields to update" refusal.
      def self.notes_source_error(sources : Array(String), what : String) : String?
        return nil if sources.size <= 1
        "#{what}: #{sources.join(", ")} cannot be combined — pick one notes source"
      end

      # nil when the content is usable; the sentence to `abort` with otherwise. Only the INDIRECT
      # sources are refused for arriving empty. `--notes ''` is the operator typing the clear,
      # and `update` has always taken it as one; a file or a pipe that yields nothing is
      # something else — `report-generator | gori run issues update 7 --notes-stdin` with a
      # generator that died wrote `notes = ''` over the write-up already on the issue and
      # printed "updated successfully", and because a pipeline exits with gori's status the
      # generator's failure was invisible too. That is destructive where `repeater create`'s
      # identical refusal (#1001) only prevented a dead row. `sources` names the culprit, and an
      # EMPTY `sources` means no notes source at all, which is not this refusal's business.
      def self.notes_content_error(sources : Array(String), content : String?, what : String) : String?
        return nil if sources.empty? || sources.first == "--notes" || !content.try(&.empty?)
        "#{what}: #{sources.first} gave no bytes — pass --notes '' to clear the notes"
      end

      # The notes bytes from whichever single source the gate allowed through, or nil for "no
      # notes source given" — which both callers read as "leave the notes alone", distinct from
      # an EMPTY body, which is the operator asking to clear them (what `--notes ''` has always
      # meant on `update`).
      #
      # The branch SELECTION lives here rather than inline so a spec can prove each door hands
      # back its own bytes — an inline chain inside a store-opening command is unreachable from
      # a spec, so deleting a branch from it is a silent behavior change nothing sees.
      def self.notes_content(*, notes : String?, file : String?, stdin : Bool,
                             io : IO, what : String) : String?
        if n = notes
          n
        elsif f = file
          read_input_file(f, "#{what}: --notes-file", noun: "notes")
        elsif stdin
          read_stdin_text(io, what, "notes",
            stdin_pipe_hint(what, flag: "--notes-stdin", file_flag: "--notes-file",
              producer: "report-generator"))
        end
      end

      # The whole notes door for one subcommand: the mutual-exclusion gate, the read, and the
      # empty-source refusal, in the ONE order they may run in — the gate has to refuse before
      # a pipe is drained, and the emptiness verdict can only be reached after it. Both
      # subcommands call this rather than spelling the three steps out twice: a door that reads
      # operator bytes and can destroy an existing write-up is not a sequence to maintain in
      # two places. The steps themselves stay pure and public above, where the specs are; this
      # is the `abort` wrapper around them.
      private def self.resolve_notes(*, notes : String?, file : String?, stdin : Bool,
                                     what : String) : String?
        sources = notes_sources(notes: notes, file: file, stdin: stdin)
        if err = notes_source_error(sources, what)
          abort err
        end
        body = notes_content(notes: notes, file: file, stdin: stdin, io: STDIN, what: what)
        if err = notes_content_error(sources, body, what)
          abort err
        end
        body
      end

      private def self.cmd_issues_create(args : Array(String)) : Nil
        proj = ProjectFlags.new
        title : String? = nil
        sev_s : String? = nil
        cvss : String? = nil
        host : String? = nil
        flow_id : Int64? = nil
        repeater_id : Int64? = nil
        notes : String? = nil
        notes_file : String? = nil
        notes_stdin = false
        format = :text

        parse_no_positionals(args, "gori run issues create",
          "pass the title as --title TEXT — quote it, a title with spaces is one argument") do |p|
          p.banner = "Usage: gori run issues create [options]\n\n" \
                     "The notes body is optional and comes from one of --notes, --notes-file or\n" \
                     "--notes-stdin; it is written with the issue, in one transaction.\n\n" \
                     "#{EVIDENCE_LINK_HELP}\n"
          project_options(p, proj, "write")
          p.on("-tTITLE", "--title=TITLE", "Issue title (required)") { |v| title = v }
          p.on("-sSEVERITY", "--severity=SEVERITY", "Severity: info|low|medium|high|critical (default: auto from cvss, else info)") { |v| sev_s = v }
          p.on("--cvss=CVSS", "CVSS vector string or numeric score (e.g. 9.8 or CVSS:3.1/...)") { |v| cvss = v }
          p.on("--host=HOST", "Host concerning the issue (default: the flow's)") { |v| host = v.strip.presence }
          p.on("--flow=ID", "Associated flow ID") { |v| flow_id = parse_flow_id(v, "gori run issues create") }
          p.on("--repeater=ID", "Link a saved Repeater session as evidence (MCP's repeater_id)") { |v| repeater_id = parse_id(v, "gori run issues create", "--repeater") }
          p.on("-nNOTES", "--notes=NOTES", "Free-form notes (the issue's body)") { |v| notes = v }
          p.on("--notes-file=FILE", "Read the notes from FILE, byte-for-byte") { |v| notes_file = v }
          p.on("--notes-stdin", "Read the notes from stdin, byte-for-byte, as --notes-file reads a file (`report-generator | gori run issues create -t … --notes-stdin`). Keeps a long write-up out of the argument vector, so it is not in the process listing or the shell history and cannot hit the command-line length limit. Needs a pipe or a redirect (`< notes.md`): a terminal is refused, because it would echo the notes back") { notes_stdin = true }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        abort "gori run issues create: --title is required" if (t = title).nil? || t.strip.empty?

        # Refuse a cvss nothing can score, BEFORE the insert. Stored as-is it would sit in a
        # column the Issues list, `cvss:` queries and every export read through a parser that
        # answers nil for it — a field only its own raw string can see, written on a command
        # that reported success. Same rule --severity follows; --flow is checked against the
        # store below, where the answer lives.
        cvss = cvss.try(&.strip).presence
        cvss.try do |c|
          abort "gori run issues create: invalid --cvss '#{c}' (a vector like CVSS:3.1/AV:N/... or a score 0.0-10.0)" unless Gori::Cvss.valid?(c)
        end

        severity = if s = sev_s
                     Store::Severity.parse?(s.strip) || abort("gori run issues create: invalid severity '#{s}' (info|low|medium|high|critical)")
                   elsif c = cvss
                     Gori::Cvss.severity_for(c) || Store::Severity::Info
                   else
                     Store::Severity::Info
                   end

        # EVERY argv-only refusal above the read, and the read above `open_store`, because
        # `--notes-stdin` blocks until EOF: a typo'd `--severity` that aborts only after the
        # pipe has been drained has consumed the operator's generated write-up to say the same
        # thing it could have said instantly. Same ordering, and same reason, as
        # `repeater create --request-stdin`. `--flow 0` is one of those refusals and rides here
        # rather than with its sibling below; only the EXISTENCE half needs the store, and that
        # is the one refusal on this command a pipe can legitimately be drained for.
        if err = issue_flow_range_error(flow_id)
          abort "gori run issues create: #{err}"
        end
        body = resolve_notes(notes: notes, file: notes_file, stdin: notes_stdin,
          what: "gori run issues create")

        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          if err = issue_evidence_error(store, flow_id, repeater_id)
            abort_closing(store, "gori run issues create: #{err}")
          end
          masked_title = Env.mask_secrets(t)
          # No --host: the filing flow's, as the TUI form pre-fills it, so `host:` filters and the
          # report do not miss an issue filed with only --flow.
          masked_host = issue_host(store, host, flow_id).try { |h| Env.mask_secrets(h) }
          # `|| ""` is the column's own default, not a fallback that loses anything: no notes
          # source at all means the issue is created bodiless, exactly as before.
          id = store.insert_issue(masked_title, severity, masked_host, flow_id, cvss: cvss,
            notes: body.try { |n| Env.mask_secrets(n) } || "")
          abort_closing(store, "gori run issues create: failed to persist issue (store busy or unwritable)") if id == 0
          # The issue IS stored, so the refusal names it: a retry of the create would file a duplicate.
          link_issue_repeater(store, id, repeater_id,
            "gori run issues create: issue ##{id} created but its repeater link NOT written (store busy " \
            "or unwritable); retry with `gori run issues update #{id} --repeater #{repeater_id}`")
          puts issue_created_output(store, id, format)
        end
      end

      # What `issues create` prints once the insert has committed: the sentence, or under
      # `--format json` the issue exactly as `gori run issues --format json` prints it (#1117).
      # Read back from the store rather than assembled from the flags, so the object carries
      # what the listing will — the masked title, the derived severity, the timestamps. An
      # issue a peer deleted in that instant has no row to describe, and the object would be
      # one the listing never shows, so that case refuses instead of printing a partial one.
      # Its own method, rather than a branch in `cmd_issues_create`, because that command is
      # at the complexity bar the lint gate holds.
      private def self.issue_created_output(store : Store, id : Int64, format : Symbol) : String
        return "Issue ##{id} created successfully." unless format == :json
        issue = store.get_issue(id) ||
                abort_closing(store, "gori run issues create: issue ##{id} was created, but it was gone before it could be read back")
        Issues::Export.issue_json(issue, store)
      end

      # `--host`, or the `--flow`'s host when none was given.
      private def self.issue_host(store : Store, host : String?, flow_id : Int64?) : String?
        host.try(&.strip).presence || flow_id.try { |fid| store.flow_row(fid).try(&.host) }
      end

      # The refusal for a `--flow` that names no captured flow, or nil when it names one (or
      # was not given). The same existence check `links add --ref flow` makes, and for the same
      # reason: a dangling flow id is not caught later, it is ADVERTISED — the listing row, the
      # markdown report and the SARIF location all print `flow#N` as evidence a reader is then
      # told to open. `flow_row`, not `get_flow`: the row-only read answers "does this exist?"
      # without materializing both BLOBs. The `<= 0` half is separate because the store has no
      # row there to disagree with — `--flow 0` and `--flow -5` parsed fine and persisted a
      # reference no id can ever be. Pure and returning the sentence (not aborting in place) so
      # the decision is spec-able; `abort` is `exit`, which a spec process cannot survive.
      private def self.issue_flow_error(store : Store, flow_id : Int64?) : String?
        return nil unless fid = flow_id
        if err = issue_flow_range_error(fid)
          return err
        end
        store.flow_row(fid) ? nil : "no flow with id #{fid}"
      end

      # The `<= 0` half on its own, so `cmd_issues_create` can ask it BEFORE `--notes-stdin`
      # blocks to EOF — it needs no store, and draining a generator's output only to refuse the
      # argument that was wrong from the moment it was typed is the thing the ordering comment
      # up there promises not to do. Still reached through `issue_flow_error` as well, so the
      # sentence has one spelling and the spec that pins it goes on covering both callers.
      # `--repeater` (MCP's `repeater_id`): the refusal for an id naming no saved Repeater
      # session, or nil. Checked before the write, as `--flow` is, so no issue is filed with a
      # dangling evidence pointer.
      def self.issue_repeater_error(store : Store, repeater_id : Int64?) : String?
        return nil unless rid = repeater_id
        store.get_repeater(rid) ? nil : "no repeater with id #{rid}"
      end

      # `--flow` then `--repeater`, the two evidence pointers both commands check before writing.
      private def self.issue_evidence_error(store : Store, flow_id : Int64?, repeater_id : Int64?) : String?
        issue_flow_error(store, flow_id) || issue_repeater_error(store, repeater_id)
      end

      # Link the issue to `--repeater`, through `Store#ensure_link` as MCP does; abort with
      # `failure` when the link did not commit.
      private def self.link_issue_repeater(store : Store, issue_id : Int64, repeater_id : Int64?, failure : String) : Nil
        return unless rid = repeater_id
        return if store.ensure_link(Store::LinkOwnerKind::Issue, issue_id, Store::LinkRefKind::Repeater, rid)
        abort_closing(store, failure)
      end

      private def self.issue_flow_range_error(flow_id : Int64?) : String?
        return nil unless fid = flow_id
        fid <= 0 ? "invalid --flow #{fid} (expected a positive flow id)" : nil
      end

      # Remove an issue outright. Distinct from `update --status=resolved|false-positive`,
      # which KEEPS it in the report — this drops it and its entity links.
      private def self.cmd_issues_delete(args : Array(String)) : Nil
        proj = ProjectFlags.new
        yes = false

        positional = parse_args(args, "gori run issues delete") do |p|
          p.banner = "Usage: gori run issues delete <id>… --yes\n\n" \
                     "Delete issues and their links (every id must exist, or nothing is deleted).\n" \
                     "To keep one in the report but mark it closed, use\n" \
                     "`gori run issues update <id> --status=resolved` instead."
          p.on("-y", "--yes", "Confirm deletion") { yes = true }
          project_options(p, proj, "update")
        end
        ids = issue_ids(positional, "gori run issues delete")

        with_store(resolve_read_project(proj.name, proj.db)) do |store|
          refuse_missing_issues(store, ids, "gori run issues delete", "deleted")
          if err = issue_delete_confirmation_error(ids, yes)
            abort_closing(store, "gori run issues delete: #{err}")
          end
          abort_closing(store, "gori run issues delete: #{issue_noun(ids)} NOT deleted (store busy or unwritable)") unless store.delete_issues(ids)
          puts "#{issue_noun(ids).capitalize} deleted."
        end
      end

      private def self.issue_delete_confirmation_error(ids : Array(Int64), yes : Bool) : String?
        return nil if yes
        "refusing to delete #{issue_noun(ids)} without --yes; deleted issues cannot be recovered"
      end

      # The `<issue-id>…` positionals of `update` / `delete`, as `history delete` reads its ids.
      private def self.issue_ids(positional : Array(String), cmd : String) : Array(Int64)
        abort "#{cmd}: <issue-id> is required" if positional.empty?
        positional.map { |v| v.to_i64? || abort("#{cmd}: invalid issue id #{v.inspect}") }.uniq!
      end

      # Every id must name an issue before anything is written — `history delete`'s rule.
      private def self.refuse_missing_issues(store : Store, ids : Array(Int64), cmd : String, verb : String) : Nil
        missing = ids.reject { |id| store.get_issue(id) }
        return if missing.empty?
        abort_closing(store, "#{cmd}: no issue with id #{missing.join(", ")}#{ids.size > 1 ? " — nothing was #{verb}" : ""}")
      end

      # `issue #3`, or `3 issues (#1, #2, #5)`.
      private def self.issue_noun(ids : Array(Int64)) : String
        return "issue ##{ids[0]}" if ids.size == 1
        "#{ids.size} issues (#{ids.map { |id| "##{id}" }.join(", ")})"
      end

      # The fields that name ONE issue's content or evidence. Written across several ids they
      # would give each issue another's title or body (see `Store#update_issues`).
      def self.issues_batch_update_error(ids : Int32, *, title : Bool, notes : Bool, flow : Bool, repeater : Bool) : String?
        return nil if ids <= 1
        one = {"--title" => title, "--notes" => notes, "--flow" => flow, "--repeater" => repeater}.select { |_, v| v }.keys
        return nil if one.empty?
        "#{one.join(", ")} name#{one.size == 1 ? "s" : ""} one issue — pass a single id " \
        "(several ids take --severity, --status, --cvss and --host)"
      end

      private def self.cmd_issues_update(args : Array(String)) : Nil
        proj = ProjectFlags.new
        title : String? = nil
        sev_s : String? = nil
        notes : String? = nil
        notes_file : String? = nil
        notes_stdin = false
        stat_s : String? = nil
        cvss : String? = nil
        clear_cvss = false
        host : String? = nil
        clear_host = false
        flow_id : Int64? = nil
        clear_flow = false
        repeater_id : Int64? = nil

        positional = parse_args(args, "gori run issues update") do |p|
          p.banner = "Usage: gori run issues update <issue-id>… [options]\n\n" \
                     "Several ids set --severity / --status / --cvss / --host on each in one write.\n" \
                     "The notes body comes from one of --notes, --notes-file or --notes-stdin.\n" \
                     "--notes '' clears the notes; a file or pipe that gives no bytes is refused.\n\n" \
                     "#{EVIDENCE_LINK_HELP}\n"
          project_options(p, proj, "update")
          p.on("-tTITLE", "--title=TITLE", "New issue title") { |v| title = v }
          p.on("-sSEVERITY", "--severity=SEVERITY", "Severity: info|low|medium|high|critical") { |v| sev_s = v }
          p.on("--cvss=CVSS", "New CVSS vector or score (empty to clear); without --severity it also sets the severity from the score") do |v|
            if v.strip.empty?
              clear_cvss = true
            else
              cvss = v.strip
            end
          end
          p.on("-nNOTES", "--notes=NOTES", "Free-form notes (empty to clear)") { |v| notes = v }
          p.on("--notes-file=FILE", "Read the notes from FILE, byte-for-byte") { |v| notes_file = v }
          p.on("--notes-stdin", "Read the notes from stdin, byte-for-byte, as --notes-file reads a file (`report-generator | gori run issues update 7 --notes-stdin`). Keeps a long write-up out of the argument vector, so it is not in the process listing or the shell history and cannot hit the command-line length limit. Needs a pipe or a redirect (`< notes.md`): a terminal is refused, because it would echo the notes back") { notes_stdin = true }
          p.on("--status=STATUS", "Status: open|confirmed|false-positive|resolved") { |v| stat_s = v }
          p.on("--host=HOST", "Host concerning the issue (empty to clear)") do |v|
            v.strip.empty? ? (clear_host = true) : (host = v.strip)
          end
          p.on("--flow=ID", "The issue's seed flow (empty to clear); the old one stays as a link") do |v|
            v.strip.empty? ? (clear_flow = true) : (flow_id = parse_flow_id(v, "gori run issues update"))
          end
          p.on("--repeater=ID", "Link a saved Repeater session as evidence (MCP's repeater_id)") { |v| repeater_id = parse_id(v, "gori run issues update", "--repeater") }
        end

        ids = issue_ids(positional, "gori run issues update")
        if err = issues_batch_update_error(ids.size, title: !title.nil?, notes: !notes.nil? || !notes_file.nil? || notes_stdin,
             flow: !flow_id.nil? || clear_flow, repeater: !repeater_id.nil?)
          abort "gori run issues update: #{err}"
        end
        if err = issue_flow_range_error(flow_id)
          abort "gori run issues update: #{err}"
        end

        cvss.try do |c|
          abort "gori run issues update: invalid --cvss '#{c}' (a vector like CVSS:3.1/AV:N/... or a score 0.0-10.0)" unless Gori::Cvss.valid?(c)
        end

        severity = sev_s.try { |s| Store::Severity.parse?(s.strip) || abort("gori run issues update: invalid severity '#{s}'") }
        if severity.nil? && (c = cvss)
          severity = Gori::Cvss.severity_for(c)
        end
        status = stat_s.try do |s|
          Store::Status.from_name?(s) || abort("gori run issues update: invalid status '#{s}' (open|confirmed|false-positive|resolved)")
        end

        # A blank title is refused as `create` and MCP `update_issue` refuse it (the row would
        # list as a bare severity tag); argv-only, so above the read below.
        abort "gori run issues update: --title must not be empty" if title.try(&.strip.empty?)

        # EVERY argv-only refusal above the read, and the read above `open_store`, because
        # `--notes-stdin` blocks until EOF — see the same ordering in `cmd_issues_create`. The
        # resolved body replaces `notes` from here on, so the "no fields to update" gate below
        # counts a file or a pipe as the field it is; reading it into a second variable is how
        # `--notes-file x.md` alone would abort with "no fields to update" after the read.
        notes = resolve_notes(notes: notes, file: notes_file, stdin: notes_stdin,
          what: "gori run issues update")

        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          refuse_missing_issues(store, ids, "gori run issues update", "updated")
          if err = issue_evidence_error(store, flow_id, repeater_id)
            abort_closing(store, "gori run issues update: #{err}")
          end

          fields = !(title.nil? && severity.nil? && notes.nil? && status.nil? && cvss.nil? && !clear_cvss &&
                     host.nil? && !clear_host && flow_id.nil? && !clear_flow)
          if !fields && repeater_id.nil?
            abort_closing(store, "gori run issues update: no fields to update (provide at least one of --title/--severity/--notes[-file|-stdin]/--status/--cvss/--host/--flow/--repeater)")
          end

          masked_title = title.try { |t| Env.mask_secrets(t) }
          masked_notes = notes.try { |n| Env.mask_secrets(n) }

          # update_issue returns false when the write didn't commit (store busy/locked):
          # don't report success then. `--repeater` alone is a link, not a row write (MCP's rule).
          if fields && !store.update_issues(ids, title: masked_title, severity: severity, notes: masked_notes, status: status,
               cvss: cvss, clear_cvss: clear_cvss, host: host.try { |h| Env.mask_secrets(h) }, clear_host: clear_host,
               flow_id: flow_id, clear_flow: clear_flow)
            abort_closing(store, "gori run issues update: project is busy (write did not commit) — try again")
          end
          # One id whenever there is a repeater: `issues_batch_update_error` refused the rest.
          link_issue_repeater(store, ids[0], repeater_id, "gori run issues update: repeater link NOT written (store busy or unwritable); try again")
          puts ids.size == 1 ? "Issue ##{ids[0]} updated successfully." : "#{issue_noun(ids).capitalize} updated."
        end
      end

      private def self.issues_text(issues : Array(Store::Issue)) : String
        String.build do |io|
          issues.each do |f|
            # sprintf, not Float64#to_s: `--cvss 8.85` is accepted, and the TUI, SARIF's
            # security-severity and this listing must not print it three different ways.
            cvss_tag = f.cvss_score.try { |sc| "  [CVSS #{sprintf("%.1f", sc)}]" } || ""
            io << '#' << f.id << "  [" << f.severity.label << '/' << f.status.label << ']' << cvss_tag << "  " << Output.term_line(f.title)
            if h = f.host.try(&.strip).presence
              io << "  (" << Output.term_line(h) << ')'
            end
            # The issue's FIRST related item, in the compact spelling this one-line-per-issue
            # listing has room for. There is no related LIST here to make it the first row of
            # — `issues_text` is handed the issue rows and no store — so the rule "the primary
            # flow is the first related row" lands on this listing as "the token names the
            # first related item", and `--format markdown` / `json` are where the whole list
            # is. Same id `--flow` wrote.
            io << "  flow#" << f.flow_id if f.flow_id
            io << '\n'
          end
        end.rstrip('\n')
      end
    end
  end
end
