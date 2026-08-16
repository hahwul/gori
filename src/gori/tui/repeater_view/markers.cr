# `§…§` markers and the Decoder chains they carry: marking verbs, the declare/adopt rules that
# keep a CAPTURE's own `§` inert until the operator asks, the CHAIN sub-pane that edits the
# chain under the cursor, the structure guards that stop a delete from breaking a delimiter,
# and the cached spans/regions the editor is tinted from.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # Whether the CHAIN sub-pane currently owns keyboard input (focused + actually on the
  # request column). The controller routes body keys here when true.
  def chain_pane_active? : Bool
    @chain_focused && @focus == :request && !request_hex?
  end

  # ^Q: drop focus into the CHAIN pane for the marker under the request cursor. Returns
  # a hint string when it can't (surfaced by the controller), nil on success.
  def focus_chain_pane : String?
    return "not available in hex edit" if request_hex?
    return "move to the REQUEST pane first (↹)" unless @focus == :request
    return literal_marker_hint unless markers_live?
    chain = Fuzz::Template.chain_at(@editor.text, @editor.cursor_offset)
    return "put the cursor in a §…§ marker · ^A mark all · ^T insert §" if chain.nil?
    @chain_marker_cursor = @editor.cursor_offset
    @chain_pane.load(chain)
    @chain_focused = true
    nil
  end

  # Commit the CHAIN pane's text back to the bound marker and return focus to the editor.
  # Idempotent — a no-op when the pane isn't focused (so set_focus can call it freely).
  def commit_chain_pane : Nil
    return unless @chain_focused
    # The marker's open § (value region) is unchanged by the chain edit, so it's a stable
    # anchor — restoring the raw cursor could land inside a now-longer hidden chain.
    anchor = Fuzz::Template.marker_start_at(@editor.text, @chain_marker_cursor) || @chain_marker_cursor
    if updated = Fuzz::Template.set_chain(@editor.text, @chain_marker_cursor, @chain_pane.value)
      @editor.set_text_keeping_eols(updated)
      @editor.place_at_offset(anchor) # back into the marker (set_text reset it) → tooltip stays up
      @dirty = true
    end
    @chain_focused = false
  end

  # Leave the CHAIN pane WITHOUT writing its edits back to the marker (esc =
  # cancel, the universal editor convention). The editor text was never touched
  # while the pane had focus — only commit_chain_pane writes — so dropping focus
  # is a clean discard; restore the cursor onto the marker so its tooltip stays up.
  def discard_chain_pane : Nil
    return unless @chain_focused
    anchor = Fuzz::Template.marker_start_at(@editor.text, @chain_marker_cursor) || @chain_marker_cursor
    @editor.place_at_offset(anchor)
    @chain_focused = false
  end

  # Route a key while the CHAIN pane is focused: typing/autocomplete stays in the
  # pane; ↵/tab/↑ commit the edit and return to the request editor, while esc
  # cancels (discards the edit) — matching how esc backs out elsewhere.
  def handle_chain_pane_key(ev : Termisu::Event::Key) : Nil
    return if @chain_pane.handle_key(ev) # consumed by the pane (edit / completion nav)
    key = ev.key
    if key.escape?
      discard_chain_pane
    elsif key.enter? || key.tab? || key.up?
      commit_chain_pane
    end
  end

  # --- marking (§…§ Decoder-chain positions) -------------------------------
  # These mirror the Fuzzer's marking helpers, gated on the REQUEST pane (a marked value
  # renders through its chain on send). All delegate to the shared Fuzz::Template helpers.
  # Each of the three that CREATES a marker also declares the buffer a template — see
  # `markers_live?` for why an evidence tab needs to be told.
  #
  # They write back through `set_text_keeping_eols`, never plain `set_text`: the Template
  # helpers take (and must take) `@editor.text`, the CR-free LF projection every offset here
  # indexes, and a plain `set_text` of that result would store the projection — flattening
  # the capture's body CRLFs before the tab has sent anything, with auto-CL resyncing the
  # shortened length behind it. That is exactly what `edit_buffer_text` documents for ^E,
  # and the Fuzzer's identical five helpers have wrapped it in `restore_wire_eols` all along.
  def auto_mark : String
    return mark_hint unless markable?
    # `Fuzz::Template.auto_mark` is a documented no-op once the text holds ANY `§`, so on a
    # capture that carries one there is nothing to gain by declaring — and everything to
    # lose: the capture's own `§` would become live positions in exchange for zero new ones.
    # Name that instead of doing it silently.
    return "the capture's own § would become markers and auto-mark adds none — ^T marks at the cursor" if literal_markers?
    declare_markers
    @editor.set_text_keeping_eols(Fuzz::Template.auto_mark(@editor.text))
    @dirty = true
    n = Fuzz::Template.parse(@editor.text).position_count
    "auto-marked #{n} position#{n == 1 ? "" : "s"}"
  end

  def mark_word : String
    return mark_hint unless markable?
    before = @editor.text
    after = Fuzz::Template.mark_word(before, @editor.cursor_offset)
    return "no word at the cursor — place it on a token (or auto-mark)" if after == before
    note = adopted_literals_note
    declare_markers
    @editor.set_text_keeping_eols(after)
    @dirty = true
    msg = Fuzz::Template.parse(after).position_count < Fuzz::Template.parse(before).position_count ? "unmarked position" : "marked position"
    "#{msg}#{note}"
  end

  def insert_marker : String
    return mark_hint unless markable?
    note = adopted_literals_note
    declare_markers
    @editor.insert(Fuzz::Template::MARKER)
    @editor.set_preedit("")
    @dirty = true
    if @editor.text.count(Fuzz::Template::MARKER).odd?
      "marker opened — move the cursor and mark again to close the region#{note}"
    else
      n = Fuzz::Template.parse(@editor.text).position_count
      "marked point — #{n} position#{n == 1 ? "" : "s"}#{note}"
    end
  end

  # NOT a declaring action: `Template.clear_markers` renders the defaults, i.e. it DELETES
  # every `§` in the buffer. On an evidence tab those are the capture's bytes, so running
  # it would do exactly the damage this whole gate exists to prevent — refuse by name.
  def clear_marks : String
    return mark_hint unless markable?
    return literal_marker_hint unless markers_live?
    @editor.set_text_keeping_eols(Fuzz::Template.clear_markers(@editor.text))
    @markers_declared = false # back to a buffer with no markers of its own
    invalidate_marker_caches
    @dirty = true
    "cleared all § markers"
  end

  # PROVENANCE: `§…§` (and its `¦chain`) is the operator's DRAFT language, not a value the
  # wire can carry. A `§` that arrived as captured evidence is DATA — U+00A7 is ordinary
  # text, ubiquitous in German and legal bodies — and rendering it as syntax deletes two
  # bytes the origin really sent, silently, with `Content-Length` re-synced behind it so
  # the loss leaves no trace. `gori run repeater <id>` and MCP `send_request` both replay
  # those bytes exactly; the TUI was the one surface that did not.
  #
  # So on an EVIDENCE tab markers start INERT and the operator declares them — by marking
  # (^A / ^T / insert §), the same explicit act the Fuzzer's ⇧I → ^A workflow already is.
  # Declaring is per-buffer and monotone: from then on every `§` in the buffer is a marker
  # (the status line says so when the capture carried one), which is the honest reading of
  # "this buffer is now a template".
  #
  # Deliberately NOT keyed on `@dirty`. `evidence?` documents that an operator edit does
  # not clear provenance — editing a header does not make the `§` in the body something the
  # operator typed — and gating on the first keystroke would put the deletion straight back
  # on the commonest workflow there is (seed a capture, tweak a header, send).
  #
  # A restore()/reconcile lands undeclared: the persisted row carries the request text and
  # its `flow_id`, and nothing that says which `§` in it the operator typed. gori does not
  # know, and for evidence the answer when gori does not know is the wire's. The REQUEST
  # border chip says which state the tab is in whenever a `§` is present at all.
  private def markers_live? : Bool
    !@evidence || @markers_declared
  end

  # Public for the send-path guards that live in the controller (group send / minimize):
  # "are there §…§ regions this send has to render?", provenance included, so a capture's
  # own `§` neither renders nor blocks an unrelated action.
  def markers_active? : Bool
    !marker_regions.empty?
  end

  # True when the buffer holds a `§` that is being treated as literal capture bytes — the
  # only state the REQUEST border needs a chip for (a marker-free request renders exactly
  # as before).
  def literal_markers? : Bool
    !markers_live? && Fuzz::Template.marker_bytes_in?(@editor.text.to_slice)
  end

  private def declare_markers : Nil
    return if @markers_declared
    @markers_declared = true
    invalidate_marker_caches
  end

  # Re-derive provenance for a REOPENED evidence tab from the flow it was seeded off.
  #
  # `restore`/`apply_peer_request` land undeclared because the repeater row says nothing
  # about which `§` in its text the operator typed. That is true of the ROW — and it made a
  # tab the operator had marked by hand come back with its own markers inert, `^T:MARK` on
  # the border, and a `^R` that would put `§…§` on the wire as literal bytes. The operator
  # marked it; gori just forgot between two runs.
  #
  # But the row is not the only evidence. The CAPTURE is still in the store, and it answers
  # the question directly: a `§` that is in this buffer and was NOT in the origin's bytes can
  # only have been typed here. So:
  #
  #   * capture had NO `§` → every `§` in the buffer is the operator's → declare.
  #   * capture HAD a `§` → gori genuinely cannot tell one from the other, so the markers
  #     stay inert and the border chip says so. That is the case `markers_live?` exists for,
  #     and it keeps its guard.
  #   * no capture to read (flow deleted, seed lost) → inert, for the same reason.
  #
  # Idempotent, and never UNdeclares: the operator's own act outranks a re-derivation.
  #
  # Head AND body, because a `§` in either is one gori cannot attribute — and the seed read
  # the same stored bytes this reads, truncation included, so the two sides are comparable
  # even for a capture whose body was cut at the cap.
  def adopt_capture_markers(capture_head : Bytes?, capture_body : Bytes?) : Nil
    return if !@evidence || @markers_declared
    return unless capture_head
    return if Fuzz::Template.marker_bytes_in?(capture_head)
    return if (b = capture_body) && Fuzz::Template.marker_bytes_in?(b)
    return unless Fuzz::Template.marker_bytes_in?(@editor.text.to_slice)
    declare_markers
  end

  # The caches key on `@editor.edits`, which a pure state flip does not bump.
  private def invalidate_marker_caches : Nil
    @marker_regions_rev = -1
    @marker_spans_rev = -1
    @chain_rev = -1
  end

  # Named in the status line when declaring adopts `§` the capture brought with it: those
  # bytes stop being data on the very next send, and that is not something to discover from
  # a 4-byte-shorter request.
  private def adopted_literals_note : String
    literal_markers? ? " — the capture's own § are markers now (^Z undoes)" : ""
  end

  private def literal_marker_hint : String
    "§ here is captured data, not a marker — ^T marks at the cursor (the capture's § become markers too)"
  end

  # Insert an OAST payload URL at the request-editor caret (cross-tab "Insert OAST
  # payload"). Only when the request pane is focused and not in hex mode.
  def insert_oast_payload(url : String) : Bool
    return false unless @focus == :request && !request_hex?
    @editor.insert_string(url)
    @editor.set_preedit("")
    @dirty = true
    true
  end

  private def markable? : Bool
    @focus == :request && !request_hex?
  end

  private def mark_hint : String
    return "marking isn't available in hex edit" if request_hex?
    "marking works on the REQUEST pane — ↹ to it"
  end

  # --- marker structure guards (delimiter delete / nesting) --------------------
  # When a backspace here would delete a §/¦ that structures a closed marker, the {a, b}
  # span of that marker (fed to the strip-confirm) — else nil. Only in the plain-HTTP
  # request envelope, where §…§ markers render + conceal.
  def marker_break_on_backspace : {Int32, Int32}?
    return nil unless req_marker_editable?
    Fuzz::Template.structural_marker_at(@editor.text, @editor.cursor_offset - 1, marker_spans)
  end

  # Same, for a forward-delete (the char UNDER the caret).
  def marker_break_on_delete : {Int32, Int32}?
    return nil unless req_marker_editable?
    Fuzz::Template.structural_marker_at(@editor.text, @editor.cursor_offset, marker_spans)
  end

  # 1-based ordinal of the closed marker at `span` — for the confirm copy ("marker §N").
  def marker_ordinal(span : {Int32, Int32}) : Int32
    (marker_spans.index(span) || 0) + 1
  end

  # Confirmed strip: drop the whole marker at `span`, keeping only its raw value; caret to
  # the freed value's end. One undoable edit, so prior edits stay undoable. Dirties the tab.
  def strip_marker_span(span : {Int32, Int32}) : Nil
    return unless @focus == :request
    new_text, caret = Fuzz::Template.strip_marker(@editor.text, span)
    # LF projection in, terminators back on — see the marking-helpers note above; the
    # `replace_all` variant so this stays ONE undoable edit and the caret survives.
    @editor.replace_all_keeping_eols(new_text, caret)
    mark_req_edit
  end

  # "§N" label for the marker under the cursor (1-based), or "§" when not in one.
  private def marker_label : String
    cur = @editor.cursor_offset
    idx = marker_spans.index { |(a, b)| a <= cur && cur <= b }
    idx ? "§#{idx + 1}" : "§"
  end

  # §…§ char-offset spans for the current request buffer, cached on the editor revision —
  # marker_label + the CHAIN title both read it, so an unchanged buffer joins/scans once.
  # The request editor is the plain-HTTP envelope where §…§ markers render + conceal —
  # the only place the delimiter-delete / nesting guards apply. Hex, gRPC, WS and the
  # decoded split pane all have their own byte semantics and CLEAR concealment, so a §
  # there is literal payload, not a marker.
  private def req_marker_editable? : Bool
    @focus == :request && !request_hex? && !@grpc_mode && !ws_mode? &&
      @decode_kind.nil? && req_editor.same?(@editor)
  end

  private def marker_spans : Array({Int32, Int32})
    return NO_SPANS unless markers_live?
    if @editor.edits != @marker_spans_rev
      @marker_spans_rev = @editor.edits
      @marker_spans_cache = Fuzz::Template.marked_spans(@editor.text)
    end
    @marker_spans_cache
  end

  # The chain (`¦…`) of the marker under the cursor, or nil (not in a marker) / "" (marker,
  # no chain). Cached on {editor revision, cursor} so a stationary cursor doesn't re-join +
  # re-scan the whole buffer every render frame the CHAIN pane is visible.
  private def chain_under_cursor : String?
    return nil unless markers_live? # a captured `¦` isn't a chain — no tooltip over evidence
    cur = @editor.cursor_offset
    if @editor.edits != @chain_rev || cur != @chain_cursor
      @chain_rev = @editor.edits
      @chain_cursor = cur
      @chain_cache = Fuzz::Template.chain_at(@editor.text, cur)
    end
    @chain_cache
  end

  # §…§ marker tinting: colour each marker in the request editor — the value in the
  # position hue, the ¦chain segment over-painted dimmer. Always on (like the Fuzzer):
  # a marker-free request yields no regions, so this is a no-op paint then.
  private def update_request_marker_tint : Nil
    bg = [] of {Int32, Int32, Color}
    conceal = [] of {Int32, Int32}
    marker_regions.each_with_index do |region, i|
      a, sep, close = region
      bg << {a, close + 1, Theme.marker_bg(i)} # band spans the whole marker; the conceal-aware paint skips hidden cells
      conceal << {sep, close} if sep < close   # hide the ¦chain inline (kept in the buffer → tooltip + ^Q overlay)
    end
    @editor.bg_regions = bg
    @editor.conceal_spans = conceal
    # A marker WITHOUT a chain gets the tooltip too (`""` → "no chain yet · ^Q edit"). The
    # chain pane is reachable by exactly one key that appears nowhere on this pane, so the
    # state with no chain — the one where the operator has nothing on screen to work from —
    # was the state that said nothing at all, while a marker that already had one explained
    # itself. nil (caret outside every marker) still draws nothing.
    @editor.chain_peek_text = chain_under_cursor
  end

  # {open, sep, close} marker regions cached on the editor revision — update_request_marker_tint
  # (and request_bytes / chain_split_visible?) read it every render; the cache skips
  # marker_regions' 2× whole-buffer `text.chars` on an unchanged request buffer.
  #
  # Empty while the markers are INERT (see `markers_live?`), which is the one place that
  # decision has to live: every consumer — the send (`request_bytes`), the Content-Length
  # reflection, the tint/conceal paint, `minimizable?`, the editor's delimiter guards —
  # reads it, and they must not be able to disagree about whether a `§` in this buffer is
  # syntax or data.
  private def marker_regions : Array({Int32, Int32, Int32})
    return NO_REGIONS unless markers_live?
    if @editor.edits != @marker_regions_rev
      @marker_regions_rev = @editor.edits
      # Pass the already-cached spans. The one-argument form defaults `spans` to
      # `marked_spans(text)`, so it re-walked the WHOLE request buffer a second time per
      # render (its own `text.chars` plus `marked_spans`' own) — on the busiest editor in
      # the app, with `@marker_spans_cache` sitting right there holding the answer.
      # `FuzzerView#marker_regions` has passed them since the cache was introduced; this
      # copy drifted. Both call sites gate on the same `@editor.edits` revision, so the
      # spans handed over are always the ones for this text.
      @marker_regions_cache = Fuzz::Template.marker_regions(@editor.text, marker_spans)
    end
    @marker_regions_cache
  end

  NO_REGIONS = [] of {Int32, Int32, Int32}
  NO_SPANS   = [] of {Int32, Int32}
end
