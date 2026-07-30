module Gori
  # The ONE host-pattern dialect, shared by Scope's `host` rules (Scope::Rule#host_match?)
  # and the TLS passthrough list (Settings.tls_passthrough). Shared deliberately: a pattern
  # the operator learned in the scope editor must mean the same thing in the passthrough
  # field, and two copies of the glob/suffix decision would be two places to drift.
  #
  #   acme.test    → the host itself AND any subdomain (api.acme.test)
  #   *.acme.test  → a glob (File.match?) — matches subdomains but NOT the bare host
  #   ::1 / [::1]  → an IPv6 literal; bracketed and bare forms both match either form
  #
  # Matching is case-insensitive. Patterns are COMPILED once (see Compiled) because both
  # callers evaluate the same patterns repeatedly on the proxy hot path — per captured row
  # for scope, per CONNECT for passthrough.
  module HostPattern
    # "[::1]" → "::1". Host matching compares bare forms so an IPv6 pattern matches whether
    # the host arrived bracketed (some URL paths) or bare (the CONNECT/tunnel path).
    def self.bare(host : String) : String
      (host.starts_with?('[') && host.ends_with?(']')) ? host[1...-1] : host
    end

    # One pattern with its derived forms precomputed: the lowercased text, its bracket-free
    # host form, and whether it is a glob. Built once per pattern (a Scope::Rule is rebuilt
    # rather than edited in place; the passthrough list recompiles on assignment), so
    # `matches?` on the hot path only normalizes the HOST.
    struct Compiled
      getter raw : String
      # The lowercased pattern — also what a glob is matched against.
      getter down : String

      def initialize(@raw : String)
        @down = @raw.downcase
        @bare = HostPattern.bare(@down)
        @glob = @down.includes?('*')
      end

      # Match `host` in any form (mixed case, bracketed IPv6).
      def matches?(host : String) : Bool
        matches_bare?(HostPattern.bare(host.downcase))
      end

      # Match a host ALREADY lowercased and bracket-stripped — the form to use when testing
      # one host against many patterns, so the normalization happens once per host.
      def matches_bare?(host : String) : Bool
        if @glob
          # File.match? raises on a malformed glob; treat that as non-matching so an operator's
          # typo can never unwind onto the proxy hot path (mirrors SQLite GLOB's tolerance,
          # which is what keeps the live scope lens and the History SQL view consistent).
          begin
            File.match?(@down, host)
          rescue File::BadPatternError
            false
          end
        else
          host == @bare || host.ends_with?(".#{@bare}")
        end
      end
    end

    # Compile a list of raw patterns, dropping blanks. The caller keeps the result and
    # matches against it with `matches_any?`.
    def self.compile(patterns : Enumerable(String)) : Array(Compiled)
      patterns.compact_map { |p| p.strip.presence.try { |s| Compiled.new(s) } }
    end

    # True when `host` matches any compiled pattern. Normalizes the host ONCE for the
    # whole list (see Compiled#matches_bare?).
    def self.matches_any?(compiled : Array(Compiled), host : String) : Bool
      return false if compiled.empty?
      h = bare(host.downcase)
      compiled.any?(&.matches_bare?(h))
    end

    # The FIRST pattern `host` matches, or nil. Same walk as `matches_any?`, but it keeps
    # the winner — for a caller that has to NAME the rule that fired, not just know one
    # did (Settings.tls_passthrough? records it so the TUI can point at the rule to remove).
    #
    # Deliberately NOT the implementation of `matches_any?`: Scope evaluates that per
    # captured row and only ever asks the Bool question, so it keeps the predicate that
    # says exactly what it needs.
    def self.match(compiled : Array(Compiled), host : String) : Compiled?
      return nil if compiled.empty?
      h = bare(host.downcase)
      compiled.find(&.matches_bare?(h))
    end
  end
end
