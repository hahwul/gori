require "./env"
require "./proxy/head_rewriter"
require "./rules/stub"
require "./store"
require "./store/safe_regexp"

module Gori
  # The Match&Replace lens (the "Rewriter" tab): rewrites of request/response messages
  # applied in flight. A rule either REPLACES text (literal substring or regex with
  # $1/\1 capture groups) in the HEAD (request/status line + headers) or BODY (the
  # entity), or performs a header operation by NAME (add / set / remove). Rules can be
  # scoped to a host glob. Human-configured (P4), persisted per project.
  #
  # One instance is SHARED between the proxy fibers (which call `rewrite_*` on every
  # message) and the TUI (which edits the rule set). A Mutex guards the rule snapshot so
  # an edit can never tear a concurrent rewrite.
  class Rules < Proxy::HeadRewriter
    def initialize(@store : Store, @rules : Array(Store::MatchRule))
      @mutex = Mutex.new
      @stub_bodies = RuleStubBodyCache.new
      # Lock-free fast-path flags: rewrite_* run on EVERY message, but the common case
      # is no rule for that side/part. These let the hot path skip the mutex + select-
      # array allocation entirely when nothing would match. The head counts gate the head
      # rewrite (replace-head AND the header ops, which all act on the head), split PER
      # DIRECTION like the body counts so a request-only rule doesn't tax every response
      # (and vice versa); the body counts also gate whether ClientConn buffers a body at all.
      @req_head_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Request, part: Store::RulePart::Head))
      @resp_head_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Response, part: Store::RulePart::Head))
      @req_body_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Request, part: Store::RulePart::Body))
      @resp_body_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Response, part: Store::RulePart::Body))
      # Short-circuit rules get their OWN gate and are excluded from all four counts above.
      # A stub rule is stored request/head like a header op, so it would otherwise inflate
      # @req_head_count and make every request head pay the mutex + select for a rule that
      # rewrites nothing — and `apply` would then have to skip it anyway, because its
      # `replacement` is a whole HTTP response and gsub'ing that into live traffic is exactly
      # the silent corruption the count exists to avoid.
      @short_circuit_count = Atomic(Int32).new(stub_count(@rules))
      # Pre-merged `$KEY` snapshot for `replacement_for`, invalidated by revision rather
      # than rebuilt per message — see `subst_snapshot`.
      @subst_vars = nil.as(Hash(String, String)?)
      @subst_declared = [] of String
      @subst_env_rev = 0_u32
      @subst_binding_rev = 0_u64
      # Rule ids already reported as blocked on an unbound binding, at that binding revision.
      @unbound_reported = Set(Int64).new
      @unbound_reported_rev = 0_u64
    end

    # Count enabled, non-empty-pattern REWRITE rules matching an optional target + a part.
    # Short-circuit rules are never counted here — see `stub_count`.
    private def active_count(rules : Array(Store::MatchRule), target : Store::RuleTarget? = nil,
                             *, part : Store::RulePart) : Int32
      rules.count do |r|
        r.enabled? && r.op.rewrite? && !r.pattern.empty? && r.part == part &&
          (target.nil? || r.target == target)
      end
    end

    # Count enabled short-circuit rules whose stub is usable. A rule with an unparseable head
    # is counted anyway: it MUST still short-circuit (fail closed — see `stub_for`), because
    # falling through would send a request the operator declared contained.
    private def stub_count(rules : Array(Store::MatchRule)) : Int32
      rules.count { |r| r.enabled? && r.op.short_circuit? && !r.pattern.empty? }
    end

    def self.load(store : Store) : Rules
      new(store, store.match_rules)
    end

    # A copy of the current rules (for the editor UI).
    def rules : Array(Store::MatchRule)
      @mutex.synchronize { @rules.dup }
    end

    # The lens is doing something iff at least one rule is enabled.
    def active? : Bool
      @mutex.synchronize { @rules.any?(&.enabled?) }
    end

    def enabled_count : Int32
      @mutex.synchronize { @rules.count(&.enabled?) }
    end

    # --- editing (persists, then refreshes the snapshot) ---------------------

    def add(target : Store::RuleTarget, part : Store::RulePart, pattern : String, replacement : String,
            op : Store::RuleOp = Store::RuleOp::Replace, match_kind : Store::MatchKind = Store::MatchKind::Literal,
            name : String = "", host : String = "", body_file : String = "") : Nil
      return if pattern.empty?
      target, part = normalize_shape(op, target, part)
      @store.insert_rule(target, part, pattern, replacement, op, match_kind, name, host, body_file: body_file)
      refresh
    end

    def update(id : Int64, target : Store::RuleTarget, part : Store::RulePart, pattern : String, replacement : String,
               op : Store::RuleOp = Store::RuleOp::Replace, match_kind : Store::MatchKind = Store::MatchKind::Literal,
               name : String = "", host : String = "", body_file : String = "") : Nil
      return if pattern.empty?
      target, part = normalize_shape(op, target, part)
      @store.update_rule(id, target, part, pattern, replacement, op, match_kind, name, host, body_file)
      refresh
    end

    # The {target, part} an op can actually have. Header ops are head-only; a short-circuit
    # rule is additionally request-only, because it matches a request and there is no response
    # to match against — the request never gets sent. Forced here (and mirrored by the CLI /
    # MCP / TUI surfaces) so a rule can never be persisted in a shape the proxy would ignore.
    def self.normalize_shape(op : Store::RuleOp, target : Store::RuleTarget,
                             part : Store::RulePart) : {Store::RuleTarget, Store::RulePart}
      return {Store::RuleTarget::Request, Store::RulePart::Head} if op.short_circuit?
      {target, op.header? ? Store::RulePart::Head : part}
    end

    private def normalize_shape(op : Store::RuleOp, target : Store::RuleTarget,
                                part : Store::RulePart) : {Store::RuleTarget, Store::RulePart}
      Rules.normalize_shape(op, target, part)
    end

    def remove(id : Int64) : Nil
      @store.delete_rule(id)
      refresh
    end

    def toggle(id : Int64) : Nil
      rule = rules.find(&.id.==(id))
      return unless rule
      @store.set_rule_enabled(id, !rule.enabled?)
      refresh
    end

    # Move a rule one slot up (dir < 0) / down (dir > 0) in the applied order.
    def move(id : Int64, dir : Int32) : Nil
      @store.move_rule(id, dir)
      refresh
    end

    # Re-read the store snapshot (e.g. after an external MCP / other-instance edit). Same
    # work `refresh` does, exposed so the Rewriter tab can pull external changes on enter.
    def reload : Nil
      refresh
    end

    # --- HeadRewriter (called from proxy fibers) -----------------------------

    def rewrite_request(head : Bytes, host : String) : Bytes
      apply(head, Store::RuleTarget::Request, Store::RulePart::Head, @req_head_count, host)
    end

    def rewrite_response(head : Bytes, host : String) : Bytes
      apply(head, Store::RuleTarget::Response, Store::RulePart::Head, @resp_head_count, host)
    end

    # A body rule is live iff at least one enabled, non-empty rule targets that side's
    # body — ClientConn keys the (expensive) body buffer on these.
    def rewrites_request_body? : Bool
      @req_body_count.get > 0
    end

    def rewrites_response_body? : Bool
      @resp_body_count.get > 0
    end

    # Whether a body rule that can actually MATCH `host` is live (#526). The two predicates
    # above answer "is any body rule live", which is the right question for `ClientConn` (it
    # is deciding whether to pay for a body buffer on a connection already pinned to one
    # host) and the wrong one for the h2 downgrade gate: that gate costs the host its
    # protocol, and a rule scoped to `alpha.test` was costing `127.0.0.1` its protocol too.
    #
    # The atomic counts are still the fast path — no body rule anywhere means no lock and no
    # select — and `host_matches?` (memoised, see below) then decides the rest. Both sides
    # are folded into one question because the gate downgrades for either.
    #
    # Once per CONNECT, so the mutex here is not on any hot path.
    def rewrites_body_for_host?(host : String) : Bool
      return false if @req_body_count.get == 0 && @resp_body_count.get == 0 # lock-free fast path
      @mutex.synchronize do
        @rules.any? do |r|
          r.enabled? && r.op.rewrite? && !r.pattern.empty? && r.part.body? && host_matches?(r.host, host)
        end
      end
    end

    def rewrite_request_body(entity : Bytes, host : String) : Bytes
      apply(entity, Store::RuleTarget::Request, Store::RulePart::Body, @req_body_count, host)
    end

    def rewrite_response_body(entity : Bytes, host : String) : Bytes
      apply(entity, Store::RuleTarget::Response, Store::RulePart::Body, @resp_body_count, host)
    end

    # --- short circuit (#511) ------------------------------------------------

    def short_circuits? : Bool
      @short_circuit_count.get > 0
    end

    # `short_circuits?` narrowed to one host (#526) — the same split, and for the same
    # reason, as `rewrites_body_for_host?` above. The host filter is exactly the one
    # `short_circuit` itself applies, so this answers "could `short_circuit` ever return a
    # stub for this host", which is precisely what the downgrade gate is protecting.
    def short_circuits_for_host?(host : String) : Bool
      return false if @short_circuit_count.get == 0 # lock-free fast path
      @mutex.synchronize do
        @rules.any? do |r|
          r.enabled? && r.op.short_circuit? && !r.pattern.empty? && host_matches?(r.host, host)
        end
      end
    end

    # The stub answering this request head, or nil when no rule claims it. The FIRST matching
    # rule in the applied order wins and the rest are not consulted — a stub terminates the
    # exchange, so "apply them all in order" (what the rewrite ops do) has no meaning here.
    def short_circuit(head : Bytes, host : String) : Proxy::HeadRewriter::Stub?
      return nil if @short_circuit_count.get == 0 # lock-free fast path
      active = @mutex.synchronize do
        @rules.select do |r|
          r.enabled? && r.op.short_circuit? && !r.pattern.empty? && host_matches?(r.host, host)
        end
      end
      return nil if active.empty?
      text = String.new(head)
      rule = active.find { |r| stub_matches?(r, text) }
      rule ? stub_for(rule) : nil
    end

    # Whether a stub rule's pattern claims this request head. Same literal/regex split the
    # `Replace` op uses, so `match:` means the same thing on both. A regex that fails to
    # compile (or meets non-UTF-8 bytes) does NOT match — the rule stays inert rather than
    # capturing every request, which is the safe direction for an op that stops traffic.
    private def stub_matches?(rule : Store::MatchRule, text : String) : Bool
      if rule.match_kind.regex?
        begin
          SafeRegexp.compile(rule.pattern).matches?(text)
        rescue
          false
        end
      else
        text.includes?(rule.pattern)
      end
    end

    # Build the response bytes for a matched stub rule. Never returns nil: once a rule has
    # claimed the request, gori answers it. An unparseable stub or an unreadable `body_file`
    # becomes a gori-authored 502 carrying the reason, which ClientConn records on the flow —
    # falling through to the origin instead would send a request the operator declared
    # contained, and a payload leaking because a stub file was deleted is the worse failure.
    private def stub_for(rule : Store::MatchRule) : Proxy::HeadRewriter::Stub
      head = RuleStub.parse_head(rule.replacement)
      return stub_failure(rule, "stub response head could not be parsed") unless head
      body = if rule.body_file.empty?
               RuleStub.inline_body(rule.replacement)
             else
               begin
                 @stub_bodies.read(rule.body_file)
               rescue ex : Gori::Error
                 return stub_failure(rule, ex.message || "stub body file unreadable")
               end
             end
      Proxy::HeadRewriter::Stub.new(head.bytes, body, head.status, rule.id)
    end

    # gori's own answer when a rule cannot be honoured. Unlike a stub, this one IS marked on
    # the wire (`X-Gori-Short-Circuit: error`): the operator's bytes go out untouched, but
    # bytes gori invented say so.
    private def stub_failure(rule : Store::MatchRule, message : String) : Proxy::HeadRewriter::Stub
      body = "gori: short-circuit rule ##{rule.id} could not be applied: #{message}\n".to_slice
      head = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nX-Gori-Short-Circuit: error\r\n".to_slice
      Proxy::HeadRewriter::Stub.new(head, body, 502, rule.id, error: message)
    end

    # Live preview for the Rewriter tab: apply every enabled rule for `target` over a
    # full HTTP message (head + body split on the first blank line). Host-scoped rules
    # use `host` (typically parsed from the sample's Host header). Empty host → only
    # unscoped rules match. Order matches the proxy path (head rules then body rules).
    #
    # `report: false` — a preview is a keystroke path over stored flows and must not write
    # an "unbound binding" event per keypress. It still SKIPS such a rule, so the preview
    # shows the operator what the proxy would really do.
    def transform_message(text : String, target : Store::RuleTarget, host : String = "") : String
      head, body, sep = split_message(text)
      new_head = String.new(apply(head.to_slice, target, Store::RulePart::Head,
        target.request? ? @req_head_count : @resp_head_count, host, report: false))
      new_body = String.new(apply(body.to_slice, target, Store::RulePart::Body,
        target.request? ? @req_body_count : @resp_body_count, host, report: false))
      "#{new_head}#{sep}#{new_body}"
    end

    # Split an HTTP message into {head, body, separator}. Separator is "\r\n\r\n" or
    # "\n\n" when a blank line exists; otherwise the whole text is the head and sep/body
    # are empty (so header-only samples still rewrite).
    private def split_message(text : String) : {String, String, String}
      if idx = text.index("\r\n\r\n")
        {text[0, idx], text[idx + 4..], "\r\n\r\n"}
      elsif idx = text.index("\n\n")
        {text[0, idx], text[idx + 2..], "\n\n"}
      else
        {text, "", ""}
      end
    end

    # Apply every enabled rule for {target, part} that also matches `host` over the bytes.
    # Returns the SAME bytes when nothing is configured or nothing is in scope (byte-
    # fidelity, P7). A no-op replace re-serializes to an equal slice (as it always has for
    # heads) — ClientConn's body path compares content, so an unchanged body still frames
    # byte-exact.
    private def apply(bytes : Bytes, target : Store::RuleTarget, part : Store::RulePart,
                      count : Atomic(Int32), host : String, report : Bool = true) : Bytes
      return bytes if count.get == 0 # lock-free fast path: no rules to apply
      active = @mutex.synchronize do
        @rules.select do |r|
          r.enabled? && r.op.rewrite? && r.target == target && r.part == part && !r.pattern.empty? &&
            !(part.body? && r.op.header?) && host_matches?(r.host, host)
        end
      end
      return bytes if active.empty? # nothing in scope → same bytes, byte-fidelity preserved
      text = String.new(bytes)
      active.each { |r| text = apply_rule(text, r, report) }
      text.to_slice
    end

    # Apply ONE rule to `text` (a head or a body already decoded to a String). Returns a
    # new String, or the same content when the rule doesn't touch it. A bad regex or a
    # regex over non-UTF-8 bytes is swallowed → the text passes through unchanged.
    private def apply_rule(text : String, rule : Store::MatchRule, report : Bool = true) : String
      # A rule naming a binding that has no value is NOT applied. Nothing else is a safe
      # answer: injecting `""` sends a request with an empty session header, and injecting
      # the literal `$SESSION` — which is what `Env.expand` does with an unknown key
      # (env.cr) — puts eight meaningless characters on the wire in a credential's place.
      # The operator hears about it through the event feed rather than through a 401.
      repl = replacement_for(rule)
      unless repl
        report_unbound(rule) if report
        return text
      end
      case rule.op
      in Store::RuleOp::Replace
        if rule.match_kind.regex?
          begin
            text.gsub(SafeRegexp.compile(rule.pattern), repl)
          rescue
            text
          end
        else
          text.gsub(rule.pattern, repl)
        end
      in Store::RuleOp::AddHeader    then head_add_header(text, rule.pattern, repl)
      in Store::RuleOp::SetHeader    then head_set_header(text, rule.pattern, repl)
      in Store::RuleOp::RemoveHeader then head_remove_header(text, rule.pattern)
      in Store::RuleOp::ShortCircuit then text # answers, never rewrites — `apply` filters it out
      end
    end

    # The replacement string this rule should actually apply, or nil when it names a
    # DECLARED binding that has no value yet (see `apply_rule`).
    #
    # This is the whole injection half of #501: `Store::MatchRule#replacement` is a literal
    # string in the database and becomes a resolved one here, at apply time. That single
    # change buys header injection (`SetHeader`/`AddHeader` with replacement `$SESSION`),
    # body injection (`Replace` with `part: Body`), static env vars in M&R rules — which
    # simply did not work before — and one syntax everywhere, with no schema change and no
    # new rule kind.
    private def replacement_for(rule : Store::MatchRule) : String?
      repl = rule.replacement
      prefix = Settings.env_prefix
      # The overwhelmingly common case, and the one that must cost nothing: no `$` in the
      # replacement means the identical String comes back, exactly as before this feature.
      return repl if prefix.empty? || !repl.byte_index(prefix)
      vars, declared = subst_snapshot
      substitute(repl, prefix, vars, declared, rule.op.replace? && rule.match_kind.regex?)
    end

    # ONE left-to-right pass that resolves `$NAME`, translates the Caido-style `$1` capture
    # ref to Crystal's `\1`, and unescapes `$$` → `$`. One pass and not three, because the
    # order between them is the whole safety argument:
    #
    #   * `$1` cannot collide with a binding name — `Env::KEY_HEAD` is `[A-Za-z_]`, so a
    #     digit never starts a key — but a substituted VALUE containing `$1` would be read
    #     as a capture ref if this ran `regex_replacement` afterwards over the result. It
    #     does not: a value is emitted and never re-scanned.
    #   * `$$` resolves LAST in meaning: `$$SESSION` is the literal text `$SESSION`, not the
    #     bound value. That is the only way an operator can write a literal `$NAME` at all.
    #     (New for the literal-replace and header ops, which previously had no escape
    #     because they had nothing to escape from.)
    #   * A binding value is **server-controlled**, and for `MatchKind::Regex` the
    #     replacement is interpreted by `gsub`: Crystal reads `\1`, `\0` and `\k<name>` in a
    #     replacement string, so a token containing `\1` would splice a capture group into
    #     the wire bytes and one containing `\k<x>` raises. `escape_backrefs` doubles every
    #     backslash in a substituted value before it lands there. `$` needs no escaping —
    #     Crystal's replacement grammar does not read it — and the literal-replace and the
    #     three header ops interpret nothing at all, so they take the value verbatim.
    #
    # Byte-level for the same reason `Env.expand` is: a BODY replacement can carry bytes
    # that are not valid UTF-8, and `String#chars` would turn each of them into U+FFFD.
    private def substitute(repl : String, prefix : String, vars : Hash(String, String),
                           declared : Array(String), regex : Bool) : String?
      bytes = repl.to_slice
      prefix_bytes = prefix.to_slice
      n = bytes.size
      plen = prefix_bytes.size
      buf = IO::Memory.new(n)
      i = 0
      while i < n
        unless prefix_at?(bytes, prefix_bytes, i)
          buf.write_byte(bytes[i])
          i += 1
          next
        end
        # `$$` → one literal prefix, consuming both.
        if prefix_at?(bytes, prefix_bytes, i + plen)
          buf << prefix
          i += 2 * plen
          next
        end
        if parsed = Env.read_key_bytes?(bytes, i + plen, n)
          key, consumed = parsed
          # Declared by an extract rule but not bound yet → the rule must not apply.
          return nil if !vars.has_key?(key) && declared.includes?(key)
          i += emit_key(buf, bytes, vars, key, consumed, prefix, plen, regex)
          next
        end
        # `$1`..`$9` → `\1`..`\9`, regex replacements only (unchanged from `regex_replacement`).
        if regex && i + plen < n && bytes[i + plen].chr.ascii_number?
          buf << '\\'
          buf.write_byte(bytes[i + plen])
          i += plen + 1
          next
        end
        buf << prefix
        i += plen
      end
      String.new(buf.to_slice)
    end

    private def prefix_at?(bytes : Bytes, prefix_bytes : Bytes, at : Int32) : Bool
      return false if at + prefix_bytes.size > bytes.size
      prefix_bytes.each_with_index.all? { |b, j| bytes[at + j] == b }
    end

    # Write one resolved (or literal) `prefix+KEY` and answer how many bytes it consumed.
    # A key that is neither a var nor a declared binding stays LITERAL — `Env.expand`'s
    # documented contract, and the meaning every pre-existing rule already had. Refusing
    # here instead would be a one-way door on a persisted, operator-authored table.
    private def emit_key(buf : IO::Memory, bytes : Bytes, vars : Hash(String, String),
                         key : String, consumed : Int32, prefix : String,
                         plen : Int32, regex : Bool) : Int32
      if val = vars[key]?
        buf << (regex ? Rules.escape_backrefs(val) : val)
        plen + consumed
      else
        buf << prefix
        plen
      end
    end

    # Double every backslash so a substituted value cannot be read as a capture reference
    # by `String#gsub(Regex, String)`. `gsub(String, String)` interprets nothing, so this is
    # applied to the regex path alone.
    def self.escape_backrefs(value : String) : String
      value.includes?('\\') ? value.gsub("\\", "\\\\") : value
    end

    # Env vars + currently-bound bindings, plus the declared-name list, cached until either
    # moves. `Env.expand`'s default argument rebuilds a merged Hash on EVERY call
    # (`env.cr`, and `highlight.cr` already carries a comment warning about it) — and this
    # runs on the proxy path per message per matching rule, so calling `display_vars` here
    # would be a per-message allocation. `Env.bump_highlight_rev` fires on a settings load,
    # a project env write, a rule edit and every rebind, which is exactly the set of events
    # that can move either half.
    private def subst_snapshot : {Hash(String, String), Array(String)}
      erev = Env.highlight_rev
      brev = Env.binding_rev
      cached = @subst_vars
      if cached.nil? || erev != @subst_env_rev || brev != @subst_binding_rev
        cached = Env.display_vars
        @subst_vars = cached
        @subst_declared = Env.declared_bindings
        @subst_env_rev = erev
        @subst_binding_rev = brev
      end
      {cached, @subst_declared}
    end

    # One warn event per (rule, binding revision): a rule injecting an unbound `$SESSION`
    # into every proxied request would otherwise write one row per message. The value is
    # never in the message — only the rule and the name, which is what #491 asked for.
    private def report_unbound(rule : Store::MatchRule) : Nil
      brev = Env.binding_rev
      if brev != @unbound_reported_rev
        @unbound_reported_rev = brev
        @unbound_reported.clear
      end
      return unless @unbound_reported.add?(rule.id)
      names = Env.unbound(rule.replacement)
      return if names.empty?
      label = rule.name.presence || rule.pattern
      @store.insert_event("bindings", "unbound", "warn",
        "rewrite rule #{label.inspect} not applied: #{Env.token_list(names)} is not bound yet")
    end

    # The line terminator a head uses — CRLF for real HTTP, LF as a fallback so a
    # hand-authored / test head still round-trips.
    private def eol_of(text : String) : String
      text.includes?("\r\n") ? "\r\n" : "\n"
    end

    # Append `Name: value` as the LAST header, just before the terminating blank line
    # (preserving the head's own EOL). If the head has no blank-line terminator, append.
    private def head_add_header(head : String, name : String, value : String) : String
      eol = eol_of(head)
      line = "#{name}: #{value}"
      term = eol + eol
      if idx = head.rindex(term)
        "#{head[0, idx]}#{eol}#{line}#{head[idx..]}"
      elsif head.ends_with?(eol)
        "#{head}#{line}#{eol}"
      else
        "#{head}#{eol}#{line}"
      end
    end

    # Replace the value of every header named `name` (case-insensitive, original casing
    # kept); if none exists, append it (upsert). The start line and blank line are left
    # untouched.
    private def head_set_header(head : String, name : String, value : String) : String
      eol = eol_of(head)
      target = name.downcase
      found = false
      out = head.split(eol).map_with_index do |ln, i|
        next ln if i == 0 || ln.empty?
        if (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          found = true
          "#{ln[0, ci]}: #{value}"
        else
          ln
        end
      end
      found ? out.join(eol) : head_add_header(head, name, value)
    end

    # Drop every header line named `name` (case-insensitive). The start line (index 0)
    # and any blank lines are always kept, so the head stays well-formed.
    private def head_remove_header(head : String, name : String) : String
      eol = eol_of(head)
      target = name.downcase
      kept = [] of String
      head.split(eol).each_with_index do |ln, i|
        if i == 0 || ln.empty?
          kept << ln
        elsif (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          # drop this header
        else
          kept << ln
        end
      end
      kept.join(eol)
    end

    private def host_matches?(glob : String, host : String) : Bool
      Rules.host_matches?(glob, host)
    end

    # Does `host` satisfy a rule's host glob? Empty = all hosts. A glob with `*` is an
    # anchored wildcard (`*.example.com`); without `*` it is a case-insensitive substring
    # (`example.com` matches `api.example.com`).
    #
    # Exposed on the class because an extract rule (#501) carries the same host glob and
    # must mean the same thing by it — an operator who learned the dialect in the Rewriter's
    # `rules` sub-tab types it again two sub-tabs over. NOT `HostPattern`, which is Scope's
    # separate suffix-matching dialect.
    def self.host_matches?(glob : String, host : String) : Bool
      return true if glob.empty?
      h = host.downcase
      g = glob.downcase
      if g.includes?('*')
        # Compile the glob→regex ONCE per distinct glob, not per proxied head. host_matches?
        # runs on the hot path for EVERY request/response head while any head rule is active
        # (including messages the rule doesn't target — the scope test is what decides that),
        # so an uncached Regex.new here was a PCRE2 compile per message. SafeRegexp memoises.
        rx = "^#{Regex.escape(g).gsub("\\*", ".*")}$"
        begin
          SafeRegexp.compile(rx).matches?(h)
        rescue
          false
        end
      else
        h.includes?(g)
      end
    end

    # --- preview (shared by the Rewriter tab's test row + the MCP preview_rule tool) ---

    RULE_PREVIEW_SCAN = 500

    # Cap the body bytes pulled per flow for a BODY rule preview: this runs on the
    # interactive keystroke path, so never fetch multi-MiB bodies. Head/header rules read
    # no body at all (body_max: 0). A body match past the cap is missed — acceptable since
    # the preview is already documented as approximate.
    RULE_PREVIEW_BODY_MAX = 64 * 1024

    record Preview, scanned : Int32, matched : Int32, total : Int64

    # How many of up to `limit` recent stored flows a candidate rule WOULD affect, by
    # replaying the SAME transform the live proxy uses (so regex / header ops / host-scope
    # are all reflected). Nothing is written. Approximate: bodies are scanned as STORED
    # (possibly compressed) wire bytes, so a text pattern mainly reflects head/text hits.
    def preview(rule : Store::MatchRule, limit : Int32 = RULE_PREVIEW_SCAN) : Preview
      scanned = 0
      matched = 0
      # Head/header rules never touch the body, so fetch head-only; body rules cap the
      # fetched bytes. Without this the preview pulled every flow's FULL request+response
      # body into memory per keystroke, stalling proportionally to stored body size.
      body_max = rule.part.body? ? RULE_PREVIEW_BODY_MAX : 0
      @store.recent_flows(limit, nil).each do |row|
        detail = @store.get_flow(row.id, body_max: body_max)
        next unless detail
        scanned += 1
        matched += 1 if rule_affects?(rule, detail)
      end
      Preview.new(scanned, matched, @store.count)
    end

    # Whether applying `rule` to the relevant part of `detail` would change its bytes — or,
    # for a short-circuit rule, whether it would have ANSWERED that flow instead of letting
    # it reach the origin. Same question the preview line asks of every other op ("how many
    # of your recent flows does this touch"), and the more useful one for a stub: it tells
    # the operator what they are about to stop sending.
    private def rule_affects?(rule : Store::MatchRule, detail : Store::FlowDetail) : Bool
      return false unless host_matches?(rule.host, detail.row.host)
      return stub_matches?(rule, String.new(detail.request_head)) if rule.op.short_circuit?
      return false if rule.part.body? && rule.op.header?
      bytes = flow_part_bytes(detail, rule)
      return false unless bytes
      apply_rule(String.new(bytes), rule, report: false).to_slice != bytes
    end

    private def flow_part_bytes(detail : Store::FlowDetail, rule : Store::MatchRule) : Bytes?
      if rule.target.request?
        rule.part.head? ? detail.request_head : detail.request_body
      else
        rule.part.head? ? detail.response_head : detail.response_body
      end
    end

    private def refresh : Nil
      fresh = @store.match_rules
      @mutex.synchronize { @rules = fresh }
      @req_head_count.set(active_count(fresh, Store::RuleTarget::Request, part: Store::RulePart::Head))
      @resp_head_count.set(active_count(fresh, Store::RuleTarget::Response, part: Store::RulePart::Head))
      @req_body_count.set(active_count(fresh, Store::RuleTarget::Request, part: Store::RulePart::Body))
      @resp_body_count.set(active_count(fresh, Store::RuleTarget::Response, part: Store::RulePart::Body))
      @short_circuit_count.set(stub_count(fresh))
      # An edit may have repointed a rule at a different file; the cache is keyed by path and
      # revalidated per read, so this only drops entries no rule refers to any more.
      @stub_bodies.clear
    end
  end
end
