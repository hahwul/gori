require "../support/fake_host"
require "file_utils"

include Gori::Tui

private FUZZ_RESTORE_CA = File.tempname("gori-fuzz-restore-ca")
Spec.after_suite { FileUtils.rm_rf(FUZZ_RESTORE_CA) }

private def with_fuzz_restore_project(session_count : Int32 = 1, &)
  root = File.tempname("gori-fuzz-restore")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("restore")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(FUZZ_RESTORE_CA),
      Gori::Verbs.registry, project)
    ids = Array(Int64).new(session_count)
    session_count.times do |i|
      ids << session.store.insert_fuzz_session("https://#{i}.test",
        "GET /#{i}?q=§x§ HTTP/1.1\r\nHost: #{i}.test\r\n\r\n", false, nil,
        %({"mode":"sniper"}), nil, i)
    end
    yield FakeHost.new(session), ids
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def seed_saved_fuzz_run(store : Gori::Store, session_id : Int64, label : String,
                                count : Int32 = 1, status : String = "done") : Int64
  run = store.insert_fuzz_run(session_id, "https://#{label}.test", "sniper", count.to_i64,
    status: "saving", surface: "tui")
  rows = Array(Gori::Store::FuzzResultWrite).new(count) do |i|
    Gori::Store::FuzzResultWrite.new(i.to_i64, %(["#{label}-#{i}"]), nil, 200 + i,
      label.bytesize.to_i64, 1, 1, 10_i64, nil, true, false, nil,
      "GET /#{label}/#{i} HTTP/1.1\r\n\r\n".to_slice,
      "HTTP/1.1 #{200 + i}\r\n\r\n".to_slice, label.to_slice)
  end
  store.insert_fuzz_results(run, rows).should be_true
  store.finish_fuzz_run(run, count.to_i64, count.to_i64, 0_i64, status).should be_true
  run
end

private def drain_until(controller : FuzzerController, &done : -> Bool)
  200.times do
    controller.drain_events
    return if done.call
    sleep 1.millisecond
  end
  raise "timed out waiting for fuzz saved-run restore"
end

describe "FuzzerController saved-run restore" do
  it "loads the newest successful run initially and each later session on first selection" do
    with_fuzz_restore_project(2) do |host, sessions|
      seed_saved_fuzz_run(host.session.store, sessions[0], "older")
      latest = seed_saved_fuzz_run(host.session.store, sessions[0], "latest", 2, "error")
      seed_saved_fuzz_run(host.session.store, sessions[0], "partial", 1, "save_failed")
      second = seed_saved_fuzz_run(host.session.store, sessions[1], "second")

      controller = FuzzerController.new(host)
      drain_until(controller) { controller.current_view.not_nil!.saved_run_id == latest }
      first = controller.current_view.not_nil!
      first.result_count.should eq(2)
      first.focus.should eq(:results)
      first.saved_run_id.should eq(latest)

      controller.jump_subtab(1)
      controller.current_view.not_nil!.saved_run_id.should be_nil
      drain_until(controller) { controller.current_view.not_nil!.saved_run_id == second }
      controller.current_view.not_nil!.result_count.should eq(1)

      # Revisiting an already-decided session neither launches another load nor appends rows.
      controller.jump_subtab(0)
      controller.current_view.not_nil!.saved_run_id.should eq(latest)
      controller.current_view.not_nil!.result_count.should eq(2)
      controller.jump_subtab(1)
      controller.current_view.not_nil!.saved_run_id.should eq(second)
      controller.current_view.not_nil!.result_count.should eq(1)
    end
  end

  it "keeps explicit history loading available for an older run" do
    with_fuzz_restore_project do |host, sessions|
      older = seed_saved_fuzz_run(host.session.store, sessions[0], "older")
      latest = seed_saved_fuzz_run(host.session.store, sessions[0], "latest")
      controller = FuzzerController.new(host)
      drain_until(controller) { controller.current_view.not_nil!.saved_run_id == latest }

      controller.load_saved_run(older)
      drain_until(controller) { controller.current_view.not_nil!.saved_run_id == older }
      controller.current_view.not_nil!.result_count.should eq(1)
    end
  end

  it "leaves the restored template alone when no successful run exists" do
    with_fuzz_restore_project do |host, sessions|
      seed_saved_fuzz_run(host.session.store, sessions[0], "partial", 1, "save_failed")
      controller = FuzzerController.new(host)
      5.times { Fiber.yield; controller.drain_events }

      view = controller.current_view.not_nil!
      view.saved_run_id.should be_nil
      view.result_count.should eq(0)
      view.template_text.should contain("GET /0?q=§x§")
    end
  end

  it "restores only the bounded newest window while preserving full run counters" do
    with_fuzz_restore_project do |host, sessions|
      run = seed_saved_fuzz_run(host.session.store, sessions[0], "large", 5_001)
      controller = FuzzerController.new(host)
      drain_until(controller) { controller.current_view.not_nil!.saved_run_id == run }

      view = controller.current_view.not_nil!
      view.result_count.should eq(5_001_i64)
      view.retained_result_count.should eq(Gori::Tui::FuzzerResultWindow::ROW_CAP)
      view.results_windowed?.should be_true
      view.results_count_label.should contain("showing 5000")
      controller.stop_all
    end
  end

  it "drops an automatic load completion after the view generation changes" do
    with_fuzz_restore_project do |host, sessions|
      seed_saved_fuzz_run(host.session.store, sessions[0], "old")
      controller = FuzzerController.new(host)
      view = controller.current_view.not_nil!
      view.reserve_result_load
      20.times { Fiber.yield; controller.drain_events }

      view.saved_run_id.should be_nil
      view.result_count.should eq(0)
    end
  end
end
