module Gori::Tui
  # The paste register: what the READ-mode `p` puts back (`ReadEdit.paste`).
  #
  # gori's own copy, not a read of the system clipboard. OSC 52 is how a copy reaches the
  # clipboard (see `Clipboard`), and the read half of OSC 52 is refused or prompted for by
  # most terminals, so a `p` that asked the terminal would work in some of them and hang or
  # paste nothing in the rest. Shelling out to `pbpaste`/`wl-paste` would work only on a local
  # desktop, never over SSH, which is where gori is meant to run as well. Text from outside
  # gori still arrives the way it always has: a terminal paste, which opens INSERT (#1124).
  #
  # Two writers. Every gori copy (`Clipboard.copy`), so `y` then `p` moves what the operator
  # just copied, wherever it was copied from. And the READ-mode deletes (`xd`, `dd`), which
  # fill the register without touching the clipboard: a delete is not a copy, and putting
  # every deleted line on the system clipboard would overwrite whatever the operator had
  # copied in another program.
  #
  # LINEWISE is the one bit of shape the text cannot carry. A whole-line copy or delete pastes
  # as its own line below the caret; anything else pastes inside the line, after the caret.
  # It is a property of HOW the text was taken (a line selection, `yy`, `dd`), so the writer
  # states it.
  #
  # One register, no names and no history: the minimum that makes `p` mean "put back the last
  # thing I took". Process-wide and in memory only, so it is gone when gori exits.
  module Register
    @@text : String? = nil
    @@linewise = false

    def self.store(text : String, linewise : Bool = false) : Nil
      @@text = text
      @@linewise = linewise
    end

    # Re-flag what is already held, for a caller that copies through `Clipboard.copy` (which
    # stores charwise) and only then knows the copy was whole lines.
    def self.linewise! : Nil
      @@linewise = true unless @@text.nil?
    end

    def self.text : String?
      @@text
    end

    def self.linewise? : Bool
      @@linewise
    end

    def self.empty? : Bool
      @@text.nil? || @@text.try(&.empty?) || false
    end

    def self.clear : Nil
      @@text = nil
      @@linewise = false
    end
  end
end
