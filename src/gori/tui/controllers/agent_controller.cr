require "../tab_controller"
require "../agent_view"
require "../../agent"
require "../../hotkeys"
require "../theme"

module Gori::Tui
  # The Agent tab (#1093): one hosted `Session`, the two panes that show it, and the seam the
  # Runner drives it through.
  #
  # WHAT THIS CONTROLLER IS NOT ALLOWED TO DO. It never opens the permission card. A held tool
  # call is QUEUED on the session and reported here (a notification, and the status band); the
  # Runner polls `pending_permission` in its tick and raises `AgentPermissionOverlay`, because
  # a controller cannot open an overlay and because the card must come up even when the
  # operator is on another tab. The split is the same one every other tab makes with its own
  # drill-in overlays, and it is what keeps "the agent wants to run rm -rf" from depending on
  # this tab being the active one.
  #
  # THE SESSION IS LAZY. Nothing spawns on `on_enter`: entering a tab must not start a child
  # process, and the empty body says what the tab is and which key starts it instead.
  # `ensure_session` is the one construction site, and a spec replaces it wholesale through
  # `session_factory` rather than putting a `claude` on the machine.
  #
  # THE LIVE TRANSCRIPT IS AUTHORITATIVE and is never reloaded from the store — `Session`'s
  # own header says why (same-process writer visibility through `data_version` is flaky, and a
  # reload could truncate an in-flight turn). `on_external_change` therefore does nothing to
  # it. `load_history` is the read-only exception: a PAST conversation is loaded into a
  # SEPARATE transcript and shown in the pane, with `esc` returning to the live one.
  class AgentController < TabController
    # How a spec (or a later headless caller) supplies a session without a `claude` binary.
    # nil in production, where `ensure_session` builds one from the host's project.
    property session_factory : Proc(Gori::Agent::Session)?

    getter view : AgentView
    getter session : Gori::Agent::Session?
    # The past conversation on screen, or nil while the pane shows the live one.
    getter viewing_history : Int64?

    def initialize(host : Host)
      super(host)
      @view = AgentView.new
      @session = nil.as(Gori::Agent::Session?)
      @history = nil.as(Gori::Agent::Transcript?)
      @viewing_history = nil.as(Int64?)
      # Permission requests already reported. Keyed on `request_id` because `drain_events`
      # runs ~20x a second and `pending` holds a request until it is answered: without the
      # set, one held tool call would post a notification on every tick.
      @notified = Set(String).new
      @notified_dead = false
      @was_running = false
    end

    # ---- identity --------------------------------------------------------------------

    def tab : Symbol
      :agent
    end

    def command_scope : Verb::Scope
      Verb::Scope::Agent
    end

    def command_section : Symbol
      @view.focus
    end

    # ---- the session -----------------------------------------------------------------

    # The session, built and started on first use. Returns the existing one otherwise — a
    # dead session is NOT rebuilt here (that is `restart`'s job), because the transcript it
    # holds is what the operator is reading.
    def ensure_session : Gori::Agent::Session
      if s = @session
        return s
      end
      s = build_session
      @session = s
      @notified.clear
      @notified_dead = false
      @was_running = false
      s.start
      @view.sync(s.transcript)
      s
    end

    private def build_session : Gori::Agent::Session
      if factory = @session_factory
        return factory.call
      end
      # `cwd` is deliberately left nil = inherit gori's own, which is what an operator who ran
      # `gori` in a repo means by "here" (Agent::Config's own comment). The project directory
      # would be the gori DB's folder, which is not a workspace anybody wants an agent in.
      config = Gori::Agent::Config.from_settings(@host.session.project.db_path)
      Gori::Agent::Session.new(Gori::Agent::ClaudeBackend.new, config, @host.session.store)
    end

    def turn_running? : Bool
      !!@session.try(&.running?)
    end

    def stop_all : Nil
      @session.try(&.stop)
    end

    def stop : Nil
      return unless s = @session
      s.stop
      @view.sync(s.transcript) unless @viewing_history
      @host.status("agent stopped")
    end

    def interrupt : Nil
      s = @session
      unless s && s.running?
        @host.status("no turn is running")
        return
      end
      unless s.interrupt
        @host.status("this agent build did not advertise interrupt — {agent.stop} stops it instead")
        return
      end
      @host.status("interrupt sent")
    end

    def restart(resume : Bool) : Nil
      s = @session
      unless s
        ensure_session
        return
      end
      @notified.clear
      @notified_dead = false
      @was_running = false
      ok = s.restart(resume)
      exit_history
      @view.sync(s.transcript)
      @host.status(ok ? (resume ? "restarted, resuming the conversation" : "restarted") : "could not restart: #{s.dead_reason}")
    end

    # A fresh conversation in a fresh row. `restart(false)` is what clears the transcript and
    # the store id, so this is that call plus the pane bookkeeping — not a second definition
    # of what "new" means.
    def new_conversation : Nil
      exit_history
      unless @session
        ensure_session
        return
      end
      restart(false)
    end

    # ---- the tick --------------------------------------------------------------------

    # Apply what the child said, then repaint if anything moved. Also the ONE place a
    # background transition becomes a notification: a death, a new held tool call, and a turn
    # that finished while the operator was elsewhere.
    def drain_events : Bool
      return false unless s = @session
      changed = s.drain
      notify_pending(s)
      notify_turn_done(s)
      notify_dead(s)
      @view.sync(s.transcript) if changed && @viewing_history.nil?
      changed
    end

    private def notify_pending(s : Gori::Agent::Session) : Nil
      s.pending.each do |p|
        next if @notified.includes?(p.request_id)
        # Marked seen even when the tab IS active and no notification goes out: the card is
        # already coming up in front of the operator, and leaving the id unmarked would post
        # a stale warning the moment they switched tabs.
        @notified << p.request_id
        next if @host.active_tab == :agent
        @host.notifications.push(:warn, "agent wants to run #{p.tool}",
          Jobs::Goto.new(:agent), source: "agent")
      end
    end

    # A turn's end is read off the state transition rather than the event, because `drain`
    # applies the `result` frame inside the session and nothing surfaces it. The reply is the
    # last assistant text in the transcript, which is the same line the pane just drew.
    private def notify_turn_done(s : Gori::Agent::Session) : Nil
      was = @was_running
      @was_running = s.running?
      return unless was && !s.running?
      return if @host.active_tab == :agent
      reply = s.transcript.messages.reverse_each.find { |m| m.role == "assistant" && m.kind == "text" }
      line = reply ? Gori::Agent::Transcript.first_line(reply.text) : "turn finished"
      @host.notifications.push(:success, line.empty? ? "turn finished" : line,
        Jobs::Goto.new(:agent), source: "agent")
    end

    private def notify_dead(s : Gori::Agent::Session) : Nil
      return unless s.dead?
      return if @notified_dead
      @notified_dead = true
      return if s.dead_reason == "stopped"
      @host.notifications.push(:error, "agent exited: #{s.dead_reason}",
        Jobs::Goto.new(:agent), source: "agent")
    end

    # ---- turns -----------------------------------------------------------------------

    # Send one user turn. Starts the session when there is none — the quick-ask path, where
    # the operator's first keystroke in an untouched tab is the message itself.
    def submit(text : String) : Bool
      if text.strip.empty?
        # An empty ↵ with no child yet is "start the agent" — what the guidance card
        # promises. With a child already up there is nothing to do but say so.
        if @session.nil?
          s = ensure_session
          @host.status(s.dead? ? "agent could not start: #{s.dead_reason}" : "agent started — type a prompt and ↵")
        else
          @host.status("nothing to send")
        end
        return false
      end
      exit_history
      s = ensure_session
      unless s.idle?
        @host.status(refusal(s))
        return false
      end
      return false unless s.send(text)
      @view.sync(s.transcript)
      true
    end

    private def refusal(s : Gori::Agent::Session) : String
      return keys("agent is not running — {agent.restart} restarts it") if s.dead?
      return keys("a turn is running — {agent.interrupt} stops it") if s.running?
      "agent is still starting"
    end

    def send_input : Bool
      return false unless submit(@view.input_text)
      @view.clear_input
      true
    end

    def answer(request_id : String, decision : Gori::Agent::Decision) : Nil
      return unless s = @session
      s.answer_permission(request_id, decision)
      @view.sync(s.transcript) unless @viewing_history
    end

    def pending_permission : Gori::Agent::Event::PermissionAsked?
      @session.try(&.pending.first?)
    end

    # ---- history ---------------------------------------------------------------------

    # Show a past conversation, read-only, in a transcript of its own. The live one is left
    # untouched — the session keeps streaming into it, and `esc` puts it back on screen.
    def load_history(session_id : Int64) : Nil
      rows = @host.session.store.agent_messages(session_id)
      if rows.empty?
        @host.status("that conversation has no transcript")
        return
      end
      t = Gori::Agent::Transcript.new
      t.load(rows.map { |r| history_message(r) })
      @history = t
      @viewing_history = session_id
      @view.sync(t)
      @view.focus_pane(:transcript)
      @host.status("viewing a past conversation — esc returns to the live one")
    end

    # A stored row as a transcript message. `tool_use_id` is NOT on the row — the column set
    # keeps the rendered text and the backend's payload, not the block id — so a past
    # conversation's calls draw folded and cannot be expanded. `tool_name` is recoverable
    # because `Session` writes the tool's name as the `tool_use` row's own text.
    private def history_message(r : Gori::Store::AgentMessageRow) : Gori::Agent::Message
      Gori::Agent::Message.new(r.seq, r.role, r.kind, r.text, payload: r.payload,
        truncated: r.truncated?, created_at: r.created_at,
        tool_name: r.kind == "tool_use" ? r.text : nil)
    end

    private def exit_history : Nil
      return unless @viewing_history
      @viewing_history = nil
      @history = nil
      if s = @session
        @view.sync(s.transcript)
      end
    end

    # ---- folding + copy ---------------------------------------------------------------

    def toggle_fold : Nil
      @host.status("no tool call on this line") unless @view.toggle_fold
    end

    def copy_text : String?
      @view.copy_text
    end

    def agent_copy : Nil
      text = @view.focus == :input ? @view.input_selection_text : (@view.copy_text || "")
      copy_text(text)
    end

    # ---- render ------------------------------------------------------------------------

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      # `multi_pane: true`: the panes gild their own borders, so the outer shell must not.
      BodyChrome.framed(screen, rect, BodyChrome.shell_focused(focus, multi_pane: true)) do |inner|
        @view.render(screen, inner, focus == :body, @session)
      end
    end

    # ---- keys ---------------------------------------------------------------------------

    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      return handle_escape if key.escape?
      # Any OTHER modified chord defers to the central keymap so it stays rebindable — the
      # rule `NotesController` states; ^Z and ⌥/⌃ motion belong to the editor below.
      return false if (ev.ctrl? || ev.alt?) && !ev.ctrl_z? && !editing_motion?(ev)
      return handle_input_key(ev, c) if @view.focus == :input
      handle_transcript_key(ev, c)
    end

    private def handle_escape : Bool
      if @view.focus == :input && @view.insert_mode?
        @view.exit_insert!
      elsif @viewing_history
        exit_history
        @host.status("back on the live conversation")
      else
        @host.request_focus(:menu)
      end
      true
    end

    private def handle_input_key(ev : Termisu::Event::Key, c : Char?) : Bool
      @view.insert_mode? ? input_insert_key(ev, c) : input_read_key(ev, c)
    end

    private def input_insert_key(ev : Termisu::Event::Key, c : Char?) : Bool
      key = ev.key
      case
      when key.enter? then @view.newline
      when ev.ctrl_z? then @view.undo
        # Tested BEFORE plain ⌫: a terminal that reports ⌥⌫ as Backspace+Alt would otherwise
        # have the chord swallowed as a one-character delete.
      when @view.word_delete_key?(ev) then @view.input_motion_key(ev)
      when key.backspace?             then @view.backspace
      when key.up?
        @view.at_top? && !ev.shift? ? @host.request_focus(:menu) : @view.input_motion_key(ev)
      when key.delete?                then @view.delete
      when @view.input_motion_key(ev) then nil
      else
        insert_printable(ev, c)
      end
      true
    end

    private def insert_printable(ev : Termisu::Event::Key, c : Char?) : Nil
      return unless c && !ev.ctrl? && !ev.alt?
      @view.insert(c)
      report_replaced(@view.last_replaced) # a printable over a selection REPLACES it
      @view.set_preedit("")
    end

    # READ on the input pane: `↵` SENDS. It is the one key this tab has to spend, and the
    # alternative (a chord only) would make the most common action in the tab the only one
    # without a reflex. Newlines are typed in INS, where `↵` is a line break.
    private def input_read_key(ev : Termisu::Event::Key, c : Char?) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && bare_chord?(ev)
      return true.tap { send_input } if ev.key.enter?
      read_nav_key(ev, c, :input)
    end

    # READ on the transcript: `↵` opens the tool call under the caret. Same position in the
    # ladder as the input's send — the pane's one verb, on the key that means "do the thing
    # I am looking at".
    private def handle_transcript_key(ev : Termisu::Event::Key, c : Char?) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && bare_chord?(ev)
      return true.tap { toggle_fold } if ev.key.enter?
      read_nav_key(ev, c, :transcript)
    end

    # The READ-mode navigation the two panes share: ↑ (which ejects to the tab bar at the
    # pane's own top), ↓, ←/→, the shared motion set, and a bare printable deferred to the
    # keymap. ONE copy, taking the pane as a symbol rather than two closures: this runs per
    # keystroke, and the two hand-written copies it replaces were each one arm over the
    # complexity gate — which is how they would have drifted.
    private def read_nav_key(ev : Termisu::Event::Key, c : Char?, pane : Symbol) : Bool
      key = ev.key
      selecting = ev.shift?
      case
      when nav_up?(ev)
        @view.at_top? ? @host.request_focus(:menu) : read_move(pane, -1, 0, selecting)
      when nav_down?(ev)             then read_move(pane, 1, 0, selecting)
      when key.left?                 then read_move(pane, 0, -1, selecting)
      when key.right?                then read_move(pane, 0, 1, selecting)
      when read_motion_key(pane, ev) then nil
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false
      end
      true
    end

    private def read_move(pane : Symbol, dr : Int32, dc : Int32, selecting : Bool) : Nil
      if pane == :input
        @view.input_read_move(dr, dc, selecting: selecting)
      else
        @view.transcript_move(dr, dc, selecting: selecting)
      end
    end

    private def read_motion_key(pane : Symbol, ev : Termisu::Event::Key) : Bool
      pane == :input ? @view.input_read_motion_key(ev) : @view.transcript_motion_key(ev)
    end

    # ---- the editor seam ------------------------------------------------------------------

    def editor_pane? : Bool
      @view.focus == :input
    end

    def editor_enter_insert : Bool
      return false unless editor_pane?
      @view.enter_insert!
      true
    end

    def editor_append_insert : Bool
      return false unless editor_pane?
      @view.input_read_move(0, 1)
      editor_enter_insert
    end

    def editor_exit_insert : Bool
      return false unless editor_pane?
      @view.exit_insert!
      true
    end

    def editor_undo : Bool
      return false unless editor_pane?
      @view.undo
      true
    end

    def editor_to_top : Bool
      if editor_pane?
        @view.input_read_to_edge(-1)
      else
        @view.transcript_move(-@view.pane.size, 0)
      end
      true
    end

    def editor_to_bottom : Bool
      if editor_pane?
        @view.input_read_to_edge(1)
      else
        @view.transcript_move(@view.pane.size, 0)
      end
      true
    end

    def editor_captures_tab? : Bool
      editor_pane? && @view.insert_mode?
    end

    def body_takes_text? : Bool
      editor_captures_tab?
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      return false unless editor_captures_tab?
      @view.insert('\t')
      @view.set_preedit("")
      true
    end

    def accepts_bulk_paste? : Bool
      editor_captures_tab?
    end

    def paste_text(text : String) : Bool
      return false unless @view.paste(text)
      report_replaced(@view.last_replaced)
      true
    end

    def set_preedit(text : String) : Bool
      return false unless editor_captures_tab?
      @view.set_preedit(text)
      true
    end

    # Why a bare `i` does nothing on the transcript — the read-only pane beside an editor, the
    # exact shape `TabController#insert_key_refusal` exists for.
    def insert_key_refusal : String?
      return nil if editor_pane?
      "the transcript is read-only — ↹ to the INPUT pane to type"
    end

    # ---- focus ring ------------------------------------------------------------------------

    def pane_advance(dir : Int32) : Bool
      @view.pane_advance(dir)
    end

    def focus_first : Nil
      @view.focus_first
    end

    def focus_last : Nil
      @view.focus_last
    end

    def focus_resume : Nil
      @view.focus_resume
    end

    # ---- mouse -------------------------------------------------------------------------------

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      @view.handle_click(BodyChrome.frame_inner(rect), mx, my, @session)
      true
    end

    def supports_drag? : Bool
      true
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      @view.handle_drag(BodyChrome.frame_inner(rect), mx, my)
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @view.handle_double_click(BodyChrome.frame_inner(rect), mx, my)
    end

    def handle_wheel(step : Int32) : Bool
      @view.handle_wheel(step)
    end

    def body_scroll(delta : Int32) : Bool
      @view.body_scroll(delta)
    end

    def page_rows : Int32?
      @view.page_rows
    end

    # ---- status strip -------------------------------------------------------------------------

    def body_badge : Symbol
      editor_captures_tab? ? :editor : :body
    end

    def body_pane_label : String?
      @view.focus == :input ? "INPUT" : "TRANSCRIPT"
    end

    def body_hint(focus : Symbol) : String
      return keys("type to edit · {agent.send} send · esc read · ↹ pane · ^Y copy") if editor_captures_tab?
      return input_hint if @view.focus == :input
      keys("↑/↓ scroll · {agent.fold}/↵ fold · {agent.copy} copy · {agent.history} history · ↹ input · space cmds · esc tabs")
    end

    private def input_hint : String
      keys("{editor.insert} edit · ↵ send · {agent.interrupt} stop turn · {agent.history} history · {agent.new} new · ↹ pane · space cmds · esc tabs")
    end

    def goto_symbol : Symbol?
      :agent
    end

    # ---- lifecycle ---------------------------------------------------------------------------

    def on_enter : Nil
      if t = @history
        @view.sync(t)
      elsif s = @session
        @view.sync(s.transcript)
      end
      @view.focus_pane(:input)
    end

    # NOTHING for the live transcript: it is authoritative in memory, and a reload on a peer's
    # `data_version` bump could truncate the turn currently streaming into it (see the class
    # comment, and `Session`'s own PERSISTENCE note).
    def on_external_change : Nil
    end

    # Persist the unsent draft. Only once the conversation has a row — before the first turn
    # there is nothing to attach it to, and the text is still on screen either way.
    def commit : Nil
      return unless s = @session
      return unless id = s.store_id
      @host.session.store.update_agent_session(id, draft: @view.input_text)
    end
  end
end
