require "../filter_ast"
require "./screen"

module Gori::Tui
  # The caret edits a one-line bar takes beyond a character at a time — word motion, the
  # line's ends, forward delete, delete-word — as pure functions over `{text, caret}`.
  #
  # `TextField` has all of these for the fields the overlays own. The six `/` bars (History,
  # Sitemap, Issues, Probe, Intercept, the sub-tab strip filter) and the issue form's title
  # keep their own `@query`/`@qcx` pair instead, because each renders through
  # `Screen#input_line` with its own highlighting and popup, and each answered ⌃←/⌥← with a
  # one-character step and Home/End/Delete with nothing. This is the one keymap they share;
  # the word rule is `TextField`'s, so a hand moving between a bar and a card feels no seam.
  module LineEdit
    # The edit `ev` asks for, or nil when it is not one of these. Checked BEFORE a bar's
    # plain ←/→ arm, since the modified arrows are a different request from the bare ones.
    #
    # ^A/^E/^U/^W are the shell's line keys (#1379). A bar that is editing takes every key ahead
    # of the keymap (Runner#handle_key), so they shadow nothing there: the tab chords on the
    # same letters (Repeater/Fuzzer ^A auto-mark, ^U pretty, ^W close, ^E $EDITOR) answer
    # once the bar is left, as they always did.
    def self.action(ev : Termisu::Event::Key) : Symbol?
      if shell = shell_action(ev)
        return shell
      end
      key = ev.key
      mod = ev.ctrl? || ev.alt? # ⌥ is the macOS spelling of the word modifier, ⌃ everywhere else
      case
      when word_delete_key?(ev) then :delete_word
      when mod && key.left?     then :word_left
      when mod && key.right?    then :word_right
      when key.home?            then :home
      when key.end?             then :end
      when key.delete?          then :delete
      end
    end

    # ^A line start, ^E line end, ^U delete to line start, ^W delete the word before the caret.
    # Ctrl only: ⌥A/⌥E are not these keys anywhere.
    def self.shell_action(ev : Termisu::Event::Key) : Symbol?
      return nil unless ev.ctrl? && !ev.alt?
      key = ev.key
      case
      when key.lower_a? then :home
      when key.lower_e? then :end
      when key.lower_u? then :delete_to_start
      when key.lower_w? then :delete_word
      end
    end

    # Whether `action` changes the text (as opposed to only moving the caret) — the bars
    # re-run their filter after an edit and not after a motion.
    def self.mutating?(action : Symbol) : Bool
      action == :delete || action == :delete_word || action == :delete_to_start
    end

    # `action` applied to `{text, caret}`; the caret is clamped on the way in.
    def self.apply(action : Symbol, text : String, caret : Int32) : {String, Int32}
      caret = caret.clamp(0, text.size)
      case action
      when :word_left  then {text, word_left(text, caret)}
      when :word_right then {text, word_right(text, caret)}
      when :home       then {text, 0}
      when :end        then {text, text.size}
      when :delete
        caret < text.size ? {"#{text[0, caret]}#{text[caret + 1..]}", caret} : {text, caret}
      when :delete_word
        at = word_left(text, caret)
        {"#{text[0, at]}#{text[caret..]}", at}
      when :delete_to_start
        {text[caret..], 0}
      else
        {text, caret}
      end
    end

    # A modified ⌫ — the one test `TextField` and `TextArea` answer through too. The `char`
    # half is load-bearing: a terminal sends ⌥⌫ as ESC + 0x7F, and termisu's Alt-prefix branch
    # maps the payload through `Key.from_char`, which has no name for DEL — so it arrives as
    # `Key::Unknown` + Alt carrying that char, not as Backspace.
    def self.word_delete_key?(ev : Termisu::Event::Key) : Bool
      return false unless ev.ctrl? || ev.alt?
      return true if ev.key.backspace?
      c = ev.char
      !!c && (c == '\u{7F}' || c == '\b')
    end

    # The word rule `TextField` uses: a run of word characters, or a run of punctuation, with
    # whitespace skipped first.
    def self.word_left(text : String, caret : Int32) : Int32
      i = caret.clamp(0, text.size)
      while i > 0 && text[i - 1].whitespace?
        i -= 1
      end
      if i > 0
        word = word_char?(text[i - 1])
        while i > 0 && !text[i - 1].whitespace? && word_char?(text[i - 1]) == word
          i -= 1
        end
      end
      i
    end

    def self.word_right(text : String, caret : Int32) : Int32
      i = caret.clamp(0, text.size)
      if i < text.size && !text[i].whitespace?
        word = word_char?(text[i])
        while i < text.size && !text[i].whitespace? && word_char?(text[i]) == word
          i += 1
        end
      end
      while i < text.size && text[i].whitespace?
        i += 1
      end
      i
    end

    # The WORD under character index `cx` for a double-click, as `{start, end}`: a run of word
    # characters or a run of punctuation, on the same rule as `word_left`/`word_right`, so a URL
    # breaks at every `/`, `?` and `=` while a host label stays whole, and a double-click and
    # ⌥←/→ agree about where a word ends. nil on whitespace or past the end — the gesture means
    # "give me this token", and there is none. The one span TextArea, ReadCursor and
    # LineFieldRead select, so the three cannot disagree.
    def self.word_span(line : String, cx : Int32) : {Int32, Int32}?
      # `Screen.column_for_click` rounds a POINTER to the NEAREST cluster boundary, so a
      # double-click on the RIGHT half of a WIDE glyph — a Hangul syllable, a CJK ideograph:
      # half of every pointer position over such text — resolves to the position AFTER it,
      # where the word may have already ended and there is no token to take. Step back over
      # that one glyph, and ONLY when it is wide: a 1-column cluster cannot be rounded past,
      # so every ASCII gesture is bit-for-bit what it was (including "a double-click on a
      # space takes nothing").
      c = Screen.step_back_over_wide(line, cx.clamp(0, line.size))
      return nil if c >= line.size || line[c].whitespace?
      word = word_char?(line[c])
      a = c
      while a > 0 && !line[a - 1].whitespace? && word_char?(line[a - 1]) == word
        a -= 1
      end
      b = c
      while b < line.size && !line[b].whitespace? && word_char?(line[b]) == word
        b += 1
      end
      a == b ? nil : {a, b}
    end

    private def self.word_char?(c : Char) : Bool
      c.alphanumeric? || c == '_' || c == '-'
    end
  end

  # The `/` bar a view holds as `@query : String` + `@qcx : Int32` + `@querying : Bool` +
  # `@preedit : String`: entering and leaving it, typing into it, and the `LineEdit` actions,
  # for all six bars (History, Sitemap, Issues, Probe, Intercept, Evidence).
  #
  # The bars differ in what an edit SETTLES, and only there. Each says so through the hooks
  # below rather than by redefining a method here: Crystal has no `override`, so a view's own
  # `def stop_query` would shadow this one in silence.
  module QueryBarEdit
    # Hook: the text changed (a typed or deleted character, a completion, Esc's clear). Issues,
    # Probe and Evidence re-filter here; the bars that reload on a debounce only re-sync the
    # dropdown, and their controller schedules the reload.
    abstract def query_edited : Nil

    # Hook: only the caret moved. A bar with a dropdown re-derives it for the token now under
    # the caret.
    abstract def query_caret_moved : Nil

    # Hook: the bar was left, by Enter or Esc.
    abstract def query_left : Nil

    # Hook: what a `LineEdit` action settles. An action that changes no text (Home, End, ⌥←,
    # ⌥→) takes the caret-move path, so it does not re-run a filter predicate.
    def query_line_edited(action : Symbol) : Nil
      LineEdit.mutating?(action) ? query_edited : query_caret_moved
    end

    # Hook: the span `query_complete` splices over. The QL cursor's, which peels the grammar's
    # punctuation (`-ho` completes to `-host:`).
    private def query_token_span : {Int32, Int32}
      cur = FilterAst.token_at(@query, @qcx)
      {cur.start, cur.stop}
    end

    def start_query : Nil
      @querying = true
      @qcx = @query.size
    end

    def stop_query : Nil # Enter: keep the filter, leave edit mode
      @querying = false
      query_left
    end

    def cancel_query : Nil # Esc: clear the filter, leave edit mode
      @querying = false
      @query = ""
      @qcx = 0
      @preedit = ""
      query_left
      query_edited
    end

    def query_insert(ch : Char) : Nil
      @query = "#{@query[0, @qcx]}#{ch}#{@query[@qcx..]}"
      @qcx += 1
      query_edited
    end

    def query_backspace : Nil
      return if @qcx == 0
      @query = "#{@query[0, @qcx - 1]}#{@query[@qcx..]}"
      @qcx -= 1
      query_edited
    end

    def query_move(d : Int32) : Nil
      @qcx = (@qcx + d).clamp(0, @query.size)
      query_caret_moved
    end

    def query_edit(action : Symbol) : Nil
      @query, @qcx = LineEdit.apply(action, @query, @qcx)
      query_line_edited(action)
    end

    # Complete the token under the caret to the SELECTED candidate (dropdown open) or the first
    # (closed). False when there is nothing to complete, so the caller leaves the query alone.
    #
    # `close` is what ↵ passes and ↹ does not, and it is load-bearing rather than cosmetic. With
    # the dropdown open, re-deriving candidates after the splice can hand back a list containing
    # the token that was just completed (`method:GET` narrows the value pool to exactly
    # `["method:GET"]`), so the popup never shuts, ↵ re-splices the identical string forever, and
    # `stop_query` becomes unreachable. ↹ keeps it open on purpose, because chaining field →
    # value is the whole point of Tab. Open, `query_edited` re-derives the now-stale candidate
    # set (a field completion opens a value list); closed, its re-sync is a no-op.
    def query_complete(close : Bool = false) : Bool
      pick = @popup.choice(query_suggestions)
      return false unless pick
      s, e = query_token_span
      @query = "#{@query[0, s]}#{pick}#{@query[e..]}"
      @qcx = s + pick.size
      popup_close if close
      query_edited
      true
    end
  end

  # The opt-in completion dropdown (`↓`) four bars share as-is: Issues, Probe, Sitemap and
  # Intercept. History's is async-aware (`@popup_requested`) and keeps its own. See
  # `SuggestPopup` for why the dropdown is opt-in.
  module QueryBarPopup
    include QueryBarEdit

    def popup_open? : Bool
      @popup.open?
    end

    # `↓`: open the dropdown, or move down inside it. Nil rather than Bool: the key is claimed
    # either way, and an earlier Bool "so the key falls through" was a contract no controller
    # honoured, which is worse than not offering one.
    def popup_down : Nil
      return @popup.move(1) if @popup.open?
      @popup.set(query_suggestions)
      @popup.open!
    end

    def popup_up : Nil
      @popup.move(-1)
    end

    def popup_close : Nil
      @popup.close
    end

    private def sync_popup : Nil
      @popup.set(query_suggestions) if @popup.open?
    end

    def query_caret_moved : Nil
      sync_popup
    end

    def query_left : Nil
      popup_close
    end
  end
end
