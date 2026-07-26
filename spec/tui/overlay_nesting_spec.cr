require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# `Overlay#on_close` — the nested-modal seam (#355). A modal opened FROM another pops back
# into it on close, which the shell used to express with a single `@prefs_return` flag plus
# a `settle_sub_editor` call at each dispatch chokepoint: one hard-coded relationship for
# the whole app, and one the Preferences family alone could use.
#
# Everything the migration batches need from it is a CONTRACT about shell state, not about
# any one modal, so this file pins the contract with doubles and no production overlay:
#
#   * on_close runs on a cancel and on a commit that closed — never while the modal is up
#   * the shell drops the modal BEFORE running it, so a pop-back's open_overlay sticks
#   * the parent it restores may be a migrated `Overlay` OR an unmigrated `@overlay` state
#   * `leave_overlay` deliberately skips it, for an exit that goes somewhere else (^P)
#
# The last three are what a confirm raised from INSIDE another modal needs — the three
# live sites being `runner.cr`'s settings ^R reset and tab-bar reset (migrated parents) and
# `history_controller.cr:385`'s delete-from-detail (an unmigrated `:detail` parent).

private def nkey(k : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(k)
end

private ESC   = Termisu::Input::Key::Escape
private ENTER = Termisu::Input::Key::Enter

# A modal that answers the outcome vocabulary and nothing else — esc cancels, ↵ commits.
# `key` is a constructor argument so an example can stand one in for whichever real modal
# it is modelling (a Settings card, a Confirm dialog) without depending on that modal.
private class NestModal < Overlay
  def initialize(@kind : OverlayKind)
  end

  def key : OverlayKind
    @kind
  end

  def title : String
    @kind.to_s.upcase
  end

  def hint : String
    "nest hint"
  end

  def render(screen : Screen, area : Rect) : Nil
  end

  def handle_key(ev : Termisu::Event::Key) : Symbol
    return :cancel if ev.key.escape?
    return :commit if ev.key.enter?
    :stay
  end
end

# A miniature of the Runner's overlay STATE — `@active_overlay` + `@overlay` and the four
# methods that read or write them, copied from runner.cr. OverlayHarness models the
# dispatch but holds no shell state, and the Runner itself needs a live tty, so this is the
# only way to assert what a nested close leaves the shell holding.
#
# Keep it in step with runner.cr: an example that passes against a drifted double proves
# nothing about the real shell.
private class NestShell
  # `property` because ~40 production sites assign @overlay directly without touching
  # @active_overlay — which is exactly what an unmigrated parent's restore has to do.
  property overlay = OverlayKind::None
  getter active : Overlay?

  # Mirrors Runner::MODAL_OVERLAYS — the states restore_overlay is allowed to name without
  # an object behind them. Keep in step (it is deliberately tiny; migrated modals are absent).
  MODAL_OVERLAYS = {OverlayKind::Palette, OverlayKind::TabsMore}

  def open_overlay(ov : Overlay) : Nil
    @active = ov
    @overlay = ov.key
  end

  def close_active_overlay(ov : Overlay) : Nil
    cur = @active
    return unless cur && cur.same?(ov)
    leave_overlay
    ov.on_close.try(&.call)
  end

  def leave_overlay : Nil
    @active = nil
    @overlay = OverlayKind::None
  end

  # The liveness gate: a modal is routed to only while @overlay still names it.
  def active_overlay : Overlay?
    ov = @active
    ov if ov && @overlay == ov.key
  end

  # Mirror of Runner#restore_overlay (runner.cr). Keep in step — a spec that passes against
  # a drifted copy proves nothing about the real shell. The `|| kind.none?` clause is the
  # #384 fix: a :none confirm displacing a modal restores it, rather than dropping it.
  def restore_overlay(kind : OverlayKind, parent : Overlay?, displaced : OverlayKind = OverlayKind::None) : Nil
    return open_overlay(parent) if parent && (parent.key == kind || kind.none?)
    # #413: a :none confirm over an unmigrated MODAL_OVERLAYS member (Palette/TabsMore, no
    # object seam) restores the captured @overlay rather than dropping to the bare body.
    return (@overlay = displaced) if kind.none? && MODAL_OVERLAYS.includes?(displaced)
    restorable = kind.none? || kind.detail? || MODAL_OVERLAYS.includes?(kind)
    @overlay = restorable ? kind : OverlayKind::None
  end

  # Mirror of Runner#confirm's overlay-state wiring (runner.cr): capture the displaced
  # parent BEFORE open_overlay overwrites it, then wire the dialog to restore-first-act-
  # second on close. Uses the real ConfirmDialog so `y`/`n`/esc route exactly as they do
  # in the shell. `return_to` mirrors the production Symbol seam.
  def confirm(*, return_to : Symbol = :none, &action : -> Nil) : Nil
    ov = ConfirmDialog.new("CONFIRM", "quit?")
    back = OverlayKind.from_sym(return_to)
    parent = active_overlay
    displaced = @overlay # for an unmigrated Palette/TabsMore that has no object on the seam (#413)
    accepted = false
    ov.on_commit = -> { accepted = true; true }
    ov.on_close = -> {
      restore_overlay(back, parent, displaced)
      action.call if accepted
    }
    open_overlay(ov)
  end

  def press(k : Termisu::Input::Key) : Nil
    return unless ov = active_overlay
    case ov.handle_key(nkey(k))
    when :cancel then close_active_overlay(ov)
    when :commit then close_active_overlay(ov) if ov.commit
    end
  end
end

# A modal whose handler opens ANOTHER modal and then returns the WRONG outcome — the
# mistake the identity check in close_active_overlay is there to absorb. Real handlers
# that hand off (a Preferences opener row) return :stay.
private class SwapModal < Overlay
  def initialize(@shell : NestShell, @next : Overlay, @outcome : Symbol)
  end

  def key : OverlayKind
    OverlayKind::Preferences
  end

  def title : String
    "SWAP"
  end

  def hint : String
    "swap hint"
  end

  def render(screen : Screen, area : Rect) : Nil
  end

  def handle_key(ev : Termisu::Event::Key) : Symbol
    @shell.open_overlay(@next)
    @outcome
  end
end

describe "Overlay#on_close — when it runs" do
  # Every example here counts the OVERLAY'S OWN closure, not just `harness.closes`. The
  # counter alone is a tautology: it would keep incrementing even if the harness stopped
  # invoking `on_close` entirely, and every migration spec downstream would stay green
  # while the pop-back never ran. Proved by mutation — deleting the harness's
  # `on_close.try(&.call)` left this file passing until the assertions moved onto `ran`.
  it "runs the overlay's own closure on a cancel and on a commit that closed" do
    {ESC, ENTER}.each do |k|
      ov = NestModal.new(OverlayKind::ScopeRule)
      ran = 0
      ov.on_close = -> { ran += 1; nil }
      h = OverlayHarness.new(ov)
      h.press(k).should eq(:closed)
      ran.should eq(1), "the overlay's own on_close did not run for #{k}"
      h.closes.should eq(1)
    end
  end

  it "does NOT run for a commit the closure rejected — the modal is still up" do
    # A validation failure keeps the form open, so there is nothing to pop back to yet.
    # Firing the pop-back here would swap the parent in underneath a modal still on screen.
    ov = NestModal.new(OverlayKind::ScopeRule)
    ran = 0
    ov.on_close = -> { ran += 1; nil }
    h = OverlayHarness.new(ov, commit: false)
    h.press(ENTER).should eq(:open)
    h.commits.should eq(1)
    ran.should eq(0)
  end

  it "does not run while the modal merely stays open" do
    ov = NestModal.new(OverlayKind::ScopeRule)
    ran = 0
    ov.on_close = -> { ran += 1; nil }
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Down).should eq(:open)
    ran.should eq(0)
  end

  it "runs AFTER the modal is dropped, so a pop-back is the last word" do
    # The closure observes the shell mid-close: by the time it runs, the modal is already
    # gone. That is what lets it call open_overlay(parent) and have it stick.
    h = OverlayHarness.new(NestModal.new(OverlayKind::ScopeRule))
    still_held = nil.as(Bool?)
    h.overlay.on_close = -> { still_held = h.open?; nil }
    h.press(ESC).should eq(:closed)
    still_held.should be_false
  end

  it "is optional — closing a modal that never set one must not raise" do
    h = OverlayHarness.new(NestModal.new(OverlayKind::ScopeRule))
    h.overlay.on_close.should be_nil
    h.press(ESC).should eq(:closed)
  end
