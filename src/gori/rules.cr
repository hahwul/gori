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
      # Lock-free fast-path flag: rewrite_request/response run on EVERY head, but
      # the common case is no rules. This lets apply() skip the mutex + select-array
      # allocation entirely when nothing would match.
      @active_count = Atomic(Int32).new(active_rule_count(@rules))
    end

    private def active_rule_count(rules : Array(Store::MatchRule)) : Int32
      rules.count { |r| r.enabled? && !r.pattern.empty? }
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

    def add(target : Store::RuleTarget, pattern : String, replacement : String) : Nil
      return if pattern.empty?
      @store.insert_rule(target, pattern, replacement)
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
      apply(head, Store::RuleTarget::Request)
    end

    def rewrite_response(head : Bytes) : Bytes
      apply(head, Store::RuleTarget::Response)
    end

    private def apply(head : Bytes, target : Store::RuleTarget) : Bytes
      return head if @active_count.get == 0 # lock-free fast path: no rules to apply
      # An empty pattern is excluded here too (not just at add-time): String#gsub
      # with "" would splice the replacement between every byte and wreck the head.
      active = @mutex.synchronize do
        @rules.select { |r| r.enabled? && r.target == target && !r.pattern.empty? }
      end
      return head if active.empty? # unchanged → same bytes, byte-fidelity preserved
      text = String.new(head)
      active.each { |r| text = text.gsub(r.pattern, r.replacement) }
      text.to_slice
    end

    private def refresh : Nil
      fresh = @store.match_rules
      @mutex.synchronize { @rules = fresh }
      @active_count.set(active_rule_count(fresh))
    end
  end
end
