require "./probe/mode"
require "./rule_set_change"
require "./store"

module Gori
  # What a PEER changed under a running session, turned into the line the operator reads (#772).
  #
  # A peer is another process on the same project db — an MCP agent, `gori run …`, a second TUI.
  # Since #771 a peer's write reaches this session's LIVE objects, so it can change what this
  # session puts on the wire; the operator was never told. This is the policy for which of those
  # changes is worth interrupting them over, and in what words.
  #
  # Deliberately OUTSIDE `Gori::Tui`, and deliberately not holding a `Notifications`: the headless
  # `gori run capture` adopts exactly the same peer writes on its own reload loop and owes the
  # operator the same sentence through `Log`. The one existing cross-surface warning (the CA trust
  # store) is hand-written twice — once for the ring at `app.cr` and once for STDERR — and the two
  # can drift apart. One builder, two emitters, no drift.
  #
  # Pure and clock-injected (`now` is a parameter, never `Time.instant` read in here) so the whole
  # policy is testable without a `Runner`, which no spec can construct.
  class PeerNotices
    # One line to emit. `tab` is where the notification's jump affordance should land, or nil for
    # a surface with nowhere useful to go; the TUI maps it to a `Jobs::Goto`, headless drops it.
    record Notice, level : Symbol, message : String, tab : Symbol?, by_agent : Bool = false do
      # How the notification ring should label the note. `agent` is what makes it render with the
      # AI marker, which is the whole point of asking who wrote it.
      def source : String
        by_agent ? "agent" : "app"
      end
    end

    # The MCP tools whose success means an agent moved the probe mode / the rule sets. Exact names,
    # matched against the feed row's `payload`, never a substring: `delete_rule` and
    # `delete_extract_rule` are separate tools and must not credit each other.
    PROBE_TOOLS = Set{"set_probe_mode"}
    RULE_TOOLS  = Set{
      "create_rule", "update_rule", "delete_rule", "set_rule_enabled",
      "create_extract_rule", "update_extract_rule", "delete_extract_rule", "set_extract_rule_enabled",
    }

    # How far back a peer change looks for the agent action that explains it. Deliberately short:
    # the question is asked the moment the change is ADOPTED, so the answer only has to span the
    # poll that noticed it plus the gap between an agent's write and the feed row it commits
    # afterwards. A wide window is not more thorough — it starts crediting an agent for a second
    # operator's edit that merely landed nearby.
    ATTRIBUTION_WINDOW = 5.seconds

    # Did an agent write one of `tools` just now? Best-effort by construction — this reads a feed
    # only the MCP process writes, so a `gori run …` peer or a second TUI is never attributed and
    # the line correctly falls back to "another session". The reverse error is possible too and is
    # the reason for the narrow window: an agent editing a rule in the same breath as a human
    # editing another one can take the credit for both.
    def self.agent_wrote?(store : Store, tools : Set(String)) : Bool
      # Microseconds the way `Store#now_us` stamps them, not a millisecond round-trip: the two
      # halves of this comparison have to be computed the same way or the constant is not the
      # window the query actually enforces.
      since = (Time.utc - ATTRIBUTION_WINDOW - Time::UNIX_EPOCH).total_microseconds.to_i64
      store.recent_agent_actions(since, 20).any? { |row| (name = row.payload) && tools.includes?(name) }
    end

    # How long a rule change waits for the rest of its burst before it is announced.
    #
    # TRAILING edge only, deliberately. An agent writing three rules in a row lands three separate
    # adoptions on three separate ticks, and one line per tick — each with the terminal bell behind
    # it — is the noise this whole feature has to avoid to be worth having. Announcing on the
    # leading edge instead would be instant but would undercount, and doing both puts two lines on
    # screen for one burst. A couple of seconds is nothing for a notice that is not an answer to
    # anything the operator just pressed.
    QUIET_WINDOW = 2.seconds

    def initialize
      @rules = nil.as(RuleSetChange?)
      @extract = nil.as(RuleSetChange?)
      # When the burst being held started. One timer for both rule kinds — they leave as one line.
      @since = nil.as(Time::Instant?)
      # Whether an agent is known to have written any part of the burst being held.
      @by_agent = false
    end

    # Take both rule sets' pending peer change and record them together, asking the feed who wrote
    # them ONCE for the pair.
    #
    # Here rather than in each surface's loop. The TUI and the headless capture both need this
    # exact take/attribute/record sequence, and a hand-written copy in each is the drift this class
    # was introduced to prevent — widening RULE_TOOLS or adding a third rule set would otherwise
    # have to be remembered twice. Each surface is left with only its emitter.
    def absorb(rules : RuleSetChange?, extract : RuleSetChange?, now : Time::Instant, store : Store) : Nil
      return unless rules || extract
      by_agent = PeerNotices.agent_wrote?(store, RULE_TOOLS)
      record_rules(rules, now, by_agent) if rules
      record_extract(extract, now, by_agent) if extract
    end

    # A peer changed the Match&Replace rules this session rewrites live traffic with.
    def record_rules(change : RuleSetChange, now : Time::Instant, by_agent : Bool = false) : Nil
      @rules = (held = @rules) ? held.merge(change) : change
      # An agent anywhere in the burst names the burst. The alternative — the LAST writer wins —
      # would let one unattributed peer write erase the one fact worth carrying.
      @by_agent ||= by_agent
      @since ||= now
    end

    # A peer changed the extract rules that decide what `$KEY` expands to at every send seam.
    def record_extract(change : RuleSetChange, now : Time::Instant, by_agent : Bool = false) : Nil
      @extract = (held = @extract) ? held.merge(change) : change
      @by_agent ||= by_agent
      @since ||= now
    end

    # Whatever the quiet window has finished holding. Called on a bare cadence, NOT only when a
    # change arrives: the last change of a burst is the one still being held, so a flush that only
    # ran on new input would wait for a peer edit that may never come.
    #
    # At most ONE line comes out, even when both rule kinds moved. Two pushes in one tick would
    # give the Companion only the second to speak (she reads the newest note and nothing else),
    # and "the rules changed" is one fact to the operator either way.
    def flush(now : Time::Instant) : Notice?
      return nil unless (since = @since) && now - since >= QUIET_WINDOW
      rules, extract, by_agent = @rules, @extract, @by_agent
      @rules = @extract = nil
      @since = nil
      @by_agent = false
      rule_notice(rules, extract, by_agent)
    end

    private def rule_notice(rules : RuleSetChange?, extract : RuleSetChange?, by_agent : Bool) : Notice?
      # ONE level for the whole line. A change that leaves nothing enabled cannot move a byte on
      # the wire, whatever just happened to the list — and the operator must not get a bell or no
      # bell depending only on whether the peer happened to touch one list or two.
      quiet = ((rules.try(&.enabled) || 0) + (extract.try(&.enabled) || 0)).zero?
      message =
        if rules && extract
          # Both halves of the send path at once. Naming neither count keeps the line short enough
          # to still say the thing that matters, which is the consequence.
          "Match&Replace and extract rules changed by #{author(by_agent)} — this session sends different bytes now"
        elsif change = rules
          "#{subject(change, "Match&Replace rule")} changed by #{author(by_agent)} — " \
          "#{consequence(change, "rewriting live traffic here", "a different rule now wins on the same header")}"
        elsif change = extract
          "#{subject(change, "extract rule")} changed by #{author(by_agent)} — " \
          "#{consequence(change, "$KEY may expand to a different value here", "they are read in a different order")}"
        else
          return nil
        end
      Notice.new(quiet ? :info : :warn, message, :rewriter, by_agent)
    end

    # What moved. A change that added, removed and edited NOTHING can only have moved in ORDER, and
    # a line reading "0 rules changed" would be both wrong and useless.
    private def subject(change : RuleSetChange, noun : String) : String
      change.changed.zero? ? "#{noun} order" : counted(change.changed, noun)
    end

    # What it means for the wire.
    #
    # `reordered` is read HERE rather than folded into the subject, because `merge` can hand back a
    # burst that edited one rule AND moved another: the count then carries the edit and nothing
    # would carry the precedence move, which is the only thing that field was added for.
    private def consequence(change : RuleSetChange, live : String, reorder : String) : String
      return "none are enabled, nothing on the wire" if change.enabled.zero?
      return reorder if change.changed.zero?
      change.reordered ? "#{live}, and in a new order" : live
    end

    # Who to name. "an agent" only when the feed says so; "another session" is the honest answer for
    # everything else, including the peers that write no feed row at all.
    private def author(by_agent : Bool) : String
      by_agent ? "an agent" : "another session"
    end

    private def counted(n : Int32, noun : String) : String
      "#{n} #{noun}#{"s" if n != 1}"
    end

    # A peer moved the project's probe mode and this session ADOPTED it — `@mode` is the
    # authorization to fire active probes, so this is the one peer change with a blast radius
    # outside the tool.
    #
    # The direction decides the volume. Going UP into an actively-probing mode is the operator
    # needing to know now (`:warn` ⇒ the bell, the toast, Miss Ring's alarmed face); every other
    # move is `:info` ⇒ a line in the notification centre and nothing else. A downgrade is safe by
    # construction — it can only stop traffic — but it still answers "when did the agent turn this
    # off?" a minute later, which is what the ring is for.
    def probe_mode(prev : Probe::Mode, curr : Probe::Mode, by_agent : Bool = false) : Notice
      if curr.probes_actively? && curr.value > prev.value
        # Includes active → aggressive: aggressive probes UNSAFE methods, so an in-scope endpoint
        # can be state-mutated by the automatic pipeline. That is a widening, not a re-label.
        Notice.new(:warn,
          "probe mode raised to #{curr.label} by #{author(by_agent)} — attack payloads are sent from here",
          :probe, by_agent)
      elsif prev.probes_actively? && !curr.probes_actively?
        Notice.new(:info,
          "probe mode lowered to #{curr.label} by #{author(by_agent)} — active probing stopped here",
          :probe, by_agent)
      else
        Notice.new(:info, "probe mode set to #{curr.label} by #{author(by_agent)}", :probe, by_agent)
      end
    end
  end
end