end

describe "Overlay#on_close — the nested lifecycle" do
  it "leaves the shell holding the parent, because the drop happens first" do
    # If close_active_overlay ran on_close BEFORE clearing @active_overlay, the clear would
    # undo the pop-back and the user would land on the bare tab body.
    shell = NestShell.new
    parent = NestModal.new(OverlayKind::Preferences)
    child = NestModal.new(OverlayKind::Hosts)
    child.on_close = -> { shell.open_overlay(parent) }

    shell.open_overlay(child)
    shell.press(ESC)

    shell.active_overlay.should be(parent)
    shell.overlay.should eq(OverlayKind::Preferences)
  end

  it "composes: a child of a child pops back one level at a time" do
    # The flag it replaced could not express this — @prefs_return was one bit for the whole
    # shell, so a second level of nesting had nowhere to record where it came from.
    shell = NestShell.new
    prefs = NestModal.new(OverlayKind::Preferences)
    editor = NestModal.new(OverlayKind::Settings)
    dialog = NestModal.new(OverlayKind::Confirm)
    editor.on_close = -> { shell.open_overlay(prefs) }
    dialog.on_close = -> { shell.open_overlay(editor) }

    shell.open_overlay(dialog)
    shell.press(ESC)
    shell.active_overlay.should be(editor) # …not straight out to Preferences
    shell.press(ESC)
    shell.active_overlay.should be(prefs)
    shell.press(ESC)
    shell.active_overlay.should be_nil # the outermost has no parent → out to the body
    shell.overlay.should eq(OverlayKind::None)
  end

  it "restores a parent that has NOT migrated, by naming its @overlay state" do
    # History's delete-from-detail (history_controller.cr:385) raises its confirm with
    # `return_to: :detail`. The History drill-in is not an Overlay object at all and is out
    # of the migration's scope, so the closure assigns the state instead of re-opening an
    # object. on_close has to cover that too, or that call-site has no path.
    shell = NestShell.new
    shell.overlay = OverlayKind::Detail
    dialog = NestModal.new(OverlayKind::Confirm)
    dialog.on_close = -> { shell.overlay = OverlayKind::Detail }

    shell.open_overlay(dialog)
    shell.press(ESC) # cancel → back to the flow detail, not out to the list
    shell.overlay.should eq(OverlayKind::Detail)
    shell.active_overlay.should be_nil # no object to route to — @overlay alone drives it
  end

  it "never closes a modal the handler swapped in mid-key" do
    # A handler may open another modal — a Preferences opener row hands off to its editor —
    # and must return :stay when it does. A wrong :cancel would otherwise drop the editor
    # that had just appeared AND run the editor's own pop-back, one keystroke after it
    # opened. close_active_overlay compares against what the shell currently holds, so the
    # wrong return is inert instead of user-visible.
    shell = NestShell.new
    editor = NestModal.new(OverlayKind::Hosts)
    popped = 0
    editor.on_close = -> { popped += 1; nil }

    shell.open_overlay(SwapModal.new(shell, editor, :cancel))
    shell.press(ESC)

    shell.active_overlay.should be(editor) # the handed-off editor is still up
    popped.should eq(0)                    # …and its pop-back never fired
  end

  it "leaves a ^P palette jump alone even if the handler then returns :cancel" do
    # The other half: a handler that calls leave_overlay on its way to the palette has
    # already emptied @active_overlay. Closing again would blank @overlay and take the
    # palette down with it.
    shell = NestShell.new
    jumper = NestModal.new(OverlayKind::Hosts)
    shell.open_overlay(jumper)
    shell.leave_overlay
    shell.overlay = OverlayKind::Palette # what open_palette does next

    shell.close_active_overlay(jumper) # the stale close the wrong outcome would trigger
    shell.overlay.should eq(OverlayKind::Palette)
  end

  it "skips on_close for an exit that goes somewhere else (the ^P palette jump)" do
    # leave_overlay is the escape hatch: a pop-back would re-open the parent ON TOP of the
    # palette the user just asked for.
    shell = NestShell.new
    parent = NestModal.new(OverlayKind::Preferences)
    child = NestModal.new(OverlayKind::Hosts)
    pops = 0
    child.on_close = -> { pops += 1; shell.open_overlay(parent) }

    shell.open_overlay(child)
    shell.leave_overlay
    shell.overlay = OverlayKind::Palette # what open_palette does next

    pops.should eq(0)
    shell.overlay.should eq(OverlayKind::Palette)
    shell.active_overlay.should be_nil
  end
