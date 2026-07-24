require "termisu"
require "./screen"
require "./geometry"

module Gori::Tui
  # A centered modal overlay the shell floats above the tab body. The Runner owns ONE
  # active overlay (`@active_overlay`) and dispatches to it polymorphically — the same
  # move TabController made for tab bodies, now extended to modals.
  #
  # Before this seam, every modal scattered ~13 `case @overlay` entries through the
  # Runner (key / click / wheel / preedit / render / title / hint routing + open/close/
  # commit glue). That central fan-out was the merge-conflict surface: touching any one
  # modal meant editing a dozen shared methods 5,000 lines apart. An `Overlay` collapses
  # all of that into the hooks below, so ADDING or editing a modal touches only its own
  # file plus one open-site — never the Runner's central dispatch. Two overlays never
  # share an edit surface in runner.cr. That is the parallel-work win.
  #
  # Concrete overlays stay dumb form objects (their own field/caret state). Behaviour
  # that couples to a domain controller is injected as the `on_commit` closure at the
  # open-site — mirroring ConfirmDialog's action proc. A modal opened from two sites with
  # different apply semantics (e.g. Sequencer new-vs-reconfigure) therefore needs no
  # shell-side flag: each site supplies its own closure.
  #
  # Outcome vocabulary (returned by handle_key / handle_click), the contract the Runner's
  # generic dispatch switches on:
  #   :stay   → stay open, redraw
  #   :commit → run `commit`; the shell closes the overlay iff `commit` returns true
  #   :cancel → close without committing
  abstract class Overlay
    # Runs on a :commit outcome; returns true when the overlay should close (false keeps
    # it open — e.g. a validation error keeps the form up). Supplied at the open-site.
    property on_commit : Proc(Bool)?

    # The `@overlay` state symbol this modal sets. Kept in sync by the Runner so
    # `modal_overlay?` and any residual `@overlay ==` checks keep working while the other
    # overlays migrate onto this base one at a time.
    abstract def key : Symbol

    # Shell chrome: the focus-badge title (top bar) and the bottom-row key hint. These
    # used to be `case @overlay` entries in the Runner; they now live with the overlay so
    # the ladders don't grow per modal.
    abstract def title : String
    abstract def hint : String

    # Draw the modal card within `area` (the body rect).
    abstract def render(screen : Screen, area : Rect) : Nil

    # Handle one key. Return an outcome from the vocabulary above.
    abstract def handle_key(ev : Termisu::Event::Key) : Symbol

    # Handle a left-click at (mx, my) within `area`. Same outcome vocabulary. The default
    # implements the shared "click-away (outside the modal box) cancels, anything inside
    # stays" behaviour; overlays with clickable rows override to also commit on a hit.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      (box.nil? || !box.contains?(mx, my)) ? :cancel : :stay
    end

    # The modal's box within `area` — the click-away hit-test. `nil` means the card has
    # no room to draw; the default handle_click then treats any click as a dismiss (the
    # prior shell behaviour: `close if box.nil? || click-outside`). Overlays that center a
    # card override this (most already do, for render).
    def overlay_box(area : Rect) : Rect?
      nil
    end

    # Move the selected field by a signed step (↑/↓ and the scroll wheel share this).
    # Default no-op; form overlays override it. Button-only modals leave it inert.
    def move(step : Int32) : Nil
    end

    # A scroll-wheel notch over the modal (already ±3-scaled). Defaults to a field move, so
    # form overlays get wheel scrolling for free by overriding `move`.
    def handle_wheel(step : Int32) : Nil
      move(step)
    end

    # Live IME composition text for the focused field. Default: no-op.
    def set_preedit(text : String) : Nil
    end

    # Run the injected commit closure. Returns true when the shell should close the
    # overlay (default true when no closure was supplied).
    def commit : Bool
      (c = on_commit) ? c.call : true
    end
  end
end
