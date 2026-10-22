require "json"
require "base64"
require "../../store"
require "../serialize"
require "../../redact/policy"
require "../../plural"

module Gori
  module MCP
    class Tools
      # Cap on `list_history{ids}` — one deliberate named set per call, not a table scan by
      # another name. Above `TabController::SELECTION_ID_CAP` (200) ON PURPOSE: a selection
      # relayed by `get_current_context` must always be ACCEPTED in one call, and the two
      # constants drifting the other way would quietly break that promise
      # (`spec/mcp/flows_spec.cr` asserts the ordering). Accepted, not always returned: a set
      # past REPLY_ROWS_BUDGET comes back in parts, the rest named in `remaining_ids` (#1649).
      MCP_HISTORY_IDS_MAX = 500

      # --- read tools ---------------------------------------------------------

      HISTORY_LIMIT = PageLimit.new(50, 500)

      @[Tool("list_history", requires: ["get_flow", "ql_reference"])]
      private def list_history(h) : Result
        limit = clamp(optional_int_arg(h, "limit"), HISTORY_LIMIT)
        before_id = optional_int_arg(h, "before_id")
        since_id = optional_int_arg(h, "since")
        # `ids` names an EXACT set — the rows the operator marked in the TUI, handed over by
        # `get_current_context` (#1091). Validated first, and above `drain_fts_or_error`
        # below, for that helper's own reason: a call that is going to be refused must not
        # take a write lock on its way to the refusal.
        ids = nil.as(Array(Int64)?)
        if present?(h, "ids")
          # An explicit empty list is REFUSED, never answered with the recent-flows firehose.
          # A caller that named an empty selection would get every recent flow with no error
          # on it, which is a wrong answer wearing a correct one's clothes.
          return err("'ids' names no flow — pass at least one id, or omit 'ids' to page the list",
            "INVALID_ARGUMENT", field: "ids") unless describes?(h, "ids")
          ids = id_list_arg(h, "ids")
          return err("'ids' names no flow — pass at least one id, or omit 'ids' to page the list",
            "INVALID_ARGUMENT", field: "ids") if ids.empty?
          if ids.size > MCP_HISTORY_IDS_MAX
            return err("#{ids.size} ids is over the #{MCP_HISTORY_IDS_MAX}-flow cap for one call — " \
                       "split it, so a short result is never mistaken for a complete one",
              "INVALID_ARGUMENT", field: "ids")
          end
          if before_id || since_id
            # There is nothing to page through: the list IS the page. A cursor beside it would
            # silently shorten the operator's selection.
            return err("'ids' names the whole page, so 'before_id' / 'since' do not apply — drop the cursor",
              "INVALID_ARGUMENT", field: "ids")
          end
        end
        if before_id && since_id
          return err("pass only one of 'since' (tail newer, oldest-first) or 'before_id' (page older, newest-first)",
            "INVALID_ARGUMENT", field: "since")
        end
        # A long poll needs a forward cursor: without `since` there is no "nothing new yet" to
        # wait out. Refused rather than ignored, so a caller expecting a wait does not spin.
        wait_ms = wait_ms_arg(h)
        if wait_ms > 0 && since_id.nil?
          return err("'wait_ms' waits for flows past 'since' — pass 'since'",
            "INVALID_ARGUMENT", field: "wait_ms")
        end
        # `count_only` answers with a number and no rows (#1648). Everything that shapes ROWS
        # contradicts it and is refused, not ignored, so the number never silently means
        # something other than "all flows the filters match". Above the FTS drain, as `ids` is.
        count_only = bool_arg(h, "count_only", false)
        if count_only
          clash = ids ? "ids" : before_id ? "before_id" : since_id ? "since" : describes?(h, "columns") ? "columns" : nil
          if clash
            return err("'count_only' counts every flow the filters match and returns no rows, so '#{clash}' " \
                       "does not apply — drop it", "INVALID_ARGUMENT", field: clash)
          end
        end
        # A forward cursor is judged against the highest id this project has EVER issued, not
        # the newest surviving flow. Since V39 an id is never reissued, so a cursor at a deleted
        # newest flow, or one held across a clear, still sees the next capture: refusing it (as
        # the `MAX(id)` check did) sent a tailing agent back to since=0 to re-read everything.
        # One beyond the high-water mark was not issued here as the project stands (another
        # project's cursor, an older copy, a reset sequence), and waiting on it would answer `[]`
        # until capture happened to climb past it, so it is still named. A failed read refuses
        # nothing, as before.
        if (cur = since_id) && cur > 0
          if (issued = store.flow_id_high_water) && cur > issued
            return err("cursor #{cur} is ahead of every flow id this project has issued (#{issued}), " \
                       "so it does not come from this project's history as it stands; restart from since=0",
              "INVALID_ARGUMENT", field: "since")
          end
        end
        query = str(h, "query")
        dropped = [] of String
        filter = ql_filter_or_error(h, query, dropped)
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
        # `in_scope` opt-in: the same per-flow scope lens the TUI History `s` toggle and
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
        # `hide_static` opt-in: `QL.hide_static`, the lens the TUI's hide-static toggle and
        # `gori run history --hide-static` AND in — images, fonts and media left out. Explicit,
        # never the TUI's persisted toggle, for `in_scope`'s reason.
        hide_static = bool_arg(h, "hide_static", false)
        filter = QL.and(filter, QL.hide_static) if hide_static
        # User-defined columns (#819): the values QL can filter on but never show — a header, a
        # JSON field, a regex capture, per row. OPT-IN and never the project's configured set,
        # unlike `gori run history`: a per-row block an agent did not ask for is paid for on
        # every row of a 500-row page, which is the same argument that keeps `headers` off this
        # feed (see `CLI::Output.flow_row_fields`).
        #
        # Parsed BEFORE the FTS drain below, which is a WRITE: a call that is going to be
        # refused must not take a write lock on its way to the refusal.
        prepared = Gori::DisplayColumns::Prepared.new([] of Store::DisplayColumn)
        if (specs = str_list(h, "columns")) && !specs.empty?
          parsed = Gori::DisplayColumns.parse_specs(specs)
          return err(parsed, "INVALID_ARGUMENT", field: "columns") if parsed.is_a?(String)
          prepared = Gori::DisplayColumns::Prepared.new(parsed.map_with_index { |sp, i| sp.to_column(i) })
        end
        include_sensitive = bool_arg(h, "include_sensitive", false)
        matcher = columns_matcher(prepared, include_sensitive)
        # An agent gets one shot at this answer and cannot tell "no match" from "not indexed
        # yet", so drain the off-commit FTS backlog (Store V4) before a query that reads it —
        # or refuse, when this server is read-only and therefore cannot drain (see the helper).
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        return emit_history_count(filter, scope_unconfigured, h, dropped) if count_only
        # A named set is not a page: it has no cursor and no `limit` (`has_more` is true only
        # when the reply budget cut it, beside `remaining_ids`), and its short answers have to
        # name themselves. Branches here rather than earlier so `query`,
        # `view` and `in_scope` are already compiled — they still narrow WITHIN the set.
        return emit_history_ids(ids, filter, query, view_filter, in_scope || hide_static,
          scope_unconfigured, prepared, h, dropped) if ids
        # One row OVER the page, then dropped. The pagination contract was documented and
        # correct ("a page shorter than `limit` means no older rows") but it was an INFERENCE
        # the caller had to make and then act on with a second call: a query matching 51 flows
        # and one matching exactly 50 returned byte-identical answers, and an agent that read
        # 50 rows as the whole story was reasoning about a truncated capture without knowing.
        # Fetching limit+1 makes the page state a FACT the reply carries.
        fetch = limit + 1
        # `view_filter` belongs in this condition and not only in the AND above: without it a
        # `view` with no `query` and no `in_scope` falls through to `recent_flows`, which
        # takes no filter at all — the call would accept the view and return everything.
        # `hide_static` likewise.
        filtered = (query && !query.strip.empty?) || in_scope || hide_static || view_filter != QL::EMPTY
        # Raising, as the count does: a failed query degraded to `[]` with has_more:false,
        # the reply for "nothing matched" (#1648 made the two paths disagree about one query).
        rows = begin
          # Read BEFORE the page, so a flow committed between the two still wakes the wait.
          mark = history_mark(filtered) if wait_ms > 0
          page = history_rows(filter, filtered, scope_unconfigured, fetch, before_id, since_id)
          # `wait_ms`: the flows are written by another process, so each slice reads the mark
          # (indexed scalars) and re-runs the page only once it moves. A new flow the filter
          # rejects moves it too, and the wait goes on. A filtered re-read can scan bodies
          # over the whole tail, so under live capture it is TRIED at most once per
          # HISTORY_REREAD_GAP — and so is the FTS drain a free-text filter needs first. Only a
          # capturing TUI indexes in the background (`gori mcp`, `gori run` and a view-only TUI
          # do not), so the wait drains itself; a write, so it is capped at one a second (P6).
          # Rows still unindexed after it (a read-only server, a contended writer) are waited
          # out: a page read past one could hand back a cursor beyond a match it omitted.
          reread_at = Time.instant
          if page.empty? && !scope_unconfigured
            long_poll(wait_ms) do
              next false if (now = history_mark(filtered)) == mark
              next false if filtered && Time.instant < reread_at
              reread_at = Time.instant + HISTORY_REREAD_GAP
              if filter.uses_fts? && store.fts_dirty?
                store.drain_fts!(LONG_POLL_SLICE) unless store.read_only?
                next false if store.fts_dirty?
              end
              page = history_rows(filter, filtered, scope_unconfigured, fetch, before_id, since_id)
              mark = now
              !page.empty?
            end
            # Ran out empty with rows still unindexed: "no match" and "not indexed yet" would
            # read the same, the ambiguity the drain above the page refuses (read-only, or a
            # drain that kept losing the writer).
            if wait_ms > 0 && page.empty? && filter.uses_fts? && store.fts_dirty?
              return fts_backlog_error(store.fts_backlog, store.read_only?)
            end
          end
          page
        rescue ex
          return history_read_failed(ex, "list")
        end
        has_more = rows.size > limit
        # `since` tails OLDEST-first, so the extra row is the NEWEST one — dropping from the
        # end is right in both directions, since each read returns its own order already.
        rows = rows.first(limit) if has_more
        # Under REPLY_ROWS_BUDGET (#1649): a cut page is a short page with `has_more`, and its
        # cursor is the last row it carried, so paging resumes exactly there.
        rows = store.with_errors(rows)
        parts = fit_rows(rows) { |rj, r, _| Serialize.flow_row(rj, r, row_columns(r, prepared, include_sensitive, matcher)) }
        cut = parts.size < rows.size
        if cut
          rows = rows.first(parts.size)
          has_more = true
        end
        tailing = !since_id.nil?
        Result.new(JSON.build do |j|
          j.object do
            j.field "returned", rows.size
            j.field "limit", limit
            # Which end of the list the caller is holding. `since` flips the order, which the
            # schema documented and nothing in the payload did — so an agent reading rows[0]
            # as "the newest" was right on one path and wrong on the other.
            j.field "order", tailing ? "oldest_first" : "newest_first"
            j.field "has_more", has_more
            # The cursor to pass back, spelled as the argument it goes in, so continuing does
            # not require re-deriving which end of `flows` to read the id off.
            if last = rows.last?
              j.field(tailing ? "next_since" : "next_before_id", last.id)
            end
            emit_cut(j, cut)
            emit_ignored_terms(j, dropped)
            j.field("flows") { raw_rows(j, parts) }
          end
        end)
      end

      # The least time between two filtered `list_history` re-reads while a wait is held.
      HISTORY_REREAD_GAP = 1.second

      # What a `list_history` wait watches: the flow id high-water mark, which every capture
      # moves. A filtered tail also needs `data_version`, since a flow inserted at request
      # time can start matching `status:`/`body:` only once its response is written (an
      # update, which moves no id). ponytail: `data_version` is per pooled connection, so a
      # read off another connection can cost a spare re-read of the tail, or miss one change
      # until the next; a missed wake ends as the empty page, and the cursor keeps the row.
      private def history_mark(filtered : Bool) : {Int64?, Int64}
        {store.flow_id_high_water, filtered ? store.data_version : 0_i64}
      end

      private def history_rows(filter : QL::Filter, filtered : Bool, scope_unconfigured : Bool, fetch : Int32,
                               before_id : Int64?, since_id : Int64?) : Array(Store::FlowRow)
        if scope_unconfigured
          [] of Store::FlowRow
        elsif filtered
          store.search(filter, fetch, before_id, since_id, raise_on_error: true, control: history_control)
        else
          store.recent_flows(fetch, before_id, since_id)
        end
      end

      # The `count_only` path (#1648): the number of flows the compiled filter matches, from the
      # same filter the row path pages through. `in_scope` with no scope rules is 0, as the row
      # path is empty, and says why, since a bare 0 reads as "nothing captured".
      private def emit_history_count(filter : QL::Filter, scope_unconfigured : Bool, h,
                                     ignored : Array(String)) : Result
        count =
          begin
            scope_unconfigured ? 0_i64 : store.count_matching(filter, history_control)
          rescue ex
            return history_read_failed(ex, "count")
          end
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", count
            j.field "scope_configured", false if scope_unconfigured
            j.field "limit_ignored", true if present?(h, "limit")
            emit_ignored_terms(j, ignored)
          end
        end)
      end

      # A History read that yields to the reader fiber and stops when the client cancels the
      # call (`notifications/cancelled`): a full scan of a big project is seconds of the one
      # thread `gori mcp` has (P6).
      private def history_control : Store::QueryControl
        Store::QueryControl.new(cancel_signal)
      end

      # One answer for a History query that did not run, whichever path ran it: a 0 or an empty
      # page here would be a wrong answer wearing a right one's clothes.
      private def history_read_failed(ex : Exception, what : String) : Result
        return err("request cancelled", "CANCELLED") if ex.is_a?(Store::QueryCancelled)
        ::Log.warn { "list_history #{what} failed: #{ex.message}" }
        err("could not #{what} the matching flows — see gori.log; retry, or simplify the query",
          "INTERNAL", field: "query")
      end

      # The `ids` path: an exact named set, returned IN THE ORDER IT WAS ASKED FOR (#1091).
      #
      # Three things this must keep apart, because "fewer rows than I asked for" has three
      # different causes and only one of them is the caller's mistake:
      #
      #   * `missing_ids` — no such row. Reported, never dropped: a remembered id can be gone
      #     (or, before V39 made `flows.id` AUTOINCREMENT, belong to a different flow), and an
      #     agent replaying a stale set needs to hear it. Not a whole-call refusal, unlike
      #     `delete_repeaters`: this is a READ, retention or `clear_history` can legitimately
      #     have eaten one row, and refusing would cost the caller the rows that do exist.
      #   * `filtered_out_ids` — the row exists, and `query`/`view`/`in_scope` excluded it.
      #     Two narrowings are two narrowings, the same rule `view` already carries — but a
      #     narrowing that removed part of the operator's selection has to say so.
      #   * `limit_ignored` — the caller passed a page size to a call that is not a page.
      # `lensed` is whether a boolean lens (`in_scope`, `hide_static`) narrowed the filter.
      private def emit_history_ids(ids : Array(Int64), filter : QL::Filter, query : String?,
                                   view_filter : QL::Filter, lensed : Bool,
                                   scope_unconfigured : Bool,
                                   prepared : Gori::DisplayColumns::Prepared, h,
                                   ignored : Array(String)) : Result
        narrowed = (query && !query.strip.empty?) || lensed || view_filter != QL::EMPTY
        include_sensitive = bool_arg(h, "include_sensitive", false)
        matcher = columns_matcher(prepared, include_sensitive)
        found = store.flow_rows(ids)
        by_id = {} of Int64 => Store::FlowRow
        found.each { |r| by_id[r.id] = r }
        missing = ids.reject { |id| by_id.has_key?(id) }

        split = narrow_present_ids(by_id.keys, filter, narrowed, scope_unconfigured)
        return split if split.is_a?(Result)
        kept, dropped = split
        keep = kept.to_set
        drop = dropped.to_set
        rows = ids.compact_map { |id| keep.includes?(id) ? by_id[id] : nil }
        # Walked over `ids`, not over the SQL result set: `flows` is `order: "as_requested"`
        # and `missing_ids` follows the caller's order too, so a third list in rowid order
        # would silently misalign an agent zipping it against its own marked list.
        filtered_out = ids.select { |id| drop.includes?(id) }
        # Under REPLY_ROWS_BUDGET (#1649). A set has no cursor, so a cut names the rows it did
        # not carry, in the order asked: passing `remaining_ids` back as `ids` fetches the rest.
        rows = store.with_errors(rows)
        parts = fit_rows(rows) { |rj, r, _| Serialize.flow_row(rj, r, row_columns(r, prepared, include_sensitive, matcher)) }
        remaining = rows[parts.size..].map(&.id)

        Result.new(JSON.build do |j|
          j.object do
            j.field "returned", parts.size
            j.field "requested_ids", ids.size
            # Not "newest_first": these come back the way they were asked for, so a caller can
            # zip them against the id list it holds without re-sorting.
            j.field "order", "as_requested"
            j.field "has_more", !remaining.empty?
            unless remaining.empty?
              emit_cut(j, true)
              j.field "remaining_ids", remaining
            end
            if present?(h, "limit")
              j.field "limit_ignored", true
              j.field "limit_ignored_note",
                "'ids' names the whole page, so 'limit' was not applied#{remaining.empty? ? " — all #{rows.size} matching rows are here" : ""}"
            end
            unless missing.empty?
              j.field "missing_ids", missing
              j.field "missing_ids_note",
                "#{missing.size} of the #{ids.size} ids have no flow — deleted, or lost to retention. " \
                "A flow id is never reissued, so a missing id stays missing: re-read the set from " \
                "get_current_context rather than replaying a remembered one"
            end
            unless filtered_out.empty?
              j.field "filtered_out_ids", filtered_out
              j.field "filtered_out_note",
                scope_unconfigured ? "in_scope:true with no scope rules configured excludes every flow — #{add_scope_rule_hint}, or drop in_scope" : "#{filtered_out.size} of the ids exist but were excluded by 'query'/'view'/'in_scope'/'hide_static' — " \
                                                                                                                                                     "drop the narrowing to see them"
            end
            emit_ignored_terms(j, ignored)
            j.field("flows") { raw_rows(j, parts) }
          end
        end)
      end

      # Split the ids that DO have a row into {kept, excluded-by-the-filter}, or the Result that
      # refuses the call. Its own method so `emit_history_ids` stays flat enough to read — the
      # three-way distinction it feeds is the point of that method, not this arithmetic.
      private def narrow_present_ids(present : Array(Int64), filter : QL::Filter,
                                     narrowed : Bool,
                                     scope_unconfigured : Bool) : {Array(Int64), Array(Int64)} | Result
        # `in_scope` with no scope rules is empty everywhere else too; every id is excluded BY
        # THE FILTER, not absent — keeping the two apart is the whole point of the caller.
        return {[] of Int64, present} if scope_unconfigured
        return {present, [] of Int64} unless narrowed && !present.empty?
        matched = store.ids_matching(filter, present)
        # nil is "no answer", and reporting it as "none matched" is exactly the confusion
        # `Store#ids_matching` refuses to express through its return type.
        return err("could not evaluate the query against 'ids' — see gori.log; retry, or drop the query",
          "INTERNAL", field: "query") if matched.nil?
        {present.select { |id| matched.includes?(id) }, present.reject { |id| matched.includes?(id) }}
      end

      # The project's redaction profile for `columns`, resolved once per call: the same one
      # `get_flow` applies, under the same `include_sensitive` opt-out (see `redact_flow`).
      private def columns_matcher(prepared : Gori::DisplayColumns::Prepared, include_sensitive : Bool) : Redact::Matcher?
        include_sensitive || prepared.empty? ? nil : Redact::Policy.ambient(store)
      end

      # One row's user-column values as `{label, value}` pairs, or nil when none were asked for.
      #
      # ONE capped read per RETURNED row, and none at all for a set that reads only heads — the
      # same P8 discipline the TUI row loop keeps, applied to a page already bounded by `limit`.
      #
      # A column extracting a sensitive header or a cookie (`DisplayColumns.sensitive?`) reads
      # `[REDACTED]` unless `include_sensitive`, as `gori run history` masks the same column: the
      # schema's own example is `req:header:authorization`, and `get_flow` withholds that value
      # behind the same flag. An EMPTY value stays empty, so a miss still reads as a miss.
      private def row_columns(row : Store::FlowRow,
                              prepared : Gori::DisplayColumns::Prepared,
                              include_sensitive : Bool,
                              matcher : Redact::Matcher?) : Array({String, String})?
        return nil if prepared.empty?
        values = prepared.row_values(store, row.id, matcher)
        prepared.columns.map_with_index do |c, i|
          v = values[i]? || ""
          v = "[REDACTED]" if !include_sensitive && !v.empty? && Gori::DisplayColumns.sensitive?(c)
          {c.label, v}
        end
      end

      EVENTS_LIMIT = PageLimit.new(100, 500)

      # #124 AI event feed. Forward-cursored (id > since, oldest-first). next_cursor is the
      # max id SCANNED this page (NOT the max matched id), so source/kind filters never make
      # the agent re-scan or skip; on an empty page it echoes the input `since` (never 0,
      # never max-of-empty) so a no-new-events poll keeps the caller's place. A page the reply
      # budget cut (#1649) is the exception: the cursor is the last event it carried.
      @[Tool("list_events")]
      private def list_events(h) : Result
        since = optional_int_arg(h, "since") || 0_i64
        limit = clamp(optional_int_arg(h, "limit"), EVENTS_LIMIT)
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
        rows, next_cursor, full = events_page(since, limit, source, kind, actor)
        # `wait_ms`: re-read past the cursor each slice — a primary-key range read that finds
        # nothing is the cheap check. Only the feed's END is waited at: a full page the filters
        # emptied answers at once with its advanced cursor, or a stored match deep in a long
        # feed would be reached one page per slice.
        long_poll(wait_ms_arg(h)) do
          rows, next_cursor, full = events_page(next_cursor, limit, source, kind, actor)
          !rows.empty? || full
        end if rows.empty? && !full
        # Under REPLY_ROWS_BUDGET (#1649): a cut page resumes after the last event it carried.
        parts = fit_rows(rows) { |rj, r, _| Serialize.event_row(rj, r) }
        cut = parts.size < rows.size
        next_cursor = rows[parts.size - 1].id if cut
        Result.new(JSON.build do |j|
          j.object do
            j.field("events") { raw_rows(j, parts) }
            j.field "next_cursor", next_cursor
            emit_cut(j, cut)
          end
        end)
      end

      # One `list_events` page past `since`: the rows the filters keep, the max id scanned, and
      # whether the scan filled `limit` (more of the feed is stored past it).
      private def events_page(since : Int64, limit : Int32, source : String?, kind : String?,
                              actor : String?) : {Array(Store::EventRow), Int64, Bool}
        scanned = store.events_after(since, limit)
        next_cursor = scanned.empty? ? since : scanned.last.id
        rows = scanned
        rows = rows.select { |r| r.source == source } if source
        rows = rows.select { |r| r.kind == kind } if kind && !kind.empty?
        rows = rows.select { |r| r.actor == actor } if actor
        {rows, next_cursor, scanned.size >= limit}
      end

      @[Tool("get_flow", requires: ["get_response_body_chunk"])]
      private def get_flow(h) : Result
        id = required_id(h, "id")
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
        #
        # Only the frames `emit_ws_messages` shows (the OLDEST WS_MSGS_MAX), and the total from a
        # COUNT: a frame is up to 16 MiB, and every one past the cap used to be read,
        # redacted and decoded to be dropped.
        #
        # `ws_query` narrows the log in SQL BEFORE that cap, with the QL `ws` term's own
        # per-message predicate (`QL.ws_match`), so a match past the first 500 is reached.
        ws_match = nil
        if (wq = str(h, "ws_query")) && !wq.empty?
          unless ws_match = QL.ws_match(wq)
            return err("ws_query #{wq.inspect} #{QL::WS_MATCH_REFUSED}", "INVALID_ARGUMENT", field: "ws_query")
          end
        end
        ws_msgs = store.ws_messages_after(id, 0_i64, Serialize::WS_MSGS_MAX, ws_match)
        ws_total = ws_msgs.size < Serialize::WS_MSGS_MAX ? ws_msgs.size : store.count_ws_messages(id, ws_match)
        ws_socket_total = ws_match ? store.count_ws_messages(id) : nil
        include_sensitive = bool_arg(h, "include_sensitive", false)
        detail, ws_msgs, redaction = redact_flow(detail, ws_msgs, include_sensitive)
        # Not under a redaction profile: the chunk tool pages the EXACT stored bytes, which it
        # cannot redact, so pointing past a sanitized 8 KB would hand over what get_flow
        # withheld. Those flows keep the full default, as before the smaller one existed.
        auto = body_auto?(h) && redaction.nil?
        opts = body_return_opts(h, auto: auto)
        return opts if opts.is_a?(Result)
        cap, omit = opts
        more = auto ? {body_more_hint("flow_id: #{id}, part: \"request\"", "request, head included"), body_more_hint("flow_id: #{id}")} : nil
        Result.new(Serialize.flow_detail_json(detail, ws_msgs, include_sensitive, cap, omit, redaction, more,
          interims: store.interims(id), ws_total: ws_total, ws_socket_total: ws_socket_total,
          originals: rewrite_originals(detail, include_sensitive)))
      end

      # What Match&Replace or an Intercept edit replaced on each side (#1589), under the flow's own
      # body redaction — the original of a redacted body carries the same secret. An edited request
      # keeps the client's whole message (`Interceptor.original`), which a rule's record then
      # lacks, as History and `gori run show --original` read it.
      private def rewrite_originals(detail : Store::FlowDetail, include_sensitive : Bool) : Array(Serialize::Original)
        found = [] of Serialize::Original
        row = detail.row
        return found unless row.rewritten? || row.intercept_edited?
        matcher = include_sensitive ? nil : Redact::Policy.ambient(store)
        Store::RuleTarget.each do |side|
          orig = if side.request? && row.intercept_edited?
                   Gori::Interceptor.original(store, detail, side)
                 elsif row.rewritten?
                   store.rewrite_original(row.id, side)
                 end
          next unless orig
          head, body = orig
          if m = matcher
            clean = Redact::Wire.message(head, body, m)
            head, body = clean.head, clean.body
          end
          found << {side.label, head, body}
        end
        found
      end

      # Safe evidence export applied to the projection an AGENT reads (#1035).
      #
      # An agent transcript is the case the issue names first, and it is the one gori has least
      # control over once the bytes leave: a model quotes a flow into a ticket, a summary, a
      # commit message. So when this project redacts by default, `get_flow` hands back the
      # sanitized derivative and says so (`body_redaction`) — the store keeps the captured
      # octets, and `get_response_body_chunk` still pages them exactly.
      #
      # `include_sensitive` turns this OFF along with header redaction. One flag, both axes: an
      # agent that has been granted the Authorization header is not served half the credentials,
      # and an operator revoking that grant does not have to remember two switches.
      private def redact_flow(detail : Store::FlowDetail, ws_msgs : Array(Store::WsMessage),
                              include_sensitive : Bool) : {Store::FlowDetail, Array(Store::WsMessage), Serialize::RedactionNote?}
        return {detail, ws_msgs, nil} if include_sensitive
        matcher = Redact::Policy.ambient(store)
        return {detail, ws_msgs, nil} unless matcher
        clean, report = Redact::Wire.flow(detail, matcher)
        frames, ws_hits = Redact::Wire.ws_messages(ws_msgs, matcher)
        {clean, frames, Serialize::RedactionNote.new(matcher.profile.name, report.count,
          ws_hits.size, report.decoded?)}
      end

      # What `load_chunk_source` hands the pager: the head (nil where the source has none),
      # the stored bytes, and whether the CAPTURE cap already cut them. The third element is
      # the one that had no home before: gori records `response_body_truncated` on the row —
      # the proxy stops storing at 2 MiB — and this tool never read it, so a body cut at 2 KB
      # of a 2.5 GB transfer paged to its end and reported `complete:true`.
      alias ChunkSource = {Bytes?, Bytes?, Bool}

      # The ceiling is the default (#1649): a 256 KiB page JSON-encoded past the size a client
      # hands a model, and a larger request is clamped rather than refused.
      BODY_CHUNK_LIMIT = PageLimit.new(65_536, 65_536)
      # A binary page goes out as base64, a third larger than its bytes, so it is held to the
      # reply budget ENCODED.
      BASE64_CHUNK_MAX = REPLY_ROWS_BUDGET * 3 // 4

      @[Tool("get_response_body_chunk")]
      private def get_response_body_chunk(h) : Result
        options = body_chunk_options(h)

        loaded = load_chunk_source(options)
        return loaded if loaded.is_a?(Result)
        head, body, source_truncated = loaded
        view = Serialize.page_view(head, body || Bytes.new(0), request: options.request?, raw: options.raw,
          include_sensitive: options.include_sensitive) { |hd, stored| decode_for_chunk(hd, stored) }
        bytes = view.bytes
        decoded = view.decoded? ? bytes : nil
        decode_note, head_omitted, trailers_omitted = view.decode_note, view.head_omitted?, view.trailers_omitted?
        total = bytes.size.to_i64
        # The decoded view is capped at ContentDecode::MAX_OUT (decompression-bomb ceiling).
        # At the cap, `complete:true` at the end would falsely imply the whole body — flag it
        # so a caller knows more decoded data may exist and can page the wire bytes with raw:true.
        decode_capped = !decoded.nil? && decoded.size >= Proxy::Codec::ContentDecode::MAX_OUT
        if pattern = options.find
          return find_in_body(options, pattern, view, decode_capped, source_truncated)
        end
        # An offset past the end used to silently clamp to the body end (0 bytes,
        # complete:true) — indistinguishable from a legitimate final read. Surface
        # both the requested and the effective offset plus a warning so the caller
        # can tell a genuine end-of-body from a bad offset.
        requested = options.offset
        start = Math.min(requested, total).to_i
        offset_out_of_range = requested > total
        count = Math.min(options.limit, bytes.size - start)
        chunk = count.zero? ? Bytes.new(0) : bytes[start, count]
        text = String.new(chunk)
        # A page boundary through a multibyte codepoint: end this page before it so the page
        # stays text, and `next_offset` picks the split sequence up — pages still tile the bytes.
        if !text.valid_encoding? && start + count < bytes.size &&
           (whole = Serialize.utf8_whole_prefix(chunk)) < count && whole > 0 &&
           (trimmed = String.new(chunk[0, whole])).valid_encoding?
          count = whole
          chunk = chunk[0, whole]
          text = trimmed
        end
        # Valid UTF-8 can still JSON-escape to six bytes a byte (NUL padding is valid UTF-8), so
        # text that escapes past the budget goes out as budgeted base64 instead.
        force_base64 = text.valid_encoding? && text.to_json.bytesize > REPLY_ROWS_BUDGET
        base64_cut = (force_base64 || !text.valid_encoding?) && count > BASE64_CHUNK_MAX
        if base64_cut
          count = BASE64_CHUNK_MAX
          chunk = chunk[0, count]
          text = String.new(chunk)
        end
        next_offset = start.to_i64 + count

        Result.new(JSON.build do |j|
          j.object do
            j.field "flow_id", options.flow_id
            j.field "repeater_id", options.repeater_id
            j.field "part", options.part
            j.field "origin", options.request? ? "client" : "target" # as `emit_body` labels it (#1586)
            j.field "requested_offset", requested
            j.field "offset", start
            j.field "offset_out_of_range", true if offset_out_of_range
            j.field "warning", "requested offset #{requested} is past the #{total}-byte body; clamped to the end" if offset_out_of_range
            j.field "returned_bytes", count
            j.field "total_bytes", total
            emit_cut(j, base64_cut)
            if head_omitted
              j.field "head_omitted", true
              j.field "head_omitted_note",
                "the request head carries a sensitive header (#{Redact::SENSITIVE_HEADERS.to_a.sort.join(", ")}) " \
                "and this tool pages the EXACT stored bytes, which cannot be redacted and stay bytes — the range " \
                "below is the body alone. Pass include_sensitive:true to page the head too, or read it redacted " \
                "from get_flow / get_repeater_context"
            end
            if trailers_omitted
              j.field "trailers_omitted", true
              j.field "trailers_omitted_note",
                "the chunked body ends in a trailer section carrying a sensitive field, and these are the EXACT " \
                "stored bytes, so the range stops at the last-chunk line rather than redact them. Pass " \
                "include_sensitive:true to page the trailers too, or read them redacted from get_flow's `trailers`"
            end
            j.field "representation", decoded ? "decoded" : "raw"
            j.field "decode_note", decode_note if decode_note
            if decode_capped
              j.field "decode_capped", true
              j.field "decode_cap_warning", "decoded view capped at #{Proxy::Codec::ContentDecode::MAX_OUT} bytes (decompression-bomb ceiling); more decoded data may exist beyond this — page the raw wire bytes with raw:true"
            end
            # `complete` is about THE BODY, not about this page's arithmetic. Reaching the end
            # of a blob the capture cap already cut is not having the whole body — the same
            # distinction `decode_capped` above draws for the decompression ceiling, applied
            # to the cut that happens first and discards far more.
            j.field "complete", next_offset >= total && !source_truncated
            j.field "next_offset", next_offset < total ? next_offset : nil
            if source_truncated
              j.field "source_truncated", true
              j.field "source_truncated_warning",
                "gori stored only the first #{total} bytes of this #{options.request? ? "request" : "response"} " \
                "body — the capture cap cut the rest as it went past, and the discarded bytes exist nowhere. " \
                "Paging to the end of this range is NOT the whole body, which is why `complete` stays false. " \
                "Re-send the request (send_request) to capture it again under a larger cap"
            end
            if text.valid_encoding? && !force_base64
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
        limit = bounded_int_arg(h, "limit", BODY_CHUNK_LIMIT.default.to_i64, min: 1_i64, max: BODY_CHUNK_LIMIT.max.to_i64).to_i
        find = str(h, "find")
        raise Gori::Error.new("invalid 'find' (expected a non-empty regex)") if find.try(&.empty?)
        BodyChunkOptions.new(flow_id, repeater_id, offset, limit, bool_arg(h, "raw", false), part,
          bool_arg(h, "include_sensitive", false), find,
          bounded_int_arg(h, "max_matches", FIND_MATCHES.default.to_i64, min: 1_i64, max: FIND_MATCHES.max.to_i64).to_i,
          bounded_int_arg(h, "context", FIND_CONTEXT.default.to_i64, min: 0_i64, max: FIND_CONTEXT.max.to_i64).to_i)
      end

      FIND_MATCHES = PageLimit.new(20, 100)
      FIND_CONTEXT = PageLimit.new(40, BodyFind::CONTEXT_MAX)

      # `find`: a regex over the SAME bytes a page reads — after the same head/trailer
      # withholding and the same decode — so every match `offset` is an `offset` for this tool
      # with the same `part`/`raw`/`include_sensitive`, and a withheld credential is never
      # searched. The search starts at `offset`; `next_offset` continues it.
      private def find_in_body(options : BodyChunkOptions, pattern : String, view : Serialize::PageView,
                               decode_capped : Bool, source_truncated : Bool) : Result
        page = BodyFind.run(view.bytes, pattern, options.offset, options.max_matches, options.context)
        parts = fit_rows(page.matches) do |rj, m, _|
          rj.object do
            rj.field "offset", m.offset
            rj.field "length", m.length
            rj.field "snippet", m.snippet
          end
        end
        cut = parts.size < page.matches.size
        next_offset = cut ? page.matches[parts.size].offset : page.next_offset
        Result.new(JSON.build do |j|
          j.object do
            j.field "flow_id", options.flow_id
            j.field "repeater_id", options.repeater_id
            j.field "part", options.part
            j.field "origin", options.request? ? "client" : "target" # as the pager labels it (#1586)
            j.field "find", pattern
            j.field "offset", options.offset
            j.field "total_bytes", view.bytes.size
            j.field "representation", view.decoded? ? "decoded" : "raw"
            j.field "decode_note", view.decode_note if view.decode_note
            j.field "head_omitted", true if view.head_omitted?
            j.field "trailers_omitted", true if view.trailers_omitted?
            j.field "decode_capped", true if decode_capped
            j.field "source_truncated", true if source_truncated
            j.field "returned", parts.size
            j.field("matches") { raw_rows(j, parts) }
            emit_cut(j, cut)
            j.field "has_more", !next_offset.nil?
            j.field "next_offset", next_offset
            j.field "stopped", BodyFind::STOPPED if page.stopped
          end
        end)
      rescue ex : ArgumentError
        err("invalid 'find' regex: #{ex.message}", "INVALID_ARGUMENT", field: "find")
      end

      # The last response body `get_response_body_chunk` decoded: {head, stored bytes, decoded,
      # decode note}. One entry, because an agent pages ONE body front to back — and every page
      # used to inflate the whole thing again (up to ContentDecode::MAX_OUT, 32 MiB) to slice
      # 64 KiB out of it: 257 pages over a 16 MiB gzip body cost 1.1 s, nearly all of it decode.
      @body_chunk_memo : {Bytes?, Bytes, Bytes?, String?}? = nil

      # `ContentDecode.decode`, reusing the memo when the head and stored bytes are the SAME
      # BYTES it was computed from. Keyed on content, not on a flow id, on purpose: ids are not
      # AUTOINCREMENT, so a deleted flow's id comes back — from this server, or from the TUI
      # or another agent writing the same project — and a flow's response is written after
      # its request. A content key cannot serve bytes of any flow but the one just read, and
      # decode is deterministic, so a hit is exactly what a fresh decode would return. The
      # compare is a memcmp over bytes this call has already read, cheap next to an inflate.
      private def decode_for_chunk(head : Bytes?, stored : Bytes) : {Bytes?, String?}
        if (memo = @body_chunk_memo) && memo[0] == head && memo[1] == stored
          return {memo[2], memo[3]}
        end
        decoded, note = Proxy::Codec::ContentDecode.decode(head, stored)
        # Only a body that decoding changed is worth holding: for an identity body the page is
        # sliced from `stored` directly and there is nothing to save.
        @body_chunk_memo = decoded ? {head, stored, decoded, note} : nil
        {decoded, note}
      end

      # The bytes this chunk pages over: {head-for-decoding, payload}.
      private def load_chunk_source(options : BodyChunkOptions) : ChunkSource | Result
        return load_response_body(options.flow_id, options.repeater_id) unless options.request?
        if id = options.repeater_id
          repeater = store.get_repeater(id)
          return not_found("no repeater with id #{id}") unless repeater
          # The stored blob IS head+body, byte-exact — the same bytes `send_request
          # {repeater_id}` replays. That is exactly what a caller reading past
          # get_repeater_context's cap wants.
          {nil, repeater.request, false}
        elsif id = options.flow_id
          detail = store.get_flow(id)
          return not_found("no flow with id #{id}") unless detail
          # `get_flow` already returns a captured request head with a base64 companion; this
          # is the paged route to the same bytes plus the body, for a request too big to inline.
          {nil, Serialize.request_wire(detail.request_head, detail.request_body), detail.request_body_truncated?}
        else
          Result.new("pass exactly one of flow_id or repeater_id", is_error: true)
        end
      end

      # Hard-delete ONE captured flow (the TUI History tab's delete). Single and explicit,
      # so no extra confirmation — unlike clear_history.
      @[Tool("delete_flow", gated: true, agent_action: true, permission: "write")]
      private def delete_flow(h) : Result
        id = required_id(h, "id")
        # flow_row is the row-only read; get_flow would materialize both BLOBs to answer
        # "does this exist?" — a 40 MB response would be read and discarded.
        return not_found("no flow with id #{id}") unless store.flow_row(id)
        return busy("flow NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_flow(id)
        @body_chunk_memo = nil # correct either way (content-keyed); this just frees the buffer
        Result.new({id: id, deleted: true}.to_json)
      end

      # Wipe EVERY captured flow. The TUI puts a danger confirm in front of this; here
      # confirm:true is that gate. Without it we report the count and refuse, so a
      # mis-issued call cannot silently empty a capture session.
      @[Tool("clear_history", gated: true, agent_action: true, permission: "write")]
      private def clear_history(h) : Result
        n = store.count?
        return busy("history NOT cleared (store busy); every flow is still there") unless n
        unless bool_arg(h, "confirm", false)
          return err("refusing to delete #{Gori.plural(n, "flow")} without confirm:true — this cannot be undone",
            "CONFIRM_REQUIRED", field: "confirm",
            details: JSON.parse({"flows" => n}.to_json))
        end
        return busy("history NOT cleared (store busy or unwritable); every flow is still there") unless store.clear_flows
        @body_chunk_memo = nil
        Result.new({"deleted" => n, "cleared" => true}.to_json)
      end

      private def load_response_body(flow_id : Int64?, repeater_id : Int64?) : ChunkSource | Result
        if id = flow_id
          # The response side only: the request BLOBs are never paged here, and `get_flow`
          # read them for every page.
          parts = store.response_parts(id)
          return not_found("no flow with id #{id}") unless parts
          # No head = no response yet (pending, or the upstream never answered). Paging that as
          # a 0-byte complete body read exactly like a real empty 204.
          return not_found("no response captured for flow #{id}") unless parts[0]
          parts
        elsif id = repeater_id
          repeater = store.get_repeater_full(id)
          return not_found("no repeater with id #{id}") unless repeater
          return not_found("no response captured for repeater #{id} (never sent)") unless repeater.response_head
          # A repeater response is a send this process made and kept whole; nothing capped it
          # on the way in, so there is no capture cut to report.
          {repeater.response_head, repeater.response_body, false}
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
          "List captured HTTP flows, newest first, as light rows (no bodies; get_flow for " \
          "detail). Optional gori QL `query`, e.g. 'host:example.com status:>=500 size:>10000 " \
          "dur:>500', 'header:set-cookie', 'body~secret\\d+' (`~` = regex, dur in ms; " \
          "ql_reference for full syntax). Returns " \
          "{flows, returned, limit, order, has_more, next_before_id | next_since}, not a bare " \
          "array. Page OLDER: pass `next_before_id` as `before_id` until `has_more` is false. " \
          "TAIL newer: pass `since`; rows come OLDEST-first; pass `next_since` back; an empty " \
          "page = no new flows (keep your cursor)." do |s|
          s.field "query", strprop("gori QL filter; empty = most recent")
          s.field "ids", id_list_prop(
            "fetch EXACTLY these flow ids (e.g. get_current_context `selection.ids`), max " \
            "#{MCP_HISTORY_IDS_MAX}. Rows keep the ORDER ASKED (`order`: \"as_requested\"); " \
            "`limit` ignored, cursors refused. Ids with no row are in `missing_ids` (ids are never " \
            "reissued), ids `query`/`view`/`in_scope`/`hide_static` removed in `filtered_out_ids`, " \
            "ids past the size budget in `remaining_ids` to pass back")
          s.field "limit", limitprop("max rows", HISTORY_LIMIT)
          s.field "before_id", intprop("cursor: page OLDER — only flows with id < this")
          s.field "since", intprop("cursor: tail NEWER — only flows with id > this, oldest-first; exclusive with before_id")
          s.field "wait_ms", intprop("with since: wait up to this many ms for a new flow instead of an empty page (max #{LONG_POLL_MAX_WAIT_MS})")
          s.field "view", strprop("saved History view name (list_views), ANDed with `query`; unknown names are refused. Built-ins: #{SavedViews.builtin_names}")
          s.field "in_scope", boolprop("only flows in the configured scope (empty when none); QL `scope:in`/`scope:out` give finer control")
          s.field "hide_static", boolprop("omit static assets (images, fonts, audio/video; never svg/css/js or status >= 400); = QL `-static:true`")
          s.field "strict", boolprop("refuse a query with an invalid term (else it is dropped, BROADENING the result, and named in `ignored_terms`; ql_explain previews which would drop)")
          s.field "lenient", boolprop("free-text an unknown `field:` instead of refusing (a typo then matches nothing, like an empty project)")
          s.field "columns", strarrprop("extract a value from each flow onto the row's `columns`. Spec [LABEL=][req|res:]kind:selector, kind cookie|header|regex|position|jsonpath, e.g. \"req:header:authorization\", \"RID=jsonpath:data.id\"; side defaults to response. \"\" is a MISS, not an empty value. Sensitive header/cookie columns read \"[REDACTED]\" unless include_sensitive. Each costs a read per row (body kinds up to 512 KiB)")
          s.field "include_sensitive", boolprop("unredact sensitive `columns`")
          s.field "count_only", boolprop("return only {count} of matching flows; refuses `ids`/`before_id`/`since`/`columns`")
        end

        tool j, "list_events",
          "Tail the event feed: job lifecycle, agent actions, denied MCP permissions. Pass " \
          "`since` = the last `next_cursor`, which never moves backward (an empty page echoes " \
          "it). Filters do NOT affect `next_cursor` (max SCANNED id, or the last event returned " \
          "when `cut_by` says the page was cut). `actor` (tui | cli | mcp) tells your writes " \
          "from the operator's; `actor_label` names an agent's client." do |s|
          s.field "since", intprop("cursor: only events with id > this (default 0 = from oldest)")
          s.field "limit", limitprop("max events scanned", EVENTS_LIMIT)
          s.field "source", enumprop("filter to one producer of feed rows", EVENT_SOURCES)
          s.field "actor", enumprop("filter to the surface that acted; background-engine rows name none", EVENT_ACTORS)
          s.field "kind", strprop("filter to one kind (e.g. job_done, agent_action, scope_add)")
          s.field "wait_ms", intprop("wait up to this many ms for a matching event instead of an empty page (max #{LONG_POLL_MAX_WAIT_MS})")
        end

        tool j, "operator_messages",
          "Messages the OPERATOR typed for you in the gori TUI. Delivered live when possible, " \
          "else as a `[gori]` block beside your next gori tool result; this is the fallback: " \
          "call it at turn start or when a `[gori]` note points here, and act on them. " \
          "Live-delivered ones are omitted unless `include_delivered`. Pass `next_cursor` back " \
          "as `since`. Each names the operator's tab and marked flow ids." do |s|
          s.field "since", intprop("feed cursor from the previous call (0 = from the start)")
          s.field "limit", limitprop("max messages to return", OPERATOR_MESSAGES_LIMIT)
          s.field "include_delivered", boolprop("also return messages a live route already carried")
          s.field "wait_ms", intprop("wait up to this many ms for a message instead of an empty page (max #{LONG_POLL_MAX_WAIT_MS})")
        end

        if @allow_actions
          tool j, "reply_to_operator",
            "Answer the operator in the gori TUI (an answer or a task outcome, not narration). " \
            "A NOTIFICATION, not a mailbox: shown only in a TUI open on this project, so keep " \
            "what must last in your own output. The result's `tui` says whether a window was " \
            "open (`windows: 0` = nobody saw it)." do |s|
            s.field "summary", strprop("ONE line (≤200 characters) for the notification ring; more goes in detail"), required: true
            s.field "detail", strprop("long form, opened from the ring; ≤32 KiB")
            s.field "level", enumprop("ring colour (default info)", %w[info success warn error])
            s.field "in_reply_to", intprop("the operator_messages id this answers")
          end

          tool j, "ask_operator",
            "Put a decision to the operator as a choice card in the gori TUI. Returns its `id` " \
            "at once: the answer arrives later as an operator message with `in_reply_to` = that " \
            "id and `outcome` answered | dismissed | expired. It is the operator's decision, not " \
            "an authorization: scope and your own limits still apply." do |s|
            s.field "question", strprop("one line, ≤200 characters"), required: true
            s.field "choices", strarrprop("2 to 4 distinct one-line labels, ≤40 columns each (CJK/emoji count 2)"), required: true
            s.field "detail", strprop("context under the question; ≤32 KiB")
            s.field "default", strprop("the choice the card starts on; one of choices")
            s.field "expires_in_minutes", intprop("minutes until it comes back expired (default 30, max 1440)")
          end
        end

        tool j, "get_flow",
          "Full request+response for one flow: heads + decoded bodies (UTF-8 inline, else a " \
          "base64 sample). Authorization/Cookie/Set-Cookie/API-key values are [REDACTED] " \
          "unless include_sensitive. Under a redaction profile BODIES are sanitized too (equal " \
          "values share a [REDACTED:tag]) and `body_redaction` says what ran; absent field = " \
          "captured bytes. Continue a cut body with get_response_body_chunk." do |s|
          s.field "id", intprop("flow id from list_history"), required: true
          s.field "include_sensitive", boolprop("unredact credential headers, and return captured bodies instead of the redaction profile's copy")
          s.field "body_mode", enumprop("body inlining. Default: up to #{AUTO_BODY_BYTES} bytes, longer cut with a `more` pointer (full under a redaction profile); full: up to #{Serialize::MAX_TEXT}; preview: a small head; none: shape only", BODY_MODES)
          s.field "max_body_bytes", intprop("cap inlined body bytes (clamped to 65536)")
          s.field "ws_query", strprop("QL ws term (ws:needle or ws~regex) narrowing ws_messages before the #{Serialize::WS_MSGS_MAX} cap; count is then the matched total, ws_total the socket's")
        end

        tool j, "get_response_body_chunk",
          "Read a byte range of a stored message that get_flow / send_request / " \
          "get_repeater_context reported truncated. Decodes content encoding by default so " \
          "offsets continue the inline view (a request part is exact stored bytes). Returns " \
          "text or base64 + next_offset/complete; a past-the-end offset is clamped and flagged. " \
          "Exactly one of flow_id / repeater_id. " \
          "`complete:true` = the WHOLE body; on a message the capture cap cut it stays false " \
          "with `source_truncated`: those bytes exist nowhere — re-send, do not page further." do |s|
          s.field "flow_id", intprop("History flow id")
          s.field "repeater_id", intprop("Repeater workbench database id")
          s.requires_one_of "flow_id", "repeater_id"
          s.field "part", enumprop("stored blob to page (default response); a repeater's request is the exact blob send_request replays", MESSAGE_SIDES)
          s.field "offset", intprop("zero-based byte offset (default 0)")
          s.field "limit", limitprop("bytes to return", BODY_CHUNK_LIMIT)
          s.field "raw", boolprop("page stored response wire bytes without content decoding")
          s.field "include_sensitive", boolprop("also page a request HEAD or chunked TRAILERS carrying a credential; otherwise withheld (head_omitted / trailers_omitted)")
          s.field "find", strprop("regex (as QL body~): return {offset, length, snippet} matches from `offset` on instead of a page")
          s.field "max_matches", limitprop("find: max matches", FIND_MATCHES)
          s.field "context", intprop("find: snippet bytes each side (default #{FIND_CONTEXT.default}, max #{FIND_CONTEXT.max})")
        end

        return unless @allow_actions

        tool j, "delete_flow",
          "Hard-delete one captured flow from History. Cannot be undone." do |s|
          s.field "id", intprop("flow id"), required: true
        end

        tool j, "clear_history",
          "Delete EVERY captured flow in the project. Cannot be undone. Without confirm:true " \
          "the call is refused and reports how many flows it would delete." do |s|
          s.field "confirm", boolprop("must be true to actually delete"), required: true
        end
      end
    end
  end
end
