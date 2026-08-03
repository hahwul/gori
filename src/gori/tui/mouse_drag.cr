module Gori::Tui
  # xterm mode 1002 — BUTTON-EVENT tracking, the one that reports pointer MOTION while a
  # button is held. Without it a terminal sends press and release only, so a drag is
  # invisible: gori saw the two ends of a selection and nothing in between, which is why
  # click-and-drag never selected anything.
  #
  # It lives here rather than in termisu because termisu's `enable_mouse` writes 1000 (normal
  # tracking) + 1006 (SGR coordinates) and nothing else, and this repo vendors that shard —
  # a patch there is undone by the next `shards install`. Writing the one extra mode
  # ourselves, at the same tty termisu draws to, is the same shape `Clipboard` already uses
  # for OSC 52.
  #
  # ORDER MATTERS on the way in: 1002 must be set AFTER 1000, because a terminal that
  # implements both treats the later request as the active tracking level. On the way out
  # both are cleared, and 1002 is cleared FIRST for the same reason — leaving it set while
  # 1000 goes away would keep motion reports coming into a terminal gori is done with (and,
  # on exit, into the user's shell).
  module MouseDrag
    ENABLE  = "\e[?1002h"
    DISABLE = "\e[?1002l"

    # Whether motion reporting is currently on, so both calls below are idempotent — the
    # Runner reconciles this from a setting on every settings save.
    @@on = false

    def self.enable(io : IO = STDOUT) : Nil
      return if @@on
      io.print(ENABLE)
      io.flush
      @@on = true
    end

    def self.disable(io : IO = STDOUT) : Nil
      return unless @@on
      io.print(DISABLE)
      io.flush
      @@on = false
    end

    # Force the next enable/disable to write, whatever we last recorded. For the resume side
    # of a suspend (^Z out and back): the terminal was reset underneath us, so our idea of
    # what it is doing is stale and the sequence has to go out again.
    def self.forget : Nil
      @@on = false
    end
  end
end
