require "../spec_helper"

private alias RM = Gori::RequestMacro

# A source that answers from a script instead of the network, so the gate can be judged alone.
private class FakeSource < RM::Source
  getter runs = 0
  getter notes = [] of String
  # 1-based run numbers that fail / that run the budget dry.
  property fail_on = Set(Int32).new
  property exhaust_on = Set(Int32).new
  property delay : Time::Span = Time::Span.zero
  property on_run : Proc(Int32, Nil)? = nil

  def run(budget : RM::Budget?, pacer : Proc(Nil)?, cancelled : Proc(Bool)? = nil) : RM::Outcome
    @runs += 1
    n = @runs
    on_run.try &.call(n)
    sleep @delay if @delay > Time::Span.zero
    return RM::Outcome.new(false, 1, 0, 1, "login", 403, "the step answered 403") if @fail_on.includes?(n)
    return RM::Outcome.new(false, 1, 0, 1, "login", nil, RM::BUDGET_ERROR, budget_exhausted: true) if @exhaust_on.includes?(n)
    RM::Outcome.new(true, 1, 1, rebound: ["CSRF"])
  end

  def labels : Array(String)
    ["csrf-fetch"]
  end

  def note(source : String, kind : String, level : Symbol, message : String, flow_id : Int64? = nil) : Nil
    @notes << "#{source}/#{kind}/#{level}"
  end
end

private class ThreeStepSource < FakeSource
  def labels : Array(String)
    ["a", "b", "c"]
  end
end

private def lane_for(source : FakeSource, every : Int32 = 1, on_failure : RM::OnFailure = RM::OnFailure::Skip,
                     cancelled : Proc(Bool)? = nil) : RM::Lane
  spec = RM::Spec.new(["1"], RM::Cadence.new(every), on_failure)
  RM::Lane.new(spec, source, "fuzzer").attach(nil, nil, cancelled)
end

