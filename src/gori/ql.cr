require "db"

module Gori
  # The query language (DESIGN.md §4): a Lucene/KQL-style boolean filter over the
  # captured flows, compiled to a SQL WHERE fragment + bound params (values are
  # always parameterised — never interpolated — so the projection columns stay
  # injection-safe). The analysis surface; QL is how you find things (P8: pull).
  #
  #   host:acme status:>=500            # AND of terms
  #   method:post path:/api OR flag:x   # OR of AND-groups
  #   -host:cdn  status:5xx  login      # negation, status class, free text
  #   body:token                        # scan request/response body bytes
  #   size:>10000 dur:>=500 dur:<2s     # total bytes (req+resp) / latency (ms; ms|s)
  #   reqsize:>1000 respsize:<500       # request-only / response-only byte size
  #   header:set-cookie                 # substring over request/response head bytes
  #   body~secret\d+  host~^api\.       # `~` = regex (host path url header body)
  module QL
    # `:` fields:  host path method scheme status size reqsize respsize dur header body flag
    # `~` regex on: host path url header body   (+ bare words = free text).
    # Comparison ops (<= >= < > =) apply to status/size/reqsize/respsize/dur.
    struct Filter
      getter sql : String # safe to splice into "WHERE ..."; values are in `args`
      getter args : Array(DB::Any)

      def initialize(@sql : String, @args : Array(DB::Any))
      end
    end

    EMPTY = Filter.new("1", [] of DB::Any)

    # Combines two filters with AND (used to layer the Scope lens over a query).
    def self.and(a : Filter, b : Filter) : Filter
      return b if a.sql == "1"
      return a if b.sql == "1"
      Filter.new("(#{a.sql}) AND (#{b.sql})", a.args + b.args)
    end

    def self.parse(query : String) : Filter
      tokens = query.split
      return EMPTY if tokens.empty?

      groups = [[] of String]
      tokens.each do |tok|
        tok == "OR" ? (groups << [] of String) : groups.last << tok
      end

      args = [] of DB::Any
      clauses = [] of String
      groups.each do |group|
        conds = [] of String
        group.each do |term|
          if result = term_to_sql(term)
            cond, cargs = result
            conds << cond
            args.concat(cargs)
          end
        end
        clauses << "(#{conds.join(" AND ")})" unless conds.empty?
      end

      clauses.empty? ? EMPTY : Filter.new(clauses.join(" OR "), args)
    end

    private def self.term_to_sql(term : String) : {String, Array(DB::Any)}?
      negate = term.starts_with?('-')
      term = term[1..] if negate
      return nil if term.empty?

      # The field/operator separator is the first ':' (field op) or '~' (regex op) —
      # whichever appears first wins, so a regex value may itself contain ':' (e.g.
      # body~https?://x). A leading separator (`:foo` / `~foo`) is treated as free text.
      ci = term.index(':')
      ti = term.index('~')
      sep = [ci, ti].compact.min?

      result =
        if sep && sep > 0
          field = term[0...sep].downcase
          value = term[(sep + 1)..]
          ti == sep ? regex_cond(field, value, term) : field_cond(field, value)
        else
          free_text(term)
        end
      return nil unless result

      cond, args = result
      {negate ? "NOT (#{cond})" : cond, args}
    end

    private def self.field_cond(field : String, value : String) : {String, Array(DB::Any)}?
      return nil if value.empty?
      case field
      when "host"                        then {"lower(host) LIKE ? ESCAPE '\\'", [like(value)] of DB::Any}
      when "path"                        then {"lower(target) LIKE ? ESCAPE '\\'", [like(value)] of DB::Any}
      when "method"                      then {"upper(method) = ?", [value.upcase] of DB::Any}
      when "scheme"                      then {"scheme = ?", [value.downcase] of DB::Any}
      when "status"                      then status_cond(value)
      when "size", "reqsize", "respsize" then size_cond(field, value)
      when "dur"                         then duration_cond(value)
      when "header"                      then header_cond(value)
      when "body"                        then body_cond(value)
      when "flag"                        then {"0", [] of DB::Any} # tags not implemented yet → matches nothing
      else                                    free_text(value)     # unknown field: treat the value as free text
      end
    end

    # size: → the TOTAL bytes (request + response), so it matches the displayed/JSON
    # `size`; reqsize:/respsize: target a single side. A NULL response_size (pending
    # flow) never matches respsize:, while size:/reqsize: fall back on the request bytes.
    private def self.size_cond(field : String, value : String) : {String, Array(DB::Any)}?
      column = case field
               when "reqsize"  then "request_size"
               when "respsize" then "response_size"
               else                 "(request_size + COALESCE(response_size, 0))"
               end
      numeric_cond(column, value)
    end

    # Body search uses the trigram FTS index over request/response body text —
    # case-insensitive SUBSTRING matching (same semantics as the old `body:` LIKE,
    # so `body:token` still finds "mytokenvalue"), just indexed instead of
    # scanning every BLOB. The value is passed as a quoted FTS phrase (embedded
    # quotes doubled) so arbitrary characters can't form FTS operator syntax. A
    # bodyless flow has an empty FTS row, so it never matches and `-body:x`
    # correctly KEEPS it. The trigram index needs >=3 characters, so shorter
    # values fall back to the NULL-safe BLOB LIKE scan.
    private def self.body_cond(value : String) : {String, Array(DB::Any)}
      value = value.chars.reject(&.control?).join # strip NUL/control chars (FTS/LIKE safety)
      if value.size < 3
        p = like(value)
        return {"((request_body IS NOT NULL AND lower(CAST(request_body AS TEXT)) LIKE ? ESCAPE '\\') OR " \
                "(response_body IS NOT NULL AND lower(CAST(response_body AS TEXT)) LIKE ? ESCAPE '\\'))",
                [p, p] of DB::Any}
      end
      phrase = %("#{value.gsub('"', "\"\"")}") # quoted phrase → contiguous substring match
      {"id IN (SELECT rowid FROM flows_fts WHERE flows_fts MATCH ?)", [phrase] of DB::Any}
    end

    # Split a leading comparison operator (<= >= < > =, default =) off a value. Shared
    # by status:, size:, dur: so the operator parsing lives in exactly one place.
    private def self.split_op(value : String) : {String, String}
      {"<=", ">=", "<", ">", "="}.each do |o|
        return {o, value[o.size..]} if value.starts_with?(o)
      end
      {"=", value}
    end

    private def self.status_cond(value : String) : {String, Array(DB::Any)}?
      op, rest = split_op(value)

      # status class: 2xx / 4xx / 5xx — honour any comparison operator against the
      # class bounds (e.g. status:>=5xx → status >= 500; bare status:4xx → 400-499).
      if rest.size == 3 && rest[1] == 'x' && rest[2] == 'x' && rest[0].ascii_number?
        base = rest[0].to_i * 100
        case op
        when ">=" then return {"status >= ?", [base] of DB::Any}
        when ">"  then return {"status >= ?", [base + 100] of DB::Any}
        when "<=" then return {"status < ?", [base + 100] of DB::Any}
        when "<"  then return {"status < ?", [base] of DB::Any}
        else           return {"(status >= ? AND status < ?)", [base, base + 100] of DB::Any}
        end
      end

      n = rest.to_i?
      return nil unless n
      {"status #{op} ?", [n] of DB::Any}
    end

    # Numeric comparison on an INTEGER column/expression. `size:` uses the total
    # (request_size + COALESCE(response_size, 0)) so it matches the displayed/JSON
    # `size`; `reqsize:`/`respsize:` target one side. A NULL column (e.g. respsize:
    # on a pending flow) never satisfies `col <op> ?`, so such rows fall out of both
    # the positive and negated form. Non-numeric values yield nil (the term is
    # dropped, like a bad status:).
    private def self.numeric_cond(column : String, value : String) : {String, Array(DB::Any)}?
      op, rest = split_op(value)
      n = rest.to_i64?
      return nil unless n
      {"#{column} #{op} ?", [n] of DB::Any}
    end

    # dur: is milliseconds (how latency reads), compared against the microsecond
    # `duration_us`. A trailing `ms` (×1000) or `s` (×1_000_000) overrides the default
    # ms scale; the magnitude is parsed as a float so `dur:>1.5s` works. NULL duration
    # (no response yet) never matches, same as size:.
    private def self.duration_cond(value : String) : {String, Array(DB::Any)}?
      op, rest = split_op(value)
      scale_us = 1000.0 # ms → µs (default)
      if rest.ends_with?("ms")
        rest = rest[0...-2]
      elsif rest.ends_with?('s')
        rest = rest[0...-1]
        scale_us = 1_000_000.0
      end
      n = rest.to_f?
      return nil unless n && n.finite?
      us = (n * scale_us).round
      # Drop an absurd magnitude rather than let Float#to_i64 raise OverflowError out of
      # QL.parse (a crash on a single TUI keystroke); size: drops the same way via
      # to_i64?. 9e18 is safely inside Int64 and astronomically beyond any real latency.
      return nil unless us.abs < 9.0e18
      {"duration_us #{op} ?", [us.to_i64] of DB::Any}
    end

    # header: substring-matches the raw request/response head bytes (request line /
    # status line + header lines), case-insensitively — same shape as body:. It scans
    # the whole head, so it also sees the request/status line (rare false hit; fine).
    # request_head is NOT NULL; response_head is guarded so a response-less flow
    # contributes no match (and `-header:x` correctly keeps it).
    private def self.header_cond(value : String) : {String, Array(DB::Any)}
      p = like(value)
      {"(lower(CAST(request_head AS TEXT)) LIKE ? ESCAPE '\\' OR " \
       "(response_head IS NOT NULL AND lower(CAST(response_head AS TEXT)) LIKE ? ESCAPE '\\'))",
       [p, p] of DB::Any}
    end

    # The `~` operator: case-sensitive regex (SQLite REGEXP, the same shard-provided
    # function Scope's regex rules use, backed by Crystal Regex) over a text field —
    # host/path/url/header/body. Any other field falls back to a literal free-text
    # search of the whole token. An invalid pattern would raise inside the SQLite
    # REGEXP callback, so we validate up front and emit a never-matches clause instead
    # (like flag:). For case-insensitive matching use an inline (?i) flag.
    private def self.regex_cond(field : String, value : String, term : String) : {String, Array(DB::Any)}?
      # A non-regex field name means `~` wasn't a regex operator here (e.g. `foo~bar`):
      # fall back to a literal free-text search of the WHOLE token. This must happen BEFORE
      # the validity guard — otherwise `foo~[` (an unterminated char class) would compile to
      # the never-match clause instead of free-texting "foo~[".
      case field
      when "host", "path", "url", "header", "body"
        return nil if value.empty?
        # An invalid pattern would raise inside the SQLite REGEXP callback, so validate up
        # front and emit a never-matches clause instead (like flag:).
        return {"0", [] of DB::Any} unless valid_regex?(value)
        case field
        when "host"   then {"host REGEXP ?", [value] of DB::Any}
        when "path"   then {"target REGEXP ?", [value] of DB::Any}
        when "url"    then {"(scheme || '://' || host || target) REGEXP ?", [value] of DB::Any}
        when "header" then header_regex_cond(value)
        else               body_regex_cond(value)
        end
      else
        free_text(term)
      end
    end

    # NULL-guarded REGEXP over both body columns (a bodyless flow contributes no match,
    # so `-body~x` keeps it — same null-safety as the body: LIKE fallback above).
    private def self.body_regex_cond(value : String) : {String, Array(DB::Any)}
      {"((request_body IS NOT NULL AND CAST(request_body AS TEXT) REGEXP ?) OR " \
       "(response_body IS NOT NULL AND CAST(response_body AS TEXT) REGEXP ?))",
       [value, value] of DB::Any}
    end

    private def self.header_regex_cond(value : String) : {String, Array(DB::Any)}
      {"(CAST(request_head AS TEXT) REGEXP ? OR " \
       "(response_head IS NOT NULL AND CAST(response_head AS TEXT) REGEXP ?))",
       [value, value] of DB::Any}
    end

    # A pattern must compile or the SQLite REGEXP callback raises (mirrors Scope.valid?).
    private def self.valid_regex?(pattern : String) : Bool
      Regex.new(pattern)
      true
    rescue
      false
    end

    private def self.free_text(word : String) : {String, Array(DB::Any)}
      pattern = like(word)
      {"(lower(method) LIKE ? OR lower(host) LIKE ? OR lower(target) LIKE ?)",
       [pattern, pattern, pattern] of DB::Any}
    end

    # Build a LIKE pattern, neutralising the LIKE metacharacters % and _ (and the
    # escape char itself) so a user's literal % / _ matches literally. Pair every
    # use with `ESCAPE '\'` in the SQL. Backslash MUST be escaped first. Public so
    # Scope's string-match rules reuse the one escaper (no second hand-rolled copy).
    def self.like(value : String) : DB::Any
      "%#{like_escape(value.downcase)}%"
    end

    # Neutralise LIKE metacharacters (% _ \) in `value` WITHOUT the surrounding `%`,
    # for callers that splice it into a larger LIKE pattern (e.g. Scope's `%.<host>`
    # subdomain match). Pair with `ESCAPE '\'`. Caller lowercases if it wants ci.
    def self.like_escape(value : String) : String
      value.gsub('\\', "\\\\").gsub('%', "\\%").gsub('_', "\\_")
    end
  end
end
