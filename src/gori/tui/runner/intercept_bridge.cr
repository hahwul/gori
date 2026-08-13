# The #123 live-intercept bridge: the capture-lock holder mirrors its held queue into the
# Store so a separate `gori mcp` process can see and decide on it — reopens
# Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays, and
# rendering). Commands arrive as Store rows and are applied on the shell's own fiber.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- #123 live-intercept bridge (capture-lock holder publishes for the MCP process) ------

  # Mirror the currently-held intercept queue into the store so the separate `gori mcp`
  # process can list/get held items. Called only when the queue changed (revision) and only
  # in the lock holder. Maps each in-memory Item to a HeldRow (wall-clock held_at_ms so the
  # MCP-side age is stable across republishes).
  private def publish_intercept_snapshot(ic : Interceptor) : Nil
    token = @session.intercept_token
    rows = ic.pending.map do |it|
      # `edit_refusal`/`head_only` ride along so the MCP process and `gori run intercept
      # get`/`list` can say "edits cannot be applied to this message" BEFORE one is written.
      # They are known at hold time and were dropped here, which is why every cross-process
      # surface described a CRLF-carrying h2 message as ordinarily editable.
      Store::HeldRow.new(token, it.id, it.kind.to_s.downcase, it.method, it.host, it.port,
        it.scheme, it.target, it.raw, it.held_at_ms, it.flow_id, false, 0_i64,
        it.edit_refusal, it.head_only?, it.binary?)
    end
    @session.store.publish_intercept_held(token, rows)
  end

  # Drain agent-written intercept commands past the watermark and apply each to the live
  # interceptor exactly once (ascending id). Runs ONLY in the lock holder (caller-gated).
  # A command whose session_token != ours targets a prior session's item ids → acked stale,
  # never applied. Returns true if any command was applied (forces a re-render). #123 Phase 2.
  private def drain_intercept_commands : Bool
    store = @session.store
    cmds = store.intercept_commands_after(@intercept_cmd_watermark, 50)
    return false if cmds.empty?
    ic = @session.interceptor
    applied = false
    cmds.each do |cmd|
      @intercept_cmd_watermark = cmd.id # exactly-once: advance even for stale/failed commands
      if cmd.session_token != @session.intercept_token
        store.ack_intercept_command(cmd.id, "stale", "command targeted a previous capture session")
        next
      end
      @intercept_agent_seen = true # a command for OUR session ⇒ an agent is/was here
      applied = true if apply_intercept_command(ic, store, cmd)
    end
    applied
  end

  # Apply one agent command to the live interceptor and ack the outcome. forward/drop
  # self-guard (a no-longer-held id is a no-op), so we look the item up first to (a) ack
  # no_such_item precisely and (b) describe the action in the visible agent Note.
  private def apply_intercept_command(ic : Interceptor, store : Store, cmd : Store::CommandRow) : Bool
    case cmd.verb
    when "forward", "drop", "forward_edit"
      item_id = cmd.item_id
      unless item_id
        store.ack_intercept_command(cmd.id, "error", "#{cmd.verb} missing item_id"); return false
      end
      item = ic.get(item_id)
      unless item
        store.ack_intercept_command(cmd.id, "no_such_item", "item #{item_id} is no longer held")
        return false
      end
      # `Item#label` composes per kind. The one expression that used to live here glued
      # `host` onto `target`, and `target` is overloaded per kind — so a held response acked
      # as `POST 127.0.0.1200 OK` (reads as HTTP status 1200) and a proxied h1 request as
      # `POST 127.0.0.1http://127.0.0.1:19201/held`. This string is the agent's only receipt
      # for an irreversible action.
      desc = item.label
      case cmd.verb
      when "forward"
        # The store's ack is the agent's only record, so it reports what actually happened:
        # `forward` is false when somebody else settled the item first (the operator's own
        # decision, `forward_all`, the reaper), and acking "forwarded" for that is the same
        # silent-no-op class the rest of this batch removed.
        unless ic.forward(item_id)
          store.ack_intercept_command(cmd.id, "error", "already decided by another surface: #{desc}")
          return false
        end
        store.ack_intercept_command(cmd.id, "forwarded", desc)
        push_agent_note(:success, "forwarded #{desc}", item)
      when "drop"
        # Same claim `forward` above makes, for the same reason: `drop` is a no-op on an item
        # somebody else settled first, and the h2/WS gates fail a hold OPEN from a PROXY fiber
        # (buffer ceiling, RST_STREAM, teardown) concurrently with this one. Acking "dropped"
        # there tells the agent gori blocked a message that is already on the wire.
        unless ic.drop(item_id)
          store.ack_intercept_command(cmd.id, "error", "already decided by another surface: #{desc}")
          return false
        end
        store.ack_intercept_command(cmd.id, "dropped", desc)
        push_agent_note(:warn, "dropped #{desc}", item)
      when "forward_edit"
        bytes = cmd.bytes
        unless bytes
          store.ack_intercept_command(cmd.id, "error", "forward_edit missing bytes"); return false
        end
        # An edit gori will not apply is REFUSED HERE, at the surface that asked for it, and
        # the item stays held so the operator can forward it, drop it, or edit it again.
        #
        # Both refusals are decided by the settle side (`H2::StreamGate` / `HeadRewrite`) and
        # used to be discovered there, on the gate's wait fiber, with no path back — the ack
        # two lines below had already gone out saying "edited". On an h2 message whose head
        # has no HTTP/1.1 text form that meant gori accepted every edit and applied none,
        # which is exactly the state a CRLF-injection probe INDUCES. Both facts are pure
        # functions of the held block, so they are known at hold time and readable here.
        if refusal = item.refuse_edit(bytes)
          store.ack_intercept_command(cmd.id, "error", "edit refused (#{desc} is still held) — #{refusal}")
          push_agent_note(:warn, "intercept edit REFUSED, still held: #{desc}", item)
          return false
        end
        # Forward the AGENT's edited bytes DIRECTLY — never through view.forward_bytes, which
        # would pull the human editor buffer and re-expand $VARS (wrong bytes + secret leak).
        unless ic.forward(item_id, bytes)
          store.ack_intercept_command(cmd.id, "error", "already decided by another surface: #{desc}")
          return false
        end
        # `size: bytes.size`, NOT `desc`'s default (the item's ORIGINAL held size): an edit
        # that changes a WS message's length must say so in its own ack, the caller's only
        # record of what actually went out. Has no effect on a request/response label (that
        # branch of `Item#label` doesn't render a byte count), so this is safe for every kind.
        edited_desc = item.label(size: bytes.size)
        store.ack_intercept_command(cmd.id, "edited", edited_desc)
        push_agent_note(:success, "forwarded (edited) #{edited_desc}", item)
      end
      true
    when "toggle"
      # Desired-state (idempotent): flip only if current != requested, so a re-applied command
      # can't oscillate. NOTE: enabling only affects NEW connections (h2→h1 downgrade gate).
      want = cmd.arg == "true"
      ic.toggle if ic.enabled? != want
      store.ack_intercept_command(cmd.id, "toggled", "enabled=#{ic.enabled?}")
      push_config_note("agent #{ic.enabled? ? "enabled" : "disabled"} intercept")
      true
    when "set_filter"
      q = cmd.arg || ""
      ic.set_filter(q)
      store.ack_intercept_command(cmd.id, "filter_set", q.empty? ? "(cleared)" : q)
      push_config_note(q.empty? ? "agent cleared intercept filter" : "agent set intercept filter: #{q}")
      true
    when "set_direction"
      dir = case cmd.arg
            when "request"  then Interceptor::Direction::RequestOnly
            when "response" then Interceptor::Direction::ResponseOnly
            else                 Interceptor::Direction::Both
            end
      ic.set_direction(dir)
      store.ack_intercept_command(cmd.id, "direction_set", dir.to_s.downcase)
      push_config_note("agent set intercept direction: #{dir.to_s.downcase}")
      true
    else
      store.ack_intercept_command(cmd.id, "error", "unknown verb #{cmd.verb}")
      false
    end
  end

  # An agent config action (toggle/filter/direction) has no held item, so it jumps to the
  # intercept tab rather than a flow.
  private def push_config_note(msg : String) : Nil
    @notifications.push(:info, msg, Jobs::Goto.new(:intercept), source: "agent")
  end

  # #123 safety net: auto-forward (original bytes, fail-open) any item held past max_hold that
  # NOBODY is watching — neither the human (not on the intercept tab) nor an agent (no recent
  # MCP intercept_list/get, tracked via viewed_ms). hold() has no timeout, so this stops a dead
  # MCP client from wedging a proxy connection forever. CRITICAL: only fires in a session where
  # an agent has actually attached (@intercept_agent_seen) — a pure-human session keeps the base
  # P4 contract (indefinite hold). Disabled when @intercept_max_hold_ms <= 0. Returns true if
  # anything was released.
  private def reap_stale_holds : Bool
    return false if @intercept_max_hold_ms <= 0
    return false if @active_tab == :intercept # human is watching the queue → never clobber
    ic = @session.interceptor
    pending = ic.pending
    return false if pending.empty?
    # `intercept_viewed_ms`, NOT `intercept_held`: this runs on the 750ms cross-process cadence
    # for as long as anything is held, and the full row carries the held `raw` BLOB — a held
    # multi-MiB response was being read out of SQLite and copied more than once a second to
    # answer a question that is one Int64 per row.
    viewed = @session.store.intercept_viewed_ms(@session.intercept_token)
    @intercept_agent_seen = true if viewed.each_value.any? { |v| v > 0 } # an agent polled the queue
    return false unless @intercept_agent_seen                            # no agent ever attached → P4: hold indefinitely
    now_ms = Time.utc.to_unix_ms
    reaped = false
    pending.each do |it|
      watched = {it.held_at_ms, viewed[it.id]? || 0_i64}.max
      next if now_ms - watched < @intercept_max_hold_ms
      # original bytes (fail-open), same as toggle-off / release_all. A false answer means
      # the operator decided it in the same tick — say nothing rather than claim a reap.
      next unless ic.forward(it.id)
      secs = @intercept_max_hold_ms // 1000
      goto = (fid = it.flow_id) ? Jobs::Goto.new(:history, fid) : nil
      @notifications.push(:warn, "auto-forwarded held #{it.label} (no decision after #{secs}s)", goto, source: "app")
      reaped = true
    end
    reaped
  end

  # Surface an agent intercept action in the human notification center (source :agent, so it
  # renders distinctly). A held response jumps to its captured flow; a held request (no flow
  # row yet) jumps to the intercept queue.
  private def push_agent_note(level : Symbol, msg : String, item : Interceptor::Item) : Nil
    goto = (fid = item.flow_id) ? Jobs::Goto.new(:history, fid) : Jobs::Goto.new(:intercept)
    @notifications.push(level, msg, goto, source: "agent")
  end

  # Refresh the bridge blob (config mirror + liveness heartbeat). Tiny single-row upsert kept
  # fresh every cross-process cadence so a mutating MCP verb can refuse when no live holder.
  private def publish_intercept_bridge(ic : Interceptor) : Nil
    json = JSON.build do |j|
      j.object do
        j.field "session_token", @session.intercept_token
        j.field "capturing", true
        j.field "enabled", ic.enabled?
        j.field "direction", ic.direction.to_s.downcase
        j.field "filter", ic.filter_source
        j.field "pending_count", ic.pending_count
        j.field "heartbeat_ms", Time.utc.to_unix_ms
      end
    end
    @session.store.set_intercept_bridge(json)
  end
end
