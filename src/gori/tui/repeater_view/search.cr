# `^F` search and goto-line over both panes, plus the display toggles the Runner pushes in
# every frame (whitespace reveal, pretty-print, the per-pane highlight query).
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # ^G go-to-line in the request editor (no-op in hex mode — the TextArea is stale).
  # Pure navigation → does NOT dirty the tab (no content change to persist/lock).
  def goto_request_line(n : Int32) : Nil
    return unless @focus == :request && !request_hex?
    req_editor.goto_line(n)
  end

  # ^F search in the request editor: 0-based line indices containing `query`.
  def request_search_lines(query : String) : Array(Int32)
    return [] of Int32 if request_hex?
    req_editor.search_lines(query)
  end

  # ^F find&replace over the request editor. Hex mode is excluded like the search
  # above (the TextArea is stale there, so a write would clobber the real bytes).
  def request_match_count(query : String) : Int32
    return 0 if request_hex?
    req_editor.match_count(query)
  end

  def request_replace_matches(query : String, replacement : String) : Int32
    return 0 if request_hex?
    n = req_editor.replace_matches(query, replacement)
    mark_req_edit if n > 0
    n
  end

  # Whitespace reveal toggle — response renders from raw bytes; the request editor
  # shows within-line whitespace too.
  def reveal=(on : Bool) : Nil
    return if @reveal == on # the controller pushes this every frame; guard so @scroll isn't zeroed each render
    @reveal = on
    @editor.reveal = on
    @decoded.reveal = on # the decode split's payload editor honours reveal too
    @scroll = 0          # reveal renders the response from RAW bytes → a different line count; reset like pretty=/x/d
    resp_wrap_reset
  end

  # Pretty toggle feeds `resp_view`, so a change drops only the response-view cache
  # (the diff/hex caches are unaffected — pretty touches neither). Change-detected
  # because the runner pushes this every frame.
  def pretty=(on : Bool) : Nil
    return if @pretty == on
    @pretty = on
    drop_resp_view_cache
    @scroll = 0 # reflow changes the line count → a stale offset could blank the pane (like x/d toggles)
    resp_wrap_reset
  end

  # ^F highlight, scoped to the searched pane (the Runner picks which).
  def request_search_hl=(q : String) : Nil
    @editor.search_hl = q
    @decoded.search_hl = q
  end

  def response_search_hl=(q : String) : Nil
    @search_hl = q
  end

  # ⇧←/→ used to nudge the response/diff/reveal/transcript pane sideways. There is no
  # sideways any more: every one of those panes soft-wraps, so the content the operator was
  # panning to is already on the next row. The method, its binding and — as of the transcript
  # ←/→ fix — the footer hint that still advertised "⇧←/→ h-scroll" are all gone; ⇧←/→ now
  # extends the read selection by a character, in the transcript as much as in a plain
  # response (see `handle_repeater_response`). Nothing is left to delete.

  # ^G go-to-line in the response pane: scroll so 1-based line `n` is at the top
  # (interpreted in the currently-shown mode — response/diff/hex row). Hex mode has
  # no caret to move; in navigable (cursor-tracked) modes, sync @resp_cursor too —
  # otherwise the first ↑/↓ after the jump moves from the caret's stale pre-jump
  # position instead of the line just jumped to.
  def goto_response_line(n : Int32) : Nil
    if resp_navigable?
      size, _ = resp_line_source
      return if size <= 0
      cy = (n - 1).clamp(0, size - 1)
      @resp_cursor.sync(cy, 0)
      @scroll = cy
      @scroll_sub = 0 # ^G names a LOGICAL line, so land on its first visual row
    else
      @scroll = (n - 1).clamp(0, {resp_line_count - 1, 0}.max)
    end
  end

  # ^F search in the response pane: 0-based line indices containing `query` in the
  # CURRENTLY-shown mode (response text or diff). Empty in hex mode.
  # Through `resp_line_source`, not a fourth per-mode ladder of its own. That re-derivation
  # had already drifted twice over: it had no REVEAL branch, so searching a whitespace-revealed
  # response scanned the plain lines and returned indices into a document the pane was not
  # showing — and it would have needed a fifth branch for the WS handshake card. One source.
  def response_search_lines(query : String) : Array(Int32)
    hits = [] of Int32
    return hits if query.empty? || resp_hex_active?
    q = query.downcase
    size, line_at = resp_line_source
    (0...size).each { |i| hits << i if line_at.call(i).downcase.includes?(q) }
    hits
  end
end
