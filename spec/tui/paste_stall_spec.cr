require "../spec_helper"

# The watchdog DECISION, which is the part that gets this wrong.
#
# `Runner` needs a tty and cannot be driven from a spec, so while this logic lived inline in the
# render loop it had no test — and the first version shipped a bug every e2e check missed: the
# stall clock was re-armed only by a dense tick and never by the paste STARTING, so a paste made
# the ordinary way (idle, switch to the browser, copy, come back, paste) was declared stalled on
# its own opening tick. Measured in the app at 44ms. The e2e checks passed only because they
# happened to paste ~1.2s after a keystroke, just inside the 1500ms window.
#
# Every example below is written against `PasteStall`'s own clock rather than wall time, so the
# suite pays no sleeps for them.
private def stall(stall_ms = 1500, burst = 8)
  Gori::Tui::PasteStall.new(stall_ms.milliseconds, burst)
end

describe Gori::Tui::PasteStall do
  it "does not fire before a paste has opened" do
    s = stall
    t = Time.instant
    s.open?.should be_false
    s.stalled?(t + 1.hour).should be_false # no paste is open; there is nothing to end
  end

  # THE REGRESSION. The clock must start when the paste starts, not carry whatever the last
  # keypress was — the gap before a paste is normally seconds or minutes, because the operator
  # went somewhere else to copy.
  it "starts its clock when the paste opens, not from earlier input" do
    s = stall
    idle = Time.instant
    s.saw(idle, 30) # a burst long ago: navigation, then the operator leaves
    open_at = idle + 5.minutes
    s.opened(open_at)

    s.stalled?(open_at).should be_false                     # the opening tick must never fire
    s.stalled?(open_at + 1400.milliseconds).should be_false # still inside the window
    s.stalled?(open_at + 1500.milliseconds).should be_true  # and only then
  end

  it "keeps the paste alive while bursts keep arriving" do
    s = stall
    t = Time.instant
    s.opened(t)
    12.times do
      t += 1400.milliseconds
      s.saw(t, 31) # a paste still streaming: ~31 events behind the tick's first
      s.stalled?(t).should be_false
    end
    s.stalled?(t + 1500.milliseconds).should be_true # the clipboard ran out
  end

  # The whole point of density over idleness: an operator whose TUI froze mashes Escape, and each
  # press must NOT buy the wedge another window. Measured in the app before this rule: 14 Escapes
  # over 11 seconds kept the keyboard dead.
  it "is not re-armed by ordinary keystrokes" do
    s = stall
    t = Time.instant
    s.opened(t)
    14.times do
      t += 800.milliseconds
      s.saw(t, 1) # one keypress per tick — a person, not a paste
    end
    s.stalled?(t).should be_true
  end

  it "treats a sub-threshold flurry as typing too" do
    s = stall
    t = Time.instant
    s.opened(t)
    t += 1400.milliseconds
    s.saw(t, 7) # just under the burst threshold
    s.stalled?(t + 200.milliseconds).should be_true
  end

  it "stops timing once the paste is closed" do
    s = stall
    t = Time.instant
    s.opened(t)
    s.open?.should be_true
    s.closed
    s.open?.should be_false
    s.stalled?(t + 1.hour).should be_false
  end

  # A later paste has to be timed on its own merits — the object is reused for the whole session.
  it "times a second paste from its own start" do
    s = stall
    first = Time.instant
    s.opened(first)
    s.stalled?(first + 2.seconds).should be_true
    s.closed

    second = first + 10.minutes
    s.opened(second)
    s.stalled?(second).should be_false
    s.stalled?(second + 1500.milliseconds).should be_true
  end

  # Ticks that arrive with no paste open must not resurrect the clock.
  it "ignores ticks while no paste is open" do
    s = stall
    t = Time.instant
    s.saw(t, 100)
    s.open?.should be_false
    s.stalled?(t + 1.hour).should be_false
  end
end
