require "../spec_helper"

private alias F = Gori::Fuzz

# The rest of the "a hook runs when you SEND, not when you look" contract (#852), pinned by
# EXECUTION COUNT the way #851's regressions are — only a count tells these defects apart from
# correct behaviour. A hook that appends one line per run and passes stdin through, plus a
# reader for the tally.
private def with_counting_hook(&)
  dir = File.tempname("gori-fuzz852")
  Dir.mkdir_p(dir)
  path = File.join(dir, "h.sh")
  tally = File.join(dir, "tally")
  File.write(path, "#!/bin/sh\necho ran >> '#{tally}'\ncat\n")
  File.chmod(path, 0o755)
  begin
    yield({path, -> { File.exists?(tally) ? File.read(tally).lines.size : 0 }})
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

describe "the draw-vs-send hook contract (#852)" do
  # Item 1: a refusal decidable WITHOUT a side effect is decided before any side effect. Two
  # markers — one an `exec:` hook, one a pure chain that fails on its value — and the hook must
  # not have run by the time the pure failure would refuse the send.
  it "does not run a hook marker when a pure marker fails first" do
    with_counting_hook do |hook, runs|
      reg = Gori::Decoder.shared_registry
      positions = [
        F::Template::Position.new(0, "abc", "exec:#{hook}"),
        F::Template::Position.new(1, "!!not-base64!!", "base64-decode"),
      ]
      reported = F::Template.apply_chains_reported(positions,
        ["abc", "!!not-base64!!"], reg)
      # The pure chain's failure is reported…
      reported[1][1].should_not be_nil
      # …and the hook was NEVER forked, because the pure failure was known first.
      runs.call.should eq 0
      # Its position came back untransformed, with no reason — naming a command that was
      # deliberately not run as "failed" would read as "your command is broken".
      reported[0].should eq({"abc", nil})
    end
  end

  # The complement: with no pure failure, the deferred command DOES run — exactly once — and
  # its stdout is taken.
  it "runs the hook marker when no pure marker fails, exactly once" do
    with_counting_hook do |hook, runs|
      reg = Gori::Decoder.shared_registry
      positions = [
        F::Template::Position.new(0, "abc", "exec:#{hook}"),
        F::Template::Position.new(1, "aGk=", "base64-decode"), # valid → "hi"
      ]
      reported = F::Template.apply_chains_reported(positions, ["abc", "aGk="], reg)
      reported[1].should eq({"hi", nil})
      runs.call.should eq 1
      reported[0].should eq({"abc", nil}) # the hook passes stdin through
    end
  end

  # `run_hooks: false` — a DISPLAY replay — withholds the command step, so it forks nothing and
  # needs no deferral. A pure marker beside it still evaluates.
  it "withholds the hook marker entirely on a display replay" do
    with_counting_hook do |hook, runs|
      reg = Gori::Decoder.shared_registry
      positions = [
        F::Template::Position.new(0, "abc", "exec:#{hook}"),
        F::Template::Position.new(1, "aGk=", "base64-decode"),
      ]
      reported = F::Template.apply_chains_reported(positions, ["abc", "aGk="], reg,
        run_hooks: false)
      runs.call.should eq 0
      reported[1].should eq({"hi", nil}) # the pure step still ran
      # The withheld command reports its own withheld reason (it is not "broken").
      reported[0][1].should_not be_nil
    end
  end

  # Item 3: `Plan.build` asks `baseline_raw` three structural questions plus the ctor's fourth.
  # Memoized, it forks the operator's `exec:` command AT MOST ONCE for all of them, at plan
  # time, before the run sends a byte. On the pre-fix tree this was one fork per question.
  it "forks a hook at most once for Plan.build's structural questions" do
    with_counting_hook do |hook, runs|
      F::Plan.build(F::PlanOptions.new(
        "GET /q?a=§P¦exec:#{hook}§ HTTP/1.1\r\nHost: t.test\r\n\r\n",
        target: "http://t.test",
        sources: [F::InlineList.new(["x"])] of F::PayloadSource,
        config: F::Config.new(mode: F::Mode::BatteringRam)), ungated)
      runs.call.should eq 1
    end
  end

  # Item 4: `WsScript#apply_chains{,_reported}` accept and forward `run_hooks`, so a WS sweep's
  # `¦chain` withholds an `exec:` step on a display replay exactly as an HTTP one does.
  it "forwards run_hooks through WsScript#apply_chains" do
    with_counting_hook do |hook, runs|
      reg = Gori::Decoder.shared_registry
      handshake = F::Template.parse("GET /ws?a=§P¦exec:#{hook}§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
      script = F::WsScript.build(handshake, [] of F::FrameTemplate)
      script.apply_chains(["P"], reg, run_hooks: false)
      runs.call.should eq 0
      script.apply_chains(["P"], reg, run_hooks: true)
      runs.call.should eq 1
    end
  end
end
