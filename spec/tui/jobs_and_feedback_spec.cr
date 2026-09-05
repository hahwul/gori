require "../support/tui_contract"

include Gori::Tui

# `Runner#stop_all_jobs` halts every engine on the way out of a project. Authorize was the
# one job-owning controller without a `stop_all`: its engine fiber owns its own sockets and
# kept sending after the operator was back at the picker, with the job pinned at `running`.
describe "AuthorizeController#stop_all" do
  it "is a no-op with nothing running, and answers without raising on every controller" do
    TuiContract.with_session("stop-all") do |session|
      TuiContract.each_controller(session) do |controller, host|
        next unless controller.is_a?(AuthorizeController)
        controller.running?.should be_false
        controller.stop_all
        host.jobs.active.should be_empty
      end
    end
  end
end

describe "Jobs::KIND_LABELS" do
  it "names every kind a controller starts, so the activity chip never falls back to `jobs N`" do
    %i[miner scan fuzz discover minimize sequence oast authorize fuzz_save fuzz_load].each do |kind|
      Jobs::KIND_LABELS.has_key?(kind).should be_true
    end
  end
end
