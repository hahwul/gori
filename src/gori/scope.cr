require "db"
require "./ql"
require "./store"

module Gori
  # The Scope lens (DESIGN.md §3): an include/exclude rule set that decides which
  # flows are "interesting". It's primarily a DISPLAY filter — everything is captured,
  # but History/Sitemap show only in-scope flows when active — and it ALSO gates
  # intercept holding. Owned by the TUI (Runner), persisted per project.
  #
  # Each rule has a KIND (include/exclude) and a MATCH_TYPE:
  #   host   — match the host: exact, subdomain (`acme.test` ⊇ `api.acme.test`), or
  #            a `*` glob (`*.acme.test`). Case-insensitive.
  #   string — case-insensitive substring of the full URL `scheme://host/target`.
  #   regex  — regex over the full URL `scheme://host/target`. Case-SENSITIVE (use an
  #            inline `(?i)` flag to opt out) so it matches the SQL `REGEXP` exactly.
  #
  # Evaluation (Burp-style): in scope ⇔ (NO include rules OR a rule matches an include)
  # AND (no exclude rule matches). So excludes-only ⇒ everything except the excludes.
  class Scope
    SETTING_ENABLED = "scope_enabled"

    KINDS = ["include", "exclude"]
    TYPES = ["host", "string", "regex"]

    # One scope rule. Immutable: rebuilt on every load/mutate (never edited in place),
    # so the compiled regex is built ONCE here and the proxy hot path never recompiles.
    class Rule
      getter id : Int64
      getter kind : String       # "include" | "exclude"
      getter match_type : String # "host" | "string" | "regex"
      getter pattern : String
      @regex : Regex?
      @pattern_down : String

      def initialize(@id : Int64, @kind : String, @match_type : String, @pattern : String)
        # The pattern is immutable (a Rule is rebuilt, never edited in place), so its
        # lowercased form — compared on every host/string match, once per rule per row
        # of a Scope-filtered reload and per host of a Sitemap reload — is computed ONCE
        # here rather than re-allocated on each `matches?` call (mirrors @regex).
        @pattern_down = @pattern.downcase
        # Compile the regex once. An invalid pattern degrades to nil → never-match,
        # rather than unwinding through SQLite's C REGEXP callback or a proxy fiber.
        # Persisted patterns are validated on add/update; this is defense-in-depth.
        @regex = if @match_type == "regex"
                   begin
                     Regex.new(@pattern)
                   rescue
                     nil
                   end
                 end
      end

      def include? : Bool
        @kind == "include"
      end

      def exclude? : Bool
        @kind == "exclude"
      end

      def host_type? : Bool
        @match_type == "host"
      end

      # Match this rule against a flow. `url` is `scheme://host/target`; `host` is the
      # bare host. Mirrors the SQL `filter` branch-for-branch so the live lens and the
      # History/Sitemap SQL view never disagree.
      def matches?(url : String, host : String) : Bool
        case @match_type
        when "host"
          host_match?(host)
        when "string"
          url.downcase.includes?(@pattern_down)
        when "regex"
          r = @regex
          return false unless r
          begin
            r.matches?(url)
          rescue
            false
          end
        else
          false
        end
      end

      private def host_match?(host : String) : Bool
        h = host.downcase
        if @pattern.includes?('*')
          # File.match? raises on a malformed glob; treat as non-matching so it can't
          # unwind onto the proxy hot path (mirrors SQLite GLOB's tolerance → keeps
          # live gating and the History SQL view consistent).
          begin
            File.match?(@pattern_down, h)
          rescue File::BadPatternError
            false
          end
        else
          h == @pattern_down || h.ends_with?(".#{@pattern_down}")
        end
      end
    end

    getter rules : Array(Rule)
    getter? enabled : Bool

    def initialize(@store : Store, @rules : Array(Rule), @enabled : Bool)
      # @rules/@enabled are read on the PROXY hot path (in_scope_url?/may_match_host?/
      # filter/active?) while the TUI fiber mutates them (add/remove/update/toggle).
      # Guard every cross-fiber access with a mutex — only the TUI mutates, so its own
      # render reads are race-free, but proxy reads vs TUI writes need the lock.
      @mutex = Mutex.new
    end

    def self.load(store : Store) : Scope
      new(store, load_rules(store), store.setting(SETTING_ENABLED) == "1")
    end

    protected def self.load_rules(store : Store) : Array(Rule)
      store.scope_rules.map { |(id, kind, match_type, pattern)| Rule.new(id, kind, match_type, pattern) }
    end

    # Rule count (chrome chip / scope_label) — read on the TUI fiber, the only writer.
    def size : Int32
      @rules.size
    end

    def active? : Bool
      @mutex.synchronize { active_unlocked? }
    end

    # Has any scope rule at all, REGARDLESS of the enabled flag — drives whether the
    # Sitemap shows scope markers (targets are marked even with the ⇧S lens off). Kept
    # mutex-guarded so it shares the same discipline as the other rule readers.
    def configured? : Bool
      @mutex.synchronize { !@rules.empty? }
    end

    # Host-level scope membership evaluated against the rules REGARDLESS of the enabled
    # flag, so the Sitemap can mark its targets even when the ⇧S lens is off. False when
    # no rules exist (nothing to mark). Conservative on url-level (string/regex) includes
    # — a host can't be ruled out by a rule whose path we don't know here — same as
    # may_match_host?; host-type scoping (the common case) is precise.
    def host_in_scope?(host : String) : Bool
      @mutex.synchronize { host_in_scope_unlocked?(host) }
    end

    # Lock-free body so synchronized callers reuse it WITHOUT re-entering the
    # non-reentrant mutex (which would deadlock).
    private def active_unlocked? : Bool
      @enabled && !@rules.empty?
    end

    # The shared Burp-style HOST gate (callers hold @mutex): (no host-affecting includes
    # OR one matches) AND no host-level exclude. Empty rules ⇒ false; may_match_host?
    # short-circuits its own inactive case before calling, so it never reaches the guard.
    private def host_in_scope_unlocked?(host : String) : Bool
      return false if @rules.empty?
      includes = @rules.select(&.include?)
      inc_ok = includes.empty? ||
               includes.any? { |r| r.host_type? && r.matches?("", host) } ||
               includes.any? { |r| !r.host_type? }
      excluded = @rules.any? { |r| r.exclude? && r.host_type? && r.matches?("", host) }
      inc_ok && !excluded
    end

    # Full include/exclude evaluation against a flow's URL + host. Used by ClientConn's
    # precise per-request hold gate (and mirrors the SQL `filter` for parity). Returns
    # true when inactive (callers gate on `active?`). Burp-style: in scope ⇔ (no
    # includes OR an include matches) AND no exclude matches.
    def in_scope_url?(url : String, host : String) : Bool
      @mutex.synchronize do
        return true unless active_unlocked?
        includes = @rules.select(&.include?)
        inc_ok = includes.empty? || includes.any?(&.matches?(url, host))
        inc_ok && @rules.none? { |r| r.exclude? && r.matches?(url, host) }
      end
    end

    # Conservative HOST-level check for the Tunnel's h2→h1 downgrade decision, made
    # BEFORE any request exists (so no path/URL is known yet). A host is *potentially*
    # in scope when includes don't rule it out — no includes, OR a host-include
    # matches, OR any url-level include exists (its path we can't know yet) — AND no
    # HOST-level exclude fully covers it (url-level excludes only kill specific paths,
    # never a whole host). ClientConn then makes the precise per-request call; this only
    # decides whether to keep the connection on h1 so a request CAN be held.
    def may_match_host?(host : String) : Bool
      @mutex.synchronize { active_unlocked? ? host_in_scope_unlocked?(host) : true }
    end

    # A SQL filter selecting in-scope flows (QL::EMPTY when inactive). The URL the
    # string/regex rules see is `scheme || '://' || host || target` — the same value
    # `in_scope_url?` builds in memory. Combined Burp-style:
    #   ( <includes OR'd, or 1 when none>  [AND NOT (<excludes OR'd>)] )
    def filter : QL::Filter
      @mutex.synchronize do
        return QL::EMPTY unless active_unlocked?
        inc_conds = [] of String
        exc_conds = [] of String
        args = [] of DB::Any
        @rules.each do |rule|
          cond, cargs = rule_cond(rule)
          (rule.include? ? inc_conds : exc_conds) << cond
          args.concat(cargs)
        end
        inc_sql = inc_conds.empty? ? "1" : "(#{inc_conds.join(" OR ")})"
        exc_sql = exc_conds.empty? ? "" : " AND NOT (#{exc_conds.join(" OR ")})"
        QL::Filter.new("(#{inc_sql}#{exc_sql})", args)
      end
    end

    # Add a rule (validates regex, dedupes on the kind/type/pattern triple). Returns
    # false (no-op) on an empty pattern, an invalid regex, or a duplicate.
    def add(kind : String, match_type : String, pattern : String) : Bool
      pattern = pattern.strip
      return false if pattern.empty? || !Scope.valid?(match_type, pattern)
      @mutex.synchronize do
        return false if @rules.any? { |r| r.kind == kind && r.match_type == match_type && r.pattern == pattern }
        @store.add_scope_rule(kind, match_type, pattern)
        reload_rules_unlocked
      end
      true
    end

    # Edit a rule in place (by id). Same validation; dedupes against OTHER rules so a
    # no-op self-edit is allowed. Returns false on empty/invalid/duplicate.
    def update(id : Int64, kind : String, match_type : String, pattern : String) : Bool
      pattern = pattern.strip
      return false if pattern.empty? || !Scope.valid?(match_type, pattern)
      @mutex.synchronize do
        return false if @rules.any? { |r| r.id != id && r.kind == kind && r.match_type == match_type && r.pattern == pattern }
        @store.update_scope_rule(id, kind, match_type, pattern)
        reload_rules_unlocked
      end
      true
    end

    def remove(id : Int64) : Nil
      @mutex.synchronize do
        @store.remove_scope_rule(id)
        reload_rules_unlocked
      end
    end

    def toggle : Nil
      @mutex.synchronize { set_enabled_unlocked(!@enabled) }
    end

    def enable : Nil
      @mutex.synchronize { set_enabled_unlocked(true) }
    end

    def disable : Nil
      @mutex.synchronize { set_enabled_unlocked(false) }
    end

    # A regex pattern must compile — the SQLite REGEXP callback and the proxy hot path
    # both call `Regex.new` and would otherwise raise. host/string patterns always valid.
    def self.valid?(match_type : String, pattern : String) : Bool
      return true unless match_type == "regex"
      Regex.new(pattern)
      true
    rescue
      false
    end

    # Re-read the rules from the store after every mutation so in-memory == DB
    # (authoritative ids + UNIQUE dedup reflected). exec_task is synchronous, so the
    # just-written row is committed and visible to this pool read.
    private def reload_rules_unlocked : Nil
      @rules = Scope.load_rules(@store)
    end

    private def set_enabled_unlocked(value : Bool) : Nil
      @enabled = value
      @store.set_setting(SETTING_ENABLED, value ? "1" : "0")
    end

    private URL_EXPR = "(scheme || '://' || host || target)"

    private def rule_cond(rule : Rule) : {String, Array(DB::Any)}
      case rule.match_type
      when "host"
        host_cond(rule.pattern)
      when "string"
        # Case-insensitive substring of the URL; QL.like neutralises % / _ so a literal
        # %/_ in the pattern matches literally (paired with ESCAPE '\').
        {"lower(#{URL_EXPR}) LIKE ? ESCAPE '\\'", [QL.like(rule.pattern)] of DB::Any}
      when "regex"
        # Case-SENSITIVE (no lower()) to match Rule#matches? + the shard's REGEXP.
        {"#{URL_EXPR} REGEXP ?", [rule.pattern] of DB::Any}
      else
        {"0", [] of DB::Any}
      end
    end

    private def host_cond(pattern : String) : {String, Array(DB::Any)}
      if pattern.includes?('*')
        {"lower(host) GLOB ?", [pattern.downcase] of DB::Any}
      else
        d = pattern.downcase
        # The subdomain arm splices the host into a LIKE pattern, so its % / _ must be
        # escaped (keeping the literal leading `%.`) or a host like `a_b.test` would
        # match `aXb.test` in SQL but not in Rule#host_match? — breaking parity.
        {"(lower(host) = ? OR lower(host) LIKE ? ESCAPE '\\')", [d, "%.#{QL.like_escape(d)}"] of DB::Any}
      end
    end
  end
end
