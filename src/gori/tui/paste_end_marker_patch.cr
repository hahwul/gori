require "termisu"

# Makes bracketed paste WORK on the termisu `shard.lock` pins today — the end marker arrives,
# and paste mode ends even when it doesn't.
#
# CARRIED PATCH — delete this file (and the `require` in `paste_newline.cr`) once shard.lock ships
# a termisu carrying these fixes. `lib/` is gitignored and shard.lock pins a commit, so there is
# nothing in the dependency to edit; each method below is verbatim from the pinned source apart
# from the change named in its own comment.
#
# TWO GUARDS, because one override of a shard's PRIVATE method can fail two different ways:
#
#   - It stops applying (upstream renames or restructures the method). The reopen would leave a
#     dead private method here and silently restore the freeze, so
#     `spec/tui/paste_end_marker_spec.cr` asserts the BEHAVIOUR — pastes driven through the real
#     parser — and fails when the behaviour is gone, whatever the cause.
#   - It keeps applying when it should not (upstream FIXES the same method under the same name).
#     No behavioural spec can see that: it passes either way, and gori would keep running this
#     frozen copy forever, diverging from the dependency it overrides. So the same spec file pins
#     the termisu commit in `shard.lock`; moving the lock fails it, which is precisely when
#     someone should be re-reading this file and deleting it.
#
# gori pins `github.com/hahwul/termisu`, so the fix at the right depth is a termisu release and a
# lock bump — this file only buys the time to do that deliberately.
#
# WHAT IS LEFT, after the #1125 lock bump. This file used to carry a third override,
# `read_paste_end_tail`, because the probe that matches `\e[201~` skipped the fd entirely
# whenever its poll budget was 0 — and 0 is what `Event::Source::Input#run_loop` drains with,
# so `Key::PasteEnd` was never emitted at all. termisu d2d0de7 (`fix: enforce input parser
# deadlines`) rewrote that method around `@reader.read_byte(paste_wait_ms)` and fixed it
# upstream, so the override is gone and the
# shard's own version runs. The remaining two are about what happens when the marker never
# arrives, which upstream still does not handle.
#
# THE GIVE-UP BRANCH, in `parse_paste_escape`: the pinned parser bounds the marker window, but
# when it expires it returns a bare `Escape` and leaves `@in_paste` SET. That is not a
# degradation, it is a session-long trap — every later ESC is probed as an end marker and
# mis-delivered. For gori that is a freeze, not a cosmetic defect: `Runner#handle` keys every
# paste decision off the two `PasteNewline#pasting?` transitions, so with no end transition the
# bulk buffer swallows every later keystroke into an insert that is never flushed.
# `Runner::PASTE_STALL` bounds that state whatever the cause, but a backstop is not a working
# paste. `leave_paste!` is the same escape hatch from outside, for a paste cut with no trailing
# ESC at all — nothing opens the probe then, so there is nothing to time out on.
class Termisu::Input::Parser
  # The bytes following ESC in the START marker, matched literally and for the same reason
  # `PASTE_END_TAIL` is: inside a paste an ESC is compared as raw bytes, never parsed as a
  # sequence. Upstream has no equivalent because upstream never looks for a start marker
  # mid-paste — see `parse_paste_escape` below for why gori must.
  PASTE_START_TAIL = "[200~".bytes

  # Abandon paste mode from OUTSIDE — the escape hatch `Runner`'s stall guard needs, and the
  # only latch it could not otherwise reach.
  #
  # Both give-up paths in `parse_paste_escape` require an ESC to have arrived, because that is
  # the only thing that opens the probe. A paste cut with no trailing ESC at all therefore leaves
  # `@in_paste` set with nothing to time out on, and while it is set every later ESC — an arrow
  # key, an SGR mouse report, Escape itself — is probed as a possible end marker for the full
  # window and then mis-delivered as a bare Escape trailed by its own bytes as text keys. gori's
  # watchdog can see that a paste stopped arriving; the parser cannot, so it is told.
  #
  # `@pending` is cleared with the flag: anything still in it is the unresolved remains of the
  # marker probe for a paste that is now over, and delivering those bytes as keystrokes is the
  # same forged-input problem the give-up branch avoids.
  def leave_paste! : Nil
    @in_paste = false
    @paste_deadline = nil
    @pending.clear
  end

  # SECOND HALF: leave paste mode when the marker is never coming, so ONE truncated paste
  # cannot poison every later one.
  #
  # The window above is bounded so a terminal that dies mid-paste degrades instead of hanging,
  # but the pinned give-up returns a bare `Escape` and leaves `@in_paste` SET — and that is not
  # a degradation, it is a session-long trap. Measured against the pinned parser (see
  # `spec/tui/paste_end_marker_spec.cr`): after `\e[200~a\e` is truncated, the NEXT paste's
  # `\e[200~` is taken by this probe and compared against the END marker, `[201~`. It misses,
  # so the start marker spills into the document as `[`, `2`, `0`, `0`, `~` and NO `PasteStart`
  # is emitted at all — which in gori means `Runner` never sees a paste: the bulk insert is
  # bypassed, and so is `paste_runs_as_commands?`, the guard that stops a paste at the tab bar
  # from running its own bytes as hotkeys. For every paste for the rest of the session.
  #
  # A short tail with the window closed means nothing more is coming, so close the bracket. The
  # ESC goes back on the queue to be re-read OUTSIDE the paste, where it is an ordinary Escape:
  # the byte is not dropped, it is only no longer claimed to belong to a paste that is over. A
  # FULL tail that merely is not the marker is left exactly as it was — that is pasted content
  # which looked like a marker, the terminal still owes us the close, and the paste stays open.
  private def parse_paste_escape : Event::Any?
    @paste_deadline ||= monotonic_now + PASTE_END_TIMEOUT_MS.milliseconds
    tail = read_paste_end_tail
    tail.reverse_each { |b| @pending.unshift(b) }

    if tail.size < PASTE_END_TAIL.size && ms_until(@paste_deadline) > 0
      @pending.unshift(0x1B_u8)
      return nil
    end

    @paste_deadline = nil

    if tail.size < PASTE_END_TAIL.size
      # The ESC and the partial tail are DISCARDED rather than re-queued. Pushing the ESC back
      # looks kinder — no byte lost — but `poll_event` would shift it into
      # `parse_escape_sequence`, which reads `@reader` and never consults `@pending`: on a link
      # that delivers `\e[20` and then `1~` a second later, that ESC pairs with the late `1` as
      # Alt-1 (a tab switch here) while `[`, `2`, `0` spill out behind it as text — and at the
      # tab bar those are commands. Upstream returns its `Escape` without re-queuing for exactly
      # this reason. What is dropped is at most four bytes at the tail of a transfer the terminal
      # abandoned; what is bought is that a dead paste cannot forge a keystroke.
      tail.size.times { @pending.shift }
      @in_paste = false
      return Event::Key.new(Key::PasteEnd)
    end

    # A START marker arriving INSIDE a paste. The branch above only catches a truncation that
    # left a dangling ESC to probe; a paste cut with no trailing ESC at all leaves nothing for
    # the parser to time out on, so `@in_paste` stays set with no way back. The next paste's
    # `\e[200~` then lands here and is compared against the END marker, misses, and falls
    # through to the bare `Escape` below — which is far worse than the spilled `[200~` text:
    # measured in the app, that Escape drops the request editor out of INSERT and the rest of
    # the clipboard runs as COMMANDS (`POST /after HTTP/1.1` navigating by its own digits).
    #
    # Inside a paste, `[200~` can only mean the previous one never closed and a new one is
    # beginning, so honour it. Trusting these five bytes is exactly as safe as trusting the
    # five the end marker is found by: content carrying either sequence verbatim is the known
    # limitation of DEC 2004, not something this can distinguish. `@in_paste` stays set, because
    # the new paste is open.
    #
    # Closing the ABANDONED paste is `Runner`'s, and it does it on this very event rather than by
    # timeout — a `PasteStart` while already pasting makes it call `close_paste` before the
    # filter sees the marker, so the new paste still gets its own start transition and its own
    # bulk-vs-refuse decision. It cannot be left to the stall guard: that fires on input going
    # QUIET, and a new paste streaming in is precisely what keeps it noisy.
    if tail == PASTE_START_TAIL
      PASTE_START_TAIL.size.times { @pending.shift }
      return Event::Key.new(Key::PasteStart)
    end

    return Event::Key.new(Key::Escape, char: '\e') unless tail == PASTE_END_TAIL

    PASTE_END_TAIL.size.times { @pending.shift }
    @in_paste = false
    Event::Key.new(Key::PasteEnd)
  end
end

class Termisu
  # Reaches the input parser's `leave_paste!` so an application can abandon paste mode the parser
  # has no way to time out of. `@input_parser` is Termisu's own ivar, so this is a forwarder
  # rather than a walk through the event loop.
  def leave_paste! : Nil
    @input_parser.leave_paste!
  end
end
