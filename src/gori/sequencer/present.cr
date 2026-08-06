require "json"
require "./stats"

module Gori::Sequencer
  # The SINGLE JSON shape for a Sequencer report, emitted by both `gori run sequence
  # --format json` and the MCP sequence_results tool — so the two can't drift. Pure over
  # a Stats::Report (no Store/TUI dependency).
  module Present
    # What the report is ABOUT. A `Stats::Report` is pure over a token list and deliberately
    # carries none of this, but a file on disk or an Issue in the report has to say which
    # target and which descriptor produced the verdict — a bare "CRITICAL, 41 bits" is
    # unactionable a week later. Every surface that writes a report out supplies one, so the
    # Markdown export and the Issue it can be promoted to describe the run in the same words.
    record Subject,
      descriptor : String,    # the TokenLoc label — `cookie "SID"`, `header X-CSRF-Token`
      origin : String? = nil, # scheme://host:port; nil for a manual paste (no network)
      mode : String? = nil,
      session : String? = nil

    def self.report_json(rep : Stats::Report) : String
      JSON.build { |j| report_object(j, rep) }
    end

    def self.report_object(j : JSON::Builder, rep : Stats::Report) : Nil
      j.object do
        j.field "rating", rep.rating.label
        j.field "rationale", rep.rationale
        j.field "sample_count", rep.sample_count
        j.field "usable_count", rep.usable_count
        j.field "effective_entropy_bits", rep.effective_entropy
        j.field "shannon_bits_per_char", rep.bits_per_char
        j.field "charset_size", rep.charset_size
        j.field "charset", rep.charset_label
        j.field "min_len", rep.min_len
        j.field "max_len", rep.max_len
        j.field "variable_length", rep.variable_length
        j.field "constant_positions", rep.constant_positions
        # Which end of the token the per-position window was anchored to — without it a
        # consumer cannot tell WHICH `min_len` bytes `constant_positions` counted.
        j.field "entropy_alignment", rep.aligned_from_end ? "end" : "start"
        j.field "uniqueness", rep.uniqueness
        j.field "duplicate_count", rep.duplicate_count
        j.field "sequential", rep.sequential
        j.field "tests" do
          j.array do
            rep.tests.each do |t|
              j.object do
                j.field "name", t.name
                j.field "value", t.value
                j.field "detail", t.detail
                j.field "verdict", t.verdict.label
              end
            end
          end
        end
      end
    end

    # A plain-text report for `gori run sequence` (and a human-readable MCP fallback).
    def self.report_text(rep : Stats::Report) : String
      String.build do |io|
        io << "rating:    " << rep.rating.label << "  (" << rep.rationale << ")\n"
        io << "samples:   " << rep.usable_count << " usable / " << rep.sample_count << " total\n"
        io << "entropy:   " << rep.effective_entropy.round(1) << " bits effective · "
        io << rep.bits_per_char.round(2) << " bits/char\n"
        io << "charset:   " << rep.charset_size << " (" << rep.charset_label << ")\n"
        io << "length:    " << (rep.variable_length ? "#{rep.min_len}-#{rep.max_len} (variable)" : "#{rep.min_len} (fixed)") << "\n"
        io << "structure: " << structure_line(rep) << "\n"
        io << "unique:    " << rep.duplicate_count << " duplicate(s)\n"
        io << "\ntests:\n"
        rep.tests.each do |t|
          io << "  " << t.verdict.label.ljust(5) << " " << t.name.ljust(14) << " " << t.value
          io << "  (" << t.detail << ")" unless t.detail.empty?
          io << "\n"
        end
      end
    end

    # The Markdown report — the TUI's "Export report" file and, minus its heading, the body of
    # an Issue promoted from a verdict. ONE renderer for both so a filed Issue and the file
    # attached next to it cannot describe the same run differently.
    #
    # It carries NO token values, and cannot: a `Stats::Report` holds frequency tables and
    # verdicts, never the sample. That is the property that lets this be written to an operator-
    # chosen path and pasted into a report without leaking live session credentials.
    def self.report_markdown(rep : Stats::Report, subject : Subject, heading : String? = nil) : String
      String.build do |io|
        io << "# " << heading << "\n\n" if heading
        io << "**" << rep.rating.label << "** — " << rep.rationale << "\n\n"
        io << "| | |\n| --- | --- |\n"
        row(io, "Target", subject.origin || "—")
        row(io, "Token", subject.descriptor)
        subject.mode.try { |m| row(io, "Mode", m) }
        subject.session.try { |s| row(io, "Session", s) }
        row(io, "Samples", "#{rep.usable_count} usable / #{rep.sample_count} collected")
        io << "\n## Entropy\n\n| measure | value |\n| --- | --- |\n"
        row(io, "effective entropy", "#{rep.effective_entropy.round(1)} bits")
        row(io, "shannon", "#{rep.bits_per_char.round(2)} bits/char")
        row(io, "charset", "#{rep.charset_size} (#{rep.charset_label})")
        row(io, "length", rep.variable_length ? "#{rep.min_len}-#{rep.max_len} (variable)" : "#{rep.min_len} (fixed)")
        row(io, "structure", structure_line(rep))
        row(io, "unique", "#{(rep.uniqueness * 100).round(1)}% (#{rep.duplicate_count} duplicate#{rep.duplicate_count == 1 ? "" : "s"})")
        io << "\n## Tests\n\n| test | result | detail | verdict |\n| --- | --- | --- | --- |\n"
        rep.tests.each do |t|
          io << "| " << cell(t.name) << " | " << cell(t.value) << " | " << cell(t.detail)
          io << " | " << t.verdict.label << " |\n"
        end
      end
    end

    # Title for an Issue filed from a verdict. Leads with the grade and names the descriptor,
    # so the Issues list reads as findings rather than as five identical "Sequencer" rows.
    def self.issue_title(rep : Stats::Report, subject : Subject) : String
      "#{rep.rating.label.capitalize} token randomness: #{subject.descriptor}"
    end

    # `Store::Severity#label` for a rating. Spelled as a STRING because this module is pure
    # over a Stats::Report and pulling `Store::Severity` in would drag the whole db layer into
    # the CLI/MCP report path. `spec/sequencer/present_spec.cr` pins every value against
    # `Store::Severity.parse?`, so the indirection cannot silently rot into a label the store
    # does not know.
    #
    # A Secure verdict maps to `info`, not to "no issue": an operator who explicitly promotes
    # one is recording that the token WAS tested, which is worth having in the report.
    def self.issue_severity_label(rep : Stats::Report) : String
      case rep.rating
      in Stats::Rating::Critical then "critical"
      in Stats::Rating::Weak     then "high"
      in Stats::Rating::Moderate then "medium"
      in Stats::Rating::Secure   then "info"
      end
    end

    private def self.structure_line(rep : Stats::Report) : String
      return "—" if rep.min_len <= 0
      anchor = rep.aligned_from_end ? "from token end" : "from token start"
      "#{rep.constant_positions}/#{rep.min_len} fixed positions (#{anchor})"
    end

    private def self.row(io : IO, label : String, value : String) : Nil
      io << "| " << cell(label) << " | " << cell(value) << " |\n"
    end

    # A pipe inside a cell would split it into two columns and silently drop the rest of the
    # row. Reachable from a real descriptor: `regex /a|b/` is an ordinary token location.
    #
    # Byte-wise, not `gsub`: a one-byte needle makes Crystal's gsub walk the subject as CHARS,
    # and a descriptor built from a response header name is not guaranteed valid UTF-8 — every
    # invalid byte would come back U+FFFD. This report can be written to a file and stored as
    # an Issue's notes, so it must not be the thing that rewrites bytes.
    private def self.cell(s : String) : String
      return s unless s.to_slice.includes?(0x7c_u8) # '|'
      String.build do |io|
        s.to_slice.each do |b|
          io.write_byte(0x5c_u8) if b == 0x7c_u8 # '\'
          io.write_byte(b)
        end
      end
    end
  end
end
