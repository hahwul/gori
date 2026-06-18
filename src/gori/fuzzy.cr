module Gori
  # Fuzzy subsequence matcher (shared by command palette and project list picker).
  # A query matches text if every query character appears in-order (not necessarily
  # contiguous). Score rewards contiguous runs ("run" bonus) and earlier matches
  # (negative position penalty). Higher score = better match. Returns nil on failure.
  #
  # Used to deliver the "fzf feeling" for filtering without pulling in a heavy
  # dependency. See Verb::Registry#search and Tui::ProjectPicker#filtered_projects.
  module Fuzzy
    def self.score(query : String, text : String) : Int32?
      return 0 if query.empty?
      score = 0
      ti = 0
      run = 0
      query.each_char do |qc|
        found = false
        while ti < text.size
          tc = text[ti]
          ti += 1
          if tc == qc
            run += 1
            score += 10 + run * 5 - ti # contiguity bonus, earlier-is-better
            found = true
            break
          else
            run = 0
          end
        end
        return nil unless found
      end
      score
    end
  end
end
