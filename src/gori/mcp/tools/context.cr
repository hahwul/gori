require "json"
require "base64"
require "../../store"
require "../serialize"
require "../../proxy/codec/http1"

module Gori
  module MCP
    class Tools
      @[Tool("list_scope")]
      private def list_scope : Result
        scope = Scope.load(store)
        Result.new(JSON.build do |j|
          j.object do
            j.field "enabled", scope.enabled?
            j.field "sandbox", scope.sandbox?
            # The state `set_sandbox` and `delete_scope_rule` both report on the WRITE that
            # causes it. Reading it back was the one place it disappeared: `sandbox: true` beside
            # three exclude rules is a proxy refusing every captured request, and nothing in this
            # payload said so — a caller would have to know that the allowlist deliberately reads
            # an empty include set as "block all" rather than "allow all" to derive it.
            j.field "blocks_all", scope.sandbox? && scope.include_count.zero?
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

      @[Tool("project_info", unbound: true)]
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
            elsif reason = @bind_error
              # Unbound because the configured project FAILED to open, not because none was
              # chosen. project_info is the tool an agent calls to orient itself, so the
              # distinction (and the reason) belongs in its answer as a field, not only in
              # the prose note.
              j.field "bind_error", reason
              j.field "note", "The configured project could not be opened (#{reason}). " \
                              "Call list_projects, then switch_project or create_project."
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
      @[Tool("get_current_context")]
      private def get_current_context : Result
        raw = store.setting(Store::UI_STATE_KEY)
        parsed = raw.try do |r|
          obj = JSON.parse(r)
          # Must decode to a JSON OBJECT: valid-but-wrong-shape JSON (an array,
          # scalar, or null) would make `parsed["active_tab"]?` below raise a raw
          # "Expected Hash for #[]?" cast error — treat it as unreadable instead.
          obj if obj.as_h?
        rescue
          nil
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "project", @project_name # the project/db this server serves
            if parsed.nil?
              j.field "available", false
              j.field "note", raw.nil? ? "No UI state recorded for this project — the gori TUI may not have run against it." : "Recorded UI state was unreadable."
            else
              j.field "available", true
              # NB: "project" is emitted once, above this branch — repeating it here put a
              # DUPLICATE key in the object (first/last-wins varies by parser, strict ones
              # reject it). Only the slug/id belong in the available branch.
              j.field "project_slug", @project_slug
              j.field "project_id", @project_id
              j.field "active_tab", parsed["active_tab"]?.try(&.as_s?)
              j.field "focus_pane", parsed["focus_pane"]?.try(&.as_s?)
              # Whether the window that recorded this was the one holding capture. A view-only
              # window publishes only when no UI-bearing holder is (Runner#may_publish_ui_state?),
              # which is the common `gori run capture` + TUI deployment — so `false` is a normal
              # answer, not a degraded one. Omitted for a row written before this field existed,
              # where "unknown" is the honest reading rather than a guessed `false`.
              # `.nil?`, never a truthiness test: `false` is the answer this field exists to
              # carry, and `if hc = ...` would drop exactly that case on the floor.
              hc = parsed["holds_capture"]?.try(&.as_bool?)
              j.field "holds_capture", hc unless hc.nil?
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

      # `query` (substring) and `filter` (the sub-tab language) applied together — both must
      # match, the way `list_history{view}` ANDs with its own `query` rather than replacing it.
      private def repeater_narrow(rows : Array(Store::RepeaterRecord), rx : Regex?,
                                  filter : Repeater::SubtabFilter?) : Array(Store::RepeaterRecord)
        if rx
          rows = rows.select do |r|
            # scrub: target/name/request can be invalid UTF-8 (seeded from a captured request
            # without scrubbing); an unscrubbed matches? raises and fails the WHOLE response
            # whenever a query meets any such repeater. Scrub is lossless for a filter match.
            r.target.scrub.matches?(rx) ||
              r.name.try(&.scrub.matches?(rx)) ||
              String.new(r.request).scrub.matches?(rx)
          end
        end
        return rows unless (f = filter) && !f.empty?
        rows.select { |r| f.matches?(Repeater::SubtabFilter::Subject.from_row(r)) }
      end

      # The `filter` argument, compiled by the ONE matcher the TUI's `/` uses, or the Result
      # that refuses it. An unparseable filter is REPORTED — a listing that answered "no such
      # sessions" for a syntax error would read as a finding about the workbench.
      private def repeater_filter_arg(text : String) : Repeater::SubtabFilter | Result
        Repeater::SubtabFilter.parse(text)
      rescue ex
        err("invalid 'filter': #{ex.message}. Fields are " \
            "#{Repeater::SubtabFilter::FIELDS.map { |x| "#{x}:" }.join(" ")}; " \
            "a bare word searches name/summary/target/tags",
          "QUERY_SYNTAX", field: "filter")
      end

      @[Tool("get_repeater_context")]
      private def get_repeater_context(h) : Result
        ui = parse_ui_state
        repeater_id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) if repeater_id.nil? && present?(h, "id")
        include_content = bool_arg(h, "include_content", false)
        include_sensitive = bool_arg(h, "include_sensitive", false)
        req_lim = optional_int_arg(h, "limit")
        req_off = optional_int_arg(h, "offset")
        limit = clamp(req_lim, 50, 500)
        offset = clamp_nonneg(req_off)
        query_str = str(h, "query").try(&.strip)
        query_rx = query_str.try { |q| q.empty? ? nil : Regex.new(Regex.escape(q), Regex::Options::IGNORE_CASE) }
        include_response_body = bool_arg(h, "include_response_body", false)
        req_body_cap = optional_int_arg(h, "max_body_bytes")
        body_cap = clamp(req_body_cap, MCP_REPEATER_BODY_DEFAULT, MCP_REPEATER_BODY_MAX)

        # The sub-tab filter the operator types into the TUI's `/`, over the SAME grammar
        # (`tag:` `name:` `host:`/`target:` `method:`/`verb:` `status:`, `-` to negate, bare
        # words as free text). ANDed with `query` rather than replacing it, the way
        # `list_history{view}` is ANDed with its own — two narrowings are two narrowings.
        filter_str = str(h, "filter").try(&.strip).presence
        filter = filter_str.try { |f| repeater_filter_arg(f) }
        return filter if filter.is_a?(Result)

        ordered = store.repeaters_mcp
        # The chip number is a rank in the WHOLE workbench, so it is taken here — before the
        # id lookup, the query and the filter each narrow the list. Deriving it from the
        # returned page instead would renumber the tabs a filter happened to keep, which is
        # exactly what the TUI's own strip refuses to do (`Chrome.chip_zones`: a filtered
        # strip reads 2, 5, 7).
        tui_index = {} of Int64 => Int32
        ordered.each_with_index { |r, i| tui_index[r.id] = i + 1 }

        all_repeaters = ordered
        if repeater_id && !all_repeaters.any? { |r| r.id == repeater_id }
          return not_found("no repeater with id #{repeater_id}")
        end
        all_repeaters = all_repeaters.select { |r| r.id == repeater_id } if repeater_id

        filtered_repeaters = repeater_narrow(all_repeaters, query_rx, filter)

        total_count = filtered_repeaters.size
        paginated_repeaters = if offset >= filtered_repeaters.size
                                [] of Store::RepeaterRecord
                              else
                                filtered_repeaters[offset, Math.min(limit, filtered_repeaters.size - offset)]
                              end

        # Response bodies are the one field on this tool that costs a BLOB read per row
        # (`repeaters_mcp` deliberately leaves `response_body` out), so they are hydrated for
        # a bounded head of the page and the shortfall is NAMED. Silently dropping them for
        # rows 11+ would read as "those tabs have no body".
        body_ids = if include_response_body
                     paginated_repeaters.first(MCP_REPEATER_BODY_ROWS).map(&.id).to_set
                   else
                     Set(Int64).new
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
                emit_tui_repeater(j, repeater, include_sensitive)
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
            # A filter string whose every term was dropped narrows NOTHING, and a listing that
            # answered "here is everything" while the caller believed it had filtered is the
            # shape `ql_explain` was fixed for. Named, not silently applied.
            if (f = filter) && f.empty? && (fs = filter_str) && !fs.empty?
              j.field "filter_ignored", true
              j.field "filter_ignored_note",
                "filter #{fs.inspect} produced no usable term, so it narrowed nothing — these are ALL " \
                "the project's sessions. Fields are #{Repeater::SubtabFilter::FIELDS.map { |x| "#{x}:" }.join(" ")}"
            end
            if include_response_body && paginated_repeaters.size > body_ids.size
              j.field "response_bodies_omitted", paginated_repeaters.size - body_ids.size
              j.field "response_bodies_omitted_note",
                "last_response_body is hydrated for the first #{MCP_REPEATER_BODY_ROWS} rows of a page only " \
                "(each is a separate BLOB read) — narrow with id/filter, or page, to read the rest"
            end
            j.field "has_more", offset + paginated_repeaters.size < total_count
            j.field "sessions" do
              j.array do
                paginated_repeaters.each do |r|
                  emit_repeater_session(j, r, include_content, include_sensitive,
                    tui_index: tui_index[r.id]?,
                    response_body_cap: body_ids.includes?(r.id) ? body_cap : nil)
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
                                        include_sensitive : Bool = false,
                                        tui_index : Int32? = nil,
                                        response_body_cap : Int32? = nil) : Nil
        j.object do
          j.field "db_id", r.id
          # The number the operator reads off the sub-tab chip ("6:POST /api"), beside the id
          # every tool here takes. Both, always, because holding one and needing the other is
          # the round trip this field exists to remove — and because acting on the wrong tab
          # is how an audit trail gets polluted. `position` below is the ORDERING COLUMN, not
          # a rank: it is what sorts the strip, not what the chip says.
          j.field "tui_index", tui_index if tui_index
          j.field "position", r.position
          # target/name/tags/sni are seeded from a captured request without scrubbing, so
          # they can carry invalid UTF-8 into the JSON-RPC line (see Serialize.text).
          j.field "target", Serialize.text(r.target)
          j.field "http2", r.http2?
          j.field "auto_content_length", r.auto_content_length?
          j.field "flow_id", r.flow_id if r.flow_id
          j.field "name", Serialize.text(r.name) if r.name
          j.field "tags", Serialize.text(r.tags) if r.tags
          j.field "sni", Serialize.text(r.sni) if r.sni
          # The tab's own TLS fingerprint (#844), when it has one. Absent means "the
          # destination's outbound_tls policy" — which is what every tab meant before it
          # existed, so a listing of untouched sessions is unchanged. An agent replaying one
          # through `send_request{repeater_id}` inherits this unless it passes its own.
          j.field "tls_preset", r.tls_preset if r.tls_preset
          r_request_text = String.new(r.request).scrub
          if include_content
            emit_capped_text(j, "request", Serialize.redact_head(String.new(r.request), include_sensitive),
              raw: r.request, include_sensitive: include_sensitive,
              read_more: %(get_response_body_chunk(repeater_id: #{r.id}, part: "request", offset: …)))
            # What the credential headers are WIRED to, with the credentials still withheld —
            # `redact_head` above blanks `Authorization: Bearer $AUTH` and a live token
            # identically, so without this the operator cannot confirm an env binding without
            # asking for the secret. See `Serialize.env_header_shapes`.
            shapes = Serialize.env_header_shapes(r_request_text)
            unless shapes.empty?
              j.field("env_headers") do
                j.array do
                  shapes.each do |(name, shape)|
                    j.object { j.field "name", name; j.field "shape", shape }
                  end
                end
              end
            end
          end

          if Repeater::WsEngine.replayable?(r_request_text)
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
                      raw = String.new(m.payload)
                      j.field "payload", raw.scrub
                      # A TEXT frame carrying invalid UTF-8 is the RFC 6455 §8.1/§5.6
                      # validation payload, not an accident — see Serialize.emit_ws_messages.
                      unless raw.valid_encoding?
                        j.field "payload_lossy", true
                        j.field "payload_base64", Base64.strict_encode(m.payload)
                      end
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
            j.field "last_error", Serialize.text(err)
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
              j.field "last_reason", Serialize.text(resp.reason)
            end
            if include_content
              j.field "last_response_head", Serialize.redact_head_opt(Serialize.head_text(head), include_sensitive)
              # A response head comes straight off a remote socket — the least trustworthy
              # source on this surface for UTF-8 validity — and `head_text` scrubs it. Same
              # companion `get_flow` already emits for a captured head.
              Serialize.emit_head_base64(j, "last_response_head", head, include_sensitive)
            end
          end
          emit_repeater_response_body(j, r, head, response_body_cap, include_sensitive) if response_body_cap
        end
      end

      # The stored last response BODY, capped and decoded — so "why did tab 6 answer 500?" is
      # one call instead of three.
      #
      # Its own BLOB read (`get_repeater_full`), because `repeaters_mcp` leaves `response_body`
      # out on purpose and a listing must not start pulling megabytes; the caller decides which
      # rows get one and the tool names the ones it skipped.
      #
      # Decoded like `get_response_body_chunk`, through the same `ContentDecode` and reported
      # with the same `representation`/`decode_note` words, so the inline preview and the paged
      # read describe the same bytes the same way.
      private def emit_repeater_response_body(j : JSON::Builder, r : Store::RepeaterRecord,
                                              head : Bytes?, cap : Int32,
                                              include_sensitive : Bool) : Nil
        full = store.get_repeater_full(r.id)
        body = full.try(&.response_body)
        # Distinguishes "never sent / no body" from "omitted": the caller ASKED for a body
        # here, so silence would be the only reading left and it is the wrong one.
        return j.field "last_response_body_absent", true if body.nil? || body.empty?

        decoded, note = Proxy::Codec::ContentDecode.decode(head, body)
        bytes = decoded || body
        text = String.new(bytes)
        emit_capped_text(j, "last_response_body", text,
          raw: bytes, include_sensitive: include_sensitive,
          read_more: %(get_response_body_chunk(repeater_id: #{r.id}, part: "response", offset: …)),
          cap: cap)
        j.field "last_response_body_representation", decoded ? "decoded" : "raw"
        j.field "last_response_body_decode_note", note if note
        # `emit_capped_text` names a cursor only when it CUT. A body that fits but is not
        # UTF-8 was still altered — scrubbed — and the caller needs the same pointer to read
        # the bytes as bytes.
        unless text.valid_encoding? || text.bytesize > cap
          j.field "last_response_body_read_more",
            %(get_response_body_chunk(repeater_id: #{r.id}, part: "response", offset: …))
        end
      end

      # A stored text blob, capped for LLM use — plus everything the caller needs to know that
      # what it read is NOT what is stored.
      #
      # `scrub` is mandatory for the transport's UTF-8 contract but it is LOSSY and silently
      # so, and this is the ONLY way to read a repeater's request back. An agent that stored
      # exact octets with `request_base64` read them back U+FFFD-substituted, edited that
      # string, and wrote it home with `update_repeater` — turning a 6-byte body into 10 and
      # having gori recompute Content-Length to match, with `isError:false` throughout. So:
      # `<field>_lossy` + `<field>_base64` whenever scrubbing changed anything, the same
      # convention `Serialize.emit_lossy_text` / `emit_head_base64` already use, and the same
      # `include_sensitive` gate `emit_head_base64` uses — base64 is encoding, not redaction,
      # so emitting it by default would hand back the Authorization/Cookie bytes `redact_head`
      # just removed. A truncated blob gets `<field>_read_more` naming the cursor that serves
      # the rest, because 16 KiB of a 20 KB request with no way to fetch byte 16385 is the
      # same silence in a different shape.
      private def emit_capped_text(j : JSON::Builder, field : String, text : String, *,
                                   raw : Bytes? = nil, include_sensitive : Bool = false,
                                   read_more : String? = nil,
                                   cap : Int32 = MCP_REPEATER_REQUEST_MAX) : Nil
        cut = text.bytesize > cap
        # Compare and cut by BYTES (the cap is a byte budget), then scrub — a slice
        # through a multi-byte UTF-8 sequence would otherwise emit invalid UTF-8 into
        # the JSON-RPC stream, which must be well-formed UTF-8 over the stdio transport.
        j.field field, cut ? text.byte_slice(0, cap).scrub : text.scrub
        if cut
          j.field "#{field}_truncated", true
          j.field "#{field}_total_bytes", text.bytesize
          j.field "#{field}_read_more", read_more if read_more
        end
        return if !cut && text.valid_encoding?
        j.field "#{field}_lossy", true
        return unless include_sensitive && (bytes = raw)
        j.field "#{field}_base64", Base64.strict_encode(bytes)
      end

      # The live-TUI repeater snapshot (ui["repeater"]) is the raw editor state the human is
      # working on; its `request` / `upgrade_request` fields are full HTTP request text whose
      # headers carry Authorization/Cookie. The blob is persisted (and read back) VERBATIM, so
      # — unlike the sessions[] path (emit_repeater_session, which redact_head's its request +
      # response head) — it would bypass redaction if emitted as-is. Rebuild the object here,
      # running redact_head over those two text fields; every other field (summary, status,
      # ws payloads-as-body, timings) passes through unchanged. With include_sensitive the blob
      # is emitted verbatim, matching the sessions policy and the sensitive_headers_redacted flag.
      private def emit_tui_repeater(j : JSON::Builder, repeater : JSON::Any, include_sensitive : Bool) : Nil
        if include_sensitive
          j.field "tui_repeater", repeater
          return
        end
        j.field("tui_repeater") { redact_tui_repeater(j, repeater, nil) }
      end

      # Re-emit the repeater snapshot with redaction. The raw-HTTP-text fields
      # (`request` / `upgrade_request`) are NESTED under "active" (repeater_controller
      # builds count/active_subtab/active{write_mcp_fields}), so walk recursively and run
      # redact_head over any string reached under one of those keys, at any depth — a
      # top-level-only pass would miss the nested request and leak its headers. Everything
      # else passes through verbatim.
      private def redact_tui_repeater(j : JSON::Builder, value : JSON::Any, key : String?) : Nil
        if (key == "request" || key == "upgrade_request") && (s = value.as_s?)
          j.string Serialize.redact_head(s, false)
        elsif obj = value.as_h?
          j.object { obj.each { |k, v| j.field(k) { redact_tui_repeater(j, v, k) } } }
        elsif arr = value.as_a?
          j.array { arr.each { |v| redact_tui_repeater(j, v, nil) } }
        else
          value.to_json(j)
        end
      end

      private def parse_ui_state : JSON::Any?
        store.setting(Store::UI_STATE_KEY).try do |r|
          obj = JSON.parse(r)
          obj if obj.as_h?
        rescue
          nil
        end
      end

      # The tools/list schemas for the session-context tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_context_tools(j : JSON::Builder) : Nil
        tool j, "list_scope", "List the project's scope include/exclude rules, plus whether the scope lens/gate and the hard-containment sandbox are enabled." { }

        tool j, "project_info",
          "Project totals: flow count, issue count, captured bytes, earliest capture time, " \
          "plus which project/db is being served and how it was selected. When unbound " \
          "(bound:false), call list_projects / create_project / switch_project first. " \
          "Always verify this before reading or mutating security-test data." { }

        tool j, "get_current_context",
          "What the user is currently viewing in the gori TUI: active tab, focused pane, the " \
          "History-selected flow id (only when on the History tab), and sub-tab index — so you " \
          "can act on \"what I'm looking at right now\" without the user pasting ids. Reflects an " \
          "open (or last-open) gori TUI for THIS project. `age_seconds` shows how long since the " \
          "TUI last recorded focus (there is no live-TUI heartbeat) — use it to judge freshness; " \
          "`available:false` means the TUI never ran against this project." { }

        tool j, "get_repeater_context",
          "The Repeater workbench state. Defaults to metadata only so request headers, WebSocket " \
          "payloads, response headers, and the live TUI editor snapshot are not copied into the " \
          "model context. Set include_content=true only when those bytes are necessary. Supports " \
          "single-id lookup, pagination, and filtering. Every session reports BOTH ids: 'db_id', " \
          "which every repeater tool takes, and 'tui_index', the 1-based number the TUI paints on " \
          "its sub-tab chip — the number the operator says out loud. tui_index shifts whenever a " \
          "session is created, deleted or moved, so read it fresh; db_id is the durable address." do |s|
          s.field "id", intprop("return one repeater DATABASE id (not a tui_index)")
          s.field "limit", intprop("max rows to return (default 50, max 500)")
          s.field "offset", intprop("start row (default 0)")
          s.field "query", strprop("case-insensitive SUBSTRING match over a session's name, target URL and stored request bytes. For a field query (tags, host, method, last status) use 'filter' — both may be passed and both must match")
          s.field "filter", strprop("the same sub-tab filter language the TUI's `/` takes, matched in memory: #{Repeater::SubtabFilter::FIELDS.map { |f| "#{f}:" }.join(" ")}, `-` before a term negates it, and a bare word searches name/summary/target/tags. `status:` is the LAST send's outcome as one token — a code (`status:404`, and `status:4` matches every 4xx by prefix), `status:error`, or `status:unsent`. ANDed with 'query' when both are given")
          s.field "include_content", boolprop("include request text, WebSocket payloads, response head, the env-binding shape of each credential header, and the live TUI repeater snapshot (default false; may expose secrets)")
          s.field "include_sensitive", boolprop("with include_content, return Authorization/Cookie/Set-Cookie/API-key header values instead of [REDACTED] (default false)")
          s.field "include_response_body", boolprop("also inline each session's stored last response BODY, decoded and capped (default false). Its own BLOB read per row, so it is hydrated for the first #{MCP_REPEATER_BODY_ROWS} rows of a page and the rest are reported as omitted — pass 'id' or narrow with 'filter' to read one. Page past the cap with get_response_body_chunk")
          s.field "max_body_bytes", intprop("cap for each inlined response body (default #{MCP_REPEATER_BODY_DEFAULT}, max #{MCP_REPEATER_BODY_MAX})")
        end
      end
    end
  end
end