describe Gori::RequestMacro::Lane do
  describe "every request" do
    it "runs the steps before each candidate, and lets a candidate see the value its own run left" do
      source = FakeSource.new
      lane = lane_for(source, 1)
      seen = [] of Int32
      4.times { lane.around { |entry| entry.send?.should be_true; seen << source.runs } }
      seen.should eq([1, 2, 3, 4])
      lane.tally.runs.should eq(4)
      lane.tally.requests.should eq(4)
    end

    it "never lets two candidates overlap, however many workers there are" do
      source = FakeSource.new
      lane = lane_for(source, 1)
      inflight = 0
      peak = 0
      values = [] of Int32
      done = Channel(Nil).new
      12.times do
        spawn do
          lane.around do |_|
            inflight += 1
            peak = Math.max(peak, inflight)
            values << source.runs
            sleep 2.milliseconds # a slow candidate: the next one must wait for it
            inflight -= 1
          end
        ensure
          done.send(nil)
        end
      end
      12.times { done.receive }
      peak.should eq(1)
      # No two candidates carried one run's value.
      values.uniq.size.should eq(12)
      source.runs.should eq(12)
    end
  end

  describe "every N" do
    it "runs the steps once per N candidates, in order" do
      source = FakeSource.new
      lane = lane_for(source, 3)
      seen = [] of Int32
      7.times { lane.around { |_| seen << source.runs } }
      seen.should eq([1, 1, 1, 2, 2, 2, 3])
      source.runs.should eq(3)
    end

    it "shares a value among concurrent candidates of an epoch and never mixes epochs" do
      source = FakeSource.new
      lane = lane_for(source, 3)
      window = [] of {Int32, Time::Instant, Time::Instant}
      done = Channel(Nil).new
      9.times do
        spawn do
          lane.around do |_|
            t0 = Time.instant
            run = source.runs
            sleep 3.milliseconds
            window << {run, t0, Time.instant}
          end
        ensure
          done.send(nil)
        end
      end
      9.times { done.receive }
      source.runs.should eq(3)
      by_run = window.group_by(&.[0])
      by_run.keys.sort!.should eq([1, 2, 3])
      by_run.each_value(&.size.should(eq(3)))
      # Epoch k+1's first candidate starts only after every candidate of epoch k has finished.
      [1, 2].each do |k|
        finished = by_run[k].max_of(&.[2])
        started = by_run[k + 1].min_of(&.[1])
        (started >= finished).should be_true
      end
    end

    it "opens no epoch on a failed run, so the next candidate tries again" do
      source = FakeSource.new
      source.fail_on = Set{1}
      lane = lane_for(source, 3)
      first = lane.enter
      first.refused?.should be_true
      first.send?.should be_false
      first.error.should start_with("#{RM::ERROR_PREFIX}failed at step 1 (login → 403)")
      first.error.should contain("the candidate was not sent")
      first.leave
      second = lane.enter
      second.send?.should be_true
      second.leave
      source.runs.should eq(2)
    end
  end

  describe "failure" do
    it "counts a failed run, files one event, and skips the candidate" do
      source = FakeSource.new
      source.fail_on = Set{2}
      lane = lane_for(source, 1)
      lane.around(&.send?.should(be_true))
      lane.around(&.send?.should(be_false))
      lane.around(&.send?.should(be_true))
      t = lane.tally
      {t.runs, t.failed, t.skipped}.should eq({3_i64, 1_i64, 1_i64})
      t.first_error.not_nil!.should contain("login → 403")
      source.notes.should eq(["fuzzer/macro_failed/warn"])
      lane.aborted?.should be_false
    end

    it "ends the run after FAILURE_LIMIT failures in a row, and not for failures that are not in a row" do
      source = FakeSource.new
      source.fail_on = Set{1, 2, 4, 5, 6}
      lane = lane_for(source, 1)
      lane.around { |_| }
      lane.around { |_| }
      lane.aborted?.should be_false
      lane.around { |_| } # run 3 succeeds and resets the streak
      lane.around { |_| }
      lane.around { |_| }
      lane.aborted?.should be_false
      lane.around { |_| } # third in a row
      lane.aborted?.should be_true
      lane.abort_reason.not_nil!.should contain("#{RM::Lane::FAILURE_LIMIT} failures in a row")
      source.notes.last.should eq("fuzzer/macro_aborted/warn")
    end

    it "ends the run on the first failure under stop" do
      source = FakeSource.new
      source.fail_on = Set{1}
      lane = lane_for(source, 1, RM::OnFailure::Stop)
      lane.around(&.refused?.should(be_true))
      lane.aborted?.should be_true
      lane.abort_reason.not_nil!.should contain("stop the run on a failure")
    end

    it "refuses every candidate after the run was ended, without running the steps again" do
      source = FakeSource.new
      source.fail_on = Set{1}
      lane = lane_for(source, 1, RM::OnFailure::Stop)
      lane.around { |_| }
      runs = source.runs
      e = lane.enter
      e.refused?.should be_true
      e.error.should eq("#{RM::ERROR_PREFIX}an earlier failure ended the run — the candidate was not sent")
      e.leave
      source.runs.should eq(runs)
      lane.tally.skipped.should eq(2)
    end

    it "caps the events a dead login endpoint can write" do
      source = FakeSource.new
      source.fail_on = (1..40).to_set
      spec = RM::Spec.new(["1"], RM::Cadence.request, RM::OnFailure::Skip)
      lane = RM::Lane.new(spec, source, "miner").attach(nil, nil, nil)
      # The streak limit ends the run at 3, so restart the streak by hand: a fresh lane per 2.
      40.times do
        e = lane.enter
        e.leave
        break if lane.aborted?
      end
      source.notes.count(&.includes?("macro_failed")).should be <= RM::Lane::EVENT_CAP
    end

    it "treats a spent budget as the run ending, not as the macro breaking" do
      source = FakeSource.new
      source.exhaust_on = Set{1}
      lane = lane_for(source, 1)
      e = lane.enter
      e.refused?.should be_true
      e.error.should eq(RM::BUDGET_ERROR)
      RM.failed?(e.error).should be_false
      e.leave
      t = lane.tally
      {t.failed, t.skipped}.should eq({0_i64, 0_i64})
      lane.aborted?.should be_false
      source.notes.should be_empty
    end

    it "turns a source that raises into a failed run rather than an exception in the worker" do
      source = FakeSource.new
      source.on_run = ->(_n : Int32) { raise "boom" }
      lane = lane_for(source, 1)
      e = lane.enter
      e.refused?.should be_true
      e.error.should contain("the macro raised")
      e.leave
    end
  end

  describe "stop" do
    it "admits nothing and runs nothing once the run was stopped" do
      source = FakeSource.new
      stopped = false
      lane = lane_for(source, 1, cancelled: -> { stopped })
      lane.around(&.send?.should(be_true))
      stopped = true
      e = lane.enter
      e.cancelled?.should be_true
      e.send?.should be_false
      e.refused?.should be_false
      e.leave
      source.runs.should eq(1)
    end

    it "drops a candidate that reaches the gate inside an open epoch after the stop, too" do
      source = FakeSource.new
      stopped = false
      lane = lane_for(source, 3, cancelled: -> { stopped })
      lane.around(&.send?.should(be_true)) # opens an epoch of 3; two slots left
      stopped = true
      e = lane.enter
      e.cancelled?.should be_true
      e.send?.should be_false
      e.leave
      source.runs.should eq(1)
    end

    it "does not run the next epoch's steps when a stop lands while it waits for the previous one" do
      source = FakeSource.new
      stopped = false
      lane = lane_for(source, 1, cancelled: -> { stopped })
      holder = lane.enter # epoch 1 is open and in flight
      got = Channel(RM::Lane::Entry).new
      spawn { got.send(lane.enter) }
      Fiber.yield
      stopped = true
      holder.leave
      e = got.receive
      e.cancelled?.should be_true
      e.leave
      source.runs.should eq(1)
    end
  end

  describe "the plan-time line" do
    it "says a per-request macro serialises the run" do
      info = lane_for(FakeSource.new, 1).info(20)
      info.concurrency.should eq(1)
      info.line.should contain("csrf-fetch")
      info.line.should contain("before every request")
      info.line.should contain("one candidate at a time")
      info.line.should contain("on failure: skip the candidate")
    end

    it "bounds the parallelism of a shared value by the epoch" do
      lane_for(FakeSource.new, 4).info(20).concurrency.should eq(4)
      lane_for(FakeSource.new, 4).info(2).concurrency.should eq(2)
      lane_for(FakeSource.new, 4).info(20).line.should contain("shared by up to 4 candidates")
    end

    it "says a race group shares the value" do
      info = lane_for(FakeSource.new, 5).info(20, race: 5)
      info.line.should contain("all 5 members share it")
    end
  end

  describe "macro_requests" do
    it "counts one run of the steps per epoch, rounded up" do
      lane_for(FakeSource.new, 1).macro_requests(10_i64).should eq(10)
      lane_for(FakeSource.new, 4).macro_requests(10_i64).should eq(3)
      lane_for(FakeSource.new, 4).macro_requests(8_i64).should eq(2)
      lane_for(FakeSource.new, 4).macro_requests(0_i64).should eq(0)
    end

    it "multiplies by the steps, and is 0 for a run of unknown size and saturates for a huge one" do
      lane = RM::Lane.new(RM::Spec.new(["a", "b", "c"], RM::Cadence.request), ThreeStepSource.new).attach(nil, nil, nil)
      lane.macro_requests(4_i64).should eq(12)
      lane.macro_requests(nil).should eq(0)
      lane.macro_requests(Int64::MAX).should eq(Int64::MAX)
    end
  end

  describe "Tally#summary" do
    it "counts the runs and the requests, and adds the failures only when there were some" do
      RM::Tally.new(12_i64, 0_i64, 0_i64, 12_i64).summary.should eq("12 runs · 12 requests")
      RM::Tally.new(1_i64, 0_i64, 0_i64, 1_i64).summary.should eq("1 run · 1 request")
    end

    it "names the failure that started it" do
      t = RM::Tally.new(5_i64, 2_i64, 2_i64, 5_i64, "macro failed at step 1 (csrf-fetch → 500)")
      t.summary.should eq("5 runs · 5 requests · 2 failed · 2 candidates not sent — first failure: macro failed at step 1 (csrf-fetch → 500)")
    end
  end
end
