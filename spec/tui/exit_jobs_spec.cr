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

  # The confirm is still byte-identical to what shipped. THE ARM HINT'S ASSERTION CHANGED,
  # deliberately: it used to end "· q: back to projects" unconditionally, but `app.back-key`
  # is registered in Verb::Scope::Sidebar ONLY (verbs/core.cr — as a Global chord it dumped
  # you to the picker from mid-browse), while the arm is raised by `handle_key`, which is
  # focus-blind. So the toast advertised a key that is dead in a list body, types a literal
  # `q` in an editor, and CLOSES THE DETAIL in the History drill-in (detail.close binds q
  # too). The clause now has to be asked for — see the scope example below.
  it "keeps the quit confirm byte-identical when nothing is running, and offers q only on request" do
    Runner.quit_confirm_message(nil, 0).should eq("Quit gori? (pending edits are committed first)")
    Runner.quit_arm_hint(nil, 0).should eq("press ^D (or ^C) again to quit")
    Runner.quit_arm_hint(nil, 0, back_key: true)
      .should eq("press ^D (or ^C) again to quit · q: back to projects")
  end

  # What `back_key` has to be told, resolved through the real registry + keymap — the same
  # lookup `Runner#back_key_live?` performs. If `q` ever becomes Global (or a scope gains its
  # own binding) this example is what says whether the hint may name it.
  it "offers q exactly where app.back-key resolves, and nowhere else" do
    keymap = Gori::Verb::Keymap.build(Gori::Verbs.registry)
    q = Gori::Verb::Chord.new("q")
    {
      Gori::Verb::Scope::Sidebar       => "app.back-key", # the tab bar — where "q projects" is hinted
      Gori::Verb::Scope::HistoryDetail => "detail.close", # q is BOUND here, to something else
      Gori::Verb::Scope::Body          => nil,            # a list body: q does nothing at all
      Gori::Verb::Scope::Repeater      => nil,            # an editor: q is a literal char
    }.each do |scope, id|
      keymap.lookup(q, scope).should eq(id)
      live = id == "app.back-key"
      Runner.quit_arm_hint(nil, 0, back_key: live).includes?("q: back to projects").should eq(live)
    end
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

