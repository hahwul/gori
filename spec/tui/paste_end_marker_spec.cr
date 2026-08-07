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

# Drives the parser over a pipe with the ZERO timeout the input source uses. Polls until
# *count* events arrive rather than *count* times: an end-marker probe that is still open
# yields nil, exactly as it does in the real loop. Bounded so a lost marker fails rather than
# hangs — generously, since the unpatched parser takes a full second to give up and would
# otherwise flake before it could be caught.
private def paste_events_nonblocking(bytes : Bytes, count : Int32) : Array(Termisu::Input::Key?)
  fds = uninitialized Int32[2]
  raise "pipe failed" if LibC.pipe(fds) != 0
  read_fd, write_fd = fds[0], fds[1]
  keys = [] of Termisu::Input::Key?
  reader = nil.as(Termisu::Reader?)
  begin
    LibC.write(write_fd, bytes, bytes.size)
    reader = Termisu::Reader.new(read_fd)
    parser = Termisu::Input::Parser.new(reader)
    deadline = Time.instant + 5.seconds
    while keys.size < count && Time.instant < deadline
      if ev = parser.poll_event(0)
        keys << (ev.is_a?(Termisu::Event::Key) ? ev.key : nil)
      else
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

# Keeps ONE parser across two writes, so a truncated paste can be followed by a later,
# complete paste through the same parser state. That is the only way to see the question this
# asks: paste state surviving a truncation is invisible until the NEXT paste is parsed by it.
# The second write is timed off the clock rather than off an event, so it lands after the
# end-marker window (PASTE_END_TIMEOUT_MS, 1000ms) has closed regardless of what the give-up
# emits — otherwise the assertion would be coupled to the behaviour under test.
private def paste_events_two_phase(first : String, second : String,
                                   count : Int32) : Array(Termisu::Input::Key?)
  fds = uninitialized Int32[2]
  raise "pipe failed" if LibC.pipe(fds) != 0
  read_fd, write_fd = fds[0], fds[1]
  keys = [] of Termisu::Input::Key?
  reader = nil.as(Termisu::Reader?)
  begin
    LibC.write(write_fd, first.to_slice, first.bytesize)
    reader = Termisu::Reader.new(read_fd)
    parser = Termisu::Input::Parser.new(reader)
    started = Time.instant
    wrote_second = false
    deadline = started + 8.seconds
    while keys.size < count && Time.instant < deadline
      if ev = parser.poll_event(0)
        keys << (ev.is_a?(Termisu::Event::Key) ? ev.key : nil)
      else
        if !wrote_second && Time.instant - started > 1500.milliseconds
          LibC.write(write_fd, second.to_slice, second.bytesize)
          wrote_second = true
        end
        sleep 1.millisecond
      end
    end
  ensure
    reader.try(&.close)
    LibC.close(read_fd)
    LibC.close(write_fd)
  end
  keys
end

describe "bracketed paste end marker (termisu, as the input source drives it)" do
  it "delivers PasteEnd for a paste polled with a zero budget" do
    keys = paste_events_nonblocking("\e[200~hi\e[201~".to_slice, 4)

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
    keys = paste_events_nonblocking("\e[200~a\r\nb\e[201~".to_slice, 6)

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
  it "recognises a later paste after one was truncated" do
    keys = paste_events_two_phase("\e[200~a\e", "\e[200~b\e[201~", 7)

    keys.should eq([
      Termisu::Input::Key::PasteStart,
      Termisu::Input::Key::LowerA,
      Termisu::Input::Key::PasteEnd, # the bracket closes even though the terminal never did
      Termisu::Input::Key::Escape,   # the dangling ESC, re-read outside the paste
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
    keys = paste_events_two_phase("\e[200~a", "\e[200~b\e[201~", 5)

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
    keys = paste_events_nonblocking("\e[200~\e[A\e[201~".to_slice, 5)

    keys.should eq([
      Termisu::Input::Key::PasteStart,
      Termisu::Input::Key::Escape,
      Termisu::Input::Key::LeftBracket,
      Termisu::Input::Key::UpperA,
      Termisu::Input::Key::PasteEnd,
    ])
  end
end
