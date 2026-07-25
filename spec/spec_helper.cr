require "spec"
require "file_utils"

# Isolate the whole suite from the developer's real ~/.gori. Paths.home_dir falls
# back to ~/.gori unless GORI_HOME is set, and Settings is a process-wide singleton;
# without this, a spec that calls Settings.load / Paths.* would read and write the
# real home, and two parallel `crystal spec` runs (e.g. AI agents in sibling
# worktrees) could stomp each other. Set once, before src/gori is required, so any
# load-time path resolution already sees the temp home. Individual specs that still
# save/restore ENV["GORI_HOME"] per-example keep working (redundant but harmless).
GORI_TEST_HOME = File.tempname("gori-spec-home")
Dir.mkdir_p(GORI_TEST_HOME)
ENV["GORI_HOME"] = GORI_TEST_HOME

require "../src/gori"

Spec.after_suite { FileUtils.rm_rf(GORI_TEST_HOME) }

# The scope decision for a spec that is exercising something OTHER than the scope gate
# (payload generation, host overrides, engine plumbing). `Gori::Outbound` is a required
# constructor argument on every active sender — that is the whole point of the seam — so
# specs need an explicit "no project, nothing to gate against" decision rather than a nil.
# Specs that DO exercise the gate build a real Outbound over a real Scope; see
# spec/outbound_spec.cr.
def ungated_outbound : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end
