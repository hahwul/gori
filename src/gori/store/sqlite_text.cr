require "sqlite3"

# The shard reads a TEXT column with `String.new(column_text)`, which stops at the first NUL, so
# a captured target `/a\0b/tail` was stored whole and read back as `/a` by every listing (P7).
# The same read, bounded by the column's byte length instead.
class SQLite3::ResultSet
  def read
    col = @column_index
    return previous_def unless LibSQLite3.column_type(self, col) == SQLite3::Type::TEXT
    # `column_text` before `column_bytes`: the order SQLite documents for a TEXT value.
    text = LibSQLite3.column_text(self, col)
    value = String.new(text, LibSQLite3.column_bytes(self, col))
    @column_index += 1
    value
  end
end
