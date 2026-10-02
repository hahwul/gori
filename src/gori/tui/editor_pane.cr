require "./text_area"
require "./text_read_state"

module Gori::Tui
  # What `ReadEdit` needs from the pane it edits, and nothing more: the buffer with its READ
  # state, the pane's own way in and out of INSERT, and its paste path.
  #
  # `TabController` is the one production implementation. The setup wizard's practice pad
  # (`KeysetPad`) is the other, and it is the reason this is a module rather than the
  # controller type: the wizard runs before any Session exists, so it has no `Host` to build a
  # controller on, and its pad has to run the same delete and paste engine the real panes do
  # rather than a lookalike that drifts from them.
  module EditorPane
    abstract def editor_text_buffer : {TextArea, TextReadState}?
    abstract def editor_read_mode? : Bool
    abstract def editor_enter_insert : Bool
    abstract def editor_exit_insert : Bool
    abstract def accepts_bulk_paste? : Bool
    abstract def paste_text(text : String) : Bool
  end
end
