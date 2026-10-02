require "termisu"
require "./register"
require "./clipboard"
require "./text_area"
require "./text_read_state"
require "./editor_pane"

module Gori::Tui
  # The READ-mode edits of an editor pane: delete the selection, delete or yank whole lines,
  # and paste the register. The two keysets spell them differently (gori: `x` then `d` / `y`,
  # and `p`; vim: `dd`, `yy`, `⇧V` then `d` / `y`, and `p`), and this is the one engine both
  # spellings run.
  #
  # NO EDIT HAPPENS HERE DIRECTLY. Each operation enters INSERT through the pane's own
  # `editor_enter_insert`, hands the span to the editor, and then replays the keystroke a hand
  # would have typed: ⌫ over a selection to delete, a paste to insert. That is the point of
  # the module. The eight editor panes each do their own work after an edit (the Repeater
  # re-derives Content-Length and refuses a lone `§`, the Fuzzer guards its markers, a note
  # saves, the Project description marks itself dirty), and a READ-mode edit that spliced
  # the TextArea itself would skip all of it. Replayed this way, `d` is exactly "select it,
  # `i`, ⌫, `esc`", and `p` is exactly the bracketed paste the pane already takes (P7: the
  # bytes go in through the same path as the operator's own paste, with the same line-ending
  # rule).
  #
  # Pure over an `EditorPane` and a key sink, so it is spec-able without a terminal: the
  # Runner passes its own `handle_key`, a spec passes the controller's `handle_body_key`, and
  # the setup wizard's practice pad (`KeysetPad`) passes its own INSERT ladder.
  # Each operation returns the status line to show, or nil when the pane already said why.
  module ReadEdit
    alias KeyIn = Proc(Termisu::Event::Key, Nil)

    NO_BUFFER   = "nothing to edit here — this field is not a text buffer"
    READ_ONLY   = "this pane is read-only here"
    NOTHING_SEL = "nothing selected — {repeater.select-line} selects the line, ⇧arrows a span"
    RELOADED    = "the pane reloaded its text — nothing changed, look again and retry"
    EMPTY_REG   = "nothing to paste — {repeater.copy} copies, {editor.delete} deletes into the paste register"

    # The keystroke a pasted character arrives as. `Runner#replay_paste` delivers a refused
    # bulk paste through this, and so does `paste` below, so the two cannot disagree about
    # what a line break or a tab is.
    def self.key_event(c : Char) : Termisu::Event::Key
      case c
      when '\n' then Termisu::Event::Key.new(Termisu::Input::Key::Enter, char: '\r')
      when '\t' then Termisu::Event::Key.new(Termisu::Input::Key::Tab)
      else           Termisu::Event::Key.new(Termisu::Input::Key::Unknown, char: c)
      end
    end

    BACKSPACE = Termisu::Event::Key.new(Termisu::Input::Key::Backspace)

    # Does the READ selection cover whole lines: from column 0 of its first line to the end of
    # its last? That is what `x` (select line) produces, and what makes a copy or a delete
    # LINEWISE, so that `p` puts it back as lines rather than inside one.
    def self.line_selection?(tab : EditorPane) : Bool
      return false unless buf = tab.editor_text_buffer
      area, read = buf
      return false unless span = read.selection_span(area)
      whole_lines?(span, area.lines_snapshot)
    end

    # A span that ENDS at column 0 of a later line is not a line selection, even when that
    # line is empty (`0 >= 0`): ⇧↓ from a line start onto the Repeater's blank head/body line
    # selects "Host: x\n", and reading it as whole lines would take the blank line with it.
    private def self.whole_lines?(span : {Int32, Int32, Int32, Int32}, lines : Array(String)) : Bool
      y0, x0, y1, x1 = span
      return false if y1 > y0 && x1 == 0
      x0 == 0 && x1 >= (lines[y1]?.try(&.size) || 0)
    end

    def self.selection?(tab : EditorPane) : Bool
      return false unless buf = tab.editor_text_buffer
      area, read = buf
      read.selection?(area)
    end

    # gori `d` after `x` (or after a ⇧arrow span), vim `d` in a line selection. The deleted
    # text goes to the register, linewise when the span was whole lines; the clipboard is not
    # touched (see `Register`).
    def self.delete_selection(tab : EditorPane, key_in : KeyIn) : String?
      return NO_BUFFER unless buf = tab.editor_text_buffer
      area, read = buf
      lines = area.lines_snapshot
      unless span = read.selection_span(area)
        # `x` on an EMPTY line selects nothing: the anchor and the caret are the same cell, so
        # there is no span to read back. The line itself is the only thing `x` then `d` can
        # mean there, and without this a blank line could not be deleted in READ at all.
        read.sync_from(area)
        return delete_lines(tab, key_in, area.cy, area.cy) if lines[area.cy]?.try(&.empty?)
        return NOTHING_SEL
      end
      if whole_lines?(span, lines)
        delete_lines(tab, key_in, span[0], span[2])
      else
        y0, x0, y1, x1 = span
        text = slice(lines, y0, x0, y1, x1)
        cut(tab, key_in, {y0, x0, y1, x1}, text, linewise: false, what: "#{text.size} chars")
      end
    end

    # vim `dd`: the caret's line, or every line the selection touches.
    def self.delete_line(tab : EditorPane, key_in : KeyIn) : String?
      return NO_BUFFER unless buf = tab.editor_text_buffer
      area, read = buf
      if span = read.selection_span(area)
        delete_lines(tab, key_in, span[0], span[2])
      else
        read.sync_from(area)
        delete_lines(tab, key_in, area.cy, area.cy)
      end
    end

    # vim `yy`: the caret's line, or every line the selection touches, to the clipboard and
    # the register, linewise. A copy, so it goes through `Clipboard.copy` like every other.
    def self.yank_line(tab : EditorPane) : String
      return NO_BUFFER unless buf = tab.editor_text_buffer
      area, read = buf
      lines = area.lines_snapshot
      return "nothing to yank" if lines.empty?
      y0, y1 = if span = read.selection_span(area)
                 {span[0], span[2]}
               else
                 read.sync_from(area)
                 {area.cy, area.cy}
               end
      text = lines[y0..y1].join("\n")
      written = Clipboard.copy(text)
      Register.linewise!
      "yanked #{plural(y1 - y0 + 1, "line")} (#{written}b to clipboard#{Clipboard.note(written, text)})"
    end

    # `p`: the register after the caret, or after the selection's end. A linewise register
    # goes in as its own line(s) below the caret's line; anything else lands in the line.
    def self.paste(tab : EditorPane, key_in : KeyIn) : String?
      return NO_BUFFER unless buf = tab.editor_text_buffer
      area, read = buf
      return EMPTY_REG unless held = Register.text
      # A copy can hold wire text (the History detail hands over the capture's CRLF). A line's
      # CRLF is its line break, the way `set_text` reads it, so it goes in as one; a lone CR
      # inside a line is data and stays, which keeps a `dd` then `p` byte-for-byte.
      text = TextArea.normalize_lf(held)
      return EMPTY_REG if text.empty?
      lines = area.lines_snapshot
      return NO_BUFFER if lines.empty?
      span = read.selection_span(area)
      read.sync_from(area)
      linewise = Register.linewise?
      y, x = paste_at(area, lines, span, linewise)
      if err = enter(tab, area)
        return err
      end
      area.place_cursor(y, x)
      before = area.edits
      deliver(tab, key_in, linewise ? "\n#{text}" : text)
      changed = area.edits != before
      # vim leaves the caret on the first pasted line; INS left it at the end of the paste.
      area.place_cursor(y + 1, 0) if linewise && changed
      held = !leave(tab)
      read.sync_from(area)
      return "the pane refused the paste" unless changed
      return nil if held
      linewise ? "pasted #{plural(text.count('\n') + 1, "line")}" : "pasted #{plural(text.size, "char")}"
    end

    # Where `p` inserts: the end of the caret's (or the selection's last) line for a linewise
    # register, else just after the selection, else just after the character under the block
    # caret, which is where vim and helix put it. An empty line has no character to step over.
    private def self.paste_at(area : TextArea, lines : Array(String),
                              span : {Int32, Int32, Int32, Int32}?, linewise : Bool) : {Int32, Int32}
      if linewise
        ly = span ? span[2] : area.cy
        {ly, lines[ly].size}
      elsif span
        {span[2], span[3]}
      else
        {area.cy, {area.cx + 1, lines[area.cy].size}.min}
      end
    end

    # The text into the pane exactly as a terminal paste would arrive: in bulk where the pane
    # takes one, else as keystrokes, which is `Runner#flush_bulk_paste`'s own fallback.
    private def self.deliver(tab : EditorPane, key_in : KeyIn, payload : String) : Nil
      return if tab.accepts_bulk_paste? && tab.paste_text(payload)
      payload.each_char { |c| key_in.call(key_event(c)) }
    end

    # Lines y0..y1 out, line breaks included, as one ⌫. Which break goes with them depends on
    # where they sit: the one after the block, or (for a block at the end) the one before it,
    # so no blank line is left where the lines were. The whole buffer leaves one empty line.
    private def self.delete_lines(tab : EditorPane, key_in : KeyIn, y0 : Int32, y1 : Int32) : String?
      return NO_BUFFER unless buf = tab.editor_text_buffer
      area, _ = buf
      lines = area.lines_snapshot
      return "nothing to delete" if lines.empty?
      y0 = y0.clamp(0, lines.size - 1)
      y1 = y1.clamp(y0, lines.size - 1)
      text = lines[y0..y1].join("\n")
      span = if y1 + 1 < lines.size
               {y0, 0, y1 + 1, 0}
             elsif y0 > 0
               {y0 - 1, lines[y0 - 1].size, y1, lines[y1].size}
             else
               {0, 0, y1, lines[y1].size}
             end
      if span[0] == span[2] && span[1] == span[3]
        # One empty line and nothing else: there is nothing to cut, only to remember.
        Register.store(text, linewise: true)
        return "deleted 1 line"
      end
      cut(tab, key_in, span, text, linewise: true, what: plural(y1 - y0 + 1, "line"))
    end

    private def self.cut(tab : EditorPane, key_in : KeyIn, span : {Int32, Int32, Int32, Int32},
                         text : String, linewise : Bool, what : String) : String?
      return NO_BUFFER unless buf = tab.editor_text_buffer
      area, read = buf
      if err = enter(tab, area)
        return err
      end
      y0, x0, y1, x1 = span
      area.select_span(y0, x0, y1, x1)
      before = area.edits
      key_in.call(BACKSPACE)
      changed = area.edits != before
      held = !leave(tab)
      read.clear_selection
      read.sync_from(area)
      return "the pane refused the delete" unless changed
      Register.store(text, linewise: linewise)
      held ? nil : "deleted #{what}"
    end

    # Out of INSERT through the pane's own exit, which does what `esc` does there (an Issue's
    # notes save, the Decoder commits). False when the pane kept INSERT, as an Issue's notes do
    # when a peer rewrote them: the pane has put its reason on screen, and the caller returns
    # nil so a "deleted 1 line" does not paint over it.
    private def self.leave(tab : EditorPane) : Bool
      tab.editor_exit_insert
      tab.editor_read_mode?
    end

    # Into INSERT through the pane's own entry. Nil when it went and the buffer is still the
    # one the span was measured in, else the reason no edit was made:
    # - a pane that stays in READ (a read-only sub-pane, a captured hex editor) takes none;
    # - an entry that RELOADED the buffer (an Issue's notes re-seed from the store when they
    #   are not dirty) moved the text out from under a span measured before it, so cutting
    #   there would delete text the operator never selected.
    private def self.enter(tab : EditorPane, area : TextArea) : String?
      return READ_ONLY unless tab.editor_read_mode?
      rev = area.edits
      tab.editor_enter_insert
      return READ_ONLY if tab.editor_read_mode?
      return nil if area.edits == rev
      leave(tab)
      RELOADED
    end

    private def self.slice(lines : Array(String), y0 : Int32, x0 : Int32, y1 : Int32, x1 : Int32) : String
      return lines[y0][x0...x1] if y0 == y1
      parts = [lines[y0][x0..]]
      (y0 + 1...y1).each { |i| parts << lines[i] }
      parts << lines[y1][0...x1]
      parts.join("\n")
    end

    private def self.plural(n : Int32, word : String) : String
      n == 1 ? "1 #{word}" : "#{n} #{word}s"
    end
  end
end
