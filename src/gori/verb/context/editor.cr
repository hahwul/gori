# The EDITOR pane, tab-blind — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr
# for the full facade and the class-reopening convention this mirrors store/compact.cr).
#
# Every other context/*.cr file is named for a TAB. This one is named for a PANE SHAPE: the
# nine controllers that hold a text editor (Repeater request/target, Notes, the Decoder /
# JWT / Cookie inputs, the Fuzzer template/target, the Issues notes, the Project
# description, the Rewriter input) each answered `i` / `↵` / `^Z` with a hand-rolled arm in
# `handle_body_key`, because the keymap had no way to say "here, in THIS pane" —
# KEY_AUDIT §1.4 and §2e. The intents below are the tab-blind half of the fix: the shell
# routes each one to whichever editor currently holds focus, exactly the way
# `read_select_line` / `read_copy` already route the READ-mode half.
abstract class Gori::Verb::ExecContext
  # Is the focused body pane a text editor at all (READ **or** INS)? The gate every
  # Scope::Editor verb hangs off, and the condition that puts Editor at the head of the
  # Runner's scope chain. Deliberately WIDER than `editor_focused?`, which answers the
  # narrower "are the keys under your fingers landing as text" (INS only) for the copy verbs.
  abstract def editor_pane? : Bool
  # …and the READ half of it: an editor pane that is NOT currently taking text. The bare
  # letters (`i`, and whatever a keyset spells `a` / `g` / `u` / `/`) only mean anything here;
  # in INS they are literal characters the editor ladder claims upstream of the keymap.
  abstract def editor_read_mode? : Bool

  abstract def editor_enter_insert : Nil  # READ → INS at the caret
  abstract def editor_append_insert : Nil # READ → INS one column right (the `a` of a vim keyset)
  abstract def editor_exit_insert : Nil   # INS → READ
  abstract def editor_undo : Nil          # undo the last edit in the focused editor
  abstract def editor_to_top : Nil        # caret to the first line
  abstract def editor_to_bottom : Nil     # caret to the last line
  # The two bottom prompts the shell owns (^G / ^F). Registered as verbs so a keyset can give
  # them a second, bare spelling — the hardcoded guards keep answering the Ctrl form either way.
  abstract def editor_goto_line : Nil
  abstract def editor_find : Nil
end
