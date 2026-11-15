require "../spec_helper"
require "../support/fake_host"
require "file_utils"

include Gori::Tui

private EXIT_SAVE_CA = File.tempname("gori-exit-save-ca")
Spec.after_suite { FileUtils.rm_rf(EXIT_SAVE_CA) }

private def with_exit_save_host(&)
  root = File.tempname("gori-exit-save")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("exit-save")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(EXIT_SAVE_CA), Gori::Verbs.registry, project)
  begin
    yield FakeHost.new(session)
  ensure
    session.close
    FileUtils.rm_rf(root)
  end
end

describe "editor persistence outcomes used by the exit guard" do
  it "propagates refused writes while preserving authored buffers" do
    with_exit_save_host do |host|
      notes = NotesController.new(host)
      notes.notes_new
      decoder = DecoderController.new(host)
      decoder.decoder_from_text("keep this conversion")
      project = ProjectController.new(host)
      project.view.replace_desc("keep this description")
      rewriter = RewriterController.new(host)
      rewriter.@preview_input.set_text("keep this sample")
      host.session.store.close
      notes.commit.should be_false
      decoder.commit.should be_false
      project.commit.should be_false
      rewriter.commit.should be_false
      notes.view.dirty?.should be_true
      decoder.@dirty.should be_true
      project.view.desc_text.should eq("keep this description")
      rewriter.@preview_input.text.should eq("keep this sample")
    end
  end

  it "attempts every inactive and active tool sub-tab even when the first write fails" do
    with_exit_save_host do |host|
      store = host.session.store
      repeater = RepeaterController.new(host)
      fuzzer = FuzzerController.new(host)
      request = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".to_slice
      2.times do |i|
        repeater.repeater_new
        fuzzer.fuzz_new
        store.insert_miner_session("https://example.test", request, false, nil, "{}", nil, i).should_not eq(0_i64)
        store.insert_sequencer_session("https://example.test", request, false, nil, "{}", nil, i).should_not eq(0_i64)
      end
      miner = MinerController.new(host)
      sequencer = SequencerController.new(host)
      repeater.@repeaters.each(&.view.replace_request(String.new(request)))
      fuzzer.@sessions.each(&.view.toggle_http2)
      miner.@sessions.each(&.view.set_config(Gori::Miner::Config.new))
      sequencer.@sessions.each { |t| t.view.set_config(Gori::Sequencer::Config.new) }
      store.close
      {% for tool in %w[repeater fuzzer miner sequencer] %}
        before = host.statuses.size
        {{ tool.id }}.save_all.should be_false
        host.statuses.size.should eq(before + 2)
      {% end %}
    end
  end
end
