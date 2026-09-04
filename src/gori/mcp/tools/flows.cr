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
        # `view` is a saved query applied as a LENS: ANDed over `query`, never replacing it, the
        # same way the TUI's `v` picker ANDs it over the filter bar. Resolved by name with
        # project > global > builtin precedence, as every surface resolves it.
        view_filter = QL::EMPTY
        if (vn = str(h, "view")) && !vn.strip.empty?
          unless view = SavedViews.resolve_by_name(store, vn)
            return err("no view named #{vn.inspect} (known: #{SavedViews.names(store).join(", ")}) — see list_views",
              "INVALID_ARGUMENT", field: "view")
          end
          # A view whose stored query compiles to nothing is REFUSED, not applied: `QL.and` folds
          # an EMPTY side away, so applying it would return EVERY flow while the call named a
          # view — the same silent-broadening `ql_filter_or_error` refuses for `query`.
          unless vf = SavedViews.filter(view, scope: Scope.ql_lens(store))
            return err("view #{view.name.inspect} is not a usable query (#{view.query.inspect}) — fix it with update_view",
              "INVALID_ARGUMENT", field: "view")
          end
          view_filter = vf
          filter = QL.and(view_filter, filter)
        end
        # `in_scope` opt-in: the same per-flow scope lens the TUI History ⇧S toggle and
        # `gori run history --in-scope` apply, independent of the persisted flag. Capture is
        # untouched — this narrows only the rows returned. Empty (nothing in scope) when no
        # scope rules are configured, matching the other surfaces.
        in_scope = bool_arg(h, "in_scope", false)
        scope_unconfigured = false
        if in_scope
          scope = Scope.load(store)
          if scope.configured?
            filter = QL.and(scope.filter(force: true), filter)
          else
            scope_unconfigured = true
          end
        end
        # User-defined columns (#819): the values QL can filter on but never show — a header, a
        # JSON field, a regex capture, per row. OPT-IN and never the project's configured set,
        # unlike `gori run history`: a per-row block an agent did not ask for is paid for on
        # every row of a 500-row page, which is the same argument that keeps `headers` off this
        # feed (see `CLI::Output.flow_row_fields`).
        #
        # Parsed BEFORE the FTS drain below, which is a WRITE: a call that is going to be
        # refused must not take a write lock on its way to the refusal.
        prepared = Gori::DisplayColumns.prepare([] of Store::DisplayColumn)
        if (specs = str_list(h, "columns")) && !specs.empty?
          parsed = Gori::DisplayColumns.parse_specs(specs)
          return err(parsed, "INVALID_ARGUMENT", field: "columns") if parsed.is_a?(String)
          prepared = Gori::DisplayColumns.prepare(parsed.map_with_index { |sp, i| sp.to_column(i) })
        end
        # An agent gets one shot at this answer and cannot tell "no match" from "not indexed
        # yet", so drain the off-commit FTS backlog (Store V4) before a query that reads it —
        # or refuse, when this server is read-only and therefore cannot drain (see the helper).
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        rows =
          if scope_unconfigured
            [] of Store::FlowRow
          elsif (query && !query.strip.empty?) || in_scope || view_filter != QL::EMPTY
            # `view_filter` belongs in this condition and not only in the AND above: without it a
            # `view` with no `query` and no `in_scope` falls through to `recent_flows`, which
            # takes no filter at all — the call would accept the view and return everything.
            store.search(filter, limit, before_id, since_id)
          else
            store.recent_flows(limit, before_id, since_id)
          end
        Result.new(JSON.build { |j| j.array { rows.each { |r| Serialize.flow_row(j, r, row_columns(r, prepared)) } } })
      end

      # One row's user-column values as `{label, value}` pairs, or nil when none were asked for.
      #
      # ONE capped read per RETURNED row, and none at all for a set that reads only heads — the
      # same P8 discipline the TUI row loop keeps, applied to a page already bounded by `limit`.
      private def row_columns(row : Store::FlowRow,
                              prepared : Gori::DisplayColumns::Prepared) : Array({String, String})?
        return nil if prepared.empty?
        detail = store.get_flow(row.id, body_max: prepared.body_scoped? ? Gori::DisplayColumns::BODY_CAP : 0)
        values = detail ? prepared.values(detail) : Array.new(prepared.size, "")
        prepared.columns.map_with_index { |c, i| {c.label, values[i]? || ""} }
      end

      # #124 AI event feed. Forward-cursored (id > since, oldest-first). next_cursor is the
      # max id SCANNED this page (NOT the max matched id), so source/kind filters never make
      # the agent re-scan or skip; on an empty page it echoes the input `since` (never 0,
      # never max-of-empty) so a no-new-events poll keeps the caller's place.
      private def list_events(h) : Result
        since = optional_int_arg(h, "since") || 0_i64
        limit = clamp(optional_int_arg(h, "limit"), 100, 500)
        # Refused, not filtered. `source` and `actor` are the two CLOSED filters on this tool,
        # and a value nothing writes narrows the feed to nothing — which comes back
        # `events: []`, `isError:false`, and reads as "the project has no such activity" rather
        # than "that is not a source". A wrong answer with no error on it is the worst shape a
        # read tool has. `kind` stays open: it is a free string each producer coins
        # (`job_done`, `agent_action`, `scope_add`, …) with no registry to check against.
        #
        # `actor` is the likelier trap of the two, because the Activity pane PRINTS `agent` for
        # the `mcp` token (project_view's `act_actor_label` — the pane's filter is cycled, not
        # typed, so it can afford the nicer word). An agent reading that label off a screenshot
        # and calling `list_events{actor:"agent"}` used to get an empty feed for a project full
        # of its own actions.
        source = closed_filter(h, "source", EVENT_SOURCES)
        return source if source.is_a?(Result)
        actor = closed_filter(h, "actor", EVENT_ACTORS)
        return actor if actor.is_a?(Result)
        kind = str(h, "kind")
        scanned = store.events_after(since, limit)
        next_cursor = scanned.empty? ? since : scanned.last.id
        rows = scanned
        rows = rows.select { |r| r.source == source } if source
        rows = rows.select { |r| r.kind == kind } if kind && !kind.empty?
        rows = rows.select { |r| r.actor == actor } if actor
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
        # A WebSocket flow carries a separate message log; fetch it so get_flow surfaces the
        # frames (parity with `gori run show`).
        #
        # Asked of the ROWS and not of the status (#742). This used to be
        # `row.status == 101 ? … : []`, which is the h1 handshake's status and NOT the h2
        # one: an RFC 8441 extended CONNECT (#733) is answered `200`, so a socket captured
        # over h2 had its transcript decoded, written, and then withheld from every agent
        # that asked for the flow. `ws_messages` already returns an empty array for anything
        # that is not a socket, so the guard bought one query on non-WS flows and cost the
        # feature on h2 ones.
        ws_msgs = store.ws_messages(id)
        include_sensitive = bool_arg(h, "include_sensitive", false)
        opts = body_return_opts(h)
        return opts if opts.is_a?(Result)
        cap, omit = opts
        Result.new(Serialize.flow_detail_json(detail, ws_msgs, include_sensitive, cap, omit))
      end

      private def get_response_body_chunk(h) : Result
        options = body_chunk_options(h)

        loaded = load_chunk_source(options)
        return loaded if loaded.is_a?(Result)
        head, body = loaded
        stored = body || Bytes.new(0)
        head_omitted = false
        if options.request? && !options.include_sensitive
          stored, head_omitted = drop_sensitive_head(stored)
        end
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
            if head_omitted
              j.field "head_omitted", true
              j.field "head_omitted_note",
                "the request head carries a sensitive header (#{Serialize::SENSITIVE_HEADERS.to_a.sort.join(", ")}) " \
                "and this tool pages the EXACT stored bytes, which cannot be redacted and stay bytes — the range " \
                "below is the body alone. Pass include_sensitive:true to page the head too, or read it redacted " \
                "from get_flow / get_repeater_context"
            end
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
        unless MESSAGE_SIDES.includes?(part)
          raise Gori::Error.new("invalid 'part' #{part.inspect} (expected #{MESSAGE_SIDES.join(" or ")})")
        end
        offset = bounded_int_arg(h, "offset", 0_i64, min: 0_i64)
        limit = bounded_int_arg(h, "limit", 65_536_i64, min: 1_i64, max: 262_144_i64).to_i
        BodyChunkOptions.new(flow_id, repeater_id, offset, limit, bool_arg(h, "raw", false), part,
          bool_arg(h, "include_sensitive", false))
      end

      # A `part:"request"` payload is head+body wire bytes, and this tool pages them EXACTLY —
      # `Serialize.emit_head_base64` states the rule those bytes fall under: "base64 is
      # encoding, not redaction … redacting INSIDE the base64 is not an option — it would no
      # longer be the bytes", so it withholds the byte-exact head unless `include_sensitive`.
      # The same head reached here ungated: `get_flow` answered `authorization: [REDACTED]`
      # while `get_response_body_chunk{flow_id, part:"request"}` on the same flow handed back
      # the whole Bearer token, from a tool that had no `include_sensitive` argument at all.
      #
      # So the head is dropped rather than rewritten, and only when it actually carries one of
      # `Serialize::SENSITIVE_HEADERS` — a request with nothing to withhold pages exactly as
      # before. `offset`/`total_bytes`/`next_offset` then describe the body alone, which is why
      # the omission is NAMED in the reply instead of shortening the payload silently.
      private def drop_sensitive_head(bytes : Bytes) : {Bytes, Bool}
        head, body = split_wire_request(bytes)
        text = String.new(head).scrub
        return {bytes, false} if Serialize.redact_head(text, false) == text
        {body || Bytes.new(0), true}
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
        n = store.count?
        return busy("history NOT cleared (store busy); every flow is still there") unless n
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
          s.field "view", strprop("apply a saved History view by name (list_views) — its query is ANDed OVER `query`, never replacing it, the same way the TUI's `v` picker layers over the filter bar. Built-ins: All, History (src:proxy), 'History + Repeater'. An unknown name is refused rather than ignored")
          s.field "in_scope", boolprop("only flows in the project's configured scope (the TUI ⇧S lens; capture still records everything). Empty result when no scope rules exist. Default false. For finer control use the QL terms `scope:in` / `scope:out` in `query`, which negate and group like any other term (ql_explain reports whether the project has scope rules at all)")
          s.field "strict", boolprop("reject the query if any term is unrecognized/invalid instead of silently dropping it (default false; use ql_explain to see which terms would drop)")
          s.field "columns", strarrprop("extract a value out of each returned flow and carry it on the row under `columns` — what QL can FILTER on but never shows. Each spec is [LABEL=][req|res:]kind:selector, kind being cookie|header|regex|position|jsonpath: e.g. \"header:x-request-id\", \"req:header:authorization\", \"RID=jsonpath:data.id\", \"regex:token=(\\w+)\", \"position:0:32\". Side defaults to the RESPONSE; a label defaults to the selector. A descriptor that matches nothing yields \"\" — an empty string is a MISS, not an empty value. Costs one extra read per row (and, for the three body-scoped kinds, up to 512 KiB of body each), so ask only for what you will read")
        end

        tool j, "list_events",
          "Tail the AI event feed: an append-only log of job lifecycle (miner/fuzzer/probe) and " \
          "agent actions, forward-cursored so you never see the same event twice. This is the " \
          "AI-facing firehose complement to list_history (which tails captured flows). Pass " \
          "`since` = the last cursor you saw (0 or omitted starts from the oldest); the response " \
          "carries `next_cursor` — pass it as the next `since`. `next_cursor` never moves backward " \
          "and echoes your input on an empty page, so a poll that returns no events keeps your place. " \
          "Optional `source`/`kind`/`actor` filters do NOT affect `next_cursor` (it is the max SCANNED id). " \
          "Every event carries `actor` — the surface that acted (tui | cli | mcp) — so you can tell " \
          "your own writes from the operator's; the human reads this same feed on the Project tab's " \
          "Activity pane." do |s|
          s.field "since", intprop("forward cursor: only events with id > this (default 0 = from oldest). Pass back the response's next_cursor to tail.")
          s.field "limit", intprop("max events scanned (default 100, max 500)")
          s.field "source", enumprop("filter to one producer of feed rows", EVENT_SOURCES)
          s.field "actor", enumprop("filter to the surface that acted; rows written by a background engine name none", EVENT_ACTORS)
          s.field "kind", strprop("filter to one kind (e.g. job_done, agent_action, scope_add)")
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
          s.field "body_mode", enumprop("how much response body to inline (default full). none returns body shape only (encoding/size, omitted:true); preview inlines a small head; page more with get_response_body_chunk", BODY_MODES)
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
          s.field "part", enumprop("which stored blob to page (default response). \"request\" pages the stored REQUEST bytes: for a repeater that is the exact head+body blob send_request(repeater_id) replays, which is the only way to read past get_repeater_context's inline cap", MESSAGE_SIDES)
          s.field "offset", intprop("zero-based byte offset (default 0)")
          s.field "limit", intprop("bytes to return (default 65536, max 262144)")
          s.field "raw", boolprop("page stored response bytes without content decoding (default false)")
          s.field "include_sensitive", boolprop("part=\"request\": also page the message HEAD when it carries an Authorization/Cookie/Set-Cookie/API-key value. These are exact stored bytes, so the head is withheld rather than redacted (default false); the reply says so with head_omitted")
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
