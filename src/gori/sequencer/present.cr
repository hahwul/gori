require "json"
require "./stats"

module Gori::Sequencer
  # The SINGLE JSON shape for a Sequencer report, emitted by both `gori run sequence
  # --format json` and the MCP sequence_results tool — so the two can't drift. Pure over
  # a Stats::Report (no Store/TUI dependency).
  module Present
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
        io << "unique:    " << rep.duplicate_count << " duplicate(s)\n"
        io << "\ntests:\n"
        rep.tests.each do |t|
          io << "  " << t.verdict.label.ljust(5) << " " << t.name.ljust(14) << " " << t.value
          io << "  (" << t.detail << ")" unless t.detail.empty?
          io << "\n"
        end
      end
    end
  end
end
