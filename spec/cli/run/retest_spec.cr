require "../../spec_helper"

# `gori run retest` — the headless half of an Issue's reproducible check (#1036). The
# `abort` branches call `exit`, so only the pure renderers run here; the engine's rules are
# spec/retest_spec.cr's and the store's are spec/store/issue_retest_spec.cr's.
#
# What these pin is the SURFACE's own contract: every row says what it will send and whether
# it can run at all, and the run report reads the same way whether it came off the wire or
# out of the store.

module Gori::CLI::Run
  def self.retest_step_line_for_spec(pl : Gori::Retest::Planned) : String
    retest_step_line(pl)
  end

  def self.retest_run_line_for_spec(r : Gori::Store::RetestRun) : String
    retest_run_line(r)
  end

  def self.retest_result_line_for_spec(position : Int32, role : Gori::Store::RetestRole, label : String,
                                       assertion : String, outcome : Gori::Store::RetestOutcome,
                                       detail : String, flow_id : Int64?) : String
    retest_result_line(position, role, label, assertion, outcome, detail, flow_id)
  end

  def self.retest_assert_help_for_spec : String
    retest_assert_help
  end

  def self.retest_roles_for_spec : String
    retest_roles
  end
end

private def planned(assertion : String = "status:200", method : String = "GET",
                    missing : String? = nil) : Gori::Retest::Planned
  step = Gori::Store::RetestStep.new(4_i64, 1_i64, 2, Gori::Store::RetestRole::Baseline,
    Gori::Store::LinkRefKind::Repeater, 9_i64, assertion, 0_i64, 0_i64)
  Gori::Retest::Planned.new(step, method, "https://acme.test/me", "login", missing)
end

describe "gori run retest" do
  it "prints a step's position, its STEP id, role, source and what it will send" do
    # Both numbers are on the row on purpose: `position` is what `move --to` takes and
    # `[id]` is what `update`/`remove` take, and a listing that showed only one of them
    # would send the operator to the wrong flag.
    line = Gori::CLI::Run.retest_step_line_for_spec(planned)
    line.should start_with("2  [4]  baseline")
    line.should contain("repeater #9")
    line.should contain("GET https://acme.test/me")
    line.should contain("expect status:200")
  end

  it "says a step has no assertion rather than printing an empty expectation" do
    Gori::CLI::Run.retest_step_line_for_spec(planned(assertion: "")).should contain("(no assertion)")
  end

  it "names the reason a step cannot run, on the row" do
    line = Gori::CLI::Run.retest_step_line_for_spec(planned(missing: "repeater #9 no longer exists"))
    line.should contain("— repeater #9 no longer exists")
  end

  it "prints a run's verdict, surface and per-outcome counts on one line" do
    run = Gori::Store::RetestRun.new(7_i64, 1_i64, 1_700_000_000_000_000_i64,
      1_700_000_001_000_000_i64, "cli", Gori::Store::RetestVerdict::Fail, 4, 2, 1, 0, 0, 0, 1)
    line = Gori::CLI::Run.retest_run_line_for_spec(run)
    line.should start_with("#7  ")
    line.should contain("cli")
    line.should contain("FAIL")
    line.should contain("4 steps · 2 passed · 1 failed · 1 skipped")
  end

  it "prints a result row with the History flow its own send recorded" do
    line = Gori::CLI::Run.retest_result_line_for_spec(1, Gori::Store::RetestRole::Variant,
      "victim order", "status:403", Gori::Store::RetestOutcome::Fail,
      "status 200, expected 403", 12_i64)
    line.should contain("variant")
    line.should contain("FAIL")
    line.should contain("expect status:403")
    line.should contain("→ status 200, expected 403")
    line.should contain("flow #12")
  end

  it "leaves the flow column off a step whose send was not recorded" do
    line = Gori::CLI::Run.retest_result_line_for_spec(1, Gori::Store::RetestRole::Cleanup,
      "undo", "", Gori::Store::RetestOutcome::Skipped, "cleanup not run after a refused send", nil)
    line.should contain("expect —")
    line.should_not contain("flow #")
  end

  it "offers the same assertion grammar the parser accepts, and every role" do
    # ONE list (`Assertion::FORMS`), so the CLI help cannot advertise a spelling `parse`
    # refuses — or omit one it takes.
    help = Gori::CLI::Run.retest_assert_help_for_spec
    Gori::Retest::Assertion::FORMS.each { |f| help.should contain(f) }
    roles = Gori::CLI::Run.retest_roles_for_spec
    Gori::Store::RetestRole.values.each { |r| roles.should contain(r.label) }
  end

  it "keeps every verb reachable, `forget` included" do
    # The dispatch's unknown-subcommand message is the list an operator reads after a typo,
    # so a verb missing from it is a verb they are told does not exist.
    Gori::CLI::Run::RETEST_VERBS.should contain("forget")
    Gori::CLI::Run::RETEST_VERBS.should contain("remove/rm")
  end

  it "is registered as a `gori run` subcommand with its verbs in the help table" do
    names = Gori::CLI::Run::SUBCOMMANDS.map(&.[0])
    names.should contain("retest (steps)")
    names.should contain("retest run")
  end
end
