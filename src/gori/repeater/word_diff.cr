module Gori
  module Repeater
    # INTRA-line diff: which parts of a changed line actually changed.
    #
    # A line diff can only say "this line is different", so the Comparer painted a whole
    # changed row red on the left and green on the right. For the comparisons this tab is
    # actually used for — the same response with one flipped field, a re-signed token, a
    # different `id` in a JSON object — that is the entire line lit up to report a
    # ten-character difference, and finding the difference was left to the operator's eyes.
    #
    # The unit is a TOKEN, not a character: a run of word characters, or a run of anything
    # else. Character-level LCS on a minified body produces a shredded highlight (every
    # brace and quote its own island); tokens keep `"user"` → `"admin"` as one legible
    # change and keep the table small enough to run on every visible row of every frame.
    module WordDiff
      # Past this many tokens on either side the intra-line highlight is dropped and the
      # caller falls back to the whole-line one. The DP is O(m*n) and this runs per VISIBLE
      # row, so the ceiling is what keeps a minified multi-KB line from costing a frame.
      # A line with 400+ tokens has no legible "the changed part" to point at anyway.
      MAX_TOKENS = 400

      # One run of a line, flagged with whether it differs from the other side.
      record Piece, text : String, changed : Bool

      # `a` (left/old) and `b` (right/new) split into pieces, each side complete: the
      # concatenation of a side's piece texts is exactly the line it came from, so a caller
      # can style the pieces and lose nothing.
      def self.pieces(a : String, b : String) : {Array(Piece), Array(Piece)}
        return whole(a, b) if a.empty? || b.empty?
        at = tokenize(a, MAX_TOKENS)
        return whole(a, b) unless at
        bt = tokenize(b, MAX_TOKENS)
        return whole(a, b) unless bt

        ids = {} of String => Int32
        aid = at.map { |s| ids[s]? || (ids[s] = ids.size) }
        bid = bt.map { |s| ids[s]? || (ids[s] = ids.size) }

        head, tail = peel(aid, bid)
        a_flags = Array(Bool).new(aid.size, false)
        b_flags = Array(Bool).new(bid.size, false)
        mark_middle(a_flags, b_flags, aid, bid, head,
          aid.size - head - tail, bid.size - head - tail)
        {merge(at, a_flags), merge(bt, b_flags)}
      end

      # The fallback: nothing usable to point at inside the line, so each side is one changed
      # run — exactly what a changed row rendered before this module existed.
      private def self.whole(a : String, b : String) : {Array(Piece), Array(Piece)}
        {[Piece.new(a, true)], [Piece.new(b, true)]}
      end

      # Lengths of the common head and, after it, the common tail. On the shape this exists
      # for — one field changed in an otherwise identical line — the peel alone leaves a
      # middle of one or two tokens, and the DP never runs on anything larger.
      private def self.peel(aid : Array(Int32), bid : Array(Int32)) : {Int32, Int32}
        m = aid.size
        n = bid.size
        head = 0
        while head < m && head < n && aid[head] == bid[head]
          head += 1
        end
        tail = 0
        while tail < m - head && tail < n - head && aid[m - 1 - tail] == bid[n - 1 - tail]
          tail += 1
        end
        {head, tail}
      end

      # Flag the changed tokens of the un-peeled middle. A one-sided middle is a pure
      # insertion or deletion; otherwise the LCS says which tokens survive on both sides
      # and everything else is a change.
      private def self.mark_middle(a_flags : Array(Bool), b_flags : Array(Bool),
                                   aid : Array(Int32), bid : Array(Int32),
                                   p : Int32, mm : Int32, nn : Int32) : Nil
        if mm == 0
          nn.times { |j| b_flags[p + j] = true }
          return
        end
        if nn == 0
          mm.times { |i| a_flags[p + i] = true }
          return
        end
        w = nn + 1
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
        i = 0
        j = 0
        while i < mm && j < nn
          if aid[p + i] == bid[p + j]
            i += 1
            j += 1
          elsif dp[(i + 1) * w + j] >= dp[i * w + j + 1]
            a_flags[p + i] = true
            i += 1
          else
            b_flags[p + j] = true
            j += 1
          end
        end
        while i < mm
          a_flags[p + i] = true
          i += 1
        end
        while j < nn
          b_flags[p + j] = true
          j += 1
        end
      end

      # Runs of word characters, and runs of everything else, in order. Byte-oriented on
      # the ASCII class test only: a non-ASCII byte is "not a word character", so a CJK or
      # UTF-8 run becomes one token rather than being split mid-codepoint. Built by
      # slicing on CHAR boundaries so every piece is a valid string.
      #
      # nil once the line has more than `limit` tokens. The caller falls back to `whole` at
      # that point anyway, so the walk stops there instead of splitting the rest of the line:
      # two 1.6 MB minified lines were tokenized in full (~280 MB of token Strings, 50-60 ms)
      # only to be thrown away for the fallback.
      private def self.tokenize(s : String, limit : Int32) : Array(String)?
        out = [] of String
        buf = String::Builder.new
        cur = nil.as(Bool?)
        s.each_char do |c|
          w = word_char?(c)
          if cur.nil?
            cur = w
          elsif w != cur
            out << buf.to_s
            return nil if out.size > limit
            buf = String::Builder.new
            cur = w
          end
          buf << c
        end
        tail = buf.to_s
        out << tail unless tail.empty?
        out.size > limit ? nil : out
      end

      private def self.word_char?(c : Char) : Bool
        c.ascii_alphanumeric? || c == '_'
      end

      # Collapse the per-token flags back into the fewest possible pieces — adjacent tokens
      # with the same verdict are one run. Fewer, longer spans is what the renderer wants:
      # a span is a draw call and a slice unit.
      private def self.merge(tokens : Array(String), flags : Array(Bool)) : Array(Piece)
        out = [] of Piece
        buf = String::Builder.new
        cur = false
        any = false
        tokens.each_with_index do |t, i|
          f = flags[i]
          if any && f != cur
            out << Piece.new(buf.to_s, cur)
            buf = String::Builder.new
          end
          buf << t
          cur = f
          any = true
        end
        out << Piece.new(buf.to_s, cur) if any
        out
      end
    end
  end
end
