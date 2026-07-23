require "json"
require "base64"
require "../../store"
require "../serialize"
require "../../proxy/codec/http1"

module Gori
  module MCP
    class Tools
      private def list_scope : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field "enabled", Scope.load(store).enabled?
            j.field "rules" do
              j.array do
                store.scope_rules.each do |(id, kind, match_type, pattern)|
                  j.object do
                    j.field "id", id
                    j.field "kind", kind
                    j.field "match_type", match_type
                    j.field "pattern", pattern
                  end
                end
              end
            end
          end
        end)
      end

      private def project_info : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field "bound", !unbound?
            j.field "project", @project_name
            j.field "project_slug", @project_slug
            j.field "project_id", @project_id
            j.field "db_path", @db_path
            j.field "selection_source", @selection_source
            j.field "workspace_root", @workspace_root
            j.field "workspace_bound", !@workspace_root.nil?
            j.field "read_only", !@allow_actions
            if s = @store
              j.field "flows", s.count
              j.field "issues", s.count_issues
              j.field "total_bytes", s.total_size
              j.field "earliest_created_at", s.earliest_created_at
              if ea = s.earliest_created_at
                j.field "earliest_created_at_iso", Serialize.unix_micros_iso(ea)
              end
            else
              j.field "note", "No project bound. Call list_projects, create_project, or switch_project before traffic tools."
            end
          end
        end)
      end

      # What the user is currently viewing in the gori TUI, recorded cross-process to the
      # project store (Store::UI_STATE_KEY) by the running TUI. Read-only. The ui-state lives in
      # THIS project's db, so it always describes this project — freshness is reported via
      # age_seconds (there is no live-TUI heartbeat), not a name comparison that would skew on
      # display-name-vs-slug.
      private def get_current_context : Result
        raw = store.setting(Store::UI_STATE_KEY)
        parsed = raw.try do |r|
          begin
            obj = JSON.parse(r)
            # Must decode to a JSON OBJECT: valid-but-wrong-shape JSON (an array,
            # scalar, or null) would make `parsed["active_tab"]?` below raise a raw
            # "Expected Hash for #[]?" cast error — treat it as unreadable instead.
            obj if obj.as_h?
          rescue
            nil
          end
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "project", @project_name # the project/db this server serves
            if parsed.nil?
              j.field "available", false
              j.field "note", raw.nil? ? "No UI state recorded for this project — the gori TUI may not have run against it." : "Recorded UI state was unreadable."
            else
              j.field "available", true
              j.field "project", @project_name
              j.field "project_slug", @project_slug
              j.field "project_id", @project_id
              j.field "active_tab", parsed["active_tab"]?.try(&.as_s?)
              j.field "focus_pane", parsed["focus_pane"]?.try(&.as_s?)
              if fid = parsed["selected_flow_id"]?.try(&.as_i64?)
                j.field "selected_flow_id", fid
              end
              if st = parsed["subtab"]?.try(&.as_i64?)
                j.field "subtab", st
              end
              if rec = parsed["recorded_at"]?.try(&.as_i64?)
                j.field "recorded_at", rec
                # A corrupt/out-of-range recorded_at must not sink the whole tool: Time.unix_ms
                # raises on out-of-range, so guard it — keep the raw value, drop derived fields.
                iso = begin
                  Time.unix_ms(rec).to_rfc3339
                rescue
                  nil
                end
                if iso
                  j.field "recorded_at_iso", iso
                  j.field "age_seconds", (Time.utc.to_unix_ms - rec) // 1000
                end
              end
            end
          end
        end)
      end

      private def get_repeater_context(h) : Result
        ui = parse_ui_state
        repeater_id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) if repeater_id.nil? && present?(h, "id")
        include_content = bool(h, "include_content")
        if include_content.nil? && present?(h, "include_content")
          return Result.new("invalid 'include_content' (expected true or false)", is_error: true)
        end
        include_content = include_content || false
        include_sensitive = bool(h, "include_sensitive") || false
        req_lim = int(h, "limit")
        req_off = int(h, "offset")
        limit = clamp(req_lim, 50, 500)
        offset = clamp_nonneg(req_off)
        query_str = str(h, "query").try(&.strip)
        query_rx = query_str.try { |q| q.empty? ? nil : Regex.new(Regex.escape(q), Regex::Options::IGNORE_CASE) }

        all_repeaters = store.repeaters_mcp
        if repeater_id && !all_repeaters.any? { |r| r.id == repeater_id }
          return not_found("no repeater with id #{repeater_id}")
        end
        all_repeaters = all_repeaters.select { |r| r.id == repeater_id } if repeater_id

        filtered_repeaters = if rx = query_rx
                               all_repeaters.select do |r|
                                 # scrub: target/name/request can be invalid UTF-8 (seeded from a
                                 # captured request without scrubbing); an unscrubbed matches? raises
                                 # and fails the WHOLE list_repeaters response whenever a query filter
                                 # meets any such repeater. Scrub is lossless for a filter match.
                                 r.target.scrub.matches?(rx) ||
                                   r.name.try(&.scrub.matches?(rx)) ||
                                   String.new(r.request).scrub.matches?(rx)
                               end
                             else
                               all_repeaters
                             end

        total_count = filtered_repeaters.size
        paginated_repeaters = if offset >= filtered_repeaters.size
                                [] of Store::RepeaterRecord
                              else
                                filtered_repeaters[offset, Math.min(limit, filtered_repeaters.size - offset)]
                              end

        Result.new(JSON.build do |j|
          j.object do
            j.field "project", @project_name
            j.field "project_slug", @project_slug
            j.field "db_path", @db_path
            on_repeater = ui.try { |u| u["active_tab"]?.try(&.as_s?) == "repeater" } || false
            j.field "tui_on_repeater_tab", on_repeater
            if ui
              if rec = ui["recorded_at"]?.try(&.as_i64?)
                j.field "ui_recorded_at", rec
                iso = begin
                  Time.unix_ms(rec).to_rfc3339
                rescue
                  nil
                end
                if iso
                  j.field "ui_recorded_at_iso", iso
                  j.field "ui_age_seconds", (Time.utc.to_unix_ms - rec) // 1000
                end
              end
              if include_content && (repeater = ui["repeater"]?)
                j.field "tui_repeater", repeater
              elsif ui["repeater"]?
                j.field "tui_repeater_available", true
              end
            end
            j.field "content_included", include_content
            j.field "sensitive_headers_redacted", !include_sensitive if include_content
            j.field "total_count", total_count
            j.field "offset", offset
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "has_more", offset + paginated_repeaters.size < total_count
            j.field "sessions" do
              j.array do
                paginated_repeaters.each do |r|
                  emit_repeater_session(j, r, include_content, include_sensitive)
                end
              end
            end
            unless on_repeater
              j.field "note", "TUI is not on the Repeater tab — `tui_repeater` may be stale; use `sessions` for persisted tabs."
            end
          end
        end)
      end

      private def emit_repeater_sessions(j : JSON::Builder, include_content : Bool = false,
                                         include_sensitive : Bool = false) : Nil
        store.repeaters_mcp.each do |r|
          emit_repeater_session(j, r, include_content, include_sensitive)
        end
      end

      private def emit_repeater_session(j : JSON::Builder, r : Store::RepeaterRecord,
                                        include_content : Bool = false,
                                        include_sensitive : Bool = false) : Nil
        j.object do
          j.field "db_id", r.id
          j.field "position", r.position
          j.field "target", r.target
          j.field "http2", r.http2?
          j.field "auto_content_length", r.auto_content_length?
          j.field "flow_id", r.flow_id if r.flow_id
          j.field "name", r.name if r.name
          j.field "sni", r.sni if r.sni
          r_request_text = String.new(r.request).scrub
          emit_capped_text(j, "request", Serialize.redact_head(r_request_text, include_sensitive)) if include_content

          if Repeater::WsEngine.upgrade_request?(r_request_text)
            ws_msgs = store.ws_messages_for_repeater(r.id)
            j.field "ws_mode", true
            j.field "ws_message_count", ws_msgs.size
            j.field "ws_messages" do
              j.array do
                ws_msgs.each do |m|
                  j.object do
                    j.field "direction", m.direction
                    j.field "opcode", m.opcode
                    j.field "type", Serialize.ws_frame_type(m.opcode)
                    j.field "at", m.created_at
                    if m.text?
                      j.field "payload", String.new(m.payload).scrub
                    else
                      # A binary frame carries arbitrary octets; emitting them as a raw
                      # string would put invalid UTF-8 on the stdio JSON-RPC stream (which
                      # must be well-formed UTF-8). Base64 it, like Serialize.emit_ws_messages.
                      j.field "binary", true
                      j.field "payload_base64", Base64.strict_encode(m.payload)
                    end
                  end
                end
              end
            end if include_content
          end

          if err = r.response_error
            j.field "last_error", err
          end
          if d = r.response_duration_us
            j.field "last_duration_us", d
          end
          if head = r.response_head
            resp = begin
              Proxy::Codec::Http1.parse_response_head(head)
            rescue
              nil
            end
            if resp
              j.field "last_status", resp.status
              j.field "last_reason", resp.reason
            end
            j.field "last_response_head", Serialize.redact_head_opt(Serialize.head_text(head), include_sensitive) if include_content
          end
        end
      end

      private def emit_capped_text(j : JSON::Builder, field : String, text : String) : Nil
        if text.bytesize > MCP_REPEATER_REQUEST_MAX
          # Compare and cut by BYTES (the cap is a byte budget), then scrub — a slice
          # through a multi-byte UTF-8 sequence would otherwise emit invalid UTF-8 into
          # the JSON-RPC stream, which must be well-formed UTF-8 over the stdio transport.
          j.field field, text.byte_slice(0, MCP_REPEATER_REQUEST_MAX).scrub
          j.field "#{field}_truncated", true
        else
          # Scrub here too: a repeater request built from a binary/non-UTF-8 body round-trips
          # invalid UTF-8 through the store, and JSON::Builder emits it verbatim — which
          # corrupts the stdio JSON-RPC stream (must be well-formed UTF-8).
          j.field field, text.scrub
        end
      end

      private def parse_ui_state : JSON::Any?
        store.setting(Store::UI_STATE_KEY).try do |r|
          begin
            obj = JSON.parse(r)
            obj if obj.as_h?
          rescue
            nil
          end
        end
      end
    end
  end
end
