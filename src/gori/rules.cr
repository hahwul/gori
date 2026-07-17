require "./proxy/head_rewriter"
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
      # Lock-free fast-path flags: rewrite_* run on EVERY message, but the common case
      # is no rule for that side/part. These let the hot path skip the mutex + select-
      # array allocation entirely when nothing would match. `@head_count` gates the head
      # rewrite (replace-head AND the header ops, which all act on the head); the two body
      # counts also gate whether ClientConn buffers a body at all.
      @head_count = Atomic(Int32).new(active_count(@rules, part: Store::RulePart::Head))
      @req_body_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Request, part: Store::RulePart::Body))
      @resp_body_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Response, part: Store::RulePart::Body))
    end

    # Count enabled, non-empty-pattern rules matching an optional target + a part.
    private def active_count(rules : Array(Store::MatchRule), target : Store::RuleTarget? = nil,
                             *, part : Store::RulePart) : Int32
      rules.count do |r|
        r.enabled? && !r.pattern.empty? && r.part == part && (target.nil? || r.target == target)
      end
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
            name : String = "", host : String = "") : Nil
      return if pattern.empty?
      part = Store::RulePart::Head if op.header? # header ops are head-only
      @store.insert_rule(target, part, pattern, replacement, op, match_kind, name, host)
      refresh
    end

    def update(id : Int64, target : Store::RuleTarget, part : Store::RulePart, pattern : String, replacement : String,
               op : Store::RuleOp = Store::RuleOp::Replace, match_kind : Store::MatchKind = Store::MatchKind::Literal,
               name : String = "", host : String = "") : Nil
      return if pattern.empty?
      part = Store::RulePart::Head if op.header?
      @store.update_rule(id, target, part, pattern, replacement, op, match_kind, name, host)
      refresh
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
      apply(head, Store::RuleTarget::Request, Store::RulePart::Head, @head_count, host)
    end

    def rewrite_response(head : Bytes, host : String) : Bytes
      apply(head, Store::RuleTarget::Response, Store::RulePart::Head, @head_count, host)
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
          r.enabled? && r.target == target && r.part == part && !r.pattern.empty? &&
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

    # Whether applying `rule` to the relevant part of `detail` would change its bytes.
    private def rule_affects?(rule : Store::MatchRule, detail : Store::FlowDetail) : Bool
      return false unless host_matches?(rule.host, detail.row.host)
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
      @head_count.set(active_count(fresh, part: Store::RulePart::Head))
      @req_body_count.set(active_count(fresh, Store::RuleTarget::Request, part: Store::RulePart::Body))
      @resp_body_count.set(active_count(fresh, Store::RuleTarget::Response, part: Store::RulePart::Body))
    end
  end
end
