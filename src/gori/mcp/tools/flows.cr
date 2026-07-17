require "json"
require "base64"
require "../../store"
require "../serialize"

module Gori
  module MCP
    class Tools
      # --- read tools ---------------------------------------------------------

      private def list_history(h) : Result
        limit = clamp(int(h, "limit"), 50, 500)
        before_id = int(h, "before_id")
        since_id = int(h, "since")
        if before_id && since_id
          return err("pass only one of 'since' (tail newer, oldest-first) or 'before_id' (page older, newest-first)",
            "INVALID_ARGUMENT", field: "since")
        end
        query = str(h, "query")
        filter = ql_filter_or_error(h, query)
        return filter if filter.is_a?(Result)
        rows = (query && !query.strip.empty?) ? @store.search(filter, limit, before_id, since_id) : @store.recent_flows(limit, before_id, since_id)
        Result.new(JSON.build { |j| j.array { rows.each { |r| Serialize.flow_row(j, r) } } })
      end

      # #124 AI event feed. Forward-cursored (id > since, oldest-first). next_cursor is the
      # max id SCANNED this page (NOT the max matched id), so source/kind filters never make
      # the agent re-scan or skip; on an empty page it echoes the input `since` (never 0,
      # never max-of-empty) so a no-new-events poll keeps the caller's place.
      private def list_events(h) : Result
        since = int(h, "since") || 0_i64
        limit = clamp(int(h, "limit"), 100, 500)
        source = str(h, "source")
        kind = str(h, "kind")
        scanned = @store.events_after(since, limit)
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
        detail = @store.get_flow(id)
        return not_found("no flow with id #{id}") unless detail
        # A WebSocket flow (101) carries a separate message log; fetch it so get_flow
        # surfaces the frames (parity with `gori run show`). Non-WS flows skip the query.
        ws_msgs = detail.row.status == 101 ? @store.ws_messages(id) : [] of Store::WsMessage
        include_sensitive = bool(h, "include_sensitive") || false
        cap, omit = body_return_opts(h)
        Result.new(Serialize.flow_detail_json(detail, ws_msgs, include_sensitive, cap, omit))
      end

      private def get_response_body_chunk(h) : Result
        options = body_chunk_options(h)

        loaded = load_response_body(options.flow_id, options.repeater_id)
        return loaded if loaded.is_a?(Result)
        head, body = loaded
        stored = body || Bytes.new(0)
        decoded, decode_note = options.raw ? {nil, nil} : Proxy::Codec::ContentDecode.decode(head, stored)
        bytes = decoded || stored
        total = bytes.size.to_i64
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
            j.field "requested_offset", requested
            j.field "offset", start
            j.field "offset_out_of_range", true if offset_out_of_range
            j.field "warning", "requested offset #{requested} is past the #{total}-byte body; clamped to the end" if offset_out_of_range
            j.field "returned_bytes", count
            j.field "total_bytes", total
            j.field "representation", decoded ? "decoded" : "raw"
            j.field "decode_note", decode_note if decode_note
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
        offset = bounded_int_arg(h, "offset", 0_i64, min: 0_i64)
        limit = bounded_int_arg(h, "limit", 65_536_i64, min: 1_i64, max: 262_144_i64).to_i
        BodyChunkOptions.new(flow_id, repeater_id, offset, limit, bool_arg(h, "raw", false))
      end

      private def load_response_body(flow_id : Int64?, repeater_id : Int64?) : {Bytes?, Bytes?} | Result
        if id = flow_id
          detail = @store.get_flow(id)
          return not_found("no flow with id #{id}") unless detail
          {detail.response_head, detail.response_body}
        elsif id = repeater_id
          repeater = @store.get_repeater_full(id)
          return not_found("no repeater with id #{id}") unless repeater
          {repeater.response_head, repeater.response_body}
        else
          Result.new("pass exactly one of flow_id or repeater_id", is_error: true)
        end
      end
    end
  end
end
