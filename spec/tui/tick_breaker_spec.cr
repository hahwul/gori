require "../spec_helper"

include Gori::Tui

# The run loop's tick-error breaker, pinned through the class the loop defers the tally to
# (`Runner.new` owns a terminal, so `absorb_tick_error` itself cannot run under spec). The
# policy of which raises count lives in the Runner; the arithmetic is here.
describe TickBreaker do
  it "trips on the limit-th strike inside the window, and not before" do
    b = TickBreaker.new(3, 10.seconds)
    t0 = Time.instant
    b.record(t0).should eq(1)
    b.tripped?(t0).should be_false
    b.record(t0 + 1.second).should eq(2)
    b.tripped?(t0 + 1.second).should be_false
    b.record(t0 + 2.seconds).should eq(3)
    b.tripped?(t0 + 2.seconds).should be_true
  end

  it "forgets strikes older than the window, so a raise every few minutes never accumulates" do
    b = TickBreaker.new(3, 10.seconds)
    t0 = Time.instant
    b.record(t0)
    b.record(t0 + 1.second)
    # 11s later the first two are outside the window: this is strike ONE of a new run.
    b.record(t0 + 12.seconds).should eq(1)
    b.tripped?(t0 + 12.seconds).should be_false
  end

  it "reads the window at the moment it is asked, not at the last strike" do
    b = TickBreaker.new(2, 10.seconds)
    t0 = Time.instant
    b.record(t0)
    b.record(t0 + 1.second)
    b.tripped?(t0 + 1.second).should be_true
    b.tripped?(t0 + 30.seconds).should be_false # both have aged out
  end

  it "resets" do
    b = TickBreaker.new(1, 10.seconds)
    b.record(Time.instant)
    b.tripped?.should be_true
    b.reset
    b.tripped?.should be_false
  end
end
