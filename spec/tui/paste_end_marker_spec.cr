require "../spec_helper"

# Guards the carried patch in `src/gori/tui/paste_end_marker_patch.cr` by asserting the
# BEHAVIOUR, not the patch: a bracketed paste driven through the real `Termisu::Input::Parser`
# the way `Event::Source::Input#run_loop` drives it must end with `Key::PasteEnd`.
#
# Why behaviour and not the method: the patch reopens a PRIVATE method of a shard class. If
# upstream renames or restructures it, the reopen would quietly become a dead method here and
# the freeze would come back with nothing failing. This spec fails instead. It also keeps
# passing once shard.lock ships a fixed termisu — at which point the patch is redundant and can
# be deleted without touching this file.
#
# The freeze it stands for: no `PasteEnd` means `PasteNewline#pasting?` never clears, so
# `Runner` swallows every subsequent keystroke into a bulk insert it will never flush — the
# text never appears and the keyboard is dead while the frame keeps repainting.

# Drives the parser over a pipe with the ZERO timeout the input source uses, optionally writing a
# SECOND chunk once the end-marker window has closed.
#
# One helper rather than two near-identical ones: the only difference between the single-paste and
# the truncated-then-later-paste cases is that deferred write, and two copies of the pipe setup,
# poll loop and teardown would drift the moment either is fixed.
#
# Polls until *count* events arrive rather than *count* times — a probe that is still open yields
# nil, exactly as it does in the real loop.
#
# `later` is written after `PASTE_END_WINDOW`, read off the parser's own constant rather than
# hard-coded: the deferred write only has to outlast that window, so naming the coupling keeps the
# spec honest and lets it shrink if upstream lowers it.
PASTE_END_WINDOW = Termisu::Input::Parser::PASTE_END_TIMEOUT_MS.milliseconds + 200.milliseconds

private def paste_keys(bytes : Bytes, count : Int32, later : Bytes? = nil) : Array(Termisu::Input::Key?)
  fds = uninitialized Int32[2]
  raise "pipe failed" if LibC.pipe(fds) != 0
  read_fd, write_fd = fds[0], fds[1]
  keys = [] of Termisu::Input::Key?
  reader = nil.as(Termisu::Reader?)
  begin
    write_all(write_fd, bytes)
    reader = Termisu::Reader.new(read_fd)
    parser = Termisu::Input::Parser.new(reader)
    started = Time.instant
    wrote_later = later.nil?
    deadline = started + PASTE_END_WINDOW + 5.seconds
    while keys.size < count && Time.instant < deadline
      if ev = parser.poll_event(0)
        keys << (ev.is_a?(Termisu::Event::Key) ? ev.key : nil)
      else
        if !wrote_later && Time.instant - started > PASTE_END_WINDOW
          write_all(write_fd, later.not_nil!)
          wrote_later = true
        end
        sleep 1.millisecond # mirrors run_loop's idle sleep
      end
    end
  ensure
    reader.try(&.close)
    LibC.close(read_fd)
    LibC.close(write_fd)
  end
  keys
end

# A short write would otherwise present as an opaque poll timeout rather than a named failure.
private def write_all(fd : Int32, bytes : Bytes) : Nil
  written = LibC.write(fd, bytes, bytes.size)
  raise "short write: #{written} of #{bytes.size}" unless written == bytes.size
end

# The trigger to DELETE the carried patch.
#
# The behavioural examples below cannot supply one: they pass whether the fix comes from the patch
# or from the shard, which is what makes them safe but also means an upstream fix would never be
# noticed. gori would keep running its own frozen copy of two private methods forever, silently
# diverging from the dependency it is overriding.
#
# So pin the lock. When termisu moves, this fails and someone re-reads the patch — which is exactly
# the moment to check whether it is still needed. Assert the LOCK rather than `Termisu::VERSION`,
# which would not change for a fix on the same version number.
describe "the termisu pin the carried paste patch is written against" do
  it "has not moved (if it has, re-check whether paste_end_marker_patch.cr is still needed)" do
    lock = File.read(File.join(__DIR__, "..", "..", "shard.lock"))
    pinned = lock[/termisu:.*?commit\.([0-9a-f]{40})/m, 1]?

    pinned.should eq("df6e907e6fe27f2cc70b9f855dff996d08398ad1")
  end
end

