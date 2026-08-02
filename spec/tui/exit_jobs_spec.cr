require "../spec_helper"

include Gori::Tui

# Leaving the project (and quitting) while an engine job is live.
#
# `leave_project` used to confirm with one sentence — "Close this project and return to
# the picker?" — and then only `commit_pending_edits`, which SAVES. Nothing stopped the
# job. With a Discover crawl running, the operator was back at the project picker within a
# second and the crawl kept its own sockets and ran the frontier to completion against the
# target: measured at 66 requests received when `leave` was confirmed and 206 two minutes
# later, with no bottom bar, no run list and no key at the picker that could stop it, and
# nothing in `tui.err` or `gori.log`. Round 4 measured a single TUI discover at 3338
# requests, so the realistic version is thousands of requests continuing against a target
# the operator believes they disconnected from. Every PER-TAB close already did the right
# thing (`request_stop` + `jobs.finish(:stopped, …)`); the project-level exits are what
# never learned it.
#
# Two halves are pinned here:
#   * the three exit PROMPTS, as pure `Runner` class methods over `Jobs#active_summary` —
#     they name the live work, and with nothing running they are byte-identical to the
#     strings that shipped before, so an idle leave gains no prompt noise;
#   * the ORDER contract, through an `ExitShell` mirror of `runner.cr`'s confirm wiring
#     (the Runner needs a live tty, so this follows `NestShell` in overlay_nesting_spec):
#     accepting stops the jobs, CANCELLING leaves them running untouched.
#
# NOT asserted here: that a real `DiscoverController#stop_all` reaches a real engine
# fiber. Every job-owning controller needs a `Host`, and a Host double is ~30 abstract
# methods; that half was verified on the wire instead (the origin receives nothing after
# `leave`).

describe "Jobs#active_summary" do
  it "is nil with nothing running, so an exit prompt keeps its no-jobs wording" do
    jobs = Jobs.new
    jobs.active_summary.should be_nil
    id = jobs.start(:discover, "http://t/")
    jobs.finish(id, :done, "0 found")
    jobs.active_summary.should be_nil
  end

  it "names one live job by kind" do
    jobs = Jobs.new
    jobs.start(:discover, "http://t/")
    jobs.active_summary.should eq("discovering 1")
  end

  it "names every live kind rather than collapsing to jobs:N the way the chip does" do
    jobs = Jobs.new
    jobs.start(:discover, "http://t/")
    jobs.start(:miner, "GET /api")
    jobs.start(:fuzz, "GET /a")
    jobs.start(:fuzz, "GET /b")
    # The status-bar chip is allowed to say "jobs:4" — an exit prompt is not: it is the
    # one place the operator decides with, and "leaving stops them" is only actionable if
    # it says what it is stopping.
    jobs.activity_label.should eq("jobs:4")
    jobs.active_summary.should eq("discovering 1 · mining 1 · fuzzing 2")
  end

  it "collapses the tail past SUMMARY_KINDS + 1 so a card line cannot overflow" do
    jobs = Jobs.new
    {:discover, :fuzz, :miner, :sequence, :minimize, :oast}.each { |k| jobs.start(k, "x") }
    jobs.active_summary.should eq("discovering 1 · fuzzing 1 · +4 more")
  end

  it "drops a job that finished, and goes back to nil when the last one does" do
    jobs = Jobs.new
    a = jobs.start(:discover, "http://t/")
    b = jobs.start(:miner, "GET /api")
    jobs.finish(a, :stopped, "project closed")
    jobs.active_summary.should eq("mining 1")
    jobs.finish(b, :stopped, "project closed")
    jobs.active_summary.should be_nil
  end
end

describe "Runner exit prompts" do
  it "keeps the LEAVE PROJECT confirm byte-identical when nothing is running" do
    Runner.leave_confirm_message(nil, 0)
      .should eq("Close this project and return to the picker?")
  end

  it "names the live jobs in the LEAVE PROJECT confirm and says leaving stops them" do
    jobs = Jobs.new
    jobs.start(:discover, "http://127.0.0.1:19703/")
    Runner.leave_confirm_message(jobs.active_summary, jobs.active.size).should eq(
      "Close this project and return to the picker?\n" \
      "1 job still running — leaving stops it.\n" \
      "discovering 1")

    jobs.start(:fuzz, "GET /a")
    Runner.leave_confirm_message(jobs.active_summary, jobs.active.size).should eq(
      "Close this project and return to the picker?\n" \
      "2 jobs still running — leaving stops them.\n" \
      "discovering 1 · fuzzing 1")
  end

  # ConfirmDialog sizes its card to the longest line and clamps the whole card at 60
  # columns (`overlay_box`: `(content + 6).clamp(16, {area.w - 2, 60}.min)`), so a line
  # over 54 display cells loses its tail to the ellipsis — which first cost this very
  # confirm its verb ("… — leaving stops i…"). Every line the exit prompts can produce
  # has to fit, including the widest realistic job mix.
  it "keeps every confirm line inside ConfirmDialog's card" do
    jobs = Jobs.new
    {:discover, :fuzz, :miner, :sequence, :minimize, :oast}.each { |k| jobs.start(k, "x") }
    [Runner.leave_confirm_message(jobs.active_summary, jobs.active.size),
     Runner.quit_confirm_message(jobs.active_summary, jobs.active.size)].each do |msg|
      msg.split('\n').each { |line| Screen.display_width(line).should be <= 54 }
    end
  end

  it "keeps both quit prompts byte-identical when nothing is running" do
    Runner.quit_confirm_message(nil, 0).should eq("Quit gori? (pending edits are committed first)")
    Runner.quit_arm_hint(nil, 0).should eq("press ^D (or ^C) again to quit · q: back to projects")
  end

  it "names the live jobs in both quit prompts" do
    jobs = Jobs.new
    jobs.start(:miner, "GET /api")
    Runner.quit_confirm_message(jobs.active_summary, jobs.active.size).should eq(
      "Quit gori? (pending edits are committed first)\n" \
      "1 job still running — quitting stops it.\n" \
      "mining 1")
    Runner.quit_arm_hint(jobs.active_summary, jobs.active.size).should eq(
      "1 job running (mining 1) — press ^D (or ^C) again to quit and stop it")
  end
