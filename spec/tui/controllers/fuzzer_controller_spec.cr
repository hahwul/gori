require "../../spec_helper"
require "../../support/fake_host"
require "../../support/memory_backend"
require "file_utils"

include Gori::Tui

private FUZZ_CTL_CA = File.tempname("gori-fuzz-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(FUZZ_CTL_CA) }

private def with_fuzzer_controller(&)
  root = File.tempname("gori-fuzz-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("fuzz")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(FUZZ_CTL_CA), Gori::Verbs.registry, project)
  begin
    yield FuzzerController.new(FakeHost.new(session))
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def fuzz_result(idx : Int32, shape : Int64 = idx.to_i64) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(idx.to_i64, ["p#{idx}"], nil, 200, 10_i64 + idx, 3, 1, 1000_i64,
    nil, false, false, nil, shape: shape)
end

# A finished run of `rows` on RESULTS.
private def finished_results(ctl : FuzzerController, rows : Array(Gori::Fuzz::Result)) : FuzzerView
  ctl.fuzz_new
  view = ctl.current_view.not_nil!
  view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
  view.begin_run(rows.size.to_i64)
  rows.each { |r| view.append_result(r) }
  view.finish_run("done")
  view.focus_pane(:results)
  view
end

private def page_key(k : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(k)
end

private PAGE_KEYS = {Termisu::Input::Key::Home, Termisu::Input::Key::End,
                     Termisu::Input::Key::PageUp, Termisu::Input::Key::PageDown}

describe FuzzerController do
  describe "PgUp/PgDn/Home/End over RESULTS (#1443)" do
    it "declines them to the Runner's page route and moves the selection there" do
      with_fuzzer_controller do |ctl|
        view = finished_results(ctl, (0...50).map { |i| fuzz_result(i) })
        view.select_result_row(25)

        PAGE_KEYS.each { |k| ctl.handle_body_key(page_key(k)).should be_false }
        view.results_selected_index.should eq(25) # declined, not acted on

        # The Runner sends Home/End as ±JUMP_ROWS; `results_move` clamps them.
        ctl.body_scroll(-Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(0)
        ctl.body_scroll(Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(49)
      end
    end

    it "pages by the rows RESULTS drew last frame" do
      with_fuzzer_controller do |ctl|
        view = finished_results(ctl, (0...50).map { |i| fuzz_result(i) })
        ctl.page_rows.should eq(1) # nothing drawn yet

        view.render(Screen.new(MemoryBackend.new(120, 40)), Rect.new(0, 0, 120, 40))
        step = ctl.page_rows.not_nil!
        step.should be > 1
        ctl.body_scroll(step).should be_true
        view.results_selected_index.should eq(step)
        ctl.body_scroll(-step).should be_true
        view.results_selected_index.should eq(0)
      end
    end

    # Grouped by shape (#1351) the list is the clusters' lines, so End lands on the last line
    # drawn, never on a member of a folded cluster.
    it "jumps over the grouped lines as drawn" do
      with_fuzzer_controller do |ctl|
        # A ×3 (0,1,2) · B ×2 (3,4) · C ×1 (5): rare first puts C, then B, then A last.
        shapes = [0xa_i64, 0xa_i64, 0xa_i64, 0xb_i64, 0xb_i64, 0xc_i64]
        view = finished_results(ctl, shapes.map_with_index { |s, i| fuzz_result(i, s) })
        ctl.fuzz_toggle_group

        ctl.body_scroll(Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(2)
        view.selected_result.not_nil!.index.should eq(0) # A's header, its members folded

        view.fold_group(true).should be_true # open A: its members follow its header
        ctl.body_scroll(Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(4)
        view.selected_result.not_nil!.index.should eq(2)
        ctl.body_scroll(-Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(0)
      end
    end

    it "leaves the keys to DETAIL, whose read pane owns them" do
      with_fuzzer_controller do |ctl|
        view = finished_results(ctl, (0...50).map { |i| fuzz_result(i) })
        view.open_detail
        view.focus.should eq(:detail)
        ctl.handle_body_key(page_key(Termisu::Input::Key::Home)).should be_true
        ctl.body_scroll(Runner::JUMP_ROWS).should be_false
        ctl.page_rows.should be_nil
      end
    end
  end
end