# The quit POLICY both entry points consume — `handle_key`'s ^C/^D (chord: true) and
# `Runner#quit!` (chord: false), which is the intent the palette's "Quit gori" verb
# dispatches. They used to answer this question in two places and disagree: the chord
# honoured settings:general "Confirm before quit" and the palette went straight to the
# teardown — stop_all_jobs / commit_pending_edits / outcome — with no modal, on the ONLY
# discoverable quit in the app (Hotkeys::FIXED_IDS keeps the chord off the rebind list
# because "single-key quit is a footgun"). A live Discover crawl or Fuzz run died unnamed
# and unasked, while `leave_project` — one row above it in the same palette, and less
# destructive — always confirms and names the jobs.
describe "Runner.quit_decision" do
  it "confirms a palette quit when 'Confirm before quit' is on — the bug this pins" do
    Runner.quit_decision(true, chord: false, armed: false).should eq(Runner::QuitAction::Confirm)
  end

  # The setting's text is unconditional ("require a confirm modal to quit") and
  # quit_confirm_message(nil, 0) is written for the idle case: a guarantee that only holds
  # while a job happens to be running is not one, and quitting idle still commits pending
  # edits and drops the session.
  it "confirms with the setting on from either path, armed or not, jobs or not" do
    [true, false].each do |armed|
      Runner.quit_decision(true, chord: true, armed: armed).should eq(Runner::QuitAction::Confirm)
      Runner.quit_decision(true, chord: false, armed: armed).should eq(Runner::QuitAction::Confirm)
    end
  end

  # Only a keystroke can arm. The arm is a typo guard for a chord under the fingers, and its
  # toast reads "press ^D (or ^C) again" — a chord the palette operator never pressed; ^P,
  # a filter and ↵ on a row that reads "Quit gori" is already that second deliberate act.
  it "keeps the chord's double press when the setting is off, and does not arm the palette" do
    Runner.quit_decision(false, chord: true, armed: false).should eq(Runner::QuitAction::Arm)
    Runner.quit_decision(false, chord: true, armed: true).should eq(Runner::QuitAction::Quit)
    Runner.quit_decision(false, chord: false, armed: false).should eq(Runner::QuitAction::Quit)
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

  # Mirror of Runner#quit! — the GUARDED entry, which is the whole point of it: the palette's
  # "Quit gori" verb dispatches this same intent (verbs/core.cr → ctx.quit!), so whatever
  # guard lives here is the guard the only discoverable quit gets. The teardown is
  # `finish_quit`, and the confirm's accept block calls THAT — routing it back through `quit!`
  # would re-raise the confirm forever. The policy call is the real `Runner.quit_decision`,
  # not a re-decision, so this double cannot drift from the shell on the question that matters.
  def quit! : Nil
    if Runner.quit_decision(Gori::Settings.confirm_quit?, chord: false, armed: false).confirm?
      @message = Runner.quit_confirm_message(@jobs.active_summary, @jobs.active.size)
      confirm(@message, danger: true, title: "QUIT GORI", label: "quit") { finish_quit }
    else
      finish_quit
    end
  end

  private def finish_quit : Nil
    stop_all_jobs
    commit_pending_edits
    @outcome = :quit
  end

  getter? danger = false

  private def confirm(message : String, *, danger : Bool, title : String = "LEAVE PROJECT",
                      label : String = "leave", &action : -> Nil) : Nil
    @danger = danger
    ov = ConfirmDialog.new(title, message, confirm_label: label,
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

# `Settings.confirm_quit` is a process-global class_property?: flipping it without putting
# it back leaks into every later example in the same `crystal spec` run. Same capture/restore
# idiom as settings_view_spec.cr:465.
private def with_confirm_quit(on : Bool, &)
  prev = Gori::Settings.confirm_quit?
  Gori::Settings.confirm_quit = on
  begin
    yield
  ensure
    Gori::Settings.confirm_quit = prev
  end
end

describe "quit with live jobs" do
  # ^D ^D kills the process, so the engine fibers die with it — but the Jobs registry and
  # every engine's own `request_stop` are what make that an orderly stop rather than a
  # truncation, and `quit!` shares the leave path's helper so the two exits cannot drift.
  # Pinned to the DEFAULT setting (confirm_quit off) now that `quit!` is confirm-gated:
  # this example is about the teardown, and the gate has its own block below.
  it "stops every job-owning controller" do
    with_confirm_quit(false) do
      shell = ExitShell.new
      shell.jobs.start(:miner, "GET /api")
      shell.quit!
      shell.outcome.should eq(:quit)
      shell.stopped.should eq([:discover, :fuzzer, :miner, :sequencer, :repeater, :oast])
      shell.jobs.any_active?.should be_false
      shell.committed?.should be_true
    end
  end
end

# The palette's "Quit gori" reaches the shell as ctx.quit! (spec/verbs/core_spec.cr pins that
# dispatch), so THIS is that path: with "Confirm before quit" on it must raise the same modal
# the ^C/^D chord raises, name the same jobs, and — like leave_project — change nothing until
# the operator accepts. It used to tear down on the spot.
describe "quit through the guarded entry (the palette's Quit gori)" do
  it "raises the QUIT GORI confirm with the setting on, and names the live jobs" do
    with_confirm_quit(true) do
      shell = ExitShell.new
      shell.jobs.start(:discover, "http://127.0.0.1:19703/")
      shell.quit!

      shell.outcome.should eq(:running) # nothing torn down yet — the modal is up
      shell.stopped.should be_empty
      shell.committed?.should be_false
      shell.danger?.should be_true
      shell.message.should eq(
        "Quit gori? (pending edits are committed first)\n" \
        "1 job still running — quitting stops it.\n" \
        "discovering 1")

      shell.press(Termisu::Input::Key::LowerY)
      shell.outcome.should eq(:quit)
      shell.stopped.should eq([:discover, :fuzzer, :miner, :sequencer, :repeater, :oast])
      shell.jobs.any_active?.should be_false
      shell.committed?.should be_true
    end
  end

  it "leaves the jobs running when the confirm is cancelled" do
    with_confirm_quit(true) do
      shell = ExitShell.new
      shell.jobs.start(:fuzz, "GET /a")
      shell.quit!

      shell.press(Termisu::Input::Key::Escape)
      shell.outcome.should eq(:running) # still in gori
      shell.stopped.should be_empty     # NOTHING was stopped
      shell.jobs.any_active?.should be_true
      shell.committed?.should be_false
    end
  end

  # Nothing running is still a quit worth confirming (it commits pending edits and drops the
  # session), and the modal keeps the original one-line wording.
  it "still confirms with the setting on when nothing is running" do
    with_confirm_quit(true) do
      shell = ExitShell.new
      shell.quit!
      shell.outcome.should eq(:running)
      shell.message.should eq("Quit gori? (pending edits are committed first)")
      shell.press(Termisu::Input::Key::LowerY)
      shell.outcome.should eq(:quit)
    end
  end

  # With the setting OFF the palette quits immediately — today's behaviour, kept on purpose:
  # arming here would toast "press ^D (or ^C) again", a chord this operator never pressed.
  it "quits outright with the setting off (the default)" do
    with_confirm_quit(false) do
      shell = ExitShell.new
      shell.jobs.start(:miner, "GET /api")
      shell.quit!
      shell.outcome.should eq(:quit)
      shell.committed?.should be_true
    end
  end
end
