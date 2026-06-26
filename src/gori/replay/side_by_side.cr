require "./diff"

module Gori
  module Replay
    # Maps a unified line-diff (`Replay::Diff.lines`) into aligned side-by-side rows
    # for the Comparer's two-column view. Within each changed region the deleted
    # (A/left) lines are zipped against the added (B/right) lines so an edited line
    # shows old-on-left / new-on-right on the SAME row; surplus lines on either side
    # become left-only or right-only rows.
    module SideBySide
      enum RowKind
        Same    # unchanged — identical text in both columns
        Changed # an A line paired with a B line (edited)
        DelOnly # present only in A (left)
        AddOnly # present only in B (right)
      end

      record Row, left : String?, right : String?, kind : RowKind

      def self.rows(diff : Array(DiffLine)) : Array(Row)
        out = [] of Row
        i = 0
        n = diff.size
        while i < n
          if diff[i].kind.same?
            out << Row.new(diff[i].text, diff[i].text, RowKind::Same)
            i += 1
          else
            # Collect the maximal run of non-Same lines, keeping dels/adds in order.
            dels = [] of String
            adds = [] of String
            while i < n && !diff[i].kind.same?
              diff[i].kind.del? ? (dels << diff[i].text) : (adds << diff[i].text)
              i += 1
            end
            {dels.size, adds.size}.max.times do |j|
              l = dels[j]?
              r = adds[j]?
              kind = l && r ? RowKind::Changed : (l ? RowKind::DelOnly : RowKind::AddOnly)
              out << Row.new(l, r, kind)
            end
          end
        end
        out
      end

      # Count of rows that differ — for the Comparer's summary footer.
      def self.change_count(rows : Array(Row)) : Int32
        rows.count { |r| r.kind != RowKind::Same }
      end
    end
  end
end
