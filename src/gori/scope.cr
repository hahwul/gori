require "db"
require "./ql"
require "./store"

module Gori
  # The Scope lens (DESIGN.md §3): the set of in-scope host patterns. It's a
  # DISPLAY filter — everything is captured, but History/Sitemap show only
  # in-scope flows when active. Owned by the TUI (Runner), persisted per project.
  #
  # Pattern match: exact host, subdomain (`acme.test` ⊇ `api.acme.test`), or a
  # `*` glob (`*.acme.test`).
  class Scope
    SETTING_ENABLED = "scope_enabled"

    getter patterns : Array(String)
    getter? enabled : Bool

    def initialize(@store : Store, @patterns : Array(String), @enabled : Bool)
      # @patterns/@enabled are read on the PROXY hot path (matches?/active? via
      # interceptor.intercepts_host?) while the TUI fiber mutates them (add/remove/
      # toggle). Guard every access with a mutex — concurrently iterating + mutating
      # a bare Array is undefined behaviour (torn reads / crash). Mirrors Rules.
      @mutex = Mutex.new
    end

    def self.load(store : Store) : Scope
      new(store, store.scope_rules, store.setting(SETTING_ENABLED) == "1")
    end

    def active? : Bool
      @mutex.synchronize { active_unlocked? }
    end

    # Lock-free body so the synchronized callers (matches?/filter) reuse it WITHOUT
    # re-entering the non-reentrant mutex (which would deadlock).
    private def active_unlocked? : Bool
      @enabled && !@patterns.empty?
    end

    def add(pattern : String) : Nil
      pattern = pattern.strip
      @mutex.synchronize do
        return if pattern.empty? || @patterns.includes?(pattern)
        @store.add_scope_rule(pattern)
        @patterns << pattern
        @patterns.sort!
      end
    end

    def remove(pattern : String) : Nil
      @mutex.synchronize do
        return unless @patterns.includes?(pattern)
        @store.remove_scope_rule(pattern)
        @patterns.delete(pattern)
      end
    end

    def toggle : Nil
      @mutex.synchronize { set_enabled_unlocked(!@enabled) }
    end

    def enable : Nil
      @mutex.synchronize { set_enabled_unlocked(true) }
    end

    # In-memory equivalent of `filter`, for live gating (Intercept). Mirrors
    # `pattern_cond`: exact host, subdomain suffix (`.d`), or `*` glob. Returns
    # true when inactive (callers gate on `active?` first).
    def matches?(host : String) : Bool
      @mutex.synchronize do
        return true unless active_unlocked?
        h = host.downcase
        @patterns.any? do |pattern|
          if pattern.includes?('*')
            # File.match? raises on a malformed glob (e.g. "*.acme[.test"); treat it
            # as non-matching rather than letting it unwind onto the proxy hot path
            # and drop the connection. (SQLite's GLOB — used by `filter` — tolerates
            # the same patterns, so this keeps live gating and history consistent.)
            begin
              File.match?(pattern.downcase, h)
            rescue File::BadPatternError
              false
            end
          else
            d = pattern.downcase
            h == d || h.ends_with?(".#{d}")
          end
        end
      end
    end

    # A SQL filter selecting in-scope hosts (QL::EMPTY when inactive).
    def filter : QL::Filter
      @mutex.synchronize do
        return QL::EMPTY unless active_unlocked?
        conds = [] of String
        args = [] of DB::Any
        @patterns.each do |pattern|
          cond, cargs = pattern_cond(pattern)
          conds << cond
          args.concat(cargs)
        end
        QL::Filter.new("(#{conds.join(" OR ")})", args)
      end
    end

    private def set_enabled_unlocked(value : Bool) : Nil
      @enabled = value
      @store.set_setting(SETTING_ENABLED, value ? "1" : "0")
    end

    private def pattern_cond(pattern : String) : {String, Array(DB::Any)}
      if pattern.includes?('*')
        {"lower(host) GLOB ?", [pattern.downcase] of DB::Any}
      else
        d = pattern.downcase
        {"(lower(host) = ? OR lower(host) LIKE ?)", [d, "%.#{d}"] of DB::Any}
      end
    end
  end
end
