require "json"
require "../../store"
require "../../oast"
require "../../oast/sessions"

module Gori
  module MCP
    class Tools
      # PERSISTED OAST sessions — the rows behind the TUI's RESUME LISTENER picker.
      #
      # `oast_start` mints an ad-hoc registration that dies with this process. The callbacks
      # that matter most arrive late (a stored payload that fires when someone opens a
      # back-office page, a webhook a nightly job replays), so a project keeps its
      # registrations, and these three tools let an agent list, re-arm and let go of the same
      # rows the TUI does. A resumed handle is a project listener: `oast_poll` PERSISTS what it
      # catches, so the tab and the agent are reading one table.
      #
      # Nothing here resumes on its own. Binding a project starts no listener (P4) — an agent
      # asks for a session back explicitly, exactly as the operator presses `r`.
      private def list_oast_sessions(h) : Result
        sessions = Oast::Sessions.list(store)
        # Which of them THIS process is polling, and under which ephemeral handle — the
        # oast_poll/oast_payload id, so an agent that resumed earlier in the conversation can
        # find its way back without a second resume.
        handles = {} of Int64 => String
        @oast_mcp.each { |sid, s| s.store_session_id.try { |row| handles[row] = sid } }
        Result.new(JSON.build do |j|
          j.object do
            j.field("sessions") do
              j.array do
                sessions.each do |s|
                  j.object do
                    j.field "id", s.id
                    j.field "provider", s.provider
                    j.field "provider_id", s.provider_key # scope-qualified, nil when it is gone
                    j.field "kind", s.kind
                    j.field "payload_host", s.payload_host
                    j.field "server_url", s.server_url
                    j.field "hits", s.hits
                    j.field "created_at", s.created_at.to_rfc3339
                    j.field "last_poll_at", s.last_poll_at.try(&.to_rfc3339)
                    # No `secret`, no `private_key_pem`, no provider token: a session list is
                    # printed and handed to an agent, and the credentials that decrypt its
                    # callbacks stay in the row (same stance as list_oast_providers' tokens).
                    j.field "session_id", handles[s.id]?
                  end
                end
              end
            end
            j.field "total", sessions.size
          end
        end)
      end

      private def oast_resume(h) : Result
        row = oast_session_row(h)
        return row if row.is_a?(Result)
        # Already resumed in this process: hand back the SAME handle rather than arming a
        # second poller on one correlation id (the MCP twin of the controller's one-listener
        # -per-provider invariant).
        if live = @oast_mcp.find { |_, s| s.store_session_id == row }
          sid, s = live
          return Result.new({session_id: sid, store_session_id: row, provider: s.kind_label,
                             payload_url: s.provider.generate_payload(s.session),
                             hits: store.oast_callback_count(row), resumed: false}.to_json)
        end
        if @oast_mcp.size >= MAX_OAST_SESSIONS
          return Result.new("too many active OAST sessions (#{@oast_mcp.size}/#{MAX_OAST_SESSIONS}); call oast_stop on one before resuming another", is_error: true)
        end
        bound = Oast::Sessions.bind(store, row)
        return oast_session_problem(bound, row) if bound.is_a?(Oast::Sessions::Problem)

        http = Oast::HttpClient.new(@verify_upstream)
        begin
          Oast::Sessions.resume(bound, http)
        rescue ex
          # `Provider#resume` raises deliberately (unlike `deregister`): a resume that failed
          # quietly would leave a handle polling a correlation id the server never heard of.
          return Result.new("OAST resume failed: #{ex.message}", is_error: true)
        end
        sid = "oast_#{Random::Secure.hex(8)}"
        s = OastMcpSession.new(bound.provider, bound.session, http, bound.session.kind.label, row)
        # Seed the dedup set from what the row already holds, so a provider that replays its
        # whole buffer on a poll does not re-announce every callback already on file.
        Oast::Sessions.seen_uids(store, row).each { |uid| s.seen << uid }
        @oast_mcp[sid] = s
        # Mark it live NOW: `OutOfBand::StoreMinter` mints out-of-band probe payloads against
        # the most-recently-POLLED session, and this one is about to be polled.
        store.touch_oast_session(row)
        Result.new({session_id: sid, store_session_id: row, provider: bound.session.kind.label,
                    payload_url: bound.provider.generate_payload(bound.session),
                    hits: store.oast_callback_count(row), resumed: true}.to_json)
      end

      # Deregister the session's SERVER-side state. The row and every callback it collected
      # stay — this releases the listener, not the evidence.
      private def oast_release(h) : Result
        row = oast_session_row(h)
        return row if row.is_a?(Result)
        bound = Oast::Sessions.bind(store, row)
        return oast_session_problem(bound, row) if bound.is_a?(Oast::Sessions::Problem)
        # Drop a live handle on it first: after the deregister its correlation id is dead, so
        # leaving one pollable would answer an agent with an endless empty poll.
        if live = @oast_mcp.find { |_, s| s.store_session_id == row }
          @oast_mcp.delete(live[0])
        end
        Oast::Sessions.release(bound, Oast::HttpClient.new(@verify_upstream))
        Result.new({released: row, callbacks_kept: store.oast_callback_count(row)}.to_json)
      end

      # The `oast_sessions` row id an argument names: `7`, or the `#7` the TUI and
      # `gori run oast list` print.
      private def oast_session_row(h) : Int64 | Result
        id = int(h, "id") || str(h, "id").try { |t| Oast::Sessions.parse_id(t) }
        return err("missing or malformed 'id' (a session id from list_oast_sessions)",
          "INVALID_ARGUMENT", field: "id") unless id && id > 0
        id
      end

      private def oast_session_problem(problem : Oast::Sessions::Problem, row : Int64) : Result
        msg = Oast::Sessions.message_for(problem, row)
        case problem
        in .missing?      then not_found(msg)
        in .unknown_kind? then err(msg, "INVALID_ARGUMENT", field: "id")
        end
      end

      private def list_oast_sessions_tools(j : JSON::Builder) : Nil
        tool j, "list_oast_sessions",
          "List the PERSISTED OAST listening sessions of this project — the rows behind the " \
          "TUI's RESUME LISTENER picker, as opposed to the ad-hoc registrations oast_start " \
          "mints. Each has its payload host, how many callbacks it has collected, and when it " \
          "was last polled. `session_id` is non-null when this server is already polling it." { }

        return unless @allow_actions

        tool j, "oast_resume",
          "Re-arm a persisted OAST session so its ALREADY-PLANTED payloads keep resolving, and " \
          "return a {session_id} for oast_poll / oast_payload. Use for callbacks that arrive " \
          "late (a stored payload, a nightly job). Unlike oast_start, a resumed session's " \
          "callbacks are PERSISTED into the project, so the TUI sees the same hits." do |s|
          s.field "id", strprop("persisted session id from list_oast_sessions"), required: true
        end

        tool j, "oast_release",
          "Deregister a persisted OAST session server-side, for a finished engagement. Its " \
          "stored callbacks stay; payloads minted from it stop resolving. To merely stop " \
          "polling and keep it resumable, call oast_stop instead." do |s|
          s.field "id", strprop("persisted session id from list_oast_sessions"), required: true
        end
      end
    end
  end
end
