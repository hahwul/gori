require "../agent_permission_overlay"
require "../name_prompt_overlay"
require "../choice_picker"

# The Agent tab's verbs and shell seams (#1093) — reopens Gori::Tui::Runner. The controller
# (`controllers/agent_controller.cr`) owns the session; this file is what the keymap, the
# palette and the tick reach it through, plus the two modals only the shell can raise: the
# permission card and the one-line quick-ask prompt.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Past conversations the history picker offers. Bounded by what one card can list.
  AGENT_HISTORY_LIMIT = 30

  private def agent_controller : AgentController
    @tabs[:agent].as(AgentController)
  end

  # ---- availability gates (space menu) -------------------------------------------------

  def agent_alive? : Bool
    agent_controller.session.try(&.alive?) || false
  end

  def agent_running? : Bool
    agent_controller.turn_running?
  end

  def agent_pending? : Bool
    !agent_controller.pending_permission.nil?
  end

  # ---- verbs ---------------------------------------------------------------------------

  def agent_send : Nil
    agent_controller.send_input
  end

  def agent_interrupt : Nil
    agent_controller.interrupt
  end

  def agent_stop : Nil
    agent_controller.stop
  end

  def agent_restart : Nil
    agent_controller.restart(resume: true)
  end

  def agent_new : Nil
    agent_controller.new_conversation
  end

  def agent_copy : Nil
    agent_controller.agent_copy
  end

  def agent_fold : Nil
    agent_controller.toggle_fold
  end

  # `p`, and the tick's own path when a request lands while the tab is open (see
  # `agent_tick`). Nothing pending is a toast, not a silent no-op.
  def agent_permission : Nil
    req = agent_controller.pending_permission
    return (@toast = "no permission request is waiting") unless req
    return if @overlay != :none
    open_agent_permission(req) { |d| agent_controller.answer(req.request_id, d) }
  end

  # The past conversations, newest first; picking one loads it READ-ONLY beside the live
  # session (the controller's history mode; `esc` returns).
  def agent_history : Nil
    rows = @session.store.list_agent_sessions(AGENT_HISTORY_LIMIT)
    return (@toast = "no past conversations in this project") if rows.empty?
    choices = rows.map_with_index do |row, i|
      stamp = Time.unix_ms(row.started_at // 1000).to_local.to_s("%m-%d %H:%M")
      state = row.ended_at ? "" : " · live"
      # `label`, NOT `title`: a block assigning to the parameter's name rewrites it.
      label = row.title.empty? ? "(untitled)" : row.title.gsub(/\s+/, " ")
      ChoicePicker::Choice.new("#{stamp}  #{label[0, 60]}  · #{row.turns} turns#{state}",
        i < 9 ? ('1' + i) : nil, Theme.text, i)
    end
    picker = ChoicePicker.new("PAST CONVERSATIONS", choices, -1, :agent_history)
    open_choice_picker(picker) do |choice|
      rows[choice.selected_value]?.try { |row| agent_controller.load_history(row.id) }
    end
  end

  # Global: a one-line prompt from wherever the operator is. Sends and STAYS — the reply
  # comes back as a notification whose Goto is the tab (the controller pushes it when the
  # turn ends while another tab is active).
  def agent_ask : Nil
    np = NamePromptOverlay.new("ASK THE AGENT", "sent to the hosted agent; the reply arrives as a notification", "", "send")
    np.on_commit = -> {
      text = np.name.strip
      if text.empty?
        false
      elsif agent_controller.submit(text)
        @toast = "asked the agent"
        true
      else
        false # the controller toasted why (a turn is running, or the child would not start)
      end
    }
    open_overlay(np)
  end

  # ---- shell seams ---------------------------------------------------------------------

  # Host#open_agent_permission. The card's `:cancel` outcome (click-away) is a deny too:
  # there is no "decide later" for a held tool call, the CLI waits forever.
  def open_agent_permission(req : Gori::Agent::Event::PermissionAsked, &answer : Gori::Agent::Decision -> Nil) : Nil
    ov = AgentPermissionOverlay.new(req)
    answered = false
    ov.on_commit = -> {
      answered = true
      true
    }
    ov.on_close = -> {
      decision = answered ? (ov.answered || Gori::Agent::Decision::Deny) : Gori::Agent::Decision::Deny
      answer.call(decision)
    }
    open_overlay(ov)
  end

  # Once per tick, after the controller drained: a request that is waiting while THIS tab
  # is on screen and no modal is up gets its card at once. Any other time it stays queued —
  # the notification the controller pushed and the status band are the two ways back — so
  # a request never yanks the operator off another tab or steals an open modal.
  private def agent_tick : Bool
    changed = agent_controller.drain_events
    if @active_tab == :agent && @overlay == :none && (req = agent_controller.pending_permission)
      open_agent_permission(req) { |d| agent_controller.answer(req.request_id, d) }
      changed = true
    end
    changed
  end
end
