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
    # Sandbox: a HARD containment gate (distinct from the display lens above). When on,
    # the capture proxy forwards ONLY requests the scope allows and BLOCKS everything
    # else — so a test can only ever touch the range the operator explicitly permitted.
    SETTING_SANDBOX = "scope_sandbox"

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
    # The sandbox flag. Read on the PROXY hot path (sandbox_blocks?/sandbox_blocks_host?)
    # under @mutex while the TUI toggles it; the bare `sandbox?` getter is read only on
    # the TUI render fiber (the sole writer), matching `enabled?`'s discipline.
    getter? sandbox : Bool

    def initialize(@store : Store, @rules : Array(Rule), @enabled : Bool, @sandbox : Bool = false)
      # @rules/@enabled are read on the PROXY hot path (in_scope_url?/may_match_host?/
      # filter/active?) while the TUI fiber mutates them (add/remove/update/toggle).
      # Guard every cross-fiber access with a mutex — only the TUI mutates, so its own
      # render reads are race-free, but proxy reads vs TUI writes need the lock.
      @mutex = Mutex.new
    end

    def self.load(store : Store) : Scope
      new(store, load_rules(store), store.setting(SETTING_ENABLED) == "1",
        store.setting(SETTING_SANDBOX) == "1")
    end

    protected def self.load_rules(store : Store) : Array(Rule)
      store.scope_rules.map { |(id, kind, match_type, pattern)| Rule.new(id, kind, match_type, pattern) }
    end

    # Rule count (chrome chip / scope_label) — read on the TUI fiber, the only writer.
    def size : Int32
      @rules.size
    end

    # Count of INCLUDE rules — the Sandbox guidance note distinguishes "blocks
    # out-of-scope" (has includes) from "blocks EVERYTHING" (zero includes ⇒ nothing
    # is allowlisted ⇒ the proxy drops all traffic). Read on the TUI fiber, like `size`.
    def include_count : Int32
      @rules.count(&.include?)
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
        matches_url_unlocked?(url, host)
      end
    end

    # Evaluate include/exclude rules against a URL REGARDLESS of the ⇧S display lens.
    # Used by Probe Active probes. Differs from the Burp display filter in one safety
    # way: at least one INCLUDE rule is required (excludes-only would otherwise mean
    # "probe the whole internet minus a few hosts" — too aggressive for an automatic
    # outbound scanner). False when no includes exist or the URL is excluded.
    def matches_url?(url : String, host : String) : Bool
      @mutex.synchronize { allowlisted_unlocked?(url, host) }
    end

    # True when any EXCLUDE rule matches the url/host — the "always deny" gate an outbound
    # scanner (Discover) applies in every containment mode, INDEPENDENT of includes and the
    # display lens. (matches_url? requires includes; this asks only "is it carved out?".)
    def excluded?(url : String, host : String) : Bool
      @mutex.synchronize { @rules.any? { |r| r.exclude? && r.matches?(url, host) } }
    end

    # The ALLOWLIST evaluation (callers hold @mutex): true ⇔ at least one INCLUDE rule
    # matches AND no EXCLUDE matches. Empty includes ⇒ false — "nothing is explicitly
    # allowed". SHARED by the Probe Active gate (matches_url?) and the Sandbox block gate
    # (sandbox_blocks?): both INTENTIONALLY reject a scope with no includes rather than
    # treating it as allow-all (the Burp display filter's rule in matches_url_unlocked?),
    # because an empty or excludes-only scope is not an "allowed range" to probe or let
    # through — it's the whole internet minus a few hosts.
    private def allowlisted_unlocked?(url : String, host : String) : Bool
      includes = @rules.select(&.include?)
      return false if includes.empty?
      includes.any?(&.matches?(url, host)) &&
        @rules.none? { |r| r.exclude? && r.matches?(url, host) }
    end

    # Pure Burp evaluation (includes empty ⇒ match all; then carve excludes). Shared by
    # in_scope_url? when the display lens is on. Rules must already be non-empty (active?
    # requires that); still guards empty for defense-in-depth.
    private def matches_url_unlocked?(url : String, host : String) : Bool
      return false if @rules.empty?
      includes = @rules.select(&.include?)
      inc_ok = includes.empty? || includes.any?(&.matches?(url, host))
      inc_ok && @rules.none? { |r| r.exclude? && r.matches?(url, host) }
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

    # --- Sandbox: the hard containment gate (safe-testing) ---------------------------
    # When ON, the capture proxy forwards ONLY the requests the scope ALLOWS
    # (allowlisted_unlocked?: ≥1 include matches, no exclude) and BLOCKS everything else —
    # including ALL traffic when no include rule exists. INDEPENDENT of the display lens
    # (`enabled?`): a blocking policy, not a view filter. It reuses the ALLOWLIST eval, NOT
    # the Burp display filter, so "no includes" means "block all" (the safe default), never
    # "allow all". Read on the proxy hot path under @mutex; toggled by the TUI.

    # Precise per-REQUEST block decision (ClientConn). `url` is `scheme://host/target` —
    # the SAME value in_scope_url?/the SQL filter build, so a blocked request lines up
    # exactly with the History row it would have been. Returns false when the sandbox is
    # off (nothing is ever blocked). One lock covers both the flag and the rule eval.
    def sandbox_blocks?(url : String, host : String) : Bool
      @mutex.synchronize { @sandbox && !allowlisted_unlocked?(url, host) }
    end

    # Coarse HOST-level block for the CONNECT gate + the h2→h1 downgrade decision, made
    # BEFORE any request exists (no path/URL yet). Blocks only when the host CAN'T be in
    # scope, so a partially-in-scope host is still tunnelled and gated per request by
    # ClientConn. Conservative like may_match_host?: a url-level include (whose path we
    # can't know here) keeps the host allowed; only a host-level include set that excludes
    # it — or an empty allowlist — blocks it outright. Returns false when the sandbox is off.
    def sandbox_blocks_host?(host : String) : Bool
      @mutex.synchronize { @sandbox && !host_allowlisted_unlocked?(host) }
    end

    # HOST-level ALLOWLIST membership (callers hold @mutex): the host CAN be in scope when
    # includes aren't empty AND (a host-include matches OR any url-level include exists —
    # its path might match on this host) AND no HOST-level exclude fully covers it. Mirrors
    # host_in_scope_unlocked? but with the allowlist's empty-includes ⇒ false rule.
    private def host_allowlisted_unlocked?(host : String) : Bool
      includes = @rules.select(&.include?)
      return false if includes.empty?
      inc_ok = includes.any? { |r| r.host_type? && r.matches?("", host) } ||
               includes.any? { |r| !r.host_type? }
      excluded = @rules.any? { |r| r.exclude? && r.host_type? && r.matches?("", host) }
      inc_ok && !excluded
    end

    def toggle_sandbox : Nil
      @mutex.synchronize { set_sandbox_unlocked(!@sandbox) }
    end

    def enable_sandbox : Nil
      @mutex.synchronize { set_sandbox_unlocked(true) }
    end

    def disable_sandbox : Nil
      @mutex.synchronize { set_sandbox_unlocked(false) }
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

    # Re-read rules + the enabled/sandbox flags from the store after an EXTERNAL change —
    # another process (`gori run project scope add/rm`) or another instance's TUI writing
    # to the SAME db. Mirrors Rules#reload: every other piece of code already holds a
    # reference to THIS object (Sitemap, Interceptor, Probe, the Sandbox gate…), so
    # refreshing it in place is enough — no additional wiring needed. Pulled by the TUI's
    # data_version poll (Runner#apply_external_change) and headless capture's periodic
    # reload fiber (App#spawn_reload_loop), the same two call sites Rules#reload already
    # has.
    def reload : Nil
      @mutex.synchronize do
        reload_rules_unlocked
        @enabled = @store.setting(SETTING_ENABLED) == "1"
        @sandbox = @store.setting(SETTING_SANDBOX) == "1"
      end
    end

    # A regex pattern must compile — the SQLite REGEXP callback and the proxy hot path
    # both call `Regex.new` and would otherwise raise. host/string patterns always valid.
    # nil when (match_type, pattern) is a storable scope rule; otherwise a human-readable
    # reason. The SINGLE validation chokepoint: Scope#add / #update — and therefore EVERY
    # write path (the TUI popup via ProjectView#commit_scope_rule, `gori run project scope
    # add`, the History add-host quick-action) — gate on Scope.valid?, defined below in
    # terms of this, so a rejection here keeps a dead rule out of the store regardless of
    # which entry point created it.
    #   regex — must compile (the SQLite REGEXP callback + the proxy hot path both call
    #           Regex.new and would otherwise raise).
    #   host  — must NOT carry a :PORT. A host rule matches the BARE host on any port
    #           (Rule#host_match? compares the port-less host, and the scope URL built by
    #           request_url carries no port for origin-form flows), so "127.0.0.1:9091"
    #           could NEVER match and would sit in the store as a silent dead rule.
    def self.validation_error(match_type : String, pattern : String) : String?
      case match_type
      when "host"
        if host_pattern_has_port?(pattern)
          "host rule must not include a port — a host rule already matches every port; " \
          "use the bare host #{host_without_port(pattern).inspect} (matches any port)"
        end
      when "regex"
        "invalid regex (failed to compile)" unless valid_regex?(pattern)
      end
    end

    # A rule is storable ⇔ validation finds no problem. Kept as the boolean the existing
    # callers use (Scope#add/#update gate, the overlay's Save-button + commit path).
    def self.valid?(match_type : String, pattern : String) : Bool
      validation_error(match_type, pattern).nil?
    end

    # True ⇔ a host-type pattern carries an explicit :PORT suffix a host rule can never
    # match. Recognises "host:8080", "1.2.3.4:8080", "*.acme.test:8080" and bracketed
    # "[::1]:8080", while NOT flagging a bare IPv6 literal ("::1", "fe80::1") whose colons
    # form the address. A non-numeric suffix ("host:abc") is intentionally NOT flagged
    # here (out of the port scope of this check; still a dead rule but not this finding).
    private def self.host_pattern_has_port?(pattern : String) : Bool
      if pattern.starts_with?('[') # bracketed IPv6: [::1] or [::1]:port — the port follows ']'
        return false unless close = pattern.index(']')
        rest = pattern[(close + 1)..]
        return rest.starts_with?(':') && rest.size > 1 && rest[1..].each_char.all?(&.ascii_number?)
      end
      i = pattern.rindex(':')
      return false unless i && i < pattern.size - 1 # no ':' or nothing after it
      return false if pattern[0...i].includes?(':') # unbracketed IPv6 literal → no port
      pattern[(i + 1)..].each_char.all?(&.ascii_number?)
    end

    # The pattern with its :PORT stripped, for the rejection message (only called when a
    # port is present). "[::1]:9091" → "[::1]"; "127.0.0.1:9091" → "127.0.0.1".
    private def self.host_without_port(pattern : String) : String
      if pattern.starts_with?('[') && (close = pattern.index(']'))
        return pattern[0..close]
      end
      i = pattern.rindex(':')
      i ? pattern[0...i] : pattern
    end

    # Regex compiles? (the historical `valid?` body, now a helper of validation_error.)
    private def self.valid_regex?(pattern : String) : Bool
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

    private def set_sandbox_unlocked(value : Bool) : Nil
      @sandbox = value
      @store.set_setting(SETTING_SANDBOX, value ? "1" : "0")
    end

    # The scope-matching URL for a live request: `scheme://host` + `target`, UNLESS
    # `target` is already ABSOLUTE-FORM (`http://host[:port]/path`) — the wire shape
    # every plain-HTTP forward-proxy request arrives in (curl -x, a browser proxying
    # a non-TLS site, a hand-written `send_request` `raw` template, …). Concatenating
    # scheme://host onto an already-absolute target doubles it into
    # `http://hosthttp://host/path`, which silently breaks any anchored or exact-match
    # string/regex scope rule for such requests (unanchored patterns still match — the
    # real target survives as a suffix — which is how this went unnoticed). Shared by
    # every caller that builds this URL from a live request's parts (Interceptor,
    # send_request); the absolute-form check itself is Store::FlowRow.absolute_form?
    # (models.cr), also used by QL::URL_EXPR below, so a case-sensitivity fix only
    # needs to land in one place. Deliberately does NOT add the port the way FlowRow#url
    # does, so an origin-form target still builds the exact same URL every existing
    # Scope spec already agrees on.
    def self.request_url(scheme : String, host : String, target : String) : String
      return target if Store::FlowRow.absolute_form?(target)
      "#{scheme}://#{host}#{target}"
    end

    private def rule_cond(rule : Rule) : {String, Array(DB::Any)}
      case rule.match_type
      when "host"
        host_cond(rule.pattern)
      when "string"
        # Case-insensitive substring of the URL; QL.like neutralises % / _ so a literal
        # %/_ in the pattern matches literally (paired with ESCAPE '\').
        {"lower(#{QL::URL_EXPR}) LIKE ? ESCAPE '\\'", [QL.like(rule.pattern)] of DB::Any}
      when "regex"
        # Case-SENSITIVE (no lower()) to match Rule#matches? + the shard's REGEXP.
        {"#{QL::URL_EXPR} REGEXP ?", [rule.pattern] of DB::Any}
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
