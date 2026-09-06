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
    def self.action(ev : Termisu::Event::Key) : Symbol?
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

    # Whether `action` changes the text (as opposed to only moving the caret) — the bars
    # re-run their filter after an edit and not after a motion.
    def self.mutating?(action : Symbol) : Bool
      action == :delete || action == :delete_word
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
      else
        {text, caret}
      end
    end

    # A modified ⌫. Same shape as `TextField#word_delete_key?`, and load-bearing for the same
    # reason: a terminal sends ⌥⌫ as ESC + 0x7F, which arrives as Unknown + Alt carrying DEL.
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

    private def self.word_char?(c : Char) : Bool
      c.alphanumeric? || c == '_' || c == '-'
    end
  end

  # For a view that holds a `/` bar as `@query : String` + `@qcx : Int32`: the `LineEdit`
  # actions applied in place. `query_edited` is the hook a view with a suggestion popup
  # overrides (History re-syncs its dropdown to the token under the caret).
  module QueryBarEdit
    def query_edit(action : Symbol) : Nil
      @query, @qcx = LineEdit.apply(action, @query, @qcx)
      query_edited
    end

    def query_edited : Nil
    end
  end
end
