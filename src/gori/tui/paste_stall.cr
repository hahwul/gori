module Gori
  module Tui
    # Decides when a bracketed paste that never ended has to be ended anyway.
    #
    # A paste is bounded by its END marker, and `Runner` keys every paste decision off the two
    # `PasteNewline#pasting?` transitions — so a marker that never arrives leaves the loop
    # mid-paste forever, and mid-paste both branches eat the keyboard: the bulk buffer swallows
    # each keystroke into an insert that is never flushed, and a refused paste discards them.
    # The frame keeps repainting, so it reads as a hung app rather than a broken one.
    #
    # Terminals really do fail to send `\e[201~` — killed mid-transfer, a dropped ssh session,
    # DEC 2004 switched off underneath — so the state has to be bounded whatever the cause.
    #
    # THE SIGNAL IS DENSITY, NOT IDLENESS, and that is the whole reason this exists as its own
    # object. Keystrokes are precisely what a wedged paste is swallowing, and an operator whose
    # TUI just froze mashes Escape and q — so a clock re-armed by any event gets pushed out by
    # the very presses meant to rescue it (measured: 14 Escapes over 11s stayed wedged). A paste
    # arrives as a BURST, ~31 events queued behind a tick's first (the input channel's buffer),
    # while typing is one event per tick because the drain's non-blocking poll finds nothing
    # behind a single keypress.
    #
    # It lives apart from `Runner` (which needs a tty and so cannot be driven from a spec) for
    # exactly the reason `PasteNewline` does. That split is not decoration: the first version of
    # this logic re-armed the clock only on a burst and never on `opened`, so a paste made the
    # ordinary way — idle, switch to the browser, copy, come back, paste — was ABORTED on its
    # own opening tick, 44ms in, because the clock still held a keypress from seconds earlier.
    # Every e2e check passed anyway; they happened to paste ~1.2s after a keystroke, just inside
    # the window. A spec on this object is what catches that, and there is one.
    class PasteStall
      # How long input must stay quiet, while a paste is open, before the marker is deemed lost.
      #
      # Comfortably longer than termisu's own PASTE_END_TIMEOUT_MS (1s) so the parser's recovery
      # wins whenever it works and this stays the backstop it is meant to be.
      DEFAULT_STALL = 1500.milliseconds

      # How many key events one tick must carry to count as a paste still STREAMING.
      #
      # 8 leaves a wide margin over human input: the fastest key repeat these terminals emit
      # (~30/s) is 1-2 per 50ms tick, and mashing is slower. In the other direction a paste would
      # have to trickle under roughly 160 bytes/s for a whole stall window — slower than any link
      # that can carry a terminal session, and a 370 KB paste measured nowhere near it.
      DEFAULT_BURST = 8

      def initialize(@stall : Time::Span = DEFAULT_STALL, @burst : Int32 = DEFAULT_BURST)
        # nil means "no paste is open"; `stalled?` can then never fire.
        @activity = nil.as(Time::Instant?)
      end

      # A paste began. THE CLOCK STARTS NOW — never from the last keypress, which may be minutes
      # old, and which is what aborted pastes on their opening tick.
      def opened(now : Time::Instant) : Nil
        @activity = now
      end

      # The paste ended, by its marker or by this guard. Until the next `opened`, ticks are moot.
      def closed : Nil
        @activity = nil
      end

      # One tick of input arrived carrying `keys` key events behind the tick's first. Only a
      # burst re-arms: see the class comment for why a keystroke must not.
      #
      # KEY events only. Counting mouse reports here would hand the wedge straight back — gori
      # enables xterm mode 1002, so a press-and-drag reports pointer motion continuously and
      # clears the burst threshold on its own, and dragging is exactly what an operator with a
      # dead keyboard does next.
      def saw(now : Time::Instant, keys : Int32) : Nil
        return unless @activity
        @activity = now if keys >= @burst
      end

      # Whether the paste open right now has gone quiet long enough to be declared over.
      def stalled?(now : Time::Instant) : Bool
        return false unless started = @activity
        now - started >= @stall
      end

      # Whether a paste is currently being timed — for a caller that wants to assert its own
      # state agrees with this one.
      def open? : Bool
        !@activity.nil?
      end
    end
  end
end
