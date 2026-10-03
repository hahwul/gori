require "./spec_helper"

private class PaceConfig
  getter rps : Float64?
  getter throttle_ms : Int32?
  getter jitter_ms : Int32

  def initialize(@rps = nil, @throttle_ms = nil, @jitter_ms = 0)
  end
end

# Stands in for an engine: one shared clock, a `pace` reachable from several fibers.
private class PaceHarness
  include Gori::Pacing

  getter stamps = [] of Time::Instant
  property? stopped = false

  def initialize(@config : PaceConfig)
    @last_dispatch = Time.instant
  end

  # What a send site does: wait for the rate, then "send" unless the run stopped meanwhile.
  def send_one : Nil
    @stamps << Time.instant if pace(pace_interval)
  end
end

describe Gori::Pacing do
  # The operator-facing knob is `--rate=RPS "Cap requests/sec"` — a promise about REQUESTS.
  # `pace` therefore has to hold across every fiber that sends, not just the orchestrator's
  # dispatch loop, because the paths that fan one dispatched unit into several sends (a
  # redirect chain, a confirm round, a calibration batch) are exactly where the promise broke.
  it "serialises concurrent senders onto one rate instead of letting them burst" do
    h = PaceHarness.new(PaceConfig.new(throttle_ms: 20))
    done = Channel(Nil).new(5)
    5.times do
      spawn do
        h.send_one
        done.send(nil)
      end
    end
    5.times { done.receive }

    h.stamps.size.should eq(5)
    span = h.stamps.max - h.stamps.min
    # Five senders at one per 20ms: the last must land at least 4 intervals after the first.
    # A per-fiber (or last-writer-wins) clock lets them all fire at once and this is ~0.
    span.should be >= 70.milliseconds
  end

  it "does not sleep at all when no rate is configured" do
    h = PaceHarness.new(PaceConfig.new)
    started = Time.instant
    10.times { h.send_one }
    (Time.instant - started).should be < 50.milliseconds
  end

  # After an idle stretch the stored instant is far in the past. Without flooring the claim at
  # `now`, every caller computes a target that already elapsed and they all go out together —
  # the opposite of a rate limit.
  it "does not bank up credit while idle and release it as a burst" do
    h = PaceHarness.new(PaceConfig.new(throttle_ms: 15))
    h.send_one
    sleep 120.milliseconds # idle far longer than the interval

    done = Channel(Nil).new(3)
    3.times { spawn { h.send_one; done.send(nil) } }
    3.times { done.receive }

    burst = h.stamps[1..]
    (burst.max - burst.min).should be >= 25.milliseconds
  end

  # A `--rate` of 1e-9 is a gap of MAX_INTERVAL_SECONDS; one unsliced sleep held a stopped
  # run "running" for a day.
  it "ends a long wait once the run is stopped" do
    h = PaceHarness.new(PaceConfig.new(throttle_ms: 600_000))
    h.send_one # claims the first slot; the next is ten minutes out
    spawn { sleep 50.milliseconds; h.stopped = true }
    started = Time.instant
    h.send_one
    (Time.instant - started).should be < 2.seconds
    h.stamps.size.should eq(1) # the slot it waited for is not a send to make
  end
end
