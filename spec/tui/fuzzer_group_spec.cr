require "../spec_helper"
require "../support/memory_backend"
require "../support/fake_host"
require "file_utils"

include Gori::Tui

# The RESULTS list grouped by response shape (#1351).

private def shaped(idx : Int32, shape : Int64, *, status : Int32 = 200, matched : Bool = false) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(idx.to_i64, ["p#{idx}"], nil, status, 10_i64 + idx, 3, 1, 1000_i64,
    nil, matched, false, nil, shape: shape)
end

private def grouped_fuzzer(window : FuzzerResultWindow = FuzzerResultWindow.new) : FuzzerView
  view = FuzzerView.new(window)
  view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
  view.focus_pane(:results)
  view.begin_run(6_i64)
  # A ×3 (0,1,2) · B ×1, matched (3) · C ×2 (4,5)
  [shaped(0, 0xa), shaped(1, 0xa), shaped(2, 0xa), shaped(3, 0xb, status: 500, matched: true),
   shaped(4, 0xc, status: 404), shaped(5, 0xc, status: 404)].each { |r| view.append_result(r) }
  view.finish_run("done")
  view
end

private FUZZ_GROUP_CA = File.tempname("gori-fuzz-group-ca")
Spec.after_suite { FileUtils.rm_rf(FUZZ_GROUP_CA) }

private def with_group_host(&)
  root = File.tempname("gori-fuzz-group")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("groups")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(FUZZ_GROUP_CA), Gori::Verbs.registry, project)
  begin
    yield FakeHost.new(session)
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def view_indices(view : FuzzerView) : Array(Int64)
  out = [] of Int64
  view.results_move(-1_000)
  loop do
    out << view.selected_result.not_nil!.index
    before = view.results_selected_index
    view.results_move(1)
    break if view.results_selected_index == before
  end
  view.results_move(-1_000)
  out
end

describe "FuzzerView grouped by response shape" do
  it "lists one representative per shape, rare first, over the whole run" do
    view = grouped_fuzzer
    view.toggle_grouped.should contain("3 clusters")
    view.grouped?.should be_true
    view_indices(view).should eq([3_i64, 4_i64, 0_i64])
    view.results_count_label.should contain("3 shapes")
  end

  it "expands a cluster with → and folds it back from a member with ←" do
    view = grouped_fuzzer
    view.toggle_grouped
    view.results_move(1) # C's header
    view.fold_group(true).should be_true
    view_indices(view).should eq([3_i64, 4_i64, 5_i64, 0_i64])
    view.results_move(-1_000)
    view.results_move(2) # C's member, #5
    view.selected_result.not_nil!.index.should eq(5)
    view.fold_group(false).should be_true
    view.selected_result.not_nil!.index.should eq(4) # back on C's header
    view_indices(view).should eq([3_i64, 4_i64, 0_i64])
    view.fold_group(false).should be_false # already folded
  end

  it "orders clusters with o while grouped, and sorts rows again once ungrouped" do
    view = grouped_fuzzer
    view.toggle_grouped
    view.cycle_sort.should eq("cluster order: common")
    view_indices(view).should eq([0_i64, 4_i64, 3_i64])
    view.cycle_sort.should eq("cluster order: first")
    view_indices(view).should eq([0_i64, 3_i64, 4_i64])
    view.toggle_grouped
    view.cycle_sort.should eq("sort: status")
  end

  it "keeps only the clusters holding a match under the matched-only lens" do
    view = grouped_fuzzer
    view.toggle_grouped
    view.toggle_matched_only
    view_indices(view).should eq([3_i64])
  end

  it "counts the whole run even after the window evicted the members" do
    view = grouped_fuzzer(FuzzerResultWindow.new(row_cap: 2))
    view.toggle_grouped
    # Only #4 and #5 are still in the window; A and B are drawn from the clusters' own
    # representatives, at their whole-run size.
    view_indices(view).should eq([3_i64, 4_i64, 0_i64])
    backend = MemoryBackend.new(160, 30)
    view.render(Screen.new(backend), Rect.new(0, 0, 160, 30))
    backend.contains?("▸×3").should be_true
    backend.contains?("▸×1").should be_true
  end

  it "draws folded and open headers, and the matched mark for a cluster with a hit" do
    view = grouped_fuzzer
    view.toggle_grouped
    view.results_move(2) # A
    view.fold_group(true)
    backend = MemoryBackend.new(160, 30)
    view.render(Screen.new(backend), Rect.new(0, 0, 160, 30))
    backend.contains?("▾×3").should be_true
    backend.contains?("▸×2").should be_true
    backend.contains?("×N").should be_true
  end

  it "starts every run with no clusters, and adopts a reopened run's whole-run clusters" do
    view = grouped_fuzzer
    view.clusters.size.should eq(3)
    view.begin_run(nil)
    view.clusters.size.should eq(0)

    clusters = Gori::Fuzz::Clusters.new
    10.times { |i| clusters.add(shaped(i, 0xd)) }
    window = FuzzerResultWindow.new
    window.append(shaped(9, 0xd))
    run = Gori::Store::FuzzRunRecord.new(1_i64, nil, 1_i64, 2_i64, "https://h", "sniper", 10_i64,
      10_i64, 0_i64, 0_i64, "done", false, nil, nil, false, "tui", nil, 1)
    view.load_saved_run(run, window, clusters)
    view.clusters.size.should eq(1)
    view.toggle_grouped
    backend = MemoryBackend.new(160, 30)
    view.render(Screen.new(backend), Rect.new(0, 0, 160, 30))
    backend.contains?("▸×10").should be_true
  end

  it "folds with → and ← in the RESULTS pane only while grouped" do
    with_group_host do |host|
      ctl = FuzzerController.new(host)
      ctl.fuzz_new
      view = ctl.current_view.not_nil!
      view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.begin_run(3_i64)
      [shaped(0, 0xa), shaped(1, 0xa), shaped(2, 0xb)].each { |r| view.append_result(r) }
      view.finish_run("done")
      view.focus_pane(:results)
      right = Termisu::Event::Key.new(Termisu::Input::Key::Right)
      left = Termisu::Event::Key.new(Termisu::Input::Key::Left)

      ctl.handle_body_key(right)
      view_indices(view).should eq([0_i64, 1_i64, 2_i64]) # ungrouped: → is not a fold

      ctl.fuzz_toggle_group
      view_indices(view).should eq([2_i64, 0_i64])
      view.results_move(1)
      ctl.handle_body_key(right)
      view_indices(view).should eq([2_i64, 0_i64, 1_i64])
      view.results_move(2) # the member #1: ← folds its cluster from there
      ctl.handle_body_key(left)
      view_indices(view).should eq([2_i64, 0_i64])
    end
  end
end
