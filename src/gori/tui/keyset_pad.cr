require "termisu"
require "../verb"
require "../hotkeys"
require "./editor_pane"
require "./frame"
require "./keybind"
require "./read_edit"
require "./register"
require "./screen"
require "./text_area"
require "./text_read_state"
require "./theme"
require "../plural"

module Gori::Tui
  # The setup wizard's practice pad: a three-line editor on which a new operator tries an
  # editor keyset before choosing it.
  #
  # It is the real grammar, not a picture of one. A key resolves through a `Verb::Keymap`
  # built for the STAGED keyset (with the operator's own rebinds, which win over a keyset in
  # the app too), down the same chain a Notes editor walks: `Scope::Editor`, then the Notes
  # tab's scope, which is where the pad borrows `select-line` and `copy` from. Delete and paste
  # run `ReadEdit`, the engine every editor pane runs, through the `EditorPane` seam. What the
  # pad does NOT do is fall through to Global: a stray `c` in a real editor stops capture, and
  # in a practice pad it has nothing to stop, so it is reported rather than run.
  #
  # Two things are deliberately NOT real:
  # - copies stay in the paste register. A real `y` also writes the system clipboard (OSC 52),
  #   and the wizard has no business replacing what the operator copied elsewhere with sample
  #   text. The wizard restores the register on its way out, too (`SetupWizard#run`).
  # - prompts (`^F` find, `^G` go to line) are named, not opened: the wizard has no prompt bar.
  #
  # Pure over its own state, so the whole grammar is spec-able without a terminal.
  class KeysetPad
    include EditorPane

    SAMPLE = "GET /api/users HTTP/1.1\nHost: example.test\nAccept: */*"

    # The tab scope the pad stands in for. Notes is the plain text editor: its tab verbs are
    # exactly select-line, copy and clear-selection, with no request-shaped extras.
    TAB_SCOPE = Verb::Scope::Notes

    # What each keyset's offer row spells out. Tokens, so the row prints the chord the
    # keymap really fires (a rebind included) rather than a letter written here.
    REFERENCE = {
      Verb::Keyset::Kind::Helix => "{notes.select-line} line · {notes.copy} copy · {editor.delete} delete · " \
                                   "{editor.paste} paste · {editor.undo} undo",
      Verb::Keyset::Kind::Vim => "{notes.select-line} line · {editor.yank-line}{editor.yank-line} yank · " \
                                 "{editor.delete-line}{editor.delete-line} delete · {editor.paste} paste · " \
                                 "{editor.undo} undo",
    }

    # The first status line under each keyset: the one gesture that differs, spelled out.
    INTRO = {
      Verb::Keyset::Kind::Helix => "READ · {notes.select-line} selects the line, then {editor.delete} deletes it · " \
                                   "{editor.paste} puts it back · {editor.undo} undoes",
      Verb::Keyset::Kind::Vim => "READ · {editor.delete-line}{editor.delete-line} deletes the line · " \
                                 "{editor.paste} puts it back · {editor.undo} undoes · {editor.insert} types",
    }

    getter keyset : Verb::Keyset::Kind
    getter status : String
    getter? insert : Bool = false

    @armed : String? = nil

    getter registry : Verb::Registry

    # `Verbs.registry` builds a fresh registry on every call, so it is asked for once, here.
    def initialize(@keyset : Verb::Keyset::Kind = Verb::Keyset::DEFAULT,
                   registry : Verb::Registry? = nil,
                   @profile : String = Settings.keymap_os,
                   overrides : Hash(String, Array(Verb::Chord))? = nil)
      @registry = reg = registry || Verbs.registry
      @overrides = overrides || Hotkeys.rebindable_overrides(reg)
      @area = TextArea.new(SAMPLE)
      @read = TextReadState.new
      @keymaps = {} of Verb::Keyset::Kind => Verb::Keymap
      @references = {} of Verb::Keyset::Kind => String
      @status = intro
    end

    # Switch the grammar under the same text, so a line deleted the helix way can be put back
    # the vim way. An armed `d` belonged to the old grammar and is dropped with it.
    def keyset=(kind : Verb::Keyset::Kind) : Verb::Keyset::Kind
      @armed = nil
      @keyset = kind
      @status = intro
      kind
    end

    def text : String
      @area.text
    end

    def armed? : Bool
      !@armed.nil?
    end

    # `kind`'s key summary for its offer row, from this pad's keymap inputs (a rebind included).
    # Fixed for the pad's lifetime and drawn every frame, so it is expanded once per keyset.
    def reference(kind : Verb::Keyset::Kind) : String
      @references[kind] ||= expand(REFERENCE[kind], kind)
    end

    # Drop an armed `d` / `y`. The host calls it when the keys leave the pad: the Runner drops
    # the operator once focus leaves the editor's READ mode, and a `d` left armed behind a ⇥
    # would spend the first key typed on return, or delete a line with nothing on screen
    # saying a `d` was waiting.
    def disarm : Nil
      @armed = nil
    end

    # One key. False only for the keys the pad hands back to its host: `esc` in READ with
    # nothing armed, which is "I am done trying". `esc` in INSERT leaves INSERT, and `esc`
    # after a `d` cancels the `d`, exactly as in a real pane.
    def handle_key(ev : Termisu::Event::Key) : Bool
      if id = @armed
        # Spent by this key whatever it is — the #1461 review found an armed `d` surviving
        # other keys when it was cleared anywhere later than the top.
        @armed = nil
        finish_op(id, ev)
        return true
      end
      return read_key(ev) unless @insert
      ev.key.escape? ? leave_insert : insert_key(ev)
      true
    end

    # --- EditorPane (the seam `ReadEdit` drives) ---

    def editor_text_buffer : {TextArea, TextReadState}?
      {@area, @read}
    end

    def editor_read_mode? : Bool
      !@insert
    end

    def editor_enter_insert : Bool
      @insert = true
      @read.sync_from(@area)
      true
    end

    def editor_exit_insert : Bool
      @insert = false
      # `esc` then `y` copies what was selected while typing, as in every editor pane.
      @read.adopt_editor_selection(@area)
      true
    end

    def accepts_bulk_paste? : Bool
      true
    end

    def paste_text(text : String) : Bool
      @area.insert_text(text)
      true
    end

    # --- rendering ---

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 6 || rect.h < 3
      title = "TRY IT · #{Verb::Keyset.name_of(@keyset)}-ish"
      Frame.card(screen, rect, title, bg: Theme.bg, border: focused ? Theme.border_focus : Theme.border)
      Frame.mode_badge(screen, rect.right - 2, rect.y, rect.x + 2, @insert)
      inner = Rect.new(rect.x + 2, rect.y + 1, {rect.w - 4, 1}.max, {rect.h - 2, 1}.max)
      @area.render(screen, inner, cursor: focused && @insert)
      @read.paint_chrome(screen, inner, @area, focused) unless @insert
    end

    # --- input ---

    # READ: the structural keys a Notes editor answers itself (`NotesController#handle_read`),
    # then everything else through the keymap.
    private def read_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      return false if key.escape?
      if step = caret_step(ev)
        @read.move(@area, step[0], step[1], selecting: ev.shift?)
      elsif !line_edge(ev)
        run(ev)
      end
      true
    end

    # The arrows, and `h`/`j`/`k`/`l` when bare: the caret keys a Notes READ pane answers.
    private def caret_step(ev : Termisu::Event::Key) : {Int32, Int32}?
      key = ev.key
      return {-1, 0} if key.up?
      return {1, 0} if key.down?
      return {0, -1} if key.left?
      return {0, 1} if key.right?
      ev.char.try { |c| CARET_LETTERS[c]? } unless ev.ctrl? || ev.alt?
    end

    private CARET_LETTERS = {'k' => {-1, 0}, 'j' => {1, 0}, 'h' => {0, -1}, 'l' => {0, 1}}

    # Home/End move the EDITOR's caret; the READ cursor follows, extending a ⇧ selection.
    private def line_edge(ev : Termisu::Event::Key) : Bool
      key = ev.key
      return false unless key.home? || key.end?
      key.home? ? @area.home(ev.shift?) : @area.end_of_line(ev.shift?)
      @read.sync_to(@area, selecting: ev.shift?)
      true
    end

    # INSERT: what every editor's INS ladder does. Modified chords other than the editor's
    # own (`^Z`, word motion) go to the keymap, which is how `^Y` copies an INS selection.
    private def insert_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?                  then @area.insert_newline
      when ev.ctrl_z?                  then @area.undo
      when @area.word_delete_key?(ev)  then @area.handle_motion_key(ev)
      when key.backspace?              then @area.backspace
      when key.delete?                 then @area.delete
      when @area.handle_motion_key(ev) then nil
      when ev.ctrl? || ev.alt?         then run(ev)
      when c && !c.control?            then @area.insert(c)
      end
    end

    private def leave_insert : Nil
      editor_exit_insert
      @status = expand("READ again — the letters are commands · {editor.insert} types")
    end

    private def run(ev : Termisu::Event::Key) : Nil
      chord = Keybind.from_event(ev)
      unless chord && (id = resolve(chord))
        @status = chord ? "#{Hotkeys.display_label(chord)}: nothing in an editor answers it" : ""
        return
      end
      dispatch(id, chord)
    end

    private def dispatch(id : String, chord : Verb::Chord) : Nil
      return if dispatch_edit(id) || dispatch_motion(id) || dispatch_tab(id)
      case id
      when "editor.insert", "editor.insert-enter"
        editor_enter_insert
        @status = "INS — type anything · esc goes back to READ"
      when "editor.append"
        @read.move(@area, 0, 1)
        editor_enter_insert
        @status = "INS one column right (append) · esc goes back to READ"
      when "editor.undo"
        before = @area.edits
        @area.undo
        @read.sync_from(@area)
        @status = @area.edits == before ? "nothing to undo" : "undone"
      else
        title = @registry[id]?.try(&.title) || id
        @status = "#{Hotkeys.display_label(chord)}: #{title} — opens in a real pane, not here"
      end
    end

    # The edits, run by `ReadEdit` as every editor pane runs them. False for any other id.
    private def dispatch_edit(id : String) : Bool
      case id
      when "editor.delete" then say(ReadEdit.delete_selection(self, key_in))
      when "editor.paste"  then say(ReadEdit.paste(self, key_in))
      when "editor.delete-line"
        ReadEdit.selection?(self) ? say(ReadEdit.delete_selection(self, key_in)) : arm(id, "deletes the line")
      when "editor.yank-line"
        ReadEdit.selection?(self) ? copy : arm(id, "copies the line")
      else
        return false
      end
      true
    end

    # The caret motions: the buffer's edges, a word, and INSERT at a line edge. False for any
    # other id.
    private def dispatch_motion(id : String) : Bool
      case id
      when "editor.top", "editor.bottom"
        @read.to_edge(@area, id == "editor.top" ? -1 : 1)
        @status = id == "editor.top" ? "top of the pane" : "bottom of the pane"
      when "editor.word-next", "editor.word-prev"
        @read.word_move(@area, id == "editor.word-next" ? 1 : -1)
      when "editor.append-line-end", "editor.insert-line-start"
        @read.line_edge(@area, id == "editor.append-line-end" ? 1 : -1)
        editor_enter_insert
        @status = "INS at the line's #{id == "editor.append-line-end" ? "end" : "start"} · esc goes back to READ"
      else
        return false
      end
      true
    end

    # The Notes tab verbs the pad borrows. False for any other id.
    private def dispatch_tab(id : String) : Bool
      case id
      when "notes.select-line"
        @read.select_line(@area, @keyset.vim?)
        @status = expand(@keyset.vim? ? "line selected · {editor.delete-line} deletes it · {editor.yank-line} copies it" : "line selected · {editor.delete} deletes it · {notes.copy} copies it")
      when "notes.clear-selection"
        @read.clear_selection
        @status = "selection cleared"
      when "notes.copy" then copy
      else
        return false
      end
      true
    end

    # The id a press of `chord` fires: the editor first, then the tab the pad stands in for.
    # Availability is the pad's own (READ vs INS), since there is no ExecContext to ask.
    private def resolve(chord : Verb::Chord) : String?
      km = keymap
      {Verb::Scope::Editor, TAB_SCOPE}.each do |scope|
        next unless id = km.lookup_in(chord, scope)
        return id if live?(id)
      end
      nil
    end

    # The READ/INS half of each verb's `available:` gate. In INS only the modified chords
    # reach here (`insert_key`): `^Y` Copy, and the two prompts a real pane opens from INS as
    # well (`^F`, `^G`), which the pad names rather than opens, as it does in READ.
    private def live?(id : String) : Bool
      return true unless @insert
      INSERT_LIVE.includes?(id)
    end

    INSERT_LIVE = {"notes.copy", "editor.find", "editor.goto-line"}

    private def keymap : Verb::Keymap
      @keymaps[@keyset] ||= Verb::Keymap.build(@registry, Verb::OsProfile.resolve(@profile), @overrides, @keyset)
    end

    # The second key of vim's `dd` / `yy` — `Runner#finish_editor_op`, over the pad.
    private def finish_op(id : String, ev : Termisu::Event::Key) : Nil
      chord = Keybind.from_event(ev)
      if chord && resolve(chord) == id
        if id == "editor.delete-line"
          say(ReadEdit.delete_line(self, key_in))
        else
          yank_line
        end
      elsif ev.key.escape?
        @status = "cancelled"
      else
        @status = expand("{#{id}} cancelled — only {#{id}}{#{id}} (the whole line) is supported")
      end
    end

    private def arm(id : String, does : String) : Nil
      @armed = id
      @status = expand("{#{id}}… — {#{id}} again #{does} · esc cancels")
    end

    # The selection (or the INS selection), else the whole pad, into the register only.
    private def copy : Nil
      text, linewise = if @insert
                         {@area.selection_text || @area.text, false}
                       elsif ReadEdit.selection?(self)
                         {@read.copy_text(@area), ReadEdit.line_selection?(self)}
                       else
                         {@read.copy_all(@area), false}
                       end
      Register.store(text, linewise: linewise)
      @status = expand("copied #{Gori.plural(text.size, "char")} · {editor.paste} pastes (your clipboard is untouched)")
    end

    # vim `yy`: `ReadEdit.yank_line` minus its clipboard write (see the class comment).
    private def yank_line : Nil
      lines = @area.lines_snapshot
      @read.sync_from(@area)
      text = lines[@area.cy]? || ""
      Register.store(text, linewise: true)
      @status = expand("yanked 1 line · {editor.paste} puts it below (your clipboard is untouched)")
    end

    # The INSERT ladder is the pad's key path, the way a pane's `handle_key` is the Runner's.
    private def key_in : ReadEdit::KeyIn
      ->(ev : Termisu::Event::Key) { insert_key(ev); nil }
    end

    # Nil is the engine saying the pane already reported; the pad never does, so keep the line.
    private def say(message : String?) : Nil
      @status = expand(message) if message
    end

    private def intro : String
      expand(INTRO[@keyset])
    end

    # `overrides` is the pad's own snapshot, taken once at construction, so it is handed in.
    private def expand(template : String, kind : Verb::Keyset::Kind = @keyset) : String
      Hotkeys.expand(@registry, template, @overrides, @profile, Verb::Keyset.name_of(kind))
    end
  end
end
