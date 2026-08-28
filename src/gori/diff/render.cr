require "json"
require "./record"
require "./report"

module Gori::Diff
  # The three shapes a diff report is read in: a terminal listing, a Markdown section an
  # operator pastes into a retest deliverable, and JSON for an agent. All three live here
  # so `gori run diff`, the MCP `diff_projects` tool and the TUI drill-down cannot drift
  # into describing the same comparison differently.
  module Render
    # Verdicts in reading order: what is new, what is confirmed gone, what moved, what
    # held, and last the bucket that is a coverage statement rather than a finding.
    ORDER = [Verdict::Added, Verdict::Gone, Verdict::Changed, Verdict::Unchanged, Verdict::Removed]

    # What a report LISTS by default. `unchanged` is left out of the listing (never out of
    # the counts): on a real retest it is most of the rows, and burying four findings under
    # three hundred "still the same" lines is how a report stops being read.
    LISTED = ORDER.reject(&.unchanged?)

    # Section headings. `Removed` names its ambiguity in the heading itself, so a reader
    # skimming only the headings of a pasted report cannot take it for "deleted".
    def self.heading(v : Verdict) : String
      case v
      in .added?     then "Added — captured in B only"
      in .gone?      then "Gone — B asked and got 404/410"
      in .changed?   then "Changed"
      in .unchanged? then "Unchanged"
      in .removed?   then "Not seen in B — no request captured (coverage gap, not proof of removal)"
      end
    end

    # ── text ────────────────────────────────────────────────────────────────────

    # `verdicts` selects which SECTIONS are listed; the summary counts always cover all
    # five, so narrowing the listing can never make a bucket look empty.
    def self.text(r : Report, *, verdicts : Array(Verdict) = LISTED, issues : Bool = true) : String
      String.build do |io|
        io << "— retest diff: " << r.a.label << " → " << r.b.label << " —\n"
        io << coverage_line(r.a) << '\n'
        io << coverage_line(r.b) << '\n'
        io << summary_line(r) << '\n'
        r.caveats.each { |c| io << "! " << c << '\n' }
        ORDER.each do |verdict|
          next unless verdicts.includes?(verdict)
          rows = r.rows_of(verdict)
          next if rows.empty?
          io << '\n' << heading(verdict) << " (" << rows.size << ")\n"
          rows.each { |row| io << "  " << row_line(row) << '\n' }
        end
        text_issues(io, r) if issues && !r.issues.empty?
      end
    end

    private def self.text_issues(io : IO, r : Report) : Nil
      io << "\nIssue retest (" << r.issues.size << ")\n"
      r.issues.each do |i|
        io << "  #" << i.id << "  " << i.severity.label << '/' << i.status.label << "  " << i.title << '\n'
        io << "      " << (i.key.try(&.to_s) || "—") << "  ·  " << i.note << '\n'
      end
    end

    private def self.row_line(row : Row) : String
      String.build do |io|
        io << row.key.method << ' ' << row.key.host << row.key.path
        facts = row.b || row.a
        io << "  ·  " << facts_line(facts) if facts
        row.changes.each { |c| io << "\n      " << c }
      end
    end

    # PUBLIC because `Diff::Record` prints the same line into an Issue/Note body. A second
    # spelling of "what did this side answer with" is how one report's summary and the
    # deliverable filed from it come to describe different responses.
    def self.facts_line(f : Facts) : String
      parts = [] of String
      parts << Compare.status_label(f)
      cts = f.sorted_content_types
      parts << cts.join(", ") unless cts.empty?
      parts << Compare.size_label(f) if f.size_mid
      parts << "#{f.flows} flow#{f.flows == 1 ? "" : "s"}"
      parts.join(" · ")
    end

    private def self.coverage_line(c : Coverage) : String
      String.build do |io|
        io << c.label << ": " << c.flows << " flow" << (c.flows == 1 ? "" : "s")
        io << " over " << c.endpoints << " endpoint" << (c.endpoints == 1 ? "" : "s")
        io << " on " << c.hosts << " host" << (c.hosts == 1 ? "" : "s")
        io << " (" << window(c) << ")"
        io << " [TRUNCATED]" if c.truncated
      end
    end

    private def self.summary_line(r : Report) : String
      counts = r.counts
      ORDER.map { |v| "#{v.label} #{counts[v]}" }.join(" · ")
    end

    # The capture window, as UTC dates — a retest report is read at day granularity, and a
    # date needs no timezone caveat beside it.
    private def self.window(c : Coverage) : String
      from = c.first_seen
      to = c.last_seen
      return "no captures" if from.nil? || to.nil?
      a = utc_date(from)
      b = utc_date(to)
      a == b ? a : "#{a} → #{b}"
    end

    private def self.utc_date(micros : Int64) : String
      (Time.utc(1970, 1, 1) + (micros // 1_000_000).seconds).to_s("%Y-%m-%d")
    end

    # RFC3339 UTC at millisecond precision from unix micros — the `*_iso` convention every
    # gori surface emits. Reimplemented rather than called for the same reason
    # `CLI::Output.iso_time_utc` is: the engine has no dependency on `MCP::` or `CLI::` and
    # should not gain one for three lines. `spec/diff_spec.cr` pins it against them.
    def self.iso(micros : Int64) : String
      sec, micro = micros.divmod(1_000_000)
      (Time.utc(1970, 1, 1) + sec.seconds + micro.microseconds).to_s("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    # ── markdown ────────────────────────────────────────────────────────────────

    # A section an operator pastes straight into a retest deliverable. Same content as
    # `text`, laid out for a document rather than a terminal.
    def self.markdown(r : Report, *, verdicts : Array(Verdict) = LISTED, issues : Bool = true) : String
      String.build do |io|
        io << "## Retest diff — " << r.a.label << " → " << r.b.label << "\n\n"
        markdown_coverage(io, r)
        io << '\n' << "**" << summary_line(r) << "**\n\n"
        # ONE blockquote, its lines separated by a bare `>` — several `>` blocks in a row
        # would render as several quotes, and the caveats are one statement about how to
        # read the counts above them.
        io << "> " << r.caveats.join("\n>\n> ") << '\n' unless r.caveats.empty?
        ORDER.each do |verdict|
          next unless verdicts.includes?(verdict)
          rows = r.rows_of(verdict)
          next if rows.empty?
          io << "\n### " << heading(verdict) << " (" << rows.size << ")\n\n"
          rows.each { |row| markdown_row(io, row) }
        end
        markdown_issues(io, r) if issues && !r.issues.empty?
      end
    end

    private def self.markdown_coverage(io : IO, r : Report) : Nil
      io << "| | A · " << md(r.a.label) << " | B · " << md(r.b.label) << " |\n"
      io << "|---|---|---|\n"
      io << "| flows | " << r.a.flows << " | " << r.b.flows << " |\n"
      io << "| endpoints | " << r.a.endpoints << " | " << r.b.endpoints << " |\n"
      io << "| hosts | " << r.a.hosts << " | " << r.b.hosts << " |\n"
      io << "| captured | " << window(r.a) << " | " << window(r.b) << " |\n"
      io << "| scope | " << md(scope_cell(r.a)) << " | " << md(scope_cell(r.b)) << " |\n"
    end

    private def self.scope_cell(c : Coverage) : String
      return "none" if c.scope_rules.empty?
      "#{c.scope_rules.join("; ")} (#{c.scope_enabled ? "on" : "off"})"
    end

    private def self.markdown_row(io : IO, row : Row) : Nil
      io << "- " << code(endpoint_label(row.key))
      facts = row.b || row.a
      io << " — " << facts_line(facts) if facts
      io << '\n'
      row.changes.each { |c| io << "  - " << c << '\n' }
    end

    # PUBLIC for `Render.facts_line`'s reason: `Diff::Record` names the same endpoint in an
    # Issue title, and one spelling is what keeps the pasted report and the filed issue
    # pointing at the same row.
    def self.endpoint_label(key : Key) : String
      "#{key.method} #{key.host}#{key.path}"
    end

    private def self.markdown_issues(io : IO, r : Report) : Nil
      io << "\n### Issue retest (" << r.issues.size << ")\n\n"
      io << "No request was sent — this reports whether the endpoint each issue was filed " \
            "against still exists and still answers the same way.\n\n"
      r.issues.each do |i|
        io << "- **#" << i.id << "** " << md(i.title) << " (" << i.severity.label << ", " << i.status.label << ")"
        if key = i.key
          io << " — " << code(endpoint_label(key))
        end
        io << " — " << md(i.note) << '\n'
      end
    end

    # Escape the Markdown table/emphasis characters a captured host or an operator's issue
    # title can legitimately contain. A report is a deliverable; a pipe in a title must not
    # split a table cell.
    private def self.md(s : String) : String
      s.gsub('|', "\\|").gsub('`', "'").delete { |c| c == '\n' || c == '\r' }
    end

    # An endpoint as a CODE SPAN. A path comes off the wire, so it can hold a backtick —
    # `/search?q=%60id%60` decoded, or a literal one in a query value — which would close
    # the span and spill the rest of the row into prose in the deliverable an operator was
    # told to paste. CommonMark's own rule for that: fence with a longer run than any run
    # inside, and pad with spaces so a leading/trailing backtick survives.
    private def self.code(text : String) : String
      body = text.delete { |c| c == '\n' || c == '\r' }
      fence = "`" * (longest_backtick_run(body) + 1)
      pad = (body.starts_with?('`') || body.ends_with?('`')) ? " " : ""
      "#{fence}#{pad}#{body}#{pad}#{fence}"
    end

    private def self.longest_backtick_run(s : String) : Int32
      best = 0
      run = 0
      s.each_char do |c|
        run = c == '`' ? run + 1 : 0
        best = run if run > best
      end
      best
    end

    # ── json ────────────────────────────────────────────────────────────────────

    def self.json(r : Report, *, verdicts : Array(Verdict) = ORDER, issues : Bool = true) : String
      JSON.build { |j| json(j, r, verdicts: verdicts, issues: issues) }
    end

    def self.json(j : JSON::Builder, r : Report, *, verdicts : Array(Verdict) = ORDER, issues : Bool = true) : Nil
      counts = r.counts
      j.object do
        j.field("a") { coverage_json(j, r.a) }
        j.field("b") { coverage_json(j, r.b) }
        j.field("counts") do
          j.object { ORDER.each { |v| j.field v.label, counts[v] } }
        end
        j.field("caveats") { j.array { r.caveats.each { |c| j.string c } } }
        j.field("scope_mismatch", r.scope_mismatch?)
        # ONE context for the whole array. `Record::Context` scrubs its labels on
        # construction (a regex per label), and building it per row costs that twice over
        # every endpoint in a report that can carry ten thousand of them.
        ctx = Record::Context.new(r.a.label, r.b.label)
        j.field("endpoints") do
          j.array do
            r.rows.each do |row|
              row_json(j, row, ctx) if verdicts.includes?(row.verdict)
            end
          end
        end
        j.field("issues") { j.array { r.issues.each { |i| issue_json(j, i) } } } if issues
      end
    end

    private def self.coverage_json(j : JSON::Builder, c : Coverage) : Nil
      j.object do
        j.field "label", c.label
        j.field "db_path", c.db_path
        j.field "flows", c.flows
        j.field "endpoints", c.endpoints
        j.field "hosts", c.hosts
        if from = c.first_seen
          j.field "first_seen", from
          j.field "first_seen_iso", iso(from)
        end
        if to = c.last_seen
          j.field "last_seen", to
          j.field "last_seen_iso", iso(to)
        end
        j.field "scope_enabled", c.scope_enabled
        j.field "scope_rules" { j.array { c.scope_rules.each { |s| j.string s } } }
        j.field "truncated", c.truncated
      end
    end

    private def self.row_json(j : JSON::Builder, row : Row, ctx : Record::Context) : Nil
      j.object do
        j.field "verdict", row.verdict.label
        # The one sentence saying what this row is evidence OF — verbatim the sentence a TUI
        # operator's Issue/Note carries (`Diff::Record.observation`). An agent reading this
        # array and calling `create_issue` off it has the coverage-gap caveat AT THE ROW, not
        # only in the report-level `caveats`, which is the level a per-row loop never reads.
        j.field "observation", Record.observation(row, ctx)
        j.field "host", row.key.host
        j.field "method", row.key.method
        j.field "path", row.key.path
        j.field("a") { facts_json(j, row.a) }
        j.field("b") { facts_json(j, row.b) }
        j.field "changes" do
          j.array do
            row.changes.each do |c|
              j.object do
                j.field "axis", c.axis.label
                j.field "from", c.from
                j.field "to", c.to
              end
            end
          end
        end
      end
    end

    private def self.facts_json(j : JSON::Builder, f : Facts?) : Nil
      unless f
        j.null
        return
      end
      j.object do
        j.field "statuses" { j.array { f.sorted_statuses.each { |s| j.number s } } }
        j.field "pending", f.pending?
        j.field "content_types" { j.array { f.sorted_content_types.each { |c| j.string c } } }
        j.field "min_size", f.min_size
        j.field "max_size", f.max_size
        j.field "flows", f.flows
        j.field "auth_required", f.auth_required?
        j.field "first_seen", f.first_seen
        j.field "first_seen_iso", iso(f.first_seen)
        j.field "last_seen", f.last_seen
        j.field "last_seen_iso", iso(f.last_seen)
        # The concrete capture behind a folded template — what a flow-level diff takes.
        j.field "sample_flow_id", f.sample_flow_id
        j.field "sample_target", f.sample_target
      end
    end

    private def self.issue_json(j : JSON::Builder, i : IssueRetest) : Nil
      j.object do
        j.field "id", i.id
        j.field "title", i.title
        j.field "severity", i.severity.label
        j.field "status", i.status.label
        if key = i.key
          j.field "host", key.host
          j.field "method", key.method
          j.field "path", key.path
        end
        j.field "verdict", i.verdict.try(&.label)
        j.field "changes" do
          j.array { i.changes.each { |c| j.string c.to_s } }
        end
        j.field "note", i.note
      end
    end
  end
end
