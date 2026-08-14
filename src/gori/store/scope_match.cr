require "sqlite3"
require "./safe_regexp" # re-opens LibSQLite3 with value_bytes, which `text` below needs
require "../host_pattern"

module Gori
  # The SQL half of a Scope rule, for the shapes where a NATIVE SQL spelling and the
  # in-memory evaluation do not mean the same thing.
  #
  # `Scope#filter` and `Scope::Rule#matches?` are two implementations of one predicate, and
  # scope.cr's own invariant is that they "never disagree". Three ways they did:
  #
  #   · `lower()` — SQLite's built-in folds ASCII only; Crystal's `String#downcase` folds the
  #     whole of Unicode. A `string` rule `/über` matched a captured `/Über` in the live gate
  #     and nothing in History.
  #   · GLOB vs File.match? — Crystal reads `{a,b}` as brace alternation, SQLite GLOB reads
  #     the braces literally. An include `*.acme.{test,dev}` matched three hosts live and none
  #     in History; an EXCLUDE with braces carved out nothing in History (fail-open).
  #   · brackets — `Rule#host_match?` peels a surrounding `[...]` off the FLOW HOST as well as
  #     off the pattern, so a flow captured as `[::1]` (what `URI#host` hands back for the
  #     absolute-form target a plain-HTTP forward-proxy request arrives in) was in scope live
  #     but unreachable by any host rule in SQL. That one is fixed in SQL directly — see
  #     `Scope::HOST_BARE` — because it applies to the fast path too.
  #
  # Rather than keep a second dialect in sync by hand, the diverging shapes call the FIRST
  # implementation from SQL: `gori_host_match` is `HostPattern::Compiled`, and
  # `gori_ci_contains` is `downcase.includes?`. Registered per pooled connection beside the
  # byte-safe REGEXP (see SafeRegexp and Store.configure_connections).
  module ScopeMatch
    # SQLite fires these once per row against a FIXED set of patterns (one per scope rule),
    # so compiling per row would be O(rows) instead of O(rules). Same bounded memo, and the
    # same single-threaded-fiber argument, as SafeRegexp::CACHE_MAX above it.
    CACHE_MAX = 32
    @@hosts = {} of String => HostPattern::Compiled
    @@needles = {} of String => String

    # :nodoc: — internal (called from the FNs, which need an explicit receiver, so not private)
    def self.compiled(pattern : String) : HostPattern::Compiled
      if c = @@hosts[pattern]?
        return c
      end
      c = HostPattern::Compiled.new(pattern)
      @@hosts.clear if @@hosts.size >= CACHE_MAX
      @@hosts[pattern] = c
      c
    end

    # :nodoc: — the needle's lowercased form, memoised for the same reason as `compiled`
    # above: it is CONSTANT across the scan (one per string rule) but `downcase` allocates,
    # and this callback fires once per row.
    def self.folded(needle : String) : String
      if d = @@needles[needle]?
        return d
      end
      d = needle.downcase
      @@needles.clear if @@needles.size >= CACHE_MAX
      @@needles[needle] = d
      d
    end

    # :nodoc: — a SQLite TEXT argument read by its TRUE byte length and scrubbed to valid
    # UTF-8. `value_text` alone stops at an embedded NUL, and a captured target is bytes a
    # peer put on the wire, not guaranteed UTF-8 — the same two hazards SafeRegexp documents.
    def self.text(v : LibSQLite3::SQLite3Value) : String
      ptr = LibSQLite3.value_text(v)
      len = LibSQLite3.value_bytes(v)
      ptr.null? || len <= 0 ? "" : String.new(ptr, len).scrub
    end

    # `gori_host_match(host, pattern)` — the host column against one host-rule pattern, through
    # the very object `Scope::Rule#host_match?` uses. Exact/subdomain/glob and the bracket
    # peeling all come from there, so there is no SQL spelling left to drift.
    HOST_FN = ->(context : LibSQLite3::SQLite3Context, _argc : Int32, argv : LibSQLite3::SQLite3Value*) do
      args = Slice.new(argv, 2)
      host = ScopeMatch.text(args[0])
      pattern = ScopeMatch.text(args[1])
      matched =
        begin
          ScopeMatch.compiled(pattern).matches?(host)
        rescue
          # A malformed glob is non-matching, never an exception unwinding through the C
          # callback and aborting the whole query (Compiled#matches_bare? rescues the one
          # documented case; this is the belt for anything else).
          false
        end
      LibSQLite3.result_int(context, matched ? 1 : 0)
      nil
    end

    # `gori_ci_contains(haystack, needle)` — case-insensitive substring, folding BOTH sides
    # with Crystal's Unicode `downcase`, exactly as `Rule#matches?` does for a string rule.
    # A `%` or `_` in the needle is literal here (there is no LIKE pattern to escape).
    CONTAINS_FN = ->(context : LibSQLite3::SQLite3Context, _argc : Int32, argv : LibSQLite3::SQLite3Value*) do
      args = Slice.new(argv, 2)
      haystack = ScopeMatch.text(args[0])
      needle = ScopeMatch.text(args[1])
      matched =
        begin
          haystack.downcase.includes?(ScopeMatch.folded(needle))
        rescue
          # Same belt as HOST_FN: an exception here unwinds through the C callback and
          # aborts the WHOLE query, which is the failure mode SafeRegexp exists to prevent.
          # `text` scrubs, so nothing known raises — that is the point of having it anyway.
          false
        end
      LibSQLite3.result_int(context, matched ? 1 : 0)
      nil
    end
  end
end

class SQLite3::Connection
  # Register the two Scope match functions on this connection's raw SQLite handle. Called
  # from `Store.configure_connections`' single setup block — see the comment there for why
  # a second `setup_connection` call would silently drop this one.
  def gori_install_scope_match : Nil
    LibSQLite3.create_function(@db, "gori_host_match", 2, 1, nil, Gori::ScopeMatch::HOST_FN, nil, nil)
    LibSQLite3.create_function(@db, "gori_ci_contains", 2, 1, nil, Gori::ScopeMatch::CONTAINS_FN, nil, nil)
  end
end