end

describe "Overlay#on_close — a confirm raised from inside another modal" do
  it "needs the parent captured BEFORE the dialog is opened" do
    # Today `confirm()` never touches @active_overlay — it only moves @overlay, so the
    # parent goes inert but stays held and `@overlay = @confirm_return` brings it back for
    # free. The moment ConfirmDialog is opened through open_overlay that stops being true:
    # the parent reference is overwritten and only a capture taken first still has it.
    shell = NestShell.new
    parent = NestModal.new(OverlayKind::Settings)
    shell.open_overlay(parent)

    captured = shell.active_overlay # the read confirm() must do at its top
    dialog = NestModal.new(OverlayKind::Confirm)
    shell.open_overlay(dialog)
    shell.active_overlay.should be(dialog) # the shell no longer holds the parent
    captured.should be(parent)             # …only the capture does

    dialog.on_close = -> { captured.try { |p| shell.open_overlay(p) } }
    shell.press(ESC) # CANCEL lands back in the parent, same as accept
    shell.active_overlay.should be(parent)
    shell.overlay.should eq(OverlayKind::Settings)
  end

  it "can run the dialog's action AFTER the restore, which History depends on" do
    # `Runner#run_confirm` is restore-then-action today, and history_controller.cr:385
    # relies on it: its action reads `@host.overlay == :detail` to decide whether the
    # drill-in should close now that the flow is gone. on_close is the hook that reproduces
    # that order under the generic dispatch.
    shell = NestShell.new
    seen_by_action = nil.as(OverlayKind?)
    accepted = false
    dialog = NestModal.new(OverlayKind::Confirm)
    dialog.on_commit = -> { accepted = true; true }
    dialog.on_close = -> {
      shell.overlay = OverlayKind::Detail        # the restore…
      seen_by_action = shell.overlay if accepted # …then the action, which reads it
      nil
    }

    shell.open_overlay(dialog)
    shell.press(ENTER)
    seen_by_action.should eq(OverlayKind::Detail)
  end

  it "shows why that action cannot ride on_commit instead" do
    # The dispatch runs `commit` BEFORE the close (`close_active_overlay if ov.commit`), so
    # an action wired into on_commit sees the DIALOG's state, never the restored parent's.
    # History's guard would silently never fire, and the pop-back would then re-open the
    # flow detail on a flow that was just deleted.
    shell = NestShell.new
    seen_by_action = nil.as(OverlayKind?)
    dialog = NestModal.new(OverlayKind::Confirm)
    dialog.on_commit = -> { seen_by_action = shell.overlay; true }
    dialog.on_close = -> { shell.overlay = OverlayKind::Detail }

    shell.open_overlay(dialog)
    shell.press(ENTER)
    seen_by_action.should eq(OverlayKind::Confirm) # not :detail — too early to read it
  end
