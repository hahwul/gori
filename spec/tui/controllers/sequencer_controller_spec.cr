require "../../spec_helper"
require "../../support/fake_host"
require "../../support/memory_backend"
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

  describe "PgUp/PgDn/Home/End over SAMPLES (#1419)" do
    it "declines them to the Runner's page route and moves the selection there" do
      with_sequencer_controller do |ctl, _session|
        ctl.sequence_from_text((1..50).map { |i| "token_#{i}" }.join("\n"))
        Fiber.yield
        ctl.drain_events
        view = ctl.current_view.not_nil!
        view.focus_pane(:samples)
        view.select_sample_row(25)

        {Termisu::Input::Key::Home, Termisu::Input::Key::End,
         Termisu::Input::Key::PageUp, Termisu::Input::Key::PageDown}.each do |k|
          ctl.handle_body_key(Termisu::Event::Key.new(k)).should be_false
        end

        # The Runner sends Home/End as ±JUMP_ROWS; `samples_move` clamps them.
        ctl.body_scroll(-100_000).should be_true
        view.samples_selected_index.should eq(0)
        ctl.body_scroll(100_000).should be_true
        view.samples_selected_index.should eq(49)
      end
    end

    it "pages by the rows SAMPLES drew last frame" do
      with_sequencer_controller do |ctl, _session|
        ctl.sequence_from_text((1..50).map { |i| "token_#{i}" }.join("\n"))
        Fiber.yield
        ctl.drain_events
        view = ctl.current_view.not_nil!
        view.focus_pane(:samples)
        view.select_sample_row(0)
        ctl.page_rows.should eq(1) # nothing drawn yet

        view.render(Gori::Tui::Screen.new(MemoryBackend.new(80, 40)), Gori::Tui::Rect.new(0, 0, 80, 40), true)
        step = ctl.page_rows.not_nil!
        step.should be > 1
        ctl.body_scroll(step).should be_true
        view.samples_selected_index.should eq(step)
      end
    end

    it "leaves the keys to ANALYSIS and DETAIL, whose read panes own them" do
      with_sequencer_controller do |ctl, _session|
        ctl.sequence_from_text((1..50).map { |i| "token_#{i}" }.join("\n"))
        Fiber.yield
        ctl.drain_events
        view = ctl.current_view.not_nil!
        view.focus_pane(:analysis)
        ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Home)).should be_true
        ctl.body_scroll(100_000).should be_false
        ctl.page_rows.should be_nil
      end
    end
  end
end
