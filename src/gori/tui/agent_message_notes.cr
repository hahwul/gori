require "../agent_presence"
require "../store"
require "./agents_overlay"

module Gori::Tui
  # The two strings the operator→agent channel (#1090) puts on screen: a picker row naming one
  # attached agent, and the notification a courier's reply turns into.
  #
  # PURE, and in their own file for exactly that reason. Both live on the Runner's paths —
  # `tell_agent` builds the picker, the DV poll drains deliveries — and `Runner.new` cannot be
  # constructed in a spec (it needs a live terminal), so wording pinned only through the Runner
  # is wording nothing pins. Everything here takes its inputs as arguments, including `now`,
  # so "attached 3m ago" is a computation and not a clock read.
  module AgentTargets
    # Every attached agent, as `Store#post_agent_message` spells it.
    ALL = "all"

    # One picker row: `claude-code · pid 48213 · attached 3m ago`.
    #
    # `client` came over the MCP initialize handshake, so it goes through `safe_client` for the
    # reason the AGENTS card's rows do — it is peer-authored text, not gori's own word, and the
    # picker is a place a pathological name could push the row past the card's edge.
    def self.label(entry : Gori::AgentPresence::Entry, now : Time) : String
      pid = entry.pid ? "pid #{entry.pid}" : "pid ?"
      attached = entry.attached_at.try { |t| "attached #{AgentsOverlay.relative_time(now - t)}" } || "attached ?"
      "#{name(entry)} · #{pid} · #{attached}"
    end

    # The agent's display name on its own — the prompt title and the sent toast both say it,
    # and neither wants the pid.
    def self.name(entry : Gori::AgentPresence::Entry) : String
      AgentsOverlay.safe_client(entry.client) || "(unnamed client)"
    end

    # How one entry is addressed — nil when the marker carries no pid, which is the one case
    # this row cannot be singled out in. Nil rather than a silent fall back to ALL: "send it to
    # everybody" is not a quieter version of "send it to that one", and the open-site says so
    # instead of guessing.
    def self.target_for(entry : Gori::AgentPresence::Entry) : String?
      entry.pid.try { |pid| "pid:#{pid}" }
    end
  end

  # A courier's reply, as one notification-ring line.
  module AgentMessageNotes
    # `{level, message}` for one delivery row.
    #
    # The `ok` test comes FIRST, ahead of the transport split below it. A courier that could
    # not deliver still reports which way it tried, and reading `via` first would turn a failed
    # hand-off through the poll table into the reassuring "left for … to pick up" — the one
    # wording that says the message is still on its way.
    def self.line(delivery : Gori::AgentDelivery) : {Symbol, String}
      who = label_of(delivery)
      unless delivery.ok
        return {:warn, "#{who}: #{safe(delivery.reason) || "delivery failed"}"}
      end
      # "poll" is not a delivery, it is a deposit: the courier wrote the line where its session
      # will read it next time it looks, which may be never. Info, not success, and it names the
      # table so the operator knows where to look when it is never picked up.
      if delivery.via == "poll"
        return {:info, "left for #{who} to pick up (operator_messages)"}
      end
      {:success, "→ #{who} got it (#{safe(delivery.via) || "?"})"}
    end

    # `target_label`, `via` and `reason` are all written by ANOTHER process. Same stance as a
    # handshake client name: scrub the control characters and cap the width before any of it
    # reaches the ring, which renders a note as one row.
    private def self.label_of(delivery : Gori::AgentDelivery) : String
      safe(delivery.target_label) || "agent"
    end

    private def self.safe(text : String?) : String?
      AgentsOverlay.safe_client(text)
    end
  end
end
