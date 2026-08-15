require "db"
require "./ql"
require "./host_pattern"
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
      # Host rules only (nil for string/regex): the shared host-pattern dialect, compiled
      # once here — see Gori::HostPattern, which the TLS passthrough list uses too.
      @host_pattern : HostPattern::Compiled?

      def initialize(@id : Int64, @kind : String, @match_type : String, @pattern : String)
        # The pattern is immutable (a Rule is rebuilt, never edited in place), so its
        # lowercased form — compared on every host/string match, once per rule per row
        # of a Scope-filtered reload and per host of a Sitemap reload — is computed ONCE
        # here rather than re-allocated on each `matches?` call (mirrors @regex).
        @pattern_down = @pattern.downcase
        # Precompute the host forms (lowercased + bracket-free, so an IPv6 rule matches
        # whether the flow host was captured bracketed or bare) only for host rules — a
        # string/regex rule never consults them.
        @host_pattern = HostPattern::Compiled.new(@pattern) if @match_type == "host"
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
            # `.scrub` the SUBJECT, not just rescue it. PCRE2 raises `ArgumentError` on a
            # non-UTF-8 subject, and `request_target` does not scrub what came off the wire,
            # so a request whose target carries a raw byte >= 0x80 used to take the rescue
            # below — reporting "no match". On an EXCLUDE rule "no match" means NOT excluded,
            # i.e. the gate fails OPEN, and a peer can dodge a regex exclude by planting one
            # invalid byte in the target. Scrubbing evaluates the rule as written instead.
            # The rescue stays as defense-in-depth for anything else PCRE2 refuses.
            r.matches?(url.scrub)
          rescue
            false
          end
        else
          false
        end
      end

      # Exact / subdomain / glob host matching, in the dialect shared with the TLS
      # passthrough list (Gori::HostPattern). Only reachable for a host rule, so
      # @host_pattern is non-nil; `try` keeps a hand-constructed odd rule non-matching
      # rather than raising onto the proxy hot path.
      private def host_match?(host : String) : Bool
        !!@host_pattern.try(&.matches?(host))
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
      #
      # Guards those fields ONLY, and every critical section it has is a field read or a
      # pointer swap. The store round-trips that used to sit inside it do not: `exec_task`
      # parks the calling fiber on its reply channel, and with `busy_timeout=5000` a PEER
      # process holding the write lock parks it for up to five seconds. `sandbox_blocks?` /
      # `sandbox_blocks_host?` / `in_scope_url?` / `may_match_host?` take this same mutex on
      # every proxied request, so holding it across a write stalled every dial, intercept
      # gate and sandbox decision in the process for as long as the peer held the lock —
      # and `reload`, which the TUI's data_version poll and headless capture's reload fiber
      # call on a timer, did three store reads inside it. `HostOverrides` measured and fixed
      # exactly this; `Scope` is the sibling that had the same shape.
      @mutex = Mutex.new
      # Serialises WRITERS through this instance, so the dedupe-then-write-then-verify
      # sequences below stay atomic against each other now that they no longer hold
      # @mutex for their duration. Same scope as `HostOverrides#@write_mutex`: it covers
      # this object, not the table — MCP and the CLI each load a `Scope` of their own, and
      # are answered the way a peer PROCESS is (the UNIQUE triple plus the post-write
      # verify), which is the case that has to work regardless.
      @write_mutex = Mutex.new
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

    # Conservative HOST-level check behind `Interceptor#intercepts_host?`, made BEFORE any
    # request exists (so no path/URL is known yet). A host is *potentially* in scope when
    # includes don't rule it out — no includes, OR a host-include matches, OR any url-level
    # include exists (its path we can't know yet) — AND no HOST-level exclude fully covers it
    # (url-level excludes only kill specific paths, never a whole host). The precise per-message
    # call is `in_scope_url?` via `intercepts_request?`/`intercepts_response?`, which do not
    # consult this. It used to drive the Tunnel's h2→h1 downgrade as well; #492 step 3 made the
    # hold work per stream on h2 and removed that.
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

    # Coarse HOST-level block for the pre-handshake gates (CONNECT, transparent SNI, reverse),
    # made BEFORE any request exists (no path/URL yet). Blocks only when the host CAN'T be in
    # scope, so a partially-in-scope host is still tunnelled and then gated PER REQUEST — by
    # `ClientConn#handle_request` on h1 and by `H2::StreamGate` on h2 (#492 step 4). That per-
    # request gate is not optional garnish on this one: a url-level include (whose path we can't
    # know here) keeps EVERY host allowed past this point, so with a path-scoped scope this
    # method blocks nothing and `sandbox_blocks?` does the entire job. Only a host-level include
    # set that excludes the host — or an empty allowlist — blocks it outright here. Returns
    # false when the sandbox is off.
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

    # These three return whether the persisted sandbox flag COMMITTED (false = store
    # busy/locked/closing), exactly as `enable`/`disable` do for the enabled flag beside
    # them. The in-memory `@sandbox` is set either way, and one `Scope` instance is shared
    # by the Interceptor and by every `Outbound` built from it — so a dropped write is not
    # merely "does not survive restart": the next `reload` re-reads the PERSISTED value and
    # silently reverts the gate a surface has already reported as on.
    def toggle_sandbox : Bool
      @write_mutex.synchronize { set_sandbox(!@mutex.synchronize { @sandbox }) }
    end

    def enable_sandbox : Bool
      @write_mutex.synchronize { set_sandbox(true) }
    end

    def disable_sandbox : Bool
      @write_mutex.synchronize { set_sandbox(false) }
    end

    # The `host` column with a SURROUNDING bracket pair peeled — the SQL twin of
    # `HostPattern.bare`, which `Rule#host_match?` applies to the flow host before matching.
    # host_cond peeled the PATTERN only, and this file's comment claimed both; a flow captured
    # as `[::1]` was therefore in scope at every live gate (intercept hold, sandbox, Probe
    # allowlist, the Sitemap marker) while the History/Sitemap SQL lens hid it — and no host
    # rule could reach it, since a `[::1]` pattern is bared to `::1` on the way in too. That
    # host shape is not exotic: `resolve_forward` puts a plain-HTTP forward-proxy request's
    # absolute-form target through `URI#host`, which hands back IPv6 literals BRACKETED, and
    # FlowMapper stores it verbatim.
    #
    # Spelled as the pair test rather than `trim(host, '[]')` so it peels exactly what
    # `HostPattern.bare` peels: a half-bracketed oddity like `[::1` keeps its bracket on both
    # sides of the parity, instead of the two disagreeing again in the other direction.
    HOST_BARE = "(CASE WHEN substr(host, 1, 1) = '[' AND substr(host, -1) = ']' " \
                "THEN substr(host, 2, length(host) - 2) ELSE host END)"

    # A SQL filter selecting in-scope flows (QL::EMPTY when inactive). The URL the
    # string/regex rules see is `scheme || '://' || host || target` — the same value
    # `in_scope_url?` builds in memory. Combined Burp-style:
    #   ( <includes OR'd, or 1 when none>  [AND NOT (<excludes OR'd>)] )
    def filter : QL::Filter
      @mutex.synchronize do
        return QL::EMPTY unless active_unlocked?
        inc_conds = [] of String
        exc_conds = [] of String
        # Bucket the values with their conditions. The SQL below is assembled
        # includes-then-excludes, but @rules is in rule-id order, so a single flat array
        # bound an exclude's pattern to an include's `?` (and vice versa) whenever an
        # exclude rule was stored first — the filter then silently described a different
        # set than `in_scope_url?`. Same placeholder/value discipline QL.tree_sql documents.
        inc_args = [] of DB::Any
        exc_args = [] of DB::Any
        @rules.each do |rule|
          cond, cargs = rule_cond(rule)
          if rule.include?
            inc_conds << cond
            inc_args.concat(cargs)
          else
            exc_conds << cond
            exc_args.concat(cargs)
          end
        end
        inc_sql = inc_conds.empty? ? "1" : "(#{inc_conds.join(" OR ")})"
        exc_sql = exc_conds.empty? ? "" : " AND NOT (#{exc_conds.join(" OR ")})"
        QL::Filter.new("(#{inc_sql}#{exc_sql})", inc_args + exc_args)
      end
    end

    # Add a rule (validates regex, dedupes on the kind/type/pattern triple). Returns
    # false (no-op) on an empty pattern, an invalid regex, a duplicate — or a store write
    # that did not commit.
    #
    # That last case used to return TRUE: unlike update/remove (exec_task_ok) the INSERT goes
    # through exec_task, which reports nothing, so a busy/locked/closing store rolled the
    # batch back and `add` still said yes. The rule then wasn't in the store OR in @rules, and
    # every caller reported a rule that gates traffic but does not exist — MCP even emitted
    # `{"id": null}` as ordinary success. The reload right above already fetches the truth, so
    # the answer is simply to look: present ⇒ stored.
    def add(kind : String, match_type : String, pattern : String) : Bool
      pattern = pattern.strip
      return false if pattern.empty? || !KINDS.includes?(kind) || !Scope.valid?(match_type, pattern)
      @write_mutex.synchronize do
        return false if rules_snapshot.any? { |r| r.kind == kind && r.match_type == match_type && r.pattern == pattern }
        @store.add_scope_rule(kind, match_type, pattern)
        reload_rules
        rules_snapshot.any? { |r| r.kind == kind && r.match_type == match_type && r.pattern == pattern }
      end
    end

    # Edit a rule in place (by id). Same validation; dedupes against OTHER rules so a
    # no-op self-edit is allowed. Returns false on empty/invalid/duplicate.
    def update(id : Int64, kind : String, match_type : String, pattern : String) : Bool
      pattern = pattern.strip
      return false if pattern.empty? || !KINDS.includes?(kind) || !Scope.valid?(match_type, pattern)
      @write_mutex.synchronize do
        return false if rules_snapshot.any? { |r| r.id != id && r.kind == kind && r.match_type == match_type && r.pattern == pattern }
        # The store's answer, not an unconditional `true`. `update_scope_rule` is `exec_task_ok`
        # and has always reported whether the UPDATE committed; `remove` below returns it, and
        # `HostOverrides#update` next door returns it with the note "false also when the store
        # write rolled back (busy/locked), not just on dup" — this was the one sibling still
        # discarding it. `ProjectView#commit_scope_rule`, its only caller, is written around
        # getting it: it settles the duplicate case itself so that "whatever false survives that
        # is the store", and answers `:failed` — "the store refused the write, the scope is
        # unchanged". That branch was unreachable for an EDIT, so an operator who narrowed a
        # rule was told the scope had changed while the old, wider pattern was still the one
        # gating what may be probed and fuzzed.
        #
        # The dup pre-check above is not the whole guard: it reads THIS object's snapshot, so a
        # rule another instance added since the last reload is invisible to it and the write
        # then violates the table's UNIQUE triple and rolls back. That is the reachable path,
        # and it is the one that used to report success.
        committed = @store.update_scope_rule(id, kind, match_type, pattern)
        reload_rules
        committed
      end
    end

    # Returns whether the DELETE COMMITTED (false = store busy/locked/closing).
    #
    # Unlike `add` above — where `add_scope_rule` goes through `exec_task` and genuinely
    # reports nothing, so looking at the reloaded list is the only answer available —
    # `remove_scope_rule` is `exec_task_ok` and has had the answer all along. Dropping it made
    # every caller claim a security rule was deleted while it was still gating traffic, and
    # each surface invented its own workaround: MCP bypassed `Scope` entirely to reach the
    # flag, and the CLI re-read the reloaded rule list. One dropped return value, three
    # treatments — so it is returned here instead.
    def remove(id : Int64) : Bool
      @write_mutex.synchronize do
        ok = @store.remove_scope_rule(id)
        reload_rules
        ok
      end
    end

    def toggle : Nil
      @write_mutex.synchronize { set_enabled(!@mutex.synchronize { @enabled }) }
    end

    # Returns whether the persisted enabled flag committed (false = store busy/locked).
    def enable : Bool
      @write_mutex.synchronize { set_enabled(true) }
    end

    # Returns whether the persisted enabled flag committed (false = store busy/locked).
    def disable : Bool
      @write_mutex.synchronize { set_enabled(false) }
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
      # All three store reads run OUTSIDE @mutex, then swap together — this is called on a
      # TIMER (the TUI data_version poll, headless capture's reload fiber), so doing them
      # under the hot-path lock stalled every proxied request on each tick for as long as
      # the store took to answer.
      fresh = Scope.load_rules(@store)
      enabled = @store.setting(SETTING_ENABLED) == "1"
      sandbox = @store.setting(SETTING_SANDBOX) == "1"
      @mutex.synchronize do
        @rules = fresh
        @enabled = enabled
        @sandbox = sandbox
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
    # `kind` is validated by `add`/`update` against KINDS rather than here, since this
    # function answers about the (match_type, pattern) pair its callers show the operator. A
    # stored `"Include"` would be neither `include?` nor `exclude?`: counted by `size` and
    # drawn in the SCOPE card, but read as ZERO includes by `matches_url_unlocked?`, which
    # then passes everything. Every write path checks KINDS itself today (MCP, `gori run
    # project scope add`/`update`, and the TUI overlay, which can only index into KINDS), so
    # the guard closes no live hole — same argument, and same next-caller guarantee, as the
    # match_type `else` arm below.
    #   match_type — must be one of TYPES. This case had no `else`, so any other string fell
    #           through to nil and `valid?` said yes: `Scope#add` stored it, and `Rule#matches?`
    #           (whose own `case` DOES end in `else false`) then never matched it. A typo'd
    #           `exclude strng logout` was listed in the operator's scope and silently excluded
    #           nothing — fail-OPEN on the exclude gate, and precisely the "silent dead rule"
    #           the host:port check below exists to prevent. Every write path happens to check
    #           membership itself today (MCP `tools/scope.cr`, `gori run project scope
    #           add`/`update`, and the TUI overlay, which can only cycle an index into TYPES),
    #           so this closes no live hole — it makes the guarantee this comment already
    #           claimed actually hold for the next caller.
    #   regex — must compile (the SQLite REGEXP callback + the proxy hot path both call
    #           Regex.new and would otherwise raise).
    #   host  — must be a BARE host: no scheme, path, userinfo, query/fragment or whitespace
    #           (host_pattern_shape_error), and no :PORT. A host rule matches the BARE host on
    #           any port (Rule#host_match? compares the port-less host, and the scope URL built
    #           by request_url carries no port for origin-form flows), so "127.0.0.1:9091" or
    #           "https://acme.test/admin" could NEVER match and would sit in the store as a
    #           silent dead rule.
    def self.validation_error(match_type : String, pattern : String) : String?
      case match_type
      when "host"
        if e = host_pattern_shape_error(pattern)
          e
        elsif host_pattern_has_port?(pattern)
          "host rule must not include a port — a host rule already matches every port; " \
          "use the bare host #{host_without_port(pattern).inspect} (matches any port)"
        end
      when "string"
        nil
      when "regex"
        "invalid regex (failed to compile)" unless valid_regex?(pattern)
      else
        "unknown match type #{match_type.inspect} (expected #{TYPES.join(", ")})"
      end
    end

    # A rule is storable ⇔ validation finds no problem. Kept as the boolean the existing
    # callers use (Scope#add/#update gate, the overlay's Save-button + commit path).
    def self.valid?(match_type : String, pattern : String) : Bool
      validation_error(match_type, pattern).nil?
    end

    # Characters a request host can NEVER contain, so a host-type pattern carrying one can
    # never fire. Deliberately a BLACKLIST, not a hostname whitelist: an IDN target typed in
    # its unicode form, or a name with an underscore, is the operator's business — only the
    # shapes that are provably dead are rejected.
    HOST_PATTERN_FORBIDDEN = {'/', '\\', '?', '#', '@'}

    # A host rule matches the BARE host of a request (Rule#host_match? / host_cond both
    # compare against the `host` column alone), so a pattern carrying a scheme, a path,
    # userinfo, a query/fragment or whitespace is a rule that matches NOTHING while sitting
    # in the operator's scope list looking configured. That is worse than a typo in both
    # directions: a dead INCLUDE under the Sandbox blocks ALL traffic while `include_count`
    # stays non-zero, so even the "blocks everything" warning stays quiet; a dead EXCLUDE
    # fails OPEN and carves out nothing. Same silent-dead-rule failure the :PORT check below
    # prevents, and the same mistake that produces it — pasting a URL where a host goes.
    private def self.host_pattern_shape_error(pattern : String) : String?
      offender = pattern.each_char.find { |c| c.whitespace? || c.in?(HOST_PATTERN_FORBIDDEN) }
      return nil unless offender
      shown = offender.whitespace? ? "whitespace" : offender.to_s.inspect
      base = "host rule must be a bare host — #{pattern.inspect} contains #{shown}, " \
             "which a request host never does"
      if suggestion = host_from_urlish(pattern)
        "#{base}; use #{suggestion.inspect} (a host rule already matches every scheme, port and path)"
      else
        "#{base} (use a string or regex rule to match a URL)"
      end
    end

    # Best-effort "what the operator meant": the host of a URL-ish pattern, with the scheme,
    # userinfo, path/query/fragment and :PORT peeled off. nil when what's left still isn't
    # host-shaped (e.g. "acme.test admin", where guessing which half was meant would be
    # worse than saying nothing), so the message degrades to the plain complaint rather than
    # suggesting a pattern that is itself dead.
    private def self.host_from_urlish(pattern : String) : String?
      s = pattern.strip
      if i = s.index("://")
        s = s[(i + 3)..]
      end
      s = s.split(/[\/?#]/, 2).first
      if at = s.rindex('@')
        s = s[(at + 1)..]
      end
      return nil if s.empty?
      return nil if s.each_char.any? { |c| c.whitespace? || c.in?(HOST_PATTERN_FORBIDDEN) }
      s = host_without_port(s) if host_pattern_has_port?(s)
      bare_host(s).presence
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

    # A host / host-pattern reduced to the bare, bracket-free form the CONNECT/tunnel
    # path stores ("[::1]" → "::1"). IPv6 flow hosts arrive bracketed via some URL-parsing
    # paths but bare via the dominant HTTPS-MITM CONNECT path; peeling surrounding brackets
    # on BOTH the rule pattern and the flow host lets "[::1]" and "::1" match interchangeably
    # (Rule#host_match? / host_cond) and keeps the suggested form the one actually stored.
    # Kept as Scope's own name (several call sites here, plus specs) but delegating, so
    # there is ONE implementation shared with the TLS passthrough list.
    def self.bare_host(host : String) : String
      HostPattern.bare(host)
    end

    # True when `host_cond`'s NATIVE SQL spelling provably means the same thing as
    # `HostPattern::Compiled`. Three things part them, and the PATTERN is what this predicate
    # reads to decide which of the three can arise:
    #
    #   · non-ASCII — SQLite's built-in `lower()` folds ASCII only while Crystal's
    #     `String#downcase` folds all of Unicode, so a rule `äcme.test` matched a captured
    #     `ÄCME.test` in the live gate and nothing in History.
    #   · `{a,b}` — Crystal's `File.match?` reads brace alternation; SQLite's GLOB reads the
    #     braces literally. An include `*.acme.{test,dev}` matched three hosts live and none
    #     in History, and an exclude with braces carved out nothing in SQL — fail-OPEN on the
    #     display lens, the direction that matters.
    #   · a SURROUNDING bracket pair — `HostPattern::Compiled` peels it for the exact/subdomain
    #     arm (`@bare`) but globs against the UN-peeled `@down`, so `[2001:db8::*]` is a rule
    #     that matches NOTHING in Crystal (`File.match?` reads the outer `[…]` as a character
    #     class). host_cond peels first, so its GLOB would match every host under
    #     `2001:db8::` — a dead INCLUDE listing its flows as in-scope in History while
    #     `allowlisted_unlocked?` refuses every request, i.e. Sandbox black-holes the proxy
    #     with `include_count` non-zero and the "blocks everything" warning quiet. Gated on
    #     the bracket pair alone rather than "bracketed AND globbed": which of Compiled's two
    #     arms applies is exactly the thing not worth restating here.
    #
    # Anything else routes through `gori_host_match`, which IS HostPattern — so the fast path
    # stays native (host matching runs per row of every scope-filtered reload) and the shapes
    # it cannot spell have no second dialect at all. `?`, a non-surrounding `[…]` and an
    # unbalanced `[` were checked and agree between the two engines; `/ \ ? # @` and whitespace
    # can't reach a stored host pattern anyway (validation_error).
    #
    # The bound this trades for that fast path: the folding case can in principle be triggered
    # from the HOST side too, by a non-ASCII character whose Unicode lowercase IS ASCII (U+212A
    # KELVIN SIGN folds to `k`) sitting in a column an ASCII pattern reads. Deciding that per
    # ROW means the UDF on every row of every reload, for a host no DNS resolver would answer.
    def self.sql_native_host?(pattern : String) : Bool
      pattern.ascii_only? && !pattern.includes?('{') && !pattern.includes?('}') &&
        bare_host(pattern) == pattern
    end

    # The pattern with its :PORT stripped AND surrounding brackets peeled, for the
    # rejection message (only called when a port is present). "[::1]:9091" → "::1";
    # "127.0.0.1:9091" → "127.0.0.1". The bare form is the one host matching stores/compares,
    # so following the suggestion yields a rule that actually matches.
    private def self.host_without_port(pattern : String) : String
      if pattern.starts_with?('[') && (close = pattern.index(']'))
        return bare_host(pattern[0..close])
      end
      i = pattern.rindex(':')
      bare_host(i ? pattern[0...i] : pattern)
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
    # The rule list as the hot path sees it. Read under @mutex; the array is rebuilt rather
    # than edited in place, so a concurrent matcher reads either the whole old list or the
    # whole new one.
    private def rules_snapshot : Array(Rule)
      @mutex.synchronize { @rules }
    end

    # Re-read the rules and swap them in. The SELECT runs OUTSIDE @mutex — see the
    # constructor — and only the pointer swap is guarded.
    private def reload_rules : Nil
      fresh = Scope.load_rules(@store)
      @mutex.synchronize { @rules = fresh }
    end

    # Flag writers: the in-memory field is swapped under @mutex (the hot path reads it
    # there), and the persisting write runs outside it. Callers hold @write_mutex, which is
    # what keeps a concurrent toggle from interleaving between the read and the write.
    private def set_enabled(value : Bool) : Bool
      @mutex.synchronize { @enabled = value }
      @store.set_setting(SETTING_ENABLED, value ? "1" : "0")
    end

    private def set_sandbox(value : Bool) : Bool
      @mutex.synchronize { @sandbox = value }
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
      # The rule itself moved to core `Gori::Url` (InterceptFilter's `url:` term needs it and
      # cannot require the store); this stays as the name its existing callers already use.
      Gori::Url.request_url(scheme, host, target)
    end

    private def rule_cond(rule : Rule) : {String, Array(DB::Any)}
      case rule.match_type
      when "host"
        host_cond(rule.pattern)
      when "string"
        # Case-insensitive substring of the URL, through the SAME `downcase.includes?`
        # Rule#matches? runs (Store::ScopeMatch). The native spelling was
        # `lower(URL_EXPR) LIKE ?`, and SQLite's built-in `lower()` folds ASCII ONLY: a
        # rule `/über` matched a captured `/Über` in the live gate and nothing in History,
        # breaking the branch-for-branch parity this file's header promises. Nothing is
        # lost by going through the function: `URL_EXPR` concatenates a fresh string per
        # row for the old `lower(…) LIKE` to fold and scan, so there was no index to give
        # up — and a literal % / _ in the pattern now needs no LIKE escaping at all.
        {"gori_ci_contains(#{QL::URL_EXPR}, ?)", [rule.pattern] of DB::Any}
      when "regex"
        # Case-SENSITIVE (no lower()) to match Rule#matches? + the shard's REGEXP.
        {"#{QL::URL_EXPR} REGEXP ?", [rule.pattern] of DB::Any}
      else
        {"0", [] of DB::Any}
      end
    end

    private def host_cond(pattern : String) : {String, Array(DB::Any)}
      # A pattern the native spelling below cannot express faithfully is matched by the very
      # object Rule#host_match? uses (Store::ScopeMatch), so the two can't drift.
      return {"gori_host_match(host, ?)", [pattern] of DB::Any} unless Scope.sql_native_host?(pattern)
      # Peel brackets so a "[::1]" rule compares against the bare "::1" the host column
      # stores — matches Rule#host_match?'s @pattern_host normalization (keeps SQL parity).
      pattern = Scope.bare_host(pattern)
      if pattern.includes?('*')
        {"lower(#{HOST_BARE}) GLOB ?", [pattern.downcase] of DB::Any}
      else
        d = pattern.downcase
        # The subdomain arm splices the host into a LIKE pattern, so its % / _ must be
        # escaped (keeping the literal leading `%.`) or a host like `a_b.test` would
        # match `aXb.test` in SQL but not in Rule#host_match? — breaking parity.
        {"(lower(#{HOST_BARE}) = ? OR lower(#{HOST_BARE}) LIKE ? ESCAPE '\\')",
         [d, "%.#{QL.like_escape(d)}"] of DB::Any}
      end
    end
  end
end
