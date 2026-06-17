module Gori
  module Replay
    enum DiffKind
      Same
      Add # present only in the new (replay) response
      Del # present only in the original response
    end

    record DiffLine, kind : DiffKind, text : String

    # Minimal LCS line diff. `a` = original, `b` = new (replay). Capped to keep
    # the O(n*m) table bounded; very long bodies are truncated (the cap is noted
    # by the caller). Good enough for response comparison this milestone.
    module Diff
      MAX_LINES = 1500

      def self.lines(a : Array(String), b : Array(String)) : Array(DiffLine)
        a = a.first(MAX_LINES)
        b = b.first(MAX_LINES)
        m = a.size
        n = b.size

        # dp[i][j] = LCS length of a[i..] and b[j..]
        dp = Array.new(m + 1) { Array.new(n + 1, 0) }
        (m - 1).downto(0) do |i|
          (n - 1).downto(0) do |j|
            dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1])
          end
        end

        out = [] of DiffLine
        i = 0
        j = 0
        while i < m && j < n
          if a[i] == b[j]
            out << DiffLine.new(DiffKind::Same, a[i]); i += 1; j += 1
          elsif dp[i + 1][j] >= dp[i][j + 1]
            out << DiffLine.new(DiffKind::Del, a[i]); i += 1
          else
            out << DiffLine.new(DiffKind::Add, b[j]); j += 1
          end
        end
        while i < m
          out << DiffLine.new(DiffKind::Del, a[i]); i += 1
        end
        while j < n
          out << DiffLine.new(DiffKind::Add, b[j]); j += 1
        end
        out
      end

      # Count of changed (added/removed) lines — for a quick summary.
      def self.change_count(diff : Array(DiffLine)) : Int32
        diff.count { |d| d.kind != DiffKind::Same }
      end
    end
  end
end
