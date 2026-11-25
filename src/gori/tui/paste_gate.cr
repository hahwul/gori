require "termisu"
require "./paste_newline"
require "./paste_stall"

module Gori::Tui
  # The paste contract for a screen that runs its OWN event loop rather than the Runner's: the
  # project picker, the setup wizard and the tour. Each is a `poll_event` loop of its own, so
  # none of the Runner's paste handling (`Runner#handle`, `runner/paste.cr`) ever reached them.
  #
  # The rule is the Runner's: a clipboard is text, never a command. Pasted keystrokes reach a
  # screen one at a time, and the screen says which it takes (the block given to `filter`, the
  # shape of `Overlay#takes_pasted?`): text where a text field has the keys, nothing where a
  # bare key acts. Without it the picker ran a paste as commands. A copied ` deploy key` on a
  # project row opened the action menu on the space, picked Delete on the `d` and answered the
  # confirm with the `y`, and `rm_rf` took the project directory.
  #
  # The first key held back latches the rest of the paste, as `Runner#refuse_modal_paste` does:
  # letting the keys after it through glued the next line onto the first. A click mid-paste is
  # swallowed too (`Runner#handle`): it would move the target out from under the paste, and a
  # clipboard carrying an SGR mouse report reads as one.
  #
  # Kept apart from the screens, which hold a live Termisu, so the state machine can be driven
  # from a spec on its own, the same split `PasteNewline` and `PasteStall` make.
  class PasteGate
    enum Verdict
      # Not part of a paste, or a pasted key the screen takes: dispatch it as usual.
      Deliver
      # Swallowed without a word: a paste marker, the LF half of a pasted CRLF, a click
      # mid-paste, or a key after the paste was already refused.
      Absorb
      # The first key this paste held back. Dropped as well, and the screen names it (`note`).
      Refuse
    end

    # The Runner's two sentences (`Runner::PASTE_MODAL_REFUSED` / `PASTE_MODAL_IGNORED`) for the
    # same two cases, with "card" widened to the screen.
    LINE_BREAK = "paste stopped at the line break — ↵ here means commit; press it yourself"
    IGNORED    = "paste ignored — this screen answers keys you press, not a clipboard"

    # The most events one `drain` hands over before the loop renders again.
    DRAIN_CAP = 256

    # Why the last `Verdict::Refuse` refused.
    getter note : String = IGNORED

    def initialize(stall : Time::Span = PasteStall::DEFAULT_STALL)
      @newline = PasteNewline.new
      @stall = PasteStall.new(stall)
      @dropped = false
      @delivered = false
    end

    # True between a paste's start marker and its end (or the stall guard).
    def pasting? : Bool
      @newline.pasting?
    end

    # True while a paste that was already refused is still arriving. Nothing it carries can
    # change the screen, so a loop may skip its frames until it ends, as the Runner skips
    # rendering ticks a paste absorbed.
    def refusing? : Bool
      pasting? && @dropped
    end

    # Whether `text` is one of the two refusals, so a screen can retire the note on its own.
    def self.note?(text : String?) : Bool
      text == LINE_BREAK || text == IGNORED
    end

    # Classifies one polled event. `takes` answers for a pasted key: true when the screen in
    # its current mode takes it as text. Asked again per key, because a paste can move a screen
    # from one mode to another.
    def filter(ev : Termisu::Event::Any, now : Time::Instant = Time.instant, & : Termisu::Event::Key -> Bool) : Verdict
      return Verdict::Absorb if track(ev, now)
      return Verdict::Deliver unless pasting?
      return Verdict::Absorb if ev.is_a?(Termisu::Event::Mouse)
      key_ev = ev.as?(Termisu::Event::Key)
      return Verdict::Deliver unless key_ev # a resize or an IME preedit is not pasted content
      return Verdict::Absorb if @dropped
      if yield key_ev
        @delivered = true
        return Verdict::Deliver
      end
      @dropped = true
      k = key_ev.key
      @note = @delivered && (k.enter? || k.tab? || k.back_tab?) ? LINE_BREAK : IGNORED
      Verdict::Refuse
    end

    # Feeds `ev` to the newline filter and follows the paste's two transitions. True when the
    # filter swallowed it (a marker, or the LF half of a pasted CRLF).
    private def track(ev : Termisu::Event::Any, now : Time::Instant) : Bool
      # A start marker while a paste is open means the previous one lost its end marker (see
      # `paste_end_marker_patch.cr`). Close it, so the new paste starts with nothing refused.
      close if pasting? && ev.is_a?(Termisu::Event::Key) && ev.key.paste_start?
      was = pasting?
      swallowed = @newline.swallow?(ev)
      if !was && pasting?
        # The stall clock starts at the marker, never at the last keypress (see PasteStall).
        @stall.opened(now)
        @dropped = false
        @delivered = false
      elsif was && !pasting?
        close
      end
      swallowed
    end

    # Hands the loop the events already queued behind the one it just polled, while a paste
    # is open. The block returns true to stop. Two reasons: a paste is handled as the burst it
    # arrived in and rendered once, and the stall guard needs that density. These loops handle
    # one event per frame, so without a drain a paste that is still streaming looks like a
    # person typing (see `PasteStall#saw`). Stops at the paste's end, so the keys typed after
    # it go back to one event per frame.
    def drain(term : Termisu, & : Termisu::Event::Any -> Bool) : Nil
      return unless pasting?
      keys = 0
      events = 0
      while pasting? && events < DRAIN_CAP && (more = term.poll_event(0))
        events += 1
        keys += 1 if more.is_a?(Termisu::Event::Key)
        break if yield more
      end
      @stall.saw(Time.instant, keys)
    end

    # Ends a paste whose end marker is not coming, so a lost marker cannot leave every later key
    # refused (`PasteStall` decides when). True when it did: the caller then calls
    # `Termisu#leave_paste!` to reset the parser as well, as `Runner#end_stalled_paste` does.
    def end_if_stalled(now : Time::Instant = Time.instant) : Bool
      return false unless pasting? && @stall.stalled?(now)
      close
      true
    end

    private def close : Nil
      @newline.end_paste
      @stall.closed
      @dropped = false
      @delivered = false
    end
  end
end
