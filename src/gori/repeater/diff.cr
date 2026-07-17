module Gori
  module Repeater
    enum DiffKind
      Same
      Add # present only in the new (repeater) response
      Del # present only in the original response
    end

    record DiffLine, kind : DiffKind, text : String

    # Minimal LCS line diff. `a` = original, `b` = new (repeater). Capped to keep
    # the O(n*m) table bounded; very long bodies are truncated (the cap is noted
    # by the caller). Good enough for response comparison this milestone.
    #
    # Two similar messages share long identical runs, so the table is kept small by
    # (1) peeling the common prefix/suffix — the bulk of the lines for a near-match —
    # down to just the changed middle, and (2) interning lines to Int32 ids so the DP
    # compares integers on one flat, cache-friendly buffer instead of re-comparing
    # strings across an array-of-arrays. The result is still a minimal (optimal) diff.
    module Diff
      MAX_LINES = 1500

      def self.lines(a : Array(String), b : Array(String)) : Array(DiffLine)
        a = a.first(MAX_LINES)
        b = b.first(MAX_LINES)
        m = a.size
        n = b.size

        # Intern each distinct line to a small Int32 id. Hashing pays once per line;
        # the O(m*n) DP then compares ids (aid[i] == bid[j] iff a[i] == b[j]).
        ids = {} of String => Int32
        aid = a.map { |s| ids[s]? || (ids[s] = ids.size) }
        bid = b.map { |s| ids[s]? || (ids[s] = ids.size) }

        # Common prefix, then common suffix of what's left. Peeling the prefix is
        # exactly what the greedy backtrack does; peeling the suffix likewise keeps
        # the diff optimal (identical trailing lines are always Same).
        p = 0
        while p < m && p < n && aid[p] == bid[p]
          p += 1
        end
        s = 0
        while s < m - p && s < n - p && aid[m - 1 - s] == bid[n - 1 - s]
          s += 1
        end

        acc = Array(DiffLine).new(m + n)
        p.times { |k| acc << DiffLine.new(DiffKind::Same, a[k]) }
        emit_middle(acc, a, b, aid, bid, p, m - p - s, n - p - s)
        s.times { |k| acc << DiffLine.new(DiffKind::Same, a[m - s + k]) }
        acc
      end

      # Diff the changed middle a[p, mm] vs b[p, nn] (the prefix/suffix already peeled),
      # appending its del/add/same rows to `acc`. A one-sided middle is a pure run.
      private def self.emit_middle(acc : Array(DiffLine), a : Array(String), b : Array(String),
                                   aid : Array(Int32), bid : Array(Int32),
                                   p : Int32, mm : Int32, nn : Int32) : Nil
        if mm == 0
          nn.times { |j| acc << DiffLine.new(DiffKind::Add, b[p + j]) }
        elsif nn == 0
          mm.times { |i| acc << DiffLine.new(DiffKind::Del, a[p + i]) }
        else
          w = nn + 1
          backtrack(acc, a, b, aid, bid, lcs_table(aid, bid, p, mm, nn, w), p, mm, nn, w)
        end
      end

      # dp[i*w + j] = LCS length of amid[i..] and bmid[j..] (amid[i] = aid[p + i]), filled
      # bottom-up in one flat zeroed buffer — the boundary row/col stay 0 — so the DP is
      # one contiguous allocation the CPU can stream, not an array-of-arrays.
      private def self.lcs_table(aid : Array(Int32), bid : Array(Int32),
                                 p : Int32, mm : Int32, nn : Int32, w : Int32) : Slice(Int32)
        dp = Slice(Int32).new((mm + 1) * w, 0)
        i = mm - 1
        while i >= 0
          ai = aid[p + i]
          row = i * w
          nxt = row + w
          j = nn - 1
          while j >= 0
            dp[row + j] = ai == bid[p + j] ? dp[nxt + j + 1] + 1 : Math.max(dp[nxt + j], dp[row + j + 1])
            j -= 1
          end
          i -= 1
        end
        dp
      end

      # Walk the filled table top-down, emitting Same/Del/Add with the same tie-break as
      # the classic backtrack (prefer Del on a length tie), then drain either surplus side.
      private def self.backtrack(acc : Array(DiffLine), a : Array(String), b : Array(String),
                                 aid : Array(Int32), bid : Array(Int32), dp : Slice(Int32),
                                 p : Int32, mm : Int32, nn : Int32, w : Int32) : Nil
        i = 0
        j = 0
        while i < mm && j < nn
          if aid[p + i] == bid[p + j]
            acc << DiffLine.new(DiffKind::Same, a[p + i]); i += 1; j += 1
          elsif dp[(i + 1) * w + j] >= dp[i * w + j + 1]
            acc << DiffLine.new(DiffKind::Del, a[p + i]); i += 1
          else
            acc << DiffLine.new(DiffKind::Add, b[p + j]); j += 1
          end
        end
        while i < mm
          acc << DiffLine.new(DiffKind::Del, a[p + i]); i += 1
        end
        while j < nn
          acc << DiffLine.new(DiffKind::Add, b[p + j]); j += 1
        end
      end

      # Count of changed (added/removed) lines — for a quick summary.
      def self.change_count(diff : Array(DiffLine)) : Int32
        diff.count { |d| d.kind != DiffKind::Same }
      end
    end
  end
end
