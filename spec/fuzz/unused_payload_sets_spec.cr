require "../spec_helper"

private alias F = Gori::Fuzz

# `Fuzz::Plan#unused_payload_sets` — the count of payload sets a run was handed and will
# never draw from.
#
# `Generator`'s set contract discards silently by construction: Sniper and BatteringRam read
# `@sets[0]` and nothing else, and Pitchfork / ClusterBomb map set k to position k, so any set
# past `position_count` is never opened. `-w users.txt -w passwords.txt` under the DEFAULT mode
# therefore swept `users.txt` into both positions and reported `N sent · 0 errors` — a run that
# looks exactly like the one that was asked for and tested half of it. A missing wordlist in a
# dropped slot did not even raise, because nothing ever opened it (pinned below).
#
# The count is the fact; each surface words its own remedy (`gori run fuzz` on stderr, MCP's
# `payload_sets_warning`, the TUI's run-start line), which is why this spec asserts the number
# and not a sentence.
private ONE_POS = "GET /a?x=§1§ HTTP/1.1\r\nHost: t.test\r\n\r\n"
private TWO_POS = "GET /a?x=§1§&y=§2§ HTTP/1.1\r\nHost: t.test\r\n\r\n"

private def unused(text : String, mode : F::Mode, sets : Int32) : Int32
  sources = Array(F::PayloadSource).new(sets) { |k| F::InlineList.new(["p#{k}"]).as(F::PayloadSource) }
  config = F::Config.new(mode: mode, concurrency: 1)
  options = F::PlanOptions.new(text, target: "http://t.test", sources: sources,
    config: config, matcher: F::Matcher.new(keep_bodies: :none))
  F::Plan.build(options, ungated_outbound).unused_payload_sets
end

describe "Fuzz::Plan#unused_payload_sets" do
  it "counts the sets Sniper and BatteringRam drop — they read set 0 and nothing else" do
    # The reported defect verbatim: two wordlists, default mode, second one never opened.
    unused(TWO_POS, F::Mode::Sniper, 2).should eq(1)
    unused(TWO_POS, F::Mode::Sniper, 3).should eq(2)
    unused(TWO_POS, F::Mode::BatteringRam, 2).should eq(1)
    # ...and stays 0 for the shape those modes are for, however many positions are marked.
    unused(TWO_POS, F::Mode::Sniper, 1).should eq(0)
    unused(ONE_POS, F::Mode::BatteringRam, 1).should eq(0)
  end

  it "counts the sets the per-position modes drop past the last marked position" do
    unused(TWO_POS, F::Mode::Pitchfork, 3).should eq(1)
    unused(TWO_POS, F::Mode::ClusterBomb, 4).should eq(2)
    unused(ONE_POS, F::Mode::Pitchfork, 2).should eq(1)
  end

  it "reports nothing when a per-position mode consumes every set" do
    unused(TWO_POS, F::Mode::Pitchfork, 2).should eq(0)
    unused(TWO_POS, F::Mode::ClusterBomb, 2).should eq(0)
    # FEWER sets than positions is the documented `Generator#set_for` fallback (set 0 fills the
    # rest) and not a discard — nothing was thrown away, so there is nothing to report.
    unused(TWO_POS, F::Mode::Pitchfork, 1).should eq(0)
  end

  it "opens no dropped wordlist — which is why the discard was silent" do
    # A set Sniper will never draw from is never opened, so a bad path in it raises nothing:
    # the plan builds, the run sends, and the operator hears about neither. The count is the
    # only signal there can be, so it has to be right on exactly this input.
    sources = [
      F::InlineList.new(["real"]).as(F::PayloadSource),
      F::WordlistFile.new("/nonexistent/definitely-not-here.txt").as(F::PayloadSource),
    ]
    options = F::PlanOptions.new(ONE_POS, target: "http://t.test", sources: sources,
      config: F::Config.new(mode: F::Mode::Sniper, concurrency: 1),
      matcher: F::Matcher.new(keep_bodies: :none))
    plan = F::Plan.build(options, ungated_outbound)
    plan.unused_payload_sets.should eq(1)
    plan.total.should eq(1_i64) # counted off set 0 alone — the missing file was never touched
  end
end
