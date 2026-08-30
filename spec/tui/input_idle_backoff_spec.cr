require "../spec_helper"
require "../../src/gori/tui/input_idle_backoff_patch"

# The delete trigger for `src/gori/tui/input_idle_backoff_patch.cr`, and the proof it is still
# wired in.
#
# It carries its OWN pin rather than leaning on `paste_end_marker_spec.cr`'s. That spec exists
# to be deleted — it is the trigger for the other carried patch, and the day termisu ships the
# paste fix, that file and its pin go with it. This patch would then have silently lost its only
# guard, which is the failure the pin exists to prevent.
describe "the termisu pin the carried input back-off is written against" do
  it "has not moved (if it has, re-check whether input_idle_backoff_patch.cr is still needed)" do
    lock = File.read(File.join(__DIR__, "..", "..", "shard.lock"))
    pinned = lock[/termisu:.*?commit\.([0-9a-f]{40})/m, 1]?

    pinned.should eq("df6e907e6fe27f2cc70b9f855dff996d08398ad1")
  end

  # The patch reopens `Termisu::Event::Source::Input` and overrides a PRIVATE method, so no spec
  # can call it. What a spec can see is that the reopen is compiled in at all: these two
  # constants exist nowhere in termisu, so their presence pins that the file is required and
  # applied. A rename upstream would leave them defined with a dead `run_loop` beside them —
  # which is what the lock pin above is for.
  it "is compiled in, and its cadences are ordered" do
    Termisu::Event::Source::Input::IDLE_GRACE.should be > Termisu::Event::Source::Input::DEEP_IDLE_SLEEP
    Termisu::Event::Source::Input::DEEP_IDLE_SLEEP.should be > Termisu::Event::Source::Input::IDLE_SLEEP
  end
end
