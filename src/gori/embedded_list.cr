module Gori
  # The ONE reading of a compile-time embedded list — `Discover::Wordlist`, `Miner::Wordlist`,
  # `Fuzz::Presets` (#1151). The curated `.txt` convention is one entry per line, surrounding
  # whitespace trimmed, blank and `#` lines skipped. It is the convention for gori's OWN assets
  # only: an operator's merge file is material, read with each caller's own fidelity rule (see
  # `merge_user_file` / `Presets.load`), and must never be routed through `parse`.
  #
  # `Env::USER_AGENTS` holds the same convention, but applies it in a macro so an empty corpus
  # fails the build — keep the two in step.
  module EmbeddedList
    def self.parse(raw : String) : Array(String)
      out = [] of String
      raw.each_line do |line|
        stripped = line.strip
        out << stripped unless stripped.empty? || stripped.starts_with?('#')
      end
      out
    end

    # De-duplicated, first occurrence wins, so a built-in entry keeps its place ahead of the
    # same value repeated by a merge file.
    def self.dedup(list : Array(String)) : Array(String)
      seen = Set(String).new
      list.select { |n| seen.add?(n) }
    end
  end
end
