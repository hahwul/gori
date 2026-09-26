require "json"
require "./stats"

module Gori::Repeater::Timing
  # The SINGLE JSON/text shape for a timing-analysis report, emitted by BOTH `gori run repeater
  # timing --format json` and the MCP `timing_requests` tool — so the two can't drift. Pure over a
  # `Stats::Report` plus a `Subject` (no Store / TUI dependency), the `Sequencer::Present` contract.
  module Present
    # What the report is ABOUT — a `Stats::Report` is pure over the durations and carries none of it.
    # `a`/`b` are the two members' labels (request lines / ids), so a reader knows which side "A" is.
    record Subject,
      a_label : String,
      b_label : String,
      origin : String? = nil,
      transport : String? = nil, # "single-packet h2" / "last-byte-sync h1" / "interleaved"
      mode : String? = nil

    def self.report_json(rep : Stats::Report, subject : Subject) : String
      JSON.build { |j| report_object(j, rep, subject) }
    end

    def self.report_object(j : JSON::Builder, rep : Stats::Report, subject : Subject) : Nil
      j.object do
        j.field "verdict", rep.verdict.to_s.underscore
        j.field "verdict_label", rep.verdict.label
        j.field "rationale", rep.rationale
        subject.origin.try { |o| j.field "target", o }
        subject.transport.try { |t| j.field "transport", t }
        subject.mode.try { |m| j.field "mode", m }
        j.field "iterations", rep.iterations
        j.field "pairs_valid", rep.pairs_valid
        j.field "median_gap_us", rep.median_gap_us
        j.field "order" do
          j.object do
            j.field "a_slower", rep.a_slower
            j.field "b_slower", rep.b_slower
            j.field "ties", rep.ties
            j.field "a_slower_frac", rep.a_slower_frac
            j.field "p_value", rep.p_value
          end
        end
        lo = rep.hist_min.to_f
        hi = rep.hist_max.to_f
        j.field "histogram_scale" do
          j.object do
            j.field "min_us", rep.hist_min
            j.field "max_us", rep.hist_max
            j.field "bins", Stats::HIST_BINS
          end
        end
        j.field "variants" do
          j.object do
            j.field "a" { variant_object(j, subject.a_label, rep.a, lo, hi) }
            j.field "b" { variant_object(j, subject.b_label, rep.b, lo, hi) }
          end
        end
      end
    end

    private def self.variant_object(j : JSON::Builder, label : String, d : Stats::VariantDist,
                                    lo : Float64, hi : Float64) : Nil
      j.object do
        j.field "label", label
        j.field "n", d.n
        j.field "min_us", d.min
        j.field "q1_us", d.q1
        j.field "median_us", d.median
        j.field "q3_us", d.q3
        j.field "max_us", d.max
        j.field "histogram" do
          j.array do
            Stats.histogram(d.samples, Stats::HIST_BINS, lo, hi).each { |c| j.number c }
          end
        end
      end
    end

    # A plain-text report for `gori run repeater timing` (and a human-readable fallback). Durations
    # are formatted with a pure µs/ms helper (this module stays surface-free, like Sequencer::Present).
    def self.report_text(rep : Stats::Report, subject : Subject) : String
      String.build do |io|
        io << "verdict:  " << rep.verdict.label << "  (" << rep.rationale << ")\n"
        subject.origin.try { |o| io << "target:   " << o << "\n" }
        io << "transport: " << (subject.transport || subject.mode || "—") << "\n"
        io << "pairs:    " << rep.pairs_valid << " usable / " << rep.iterations << " sent\n"
        io << "order:    A slower in " << rep.a_slower << ", B slower in " << rep.b_slower
        io << ", ties " << rep.ties << "  (p=" << Stats.fmt_p(rep.p_value) << ")\n"
        io << "\n"
        variant_line(io, "A  " + subject.a_label, rep.a)
        variant_line(io, "B  " + subject.b_label, rep.b)
      end
    end

    private def self.variant_line(io : IO, label : String, d : Stats::VariantDist) : Nil
      if d.n == 0
        io << label << "\n    (no responses)\n"
        return
      end
      io << label << "\n"
      io << "    n=" << d.n
      io << "  min " << Stats.fmt_us(d.min)
      io << "  q1 " << Stats.fmt_us(d.q1.round.to_i64)
      io << "  med " << Stats.fmt_us(d.median.round.to_i64)
      io << "  q3 " << Stats.fmt_us(d.q3.round.to_i64)
      io << "  max " << Stats.fmt_us(d.max) << "\n"
    end
  end
end
