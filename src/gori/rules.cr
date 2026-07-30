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
    def transform_message(text : String, target : Store::RuleTarget, host : String = "") : String
      head, body, sep = split_message(text)
      new_head = String.new(apply(head.to_slice, target, Store::RulePart::Head,
        target.request? ? @req_head_count : @resp_head_count, host))
      new_body = String.new(apply(body.to_slice, target, Store::RulePart::Body,
        target.request? ? @req_body_count : @resp_body_count, host))
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
                      count : Atomic(Int32), host : String) : Bytes
      return bytes if count.get == 0 # lock-free fast path: no rules to apply
      active = @mutex.synchronize do
        @rules.select do |r|
          r.enabled? && r.op.rewrite? && r.target == target && r.part == part && !r.pattern.empty? &&
            !(part.body? && r.op.header?) && host_matches?(r.host, host)
        end
      end
      return bytes if active.empty? # nothing in scope → same bytes, byte-fidelity preserved
      text = String.new(bytes)
      active.each { |r| text = apply_rule(text, r) }
      text.to_slice
    end

    # Apply ONE rule to `text` (a head or a body already decoded to a String). Returns a
    # new String, or the same content when the rule doesn't touch it. A bad regex or a
    # regex over non-UTF-8 bytes is swallowed → the text passes through unchanged.
    private def apply_rule(text : String, rule : Store::MatchRule) : String
      case rule.op
      in Store::RuleOp::Replace
        if rule.match_kind.regex?
          begin
            text.gsub(SafeRegexp.compile(rule.pattern), regex_replacement(rule.replacement))
          rescue
            text
          end
        else
          text.gsub(rule.pattern, rule.replacement)
        end
      in Store::RuleOp::AddHeader    then head_add_header(text, rule.pattern, rule.replacement)
      in Store::RuleOp::SetHeader    then head_set_header(text, rule.pattern, rule.replacement)
      in Store::RuleOp::RemoveHeader then head_remove_header(text, rule.pattern)
      in Store::RuleOp::ShortCircuit then text # answers, never rewrites — `apply` filters it out
      end
    end

    # Translate Caido-style `$1` capture refs to Crystal's `\1`, and `$$` to a literal
    # `$`. Existing backslash refs (`\1`, `\k<name>`) pass through untouched.
    private def regex_replacement(repl : String) : String
      return repl unless repl.includes?('$')
      String.build do |io|
        i = 0
        while i < repl.size
          c = repl[i]
          if c == '$' && i + 1 < repl.size
            nxt = repl[i + 1]
            if nxt == '$'
              io << '$'; i += 2; next
            elsif nxt.ascii_number?
              io << '\\' << nxt; i += 2; next
            end
          end
          io << c
          i += 1
        end
      end
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

    # Does `host` satisfy a rule's host glob? Empty = all hosts. A glob with `*` is an
    # anchored wildcard (`*.example.com`); without `*` it is a case-insensitive substring
    # (`example.com` matches `api.example.com`).
    private def host_matches?(glob : String, host : String) : Bool
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
      apply_rule(String.new(bytes), rule).to_slice != bytes
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
