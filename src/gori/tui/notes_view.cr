require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "../store"

module Gori::Tui
  # The Notes tab (DESIGN.md: 메모/리포트 — the running scratchpad/report). One
  # free-form, per-project document edited inline (no edit mode — typing edits
  # directly, like Replay). Persisted in the project's settings KV (key "notes")
  # and saved when you leave the editor, so it survives reopening the project.
  class NotesView
    KEY = "notes"

    def initialize
      @area = TextArea.new
      @dirty = false
      @loaded = false
    end

    # Load from the store. Re-entering the tab refreshes from disk; safe because
    # edits are always saved before another tab can take focus.
    def reload(store : Store) : Nil
      @area.set_text(store.setting(KEY) || "")
      @dirty = false
      @loaded = true
    end

    def set_preedit(text : String) : Nil
      @area.set_preedit(text)
    end


    def insert(ch : Char) : Nil
      @area.insert(ch)
      @dirty = true
    end

    def newline : Nil
      @area.insert_newline
      @dirty = true
    end

    def backspace : Nil
      @area.backspace
      @dirty = true
    end

    def move(dr : Int32, dc : Int32) : Nil
      @area.move(dr, dc)
    end

    # Persist iff edited (no-op otherwise — cheap to call on every exit path).
    def save(store : Store) : Nil
      return unless @dirty
      store.set_setting(KEY, @area.text)
      @dirty = false
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      screen.text(rect.x + 1, rect.y, "NOTES", Theme::ACCENT, attr: Attribute::Bold)
      hint = focused ? "type to edit · esc back to tabs" : "↵/→ to edit"
      screen.text(rect.x + 8, rect.y, hint, Theme::MUTED)
      Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))
      area = Rect.new(rect.x + 1, rect.y + 2, {rect.w - 2, 0}.max, {rect.bottom - (rect.y + 2), 0}.max)
      @area.render(screen, area, cursor: focused)
    end
  end
end
