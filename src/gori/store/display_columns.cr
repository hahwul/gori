require "db"

module Gori
  class Store
    # --- user-defined History columns (#819) ---------------------------------------------
    #
    # ORDERED, and that is the whole reason this is not a `display` flag on `extract_rules`:
    # an extract rule produces no bytes and cannot compose, so V6 gave it no order at all,
    # while a column's place in the row IS what the operator arranges. Shaped like
    # `color_rules` — same `position` renumber on move, same "returns whether the write
    # COMMITTED" contract on every mutator.

    def display_columns : Array(DisplayColumn)
      list = [] of DisplayColumn
      # Column order mirrors DisplayColumn's positional initialize, so the reads line up by
      # construction rather than by counting.
      @db.query("SELECT id, position, label, side, kind, selector, pos_start, pos_end, width FROM display_columns ORDER BY position, id") do |rs|
        rs.each do
          id = rs.read(Int64)
          pos = rs.read(Int64).to_i32
          label = rs.read(String)
          # An unreadable `side`/`kind` degrades to the default rather than raising: this list
          # is read on the History render path, and a hand-edited or peer-written row must
          # cost that column its meaning, not the tab.
          side = Gori::MessageSide.parse?(rs.read(String)) || Gori::MessageSide::Response
          kind = Gori::ExtractKind.parse?(rs.read(String)) || Gori::ExtractKind::Header
          list << DisplayColumn.new(id, pos, label, side, kind,
            rs.read(String), rs.read(Int64).to_i32, rs.read(Int64).to_i32, rs.read(Int64).to_i32)
        end
      end
      list
    end

    # Append a column at the END of the ordered list (position = max+1) so reordering has
    # distinct slots to swap. Returns the new id, or 0 when the write did not commit — the
    # same contract `insert_color_rule` has.
    def insert_display_column(label : String, kind : Gori::ExtractKind,
                              selector : String = "", pos_start : Int32 = 0, pos_end : Int32 = 0,
                              side : Gori::MessageSide = Gori::MessageSide::Response,
                              width : Int32 = 0) : Int64
      exec_task ->(c : DB::Connection) {
        pos = c.query_one("SELECT COALESCE(MAX(position), -1) + 1 FROM display_columns", as: Int64)
        c.exec("INSERT INTO display_columns (position, label, side, kind, selector, pos_start, pos_end, width) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          pos, label, side.label, kind.label, selector, pos_start, pos_end, width)
        nil
      }
    end

    # Update a column's fields in place (position unchanged). No-op on an unknown id.
    # Returns whether the write committed.
    def update_display_column(id : Int64, label : String, kind : Gori::ExtractKind,
                              selector : String = "", pos_start : Int32 = 0, pos_end : Int32 = 0,
                              side : Gori::MessageSide = Gori::MessageSide::Response,
                              width : Int32 = 0) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE display_columns SET label = ?, side = ?, kind = ?, selector = ?, pos_start = ?, pos_end = ?, width = ? WHERE id = ?",
          label, side.label, kind.label, selector, pos_start, pos_end, width, id)
        nil
      }
    end

    # Move a column one slot left (dir < 0) or right (dir > 0). Full renumber afterwards, like
    # `move_color_rule` — the table is tiny and tie-free positions are worth more than the
    # saved writes. False also covers "nothing moved" (an edge of the block, or an unknown id).
    def move_display_column(id : Int64, dir : Int32) : Bool
      ids = [] of Int64
      @db.query("SELECT id FROM display_columns ORDER BY position, id") { |rs| rs.each { ids << rs.read(Int64) } }
      i = ids.index(id)
      return false unless i
      j = i + (dir < 0 ? -1 : 1)
      return false unless 0 <= j < ids.size
      ids.swap(i, j)
      exec_task_ok ->(c : DB::Connection) {
        ids.each_with_index { |cid, pos| c.exec("UPDATE display_columns SET position = ? WHERE id = ?", pos, cid) }
        nil
      }
    end

    # Returns whether the write committed (false = store busy/locked/closing → the caller must
    # not report the column as removed; it is still in the list).
    def delete_display_column(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM display_columns WHERE id = ?", id); nil }
    end
  end
end
