require "termisu"
require "./screen"

module Gori::Tui
  # The terminal the four TUI surfaces (Runner, ProjectPicker, SetupWizard, Tutorial) hold.
  #
  # Every one of them used to take a `Termisu` directly, which meant "a TUI surface" and "a live
  # /dev/tty" were the same thing: `Termisu.new` opens the tty itself and raises without one, so
  # there was no way to draw a frame in a spec, in CI, or for a screenshot without a terminal to
  # draw it on. This is the seam that separates the two. A surface asks the port for its cell
  # sink and for input, and everything else it does to a terminal is terminal STATE — a title, a
  # cursor position, mouse reporting, the paste latch — for which "do nothing" is the correct
  # answer when there is no terminal, which is why those are concrete no-op defaults here rather
  # than abstract methods every offscreen port would have to stub.
  #
  # Two implementations: `TermisuTerminal` (thin delegation onto a live `Termisu`) and
  # `OffscreenTerminal` (fixed dimensions, no input, cells kept in the backend's own grid).
  abstract class TerminalPort
    # The dims the surface lays out against.
    abstract def size : {Int32, Int32}

    # `nil` on timeout — and, for a port with no input at all, always. That matters to
    # `Runner#drain_burst`, which loops on `poll_event(0)` until it returns nil.
    abstract def poll_event(timeout_ms : Int32) : Termisu::Event::Any?

    # THE monomorphization seam, and the reason this is a method on the port rather than the
    # caller doing `TermisuBackend.new(port)`.
    #
    # `TermisuBackend(T)` is generic over the terminal type precisely so its per-cell `set_cell`
    # forward is a static call — screen.cr's header measures why (~1.8 MB and ~2.3 ms of
    # allocation for one 200×50 frame when that path is not free). Building the backend from a
    # variable typed as this abstract class would instantiate `TermisuBackend(TerminalPort)` and
    # put a vtable lookup on the hottest line in the renderer. The port therefore builds its OWN
    # backend, over `self` or over the concrete terminal it wraps, so `T` stays concrete and the
    # caller only ever sees the base `Backend`.
    abstract def make_backend : Backend

    # ── Terminal state ────────────────────────────────────────────────────────────────────
    # Each of these asks the terminal to remember something about how it presents itself. A
    # port with no terminal has nowhere to put that and nobody to show it to, so the no-op is
    # the answer rather than an omission.

    def title=(t : String) : Nil
    end

    def set_cursor(x : Int32, y : Int32, *, visible : Bool = true) : Nil
    end

    def hide_cursor : Nil
    end

    def enable_mouse : Nil
    end

    def disable_mouse : Nil
    end

    def enable_enhanced_keyboard : Nil
    end

    def enable_bracketed_paste : Nil
    end

    # Abandon the input parser's paste latch from outside — see `paste_end_marker_patch.cr`
    # for the stall it exists to break. There is no parser behind an offscreen port, so there
    # is no latch to release either.
    def leave_paste! : Nil
    end

    # Hand the tty to a child process (the external editor) and take it back afterwards.
    # Offscreen there is no tty to hand over, so the block simply runs.
    def suspend(&)
      yield
    end

    def close : Nil
    end
  end

  # The production port: a live terminal, every call forwarded.
  class TermisuTerminal < TerminalPort
    def initialize(@term : Termisu)
    end

    def size : {Int32, Int32}
      @term.size
    end

    def poll_event(timeout_ms : Int32) : Termisu::Event::Any?
      @term.poll_event(timeout_ms)
    end

    # `@term`, not `self`: `T` is `Termisu` here exactly as it was before the port existed, so
    # the renderer's per-cell forward stays the same static call. Wrapping the port instead
    # would add a delegation hop per cell for nothing.
    def make_backend : Backend
      TermisuBackend.new(@term).as(Backend)
    end

    def title=(t : String) : Nil
      @term.title = t
    end

    def set_cursor(x : Int32, y : Int32, *, visible : Bool = true) : Nil
      @term.set_cursor(x, y, visible: visible)
    end

    def hide_cursor : Nil
      @term.hide_cursor
    end

    def enable_mouse : Nil
      @term.enable_mouse
    end

    def disable_mouse : Nil
      @term.disable_mouse
    end

    def enable_enhanced_keyboard : Nil
      @term.enable_enhanced_keyboard
    end

    def enable_bracketed_paste : Nil
      @term.enable_bracketed_paste
    end

    def leave_paste! : Nil
      @term.leave_paste!
    end

    def suspend(&)
      @term.suspend { yield }
    end

    def close : Nil
      @term.close
    end
  end

  # A terminal that is only a size. Nothing is written to a device and nothing is ever read
  # from one: the frame lives entirely in the backend's cell grid, where `Backend#snapshot`
  # can pick it up. This is what lets a Runner boot, draw and be photographed with no tty.
  #
  # The default 132×38 is a comfortable reading width for a captured frame rather than
  # anything the code depends on — every caller passes its own dims.
  class OffscreenTerminal < TerminalPort
    def initialize(@cols : Int32 = 132, @rows : Int32 = 38)
    end

    def size : {Int32, Int32}
      {@cols, @rows}
    end

    # No input source at all. `Runner#run`'s poll and `drain_burst`'s inner loop both read this
    # as "nothing happened", which is what drives a headless render to a single frame instead
    # of a loop; scripted keys are fed straight to `Runner#feed`.
    def poll_event(timeout_ms : Int32) : Termisu::Event::Any?
      nil
    end

    # `self`, so `T` is `OffscreenTerminal` and the per-cell forward below is still a static
    # call into a method the optimiser can see through.
    def make_backend : Backend
      TermisuBackend.new(self).as(Backend)
    end

    # ── The duck-typed half `TermisuBackend(T)` drives ────────────────────────────────────

    # Always accepted. `TermisuBackend` has already applied termisu's own acceptance rules in
    # `accepted_width` before it forwards a cell, so every write that reaches here is one a
    # real terminal would have taken — and answering `false` would make the backend hold its
    # `@front` back from a cell it did put in `@back`, desyncing the two grids permanently.
    def set_cell(x : Int32, y : Int32, grapheme : String, *, fg : Color, bg : Color, attr : Attribute) : Bool
      true
    end

    # Presenting a frame is exactly the part there is no device for.
    def render
    end

    def sync
    end
  end
end
