require "json"
require "base64"
require "../../repeater/ws_session"

module Gori
  module MCP
    class Tools
      # --- persistent WebSocket sessions (#1630) --------------------------------------------
      #
      # A thin adapter over `Repeater::WsSession`: `ws_session_open` connects through
      # `Plan#open_ws` (the gated door) and registers a job, `ws_session_send` writes on it,
      # `get_job{after}` reads the transcript past a cursor, `stop_job` closes it. The session
      # lives in this process only: a rebind or the server's shutdown closes every one
      # (`close_ws_sessions`), and nothing of it is written to the project.

      # Open sessions this server holds at once. Each is a socket and a reader fiber, and an
      # agent that forgets `stop_job` should hit a sentence, not the fd limit.
      MAX_WS_SESSIONS = 8

      # Transcript rows one `get_job` / `ws_session_send` hands back, at most: the page is also
      # held to REPLY_ROWS_BUDGET (#1649), since one row carries a whole payload. The ring holds
      # up to `WsSession::MAX_ENTRIES`.
      WS_SESSION_PAGE = 200

      # Finished sessions retained before the oldest terminal ones are evicted. Far below the
      # 100 the other kinds keep (`MAX_JOBS_RETAINED`): a terminal session still pins its ring
      # (up to `WsSession::MAX_BYTES`, 8 MiB), so 100 of them could hold ~800 MiB (#1630).
      MAX_WS_JOBS_RETAINED = 16

      # The longest `ws_session_send{wait_ms}`: the server runs one call at a time, so a wait
      # holds every other call behind it.
      WS_SESSION_MAX_WAIT_MS = 30_000_i64

      # The `wait_ms` slice between cancellation checks.
      WS_WAIT_SLICE = 250.milliseconds

      # The longest shutdown waits for the CLOSE handshakes to land — bounded, so a peer that
      # stopped reading cannot hang the process (#1630).
      WS_SHUTDOWN_GRACE = 1.second

      # Close every open session: on a rebind (`bind_project` / `unbind_project`) and at
      # shutdown (`Server#run`). `job.stop` spawns each CLOSE handshake in the background; at
      # shutdown (`wait`) we give them one bounded window to finish, since the process is about
      # to exit and an unwaited spawn would never run its CLOSE. A rebind does not wait: the
      # server keeps running, so the fibers finish on their own.
      def close_ws_sessions(wait : Bool = false) : Nil
        live = @ws_jobs.each_value.select(&.live?).to_a
        live.each(&.stop)
        return unless wait && !live.empty?
        deadline = Time.instant + WS_SHUTDOWN_GRACE
        until live.all?(&.session.closed?) || Time.instant >= deadline
          sleep 20.milliseconds
        end
      end

      # Connect a saved WebSocket repeater and keep the socket open. The handshake takes the
      # same Layer 1 / Layer 2 verdict as `send_websocket` (`ws_gated_plan`), once: every
      # later message rides the socket it admitted.
      @[Tool("ws_session_open", gated: true, agent_action: true, env_refresh: true, permission: "send")]
      private def ws_session_open(h) : Result
        return err("request cancelled", "CANCELLED") if cancelled?
        found = ws_repeater(h)
        return found if found.is_a?(Result)
        repeater_id, repeater = found
        # Before the dial, off the stored bytes: the sender refuses the same handshake after
        # its gate, but an agent should not need a scope verdict to learn it is h2.
        if reason = Repeater::WsSession.refusal(repeater.request)
          return err(reason, "INVALID_ARGUMENT", field: "repeater_id")
        end
        live = @ws_jobs.each_value.count(&.live?)
        # The OAST cap's shape (`oast_start`).
        if live >= MAX_WS_SESSIONS
          return Result.new("too many open WebSocket sessions (#{live}/#{MAX_WS_SESSIONS}); stop_job " \
                            "one before opening another", is_error: true)
        end
        auto_replies = ws_auto_replies(h)
        return auto_replies if auto_replies.is_a?(Result)
        verbatim = bool_arg(h, "verbatim", false)
        keep_key = bool_arg(h, "keep_sec_websocket_key", repeater.ws_keep_key?)
        gated = ws_gated_plan(h, repeater, verbatim)
        return gated if gated.is_a?(Result)
        plan, sc = gated
        return err("request cancelled", "CANCELLED") if cancelled?
        # The per-send Layer-2 re-check: `plan.refusal` is `Outbound#send_block` (Sandbox,
        # with its throttled scope reload), with no budget side effect, so the session can ask
        # it before every frame and honour a Sandbox the operator turns on after the open.
        opened = plan.open_ws(keep_key, auto_replies, cancel_signal, gate: -> { plan.refusal })
        result = opened.result
        target = "#{plan.scheme}://#{plan.host}:#{plan.port}"
        Log.info { "ws_session_open #{target} repeater_id=#{repeater_id} -> #{opened.session ? "open" : result.error}" }
        job = nil.as(WsSessionJob?)
        if session = opened.session
          # A cancel that landed during the dial: the agent will never see this id.
          if cancelled?
            spawn(name: "gori-mcp-ws-close") { session.close }
            return err("request cancelled", "CANCELLED")
          end
          @job_seq += 1
          id = "ws_#{@job_seq}"
          evict_finished_jobs(@ws_jobs, MAX_WS_JOBS_RETAINED)
          job = @ws_jobs[id] = WsSessionJob.new(id, JobAudit.new(target, nil, 1, nil, Time.utc.to_unix_ms),
            @db_path, session, repeater_id, verbatim)
        end
        payload = JSON.build do |j|
          j.object do
            emit_scope(j, sc)
            j.field "job_id", job.id if job
            j.field "repeater_id", repeater_id
            emit_ws_open(j, result, job)
          end
        end
        Result.new(payload, is_error: job.nil?)
      end

      # The handshake half of an `ws_session_open` result: the 101, the note, and — when no
      # session came back — why.
      private def emit_ws_open(j : JSON::Builder, result : Repeater::WsEngine::Result, job : WsSessionJob?) : Nil
        j.field "upgraded", result.upgraded?
        j.field "duration_us", result.duration_us
        if note = result.note
          j.field "note", Env.mask_secrets(note)
        end
        unless result.handshake_head.empty?
          response = Proxy::Codec::Http1.parse_response_head(result.handshake_head) rescue nil
          j.field "handshake_status", response.status if response
        end
        if e = result.error
          kind = network_error_kind(e)
          j.field "error", Env.mask_secrets(e)
          j.field "error_kind", kind
          emit_send_error_code(j, kind, result.answered?)
        elsif job.nil?
          # Answered, but not with a 101: the origin refused the upgrade.
          j.field "error", "the handshake was not upgraded; no session was opened"
        end
      end

      # Write one or more messages on an open session. Returns once they are written, or —
      # with `wait_ms` — once the server sends something back (or the session ends), at most
      # that long. The reply carries every row past the pre-send cursor.
      @[Tool("ws_session_send", gated: true, agent_action: true, env_refresh: true, permission: "send")]
      private def ws_session_send(h) : Result
        job = lookup_job(h, @ws_jobs, "ws_session", "send")
        return job if job.is_a?(Result)
        return Result.new("missing required 'messages'", is_error: true) unless describes?(h, "messages")
        source = ws_call_messages(h)
        return source if source.is_a?(Result)
        wait_ms = optional_int_arg(h, "wait_ms").try(&.clamp(0_i64, WS_SESSION_MAX_WAIT_MS)) || 0_i64
        session = job.session
        before = session.transcript.last?.try(&.seq) || 0_i64
        sent, error, stopped = ws_send_each(session, ws_out_msgs(source, job.verbatim?))
        ws_wait_for_reply(session, before, wait_ms) if wait_ms > 0 && error.nil? && !stopped
        payload = JSON.build do |j|
          j.object do
            j.field "job_id", job.id
            j.field "sent", sent
            j.field "cancelled", true if stopped
            j.field "error", Env.mask_secrets(error) if error
            emit_ws_transcript(j, job, before)
          end
        end
        Result.new(payload, is_error: !error.nil?)
      end

      # Send `msgs` in order: {how many went out, why the next did not, whether a cancel stopped
      # it}. Checked between messages: each write can block for the dial's write timeout on a
      # peer that stopped reading, and this is the single MCP worker. A cancel still answers
      # with what went out, so a retry does not send those messages again.
      private def ws_send_each(session : Repeater::WsSession,
                               msgs : Array(Repeater::WsEngine::OutMsg)) : {Int32, String?, Bool}
        msgs.each_with_index do |m, i|
          return {i, nil, true} if cancelled?
          if error = session.send(m, cancel_signal)
            return {i, error, false}
          end
        end
        {msgs.size, nil, false}
      end

      # Wait up to `wait_ms` for the first server message after `before` that is not a
      # keepalive (a PING or an auto-replied heartbeat is no answer), or until the session ends.
      # Waited in ≤WS_WAIT_SLICE slices so `notifications/cancelled` is honoured within one slice — the single MCP worker is held here, so an uncancellable 30 s wait would
      # wedge every other call behind it (#1630). One waiter per session (`WsSession#wait`).
      private def ws_wait_for_reply(session : Repeater::WsSession, before : Int64, wait_ms : Int64) : Nil
        deadline = Time.instant + wait_ms.milliseconds
        until cancelled? || session.closed? || session.transcript(before).any?(&.reply?)
          left = deadline - Time.instant
          break if left <= Time::Span.zero
          session.wait(left < WS_WAIT_SLICE ? left : WS_WAIT_SLICE)
        end
      end

      # `get_job` for a session: its state and the transcript past `after`.
      private def ws_session_status(h) : Result
        job = lookup_job(h, @ws_jobs, "ws_session", "status")
        return job if job.is_a?(Result)
        after = optional_int_arg(h, "after") || 0_i64
        # `status` first: reading it is what lazily stamps `ended_at_ms` off the session's
        # close time, so a peer close is reported WITH its end time on the very first poll,
        # before `ended_at` below reads it.
        job.status
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", job.id
            j.field "kind", "ws_session"
            j.field "repeater_id", job.repeater_id
            j.field "target", Serialize.text(job.audit.target)
            j.field "started_at", job.audit.started_at_ms
            j.field "ended_at", job.ended_at_ms if job.ended_at_ms
            emit_ws_transcript(j, job, after)
          end
        end)
      end

      # The session's state and one page of rows with `seq > after`, oldest first. `cursor` is
      # the `after` for the next read (the last row sent); `has_more` says a next page is
      # already waiting, and `cut_by: "bytes"` that REPLY_ROWS_BUDGET ended this one (#1649).
      private def emit_ws_transcript(j : JSON::Builder, job : WsSessionJob, after : Int64) : Nil
        session = job.session
        j.field "status", job.status.to_s
        j.field "open", !session.closed?
        session.close_reason.try { |r| j.field "close_reason", Env.mask_secrets(r) }
        session.close_code.try { |c| j.field "close_code", c }
        j.field "dropped", session.dropped if session.dropped > 0
        j.field "keepalive_unrecorded", session.keepalive_unrecorded if session.keepalive_unrecorded > 0
        rows = session.transcript(after)
        page = rows.first(WS_SESSION_PAGE)
        parts = fit_rows(page) { |rj, e, _| emit_ws_message(rj, e.message, seq: e.seq, auto: e.auto) }
        j.field "cursor", parts.empty? ? after : page[parts.size - 1].seq
        j.field "has_more", rows.size > parts.size
        emit_cut(j, parts.size < page.size)
        j.field("messages") { raw_rows(j, parts) }
      end

      # `auto_replies` (exact TEXT match → TEXT reply pairs) plus the `engine_io` preset.
      private def ws_auto_replies(h) : Array(Repeater::WsSession::AutoReply) | Result
        rules = [] of Repeater::WsSession::AutoReply
        rules << Repeater::WsSession::ENGINE_IO_HEARTBEAT if bool_arg(h, "engine_io", false)
        return rules unless describes?(h, "auto_replies")
        arr = h["auto_replies"]?.try(&.as_a?)
        return err("invalid 'auto_replies' (expected an array of {match, reply} objects)", "INVALID_ARGUMENT", field: "auto_replies") unless arr
        arr.each do |item|
          o = item.as_h?
          match = o.try(&.["match"]?).try(&.as_s?)
          reply = o.try(&.["reply"]?).try(&.as_s?)
          unless match && reply && !match.empty?
            return err("invalid 'auto_replies' entry #{item.to_json} (expected {match: non-empty string, reply: string})",
              "INVALID_ARGUMENT", field: "auto_replies")
          end
          rules << Repeater::WsSession::AutoReply.new(match, reply)
        end
        rules
      end

      # Schemas for the two live-session tools (`get_job` / `stop_job` drive them from the
      # shared job registry, so only open and send are declared here).
      private def list_ws_session_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "ws_session_open",
          "Open a PERSISTENT WebSocket session from a saved repeater and keep the socket open " \
          "(#1630): connect once, then ws_session_send one message at a time while the server " \
          "pushes back — unlike send_websocket, which dials, runs a fixed script and hangs up. " \
          "ACTIVE: a real outbound connection, scope-gated like send_websocket. Returns a job_id " \
          "and the handshake result; read server messages with get_job{job_id, after}, send with " \
          "ws_session_send, and close with stop_job (list_jobs lists it). HTTP/1.1 only. The session lives in THIS " \
          "server only and is not written to the project; it is closed on shutdown or a " \
          "switch_project. At most #{MAX_WS_SESSIONS} open at once." do |s|
          s.field "repeater_id", intprop("WebSocket repeater database id (an RFC 6455 Upgrade handshake)"), required: true
          s.field "auto_replies", JSON.parse(%({"type":"array","description":"optional heartbeat auto-replies: for each {match, reply}, an inbound TEXT frame whose payload is EXACTLY 'match' is answered with a TEXT 'reply'. Exact match, because it writes into the session unasked","items":{"type":"object","properties":{"match":{"type":"string"},"reply":{"type":"string"}},"required":["match","reply"]}}))
          s.field "engine_io", boolprop("answer the Engine.IO heartbeat for you: an inbound TEXT '2' (ping) gets a TEXT '3' (pong). Shorthand for one auto_replies pair (default false)")
          s.field "keep_sec_websocket_key", boolprop("send the repeater's OWN Sec-WebSocket-Key instead of a fresh one (default: the repeater's stored setting)")
          s.field "tls_preset", strprop("TLS fingerprint for the handshake: #{Settings::TLS_PRESET_NAMES.join(" | ")} (default: the repeater's stored setting). wss:// only")
          s.field "insecure", boolprop("skip upstream TLS verification (default false)")
          s.field "allow_unscoped", boolprop("connect even when the target host is outside (or without) a configured scope (default false)")
          s.field "verbatim", boolprop("send the handshake, and every later message, EXACTLY: no token expansion in the head or in TEXT payloads (default false)")
        end

        tool j, "ws_session_send",
          "Send one or more messages on an open WebSocket session (from ws_session_open). " \
          "Each entry is a plain string (TEXT), or the object/key=value form send_websocket's " \
          "'messages' takes — binary as base64, a PING, a CLOSE with a chosen code, an unmasked " \
          "or lying-length frame. Returns immediately with the transcript since before the send; " \
          "with wait_ms it waits up to that long for the first server message. Read later " \
          "messages with get_job{job_id, after: cursor}." do |s|
          s.field "job_id", strprop("a ws_session_open job id (ws_*)"), required: true
          s.field "messages", ws_out_messages_prop("the outbound messages to send"), required: true
          s.field "wait_ms", intprop("wait up to this many ms for a server message before returning (0-#{WS_SESSION_MAX_WAIT_MS}; default 0, return at once)")
        end
      end
    end
  end
end
