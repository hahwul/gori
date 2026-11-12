require "./text_field"
require "./line_edit"
require "./screen"
require "./theme"
require "./geometry"
require "./frame"

module Gori::Tui
  # A `/` substring filter over a list pane's rows — the OAST callbacks filter, lifted so the
  # Discover FINDINGS, Miner RESULTS and Authorize request lists can share it instead of
  # each growing a `@query`/caret pair of their own.
  #
  # `TextField` carries the line editing (⌃/⌥←→ by word, Home/End, Delete, ⌥⌫, ^Z), so the
  # bar answers every key a card's field does. The filter is a LENS: the view keeps its
  # source array, memoises the visible indices over `query`, and points its cursor at the
  # visible list. `shown?` is whether the bar owns a row THIS frame, which is only while it
  # is being typed in: at rest (idle, or holding a query) the filter rides the border above
  # its rows (`render_label`), so a pane's geometry never moves for a filter nobody is typing.
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
      @editing
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
      elsif act = LineEdit.shell_action(ev) # ^A/^E/^U/^W, as on the `/` bars (#1379)
        case act
        when :home            then @field.home
        when :end             then @field.end_of_line
        when :delete_to_start then @field.delete_to_start
        when :delete_word     then @field.delete_word_left
        end
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

    # The bar: `filter › text▏` (hardware cursor + IME preedit through `Screen#input_line`).
    # Drawn only while editing; see #render_label for the rest of the time.
    def render_bar(screen : Screen, rect : Rect) : Nil
      return if rect.empty? || !@editing
      screen.fill(Rect.new(rect.x, rect.y, rect.w, 1), Theme.bg)
      prefix = "filter › "
      screen.text(rect.x + 1, rect.y, prefix, Theme.accent, Theme.bg)
      base = rect.x + 1 + prefix.size
      screen.input_line(base, rect.y, @field.value, @field.caret, @field.preedit,
        Theme.text_bright, Theme.bg, width: {rect.w - prefix.size - 2, 0}.max)
    end

    # The filter at rest, on the border or hairline above its rows: ` / filter ` idle,
    # ` : query ` while one is held. `x`/`y` are where on that border; the label never
    # reaches `max_x`, which a caller sets clear of whatever the border's right end carries.
    # `rows` is how many rows the pane has to narrow: with none, and no query held, there is
    # no key to name.
    def render_label(screen : Screen, x : Int32, y : Int32, max_x : Int32, rows : Int32) : Nil
      return if @editing || (rows <= 0 && !active?)
      Frame.filter_label(screen, x, y, max_x, @field.value.strip)
    end

    # The usual `max_x` for a card's top border: the label keeps to the left three fifths,
    # which leaves the right end to the count or the badges every list card puts there, and
    # never runs past `meta_x` (what `Frame.border_meta` returned) when that meta is long
    # enough to reach into those three fifths: a held query is clipped, not run into it.
    def self.label_limit(rect : Rect, meta_x : Int32? = nil) : Int32
      limit = rect.x + rect.w * 3 // 5
      meta_x ? {limit, meta_x}.min : limit
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
