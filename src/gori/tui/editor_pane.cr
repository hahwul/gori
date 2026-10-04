require "./text_area"
require "./text_read_state"

module Gori::Tui
  # What `ReadEdit` needs from the pane it edits, and nothing more: the buffer with its READ
  # state, the pane's own way in and out of INSERT, and its paste path.
  #
  # `TabController` is the one production implementation. The keyset playground's practice
  # pad (`KeysetPad`) is the other, and it is the reason this is a module rather than the
  # controller type: the pad stands behind no tab, so it has no `Host` to build a controller
  # on, and it has to run the same delete and paste engine the real panes do rather than a
  # lookalike that drifts from them.
  module EditorPane
    # The keys that leave READ for INSERT, as `{verb.id}` tokens for `Hotkeys.expand`: what a
    # hint names when the focused pane is a text editor in READ, where a bare letter is a
    # command (or a Global breath key) rather than a typed character.
    INSERT_KEYS = "{editor.insert}/{editor.insert-enter}"

    abstract def editor_text_buffer : {TextArea, TextReadState}?
    abstract def editor_read_mode? : Bool
    abstract def editor_enter_insert : Bool
    abstract def editor_exit_insert : Bool
    abstract def accepts_bulk_paste? : Bool
    abstract def paste_text(text : String) : Bool
  end
end
