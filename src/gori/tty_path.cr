module Gori
  # "Does this operator-supplied PATH name a terminal?" — asked before a file is read whole as
  # a document or streamed as a wordlist.
  #
  # A terminal is not a file with bytes waiting in it (#1034). The line discipline ECHOES
  # everything typed back into the scrollback, and into any captured PTY transcript; `^D`
  # FLUSHES the pending line instead of ending the read, so a source whose last line has no
  # newline needs two of them and a driver that sends one waits forever; and `MAX_CANON`
  # truncates a long line before the reader is handed an octet. `--wordlist /dev/tty`,
  # `-w /dev/stdin` under a tty and `--request-file /dev/fd/0` all land there, and each one
  # hung outright.
  #
  # The `character_device?` pre-check is what makes this safe to ask of ANY path, which is the
  # whole point of a shared predicate: a terminal is ALWAYS a character device, a FIFO is
  # `pipe?` and a wordlist is `file?`, so the probe `open` below never runs on the named pipe
  # whose open would BLOCK until a writer arrives — the one source a readability check must
  # neither consume nor wait on (`Fuzz::Payload::WordlistFile` exists to serve it). A
  # `/dev/stdin` reports the type of whatever fd 0 IS — a pipe under `generator | gori …`, the
  # terminal under a bare shell — which is exactly the distinction being drawn.
  #
  # False for anything that cannot be stat'd or opened: this answers "is it a terminal", not
  # "is it readable". Each caller keeps its own readability check, and its own wording for it.
  module TtyPath
    def self.terminal?(path : String) : Bool
      return false unless File.info(path).type.character_device?
      File.open(path, &.tty?)
    rescue
      false
    end
  end
end
