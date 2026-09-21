require "termisu"

# Stops an IDLE `gori tui` burning two thirds of its CPU on a poll for input that is not coming.
#
# CARRIED PATCH — same terms as `paste_end_marker_patch.cr`: `lib/` is gitignored and shard.lock
# pins a commit, so there is nothing in the dependency to edit, and this is a verbatim copy of
# the pinned `run_loop` apart from the change named below. Delete it once shard.lock ships a
# termisu whose input source waits on the fd instead of polling it.
#
# `spec/tui/input_idle_backoff_spec.cr` carries the trigger, and it is this patch's OWN, not a
# reference to the paste patch's. That one exists to be deleted the day termisu ships the paste
# fix, and this file would have gone unguarded with it.
#
# THE COST, in `Termisu::Event::Source::Input#run_loop`: the fiber every termisu app receives
# input through drains with a NON-BLOCKING `poll_event(0)` and then sleeps a fixed
# `IDLE_SLEEP` (4ms). That is 250 wake-ups a second, each one a fiber-scheduler round trip and
# a `select(2)` on the tty, for as long as the program is open — whether or not anybody is
# typing. Termisu's own comment calls the 4ms a "measured stopgap" and names the real fix
# (evented IO on the input fd) as deferred.
#
# MEASURED here as cumulative process CPU (`ps -o cputime=`) across an idle window, tmux 120x30,
# the two gori builds run alternately so machine drift shows up as noise rather than as a result:
#
#     a bare termisu app polling at gori's own 50ms cadence   0.42s /  30s = 1.4%
#     the same app with the back-off below                    0.13s /  30s = 0.43%
#     `gori tui` on the Project tab, unpatched                2.67s / 120s = 2.2%
#     `gori tui` on the Project tab, with this                2.00s / 120s = 1.7%
#
# So most of what an idle termisu costs is this poll (3.3x), and a quarter of what an idle gori
# costs is the same poll seen through everything else gori does per tick — on a tool that stays
# open all day beside a browser, on a laptop. Key-to-repaint latency was measured over the same
# pair (tab switch after a 2s pause, 6 runs each) and did not regress.
#
# THE FIX is to poll at the SAME 4ms while input is actually flowing and back off to one 60Hz
# frame once it has been quiet for a moment. `IDLE_GRACE` is what keeps typing on the fast
# path: any delivered event re-arms it, so a keystroke, a held arrow, a paste and a mouse drag
# all run at the original cadence — the back-off can only ever apply to the FIRST event after a
# pause, and it bounds that at one frame. gori cannot get this from the outside: the sleep is
# inside the fiber termisu owns, and the caller's `poll_event` timeout does not reach it.
#
# NOT evented IO, deliberately. `Reader` does its readiness check with a raw `select(2)`, which
# blocks the THREAD rather than the fiber — under a single-threaded scheduler that would stall
# the proxy's fibers, which is the whole reason the loop polls in the first place. Rebuilding it
# on `IO::FileDescriptor` means a second IO over gori's live tty fd (and a finalizer that would
# close it), which is a change that belongs in termisu, not in a patch carried by a consumer.
#
# WHAT THIS WIDENS, disclosed because it is not zero. It used to be a double-fiber race:
# `resume_input_processing` flipped `@running` back on and spawned a fresh fiber while the
# previous one was still parked in the sleep. That race is gone at c3d69e6 (`fix:
# coordinate raw input ownership`) — `Source::Input` serializes `start`/`stop` on a
# lifecycle lock and `stop` blocks on `@done` until the old
# fiber's `ensure` runs, so two can no longer coexist.
#
# What replaces it is the mirror image: `stop` now WAITS for that fiber, and the loop does not
# select on the stop signal while sleeping. So every mode transition that pauses input —
# `term.suspend` for the external editor, `term.close` on quit — blocks on the sleep finishing,
# and this patch takes that from upstream's 4ms to at most 16ms. Both are far below the
# `Process.run` either of them brackets, which is why it stays worth the idle CPU.
#
# TWO WAYS THIS GOES WRONG, and only one of them is benign. If upstream RENAMES or restructures
# `run_loop`, the override becomes dead code and the poll returns to 4ms — nothing breaks, and
# the spec's constant assertion still says the file is compiled in. The other way is not benign:
# if upstream keeps the name and fixes something INSIDE it — including the double-fiber race
# this file discloses above — a verbatim copy silently reinstates whatever was fixed, with no
# compile error and no failing example. That is the same "keeps applying when it should not"
# case `paste_end_marker_patch.cr` guards on purpose, and it is what the lock pin answers: move
# the pin and the spec fails, which is exactly when someone should be re-reading this file.
#
# BOTH have now happened once, at the #1125 lock bump. `run_loop` took two parameters upstream,
# so the old no-argument copy became a silent overload nobody called and the back-off was simply
# gone; and the body it froze predated `@pending_event`, which keeps a parsed event across a
# paused output channel instead of dropping it. The copy below is the CURRENT upstream body with
# the sleep line changed and nothing else, which is the only shape that re-reading can check.
class Termisu::Event::Source::Input
  # How long input must have been quiet before the poll backs off. Long enough that a pause
  # between two keystrokes — even a slow typist's — never leaves the fast path.
  IDLE_GRACE = 250.milliseconds

  # The backed-off cadence: one frame at 60Hz. This is the WORST added latency for the first
  # event after a pause, and only for that one, since delivering it re-arms `IDLE_GRACE`.
  DEEP_IDLE_SLEEP = 16.milliseconds

  private def run_loop(output : Channel(Event::Any), stop_signal : Channel(Nil)) : Nil
    last_delivery = Time.instant

    while @running.get
      emitted = false
      drained = 0

      while @running.get && drained < MAX_DRAIN_PER_CYCLE
        event = @pending_event || @parser.poll_event(0)
        break unless event

        unless send_event(output, stop_signal, event)
          # The parser already consumed this complete event. Keep it for the
          # next run instead of losing it when a full output channel is paused.
          @pending_event = event
          return
        end

        @pending_event = nil
        emitted = true
        drained += 1
      end

      break unless @running.get

      if emitted
        last_delivery = Time.instant
        Fiber.yield
      else
        # THE CHANGE. Upstream sleeps `IDLE_SLEEP` unconditionally here.
        sleep(Time.instant - last_delivery >= IDLE_GRACE ? DEEP_IDLE_SLEEP : IDLE_SLEEP)
      end
    end
  rescue Channel::ClosedError
    # Channel closed during shutdown - exit gracefully
    Log.debug { "Input channel closed, exiting" }
  end
end
