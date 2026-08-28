require "../store"
require "../issues_export" # Issues::Export.one_line — the shared scrub/collapse helper
require "./compare"
require "./keys"
require "./render"

module Gori::Diff
  # A retest row on its way to an Issue or a Note.
  #
  # The diff is the one surface in gori whose ENTIRE output is a list of things worth
  # writing down, and the context it holds — which two projects were compared, what each
  # side actually answered, which axis moved — is exactly what a retyped issue loses. This
  # module is the single place that context becomes text, so the Issue, the Note and the
  # agent-facing JSON (`Render.row_json`) cannot describe one row three different ways.
  #
  # Pure: no store, no TUI, no clock. That matters most for the sentence this exists to
  # protect. #824 split "B never asked" from "B asked and got a 404" precisely because a
  # report that collapses them files removals it never observed — and a record is the
  # point where a verdict stops being a screenful an operator re-reads and becomes a claim
  # in a deliverable. `observation` is where that split survives or quietly dies.
  module Record
    # Which slot a fact came from. A `Symbol` would do and did not: `linked` is compared
    # against a side twice below, and `:a`/`:A`/`:added` are all one typo apart with no
    # compiler between them.
    enum Side
      A
      B
    end

    # The keying caveat every record carries, because a folded template row is NOT one
    # captured URL and an issue filed against `/users/{uuid}` that reads as a literal path
    # sends the next reader to a URL nobody ever requested.
    KEYING_NOTE = "Endpoints are keyed by the Sitemap's folded path template, so this row " \
                  "can stand for many captured URLs; the flow named above is the newest of them."

    # Which two projects were compared, which slot names the project the record is being
    # WRITTEN to, and whether that side's capture actually got attached.
    #
    # `entity_links.ref_id` is a bare rowid with no project column (see `store/schema.cr`),
    # so a flow id from the other engagement's database either names a different flow here
    # or names nothing. The reachable side is linked; the other is NAMED in the body, which
    # is the honest version of "link, do not copy" when the link cannot cross the seam.
    #
    # `home` and `linked` are two facts, not one. A capture on the home side that was pruned
    # between the run and the record is unlinkable for a completely different reason than one
    # sitting in the other project's database, and an evidence line that spells the first as
    # the second sends the reader to a project where it was never going to be.
    struct Context
      getter a_label : String
      getter b_label : String
      getter a_path : String
      getter b_path : String
      getter home : Side?
      getter? linked : Bool

      # Labels are project NAMES — operator text that ends up in an issue title and a TUI
      # form. Scrubbed once here so nothing below has to remember to: `one_line` also fixes
      # invalid UTF-8, which `Hotkeys.retag`'s regex raises on when it reaches display text.
      #
      # The PATHS matter for the same reason the project picker prints a date beside each
      # name (`Runner#diff_project_label`): two engagements against one target are routinely
      # named alike, and a record whose only handle on "which q3" is the word "q3" identifies
      # neither side. Optional, because the JSON row has no project on disk to name.
      def initialize(a_label : String, b_label : String, @home : Side? = nil,
                     @linked : Bool = false, a_path : String = "", b_path : String = "")
        @a_label = Issues::Export.one_line(a_label)
        @b_label = Issues::Export.one_line(b_label)
        @a_path = Issues::Export.one_line(a_path)
        @b_path = Issues::Export.one_line(b_path)
      end

      def paths? : Bool
        !@a_path.empty? || !@b_path.empty?
      end
    end

    # What an open-site hands to `IssueForm` (or writes straight into a note).
    record Draft,
      title : String,
      severity : Store::Severity,
      body : String,
      host : String do
      # The note form of the same record. The title becomes the note's FIRST line, which is
      # what `Notes.title` names the sub-tab from — without it every note filed from one
      # diff would carry the identical "Retest diff — q1 → q3" name.
      def note_text : String
        "#{title}\n\n#{body}"
      end
    end

    def self.draft(row : Row, ctx : Context) : Draft
      Draft.new(title(row, ctx), severity(row), body(row, ctx), row.key.host)
    end

    # A coverage gap is NOT a finding — that is the whole reason `removed` and `gone` are
    # two verdicts — so it opens on `info` rather than on the form's `medium`. Every other
    # verdict takes the form's own default and the operator moves it: the diff measured
    # that an axis moved, it did not judge what that is worth (P4).
    def self.severity(row : Row) : Store::Severity
      row.verdict.removed? ? Store::Severity::Info : Store::Severity::Medium
    end

    # One line for the Issues list: the endpoint, then what the retest saw. The endpoint is
    # not abbreviated — it is the identity here, and two rows of one host that differ only
    # in their tail would read alike. The form the operator commits from is where a title
    # gets shortened, by the human who knows which half matters.
    def self.title(row : Row, ctx : Context) : String
      "#{endpoint(row.key)} — #{title_tail(row, ctx)}"
    end

    # `METHOD host/path`, scrubbed. A captured host or target can be invalid UTF-8 and can
    # carry control bytes; both reach a TUI form title from here.
    def self.endpoint(key : Key) : String
      Issues::Export.one_line("#{key.method} #{key.host}#{key.path}")
    end

    # The sentence the record exists for: what this row is EVIDENCE of, and — for the two
    # absence verdicts — what it is not.
    #
    # `removed` is the one that matters. An endpoint the newer capture never requested is a
    # hole in this retest's coverage; a record that spells that as "removed" reports a fix
    # the engagement never observed, and a client acting on it stops testing something that
    # is still live. `added` gets the mirror caveat for the same reason, one side over.
    def self.observation(row : Row, ctx : Context) : String
      case row.verdict
      in .added?
        "#{ctx.b_label} captured this endpoint and #{ctx.a_label} captured no request to it. " \
        "It may be new, or the baseline may simply never have visited it — this diff has no " \
        "evidence either way."
      in .removed?
        "#{ctx.b_label} captured NO request to this endpoint, so this diff observed nothing " \
        "about it. That is a gap in the retest's coverage, not evidence the endpoint was " \
        "removed — request it before recording it as gone."
      in .gone?
        "#{ctx.b_label} asked and every answer was #{b_statuses(row)}, where #{ctx.a_label} " \
        "reached it. That is captured evidence the endpoint is gone."
      in .changed?
        "Both captures reached this endpoint and the answer moved beyond the retest tolerance " \
        "on #{axes_phrase(row)}. Size is compared against a band and status by CLASS, so an " \
        "axis that moved inside the tolerance is deliberately not listed above."
      in .unchanged?
        # Careful the other way round: this row is not a claim that a finding EXISTS here.
        # It is a claim about what moved, which is nothing this diff can measure.
        "Both captures reached this endpoint and the answers are equivalent within the retest " \
        "tolerance — nothing this diff can see moved, so anything filed against it in " \
        "#{ctx.a_label} is unlikely to have been fixed."
      end
    end

    # The full record: what was compared, what each side answered, what moved, what that is
    # and is not evidence of, and where the bytes are.
    def self.body(row : Row, ctx : Context) : String
      String.build do |io|
        io << "Retest diff — " << ctx.a_label << " (baseline) → " << ctx.b_label << " (newer)\n\n"
        field(io, "Endpoint", endpoint(row.key))
        field(io, "Verdict", Render.heading(row.verdict))
        io << '\n'
        field(io, "Baseline", side_line(ctx.a_label, row.a))
        field(io, "Newer", side_line(ctx.b_label, row.b))
        unless row.changes.empty?
          io << '\n'
          row.changes.each_with_index { |c, i| field(io, i.zero? ? "Changes" : "", c.to_s) }
        end
        io << '\n' << observation(row, ctx) << '\n'
        io << "\nEvidence\n"
        evidence_lines(row, ctx).each { |line| io << "  " << line << '\n' }
        # WHICH q3. Two engagements against one target routinely carry the same name, and
        # this block is also the answer to "where do I open the side that could not be
        # linked" — so it sits directly under the evidence it qualifies.
        if ctx.paths?
          io << "\nProjects\n"
          io << "  " << ctx.a_label << " (baseline) — " << ctx.a_path << '\n'
          io << "  " << ctx.b_label << " (newer) — " << ctx.b_path << '\n'
        end
        io << '\n' << KEYING_NOTE << '\n'
      end
    end

    # The label column every body row lines up on. One writer, because a body whose columns
    # disagree is read as two different documents pasted together.
    LABEL_W = 11

    private def self.field(io : IO, label : String, value : String) : Nil
      io << label.ljust(LABEL_W) << value << '\n'
    end

    private def self.title_tail(row : Row, ctx : Context) : String
      case row.verdict
      in .added?     then "captured only in #{ctx.b_label}"
      in .removed?   then "not requested in #{ctx.b_label} (coverage gap, not a removal)"
      in .gone?      then "gone in #{ctx.b_label} (#{b_statuses(row)})"
      in .changed?   then changed_tail(row)
      in .unchanged? then "unchanged since #{ctx.a_label}"
      end
    end

    # The lead change, plus how many more there were. A title that concatenated all four
    # axes is a title nothing can list.
    private def self.changed_tail(row : Row) : String
      first = row.changes.first?
      return "answers differently" unless first
      rest = row.changes.size - 1
      rest > 0 ? "#{first} (+#{rest} more)" : first.to_s
    end

    private def self.axes_phrase(row : Row) : String
      names = row.changes.map(&.axis.label)
      return "no measured axis" if names.empty?
      return names.first if names.size == 1
      "#{names[0..-2].join(", ")} and #{names.last}"
    end

    # What B answered, as a report prints it. `row.b` is nilable on every verdict and
    # non-nil on the two that call this; the fallback names the rule rather than the
    # observation, so a caller that ever gets here cannot read it as a captured status.
    private def self.b_statuses(row : Row) : String
      f = row.b
      f ? Compare.status_label(f) : "404/410"
    end

    private def self.side_line(label : String, f : Facts?) : String
      return "#{label} · no request captured" unless f
      "#{label} · #{Render.facts_line(f)} · flow ##{f.sample_flow_id}"
    end

    private def self.evidence_lines(row : Row, ctx : Context) : Array(String)
      [evidence_line(Side::A, ctx.a_label, row.a, ctx),
       evidence_line(Side::B, ctx.b_label, row.b, ctx)]
    end

    private def self.evidence_line(side : Side, label : String, f : Facts?, ctx : Context) : String
      return "#{label} — no capture on this side" unless f
      ref = "#{label} flow ##{f.sample_flow_id}"
      if ctx.home == side
        # The record's own project. Linked, unless the capture was pruned between the run
        # that produced this row and the keystroke that filed it.
        return ctx.linked? ? "#{ref} — linked to this record" : "#{ref} — no longer captured in this project; nothing left to link"
      end
      # Not a failure and not hidden: `entity_links` holds a rowid with no project column,
      # so the other engagement's flow cannot be linked from this store. Naming it WITH the
      # target it was captured on is what keeps the evidence reachable — open that project
      # and the id resolves.
      "#{ref} (#{Issues::Export.one_line(f.sample_target)}) — in #{label}'s own database; " \
      "entity links do not cross projects"
    end
  end
end
