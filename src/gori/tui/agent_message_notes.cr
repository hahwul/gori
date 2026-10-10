require "../agent_presence"
require "../store"
require "./agents_overlay"
require "./fmt"

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
      attached = entry.attached_at.try { |t| "attached #{Fmt.ago_phrase(now - t)}" } || "attached ?"
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
      case delivery.via
      when Gori::AgentDelivery::VIA_POLL
        {:info, "left for #{who} to pick up (operator_messages)"}
      when Gori::AgentDelivery::VIA_PICKED_UP
        {:success, "→ #{who} picked it up (operator_messages)"}
      when Gori::AgentDelivery::VIA_TOOL_RESULT
        # The agent asked gori something and the answer carried the line back. As confirmed as
        # a socket write — the client had it — and it names the seam so the operator knows the
        # message went out on the agent's own next call rather than waking it.
        {:success, "→ #{who} got it (on its next tool result)"}
      when Gori::AgentDelivery::VIA_CODEX_QUEUE
        # The CLI took it and said so, which is as far as any route can see: the session runs a
        # turn on it now if it is idle, after the current one if it is not.
        {:success, "→ #{who} got it (queued in codex)"}
      when Gori::AgentDelivery::VIA_CHANNEL
        # A channel push is fire-and-forget: the server cannot tell whether that session was
        # launched with channels, and a push to one that was not is dropped without a word.
        # Say so on the row rather than let "got it" promise what nobody checked.
        {:success, "→ #{who} got it (channel — only if that session runs with channels)"}
      else
        {:success, "→ #{who} got it (#{safe(delivery.via) || "?"})"}
      end
    end

    # `{level, message}` for one reply: the client's name and the one line it sent. The level
    # is the agent's own, already clamped to the feed's four by the store.
    def self.reply_line(reply : Gori::AgentReply) : {Symbol, String}
      who = sender(reply)
      level = {"success" => :success, "warn" => :warn, "error" => :error}[reply.level]? || :info
      # The client NAME is width-capped (`safe`), but the SUMMARY is not: it is the message,
      # and the surfaces size it themselves — the ring row truncates to one line, Miss Ring's
      # bubble wraps it to three. Capping it here would flatten both to a client-name width.
      {level, "#{who}: #{scrub_line(reply.summary)}"}
    end

    # The ring source a reply's note carries: `script` for a `gori run notify` line (#1323),
    # `agent` for everything else — including a row whose source is some word this build does
    # not know, which is the direction that still shows it with the marker rather than hides
    # who sent it.
    def self.note_source(reply : Gori::AgentReply) : String
      reply.source == Gori::AgentReply::SOURCE_SCRIPT ? "script" : "agent"
    end

    # How much of ONE reply's detail the away summary carries. The summary is one note, and a
    # note's detail is a card the operator scrolls: fifty replies at the full `DETAIL_MAX`
    # each would be 1.6 MB of card for a notice whose job is to say "these arrived".
    MISSED_DETAIL_MAX = 2_000

    # `{level, message, detail}` for the one note a window opens with when replies landed
    # while no window was open (#1322). `rows` is the page the note lists (oldest first) and
    # `total` how many there really were, which the page may be short of.
    #
    # ONE note, not the replies replayed: a project reopened after a night of an agent working
    # would otherwise open onto a ring it has to page through, and Miss Ring would say only the
    # last of them. The level is the most severe one sent, so a single `error` among the
    # `info`s still colours the row (and rings the bell, when that is on).
    def self.missed_replies(rows : Array(Gori::AgentReply), total : Int32) : {Symbol, String, String}
      names = rows.map { |r| sender(r) }.uniq!
      count = {total, rows.size}.max
      noun = count == 1 ? "reply" : "replies"
      message =
        if names.size == 1
          "#{names.first} sent #{count} #{noun} while you were away"
        else
          shown = names.first(3).join(", ")
          shown += ", …" if names.size > 3
          "#{count} #{noun} arrived while you were away (#{shown})"
        end
      {worst_level(rows), message, missed_detail(rows, count)}
    end

    # The replies, one block each: who and when, then what they said.
    private def self.missed_detail(rows : Array(Gori::AgentReply), count : Int32) : String
      String.build do |io|
        rows.each_with_index do |r, i|
          io << "\n\n" if i > 0
          at = LocalTime.format(r.created_at, "%Y-%m-%d %H:%M")
          io << sender(r) << " · " << r.level << " · " << at << '\n'
          io << scrub_line(r.summary)
          if (d = r.detail) && !d.empty?
            io << "\n\n"
            if d.size > MISSED_DETAIL_MAX
              io << d[0, MISSED_DETAIL_MAX] << "\n… (cut here; the full reply is in the Activity pane)"
            else
              io << d
            end
          end
        end
        if count > rows.size
          io << "\n\n… and " << (count - rows.size) << " more in the Project tab's Activity pane."
        end
      end
    end

    # The client's name as a ring row shows it (`claude-code`, not `claude-code pid 48213`).
    private def self.sender(reply : Gori::AgentReply) : String
      sender_of(reply.target_label)
    end

    # `claude-code pid 48213` → `claude-code`, scrubbed: the one derivation of a client's name
    # from a feed row's label, for a reply and a question alike.
    private def self.sender_of(label : String) : String
      AgentsOverlay.safe_client(label.split(" pid ").first?) || "agent"
    end

    private def self.worst_level(rows : Array(Gori::AgentReply)) : Symbol
      rank = {"info" => 0, "success" => 1, "warn" => 2, "error" => 3}
      worst = rows.max_of? { |r| rank[r.level]? || 0 } || 0
      {:info, :success, :warn, :error}[worst]
    end

    # --- ask_operator (#1324) ---------------------------------------------------------------

    # The ring line that announces a question: `claude-code asks: Add api.example.com to scope?`.
    def self.question_line(q : Gori::AgentQuestion) : String
      "#{question_sender(q)} asks: #{scrub_line(q.question)}"
    end

    # The note's long form, what ↵ shows once the question is closed and the card is no
    # longer offered: the context and the choices it was asked with.
    def self.question_detail(q : Gori::AgentQuestion) : String
      String.build do |io|
        if (d = q.detail) && !d.strip.empty?
          io << d.rstrip << "\n\n"
        end
        io << "Choices: " << q.choices.map { |c| scrub_line(c) }.join(" · ")
      end
    end

    # The card's second line: how long it has waited and how long it has left.
    def self.question_meta(q : Gori::AgentQuestion, now_us : Int64) : String
      # Compared before subtracting: `expires_at` came off a feed row another process wrote,
      # and a hand-written one far in the past would overflow the difference.
      waited = now_us > q.created_at ? (now_us - q.created_at) // 1000 : 0_i64
      asked = Fmt.ago_phrase(waited.milliseconds)
      left = q.expires_at > now_us ? (q.expires_at - now_us) // 1_000_000 : 0_i64
      expires =
        if left <= 0
          "expired"
        elsif left < 60
          "expires in <1m"
        elsif left < 3600
          "expires in #{left // 60}m"
        else
          "expires in #{left // 3600}h#{(left % 3600) // 60 > 0 ? " #{(left % 3600) // 60}m" : ""}"
        end
      "asked #{asked} · #{expires}"
    end

    # The toast after the operator answered.
    def self.question_answered(q : Gori::AgentQuestion, choice : String?) : String
      who = question_sender(q)
      choice ? "answered #{who}: #{scrub_line(choice)}" : "dismissed #{who}'s question"
    end

    # The asking client, as a ring row names it.
    def self.question_sender(q : Gori::AgentQuestion) : String
      sender_of(q.target_label)
    end

    # `scrub_line` for a caller outside this module (the question card).
    def self.scrub(text : String) : String
      scrub_line(text)
    end

    # Peer-written text with the control characters removed and whitespace collapsed, but no
    # width cap — for a line the drawing surface will size.
    private def self.scrub_line(text : String) : String
      text.scrub.gsub(/\p{C}/, "").gsub(/\s+/, " ").strip
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
