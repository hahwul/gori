require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "./text_area"
require "./input_mode"
require "./text_read_state"
require "./gutter"
require "../store"
require "../notes"
require "../settings"
require "./subtab_clone"

module Gori::Tui
  # The Notes tab (DESIGN.md: notes/report — the running scratchpad/report).
  # Multiple free-form, per-project documents kept as sub-tabs (like Repeater):
  # `^N` opens a new note, `^W` closes the current one, `^1-9` switches. Each
  # note defaults to READ (navigate/select/copy); i/↵ enters INS to type. The whole set
  # is persisted in the project's settings KV as JSON (key "notes.docs") and
  # saved when you leave the editor, so it survives reopening the project.
  #
  # Backward compatibility: a project written by the single-note build stored a
  # plain-text document under the key "notes". On first load (when "notes.docs"
  # is absent) that legacy value is migrated into the first note; the new JSON
  # key is written on the next save (the legacy key is left untouched, harmless).
  class NotesView
    DOCS_KEY = Notes::DOCS_KEY # JSON {"cur":Int32, "notes":[String, ...]}

    # One note document: a title is derived from its first non-blank line, so
    # there's no separate rename mode — the tab label tracks what you type.
    class Note
      getter id : Int64
      getter area : TextArea

      def initialize(@id : Int64, text : String = "")
        @area = TextArea.new(text)
        @area.follow_x = true # long lines scroll horizontally to keep the cursor visible (like the Project description)
      end

      # Sub-tab label: the note's title (first non-blank line, trimmed) truncated
      # to the chip width, else a positional fallback so empty notes are still
      # addressable. The title rule itself lives in `Notes.title` — the single
      # source of truth the CLI listing reads too, so labels can't drift.
      def label(idx : Int32) : String
        if t = Notes.title(@area.text)
          t.size > 15 ? "#{t[0, 14]}…" : t
        else
          "note #{idx + 1}"
        end
      end
    end

    # Unsaved local edits — the Runner consults this so a cross-session reload never
    # clobbers in-progress typing (focus alone is insufficient: Tab / tab-switch /
    # sub-tab-switch leave the buffer dirty without saving).
    getter? dirty : Bool

    def initialize
      @notes = [Note.new(1_i64)] of Note # never empty — always at least one note to type into
      @current = 0
      @next_id = 2_i64
      @dirty = false
      @link_preview = ""            # resolved first-link line for the bottom strip (set by controller)
      @deleted_ids = Set(Int64).new # notes closed this session — so a merge-on-save doesn't resurrect them
      @mode = InputMode::Read
      @read = TextReadState.new
    end

    # Allocate a cross-session-unique note id. A random 63-bit id (not a shared
    # per-doc counter) means a SECOND TUI session on the same project can't hand out
    # the same id for a DIFFERENT new note — which the merge would otherwise mistake
    # for an edit of ours and drop one note's content. Collision is astronomically
    # unlikely for any realistic note count.
    private def alloc_note_id : Int64
      id = Random::Secure.rand(1_i64..0x7fff_ffff_ffff_ffff_i64)
      @next_id = {@next_id, id + 1}.max
      id
    end

    getter link_preview : String

    def link_preview=(s : String) : Nil
      @link_preview = s
    end

    # Stable id of the active note (for entity_links owner_id).
    def current_note_id : Int64
      current.id
    end

    # Load / soft-merge from the store. Re-entering the tab and data_version polls
    # refresh peer changes WITHOUT rebuilding every TextArea when a note's text is
    # unchanged — that preserves caret, scroll, and read-mode selection across
    # capture/ui_state writes that falsely look like "external" commits.
    # Dirty buffers are never touched (caller should also skip when dirty).
    def reload(store : Store) : Nil
      return if @dirty
      soft_merge_from(Notes.load(store))
    end

    # Apply a loaded Doc onto the live note list by stable note id.
    private def soft_merge_from(doc : Notes::Doc) : Nil
      by_id = {} of Int64 => Note
      @notes.each { |n| by_id[n.id] = n }

      merged = [] of Note
      doc.notes.each do |e|
        if existing = by_id[e.id]?
          # Compare on a CRLF-normalized basis: the TextArea buffer is ALWAYS LF (set_text
          # strips \r) while NoteEntry#text is whatever was written into the JSON KV verbatim,
          # and several writers store wire CRLF — MCP create_note/update_note pass the caller's
          # string straight through, and `gori run notes create` takes its body from --text /
          # positional args / STDIN (piping a CRLF file, or `gori run flow N --raw`, stores
          # CRLF). Without normalizing, a CRLF note compares unequal on EVERY poll, so set_text
          # re-ran ~1.3×/s during capture and zeroed the caret + scroll and cleared undo.
          if existing.area.text != TextArea.normalize_lf(e.text)
            # Peer (or our own saved) content genuinely changed — replace body; caret resets
            # with set_text, which is correct here: the text under it is no longer the same.
            existing.area.set_text(e.text)
          end
          # Same text → keep the TextArea object (caret/scroll/undo stack intact).
          merged << existing
        else
          merged << Note.new(e.id, e.text)
        end
      end
      if merged.empty?
        merged << Note.new(alloc_note_id)
      end

      # Keep the active note by id when it still exists; else fall back to persisted cur.
      cur_id = @notes[@current]?.try(&.id)
      @notes = merged
      @current =
        if cur_id && (idx = @notes.index { |n| n.id == cur_id })
          idx
        else
          doc.cur.clamp(0, @notes.size - 1)
        end
      @next_id = {@next_id, doc.next_id}.max
      @dirty = false
      # Leave @mode / @read alone — soft merge must not force READ or drop selection.
    end

    def count : Int32
      @notes.size
    end

    # The active sub-tab index — read by the Runner's arrow-key sub-tab navigation.
    def current_index : Int32
      @current
    end

    # The current note's sub-tab label (first non-blank line, or "note N") — used
    # by the Runner's close-confirmation message.
    def current_label : String
      current.label(@current.clamp(0, @notes.size - 1))
    end

    # True when the current note has no content worth confirming the loss of (so
    # closing it can skip the confirmation modal).
    def current_blank? : Bool
      current.area.first_nonblank_line.nil?
    end

    def set_preedit(text : String) : Nil
      current.area.set_preedit(text)
    end

    def current_text : String
      current.area.text
    end

    # Replace the current note's text (e.g. from the external editor); marks dirty
    # so it persists + the cross-session reconcile won't clobber it.
    def replace_current(text : String) : Nil
      current.area.set_text(text)
      @dirty = true
    end

    # Clear the current note's text (the sub-tab stays open).
    def clear_current : Nil
      current.area.set_text("")
      @dirty = true
    end

    getter mode : InputMode

    def insert_mode? : Bool
      @mode == InputMode::Insert
    end

    def enter_insert! : Nil
      @mode = InputMode::Insert
      @read.sync_from(current.area)
    end

    def exit_insert! : Nil
      @mode = InputMode::Read
      @read.sync_from(current.area)
    end

    def read_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if insert_mode?
      @read.move(current.area, dr, dc, selecting: selecting)
    end

    def copy_text : String
      @read.copy_text(current.area)
    end

    def selection? : Bool
      !insert_mode? && @read.selection?
    end

    def select_line : Nil
      return if insert_mode?
      @read.select_line(current.area)
    end

    def clear_selection : Nil
      @read.clear_selection
    end

    def insert(ch : Char) : Nil
      current.area.insert(ch)
      @dirty = true
    end

    def newline : Nil
      current.area.insert_newline
      @dirty = true
    end

    def backspace : Nil
      current.area.backspace
      @dirty = true
    end

    def undo : Nil
      current.area.undo
      @dirty = true
    end

    def move(dr : Int32, dc : Int32) : Nil
      current.area.move(dr, dc)
    end

    def scroll_view(step : Int32) : Nil
      current.area.scroll_view(step)
    end

    # Home/End: caret to line start/end — pure navigation, does not dirty.
    def home : Nil
      current.area.home
    end

    def end_of_line : Nil
      current.area.end_of_line
    end

    # Forward-delete the char under the caret — a content edit.
    def delete : Nil
      current.area.delete
      @dirty = true
    end

    # Mouse: place the cursor at a click. `rect` is the framed interior the runner
    # passes to render; re-apply render's 1-col side inset so the editor geometry matches.
    def click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      area = Rect.new(rect.x + 1, rect.y, {rect.w - 2, 0}.max, rect.h)
      enter_insert!
      current.area.click_to_cursor(area, mx, my)
    end

    def goto_line(n : Int32) : Nil
      current.area.goto_line(n)
    end

    def search_lines(query : String) : Array(Int32)
      current.area.search_lines(query)
    end

    def match_count(query : String) : Int32
      current.area.match_count(query)
    end

    def replace_matches(query : String, replacement : String) : Int32
      n = current.area.replace_matches(query, replacement)
      @dirty = true if n > 0
      n
    end

    def search_hl=(q : String) : Nil
      current.area.search_hl = q
    end

    # Cursor on the first line → ↑ pops focus to the tab bar (after saving).
    def at_top? : Bool
      current.area.at_top?
    end

    # Open a fresh note and make it current (the new tab gets focus to type into).
    def new_note : Nil
      @notes << Note.new(alloc_note_id)
      @current = @notes.size - 1
      @dirty = true
    end

    # Content-only clone of the active note into a new sibling (new id; no entity_links).
    def duplicate_current : Nil
      text = current.area.text
      @notes << Note.new(alloc_note_id, text)
      @current = @notes.size - 1
      @dirty = true
    end

    # Close the current note. Returns the closed note's id (for link cleanup), or nil
    # when nothing was removed. Always keeps at least one note open.
    def close_note : Int64?
      closed_id = @notes[@current]?.try(&.id)
      @notes.delete_at(@current) if @current < @notes.size
      @deleted_ids << closed_id if closed_id # so merge-on-save doesn't resurrect it from a peer's copy
      if @notes.empty?
        @notes << Note.new(alloc_note_id)
      end
      @current = @current.clamp(0, @notes.size - 1)
      @dirty = true
      closed_id
    end

    # Switch to note `idx` (no-op if out of range or already current). Marks dirty
    # so the active tab is remembered across reloads.
    def switch_note(idx : Int32) : Nil
      return unless 0 <= idx < @notes.size
      return if idx == @current
      @current = idx
      @dirty = true
    end

    # Switch to the note with stable id `id` (create-and-link "open" path).
    # Returns false when that note is not in this session's list.
    def switch_note_by_id(id : Int64) : Bool
      return false unless idx = @notes.index { |n| n.id == id }
      switch_note(idx)
      true
    end

    # Persist iff edited (no-op otherwise — cheap to call on every exit path). Merges
    # against the currently-persisted set first, so a second TUI session on the same
    # project doesn't clobber this session's notes (and vice-versa): peer notes are
    # kept, this session's edits win per-note, and this session's closes are honoured.
    def save(store : Store) : Nil
      return unless @dirty
      mine = @notes.map { |n| Notes::NoteEntry.new(n.id, n.area.text) }
      merged = Notes.merge(Notes.load(store), mine, @deleted_ids, @current, @next_id)
      store.set_setting(DOCS_KEY, Notes.serialize(merged.cur, merged.notes, merged.next_id))
      @next_id = merged.next_id
      @dirty = false
    end

    # `focused` = the editor has focus (cursor + bright). The sub-tab strip is now
    # runner-owned chrome above this frame (shared with Repeater), so the view simply
    # fills its framed interior with the current note's editor.
    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      # Keep the 1-col gap from the frame border that every render_framed body uses
      # (and that Notes used before): only the strip/band above the editor moved —
      # the editor body renders exactly where it did, now filling the freed height.
      area = Rect.new(rect.x + 1, rect.y, {rect.w - 2, 0}.max, rect.h)
      TrafficEmptyState.render(screen, area, variant: :notes) if current_blank?
      ins = focused && insert_mode?
      if focused
        Frame.mode_badge(screen, rect.right - 1, rect.y, rect.x + 1, ins)
      end
      ed = current.area
      ed.render(screen, area, cursor: ins,
        highlight: Settings.editor_markdown ? :markdown : nil)
      paint_read_chrome(screen, area, ed, focused && !insert_mode?) if !insert_mode?
    end

    private def paint_read_chrome(screen : Screen, rect : Rect, ed : TextArea, focused : Bool) : Nil
      return unless focused
      lines = ed.lines_snapshot
      return if lines.empty?
      # Re-sync the read cursor from the editor before painting. A peer edit (2nd session or MCP
      # update_note) can reload a shorter note via soft_merge_from, which resets the editor's
      # clamped caret but deliberately leaves @read alone — a stale @read.cursor.cy past the new
      # end would make the lines[cy] below raise IndexError and crash the TUI render. Mirrors
      # RepeaterView#paint_request_read_chrome.
      @read.sync_from(ed)
      scr = ed.scroll
      sel_bg = Theme.accent_bg
      @read.cursor.highlight_spans(lines).each do |(li, x0, x1)|
        next unless li >= scr && li < scr + rect.h
        row = li - scr
        gw = ed.gutter? ? Gutter.width(lines.size) : 0
        paint_char_span_bg(screen, rect.x + gw, rect.y + row, lines[li], x0, x1, sel_bg)
      end
      cy, cx = @read.cursor.cy, @read.cursor.cx
      return unless cy >= scr && cy < scr + rect.h
      row = cy - scr
      gw = ed.gutter? ? Gutter.width(lines.size) : 0
      line = lines[cy]
      px = rect.x + gw + Screen.draw_width(line[0, cx])
      if px < rect.x + rect.w
        ch = cx < line.size ? line[cx] : ' '
        screen.cell(px, rect.y + row, ch, Theme.bg, Theme.accent_bg)
        screen.cursor(px, rect.y + row)
      end
    end

    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color) : Nil
      return if x0 >= x1
      # Cluster-wise, matching the base draw and the caret. Summing draw_width over single
      # CHARS is exactly the retired per-codepoint measure: it drifts right by each
      # cluster's inflation (1 column for a skin tone, 9 for a ZWJ family), and drawing
      # char-by-char also SHREDS a cluster across cells, stranding a bare combining mark in
      # one of its own. Span edges snap outward so the tint covers whole glyphs.
      a = Screen.cluster_start(line, {x0, line.size}.min)
      b = Screen.cluster_end(line, {x1, line.size}.min)
      px = x + Screen.draw_width(line[0, a])
      i = a
      while i < b
        e = Screen.cluster_end(line, i + 1)
        seg = line[i...e]
        screen.text(px, y, seg, Theme.text, bg)
        px += Screen.draw_width(seg)
        i = e
      end
    end

    # Sub-tab chip labels (one per note), sourced by the Runner's shared strip: each
    # note's first non-blank line, with a positional fallback for empty notes.
    def subtab_labels : Array(String)
      @notes.map_with_index { |note, i| "#{i + 1}:#{note.label(i)}" }
    end

    # The sub-tab filter's searchable projection (one per note, in chip order): the note's
    # title (nil when blank) + its full body text, so a note is findable by title or by
    # any content it holds. See NotesController#filter_subjects.
    def filter_rows : Array({String?, String})
      @notes.map { |note| {Notes.title(note.area.text), note.area.text} }
    end

    # The note currently being edited; @current is kept in range by every mutator.
    private def current : Note
      @notes[@current.clamp(0, @notes.size - 1)]
    end
  end
end
