require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "../settings"
require "./highlight"
require "./text_area"
require "./url"
require "../interceptor"
require "../store"
require "../fuzz/content_length"
require "../env"

module Gori::Tui
  # The Intercept tab: a queue of held requests/responses (P4 — the human decides
  # to Forward or Drop each one; the proxy fiber blocks until then). Left: the
  # queue (REQ/RES badge, method, host+target, waiting age). Right: the selected
  # item's raw bytes in a TextArea (editable — Forward sends the edited bytes).
  # Pure view: it reads the shared Interceptor snapshot; the Runner performs the
  # actual forward/drop. No diff (that's Repeater's job).
  class InterceptView
    # Height of the top filter bar (catch direction + condition), reserved above the
    # queue|detail split — the Intercept tab's analogue of History's QL bar. While the
    # condition is being edited a second row carries Tab suggestions (see bar_h).
    FILTER_BAR_H = 1
    # Standing hint on the suggestion row at a cold start (editing, but nothing typed
    # yet to complete), so the condition language is discoverable the moment `/` opens.
    # Example values double as syntax cues; keep in sync with InterceptFilter::FIELDS.
    # `proto:ws` earns its own note: it is not a narrowing term but the WebSocket hold's
    # OPT-IN, and without it no WS message is held however permissive the rest is (#500).
    QUERY_HINT = "fields:  host:  path:  method:  scheme:  status:  proto:  body:    ·    proto:ws opts WS messages IN    ·    AND OR NOT ( ) combine  ·  -term negates"

    # How much of a held WebSocket payload the queue row previews. A row is one line, and
    # the detail pane is where the message is actually read.
    WS_LABEL_MAX = 120

    getter? editing : Bool
    getter? querying : Bool
    getter query : String

    def initialize
      @items = [] of Interceptor::Item
      @selected = 0
      @scroll = 0
      @editor = TextArea.new
      @editor.gutter = true   # line numbers in the held-message editor (pairs with ^G)
      @editor.follow_x = true # long lines (headers, URLs) scroll horizontally to keep the cursor visible
      @editing = false
      # Filter bar: the catch direction + on/off mirror the Interceptor (captured on
      # reload, rendered as chips); the condition query is a local edit buffer pushed
      # to the Interceptor on every keystroke (live, like History's filter).
      @enabled = false
      @direction = Interceptor::Direction::Both
      @querying = false
      @query = ""
      @qcx = 0
      @preedit = ""
      # Weak back-pointer for `host:` Tab suggestions, handed over when the bar opens.
      # Nil until then — suggestions simply skip the host pool. The DISTINCT query is
      # memoised on the typed prefix so a keystroke doesn't re-hit SQLite.
      @suggest_store = nil.as(Store?)
      @host_suggest_prefix = nil.as(String?)
      @host_suggest_values = [] of String
      @loaded_id = nil.as(Int64?) # which item the editor currently holds
      @editor_dirty = false       # whether the held bytes were actually edited (vs just viewed)
      # Whether the LOADED item is a WebSocket message. Captured when the editor takes the
      # bytes rather than looked up per call: `pending_edit` must know before it touches the
      # buffer, and by then the item can already have left the queue (forwarded cross-process
      # by an MCP peer, reaped, released) — at which point a lookup would fall back to the
      # HTTP path and splice a `Content-Length:` line into a payload with no head.
      @loaded_ws = false
      # "Update Content-Length" (Burp's option name), default ON — see
      # `toggle_content_length_sync`. Session-wide rather than per-item: it is a property of
      # how the operator is working, and an intercept queue is transient anyway.
      @sync_content_length = true
      # Cached highlight of the selected held item's bytes (read-only detail pane).
      # Held bytes are immutable, so the item id + theme is the base cache key —
      # recomputed only when the selection/theme changes, not every render. The loaded
      # item's IN-PROGRESS edit is the exception: its preview must show the edited bytes
      # (not the original), so @detail_win_edit_rev folds the editor's change counter into
      # the key and the preview refreshes as those bytes change (same item id).
      @detail_win = nil.as(Highlight::Windowed?)
      @detail_win_id = nil.as(Int64?)
      @detail_win_rev = Theme.revision # the theme the cached (colour-baked) head was built under
      @detail_win_edit_rev = -1        # @editor.edits the preview was built at (-1 = built from the pristine held bytes)
      @detail_xscroll = 0              # horizontal scroll offset for the read-only held-item preview
      @detail_scroll = 0               # vertical scroll offset (lines) for the read-only preview
      @reload_rev = -1                 # Interceptor#revision the queue snapshot was last taken at (-1 ⇒ never)
      # Multi-select marks (#442's model, ported to the hold queue), keyed by ITEM ID rather
      # than row index: a forward/drop of an earlier entry shifts every index below it, so an
      # index-keyed set would silently retarget on the next revision tick. Unlike History there
      # is no hidden-mark case — `pending` returns exactly what the queue renders — so reload
      # prunes ids that have left the queue and marks stay a subset of what's on screen.
      @marks = Set(Int64).new
      @mark_anchor = nil.as(Int64?) # id-keyed range anchor for the ⇧arrow extend
      # Ids THIS ⇧arrow gesture added (vs a deliberate `t`/⇧T mark) — the set a plain arrow
      # hands back, and the set a shrinking range gives up. Cleared whenever the anchor resets.
      @mark_extent = Set(Int64).new
    end

    # Fresh snapshot (called on enter AND every frame via the 50ms loop). Gated on the
    # Interceptor's lock-free revision counter: every mutation that changes what this
    # method reads — a hold/forward/drop/clear, or an enable/direction/filter change —
    # bumps it, so an unchanged counter means the queue snapshot + @enabled/@direction
    # are still current. Skipping then avoids a per-frame mutex lock + Array alloc +
    # linear re-anchor scan on the common idle frame (spinner tick, clock, unrelated key).
    # Re-anchors selection by item id (not index) so forward/drop of an earlier
    # queue entry does not silently move the highlight onto a different hold.
    # If the edited item vanished (forwarded/dropped/released), drop edit mode.
    def reload(interceptor : Interceptor) : Nil
      rev = interceptor.revision
      return if rev == @reload_rev
      @reload_rev = rev
      prev_id = @items[@selected]?.try(&.id)
      @items = interceptor.pending
      @selected =
        if prev_id && (idx = @items.index { |it| it.id == prev_id })
          idx
        else
          @selected.clamp(0, {@items.size - 1, 0}.max)
        end
      @enabled = interceptor.enabled?
      @direction = interceptor.direction
      prune_marks
      if @editing && (id = @loaded_id) && @items.none? { |it| it.id == id }
        @editing = false
        @loaded_id = nil
      end
    end

    # Drop marks whose held item has left the queue — forwarded/dropped here, by a batch
    # verb, or cross-process by an MCP peer. Held ids are monotonic and never reused, so a
    # stale mark can never retarget a different message; it would only inflate the count and
    # make the chip lie about a set that is no longer there.
    private def prune_marks : Nil
      return if @marks.empty?
      live = @items.map(&.id).to_set
      return if @marks.all? { |id| live.includes?(id) }
      @marks &= live
      @mark_extent &= live
      @mark_anchor = nil unless @mark_anchor.try { |a| live.includes?(a) }
    end

    def selected_item : Interceptor::Item?
      @items[@selected]?
    end

    def selected_id : Int64?
      selected_item.try(&.id)
    end

    # The cursor's queue index (mouse dispatch readability; mirrors HistoryView#selected_index).
    def selected_index : Int32
      @selected
    end

    def empty? : Bool
      @items.empty?
    end

    def move(delta : Int32) : Nil
      return if @items.empty? || @editing
      @selected = (@selected + delta).clamp(0, @items.size - 1)
      reset_mark_anchor # a plain move re-seeds the range anchor, like a GUI list
    end

    # At the first (top) queue item (and not editing) — lets the Runner pop focus
    # to the tab bar on ↑.
    def at_top? : Bool
      !@editing && @selected == 0
    end

    # --- marks (multi-select over the hold queue) -----------------------------

    def marked?(id : Int64) : Bool
      @marks.includes?(id)
    end

    def mark_count : Int32
      @marks.size
    end

    # Marks in QUEUE order. `pending` yields the Hash's insertion order — held ids are handed
    # out by an increasing counter, so sorting by id reproduces exactly what the list shows.
    def marked_ids : Array(Int64)
      @marks.to_a.sort!
    end

    # The effective target set every batch verb acts on: the marks if any are set, else the
    # cursor row. One rule, so forward/drop need no notion of "batch mode".
    def target_ids : Array(Int64)
      return marked_ids unless @marks.empty?
      [selected_id].compact
    end

    # `t` — flip the cursor row's mark, then step DOWN one, so a run of `t` marks consecutive
    # holds. Plainly +1 (not History's follow-aware "next older"): the queue is insertion-
    # ordered with no follow mode and no reversible sort. The anchor lands on the row just
    # toggled, so `t` then ⇧↓ extends from it.
    #
    # The step CLAMPS at the last row, so one more `t` there lands on the row it just marked
    # and takes the mark back off. Same as History at its own clamped end, and deliberate:
    # a mark-only variant would leave the bottom hold with no way to un-mark it by key at all.
    def toggle_mark : Nil
      return unless id = selected_id
      @marks.includes?(id) ? @marks.delete(id) : @marks.add(id)
      step_cursor(1)
      @mark_anchor = id
      @mark_extent.clear
    end

    # ⇧T — mark every held message currently queued (the queue's Ctrl+A).
    def mark_all : Nil
      @items.each { |it| @marks.add(it.id) }
      @mark_anchor = selected_id
      @mark_extent.clear
    end

    def clear_marks : Nil
      @marks.clear
      reset_mark_anchor
    end

    # Forget where a range gesture started (and what it had added), so the next ⇧arrow
    # anchors at the cursor instead of sweeping back to a stale point.
    private def reset_mark_anchor : Nil
      @mark_anchor = nil
      @mark_extent.clear
    end

    # End a ⇧arrow range gesture AND hand back everything it marked — what letting go of ⇧
    # and pressing a plain arrow does in a GUI list, where the highlight collapses instead of
    # being left behind (#442/#457). Only the gesture's own ids go (@mark_extent): `t`/⇧T
    # marks are deliberate tags, and dropping those too would put a discontiguous set out of
    # reach. Returns how many marks it gave back, so the caller can say so.
    def end_mark_gesture : Int32
      before = @marks.size
      @mark_extent.each { |id| @marks.delete(id) }
      reset_mark_anchor
      before - @marks.size
    end

    # ⇧↑/⇧↓ — extend a contiguous range from the anchor, the keyboard form of a GUI
    # shift+click. The anchor is seeded from the cursor when it's unset or gone (a plain
    # move/click clears it), so the first ⇧arrow always starts from where you are.
    def extend_marks(delta : Int32) : Nil
      return if @items.empty?
      anchor_idx = @mark_anchor.try { |a| @items.index { |it| it.id == a } }
      unless anchor_idx
        @mark_anchor = selected_id
        anchor_idx = @selected
        @mark_extent.clear
      end
      step_cursor(delta)
      lo, hi = {anchor_idx, @selected}.minmax
      wanted = Set(Int64).new
      (lo..hi).each { |i| @items[i]?.try { |it| wanted.add(it.id) } }
      # Give back what THIS gesture added but the new range no longer covers, so ⇧↑ after
      # ⇧↓⇧↓ leaves two rows marked rather than three. A mark made earlier by `t`/⇧T survives
      # a range sweeping over it and back off, since it was never in @mark_extent.
      (@mark_extent - wanted).each { |id| @marks.delete(id) }
      added = wanted - @marks
      @marks.concat(added)
      @mark_extent = (@mark_extent & wanted) | added
    end

    # Cursor step used by the mark gestures. Deliberately NOT `move` — that no-ops while
    # editing and is also the wheel's path; this one only ever runs from the queue's keyboard
    # gestures. Clamps, so it saturates at both ends instead of wrapping.
    private def step_cursor(delta : Int32) : Nil
      return if @items.empty?
      @selected = (@selected + delta).clamp(0, @items.size - 1)
    end

    # A still-held item by id (nil once it has been forwarded/dropped) — lets the controller
    # name a batch target with the same `intercept_label` it uses for the cursor row.
    def item_by_id(id : Int64) : Interceptor::Item?
      @items.find { |it| it.id == id }
    end

    # --- catch-condition filter bar (a text sub-mode; mirrors History's QL bar) ---
    # `store` (optional) backs `host:` Tab-completion; without it every other field
    # still completes from its static pool.
    def start_query(store : Store? = nil) : Nil
      @querying = true
      @qcx = @query.size
      @suggest_store = store
      @host_suggest_prefix = nil # invalidate: peers may have captured new hosts since
    end

    def stop_query : Nil # Enter: keep the condition, leave edit mode
      @querying = false
    end

    def cancel_query : Nil # Esc: clear the condition, leave edit mode
      @querying = false
      @query = ""
      @qcx = 0
      @preedit = ""
    end

    def query_insert(ch : Char) : Nil
      @query = "#{@query[0, @qcx]}#{ch}#{@query[@qcx..]}"
      @qcx += 1
    end

    def query_backspace : Nil
      return if @qcx == 0
      @query = "#{@query[0, @qcx - 1]}#{@query[@qcx..]}"
      @qcx -= 1
    end

    def query_move(d : Int32) : Nil
      @qcx = (@qcx + d).clamp(0, @query.size)
    end

    # Tab: splice the first suggestion over the token under the caret. False when there
    # is nothing to complete, so the caller can leave the query untouched.
    def query_complete : Bool
      sugg = query_suggestions
      return false if sugg.empty?
      cur = FilterAst.token_at(@query, @qcx)
      @query = "#{@query[0, cur.start]}#{sugg.first}#{@query[cur.stop..]}"
      @qcx = cur.start + sugg.first.size
      true
    end

    def query_suggestions : Array(String)
      InterceptFilter.suggestions(@query, @qcx, host_suggestions)
    end

    # DISTINCT hosts for the `host:` pool, memoised on the typed prefix (single-entry,
    # like History's) so holding a key doesn't issue a query per keystroke.
    private def host_suggestions : Array(String)
      core = FilterAst.token_at(@query, @qcx).core
      return [] of String unless (colon = core.index(':')) && core[0...colon].downcase == "host"
      prefix = FilterAst.unquote_prefix(core[(colon + 1)..])
      key = prefix.downcase
      return @host_suggest_values if @host_suggest_prefix == key
      store = @suggest_store
      @host_suggest_prefix = key
      @host_suggest_values = store ? store.distinct_hosts(prefix: prefix, limit: 16) : [] of String
      @host_suggest_values
    end

    # Live IME composition shown underlined ahead of the committed query; cleared
    # when a char commits (same model as the History bar / TextArea).
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def toggle_edit : Nil
      if @editing
        @editing = false
      elsif (it = selected_item) && !it.binary?
        # Only reload from pristine bytes when switching to a DIFFERENT held item; re-entering
        # edit on the same item (Esc/Shift-Tab then back) must preserve the in-progress edit,
        # mirroring detail_window_for's @detail_win_id guard.
        if @loaded_id != it.id
          @editor.set_text(String.new(it.raw))
          @editor_dirty = false # freshly loaded — not yet modified
        end
        @loaded_id = it.id
        @loaded_ws = it.kind.ws?
        @editing = true
      end
    end

    # A held WebSocket BINARY message (opcode 2) is holdable, forwardable and droppable but
    # NOT editable: the TextArea round trip is `String.new(raw)` → char ops → `.to_slice`,
    # which is lossy on non-UTF-8. That hazard exists for a held HTTP body too (a JPEG
    # response), but on WebSocket it is the COMMON case — opcode 2 is protobuf/msgpack/CBOR,
    # not an exception — so it is refused rather than left to corrupt the message silently.
    def read_only_selection? : Bool
      !!selected_item.try(&.binary?)
    end

    def stop_edit : Nil
      @editing = false
    end

    # The forward payload. An UNEDITED forward (editor never opened, or opened to view
    # only) returns the original raw bytes BYTE-EXACT (P7) — so merely inspecting a
    # held message can't mutate it, and a deliberately CL-mismatched smuggling probe
    # forwards untouched. Only an ACTUAL edit returns the editor's bytes, with
    # Content-Length recomputed to match the edited body (Burp's "update
    # Content-Length", default on; add_when_missing: true so adding a body to a GET
    # that had none still gets framed). The proxy itself stays byte-exact — the
    # update-CL decision lives here, in the human's editor, not the wire path. An edit now
    # keeps every line's ORIGINAL terminator (TextArea#wire_text), so editing the head leaves
    # the body byte-identical; only the head is normalized to CRLF, which is where CRLF is
    # required. The one thing an edit still changes on its own is Content-Length, deliberately.
    def forward_bytes(it : Interceptor::Item) : Bytes
      edit = pending_edit
      (edit && edit[0] == it.id) ? edit[1] : it.raw
    end

    # The {id, edited-bytes} of the currently-loaded held item IFF it has an unsaved edit,
    # else nil. Keyed by @loaded_id (the item the editor holds) rather than the queue
    # selection, so "forward all" can pick up an in-progress edit for whichever item is
    # loaded even when the cursor has since moved to a different row.
    # A WebSocket message payload is taken VERBATIM, and the kind gate comes before anything
    # else touches the buffer, because both of the steps below corrupt it:
    #
    #   * `ContentLength.sync(add_when_missing: true)` is the editor's "update
    #     Content-Length" affordance. On a WS payload there is no head to update, so
    #     `add_when_missing` splices a `Content-Length: N` header LINE into the message body
    #     — #513's `restore_content_length` trap with nothing to restore it from.
    #   * `Env.expand_wire` rewrites bare LF to CRLF across the head. A WS payload has no
    #     head/body boundary, so a pretty-printed JSON message would silently change length
    #     and content on every edit.
    #
    # Env substitution is dropped along with it rather than downgraded to `Env.expand`: in a
    # head a `$` starts a reference and in a body it is a byte, and a WS payload is all body.
    def pending_edit : {Int64, Bytes}?
      id = @loaded_id
      return nil unless id && @editor_dirty
      # `wire_text`, NOT `text` — a WS payload is opaque bytes with no line structure at all,
      # so it has to come back exactly as it was loaded. (`to_bytes` would be worse still: it
      # joins with CRLF because it exists for wire HEADS.)
      return {id, @editor.wire_bytes} if @loaded_ws
      # `wire_text` again, for the same reason the Repeater's send path reads it: `text` is the
      # LF projection, so an edit to a HEADER used to rewrite the BODY — every CR deleted and
      # Content-Length silently resynced down to match. That is the "I only changed one header"
      # case, which is most intercept edits, and it shipped different bytes to a live target.
      # `Env.expand_wire` (gsub `/\r?\n/`) not `split('\n').join("\r\n")`: a `$KEY` value
      # carrying a CRLF would otherwise double into `\r\r\n` and corrupt the forwarded bytes.
      #
      # `Escape::Consume`: a forward goes STRAIGHT to the origin — there is no send-seam
      # `expand_bindings` after this the way there is on every Repeater/Fuzzer path — so this
      # pass is the last one and therefore the one that owes the operator `$$` → `$`.
      raw = Env.expand_wire(@editor.wire_text, escape: Env::Escape::Consume)
      # `@sync_content_length` (^L) — see its toggle. When it is OFF the operator's declared
      # value goes out as written. When it is on the rewrite has ALREADY been reflected into
      # the visible buffer by `reflect_content_length_in_editor`, so the call below is
      # normally a no-op that only catches a `$KEY` whose expansion changed the body length.
      return {id, raw} unless @sync_content_length
      {id, Fuzz::ContentLength.sync(raw, add_when_missing: true)}
    end

    # Why gori would REFUSE the current pending edit, or nil when it would apply it.
    #
    # A QUERY beside `pending_edit`, not a change to it: the editor keeps showing what the
    # operator typed, and only the FORWARD consults this. `Item#refuse_edit` is the single definition of the answer — the CLI/MCP drain
    # (`Runner#apply_intercept_command`) has asked it since R3-F1, and this path did not, so a
    # human editing an h2 message whose head has no HTTP/1.1 text form got `forwarded …` in
    # the status bar while the ORIGINAL request went on the wire byte for byte.
    #
    # Nil when the editor is clean: an unedited forward is byte-exact, so there is no edit to
    # refuse — inspecting a held message must never make it unforwardable.
    def refused_edit : {Interceptor::Item, String}?
      edit = pending_edit
      return nil unless edit
      item = item_by_id(edit[0])
      return nil unless item
      reason = item.refuse_edit(edit[1])
      reason ? {item, reason} : nil
    end

    # Whether a forward recomputes `Content-Length` from the edited body (Burp's "Update
    # Content-Length"; default on).
    #
    # It had no switch at all, and it is unconditional the moment the editor is dirty — so
    # the one edit an intercept editor exists for could not be made. A CL/body desync (CL
    # shorter than the body, CL longer, CL beside a `Transfer-Encoding`) is *the* canonical
    # reason to hold a request, and gori answered every such edit by silently putting its own
    # number on the wire: the pane read `Content-Length: 5`, the origin received `16`, and
    # the status line said `forwarded`. A refusal that names nothing is bad; a rewrite that
    # names nothing is worse.
    getter? sync_content_length : Bool

    def toggle_content_length_sync : Bool
      @sync_content_length = !@sync_content_length
      reflect_content_length_in_editor
      @sync_content_length
    end

    # Put the Content-Length that will actually be SENT into the visible buffer.
    #
    # The other half of the defect above: even with the rewrite left default-on, a pane that
    # keeps showing the operator's `5` while the wire carries gori's `16` is a display lie
    # about a live request. So the rewrite is applied where the operator can see it and undo
    # it, exactly as the Repeater's auto-CL does — after which `pending_edit`'s own sync has
    # nothing left to change and display and wire agree by construction.
    #
    # `replace_line` (not `set_text`) keeps the caret and the undo stack, so this can run on
    # every keystroke. The CL line is located in the RAW editor head BY CONTENT rather than
    # by transplanting the expanded-space index: a multi-line `$KEY` expansion earlier in the
    # head shifts the line count, and the index would then overwrite an unrelated header.
    private def reflect_content_length_in_editor : Nil
      return unless @editing && @editor_dirty && @sync_content_length
      return if @loaded_ws                                                   # no head to update — see pending_edit
      raw = Env.expand_wire(@editor.wire_text, escape: Env::Escape::Consume) # see pending_edit
      synced = Fuzz::ContentLength.sync(raw, add_when_missing: true)
      return if synced == raw # already agrees (or chunked / no boundary — sync no-ops)
      synced_head = String.new(synced).split("\r\n\r\n", limit: 2).first
      new_line = synced_head.split("\r\n").find { |l| content_length_line?(l) } || return
      lines = @editor.lines_snapshot
      head_end = lines.index(&.empty?) || lines.size
      if idx = (0...head_end).find { |i| content_length_line?(lines[i]) }
        @editor.replace_line(idx, new_line) unless lines[idx] == new_line
      end
      # A head with NO Content-Length line got one spliced in by `add_when_missing`. Leave
      # the buffer alone rather than inserting a line under the caret mid-keystroke; the
      # forward still adds it, and the operator's head is unchanged either way.
    end

    private def content_length_line?(line : String) : Bool
      line.lstrip.downcase.starts_with?("content-length:")
    end

    # The method + target to DISPLAY for a held item — the EDITED values when this is
    # the item loaded in the editor and modified (so a GET→PUT method change or a
    # 200→201 status edit shows in the queue row + forward/drop toast, not the stale
    # hold-time metadata), else the immutable Item's own fields. For a response,
    # `target` is the "status reason" the response Item carries.
    #
    # A WebSocket message re-reads NOTHING from the editor: its first line is JSON or
    # protobuf, not an HTTP start line, so parsing it would rewrite the row's own label from
    # the first three space-separated tokens of a payload. Its method/target are the
    # handshake's and are immutable, which is exactly why the row stays identifiable while
    # its payload is being edited.
    def effective_method_target(it : Interceptor::Item) : {String, String}
      return {it.method, it.target} unless @loaded_id == it.id && @editor_dirty
      case it.kind
      in .ws_out?, .ws_in? then {it.method, it.target}
      in .request?
        first = editor_first_line
        parts = first.split(' ', 3)
        {parts[0]?.presence || it.method, parts[1]?.presence || it.target}
      in .response?
        first = editor_first_line
        parts = first.split(' ', 2) # "HTTP/1.1 201 CREATED" → the "201 CREATED" target
        {it.method, parts[1]?.presence || it.target}
      end
    end

    private def editor_first_line : String
      (String.new(@editor.to_bytes).split('\n', 2).first? || "").rstrip('\r')
    end

    # backspace/delete/undo are no-ops at buffer start / end-of-buffer / empty undo
    # stack (TextArea returns early without bumping @edits). A no-op here must NOT set
    # @editor_dirty: once dirty, forward_bytes recomputes Content-Length and normalizes
    # line endings, so a held message the user only *looked* at would forward as
    # different bytes — breaking the byte-exact hold contract (P7). Gate on a real edit.
    def edit_undo : Nil
      return unless @editing
      before = @editor.edits
      @editor.undo
      mark_editor_edit if @editor.edits != before
    end

    def edit_insert(ch : Char) : Nil
      return unless @editing
      @editor.insert(ch)
      mark_editor_edit
    end

    def edit_newline : Nil
      return unless @editing
      @editor.insert_newline
      mark_editor_edit
    end

    def edit_backspace : Nil
      return unless @editing
      before = @editor.edits
      @editor.backspace
      mark_editor_edit if @editor.edits != before
    end

    # A real content edit: the held bytes are now the operator's, and the visible
    # Content-Length is brought in line with what a forward would send (see
    # `reflect_content_length_in_editor`). Every edit path funnels through here so the pane
    # and the wire cannot drift.
    private def mark_editor_edit : Nil
      @editor_dirty = true
      reflect_content_length_in_editor
    end

    def edit_move(dr : Int32, dc : Int32) : Nil
      @editor.move(dr, dc) if @editing
    end

    # The shared editor keymap — ⇧arrows select, Page keys, ⇧Home/⇧End, ⌥←/→ by word, ⌥⌫
    # deletes one (`TextArea#handle_motion_key`). This editor had NO selection of any kind
    # before: the one pane where the operator edits bytes already on the wire was also the
    # one where a mistyped header could not be selected and replaced.
    #
    # `mark_editor_edit` only on a real buffer change (⌥⌫), and for the reason spelled out at
    # `edit_undo`: once dirty, `forward_bytes` recomputes Content-Length and normalizes line
    # endings, so a held message the operator only NAVIGATED must not be marked edited or it
    # forwards as different bytes (P7).
    def edit_motion_key(ev : Termisu::Event::Key) : Bool
      return false unless @editing
      before = @editor.edits
      return false unless @editor.handle_motion_key(ev)
      mark_editor_edit if @editor.edits != before
      true
    end

    def edit_word_delete_key?(ev : Termisu::Event::Key) : Bool
      @editor.word_delete_key?(ev)
    end

    # Mouse DRAG / DOUBLE-CLICK over the held-bytes editor.
    def editor_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @editing
      _, right = split_panes(body_rect(rect))
      @editor.click_to_cursor(right.inset(1, 1), mx, my, selecting: true)
    end

    def editor_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless @editing
      _, right = split_panes(body_rect(rect))
      @editor.select_word_at(right.inset(1, 1), mx, my)
    end

    # Home/End: caret to line start/end — pure navigation, doesn't change the bytes.
    def edit_home : Nil
      @editor.home if @editing
    end

    def edit_end : Nil
      @editor.end_of_line if @editing
    end

    # Forward-delete the char under the caret — a content edit (no-op at end-of-buffer).
    def edit_delete : Nil
      return unless @editing
      before = @editor.edits
      @editor.delete
      mark_editor_edit if @editor.edits != before
    end

    # ^G go-to-line / ^F search in the held-message editor (only while editing).
    def edit_goto_line(n : Int32) : Nil
      @editor.goto_line(n) if @editing
    end

    def edit_search_lines(query : String) : Array(Int32)
      @editing ? @editor.search_lines(query) : [] of Int32
    end

    def edit_match_count(query : String) : Int32
      @editing ? @editor.match_count(query) : 0
    end

    def edit_replace_matches(query : String, replacement : String) : Int32
      return 0 unless @editing
      n = @editor.replace_matches(query, replacement)
      mark_editor_edit if n > 0
      n
    end

    def search_hl=(q : String) : Nil
      @editor.search_hl = q
    end

    # The buffer handed to the external editor (^E). `wire_text`, NOT `text`, for the same
    # reason `pending_edit` reads it: `text` is the LF projection, so `^E` handed `$EDITOR` a
    # DIFFERENT message than the one being held — every CRLF in the head and the body flat
    # gone — and `replace_editor` then wrote that LF-only projection back over the buffer,
    # destroying the terminators for good. `Fuzz::ContentLength.sync` resyncing down to the
    # shortened body is what hid it: nothing hung, nothing errored, and a smuggling / CL-TE /
    # binary-body test simply stopped being that test. `ExternalEditor` was hardened to keep
    # wire bytes byte-exact (its `WIRE_KINDS` trailing-newline rule); that invariant was
    # defeated one layer up, here.
    def editor_text : String
      @editor.wire_text
    end

    # Replace the held item's editable bytes (e.g. from the external editor); only
    # while editing — forward_bytes then sends the edited text.
    #
    # `set_text` is the exact inverse of the `wire_text` above (`TextArea#split_wire`
    # round-trips every terminator, including a lone CR), so ^E is a byte-exact round trip
    # for a file the editor left alone.
    def replace_editor(text : String) : Nil
      return unless @editing
      @editor.set_text(text)
      mark_editor_edit
    end

    # --- focus ring (driven by the Runner's Tab/Shift-Tab) ---
    # Two panes: queue (editing off) ▸ detail editor (editing on). Entering the
    # detail pane starts editing the selected item; pane_advance returns false at
    # an end so the Runner wraps focus back to the tab bar.
    def focus_first : Nil
      @editing = false
    end

    def focus_last : Nil
      toggle_edit unless @editing
    end

    def pane_advance(dir : Int32) : Bool
      if dir > 0
        return false if @editing # detail → off the end (to the tab bar)
        return false unless selected_item
        toggle_edit # queue → detail (start editing)
        true
      else
        return false unless @editing # queue → off the end (to the tab bar)
        @editing = false             # detail → queue
        true
      end
    end

    # --- mouse hit-testing (inverts render's offset math; coords are 0-based) ---

    # Rows the bar occupies: one for the condition itself, plus a suggestion row while
    # it's being edited. Both render() and every hit-test derive from this, so the two
    # can't drift as the bar grows/shrinks under the caret.
    private def bar_h : Int32
      @querying ? FILTER_BAR_H + 1 : FILTER_BAR_H
    end

    # The body (queue|detail split) sits BELOW the filter bar — every hit-test must
    # subtract the bar rows first, exactly as render() does.
    private def body_rect(rect : Rect) : Rect
      Rect.new(rect.x, rect.y + bar_h, rect.w, {rect.h - bar_h, 0}.max)
    end

    # The w//3 split render() uses (render: `half = {body.w // 3, 1}.max`). `body` is
    # the post-bar rect (body_rect), NOT the full tab rect.
    private def split_panes(body : Rect) : {Rect, Rect}
      half = {body.w // 3, 1}.max
      left = Rect.new(body.x, body.y, half, body.h)
      right = Rect.new(body.x + half + 1, body.y, {body.w - half - 1, 0}.max, body.h)
      {left, right}
    end

    # Filter-bar click zones, matching render_filter_bar left-to-right:
    #   " i:CATCH " chip → :catch
    #   direction label (c:ALL / c:REQ / c:RES) → :direction
    #   rest of the bar → :condition (start query edit)
    # Nil while the bar is an input line (@querying) or off the bar row.
    def bar_zone_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @querying || my != rect.y
      return nil if mx < rect.x || mx >= rect.right
      catch_label = " i:CATCH "
      x = rect.x + 1
      return :catch if mx >= x && mx < x + catch_label.size
      x += catch_label.size + 1 # render: Frame.chip(...) + 1
      dir_label, _ = direction_chip
      return :direction if mx >= x && mx < x + dir_label.size
      :condition
    end

    # Which pane a click landed in: :list (left queue), :detail (right editor),
    # else nil. Mirrors render's split; nil while empty (single full-rect card, no
    # split), on the filter-bar row, and in the 1-cell gap column between the panes.
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @items.empty?
      left, right = split_panes(body_rect(rect))
      return :list if left.contains?(mx, my)
      return :detail if right.contains?(mx, my)
      nil
    end

    # The @items index under a click in the LEFT queue list, or nil. Inverts
    # render_list: the card border is `left.inset(1, 1)`, then row i sits at
    # `inner.y + i` for idx = @scroll + i (clamped to populated rows).
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if @items.empty?
      left, _ = split_panes(body_rect(rect))
      inner = left.inset(1, 1)
      return nil unless inner.contains?(mx, my)
      idx = @scroll + (my - inner.y)
      idx < @items.size ? idx : nil
    end

    # Set the selection, clamped to the populated rows (mirrors `move`).
    def select_index(idx : Int32) : Nil
      return if @items.empty?
      @selected = idx.clamp(0, @items.size - 1)
      reset_mark_anchor # same as the keyboard `move`: a plain click re-seeds the anchor
    end

    # Click the queue list → focus the list (stop editing the detail editor).
    def focus_list : Nil
      @editing = false
    end

    # Click the detail pane → focus the editor, but only when an item is loaded
    # (mirrors toggle_edit's guard; loads the selected item's bytes if needed).
    def focus_detail : Nil
      toggle_edit unless @editing || selected_item.nil?
    end

    # Mouse: place the held-message editor cursor at a click. `rect` is the body rect
    # render() receives; re-derive the right (detail) pane + its 1-cell inset exactly
    # as render_detail does. Only meaningful while editing (the editor is shown then).
    def editor_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @editing
      _, right = split_panes(body_rect(rect))
      @editor.click_to_cursor(right.inset(1, 1), mx, my)
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true, *,
               listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      render_filter_bar(screen, Rect.new(rect.x, rect.y, rect.w, FILTER_BAR_H), focused)
      render_suggestions(screen, rect, rect.y + FILTER_BAR_H) if @querying
      body = body_rect(rect)
      return if body.empty?

      if @items.empty?
        TrafficEmptyState.render(screen, body, variant: :intercept, listen: listen,
          capturing: capturing, catch_on: @enabled)
        return
      end

      left, right = split_panes(body)
      render_list(screen, left, focused && !@editing && !@querying)
      render_detail(screen, right, focused && @editing)
    end

    # The top filter bar: while editing the condition it's a single input line
    # (`catch › …`); otherwise a catch-direction chip, the committed condition (or a
    # field hint), and a right-aligned held count. Mirrors History's QL bar.
    private def render_filter_bar(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      if @querying
        prefix = "catch › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit, Theme.text_bright,
          width: {rect.w - prefix.size - 2, 0}.max,
          colors: Highlight.filter_query(@query, Theme.text_bright, FilterAst::SEPS_FIELD))
        return
      end

      # Left cluster: the master CATCH toggle (lit while holding) then the direction
      # sub-mode — each carries its chord (i toggles, c cycles) so both are discoverable
      # in the chrome, not just the empty-state prose.
      x = Frame.chip(screen, rect.x + 1, rect.y, " i:CATCH ", @enabled) + 1
      label, color = direction_chip
      x = screen.text(x, rect.y, label, color, Theme.bg, Attribute::Bold) + 2

      rx = rect.right - 1
      if !@items.empty?
        count = @items.size.to_s
        screen.text({rx - count.size, rect.x}.max, rect.y, count, Theme.muted)
        rx -= count.size + 2
      end
      rx = render_mark_chip(screen, rect, rx)

      left_w = {rx - x, 0}.max
      if @query.blank?
        screen.text(x, rect.y, "/ condition  ·  host:  method:  path:  status:>=500  scheme:", Theme.muted, width: left_w)
      else
        # The committed condition stays highlighted — this readout is what you scan to
        # check WHY something is (or isn't) being held.
        x = screen.text(x, rect.y, ": ", Theme.muted, width: left_w)
        screen.styled_text(x, rect.y, @query, Highlight.filter_query(@query, Theme.text, FilterAst::SEPS_FIELD),
          Theme.text, width: {rect.right - 1 - x, 0}.max)
      end
    end

    # Mark count, drawn right-to-left ending just left of `right_x`; returns the new left edge
    # of the chip cluster. No "hidden" split (History's chip carries one): the queue renders
    # every pending item, and reload prunes marks whose item is gone, so the count can never
    # exceed what is on screen.
    private def render_mark_chip(screen : Screen, rect : Rect, right_x : Int32) : Int32
      return right_x if @marks.empty?
      chip = "#{@marks.size} marked"
      x = right_x - chip.size - 1
      return right_x unless x > rect.x + 1 # too narrow — the held count wins
      screen.text(x, rect.y, chip, Theme.accent)
      x
    end

    # The Tab-completion row under the condition input: the leading candidate is what ↹
    # takes, the rest preview what typing one more char would narrow to. With nothing to
    # complete, a cold-start token (empty, or the caret just past a space) shows the
    # standing field hint; a non-empty token with no match stays quiet, since the human
    # is then deliberately typing a free-text word.
    private def render_suggestions(screen : Screen, rect : Rect, y : Int32) : Nil
      return if y >= rect.bottom
      sugg = query_suggestions
      unless sugg.empty?
        screen.text(rect.x + 1, y, "↹ #{sugg.first(8).join("  ")}", Theme.muted, width: {rect.w - 2, 0}.max)
        return
      end
      return unless FilterAst.token_at(@query, @qcx).core.empty?
      screen.text(rect.x + 1, y, QUERY_HINT, Theme.muted, width: {rect.w - 2, 0}.max)
    end

    # The catch-direction chip: `c`-chord + which direction, coloured by enabled state.
    # Dim when intercept is OFF (nothing is held yet, so the chip advertises what WILL be
    # caught once toggled on).
    private def direction_chip : {String, Color}
      label = case @direction
              when .request_only?  then "c:REQ"
              when .response_only? then "c:RES"
              else                      "c:ALL"
              end
      {label, @enabled ? Theme.accent : Theme.muted}
    end

    private def pane_border(focused : Bool) : Color
      Frame.pane_border(focused)
    end

    # --- what a queue row IS ---------------------------------------------------
    # Every branch on `Interceptor::Kind` in this file (and `InterceptController`'s toast
    # label) is an exhaustive `case ... in`, deliberately. They were all `kind.request?`
    # ternaries, which meant a new enum member compiled clean and silently rendered as `RES`
    # — the shape #533 removed from `RulePart#badge`, closed here for the same reason.

    # 3 cells wide, like REQ/RES, so the label column never shifts. The colour follows the
    # LEG rather than the protocol: a WS message travelling client→server is caught by the
    # same `c:REQ` chip an HTTP request is, so it reads in the same colour.
    private def kind_badge(kind : Interceptor::Kind) : {String, Color}
      case kind
      in .request?  then {"REQ", Theme.yellow}
      in .response? then {"RES", Theme.accent}
      in .ws_out?   then {"WS↑", Theme.yellow}
      in .ws_in?    then {"WS↓", Theme.accent}
      end
    end

    # The row's one line. HTTP shows its method/host/target (edited values for the loaded
    # item); a WebSocket message shows the socket it rides on plus a preview of the payload,
    # because the handshake identity is shared by every message on that socket and the
    # payload is the only thing that tells two rows apart.
    # `Item#label` composes the HTTP kinds — the ONE definition of "host + an overloaded
    # target", which as three separate copies produced `POST 127.0.0.1200 OK` (reads as HTTP
    # status 1200) on the ack path. It takes the EDITED method/target so a row still tracks
    # what is about to be sent. A WebSocket row keeps its own tail: `Item#label` ends a WS
    # message with its byte count, and here the PAYLOAD PREVIEW is the only thing that tells
    # two messages on one socket apart.
    private def row_label(it : Interceptor::Item) : String
      method, raw_target = effective_method_target(it) # edited values for the loaded item
      case it.kind
      in .request?, .response? then it.label(method, raw_target)
      in .ws_out?, .ws_in?     then "#{it.host}#{Url.origin_path(raw_target)}  #{ws_preview(it)}"
      end
    end

    # A binary message has no line to show, and rendering one would be a wall of U+FFFD:
    # opcode 2 is protobuf/msgpack/CBOR. Its size is the useful fact.
    private def ws_preview(it : Interceptor::Item) : String
      return "<binary, #{it.raw.size} bytes>" if it.binary?
      text = @loaded_id == it.id && @editor_dirty ? @editor.text : String.new(it.raw)
      line = (text.split('\n', 2).first? || "").rstrip('\r')
      line.size > WS_LABEL_MAX ? "#{line[0, WS_LABEL_MAX]}…" : line
    end

    private def detail_title(it : Interceptor::Item) : String
      case it.kind
      in .request?  then "REQUEST (held)"
      in .response? then "RESPONSE (held)"
      in .ws_out?   then "WS MESSAGE client→server (held)"
      in .ws_in?    then "WS MESSAGE server→client (held)"
      end
    end

    # The editor's syntax overlay. `nil` for a WebSocket payload: `Highlight.from_lines`
    # splits at the first blank line and styles everything above it as a start line plus
    # header lines, which is HTTP's shape and not a message's.
    private def editor_highlight(it : Interceptor::Item) : Symbol?
      case it.kind
      in .request?         then :request
      in .response?        then :response
      in .ws_out?, .ws_in? then nil
      end
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "QUEUE (#{@items.size})", bg: Theme.bg, border: pane_border(focused))
      inner = rect.inset(1, 1)
      ensure_visible(inner.h)
      (0...inner.h).each do |i|
        idx = @scroll + i
        break if idx >= @items.size
        it = @items[idx]
        y = inner.y + i
        selected = idx == @selected
        marked = @marks.includes?(it.id)
        bg = row_band(screen, inner, y, selected: selected, marked: marked, focused: focused)
        badge, bcolor = kind_badge(it.kind)
        screen.text(inner.x + 1, y, badge, bcolor, bg, Attribute::Bold)
        screen.text(inner.x + 5, y, row_label(it), selected || marked ? Theme.text_bright : Theme.text, bg, width: {inner.w - 6, 1}.max)
      end
      Frame.scroll_gauge(screen, inner, @items.size, @scroll, focused)
    end

    # Paint a queue row's background band + gutter glyph, returning the bg every cell on that
    # row then draws over. A marked row reads as a dim band with a FULLER bar, so it stays
    # distinguishable from the cursor row (accent band) and from a cursor row that is ALSO
    # marked (accent band + full bar) — the same two glyphs History's list uses. Both glyphs
    # are single-width, so no column offset moves and list_row_at stays valid.
    private def row_band(screen : Screen, inner : Rect, y : Int32, *,
                         selected : Bool, marked : Bool, focused : Bool) : Color
      return Theme.bg unless selected || marked
      bg = if selected
             focused ? Theme.accent_bg : Theme.selection_dim
           else
             Theme.selection_dim
           end
      screen.fill(Rect.new(inner.x, y, inner.w, 1), bg)
      screen.cell(inner.x, y, marked ? '▌' : '▎', Theme.accent, bg)
      bg
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      it = selected_item
      title = it.nil? ? "DETAIL" : detail_title(it)
      Frame.card(screen, rect, title, bg: Theme.bg, border: pane_border(focused))
      # `e` (or ↵) toggles editing the held bytes vs previewing them — lit while editing,
      # a muted hint while previewing, so the edit affordance rides the border. A binary WS
      # message says READ-ONLY there instead: the affordance must not advertise an edit the
      # TextArea round trip would corrupt.
      render_detail_badges(screen, rect, it, rect.x + title.size + 4) if it
      inner = rect.inset(1, 1)
      unless it
        screen.text(inner.x, inner.y, "—", Theme.muted)
        return
      end
      mode = editor_highlight(it)
      if @editing && @loaded_id == it.id
        @editor.render(screen, inner, cursor: focused, highlight: mode, gauge: true, gauge_focused: focused)
      else
        win = detail_window_for(it)
        total = win.total
        # Clamp the vertical offset so a body longer than the pane is scrollable but can
        # never blank it (content may be shorter than a stale offset). Cap at total-inner.h
        # so the LAST screenful stays visible at max scroll (not just one trailing line).
        # Upper-bound clamp lives here (mirrors @detail_xscroll below).
        @detail_scroll = @detail_scroll.clamp(0, {total - inner.h, 0}.max)
        # Styles each visible line ONCE (into `rows`), then clamps/slices from that —
        # mirrors RepeaterView#render_response_body / HistoryView#render_detail.
        rows = (0...inner.h).compact_map { |i| (li = @detail_scroll + i) < total ? win.line_at(li) : nil }
        @detail_xscroll = @detail_xscroll.clamp(0, {(rows.max_of? { |l| Highlight.line_width_upto(l, @detail_xscroll + inner.w + 1) } || 0) - inner.w, 0}.max)
        rows.each_with_index do |styled, i|
          shown = @detail_xscroll > 0 ? Highlight.slice_left(styled, @detail_xscroll) : styled
          Highlight.draw(screen, inner.x, inner.y + i, shown, width: inner.w)
        end
        Frame.scroll_gauge(screen, inner, total, @detail_scroll, focused)
      end
    end

    # The right-aligned chip cluster on the detail card's top border, drawn right to left.
    #
    # `^l`:CL is "Update Content-Length" (Burp's option name) and rides beside EDIT whenever
    # the editor is open on something with a head. Without it the rewrite was both invisible
    # and unswitchable: the operator's deliberate CL/body desync — the canonical reason to
    # hold a request at all — went out as gori's own number, with no toast, no badge and no
    # setting anywhere in the product.
    private def render_detail_badges(screen : Screen, rect : Rect, it : Interceptor::Item,
                                     min_x : Int32) : Nil
      return read_only_badge(screen, rect, min_x) if it.binary?
      x = Frame.toggle_badge(screen, rect.right - 1, rect.y, min_x, "e", "EDIT", @editing)
      return unless @editing
      return if @loaded_ws # a WS payload has no head — the sync never runs on it
      Frame.toggle_badge(screen, x, rect.y, min_x, "^l", "CL", @sync_content_length)
    end

    # Where `e`:EDIT would ride, for a message the editor must not open. Right-aligned with
    # the same min_x guard `Frame.toggle_badge` uses, so it drops out on a narrow pane rather
    # than overwriting the title.
    private def read_only_badge(screen : Screen, rect : Rect, min_x : Int32) : Nil
      label = " READ-ONLY "
      x = rect.right - 1 - label.size
      return if x < min_x
      screen.text(x, rect.y, label, Theme.muted)
    end

    # Nudge the read-only held-item preview sideways (shift+←/→). No-op while
    # editing — the TextArea editor's own follow_x already handles that case.
    def hscroll_detail(delta : Int32) : Nil
      return if @editing
      @detail_xscroll = {@detail_xscroll + delta * 4, 0}.max
    end

    # Vertical companion to hscroll_detail (shift+↑/↓): scroll the read-only preview so a
    # held body taller than the pane is fully readable WITHOUT entering edit mode (which
    # risks mutating byte-exact held bytes). Floored at 0 here; render clamps the upper bound.
    def vscroll_detail(delta : Int32) : Nil
      return if @editing
      @detail_scroll = {@detail_scroll + delta, 0}.max
    end

    # Windowed view of the held item's raw bytes, cached by item id (held bytes
    # never change; ids never repeat). The head is styled eagerly, the body kept RAW
    # and styled per visible line — a multi-MiB held body no longer freezes the UI
    # fiber on selection (mirrors the History/Repeater windowing).
    private def detail_window_for(it : Interceptor::Item) : Highlight::Windowed
      # When this is the item loaded in the editor AND it was modified, preview the EDITED
      # bytes (mirrors forward_bytes / effective_method_target) rather than the pristine
      # held bytes — so leaving the editor for the QUEUE doesn't snap the body back to the
      # original. edit_rev keys the cache on the editor's change counter for that case.
      edited = @loaded_id == it.id && @editor_dirty
      edit_rev = edited ? @editor.edits : -1
      cached = @detail_win
      return cached if cached && @detail_win_id == it.id && @detail_win_rev == Theme.revision && @detail_win_edit_rev == edit_rev
      if @detail_win_id != it.id # a newly-previewed item resets both scroll axes
        @detail_xscroll = 0
        @detail_scroll = 0
      end
      @detail_win_id = it.id
      @detail_win_rev = Theme.revision
      @detail_win_edit_rev = edit_rev
      @detail_win = it.kind.ws? ? ws_window_for(it, edited) : http_window_for(it, edited)
    end

    private def http_window_for(it : Interceptor::Item, edited : Bool) : Highlight::Windowed
      lines = edited ? @editor.lines_snapshot : String.new(it.raw).split('\n').map(&.rstrip('\r'))
      Highlight.from_lines_windowed(lines, it.kind.request?)
    end

    # A WebSocket message is ALL body: no start line, no headers, no head/body separator to
    # split on — and for opcode 2, no lines at all. So it gets an empty head and the payload
    # as lazy `BodyLines` (built straight from the BYTES when unedited, which keeps a multi-MiB
    # message off the UI fiber and scrubs per visible line rather than up front).
    private def ws_window_for(it : Interceptor::Item, edited : Bool) : Highlight::Windowed
      body = edited ? Highlight::BodyLines.from_array(@editor.lines_snapshot) : Highlight::BodyLines.from_bytes(it.raw)
      Highlight::Windowed.new([] of Highlight::Line, body, it.binary? ? :text : ws_body_kind(it.raw))
    end

    # A WS message carries no Content-Type, so the payload's own first byte is the only
    # signal there is. Sniffed, not guessed at render time: `Windowed#kind` is fixed for the
    # life of the cached window.
    private def ws_body_kind(raw : Bytes) : Symbol
      first = raw.find { |b| b != 0x20_u8 && b != 0x09_u8 && b != 0x0A_u8 && b != 0x0D_u8 }
      case first
      when 0x7B_u8, 0x5B_u8 then :json # '{' '['
      when 0x3C_u8          then :xml  # '<'
      else                       :text
      end
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