describe "bracketed paste end marker (termisu, as the input source drives it)" do
  it "delivers PasteEnd for a paste polled with a zero budget" do
    keys = paste_keys("\e[200~hi\e[201~".to_slice, 4)

    keys.should eq([
      Termisu::Input::Key::PasteStart,
      Termisu::Input::Key::LowerH,
      Termisu::Input::Key::LowerI,
      Termisu::Input::Key::PasteEnd,
    ])
  end

  # The paste an operator actually makes: a request with CRLF line breaks. Asserts the WHOLE
  # stream, because the failure's tell was not a missing event but five EXTRA ones — `[`, `2`,
  # `0`, `1`, `~` spilling in as text behind an Escape that should have been the marker, which
  # is what ended up inside the pasted request.
  it "closes a multi-line paste without leaking the marker as text" do
    keys = paste_keys("\e[200~a\r\nb\e[201~".to_slice, 6)

    keys.should eq([
      Termisu::Input::Key::PasteStart,
      Termisu::Input::Key::LowerA,
      Termisu::Input::Key::Enter, # CR
      Termisu::Input::Key::Enter, # LF — PasteNewline collapses the pair, not the parser
      Termisu::Input::Key::LowerB,
      Termisu::Input::Key::PasteEnd,
    ])
  end

  # ONE TRUNCATED PASTE MUST NOT POISON THE NEXT. A terminal killed mid-transfer leaves the
  # parser holding an ESC it can never resolve; when the window closes it must also leave paste
  # mode, or the next paste's `\e[200~` is compared against the END marker (`[201~`), missed,
  # and spilled into the document as text — no `PasteStart`, so gori sees no paste at all: the
  # bulk insert is bypassed AND so is `paste_runs_as_commands?`, which is what stops a paste at
  # the tab bar from running as hotkeys. Every paste for the rest of the session.
  #
  # The dangling ESC is DISCARDED, not delivered. Re-queuing it looks kinder but is worse: the
  # re-read would go through `parse_escape_sequence`, which reads the fd and not the push-back
  # queue, so it pairs with whatever arrives next — here the `\e` would have merged with the later
  # paste's `[200~`. A dead paste must not be able to forge a keystroke.
  it "recognises a later paste after one was truncated" do
    keys = paste_keys("\e[200~a\e".to_slice, 6, later: "\e[200~b\e[201~".to_slice)

    keys.should eq([
      Termisu::Input::Key::PasteStart,
      Termisu::Input::Key::LowerA,
      Termisu::Input::Key::PasteEnd, # the bracket closes even though the terminal never did
      Termisu::Input::Key::PasteStart,
      Termisu::Input::Key::LowerB,
      Termisu::Input::Key::PasteEnd,
    ])
  end

  # The same poisoning by the OTHER route, and the one that actually bit in the app: a paste cut
  # with no trailing ESC at all. There is then nothing for the parser to time out on — the probe
  # is only ever entered by an ESC — so paste mode has no way back, and the branch above cannot
  # help. The next paste's `\e[200~` is what lands in the probe.
  #
  # Getting this wrong is not a cosmetic spill. Measured in the app before this: the mismatched
  # marker returned a bare Escape, which dropped the request editor out of INSERT, and the rest
  # of the clipboard ran as COMMANDS — `POST /after HTTP/1.1` navigated tabs by its own digits.
  # A paste executing itself is the one outcome `paste_runs_as_commands?` exists to prevent, and
  # a paste with no `PasteStart` never reaches that guard.
  it "recognises a later paste after one was truncated with no trailing ESC" do
    keys = paste_keys("\e[200~a".to_slice, 5, later: "\e[200~b\e[201~".to_slice)

    keys.should eq([
      Termisu::Input::Key::PasteStart,
      Termisu::Input::Key::LowerA,
      Termisu::Input::Key::PasteStart, # the new paste, seen through the abandoned one
      Termisu::Input::Key::LowerB,
      Termisu::Input::Key::PasteEnd,
    ])
  end

  # Pasted content that merely LOOKS like the marker at first must still be delivered whole,
  # and the paste must still close. This is the path the patch leaves untouched (a full tail
  # that does not match is pushed back byte for byte), so it pins that the override did not
  # trade one behaviour for the other.
  it "delivers an escape sequence inside a paste as its literal bytes" do
    keys = paste_keys("\e[200~\e[A\e[201~".to_slice, 5)

    keys.should eq([
      Termisu::Input::Key::PasteStart,
      Termisu::Input::Key::Escape,
      Termisu::Input::Key::LeftBracket,
      Termisu::Input::Key::UpperA,
      Termisu::Input::Key::PasteEnd,
    ])
  end
end
