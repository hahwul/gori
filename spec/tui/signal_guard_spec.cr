require "../spec_helper"

# Stands in for the two seams App::SignalGuard injects. Nothing in this file may install a
# real trap or reset a real disposition: both are process-global and would leak into every
# later example in the suite (and the real `die` would take the run down with it).
private class SignalRecorder
  getter armed = [] of Signal
  getter died = [] of Signal
  getter handlers = {} of Signal => Proc(Nil)
  # restore and die land in ONE list: their relative order is the fix (a handler that dies
  # first restores nothing, which is exactly the pre-fix behaviour).
  getter trace = [] of Symbol

  def arm : Proc(Signal, Proc(Nil), Nil)
    ->(sig : Signal, handler : Proc(Nil)) : Nil do
      @armed << sig
      @handlers[sig] = handler
    end
  end

  def die : Proc(Signal, Nil)
    ->(sig : Signal) : Nil do
      @trace << :die
      @died << sig
    end
  end

  # A terminal restore that records itself; `outcome` lets an example make it fail the way
  # Termisu#close can when the tty is already gone.
  def restore(&outcome : -> Nil) : Proc(Nil)
    -> do
      @trace << :restore
      outcome.call
    end
  end

  def restore : Proc(Nil)
    restore { }
  end
end

# The interactive TUI installed NO signal traps: `install_signal_traps` was called only from
# the headless `run_capture` path, so a DELIVERED INT/TERM/HUP killed gori by its default
# disposition — no stack unwind, so `run_tui`'s `ensure term.close` never ran and the
# operator's pane was handed back with ECHO/ICANON/ISIG/OPOST off, the alternate screen up
# and SGR-1006 mouse reporting still on (only `reset` recovered it).
#
# The one thing that cannot be exercised in-process is the `run_tui` call site itself, which
# needs a live /dev/tty.
describe Gori::App::SignalGuard do
  it "arms every signal the TUI must not die from, and never fewer than headless capture" do
    rec = SignalRecorder.new
    Gori::App::SignalGuard.new(rec.restore, arm: rec.arm, die: rec.die).install

    rec.armed.should contain(Signal::INT)
    rec.armed.should contain(Signal::TERM)
    # HUP: an SSH drop kills gori while the tmux/screen session it ran in survives, so the
    # surviving pane is the one left wrecked. Headless capture deliberately does NOT trap it.
    rec.armed.should contain(Signal::HUP)
    # The TUI owns a raw-mode tty and headless capture does not, so the TUI can never handle
    # a strictly smaller set than the path that has less to lose.
    (Gori::App::CAPTURE_SIGNALS - Gori::App::TUI_SIGNALS).should be_empty
    Gori::App::CAPTURE_SIGNALS.should_not contain(Signal::HUP)
    # Arming alone must not fire anything — the terminal is still in use.
    rec.died.should be_empty
  end

  it "restores the terminal BEFORE it dies, and dies from the signal it received" do
    rec = SignalRecorder.new
    Gori::App::SignalGuard.new(rec.restore, arm: rec.arm, die: rec.die).install

    rec.handlers[Signal::TERM].call
    # Order, not just occurrence: `die` re-raises under the default disposition and never
    # returns, so anything sequenced after it never runs at all.
    rec.trace.should eq([:restore, :die])
    # Re-raised as TERM, not as whichever signal the install loop happened to end on — the
    # exit status ($? = 128+signo) is the whole reason for re-raising rather than exiting.
    rec.died.should eq([Signal::TERM])
  end

  it "binds each handler to its own signal" do
    rec = SignalRecorder.new
    Gori::App::SignalGuard.new(rec.restore, arm: rec.arm, die: rec.die).install

    Gori::App::TUI_SIGNALS.each { |sig| rec.handlers[sig].call }
    rec.died.should eq(Gori::App::TUI_SIGNALS)
  end

  it "still dies when the terminal restore raises" do
    rec = SignalRecorder.new
    # Termisu#close touches a tty that may already be gone (an SSH drop takes the fd with it).
    # A teardown that raises must not turn "killed" into "hung" — that would be worse than
    # the bug this guard fixes, since the operator's remaining recourse is SIGKILL.
    restore = rec.restore { raise IO::Error.new("tty is gone") }
    Gori::App::SignalGuard.new(restore, arm: rec.arm, die: rec.die).install

    rec.handlers[Signal::HUP].call
    rec.trace.should eq([:restore, :die])
    rec.died.should eq([Signal::HUP])
  end

  it "honours an explicit signal set" do
    rec = SignalRecorder.new
    Gori::App::SignalGuard.new(rec.restore, [Signal::INT], arm: rec.arm, die: rec.die).install
    rec.armed.should eq([Signal::INT])
  end
end
