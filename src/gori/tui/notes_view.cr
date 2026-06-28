require "json"
require "./screen"
require "./theme"
require "./text_area"
require "../store"
require "../settings"

module Gori::Tui
  # The Notes tab (DESIGN.md: notes/report — the running scratchpad/report).
  # Multiple free-form, per-project documents kept as sub-tabs (like Replay):
  # `^N` opens a new note, `^W` closes the current one, `^1-9` switches. Each
  # note is edited inline (no edit mode — typing edits directly). The whole set
  # is persisted in the project's settings KV as JSON (key "notes.docs") and
  # saved when you leave the editor, so it survives reopening the project.
  #
  # Backward compatibility: a project written by the single-note build stored a
  # plain-text document under the key "notes". On first load (when "notes.docs"
  # is absent) that legacy value is migrated into the first note; the new JSON
  # key is written on the next save (the legacy key is left untouched, harmless).
  class NotesView
    DOCS_KEY   = "notes.docs" # JSON {"cur":Int32, "notes":[String, ...]}
    LEGACY_KEY = "notes"      # pre-multi single plain-text note

    # One note document: a title is derived from its first non-blank line, so
    # there's no separate rename mode — the tab label tracks what you type.
    class Note
      getter area : TextArea

      def initialize(text : String = "")
        @area = TextArea.new(text)
      end

      # Sub-tab label: the first non-blank line (trimmed/truncated), else a
      # positional fallback so empty notes are still addressable.
      def label(idx : Int32) : String
        if line = @area.first_nonblank_line
          t = line.strip
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
      @notes = [Note.new] of Note # never empty — always at least one note to type into
      @current = 0
      @dirty = false
    end

    # Load from the store. Re-entering the tab refreshes from disk; safe because
    # edits are always saved before another tab can take focus.
    def reload(store : Store) : Nil
      @notes = load_notes(store)
      @notes << Note.new if @notes.empty?
      @current = @current.clamp(0, @notes.size - 1)
      @dirty = false
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

    def move(dr : Int32, dc : Int32) : Nil
      current.area.move(dr, dc)
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
      current.area.click_to_cursor(area, mx, my)
    end

    def goto_line(n : Int32) : Nil
      current.area.goto_line(n)
    end

    def search_lines(query : String) : Array(Int32)
      current.area.search_lines(query)
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
      @notes << Note.new
      @current = @notes.size - 1
      @dirty = true
    end

    # Close the current note. Always keeps at least one note open (a fresh empty
    # one replaces the last), clamping the active index like Replay's ^W.
    def close_note : Nil
      @notes.delete_at(@current) if @current < @notes.size
      @notes << Note.new if @notes.empty?
      @current = @current.clamp(0, @notes.size - 1)
      @dirty = true
    end

    # Switch to note `idx` (no-op if out of range or already current). Marks dirty
    # so the active tab is remembered across reloads.
    def switch_note(idx : Int32) : Nil
      return unless 0 <= idx < @notes.size
      return if idx == @current
      @current = idx
      @dirty = true
    end

    # Persist iff edited (no-op otherwise — cheap to call on every exit path).
    def save(store : Store) : Nil
      return unless @dirty
      store.set_setting(DOCS_KEY, serialize)
      @dirty = false
    end

    # `focused` = the editor has focus (cursor + bright). The sub-tab strip is now
    # runner-owned chrome above this frame (shared with Replay), so the view simply
    # fills its framed interior with the current note's editor.
    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      # Keep the 1-col gap from the frame border that every render_framed body uses
      # (and that Notes used before): only the strip/band above the editor moved —
      # the editor body renders exactly where it did, now filling the freed height.
      area = Rect.new(rect.x + 1, rect.y, {rect.w - 2, 0}.max, rect.h)
      current.area.render(screen, area, cursor: focused,
        highlight: Settings.editor_markdown ? :markdown : nil)
    end

    # Sub-tab chip labels (one per note), sourced by the Runner's shared strip: each
    # note's first non-blank line, with a positional fallback for empty notes.
    def subtab_labels : Array(String)
      @notes.map_with_index { |note, i| "#{i + 1}:#{note.label(i)}" }
    end

    # The note currently being edited; @current is kept in range by every mutator.
    private def current : Note
      @notes[@current.clamp(0, @notes.size - 1)]
    end

    # Read the persisted notes: prefer the JSON set, fall back to the legacy
    # single-note plain text, else nothing (reload then seeds one empty note).
    private def load_notes(store : Store) : Array(Note)
      if raw = store.setting(DOCS_KEY)
        if notes = parse_docs(raw)
          return notes
        end
      end
      legacy = store.setting(LEGACY_KEY)
      @current = 0
      return [Note.new(legacy)] if legacy && !legacy.empty?
      [] of Note
    end

    # Parse the JSON document set; nil on malformed data so the caller falls back
    # (defensive — the KV value could be hand-edited or written by a future build).
    private def parse_docs(raw : String) : Array(Note)?
      doc = JSON.parse(raw)
      arr = doc["notes"]?.try(&.as_a?)
      return nil unless arr
      @current = doc["cur"]?.try(&.as_i?) || 0
      arr.map { |v| Note.new(v.as_s? || "") }
    rescue JSON::ParseException
      nil
    end

    private def serialize : String
      JSON.build do |j|
        j.object do
          j.field "cur", @current
          j.field "notes" do
            j.array do
              @notes.each { |n| j.string(n.area.text) }
            end
          end
        end
      end
    end
  end
end
