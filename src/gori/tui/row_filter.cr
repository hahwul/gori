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
        @field.set_preedit("")
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

    # The status row's width at 80×24 — every toast a filtered list raises fits it whole, so
    # the cut never lands on the half that says where the rule went.
    TOAST_COLS = 59

    # What a toast appends when the query hides the rule a write just saved: ` · hidden by /`,
    # or ` · 2 hidden by /` for a write that saved several (`of`). Short on purpose — the
    # remedy in words is `hidden_detail`, for the Notifications card. `key` is the filter
    # verb's chord, already resolved through the keymap by the caller.
    def self.hidden_suffix(key : String, hidden : Int32 = 1, of : Int32 = 1) : String
      " · #{of > 1 ? "#{hidden} " : ""}hidden by #{key}"
    end

    # The long form of a `hidden_suffix` toast, for the Notifications card.
    def hidden_detail(key : String) : String
      "The filter “#{text.strip}” hides it; it is saved and in effect. #{key} then esc clears the filter."
    end

    # A filtered card's border count, every number read off the SAME list: `E/S enabled` over
    # the rows on screen, plus `· T total` while a query hides some (`total` is the unfiltered
    # size). The Rewriter and Colormarker cards used to put the engine's count of EVERY enabled
    # rule over the filtered row count, so one query read `2/1 enabled` and, two adds later,
    # `4/1` — a ratio of two different lists.
    def self.count_meta(enabled : Int32, shown : Int32, total : Int32) : String
      meta = "#{enabled}/#{shown} enabled"
      total > shown ? "#{meta} · #{total} total" : meta
    end

    # The empty-state line for a pane whose source has rows but none match. `remedy` is for a
    # pane whose `esc` at rest does something else.
    def no_match_line(noun : String, remedy : String = "esc to clear") : String
      "no #{noun} match “#{text.strip}” — #{remedy}"
    end
  end
end
