module Gori
  # The ONE host-pattern dialect, shared by Scope's `host` rules (Scope::Rule#host_match?),
  # TLS passthrough, upstream rules and the project's Destination host gate. Shared
  # deliberately: a pattern the operator learned in one editor must mean the same thing in
  # another, and copies of the glob/suffix decision would be places to drift.
  #
  #   acme.test    → the host itself AND any subdomain (api.acme.test)
  #   *.acme.test  → a glob (File.match?) — matches subdomains but NOT the bare host
  #   ::1 / [::1]  → an IPv6 literal; bracketed and bare forms both match either form
  #
  # Matching is case-insensitive. Patterns are COMPILED once (see Compiled) because both
  # callers evaluate the same patterns repeatedly on the proxy hot path — per captured row
  # for scope and per destination dial for routing/passthrough.
  module HostPattern
    # The form both sides of a host match compare: a SURROUNDING bracket pair peeled, and every
    # TRAILING ROOT DOT stripped.
    #
    # Brackets, because an IPv6 host arrives bracketed on some URL paths and bare on the
    # CONNECT/tunnel path, and a pattern must reach both.
    #
    # The root dot, because `acme.test.` and `acme.test` are one name to every resolver and gori
    # captures the `Host:` bytes as they arrived — a browser sends the dot when the user types
    # one, which is exactly why the dotted spelling is a standing WAF/cache bypass. To a string
    # compare it was a different host, so `acme.test.` escaped a scope EXCLUDE, a TLS-passthrough
    # entry and an upstream route written for `acme.test`, each in the permissive direction; and a
    # pattern typed WITH the dot was a rule no request could ever match. `OverrideHost.key` folds
    # it on the host-override table and `Upstream.strip_root_dot` on the self-loop gate, both for
    # this reason — this is the third table and the one the other two cite.
    #
    # `rstrip` rather than `chomp`, like `OverrideHost.key`: the pathological `acme.test..` folds
    # too instead of leaving a dot behind that still matches nothing.
    #
    # A GLOB pattern is matched against the UN-bared text (see `matches_bare?`), so a glob typed
    # with a trailing dot stays a rule that matches nothing — exactly as a bracketed glob does,
    # and `Scope.sql_native_host?` keeps the SQL lens agreeing with it either way.
    def self.bare(host : String) : String
      h = (host.starts_with?('[') && host.ends_with?(']')) ? host[1...-1] : host
      h.ends_with?('.') ? h.rstrip('.') : h
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