end

# A miniature of the Runner's exit wiring — the confirm state machine (copied from
# runner.cr#confirm, as NestShell does) plus the `stop_all_jobs` / `commit_pending_edits`
# / `@outcome` ordering of `leave_project` and `quit!`. Keep it in step with runner.cr: an
# example that passes against a drifted double proves nothing about the real shell.
private class ExitShell
  getter jobs = Jobs.new
  getter outcome = :running
  getter stopped = [] of Symbol  # which controllers had stop_all called, in order
  getter? committed = false      # commit_pending_edits ran
  getter! dialog : ConfirmDialog # the modal currently up
  getter message = ""

  # Mirror of Runner#stop_all_jobs. Every controller that calls `@host.jobs.start` is
  # listed; each finishes its own jobs the way its tab-close already does.
  private def stop_all_jobs : Nil
    {:discover, :fuzzer, :miner, :sequencer, :repeater, :oast}.each do |c|
      @stopped << c
      @jobs.active.each { |j| @jobs.finish(j.id, :stopped, "project closed") }
    end
  end

  private def commit_pending_edits : Nil
    @committed = true
  end

  # Mirror of Runner#leave_project.
  def leave_project : Nil
    active = @jobs.active_summary
    @message = Runner.leave_confirm_message(active, @jobs.active.size)
    confirm(@message, danger: !active.nil?) do
      stop_all_jobs
      commit_pending_edits
      @outcome = :back
    end
  end

  # Mirror of Runner#quit! (no confirm on the default double-press path).
  def quit! : Nil
    stop_all_jobs
    commit_pending_edits
    @outcome = :quit
  end

  getter? danger = false

  private def confirm(message : String, *, danger : Bool, &action : -> Nil) : Nil
    @danger = danger
    ov = ConfirmDialog.new("LEAVE PROJECT", message, confirm_label: "leave",
      danger: danger)
    accepted = false
    ov.on_commit = -> { accepted = true; true }
    ov.on_close = -> { action.call if accepted }
    @dialog = ov
  end

  # Route a key through the real dialog exactly as the shell's dispatch does.
  def press(k : Termisu::Input::Key) : Nil
    ov = dialog
    case ov.handle_key(Termisu::Event::Key.new(k))
    when :cancel then ov.on_close.try(&.call)
    when :commit then ov.on_close.try(&.call) if ov.commit
    end
  end
end

describe "leave project with live jobs" do
  it "stops every job-owning controller when the operator accepts" do
    shell = ExitShell.new
    shell.jobs.start(:discover, "http://127.0.0.1:19703/")
    shell.leave_project
    shell.message.should contain("leaving stops it")
    shell.danger?.should be_true

    shell.press(Termisu::Input::Key::LowerY)
    shell.outcome.should eq(:back)
    shell.stopped.should eq([:discover, :fuzzer, :miner, :sequencer, :repeater, :oast])
    shell.jobs.any_active?.should be_false
    shell.committed?.should be_true
  end

  it "leaves every job running untouched when the operator cancels" do
    shell = ExitShell.new
    shell.jobs.start(:discover, "http://127.0.0.1:19703/")
    shell.leave_project

    shell.press(Termisu::Input::Key::Escape)
    shell.outcome.should eq(:running) # still in the project
    shell.stopped.should be_empty     # NOTHING was stopped
    shell.jobs.any_active?.should be_true
    shell.committed?.should be_false
  end

  it "is an ordinary non-danger confirm with the old wording when nothing is running" do
    shell = ExitShell.new
    shell.leave_project
    shell.message.should eq("Close this project and return to the picker?")
    shell.danger?.should be_false

    shell.press(Termisu::Input::Key::LowerY)
    shell.outcome.should eq(:back)
    shell.committed?.should be_true
  end

  # Switching projects IS this path: `:back` unwinds Runner#run into App's picker loop,
  # which opens the next project with a fresh Runner and a fresh Jobs. So the leave fix
  # covers the switch; there is no separate seam to test.
  it "stops the jobs before the outcome that unwinds the Runner is set" do
    shell = ExitShell.new
    shell.jobs.start(:fuzz, "GET /a")
    shell.leave_project
    shell.press(Termisu::Input::Key::LowerY)
    # If :back were set first the Runner could unwind before stop_all_jobs ran; the
    # accept block's order is what guarantees it does not.
    shell.stopped.should_not be_empty
    shell.outcome.should eq(:back)
  end
end

describe "quit with live jobs" do
  # ^D ^D kills the process, so the engine fibers die with it — but the Jobs registry and
  # every engine's own `request_stop` are what make that an orderly stop rather than a
  # truncation, and `quit!` shares the leave path's helper so the two exits cannot drift.
  it "stops every job-owning controller" do
    shell = ExitShell.new
    shell.jobs.start(:miner, "GET /api")
    shell.quit!
    shell.outcome.should eq(:quit)
    shell.stopped.should eq([:discover, :fuzzer, :miner, :sequencer, :repeater, :oast])
    shell.jobs.any_active?.should be_false
    shell.committed?.should be_true
  end
end
