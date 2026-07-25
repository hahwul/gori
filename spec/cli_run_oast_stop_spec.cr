require "./spec_helper"

# Test seam: oast_wait_or_stop is a private module method; expose a thin caller within
# the same namespace (test binary only) so Fix #6's stop mechanism can be tested
# without installing a real signal trap or delivering SIGINT to the spec runner.
module Gori::CLI::Run
  def self.spec_oast_wait_or_stop(stop : Channel(Nil), interval : Time::Span) : Bool
    oast_wait_or_stop(stop, interval)
  end
end

# Fix #6 — `gori run oast listen` ignored Ctrl-C: the poll loop trapped no signals and
# only SIGTERM/SIGKILL stopped it. INT/TERM now send to a channel that oast_wait_or_stop
# selects on, so a stop breaks the loop promptly instead of waiting out the interval.
describe "Gori::CLI::Run.oast_wait_or_stop" do
  it "returns true immediately when a stop is already signalled (interrupt the sleep)" do
    stop = Channel(Nil).new(1)
    stop.send(nil) # simulate the INT/TERM trap firing
    # A long interval proves it doesn't wait it out: it must wake on the channel.
    Gori::CLI::Run.spec_oast_wait_or_stop(stop, 30.seconds).should be_true
  end

  it "returns false on timeout when no stop arrives (keep polling)" do
    stop = Channel(Nil).new(1)
    Gori::CLI::Run.spec_oast_wait_or_stop(stop, 1.milliseconds).should be_false
  end
end
