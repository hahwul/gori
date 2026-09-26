require "../../spec_helper"

# `gori run fuzz`'s "every send errored" exit 1 — the rule a scripted `… || die` reads as
# "target down". A met `--stop-on` is the run reaching its goal: a `time:>=N` condition is met
# by a TIMED-OUT send, which the run's own matcher leaves an unmatched error row.
describe "Gori::CLI::Run.fuzz_every_send_errored?" do
  it "does not call a met stop condition a dead target" do
    # `--stop-on 'time:>=5000' --timeout 5 -c 1`: the first payload hangs, the condition is met.
    Gori::CLI::Run.fuzz_every_send_errored?(0, 1, 1_i64, condition_met: true).should be_false
  end

  it "still fails a run whose every send errored with nothing matched" do
    Gori::CLI::Run.fuzz_every_send_errored?(0, 3, 3_i64, condition_met: false).should be_true
  end

  it "passes a run with a match, a clean send, or no sends at all" do
    Gori::CLI::Run.fuzz_every_send_errored?(1, 2, 3_i64, condition_met: false).should be_false
    Gori::CLI::Run.fuzz_every_send_errored?(0, 2, 3_i64, condition_met: false).should be_false
    Gori::CLI::Run.fuzz_every_send_errored?(0, 0, 0_i64, condition_met: false).should be_false
    Gori::CLI::Run.fuzz_every_send_errored?(0, 1, nil, condition_met: false).should be_false
  end
end
