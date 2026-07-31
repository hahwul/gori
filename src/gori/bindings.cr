require "./env"
require "./intercept_filter"
require "./store"
require "./token_extract"
require "./repeater/engine"

module Gori
  # Session bindings (#501): named values observed from a response and resolved into
  # outgoing requests at SEND time.
  #
  #   extraction observes, injection rewrites, and a binding is the only thing between
  #   them. Injection is not a new rule kind — it is the existing rewrite with its
  #   replacement resolved late.
  #
  # So this class owns exactly two things: the persisted `extract_rules` (the READ half)
  # and an IN-MEMORY name→value table (the binding itself). The WRITE half is an ordinary
  # `Store::MatchRule` whose `replacement` says `$NAME`, plus the four send seams that
  # resolve `$NAME` on their way to the socket.
  #
  # **The rule persists; the value never does.** Not in `settings.json`, and — unlike
  # `oast_sessions` — not in the project DB either. Two reasons, and the second is the
  # real one: a restored token is stale by construction (minutes to days old on reopen)
  # and injecting it produces exactly the 401s this feature exists to remove; and
  # re-extracting costs one request, so there is nothing to save.
  #
  # The guarantee is BOUNDED and stated as such: a binding value never appears in
  # `settings.json`, the project DB, the event feed, an issue, a note, or a log line. It
  # DOES appear in captured traffic, because that is where it came from — masking a
  # capture would be a P7 violation, not a fix.
  #
  # One instance is SHARED between the TUI (which edits rules and reads the table), the
  # Repeater send path (which writes it) and every send seam (which reads it), so a Mutex
  # guards both the rule snapshot and the value table. Same contract as `Rules`.
  class Bindings < Env::Layer
    # What one name looks like to a readout. `value` is the raw bound value and is only
    # ever handed to a surface that masks it (`preview`) or to an explicit one-row reveal;
    # nothing here goes near a log line or an event message.
    record Row,
      name : String,
      rule_id : Int64,
      host : String,
      descriptor : String,
      enabled : Bool,
      value : String?,
      bound_at : Time? do
      def bound? : Bool
        !value.nil?
      end

      # First 4 / last 4 with the length in between — enough to tell two tokens apart and
      # to confirm a rebind happened, without printing a credential. `env_value_preview`
      # truncating to 20 characters showed the first 19, which is fine for `$HOST` and
      # wrong for a session cookie; this is the shape that is right for both.
      def preview : String
        v = value
        return "—" unless v
        Bindings.mask_preview(v)
      end
    end

    # A rule with everything it needs precompiled. The `InterceptFilter` compiles its
    # `FilterAst` tree once (it is the same backend the conditional-intercept bar uses on
    # the proxy path), and a Regex-kind descriptor compiles its pattern once — the same
    # thing `Sequencer::Engine#run_live` does per run, for the same reason.
    private record Compiled,
      rule : Store::ExtractRule,
      filter : InterceptFilter,
      re : Regex?

    # A name's live value plus where it came from. `rule_id` is what lets the readout say
    # WHICH rule wrote a name after the operator has edited several.
    private record Bound, value : String, rule_id : Int64, at : Time

    @rules : Array(Store::ExtractRule)
    @compiled : Array(Compiled)
    @values : Hash(String, Bound)

    def initialize(@store : Store, rules : Array(Store::ExtractRule))
      @mutex = Mutex.new
      @rules = rules
      @compiled = compile(rules)
      @values = {} of String => Bound
      @rev = 0_u64
    end

    def self.load(store : Store) : Bindings
      new(store, store.extract_rules)
    end

    # ── Env::Layer ────────────────────────────────────────────────────────────

    # Names declared by an ENABLED rule. A disabled rule declares nothing: its name goes
    # back to being an ordinary unknown key, which plan-build then refuses by #525's rule.
    # That is deliberate — disabling the writer must not leave the reader silently
    # injecting a stale value, and it must not leave `$SESSION` sailing out literally
    # either.
    def declared : Array(String)
      @mutex.synchronize { @compiled.select(&.rule.enabled?).map(&.rule.name) }
    end

    def values : Hash(String, String)
      @mutex.synchronize do
        h = {} of String => String
        @values.each { |(k, b)| h[k] = b.value }
        h
      end
    end

    # Bumped on every rule edit and every rebind. Consumers that must not rebuild a merged
    # snapshot per message (`Rules`, on the proxy hot path) cache on this plus
    # `Env.highlight_rev`.
    def rev : UInt64
      @rev
    end

    # ── rule editing (persists, then refreshes the snapshot) ──────────────────

    def rules : Array(Store::ExtractRule)
      @mutex.synchronize { @rules.dup }
    end

    def enabled_count : Int32
      @mutex.synchronize { @rules.count(&.enabled?) }
    end

    # Why this rule may not be saved, or nil to proceed. Refused at SAVE time and named,
    # the way `upstream_rule_error` refuses — a precedence rule would have been the wrong
    # answer, because "bind from the login response OR the refresh response" is ONE rule
    # with `path:/login OR path:/refresh`, not two rules racing for a name.
    #
    # `except_id` excludes the row being edited from the duplicate-name test.
    def validate(name : String, kind : Gori::ExtractKind, selector : String,
                 except_id : Int64? = nil) : String?
      return "a binding needs a name" if name.empty?
      unless Env.valid_key?(name)
        return "#{name.inspect} is not a valid binding name (letters, digits and _ only, not starting with a digit)"
      end
      if @mutex.synchronize { @rules.any? { |r| r.name == name && r.id != except_id } }
        return "$#{name} is already written by another extract rule — one name, one writer"
      end
      return "a #{kind.label} descriptor needs a selector" if kind_needs_selector?(kind) && selector.empty?
      if kind.regex?
        begin
          Regex.new(selector)
        rescue ex : ArgumentError | Regex::Error
          return "regex #{selector.inspect} does not compile: #{ex.message}"
        end
      end
      nil
    end

    private def kind_needs_selector?(kind : Gori::ExtractKind) : Bool
      !kind.position?
    end

    # Add a rule. Returns nil on success, or the refusal message.
    def add(name : String, match_filter : String, kind : Gori::ExtractKind,
            selector : String = "", pos_start : Int32 = 0, pos_end : Int32 = 0,
            host : String = "") : String?
      if err = validate(name, kind, selector)
        return err
      end
      @store.insert_extract_rule(name, match_filter, kind, selector, pos_start, pos_end, host)
      refresh
      nil
    end

    def update(id : Int64, name : String, match_filter : String, kind : Gori::ExtractKind,
               selector : String = "", pos_start : Int32 = 0, pos_end : Int32 = 0,
               host : String = "") : String?
      if err = validate(name, kind, selector, except_id: id)
        return err
      end
      previous = @mutex.synchronize { @rules.find(&.id.==(id)) }
      @store.update_extract_rule(id, name, match_filter, kind, selector, pos_start, pos_end, host)
      # A RENAME drops the old name's value rather than carrying it over: the value was
      # observed under the old descriptor, and silently re-labelling it is how a binding
      # would come to disagree with the rule that claims to own it.
      if previous && previous.name != name
        @mutex.synchronize { @values.delete(previous.name) }
      end
      refresh
      nil
    end

    def remove(id : Int64) : Nil
      gone = @mutex.synchronize { @rules.find(&.id.==(id)) }
      @store.delete_extract_rule(id)
      @mutex.synchronize { @values.delete(gone.name) } if gone
      refresh
    end

    def toggle(id : Int64) : Nil
      rule = @mutex.synchronize { @rules.find(&.id.==(id)) }
      return unless rule
      @store.set_extract_rule_enabled(id, !rule.enabled?)
      refresh
    end

    # Re-read the store snapshot (an MCP / other-instance edit). Same work `refresh` does,
    # exposed so the Rewriter tab can pull external changes on enter, exactly as `Rules#reload`.
    def reload : Nil
      refresh
    end

    # ── the binding table ─────────────────────────────────────────────────────

    def rows : Array(Row)
      @mutex.synchronize do
        @rules.map do |r|
          b = @values[r.name]?
          Row.new(r.name, r.id, r.host, r.token_loc.label, r.enabled?, b.try(&.value), b.try(&.at))
        end
      end
    end

    def bound?(name : String) : Bool
      @mutex.synchronize { @values.has_key?(name) }
    end

    # Forget one name (the `bindings` sub-tab's clear action). The RULE is untouched — a
    # cleared name is declared-but-unbound, so the next send naming it refuses rather than
    # going out with a stale value.
    def clear(name : String) : Nil
      @mutex.synchronize do
        @values.delete(name)
        @rev &+= 1
      end
      Env.bump_highlight_rev
    end

    def clear_all : Nil
      @mutex.synchronize do
        @values.clear
        @rev &+= 1
      end
      Env.bump_highlight_rev
    end

    # ── extraction ────────────────────────────────────────────────────────────

    # Run every enabled rule whose host glob and condition match this response, and rebind
    # the names that hit. Returns the names rebound (for a status line), never the values.
    #
    # **Only a deliberate single send reaches here.** `Repeater::Sender` documents itself as
    # "a single HAND-AUTHORED send"; `Fuzz::Sender` — the sweep sender for Fuzzer, Miner,
    # Sequencer, Repeater minimize and Probe active — deliberately does not call this. That
    # is a security line, not a scope trim: a sweep sends attacker-shaped payloads, and a
    # response that echoes one back could rebind the operator's session to a payload-derived
    # value which is then injected into every subsequent request. The line between the two
    # is one this codebase had already drawn, at `Repeater::Sender` vs `Fuzz::Sender`.
    #
    # A MISS never clears a binding. The previous value stands and the miss is recorded to
    # the `events` feed at warn level, carrying the rule name and the reason and NEVER the
    # value — `Sequencer::Extract`'s "nil on a miss rather than raising" contract was
    # already right; what was missing is that anybody heard about it.
    def observe(raw : Repeater::Result, subject : InterceptFilter::Subject,
                flow_id : Int64? = nil) : Array(String)
      return [] of String if raw.error
      candidates = @mutex.synchronize do
        @compiled.select do |c|
          c.rule.enabled? && Rules.host_matches?(c.rule.host, subject.host) && c.filter.matches?(subject)
        end
      end
      return [] of String if candidates.empty?

      bound = [] of String
      now = Time.utc
      candidates.each do |c|
        value = Gori::TokenExtract.extract(raw, c.rule.token_loc, c.re)
        if value.nil? || value.empty?
          miss(c.rule, value.nil? ? "no match" : "matched an empty value", flow_id)
          next
        end
        @mutex.synchronize { @values[c.rule.name] = Bound.new(value, c.rule.id, now) }
        bound << c.rule.name
      end
      unless bound.empty?
        @mutex.synchronize { @rev &+= 1 }
        # Repaint every `$KEY` token in every open editor: an unbound name paints like an
        # unknown key and a bound one like a set var, and that difference is the operator's
        # only pre-send signal.
        Env.bump_highlight_rev
      end
      bound
    end

    private def miss(rule : Store::ExtractRule, reason : String, flow_id : Int64?) : Nil
      @store.insert_event("bindings", "extract_miss", "warn",
        "$#{rule.name}: #{rule.token_loc.label} found nothing (#{reason})", flow_id: flow_id)
    end

    # ── helpers ───────────────────────────────────────────────────────────────

    # First 4 / last 4 with the length between them. Short values are masked whole rather
    # than half-revealed — a 6-character value showing 4 of its characters is not masked.
    def self.mask_preview(value : String) : String
      return "•" * value.size if value.size <= 12
      "#{value[0, 4]}…#{value.size}…#{value[-4, 4]}"
    end

    private def compile(rules : Array(Store::ExtractRule)) : Array(Compiled)
      rules.map do |r|
        re =
          if r.kind.regex? && !r.selector.empty?
            begin
              Regex.new(r.selector)
            rescue ArgumentError | Regex::Error
              nil
            end
          end
        Compiled.new(r, InterceptFilter.new(r.match_filter), re)
      end
    end

    private def refresh : Nil
      fresh = @store.extract_rules
      compiled = compile(fresh)
      @mutex.synchronize do
        @rules = fresh
        @compiled = compiled
        # Drop values whose rule is gone. Not values whose rule is merely DISABLED: an
        # operator toggling a rule off and back on has not asked to lose the token.
        names = fresh.map(&.name)
        @values.reject! { |k, _| !names.includes?(k) }
        @rev &+= 1
      end
      # A rule edit changes which names are DECLARED, and `token_regions` paints on that.
      Env.bump_highlight_rev
    end
  end
end
