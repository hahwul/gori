require "json"
require "base64"
require "../../store"
require "../serialize"

module Gori
  module MCP
    class Tools
      # --- read tools ---------------------------------------------------------

      private def list_history(h) : Result
        limit = clamp(optional_int_arg(h, "limit"), 50, 500)
        before_id = optional_int_arg(h, "before_id")
        since_id = optional_int_arg(h, "since")
        if before_id && since_id
          return err("pass only one of 'since' (tail newer, oldest-first) or 'before_id' (page older, newest-first)",
            "INVALID_ARGUMENT", field: "since")
        end
        # `flows.id` is a REUSABLE rowid, so a clear (or deleting the newest flow) restarts
        # numbering — and a forward cursor held from before that is then permanently ahead of
        # every row. `since: 22` returned `[]` forever while the rows sat right there at ids
        # 1-3, with no signal an agent could act on: "no new flows" and "your cursor is
        # stranded" were the same answer. Say which. Cheap enough to check per call (a
        # rightmost-leaf seek), and it also covers a cursor held across a project switch.
        if (cur = since_id) && (newest = store.max_flow_id) && cur > newest
          return err("cursor #{cur} is ahead of the newest flow #{newest} — history was cleared " \
                     "or the flows were deleted; restart from since=0",
            "INVALID_ARGUMENT", field: "since")
        end
        query = str(h, "query")
        filter = ql_filter_or_error(h, query)
        return filter if filter.is_a?(Result)
        # An agent gets one shot at this answer and cannot tell "no match" from "not indexed
        # yet", so drain the off-commit FTS backlog (Store V4) before a query that reads it.
        store.index_pending! if filter.uses_fts?
        rows = (query && !query.strip.empty?) ? store.search(filter, limit, before_id, since_id) : store.recent_flows(limit, before_id, since_id)
        Result.new(JSON.build { |j| j.array { rows.each { |r| Serialize.flow_row(j, r) } } })
      end

      # #124 AI event feed. Forward-cursored (id > since, oldest-first). next_cursor is the
      # max id SCANNED this page (NOT the max matched id), so source/kind filters never make
      # the agent re-scan or skip; on an empty page it echoes the input `since` (never 0,
      # never max-of-empty) so a no-new-events poll keeps the caller's place.
      private def list_events(h) : Result
        since = optional_int_arg(h, "since") || 0_i64
        limit = clamp(optional_int_arg(h, "limit"), 100, 500)
        source = str(h, "source")
        kind = str(h, "kind")
        scanned = store.events_after(since, limit)
        next_cursor = scanned.empty? ? since : scanned.last.id
        rows = scanned
        rows = rows.select { |r| r.source == source } if source && !source.empty?
        rows = rows.select { |r| r.kind == kind } if kind && !kind.empty?
        Result.new(JSON.build do |j|
          j.object do
            j.field("events") { j.array { rows.each { |r| Serialize.event_row(j, r) } } }
            j.field "next_cursor", next_cursor
          end
        end)
      end

      private def get_flow(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        detail = store.get_flow(id)
        return not_found("no flow with id #{id}") unless detail
        # A WebSocket flow (101) carries a separate message log; fetch it so get_flow
        # surfaces the frames (parity with `gori run show`). Non-WS flows skip the query.
        ws_msgs = detail.row.status == 101 ? store.ws_messages(id) : [] of Store::WsMessage
        include_sensitive = bool_arg(h, "include_sensitive", false)
        cap, omit = body_return_opts(h)
        Result.new(Serialize.flow_detail_json(detail, ws_msgs, include_sensitive, cap, omit))
      end

      private def get_response_body_chunk(h) : Result
        options = body_chunk_options(h)

        loaded = load_chunk_source(options)
        return loaded if loaded.is_a?(Result)
        head, body = loaded
        stored = body || Bytes.new(0)
        # A REQUEST part is stored wire bytes, not a content-encoded response entity: there is
        # nothing to decode and decoding would be a lie about what is on disk.
        decoded, decode_note = (options.raw || options.request?) ? {nil, nil} : Proxy::Codec::ContentDecode.decode(head, stored)
        bytes = decoded || stored
        total = bytes.size.to_i64
        # The decoded view is capped at ContentDecode::MAX_OUT (decompression-bomb ceiling).
        # At the cap, `complete:true` at the end would falsely imply the whole body — flag it
        # so a caller knows more decoded data may exist and can page the wire bytes with raw:true.
        decode_capped = !decoded.nil? && decoded.size >= Proxy::Codec::ContentDecode::MAX_OUT
        # An offset past the end used to silently clamp to the body end (0 bytes,
        # complete:true) — indistinguishable from a legitimate final read. Surface
        # both the requested and the effective offset plus a warning so the caller
        # can tell a genuine end-of-body from a bad offset.
        requested = options.offset
        start = Math.min(requested, total).to_i
        offset_out_of_range = requested > total
        count = Math.min(options.limit, bytes.size - start)
        chunk = count.zero? ? Bytes.new(0) : bytes[start, count]
        next_offset = start.to_i64 + count
        text = String.new(chunk)

        Result.new(JSON.build do |j|
          j.object do
            j.field "flow_id", options.flow_id
            j.field "repeater_id", options.repeater_id
            j.field "part", options.part
            j.field "requested_offset", requested
            j.field "offset", start
            j.field "offset_out_of_range", true if offset_out_of_range
            j.field "warning", "requested offset #{requested} is past the #{total}-byte body; clamped to the end" if offset_out_of_range
            j.field "returned_bytes", count
            j.field "total_bytes", total
            j.field "representation", decoded ? "decoded" : "raw"
            j.field "decode_note", decode_note if decode_note
            if decode_capped
              j.field "decode_capped", true
              j.field "decode_cap_warning", "decoded view capped at #{Proxy::Codec::ContentDecode::MAX_OUT} bytes (decompression-bomb ceiling); more decoded data may exist beyond this — page the raw wire bytes with raw:true"
            end
            j.field "complete", next_offset >= total
            j.field "next_offset", next_offset < total ? next_offset : nil
            if text.valid_encoding?
              j.field "encoding", "text"
              j.field "text", text
            else
              j.field "encoding", "base64"
              j.field "base64", Base64.strict_encode(chunk)
            end
          end
        end)
      rescue ex : Gori::Error
        Result.new(ex.message || "invalid response-body arguments", is_error: true)
      end

      private def body_chunk_options(h) : BodyChunkOptions
        flow_id = optional_int_arg(h, "flow_id")
        repeater_id = optional_int_arg(h, "repeater_id")
        if flow_id.nil? == repeater_id.nil?
          raise Gori::Error.new("pass exactly one of flow_id or repeater_id")
        end
        part = str(h, "part") || "response"
        unless part == "response" || part == "request"
          raise Gori::Error.new("invalid 'part' #{part.inspect} (expected \"response\" or \"request\")")
        end
        offset = bounded_int_arg(h, "offset", 0_i64, min: 0_i64)
        limit = bounded_int_arg(h, "limit", 65_536_i64, min: 1_i64, max: 262_144_i64).to_i
        BodyChunkOptions.new(flow_id, repeater_id, offset, limit, bool_arg(h, "raw", false), part)
      end

      # The bytes this chunk pages over: {head-for-decoding, payload}.
      private def load_chunk_source(options : BodyChunkOptions) : {Bytes?, Bytes?} | Result
        return load_response_body(options.flow_id, options.repeater_id) unless options.request?
        if id = options.repeater_id
          repeater = store.get_repeater(id)
          return not_found("no repeater with id #{id}") unless repeater
          # The stored blob IS head+body, byte-exact — the same bytes `send_request
          # {repeater_id}` replays. That is exactly what a caller reading past
          # get_repeater_context's cap wants.
          {nil, repeater.request}
        elsif id = options.flow_id
          detail = store.get_flow(id)
          return not_found("no flow with id #{id}") unless detail
          # `get_flow` already returns a captured request head with a base64 companion; this
          # is the paged route to the same bytes plus the body, for a request too big to inline.
          head = detail.request_head || Bytes.new(0)
          body = detail.request_body
          {nil, body ? Bytes.new(head.size + body.size) { |i| i < head.size ? head[i] : body[i - head.size] } : head}
        else
          Result.new("pass exactly one of flow_id or repeater_id", is_error: true)
        end
      end

      # Hard-delete ONE captured flow (the TUI History tab's delete). Single and explicit,
      # so no extra confirmation — unlike clear_history.
      private def delete_flow(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        # flow_row is the row-only read; get_flow would materialize both BLOBs to answer
        # "does this exist?" — a 40 MB response would be read and discarded.
        return not_found("no flow with id #{id}") unless store.flow_row(id)
        return busy("flow NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_flow(id)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true } })
      end

      # Wipe EVERY captured flow. The TUI puts a danger confirm in front of this; here
      # confirm:true is that gate. Without it we report the count and refuse, so a
      # mis-issued call cannot silently empty a capture session.
      private def clear_history(h) : Result
        n = store.count
        unless bool_arg(h, "confirm", false)
          return err("refusing to delete #{n} flow#{n == 1 ? "" : "s"} without confirm:true — this cannot be undone",
            "CONFIRM_REQUIRED", field: "confirm",
            details: JSON.parse({"flows" => n}.to_json))
        end
        return busy("history NOT cleared (store busy or unwritable); every flow is still there") unless store.clear_flows
        Result.new({"deleted" => n, "cleared" => true}.to_json)
      end

      private def load_response_body(flow_id : Int64?, repeater_id : Int64?) : {Bytes?, Bytes?} | Result
        if id = flow_id
          detail = store.get_flow(id)
          return not_found("no flow with id #{id}") unless detail
          {detail.response_head, detail.response_body}
        elsif id = repeater_id
          repeater = store.get_repeater_full(id)
          return not_found("no repeater with id #{id}") unless repeater
          {repeater.response_head, repeater.response_body}
        else
          Result.new("pass exactly one of flow_id or repeater_id", is_error: true)
        end
      end

      # The tools/list schemas for the captured-flow tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_flows_tools(j : JSON::Builder) : Nil
        tool j, "list_history",
          "List captured HTTP flows, newest first. Optional gori QL `query` " \
          "filters (e.g. 'host:example.com status:>=500 size:>10000 dur:>500', " \
          "'header:set-cookie', 'body~secret\\d+' — `~` is regex, dur is ms); " \
          "empty query returns the most recent. Returns light rows (no bodies); " \
          "use get_flow for full detail. Paginate by passing the oldest id seen as " \
          "`before_id` (rows are newest-first); a page shorter than `limit` means no older rows. " \
          "To TAIL new flows instead, pass `since` (the largest id you've seen): rows come back " \
          "OLDEST-first; tail by passing the last id as the next `since`; an empty page means no " \
          "new flows (keep your cursor). `since` and `before_id` are mutually exclusive. " \
          "Call ql_reference for full QL syntax." do |s|
          s.field "query", strprop("gori QL filter; empty = most recent")
          s.field "limit", intprop("max rows (default 50, max 500)")
          s.field "before_id", intprop("cursor: page OLDER — only flows with id < this (newest-first; works with query too)")
          s.field "since", intprop("forward cursor: tail NEWER — only flows with id > this, oldest-first (mutually exclusive with before_id)")
          s.field "strict", boolprop("reject the query if any term is unrecognized/invalid instead of silently dropping it (default false; use ql_explain to see which terms would drop)")
        end

        tool j, "list_events",
          "Tail the AI event feed: an append-only log of job lifecycle (miner/fuzzer/probe) and " \
          "agent actions, forward-cursored so you never see the same event twice. This is the " \
          "AI-facing firehose complement to list_history (which tails captured flows). Pass " \
          "`since` = the last cursor you saw (0 or omitted starts from the oldest); the response " \
          "carries `next_cursor` — pass it as the next `since`. `next_cursor` never moves backward " \
          "and echoes your input on an empty page, so a poll that returns no events keeps your place. " \
          "Optional `source`/`kind` filters do NOT affect `next_cursor` (it is the max SCANNED id)." do |s|
          s.field "since", intprop("forward cursor: only events with id > this (default 0 = from oldest). Pass back the response's next_cursor to tail.")
          s.field "limit", intprop("max events scanned (default 100, max 500)")
          s.field "source", strprop("filter to one source: miner | fuzzer | probe | agent")
          s.field "kind", strprop("filter to one kind (e.g. job_done, agent_action)")
        end

        tool j, "get_flow",
          "Full request+response for one flow id (heads + decoded bodies). " \
          "Bodies are de-chunked/decompressed and summarised: inline text when " \
          "UTF-8 (capped 64KB), else a base64 sample. Use get_response_body_chunk " \
          "with the same flow id to retrieve exact continuation bytes. " \
          "Authorization/Cookie/Set-Cookie/API-key header values are [REDACTED] " \
          "unless include_sensitive=true." do |s|
          s.field "id", intprop("flow id from list_history"), required: true
          s.field "include_sensitive", boolprop("return Authorization/Cookie/Set-Cookie/API-key header values instead of [REDACTED] (default false)")
          s.field "body_mode", strprop("none | preview | full (default full) — none returns body shape only (encoding/size, omitted:true); preview inlines a small head; page more with get_response_body_chunk")
          s.field "max_body_bytes", intprop("cap inlined body bytes (clamped to 65536; page the rest with get_response_body_chunk)")
        end

        tool j, "get_response_body_chunk",
          "Read a byte range from a stored message when get_flow / send_request / " \
          "get_repeater_context reports truncation. Pass exactly one of flow_id or repeater_id, " \
          "and part=\"response\" (default) or part=\"request\". Content encoding is decoded by " \
          "default so offsets continue the inline view; raw=true pages stored wire bytes, and a " \
          "request part is always the exact stored bytes. Returns UTF-8 text " \
          "or base64 plus next_offset/complete. An offset past the end is clamped and flagged " \
          "(requested_offset, offset_out_of_range, warning) rather than silently returning empty." do |s|
          s.field "flow_id", intprop("History flow id")
          s.field "repeater_id", intprop("Repeater workbench database id")
          s.field "part", strprop("response (default) | request — \"request\" pages the stored REQUEST bytes: for a repeater that is the exact head+body blob send_request(repeater_id) replays, which is the only way to read past get_repeater_context's inline cap")
          s.field "offset", intprop("zero-based byte offset (default 0)")
          s.field "limit", intprop("bytes to return (default 65536, max 262144)")
          s.field "raw", boolprop("page stored response bytes without content decoding (default false)")
        end

        return unless @allow_actions

        tool j, "delete_flow",
          "Hard-delete one captured flow from History. This cannot be undone." do |s|
          s.field "id", intprop("flow id"), required: true
        end

        tool j, "clear_history",
          "Delete EVERY captured flow in the project. Requires confirm:true — without it " \
          "the call is refused and reports how many flows it would have destroyed. " \
          "This cannot be undone." do |s|
          s.field "confirm", boolprop("must be true to actually delete; anything else refuses"), required: true
        end
      end
    end
  end
end
