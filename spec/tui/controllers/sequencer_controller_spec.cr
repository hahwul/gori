require "../../spec_helper"
require "../../support/fake_host"
require "file_utils"

include Gori::Tui

private SEQUENCER_CA = File.tempname("gori-sequencer-ca")
Spec.after_suite { FileUtils.rm_rf(SEQUENCER_CA) }

private def with_sequencer_controller(&)
  root = File.tempname("gori-sequencer-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("sequencer")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(SEQUENCER_CA), Gori::Verbs.registry, project)
  begin
    yield SequencerController.new(FakeHost.new(session)), session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe SequencerController do
  it "follows cursor to the tail when draining streamed samples (#1429)" do
    with_sequencer_controller do |ctl, _session|
      tokens = (1..20).map { |i| "token_#{i}" }.join("\n")
      ctl.sequence_from_text(tokens)

      view = ctl.current_view.not_nil!

      # Yield so the background run fiber finishes sending events into the channel
      Fiber.yield

      # Drain the queued events on the main fiber
      ctl.drain_events

      # The cursor should follow to the last sample (index 19 of 20 samples)
      view.collected_count.should eq(20)
      view.samples_selected_index.should eq(19)
      view.running?.should be_false
    end
  end
end
