# INS-mode editing of the request pane: insert/newline/paste/backspace/delete, caret motion
# (including the cross into a decode split's other sub-pane), and the `$KEY` autocomplete the
# editor offers while typing. Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # --- $ENV autocomplete in the request editor (delegates to the active req editor) ---
  # True while the request pane is a live text editor (insert mode, not hex) — the state
  # in which the $ENV dropdown and editor-style Tab apply (read by the controller too).
  def request_text_editing? : Bool
    @focus == :request && request_insert? && !request_hex?
  end

  def request_env_completing? : Bool
    request_text_editing? && req_editor.env_completing?
  end

  # The popup owns tab/↵/↑/↓/esc while open; accepting a key edits the buffer, so mirror
  # the dirty-marking edit_* helpers do. Returns true when the key was consumed.
  def handle_request_env_complete_key(ev : Termisu::Event::Key) : Bool
    return false unless request_text_editing?
    ed = req_editor
    before = ed.edits
    handled = ed.handle_env_complete_key(ev)
    mark_req_edit if handled && ed.edits != before
    handled
  end

  # Editor-style Tab: insert a literal tab into the request editor (no focus move).
  def request_tab_insert : Nil
    return unless request_text_editing?
    req_editor.insert('\t')
    req_editor.set_preedit("") # commit any preedit (termisu dup-guard)
    mark_req_edit
  end

  # --- request editor (focus == :request) ---
  # Input/cursor target the active sub-pane (envelope or decoded); a content edit
  # dirties the right buffer — the envelope (persist/sync) or the decoded payload
  # (→ re-encode on send). Pure navigation dirties neither.
  # `reflect: false` marks the buffer edited WITHOUT re-deriving Content-Length. Exactly one
  # caller passes it — `edit_undo` — and it has to: reflection is itself an edit, so running
  # it on the state ⌃Z just restored re-applies the change being undone. An auto-CL rewrite
  # was therefore unreachable by undo at ANY depth: each press restored the line and the
  # reflection put it straight back (and pushed another undo state doing so). Nothing is lost
  # by skipping it — an undo snapshot is a state the buffer really held, Content-Length line
  # included, so what comes back is already self-consistent.
  private def mark_req_edit(reflect : Bool = true) : Nil
    if req_split? && @req_pane == :decoded
      @decoded_dirty = true
      @ws_out_edited = true
    else
      @dirty = true
      reflect_content_length_in_editor if reflect
    end
  end

  # undo / backspace / forward-delete are NO-OPS on an empty undo stack, at buffer start and
  # at end-of-buffer respectively (TextArea returns early without bumping @edits). A no-op
  # must not mark the buffer edited. `intercept_view.cr` has carried this guard and the
  # reason for it since #513; the Repeater's copy did not, and the consequence here is
  # worse: `mark_req_edit` sets `@ws_out_edited`, so a single `Ctrl-Z` in READ mode on an
  # untouched WebSocket tab took the pane off its seed and dropped every frame the pane was
  # not showing — observed as a captured BIN frame vanishing from the wire between two
  # otherwise identical replays. Gate on a real edit.
  def edit_undo : Nil
    return unless @focus == :request
    ed = req_editor
    before = ed.edits
    ed.undo
    mark_req_edit(reflect: false) if ed.edits != before # see mark_req_edit
  end

  # Characters the last `edit_insert` replaced — see TextArea#last_replaced.
  def edit_last_replaced : Int32
    req_editor.last_replaced
  end

  def edit_insert(ch : Char) : Nil
    return unless @focus == :request
    # Marker-in-marker guard: a §/¦ typed inside (or flush against) a closed marker is
    # auto-escaped to a §§/¦¦ literal so the structure survives (Template.insert_breaks_marker?).
    if req_marker_editable? &&
       Fuzz::Template.insert_breaks_marker?(@editor.text, @editor.cursor_offset, ch, marker_spans)
      @editor.insert_pair(ch)
    else
      req_editor.insert(ch)
    end
    mark_req_edit
  end

  def edit_newline : Nil
    return unless @focus == :request
    req_editor.insert_newline
    mark_req_edit
  end

  # Splice a whole bracketed paste in as ONE edit — one undo step, one Content-Length
  # reflection, one frame — instead of the N keystrokes it used to arrive as. Returns false
  # when this buffer must take the paste the slow way, and the Runner then replays it
  # keystroke by keystroke (see `Runner#flush_bulk_paste`), so a refusal costs speed and
  # nothing else.
  #
  # The one refusal: a `§`/`¦` in the pasted text while this buffer's markers are editable.
  # `edit_insert` escapes a typed delimiter that would nest inside (or flush against) a
  # closed marker, character by character against the buffer as it stands at that moment —
  # a question a bulk splice cannot ask, and one whose wrong answer silently changes what
  # the template sends. Clipboards with a `§` in them are rare; correctness there is not.
  def edit_paste(text : String) : Bool
    return false unless @focus == :request && request_insert? && !request_hex?
    if req_marker_editable? && (text.includes?(Fuzz::Template::MARKER) || text.includes?(Fuzz::Template::CHAIN_SEP))
      return false
    end
    req_editor.insert_text(text)
    mark_req_edit
    true
  end

  def edit_backspace : Nil
    return unless @focus == :request
    ed = req_editor
    before = ed.edits
    ed.backspace
    mark_req_edit if ed.edits != before # no-op at buffer start — see edit_undo
  end

  # `selecting` is the Shift half of ⇧←/→/↑/↓: it extends the INS-mode selection from its
  # anchor instead of collapsing it. Defaulted false so every existing caller is a plain
  # move. The pane-crossing branch below deliberately does NOT forward it — a selection
  # that jumped from the ENVELOPE into the DECODED sub-pane would span two buffers, and
  # neither `cut_selection` nor the band painter can express that.
  def edit_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
    return unless @focus == :request
    return if dc == 0 && try_cross_req_pane(dr)
    req_editor.move(dr, dc, selecting)
    # Cursor navigation is NOT a content edit: leave @dirty alone. Marking it here made
    # pure arrow-key movement persist the tab (V11) and, worse, latch sync-clobber
    # protection so a live cross-session update could no longer refresh the tab.
  end

  # In a split column, a vertical step off the end of one sub-pane crosses into the other
  # (↓ off the ENVELOPE/HANDSHAKE bottom → DECODED/MESSAGES top; ↑ off the lower pane's top
  # → the upper pane's last line), so the split feels like one continuous column. (↑ off the
  # upper pane's top pops to the tab bar via `at_top?`.) Returns true when it crossed and
  # the caller must not also step inside a buffer.
  #
  # Shared by INS (`edit_move`) and READ (`request_read_move`) on purpose. It lived inline
  # in `edit_move` only, so a WebSocket tab — which `restore` leaves in READ mode — could
  # not get from HANDSHAKE to MESSAGES with the arrow keys at all: ↓ clamped at the bottom
  # of one buffer and ↑ clamped at the top of the other, leaving `^T` as the only way
  # across. That is the same "the keyboard does nothing here" the invisible READ caret
  # produced, from a different direction.
  private def try_cross_req_pane(dr : Int32) : Bool
    return false unless req_split?
    if dr > 0 && @req_pane == :envelope && @editor.at_bottom?
      switch_req_pane(:decoded)
      @decoded.goto_line(1)
      @req_read.sync_from(@decoded) # READ paints from @req_read; leave it on the arriving caret
      return true
    end
    if dr < 0 && @req_pane == :decoded && @decoded.at_top?
      switch_req_pane(:envelope)
      @editor.goto_line(Int32::MAX) # clamps to the last line
      @req_read.sync_from(@editor)
      return true
    end
    false
  end

  # Home/End: pure navigation (caret to line start/end) → does NOT dirty, like edit_move.
  #
  # These move the EDITOR's caret directly, so READ mode has to adopt the result: without
  # `sync_to`, a plain Home left `@req_read`'s anchor where it was and the band was painted
  # from there to column 0 — a selection the operator had just collapsed — while ⇧Home
  # planted no anchor at all and extended nothing. `sync_to` is the helper written for
  # exactly this pair; Notes, Issues, Project and the Decoder input all already call it.
  def edit_home(selecting : Bool = false) : Nil
    return unless @focus == :request
    ed = req_editor
    ed.home(selecting)
    @req_read.sync_to(ed, selecting: selecting) unless request_insert?
  end

  def edit_end(selecting : Bool = false) : Nil
    return unless @focus == :request
    ed = req_editor
    ed.end_of_line(selecting)
    @req_read.sync_to(ed, selecting: selecting) unless request_insert?
  end

  # PageUp / PageDown in the request editor: `dir` is -1/+1, sized from the editor's OWN
  # last rendered height so the step matches the pane the operator is looking at (a split
  # decode tab pages by its half, not by the window).
  def edit_page(dir : Int32, selecting : Bool = false) : Nil
    return unless @focus == :request
    ed = req_editor
    ed.page(dir * ed.page_rows, selecting: selecting)
  end

  # THE shared editor keymap over the request editor — see `TextArea#handle_motion_key`.
  # Dirties only on a real buffer change (⌥⌫ is the one mutation in the set).
  #
  # Split-decode tabs keep their own ↑/↓, which cross between the ENVELOPE and DECODED
  # sub-panes; the shared set would clamp inside one buffer instead, so those two keys are
  # routed through `edit_move` there and everything else still comes here.
  def edit_motion_key(ev : Termisu::Event::Key) : Bool
    return false unless @focus == :request
    if req_split? && (ev.key.up? || ev.key.down?)
      edit_move(ev.key.up? ? -1 : 1, 0, selecting: ev.shift?)
      return true
    end
    ed = req_editor
    before = ed.edits
    return false unless ed.handle_motion_key(ev)
    mark_req_edit if ed.edits != before
    true
  end

  # ⌃/⌥ + ←/→ — one word instead of one character. Pure motion: nothing dirties, matching
  # `edit_move`.
  def edit_word_move(dir : Int32, selecting : Bool = false) : Nil
    return unless @focus == :request
    ed = req_editor
    dir < 0 ? ed.word_left(selecting) : ed.word_right(selecting)
  end

  # ⌃/⌥ + Home/End — the buffer's start/end, not the line's.
  def edit_buffer_start(selecting : Bool = false) : Nil
    req_editor.to_buffer_start(selecting) if @focus == :request
  end

  def edit_buffer_end(selecting : Bool = false) : Nil
    req_editor.to_buffer_end(selecting) if @focus == :request
  end

  # ⌥⌫ — delete back to the previous word boundary as one undo step.
  def edit_delete_word : Nil
    return unless @focus == :request
    ed = req_editor
    before = ed.edits
    ed.delete_word_left
    mark_req_edit if ed.edits != before # no-op at buffer start — see edit_undo
  end

  # Forward-delete: a content edit → dirties (matches edit_backspace).
  def edit_delete : Nil
    return unless @focus == :request
    ed = req_editor
    before = ed.edits
    ed.delete
    mark_req_edit if ed.edits != before # no-op at end-of-buffer — see edit_undo
  end
end
