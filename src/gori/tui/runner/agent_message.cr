require "../../agent_presence"
require "../agent_message_notes"
require "../agents_overlay"
require "../choice_picker"
require "../name_prompt_overlay"
require "../theme"

# The operator→agent channel (#1090) — "Tell the agent…" and the courier replies it produces.
# ExecContext verb implementations; reopens Gori::Tui::Runner (see tui/runner.cr for the loop).
#
# The two halves go opposite ways through the store. The SEND writes one row into the project's
# events feed and stops there — gori never talks to a Claude session, it leaves a line where
# each attached `gori mcp` process is already tailing. The RECEIVE is that courier writing back
# what it did with the line, which this file turns into a notification. Nothing here waits: an
# agent that is wedged, or that never looks, simply never produces a reply row.
#
# Wording lives in `tui/agent_message_notes.cr`, not here — `Runner.new` needs a live terminal,
# so anything spelled in this file is unreachable from a spec.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Row mnemonics for the target picker, `1`..`9` — the digits, and only the digits. A tenth
  # attached agent (plus the "all" row) is reached with ↑/↓ and ↵ rather than spilling into
  # letters: `j`/`k` are the list's own navigation and ChoicePicker tries a mnemonic FIRST.
  AGENT_PICK_KEYS = ('1'..'9').to_a

  # How many courier replies one poll tick turns into notes. A bound, not a pace: the cursor
  # below advances past whatever this returns, so a backlog drains over the next few ticks
  # instead of flooding the ring in one frame.
  AGENT_DELIVERY_BATCH = 50

  # High-water mark of the delivery rows already announced. Seeded in `Runner#initialize` from
  # `last_agent_delivery_id` — at "now", not at 0 — because a project carries every reply it has
  # ever collected, and opening it would otherwise replay them all as things that just happened
  # (the same rule `@passthrough_announced` and `@intercept_cmd_watermark` follow).
  @agent_delivery_cursor : Int64 = 0_i64

  # --- sending ---------------------------------------------------------------------------

  # `app.tell-agent`. Pick an attached agent, type one line, post it.
  #
  # The target set is the MCP markers ONLY. `AgentPresence.live` defaults to that directory, but
  # the filter is spelled anyway: `kind` is what a half-written marker body falls back to, and a
  # TUI window in the list would be a row that can never receive anything.
  def tell_agent : Nil
    rows = Gori::AgentPresence.live(@session.project.db_path).select { |e| e.kind == Gori::AgentPresence::KIND_MCP }
    if rows.empty?
      @toast = "no agent is attached — gori mcp --install-claude-code shows how"
      return
    end
    # Resolved HERE, before any card is up, and carried into the commit closure. The marks are
    # what the operator was looking at when they reached for the verb; re-reading them two
    # overlays later would answer for a list the picker has been sitting on top of.
    ids = @active_tab == :history ? history_target_flow_ids : [] of Int64
    from = @active_tab.to_s
    # One agent is not a choice. The picker would be a card whose only content is the answer.
    if rows.size == 1
      prompt_agent_message(rows.first, ids, from)
      return
    end
    open_agent_target_picker(rows, ids, from)
  end

  private def open_agent_target_picker(rows : Array(Gori::AgentPresence::Entry),
                                       ids : Array(Int64), from : String) : Nil
    now = Time.utc
    choices = rows.map_with_index do |entry, i|
      ChoicePicker::Choice.new(AgentTargets.label(entry, now), AGENT_PICK_KEYS[i]?, Theme.text, i)
    end
    # The broadcast row LAST and keyless-if-crowded, like every other row. It is the widest
    # gesture on the card, and a list whose first mnemonic sends to everybody is one fat-finger
    # away from telling four sessions something meant for one.
    choices << ChoicePicker::Choice.new("all attached agents", AGENT_PICK_KEYS[rows.size]?,
      Theme.accent, rows.size)
    picker = ChoicePicker.new("TELL WHICH AGENT", choices, -1, :agent_target)
    open_choice_picker(picker) do |picked|
      if entry = rows[picked.selected_value]?
        prompt_agent_message(entry, ids, from)
      else
        open_agent_message_prompt("all attached agents", AgentTargets::ALL, ids, from)
      end
    end
  end

  private def prompt_agent_message(entry : Gori::AgentPresence::Entry,
                                   ids : Array(Int64), from : String) : Nil
    target = AgentTargets.target_for(entry)
    unless target
      @toast = "that agent's marker carries no pid — send to all attached agents instead"
      return
    end
    open_agent_message_prompt(AgentTargets.name(entry), target, ids, from)
  end

  # Step two: the line itself. `NamePromptOverlay` because the shape is exactly its shape — one
  # field, a subject line saying where the text lands, and a named ↵ verb.
  private def open_agent_message_prompt(name : String, target : String,
                                        ids : Array(Int64), from : String) : Nil
    np = NamePromptOverlay.new("TELL #{name}",
      "sent to the agent's session; delivery shows in the notification ring", "", "send", "message")
    np.on_commit = -> {
      text = np.name
      if text.empty?
        # Keep the card up: an empty field is a line not typed yet, not a decision to redo.
        # esc is how the operator backs out, and it already says so on the hint row.
        @toast = "type the message first — esc cancels"
        false
      else
        @session.store.post_agent_message(text, target, from, ids)
        @toast = "sent to #{name}"
        true
      end
    }
    open_overlay(np)
  end

  # --- receiving -------------------------------------------------------------------------

  # Turn every courier reply we have not announced yet into a notification. Returns true when
  # anything was pushed (the poll loop repaints on that). Called every DV_POLL_INTERVAL tick.
  def drain_agent_deliveries : Bool
    # High-water first, then the page (the courier's rule): the feed has no index on `kind`,
    # so a cursor that only moved on a delivery would re-walk everything the project wrote
    # since the TUI opened, every 750 ms, on the normal day when nobody is talking.
    high = @session.store.last_agent_delivery_id
    page = @session.store.agent_deliveries_after(@agent_delivery_cursor, AGENT_DELIVERY_BATCH)
    @agent_delivery_cursor = page.full ? {@agent_delivery_cursor, page.scanned_max}.max : {@agent_delivery_cursor, page.scanned_max, high}.max
    return false if page.rows.empty?
    page.rows.each do |row|
      level, message = AgentMessageNotes.line(row)
      @notifications.push(level, message, nil, source: "app")
    end
    true
  end
end
