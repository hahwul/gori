require "../../spec_helper"
require "../../support/fake_host"
require "../../support/memory_backend"
require "file_utils"

include Gori::Tui

private MINER_CA = File.tempname("gori-miner-ca")
Spec.after_suite { FileUtils.rm_rf(MINER_CA) }

private def with_miner_controller(&)
  root = File.tempname("gori-miner-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("miner")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(MINER_CA), Gori::Verbs.registry, project)
  begin
    yield MinerController.new(FakeHost.new(session)), session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def seed_miner_flow(store, url : String) : Int64
  pair = Gori::Import::Builder.complete_flow(
    Time.utc.to_unix_ms * 1000, url, "GET",
    Gori::Import::Builder::Headers.new, nil, "HTTP/1.1",
    200, "OK", Gori::Import::Builder::Headers.new, nil, "text/html", nil,
    source: Gori::FlowSource::Kind::Import)
  store.insert_import_batch([{pair.request, pair.response}])
  store.search(Gori::QL::EMPTY, 1).first.id
end

# Spin the scheduler until the worker's answer lands (the Runner does this once per tick).
private def drain_until_landed(ctl : MinerController) : Nil
  deadline = Time.instant + 10.seconds
  until ctl.drain_seed_names
    raise "seed-name scan never landed" if Time.instant > deadline
    sleep 1.millisecond
  end
end

# One restored miner session holding 50 findings, on FINDINGS. The session row needs real
# request bytes: `insert_miner_session` binds them to a `BLOB NOT NULL` column.
private def with_findings(&)
  root = File.tempname("gori-miner-page")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("miner-page")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(MINER_CA), Gori::Verbs.registry, project)
  begin
    session.store.insert_miner_session("https://shop.test",
      "GET /login HTTP/1.1\r\nHost: shop.test\r\n\r\n".to_slice, false, nil, "{}", nil, 0).should be > 0
    ctl = MinerController.new(FakeHost.new(session))
    view = ctl.current_view.not_nil!
    50.times do |i|
      view.append_finding(Gori::Miner::Finding.new("p#{i}", Gori::Miner::Location::Query,
        Gori::Miner::Evidence::Status, Gori::Miner::Confidence::Confirmed, nil, nil, 0_i64))
    end
    view.focus_pane(:results)
    yield ctl, view
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The controller's half of a History mine's seed names: the scan runs off the event loop and
# lands on the popup through `drain_seed_names`. The names themselves are pinned in
# spec/param_inventory_spec.cr (`.seed_names`).
describe MinerController do
  describe "PgUp/PgDn/Home/End over FINDINGS (#1443)" do
    it "moves the selection on the Runner's page route" do
      with_findings do |ctl, view|
        view.select_result_row(25)
        {Termisu::Input::Key::Home, Termisu::Input::Key::End,
         Termisu::Input::Key::PageUp, Termisu::Input::Key::PageDown}.each do |k|
          ctl.handle_body_key(Termisu::Event::Key.new(k)).should be_false
        end
        view.results_selected_index.should eq(25)

        # The Runner sends Home/End as ±JUMP_ROWS; `results_move` clamps them.
        ctl.body_scroll(-Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(0)
        ctl.body_scroll(Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(49)
      end
    end

    it "pages by the rows FINDINGS drew last frame" do
      with_findings do |ctl, view|
        ctl.page_rows.should eq(1) # nothing drawn yet
        view.render(Screen.new(MemoryBackend.new(100, 40)), Rect.new(0, 0, 100, 40), true)
        step = ctl.page_rows.not_nil!
        step.should be > 1
        ctl.body_scroll(step).should be_true
        view.results_selected_index.should eq(step)
      end
    end

    it "leaves SUMMARY and DETAIL out of the route" do
      with_findings do |ctl, view|
        view.focus_pane(:summary)
        ctl.body_scroll(Runner::JUMP_ROWS).should be_false
        ctl.page_rows.should be_nil
        view.focus_pane(:results)
        view.open_detail
        view.focus.should eq(:detail)
        ctl.body_scroll(Runner::JUMP_ROWS).should be_false
        ctl.page_rows.should be_nil
      end
    end
  end

  describe "#scan_seed_names (#1231)" do
    it "seeds a History mine with the host's other endpoints' names" do
      with_miner_controller do |ctl, session|
        seed_miner_flow(session.store, "https://acme.test/orders?tenant=1")
        id = seed_miner_flow(session.store, "https://acme.test/invoices?page=1")
        ov = MineConfigOverlay.new(ctl.build_seed_from_flow(id) || raise "no seed for flow #{id}")
        ctl.scan_seed_names(ov)
        ov.seeding?.should be_true
        drain_until_landed(ctl)
        ov.seeding?.should be_false
        ov.build_config.seed_names.should eq(["tenant"])
      end
    end

    # Start cancels it, and a newer popup's scan supersedes it: either way the old answer is
    # dropped rather than landed on a popup that no longer decides anything.
    it "drops a cancelled scan's answer" do
      with_miner_controller do |ctl, session|
        seed_miner_flow(session.store, "https://acme.test/orders?tenant=1")
        id = seed_miner_flow(session.store, "https://acme.test/invoices?page=1")
        ov = MineConfigOverlay.new(ctl.build_seed_from_flow(id) || raise "no seed for flow #{id}")
        ctl.scan_seed_names(ov)
        ctl.cancel_seed_scan
        deadline = Time.instant + 2.seconds
        until Time.instant > deadline
          ctl.drain_seed_names.should be_false
          sleep 5.milliseconds
        end
        ov.build_config.seed_names.should be_empty
      end
    end

    # esc or a click outside runs the popup's on_close: its scan stops there instead of reading
    # every host's flows for a popup nobody sees. A popup closing after a newer one opened
    # must not cancel the newer scan.
    it "cancels the scan when its popup is dismissed, and only its own" do
      with_miner_controller do |ctl, session|
        seed_miner_flow(session.store, "https://acme.test/orders?tenant=1")
        id = seed_miner_flow(session.store, "https://acme.test/invoices?page=1")
        seed = ctl.build_seed_from_flow(id) || raise "no seed for flow #{id}"
        old = MineConfigOverlay.new(seed)
        ctl.scan_seed_names(old)
        gen = ctl.seed_generation
        old.on_close.not_nil!.call
        ctl.seed_generation.should_not eq(gen)

        fresh = MineConfigOverlay.new(seed)
        ctl.scan_seed_names(fresh)
        old.on_close.not_nil!.call # late: the newer scan stays current
        drain_until_landed(ctl)
        fresh.build_config.seed_names.should eq(["tenant"])
        old.build_config.seed_names.should be_empty
      end
    end

    it "does not scan for a seed with no flow behind it" do
      with_miner_controller do |ctl, _|
        seed = ctl.build_seed_from_request("https://acme.test", "GET /x HTTP/1.1\nHost: acme.test\n\n", false, nil)
        ov = MineConfigOverlay.new(seed)
        ctl.scan_seed_names(ov)
        ov.seeding?.should be_false
      end
    end
  end

  # #1379: the start toast says "watch the bottom bar", and under the default "when found" an
  # empty run then said nothing there at all.
  describe "a finished run with nothing found" do
    it "says so on the bottom bar under the default notify mode" do
      root = File.tempname("gori-miner-done")
      Dir.mkdir_p(root)
      project = Gori::ProjectRegistry.new(root).temp("miner-done")
      session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
        Gori::Proxy::Tls::CertAuthority.load_or_create(MINER_CA), Gori::Verbs.registry, project)
      begin
        session.store.insert_miner_session("https://shop.test",
          "GET /login HTTP/1.1\r\nHost: shop.test\r\n\r\n".to_slice, false, nil, "{}", nil, 0).should be > 0
        host = FakeHost.new(session)
        ctl = MinerController.new(host)
        view = ctl.current_view.not_nil!
        view.config.notify.when_found?.should be_true
        progress = Gori::Miner::Progress.new(names_total: 10_i64, names_done: 10_i64, sent: 12_i64,
          found: 0, errors: 0_i64)
        ctl.@mine_events.send({view, Gori::Miner::DoneEvent.new(progress, false).as(Gori::Miner::Event)})
        ctl.drain_events.should be_true
        host.statuses.last.should start_with("Miner: done — nothing found on ")
        host.notifications.all.should be_empty # the notification centre stays gated
      ensure
        session.close
        FileUtils.rm_rf(root) if Dir.exists?(root)
      end
    end
  end

  # The shell MinerController shares with SequencerController (#1463): the seed's request
  # summary, the empty state, the key tail and the close path.
  describe "the seeded-session shell" do
    it "summarises a seed's request line unclipped, or `request` when there is none" do
      with_miner_controller do |ctl, _|
        path = "/#{"a" * 60}"
        ctl.build_seed_from_request("https://shop.test", "POST #{path} HTTP/1.1\nHost: shop.test\n\n", false, nil)
          .summary.should eq("POST #{path}")
        ctl.build_seed_from_request("https://shop.test", "\n", false, nil).summary.should eq("request")
      end
    end

    it "draws the Miner's empty state with no session open" do
      with_miner_controller do |ctl, _|
        backend = MemoryBackend.new(100, 30)
        ctl.render_body(Screen.new(backend), Rect.new(0, 0, 100, 30), :body)
        backend.contains?("no mining session").should be_true
      end
    end

    it "leaves a bare key no pane takes to the keymap" do
      with_findings do |ctl, view|
        view.focus_pane(:summary)
        ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerZ, char: 'z')).should be_false
      end
    end

    it "closes the active session on ^W behind a confirm that names its request" do
      with_findings do |ctl, _|
        host = ctl.@host.as(FakeHost)
        ctrl_w = Termisu::Event::Key.new(Termisu::Input::Key::LowerW, Termisu::Input::Modifier::Ctrl)
        ctl.handle_body_key(ctrl_w).should be_true
        host.confirms.should eq([{"CLOSE MINER", "Close mining session “GET /login”?\nIts config and results are discarded."}])
        ctl.current_view.should be_nil
        ctl.subtab_strip_shown?.should be_false
        host.session.store.miner_sessions.should be_empty
        host.statuses.last.should eq("closed — none open")
      end
    end

    # ^1-9 is an absolute chip number and escapes the strip filter: a chip it hides must not
    # become the active one while no visible chip is lit.
    it "drops the strip filter when ^2 lands on a chip it hides" do
      with_miner_controller do |_, session|
        store = session.store
        store.insert_miner_session("https://a.test", "GET /a HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, false, nil, "{}", nil, 0)
        store.insert_miner_session("https://b.test", "GET /b HTTP/1.1\r\nHost: b.test\r\n\r\n".to_slice, false, nil, "{}", nil, 1)
        ctl = MinerController.new(FakeHost.new(session))
        ctl.start_subtab_filter
        "a.test".each_char { |c| ctl.handle_subtab_filter_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
        ctl.subtab_hidden.not_nil!.should contain(1)
        ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Num2, Termisu::Input::Modifier::Ctrl, char: '2')).should be_true
        ctl.subtab_index.should eq(1)
        ctl.subtab_hidden.should be_nil
      end
    end

    # `reconcile` runs under the modal: a peer closing the named session slides the index onto
    # its neighbour, which the accepted confirm must not then close in its place.
    it "never closes a neighbour when a peer closed the named session under the confirm" do
      with_miner_controller do |_, session|
        store = session.store
        a = store.insert_miner_session("https://a.test", "GET /a HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, false, nil, "{}", nil, 0)
        store.insert_miner_session("https://b.test", "GET /b HTTP/1.1\r\nHost: b.test\r\n\r\n".to_slice, false, nil, "{}", nil, 1)
        host = FakeHost.new(session)
        ctl = MinerController.new(host)
        ctl.subtab_index.should eq(0)
        host.under_modal = -> { store.delete_miner_session(a); ctl.reconcile }
        ctl.request_close
        host.statuses.last.should eq("already closed")
        store.miner_sessions.size.should eq(1)
        ctl.current_view.should_not be_nil
      end
    end
  end
end