end

# #384 — a confirm raised OVER another modal with the default `return_to: :none`. Its one
# reachable trigger is the opt-in quit confirm (settings:general "Confirm before quit"),
# which fires from `Runner#handle_key` while ANY modal is up. These drive the real
# `NestShell#confirm` + `#restore_overlay` (mirrors of runner.cr) through the real
# ConfirmDialog, so `n`/`y`/esc route exactly as the shell does.
private YES = Termisu::Input::Key::LowerY
private NO  = Termisu::Input::Key::LowerN

describe "Runner#restore_overlay — a :none confirm displacing a modal (#384)" do
  it "restores the displaced modal on decline, and does NOT run its on_close" do
    # The bug: declining the quit confirm dropped the modal AND left its on_close unrun, so
    # a theme preview stuck applied, an unsaved edit vanished, or a nested pop-back was lost.
    # The modal was only DISPLACED, never asked to close, so its teardown must not fire — it
    # comes back exactly as it was.
    shell = NestShell.new
    editor = NestModal.new(OverlayKind::Settings) # e.g. the Theme card, mid live-preview
    popped_back = 0
    editor.on_close = -> { popped_back += 1; nil } # its teardown (revert preview / pop to Prefs)
    shell.open_overlay(editor)

    shell.confirm(return_to: :none) { } # ^C/^D with confirm-before-quit on
    shell.active_overlay.should be_a(ConfirmDialog)
    shell.press(NO) # "no, don't quit"

    shell.active_overlay.should be(editor)         # the card is back…
    shell.overlay.should eq(OverlayKind::Settings) # …object AND state, so it renders + captures
    popped_back.should eq(0)                       # …and its teardown never ran
  end

  it "on accept, restores the modal FIRST and then runs the quit action" do
    # Accepting still runs restore-then-action (the ordering history_controller relies on).
    # The quit action fires last; the restore before it is harmless (the app is leaving).
    shell = NestShell.new
    editor = NestModal.new(OverlayKind::Hosts)
    shell.open_overlay(editor)

    quit_ran = false
    seen_by_action = nil.as(Overlay?)
    shell.confirm(return_to: :none) { quit_ran = true; seen_by_action = shell.active_overlay }
    shell.press(YES) # "yes, quit"

    quit_ran.should be_true
    seen_by_action.should be(editor) # the restore ran before the action, not after
  end

  it "still restores when return_to NAMES the parent (the existing path, unregressed)" do
    # RESET SETTINGS / RESET TAB BAR raise their confirm with return_to: :settings / :tabs
    # from inside the card. This worked before #384 and must keep working: same object-restore.
    shell = NestShell.new
    card = NestModal.new(OverlayKind::Settings)
    reset_ran = 0
    card.on_close = -> { reset_ran += 1; nil }
    shell.open_overlay(card)

    shell.confirm(return_to: :settings) { }
    shell.press(NO)

    shell.active_overlay.should be(card)
    shell.overlay.should eq(OverlayKind::Settings)
    reset_ran.should eq(0) # the card was displaced, not closed
  end

  it "lands on the bare body when a :none confirm displaced nothing" do
    # A palette-launched confirm (no modal up) still means "nowhere to go back to": decline
    # leaves the user on the tab body. The fix must not conjure a parent that was never there.
    shell = NestShell.new
    shell.confirm(return_to: :none) { }
    shell.press(NO)

    shell.active_overlay.should be_nil
    shell.overlay.should eq(OverlayKind::None)
  end

  it "restores the command palette / hidden-tabs dropdown displaced by a :none confirm (#413)" do
    # Palette and TabsMore are NOT on the object seam — open_palette/open_more_menu set
    # @overlay directly, no @active_overlay. So the quit confirm captured a nil `parent` and,
    # with `back` = None, dropped them to the bare body. The captured @overlay restores them.
    {OverlayKind::Palette, OverlayKind::TabsMore}.each do |kind|
      shell = NestShell.new
      shell.overlay = kind # mirror open_palette / open_more_menu (state only, no object)

      shell.confirm(return_to: :none) { } # ^C/^D with confirm-before-quit on
      shell.active_overlay.should be_a(ConfirmDialog)
      shell.press(NO) # decline the quit

      shell.active.should be_nil    # neither carries an object…
      shell.overlay.should eq(kind) # …but the state is restored, so it still renders + captures
    end
  end

  it "never restores a MIGRATED kind by STATE alone — the phantom hazard" do
    # restore_overlay may only name a state for None / Detail / an unmigrated MODAL_OVERLAYS
    # member. A migrated kind restored by @overlay alone (no object) renders nothing, takes
    # no keys, and — being absent from MODAL_OVERLAYS — lets clicks fall through to the body
    # behind a card that was never drawn. With no object to restore it, fall to the bare body.
    shell = NestShell.new
    shell.restore_overlay(OverlayKind::Settings, nil) # a migrated kind, no object
    shell.overlay.should eq(OverlayKind::None)        # …not a phantom Settings

    shell.restore_overlay(OverlayKind::Palette, nil) # an unmigrated MODAL_OVERLAYS member
    shell.overlay.should eq(OverlayKind::Palette)    # …that one IS routed by state
  end
end
