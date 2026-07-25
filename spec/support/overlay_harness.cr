require "../spec_helper"
require "./memory_backend"

# Drives ONE `Gori::Tui::Overlay` through the exact lifecycle the shell gives it —
# open → keys / clicks / wheel / IME preedit → commit or cancel — with no terminal and
# no Runner.
#
# The Runner needs a live tty, so it cannot be unit-tested; every migrated modal's spec
# would otherwise re-derive the shell's generic dispatch by hand (and each slightly
# differently). This is that dispatch, written once:
#
#   * `press` / `click` mirror `Runner#dispatch_overlay_key` / `#dispatch_overlay_click`
#     LINE FOR LINE — :cancel closes, :commit runs `commit` and closes iff it returns
#     true, anything else stays open.
#   * `open?` mirrors whether the shell still holds the modal in `@active_overlay`.
#   * `commits` counts runs of the injected `on_commit` closure — the open-site behaviour
#     a migrated modal no longer carries itself.
#
# If those Runner methods ever change, change them HERE too: this harness is the
# spec-side statement of that contract, and a modal spec that passes against a stale
# harness proves nothing about the real shell.
#
# WHAT IT DOES NOT MODEL: the shell's pre-filter. `^C`/`^D` (quit-arm), `^B` (reveal) and
# the space-menu / copy-as / send-to / `^F` prompts are all claimed in `Runner#handle_key`
# BEFORE a migrated modal is dispatched to, so those keys never reach an overlay in the
# real app. Driving them through this harness will "work" here and be dead in the TUI —
# assert them against the Runner ladder instead.
#
# Note that `press`/`click` collapse `:cancel` and a truthy `:commit` to the same
# `:closed`, because that is what the shell does. An example that cares WHICH one it was
# must also assert `commits`, or call `overlay.handle_key` directly for the raw vocabulary.
class OverlayHarness
  # The body rect the shell hands an overlay. 80x24 is the size every existing overlay
  # spec centres its card in, so box geometry matches what those specs already assert.
  #
  # CAVEAT: this is the whole SCREEN, not `layout.body`. On a real 80x24 terminal the shell
  # passes Rect(2, 4, 76, 18) — 6 rows shorter and offset — so a card gets 22 usable rows
  # here where production gives 16. Every migrated overlay's `overlay_box` bails out with
  # `nil` below a floor (`w < 28 || h < 8`), and that nil path — where the base
  # `handle_click` turns EVERY click into a dismiss — is therefore unreachable through this
  # default. If your modal is tall, or you care about the small-terminal path, pass an
  # explicit `area:` rather than trusting this.
  DEFAULT_AREA = Gori::Tui::Rect.new(0, 0, 80, 24)

  getter overlay : Gori::Tui::Overlay
  getter area : Gori::Tui::Rect
  # Times the injected on_commit ran (a :commit outcome, whether or not it closed).
  getter commits = 0
  # The shell still holds this modal — false once a :cancel, or a :commit whose closure
  # returned true, dropped it.
  getter? open = true

  # `commit` is what the injected closure reports back to the shell: true = "applied,
  # close me", false = the validation-rejected path that keeps the form up. Override it
  # mid-example with `on_commit`.
  #
  # An overlay that ALREADY carries a closure is wrapped, not replaced: the real open-sites
  # (`open_scope_rule_editor` and friends) set `on_commit` before handing the modal over, so
  # a migration spec that mirrors its open-site and then wraps it here must still be running
  # the production closure. Silently swapping in `-> { true }` would leave the example
  # asserting `commits == 1` while proving nothing about the code under test.
  def initialize(@overlay : Gori::Tui::Overlay, *, area : Gori::Tui::Rect = DEFAULT_AREA,
                 commit : Bool? = nil)
    @area = area
    if existing = @overlay.on_commit
      raise ArgumentError.new(
        "the overlay already carries an on_commit closure; pass commit: to override it deliberately"
      ) unless commit.nil?
      count(&existing) # keep the production closure, just make its runs observable
    else
      result = commit.nil? ? true : commit
      count { result }
    end
  end

  # Replace the commit outcome wholesale (e.g. flip to a rejecting closure part-way
  # through). Discards whatever closure is installed — that is the point.
  def commit_result=(ok : Bool)
    count { ok }
  end

  # Inject a bespoke commit closure — still counted in `commits`. Use when the example
  # needs to observe the overlay's state at commit time (the real open-sites all do).
  def on_commit(&blk : -> Bool) : Nil
    count(&blk)
  end

  # The one place a closure is installed, so `commits` counts every path uniformly.
  private def count(&blk : -> Bool) : Nil
    @overlay.on_commit = -> {
      @commits += 1
      blk.call
    }
  end

  # One key through the shell's dispatch. Returns :open or :closed — the shell-visible
  # outcome, NOT the overlay's raw :stay/:commit/:cancel (assert that with
  # `overlay.handle_key` directly when a spec cares about the vocabulary itself).
  def press(k : Termisu::Input::Key, char : Char? = nil,
            ctrl : Bool = false, alt : Bool = false, shift : Bool = false) : Symbol
    live!
    dispatch(@overlay.handle_key(event(k, char, ctrl, alt, shift)))
  end

  # Type a literal string one printable key at a time. Returns the state after the LAST
  # character.
  #
  # CAVEAT: every char rides on Key::LowerA with the real char attached, which is what the
  # existing overlay specs do and is correct for any field that reads `ev.char`. An overlay
  # that branches on `ev.key` instead — vim-style j/k nav, a mnemonic matched off the key
  # rather than the char — will NOT see the key you typed. Drive those with `press` and the
  # real Input::Key.
  def type(text : String) : Symbol
    live!
    out = :open
    text.each_char { |c| out = press(Termisu::Input::Key::LowerA, c) }
    out
  end

  # Absolute click within `area` (the shell passes raw body coordinates).
  def click(mx : Int32, my : Int32) : Symbol
    live!
    dispatch(@overlay.handle_click(@area, mx, my))
  end

  # Click at an offset INSIDE the modal card — the readable way to hit a row, since each
  # overlay puts its first row a different distance below its own box top.
  def click_in_box(dx : Int32, dy : Int32) : Symbol
    b = box
    raise "overlay has no box to click in (overlay_box returned nil)" unless b
    click(b.x + dx, b.y + dy)
  end

  # A scroll-wheel notch over the modal, already ±3-scaled like Runner#handle_wheel.
  # Guarded like press/click: once the shell has dropped the modal, `active_overlay`
  # returns nil and neither Runner#wheel_overlay nor #apply_preedit reaches it again.
  def wheel(step : Int32) : Nil
    live!
    @overlay.handle_wheel(step)
  end

  def preedit(text : String) : Nil
    live!
    @overlay.set_preedit(text)
  end

  def box : Gori::Tui::Rect?
    @overlay.overlay_box(@area)
  end

  # Draw the card into a fresh MemoryBackend sized to `area` and return it, so an example
  # can assert on what the user actually sees (`mb.contains?("…")`, `mb.row(y)`).
  def render : MemoryBackend
    mb = MemoryBackend.new(@area.x + @area.w, @area.y + @area.h)
    @overlay.render(Gori::Tui::Screen.new(mb), @area)
    mb
  end

  def rendered?(text : String) : Bool
    render.contains?(text)
  end

  # The chrome the Runner's collapsed title/hint ladders now read off the overlay. Every
  # migrated modal must supply all three, so assert it once per modal.
  def assert_chrome(key : Gori::Tui::OverlayKind, title : String) : Nil
    @overlay.key.should eq(key)
    @overlay.title.should eq(title)
    @overlay.hint.should_not be_empty
  end

  # The shell stops routing input the moment it drops the modal, so an example that keeps
  # driving a closed overlay is asserting against something the user can no longer touch.
  private def live! : Nil
    raise "the overlay is already closed — the shell would have stopped routing input" unless @open
  end

  private def dispatch(outcome : Symbol) : Symbol
    case outcome
    when :cancel then @open = false
    when :commit then @open = false if @overlay.commit
    end
    @open ? :open : :closed
  end

  private def event(k : Termisu::Input::Key, char : Char?,
                    ctrl : Bool, alt : Bool, shift : Bool) : Termisu::Event::Key
    mods = Termisu::Input::Modifier::None
    mods |= Termisu::Input::Modifier::Ctrl if ctrl
    mods |= Termisu::Input::Modifier::Alt if alt
    mods |= Termisu::Input::Modifier::Shift if shift
    Termisu::Event::Key.new(k, mods, char)
  end
end
