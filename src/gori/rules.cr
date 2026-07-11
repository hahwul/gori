require "./proxy/head_rewriter"
require "./store"

module Gori
  # The Match&Replace lens (DESIGN.md §3, "Rules"): literal substring rewrites
  # applied to request/response HEAD bytes in flight (request line + headers;
  # bodies stream untouched, P6). Human-configured (P4), persisted per project.
  #
  # One instance is SHARED between the proxy fibers (which call `rewrite_*` on
  # every message) and the TUI (which edits the rule set). A Mutex guards the
  # rule snapshot so an edit can never tear a concurrent rewrite.
  class Rules < Proxy::HeadRewriter
    def initialize(@store : Store, @rules : Array(Store::MatchRule))
      @mutex = Mutex.new
      # Lock-free fast-path flags: rewrite_* run on EVERY message, but the common case
      # is no rule for that side/part. These let the hot path skip the mutex + select-
      # array allocation entirely when nothing would match. `@head_count` gates the head
      # rewrite; the two body counts also gate whether ClientConn buffers a body at all.
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

    def add(target : Store::RuleTarget, part : Store::RulePart, pattern : String, replacement : String) : Nil
      return if pattern.empty?
      @store.insert_rule(target, part, pattern, replacement)
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

    # --- HeadRewriter (called from proxy fibers) -----------------------------

    def rewrite_request(head : Bytes) : Bytes
      apply(head, Store::RuleTarget::Request, Store::RulePart::Head, @head_count)
    end

    def rewrite_response(head : Bytes) : Bytes
      apply(head, Store::RuleTarget::Response, Store::RulePart::Head, @head_count)
    end

    # A body rule is live iff at least one enabled, non-empty rule targets that side's
    # body — ClientConn keys the (expensive) body buffer on these.
    def rewrites_request_body? : Bool
      @req_body_count.get > 0
    end

    def rewrites_response_body? : Bool
      @resp_body_count.get > 0
    end

    def rewrite_request_body(entity : Bytes) : Bytes
      apply(entity, Store::RuleTarget::Request, Store::RulePart::Body, @req_body_count)
    end

    def rewrite_response_body(entity : Bytes) : Bytes
      apply(entity, Store::RuleTarget::Response, Store::RulePart::Body, @resp_body_count)
    end

    # gsub every enabled rule for {target, part} over the bytes. Returns the SAME
    # bytes when nothing is configured or nothing matches (byte-fidelity, P7).
    private def apply(bytes : Bytes, target : Store::RuleTarget, part : Store::RulePart,
                      count : Atomic(Int32)) : Bytes
      return bytes if count.get == 0 # lock-free fast path: no rules to apply
      # An empty pattern is excluded here too (not just at add-time): String#gsub
      # with "" would splice the replacement between every byte and wreck the bytes.
      active = @mutex.synchronize do
        @rules.select { |r| r.enabled? && r.target == target && r.part == part && !r.pattern.empty? }
      end
      return bytes if active.empty? # unchanged → same bytes, byte-fidelity preserved
      text = String.new(bytes)
      active.each { |r| text = text.gsub(r.pattern, r.replacement) }
      text.to_slice
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
