require "./text_field"
require "./screen"
require "./theme"
require "./geometry"

module Gori::Tui
  # A `/` substring filter over a list pane's rows — the OAST callbacks filter, lifted so the
  # Discover FINDINGS, Miner RESULTS and Authorize request lists can share it instead of
  # each growing a `@query`/caret pair of their own.
  #
  # `TextField` carries the line editing (⌃/⌥←→ by word, Home/End, Delete, ⌥⌫, ^Z), so the
  # bar answers every key a card's field does. The filter is a LENS: the view keeps its
  # source array, memoises the visible indices over `query`, and points its cursor at the
  # visible list. `shown?` is whether the bar owns a row THIS frame — editing, or holding a
  # query — so an idle pane's geometry is exactly what it was without a filter.
  class RowFilter
    def initialize
      @field = TextField.new
      @editing = false
    end

    def start : Nil
      @editing = true
      @field.end_of_line
    end

    # The bar captures keys (the shell routes them here ahead of the focus ring).
    def editing? : Bool
      @editing
    end

    # A query is held — committed or mid-edit — so the rows are narrowed.
    def active? : Bool
      !@field.value.blank?
    end

    # The bar takes a row of the pane this frame.
    def shown? : Bool
      @editing || active?
    end

    def text : String
      @field.value
    end

    # The memo-key half: what `matches?` compares against.
    def query : String
      @field.value.strip.downcase
    end

    def clear : Nil
      @field.set("")
      @editing = false
    end

    # ↵ keeps the query and leaves edit mode; esc clears it; everything else edits the field.
    # ALWAYS true — a Tab that escaped to the shell would move the focus ring mid-edit.
    def handle_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.enter?
        @editing = false
      elsif key.escape?
        clear
      else
        @field.handle_edit_key(ev)
      end
      true
    end

    def set_preedit(text : String) : Bool
      return false unless @editing
      @field.set_preedit(text)
      true
    end

    # Case-insensitive substring over whatever the row shows; a blank query matches all.
    def matches?(haystack : String) : Bool
      q = query
      q.empty? || haystack.downcase.includes?(q)
    end

    # The bar: `filter › text▏` while editing (hardware cursor + IME preedit through
    # `Screen#input_line`), `: text` once committed.
    def render_bar(screen : Screen, rect : Rect) : Nil
      return if rect.empty?
      screen.fill(Rect.new(rect.x, rect.y, rect.w, 1), Theme.bg)
      if @editing
        prefix = "filter › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent, Theme.bg)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @field.value, @field.caret, @field.preedit,
          Theme.text_bright, Theme.bg, width: {rect.w - prefix.size - 2, 0}.max)
      else
        screen.text(rect.x + 1, rect.y, ": #{@field.value}", Theme.text, Theme.bg, width: {rect.w - 2, 0}.max)
      end
    end

    def hint : String
      "type to filter · ↵ keep · esc clear"
    end

    # The empty-state line for a pane whose source has rows but none match.
    def no_match_line(noun : String) : String
      "no #{noun} match “#{text.strip}” — esc to clear"
    end
  end
end
